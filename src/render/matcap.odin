package render

import "../gpu"
import "core:log"

// MatCaps: a picture of a lit sphere that the mesh shader looks up by the surface's
// normal as the camera sees it, so the light, colour and sheen painted into the picture
// cover the whole mesh with one texture fetch a pixel, as ZBrush's MatCap materials and
// Blender's MatCap shading do. The picture is sRGB, so sampling returns linear light and
// filtering blends in linear light; it has a full mip chain, so a dense mesh whose normals
// turn quickly across a pixel reads the blurred sphere rather than shimmering.
MATCAP_FORMAT :: gpu.Format.RGBA8_Srgb

// Makes a matcap texture from `pixels`: RGBA8 sRGB, rows top to bottom, `width` by
// `height`, the sphere filling the picture. The upload and the mip chain are recorded on
// a command buffer of their own and submitted, so it may be called outside a frame. Nil,
// with the reason logged, when the device refuses.
matcap_create :: proc(r: ^Renderer, pixels: []u8, width, height: int) -> gpu.Texture {
	return texture_create(r, MATCAP_FORMAT, pixels, width, height)
}

// Waits for the GPU (a frame in flight may still sample it) and releases the texture.
matcap_destroy :: proc(r: ^Renderer, tex: ^gpu.Texture) {
	if tex^ == nil do return
	_ = gpu.wait_for_idle()
	gpu.release_texture(tex^)
	tex^ = nil
}

// Copies RGBA8 `pixels` into mip level 0 of `tex` and, with `mips`, has the GPU build the
// rest of the chain; waits for the GPU so the transfer buffer can go at once.
@(private)
texture_upload :: proc(r: ^Renderer, tex: gpu.Texture, pixels: []u8, width, height: int, mips: bool) -> bool {
	transfer := gpu.create_transfer_buffer({usage = .Upload, size = u32(len(pixels))})
	if transfer == nil {
		log.errorf("texture upload buffer: %s", gpu.last_error())
		return false
	}
	defer gpu.release_transfer_buffer(transfer)
	dst := ([^]u8)(gpu.map_transfer_buffer(transfer, false))
	if dst == nil {
		log.errorf("texture upload map: %s", gpu.last_error())
		return false
	}
	copy(dst[:len(pixels)], pixels)
	gpu.unmap_transfer_buffer(transfer)

	cmd := gpu.acquire_command_buffer()
	if cmd == nil {
		log.errorf("texture upload: %s", gpu.last_error())
		return false
	}
	pass := gpu.begin_copy_pass(cmd)
	gpu.upload_to_texture(pass,
		{transfer_buffer = transfer, pixels_per_row = u32(width), rows_per_layer = u32(height)},
		{texture = tex, w = u32(width), h = u32(height), d = 1}, false)
	gpu.end_copy_pass(pass)
	if mips do gpu.generate_mipmaps_for_texture(cmd, tex)
	fence := gpu.submit_command_buffer_and_acquire_fence(cmd)
	if fence == nil {
		log.errorf("texture upload submit: %s", gpu.last_error())
		return false
	}
	defer gpu.release_fence(fence)
	return gpu.wait_for_fences(true, &fence, 1)
}

// Makes a picture the interface draws from `pixels`: RGBA8 already encoded for the display
// (as the viewport's own pictures are, so the interface draws it unchanged), rows top to
// bottom, `width` by `height`, with mips for drawing it smaller. Release it with
// matcap_destroy. Nil, with the reason logged, when the device refuses.
picture_create :: proc(r: ^Renderer, pixels: []u8, width, height: int) -> gpu.Texture {
	return texture_create(r, VIEWPORT_COLOR_FORMAT, pixels, width, height)
}
