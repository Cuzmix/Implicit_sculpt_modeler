package render

import "core:log"
import sdl "vendor:sdl3"

// MatCaps: a picture of a lit sphere that the mesh shader looks up by the surface's
// normal as the camera sees it, so the light, colour and sheen painted into the picture
// cover the whole mesh with one texture fetch a pixel, as ZBrush's MatCap materials and
// Blender's MatCap shading do. The picture is sRGB, so sampling returns linear light and
// filtering blends in linear light; it has a full mip chain, so a dense mesh whose normals
// turn quickly across a pixel reads the blurred sphere rather than shimmering.
MATCAP_FORMAT :: sdl.GPUTextureFormat.R8G8B8A8_UNORM_SRGB

// Makes a matcap texture from `pixels`: RGBA8 sRGB, rows top to bottom, `width` by
// `height`, the sphere filling the picture. The upload and the mip chain are recorded on
// a command buffer of their own and submitted, so it may be called outside a frame. Nil,
// with the reason logged, when the device refuses.
matcap_create :: proc(r: ^Renderer, pixels: []u8, width, height: int) -> ^sdl.GPUTexture {
	return texture_create(r, MATCAP_FORMAT, pixels, width, height)
}

// Waits for the GPU (a frame in flight may still sample it) and releases the texture.
matcap_destroy :: proc(r: ^Renderer, tex: ^^sdl.GPUTexture) {
	if tex^ == nil do return
	_ = gpu_wait_for_idle(r.device)
	gpu_release_texture(r.device, tex^)
	tex^ = nil
}

// Copies RGBA8 `pixels` into mip level 0 of `tex` and, with `mips`, has the GPU build the
// rest of the chain; waits for the GPU so the transfer buffer can go at once.
@(private)
texture_upload :: proc(r: ^Renderer, tex: ^sdl.GPUTexture, pixels: []u8, width, height: int, mips: bool) -> bool {
	transfer := gpu_create_transfer_buffer(r.device, {usage = .UPLOAD, size = u32(len(pixels))})
	if transfer == nil {
		log.errorf("texture upload buffer: %s", sdl.GetError())
		return false
	}
	defer gpu_release_transfer_buffer(r.device, transfer)
	dst := ([^]u8)(gpu_map_transfer_buffer(r.device, transfer, false))
	if dst == nil {
		log.errorf("texture upload map: %s", sdl.GetError())
		return false
	}
	copy(dst[:len(pixels)], pixels)
	gpu_unmap_transfer_buffer(r.device, transfer)

	cmd := gpu_acquire_command_buffer(r.device)
	if cmd == nil {
		log.errorf("texture upload: %s", sdl.GetError())
		return false
	}
	pass := gpu_begin_copy_pass(cmd)
	gpu_upload_to_texture(pass,
		{transfer_buffer = transfer, pixels_per_row = u32(width), rows_per_layer = u32(height)},
		{texture = tex, w = u32(width), h = u32(height), d = 1}, false)
	gpu_end_copy_pass(pass)
	if mips do gpu_generate_mipmaps_for_texture(cmd, tex)
	fence := gpu_submit_command_buffer_and_acquire_fence(cmd)
	if fence == nil {
		log.errorf("texture upload submit: %s", sdl.GetError())
		return false
	}
	defer gpu_release_fence(r.device, fence)
	return gpu_wait_for_fences(r.device, true, &fence, 1)
}
