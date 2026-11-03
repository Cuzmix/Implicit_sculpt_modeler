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

// Releases the texture; a frame in flight that samples it keeps it until it is done.
matcap_destroy :: proc(r: ^Renderer, tex: ^gpu.Texture) {
	if tex^ == 0 do return
	gpu.release_texture(tex^)
	tex^ = 0
}

// Copies RGBA8 `pixels` into mip level 0 of `tex` and, with `mips`, has the GPU build the
// rest of the chain, on a command buffer of its own, submitted at once; the frames after
// it see the texture filled.
@(private)
texture_upload :: proc(r: ^Renderer, tex: gpu.Texture, pixels: []u8, width, height: int, mips: bool) -> bool {
	cmd := gpu.acquire_command_buffer()
	if cmd == nil {
		log.errorf("texture upload: %s", gpu.last_error())
		return false
	}
	if !gpu.upload_texture(cmd, {texture = tex, w = u32(width), h = u32(height), d = 1}, pixels) {
		log.errorf("texture upload: %s", gpu.last_error())
		_ = gpu.cancel_command_buffer(cmd)
		return false
	}
	if mips do gpu.generate_mipmaps_for_texture(cmd, tex)
	if _, ok := gpu.submit(cmd); !ok {
		log.errorf("texture upload submit: %s", gpu.last_error())
		return false
	}
	return true
}

// Makes a picture the interface draws from `pixels`: RGBA8 already encoded for the display
// (as the viewport's own pictures are, so the interface draws it unchanged), rows top to
// bottom, `width` by `height`, with mips for drawing it smaller. Release it with
// matcap_destroy. Nil, with the reason logged, when the device refuses.
picture_create :: proc(r: ^Renderer, pixels: []u8, width, height: int) -> gpu.Texture {
	return texture_create(r, VIEWPORT_COLOR_FORMAT, pixels, width, height)
}
