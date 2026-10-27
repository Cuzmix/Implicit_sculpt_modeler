package render

import "core:log"
import sdl "vendor:sdl3"

// Small pictures of objects for the Objects card's rows: each is drawn with the mesh
// pipeline into a scratch target cleared to transparent, then copied into its cell of
// one atlas texture, which the interface shows a cell at a time. A thumbnail is drawn
// from the mesh's whole index buffer (Draw_Item.chunks left nil), so it never touches
// the indirect commands prepare_draws records for the viewport this frame.
Thumbs :: struct {
	atlas:   ^sdl.GPUTexture,
	scratch: Viewport_Target,
	failed:  bool, // the device refused a texture; no thumbnail is drawn
}

// Each cell is THUMB_PX pixels square, THUMB_CELLS to a side of the atlas.
// 128 pixels covers a 44 point picture on a screen of up to about three pixels a point.
THUMB_PX :: 128
THUMB_CELLS :: 8
THUMB_SLOTS :: THUMB_CELLS * THUMB_CELLS

thumbs_destroy :: proc(r: ^Renderer, t: ^Thumbs) {
	if r.device == nil do return
	_ = sdl.WaitForGPUIdle(r.device)
	if t.atlas != nil do sdl.ReleaseGPUTexture(r.device, t.atlas)
	viewport_target_destroy(r, &t.scratch)
	t^ = {}
}

// The atlas, made and cleared to transparent on first use; nil when it cannot be made.
thumbs_atlas :: proc(r: ^Renderer, t: ^Thumbs, cmd: ^sdl.GPUCommandBuffer) -> ^sdl.GPUTexture {
	if t.failed do return nil
	if t.atlas != nil do return t.atlas
	SIZE :: THUMB_PX * THUMB_CELLS
	t.atlas = sdl.CreateGPUTexture(r.device, {
		type = .D2, format = VIEWPORT_COLOR_FORMAT, usage = {.COLOR_TARGET, .SAMPLER},
		width = SIZE, height = SIZE, layer_count_or_depth = 1, num_levels = 1,
	})
	if t.atlas == nil || !viewport_target_resize(r, &t.scratch, THUMB_PX, THUMB_PX) {
		log.errorf("thumbnail textures: %s", sdl.GetError())
		t.failed = true
		return nil
	}
	// A new texture holds anything: every cell starts empty.
	color := sdl.GPUColorTargetInfo{texture = t.atlas, load_op = .CLEAR, store_op = .STORE}
	pass := sdl.BeginGPURenderPass(cmd, &color, 1, nil)
	sdl.EndGPURenderPass(pass)
	return t.atlas
}

// Draws `item` into cell `slot` of the atlas, seen through `view` and `proj`, on a
// transparent background. False when there is no atlas to draw into.
thumbs_draw :: proc(r: ^Renderer, t: ^Thumbs, cmd: ^sdl.GPUCommandBuffer, slot: int, view, proj: Mat4, item: Draw_Item) -> bool {
	if thumbs_atlas(r, t, cmd) == nil || slot < 0 || slot >= THUMB_SLOTS do return false
	whole := item
	whole.chunks, whole.chunk_groups, whole.hidden = nil, nil, nil
	pass := begin_mesh_pass(r, cmd, &r.single, t.scratch.color, t.scratch.depth, load = false, keep_depth = false, background = {0, 0, 0, 0})
	draw_items(r, cmd, pass, &r.single, view, proj, {whole}, nil, nil)
	sdl.EndGPURenderPass(pass)
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	x, y := u32(slot % THUMB_CELLS) * THUMB_PX, u32(slot / THUMB_CELLS) * THUMB_PX
	sdl.CopyGPUTextureToTexture(copy_pass, {texture = t.scratch.color}, {texture = t.atlas, x = x, y = y}, THUMB_PX, THUMB_PX, 1, cycle = false)
	sdl.EndGPUCopyPass(copy_pass)
	return true
}

// Where cell `slot` lies in the atlas, as texture coordinates from 0 to 1.
thumb_uv :: proc(slot: int) -> (lo, hi: [2]f32) {
	step := 1 / f32(THUMB_CELLS)
	lo = {f32(slot % THUMB_CELLS) * step, f32(slot / THUMB_CELLS) * step}
	return lo, lo + step
}
