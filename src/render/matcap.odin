package render

import "core:log"
import "core:math/bits"
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
	assert(width > 0 && height > 0 && len(pixels) == width * height * 4)
	levels := u32(bits.log2(uint(max(width, height)))) + 1
	tex := sdl.CreateGPUTexture(r.device, {
		type = .D2, format = MATCAP_FORMAT, usage = {.SAMPLER, .COLOR_TARGET},
		width = u32(width), height = u32(height), layer_count_or_depth = 1, num_levels = levels,
	})
	if tex == nil {
		log.errorf("matcap texture: %s", sdl.GetError())
		return nil
	}
	if !texture_upload(r, tex, pixels, width, height, mips = levels > 1) {
		sdl.ReleaseGPUTexture(r.device, tex)
		return nil
	}
	return tex
}

// Waits for the GPU (a frame in flight may still sample it) and releases the texture.
matcap_destroy :: proc(r: ^Renderer, tex: ^^sdl.GPUTexture) {
	if tex^ == nil do return
	_ = sdl.WaitForGPUIdle(r.device)
	sdl.ReleaseGPUTexture(r.device, tex^)
	tex^ = nil
}

// Copies RGBA8 `pixels` into mip level 0 of `tex` and, with `mips`, has the GPU build the
// rest of the chain; waits for the GPU so the transfer buffer can go at once.
@(private)
texture_upload :: proc(r: ^Renderer, tex: ^sdl.GPUTexture, pixels: []u8, width, height: int, mips: bool) -> bool {
	transfer := sdl.CreateGPUTransferBuffer(r.device, {usage = .UPLOAD, size = u32(len(pixels))})
	if transfer == nil {
		log.errorf("texture upload buffer: %s", sdl.GetError())
		return false
	}
	defer sdl.ReleaseGPUTransferBuffer(r.device, transfer)
	dst := ([^]u8)(sdl.MapGPUTransferBuffer(r.device, transfer, false))
	if dst == nil {
		log.errorf("texture upload map: %s", sdl.GetError())
		return false
	}
	copy(dst[:len(pixels)], pixels)
	sdl.UnmapGPUTransferBuffer(r.device, transfer)

	cmd := sdl.AcquireGPUCommandBuffer(r.device)
	if cmd == nil {
		log.errorf("texture upload: %s", sdl.GetError())
		return false
	}
	pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUTexture(pass,
		{transfer_buffer = transfer, pixels_per_row = u32(width), rows_per_layer = u32(height)},
		{texture = tex, w = u32(width), h = u32(height), d = 1}, false)
	sdl.EndGPUCopyPass(pass)
	if mips do sdl.GenerateMipmapsForGPUTexture(cmd, tex)
	fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cmd)
	if fence == nil {
		log.errorf("texture upload submit: %s", sdl.GetError())
		return false
	}
	defer sdl.ReleaseGPUFence(r.device, fence)
	return sdl.WaitForGPUFences(r.device, true, &fence, 1)
}
