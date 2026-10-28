package render

import "core:log"
import sdl "vendor:sdl3"

// Pictures the CPU decoded for the interface to show, such as the Home screen's previews
// of saved scenes: each goes into a cell of one atlas texture from the frame's own
// command buffer, a few a frame, so a page of them fills in without a frame waiting for
// the GPU. A picture keeps its own size at its cell's top left; the interface shows that
// part alone (picture_uv).
Pictures :: struct {
	atlas:    ^sdl.GPUTexture,
	transfer: ^sdl.GPUTransferBuffer, // PICTURES_PER_FRAME cells' worth, cycled each frame
	failed:   bool, // the device refused a texture or buffer; no picture is shown
}

// Each cell is PICTURE_PX pixels square, PICTURE_CELLS to a side of the atlas: a scene's
// preview is at most 320 pixels on its long side, either way up, and 36 cells hold the
// Home screen's 24 recent scenes and the autosaves beside them without reading any twice.
PICTURE_PX :: 320
PICTURE_CELLS :: 6
PICTURE_SLOTS :: PICTURE_CELLS * PICTURE_CELLS
// The most pictures one frame uploads.
PICTURES_PER_FRAME :: 2

// One picture to put in a cell: RGBA8 `pixels`, `width` by `height`, each at most PICTURE_PX.
Picture_Upload :: struct {
	cell:          int,
	pixels:        []u8,
	width, height: int,
}

pictures_destroy :: proc(r: ^Renderer, p: ^Pictures) {
	if r.device == nil do return
	_ = gpu_wait_for_idle(r.device)
	if p.atlas != nil do gpu_release_texture(r.device, p.atlas)
	if p.transfer != nil do gpu_release_transfer_buffer(r.device, p.transfer)
	p^ = {}
}

// Uploads up to PICTURES_PER_FRAME of `items` into their cells on `cmd`, making the atlas
// (cleared to transparent) on first use. Items out of range are skipped. False when there
// is no atlas to upload into.
pictures_upload :: proc(r: ^Renderer, p: ^Pictures, cmd: ^sdl.GPUCommandBuffer, items: []Picture_Upload) -> bool {
	if p.failed do return false
	CELL_BYTES :: PICTURE_PX * PICTURE_PX * 4
	if p.atlas == nil {
		SIZE :: PICTURE_PX * PICTURE_CELLS
		p.atlas = gpu_create_texture(r.device, {
			type = .D2, format = .R8G8B8A8_UNORM, usage = {.COLOR_TARGET, .SAMPLER},
			width = SIZE, height = SIZE, layer_count_or_depth = 1, num_levels = 1,
		})
		p.transfer = gpu_create_transfer_buffer(r.device, {usage = .UPLOAD, size = CELL_BYTES * PICTURES_PER_FRAME})
		if p.atlas == nil || p.transfer == nil {
			log.errorf("picture textures: %s", sdl.GetError())
			p.failed = true
			return false
		}
		// A new texture holds anything: every cell starts empty.
		color := sdl.GPUColorTargetInfo{texture = p.atlas, load_op = .CLEAR, store_op = .STORE}
		pass := gpu_begin_render_pass(cmd, &color, 1, nil)
		gpu_end_render_pass(pass)
	}
	n := 0
	for it in items {
		if n < PICTURES_PER_FRAME && picture_fits(it) do n += 1
	}
	if n == 0 do return true
	// Cycled: the copy of an earlier frame may still be reading the buffer.
	dst := ([^]u8)(gpu_map_transfer_buffer(r.device, p.transfer, true))
	if dst == nil {
		log.errorf("picture map: %s", sdl.GetError())
		return false
	}
	at := 0
	for it in items {
		if at == n do break
		if !picture_fits(it) do continue
		copy(dst[at * CELL_BYTES:][:it.width * it.height * 4], it.pixels)
		at += 1
	}
	gpu_unmap_transfer_buffer(r.device, p.transfer)
	pass := gpu_begin_copy_pass(cmd)
	at = 0
	for it in items {
		if at == n do break
		if !picture_fits(it) do continue
		x, y := u32(it.cell % PICTURE_CELLS) * PICTURE_PX, u32(it.cell / PICTURE_CELLS) * PICTURE_PX
		gpu_upload_to_texture(pass,
			{transfer_buffer = p.transfer, offset = u32(at * CELL_BYTES), pixels_per_row = u32(it.width), rows_per_layer = u32(it.height)},
			{texture = p.atlas, x = x, y = y, w = u32(it.width), h = u32(it.height), d = 1}, false)
		at += 1
	}
	gpu_end_copy_pass(pass)
	return true
}

@(private = "file")
picture_fits :: proc(it: Picture_Upload) -> bool {
	return it.cell >= 0 && it.cell < PICTURE_SLOTS && it.width > 0 && it.height > 0 && it.width <= PICTURE_PX && it.height <= PICTURE_PX && len(it.pixels) >= it.width * it.height * 4
}

// Where a `width` by `height` picture in cell `cell` lies in the atlas, as texture
// coordinates from 0 to 1.
picture_uv :: proc(cell, width, height: int) -> (lo, hi: [2]f32) {
	SIZE :: f32(PICTURE_PX * PICTURE_CELLS)
	lo = {f32(cell % PICTURE_CELLS * PICTURE_PX) / SIZE, f32(cell / PICTURE_CELLS * PICTURE_PX) / SIZE}
	return lo, lo + {f32(width), f32(height)} / SIZE
}
