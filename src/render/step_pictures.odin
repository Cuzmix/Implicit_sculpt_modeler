package render

import "core:log"
import sdl "vendor:sdl3"

// The History's pictures of steps: each is the scene drawn again, as the main view saw it
// when the step was made, through that view's projection narrowed to a square round what
// the step changed, into a scratch target, then copied into its cell of one atlas, which
// the interface shows a cell at a time. Cells are taken in turn, so the newest
// STEP_PICTURE_SLOTS steps keep theirs.
Step_Pictures :: struct {
	atlas:   ^sdl.GPUTexture,
	scratch: Thumbnail_View,
	failed:  bool, // the device refused a texture; no picture is drawn
}

// Each cell is STEP_PICTURE_PX pixels square, STEP_PICTURE_CELLS to a side of the atlas:
// a 72 point picture at two pixels a point.
STEP_PICTURE_PX :: 144
STEP_PICTURE_CELLS :: 8
STEP_PICTURE_SLOTS :: STEP_PICTURE_CELLS * STEP_PICTURE_CELLS

step_pictures_destroy :: proc(r: ^Renderer, s: ^Step_Pictures) {
	if r.device == nil do return
	_ = gpu_wait_for_idle(r.device)
	if s.atlas != nil do gpu_release_texture(r.device, s.atlas)
	thumbnail_view_destroy(r, &s.scratch)
	s^ = {}
}

// Draws `items` seen through `view` and `proj` (the main view's, narrowed to the cell's
// square) on `background` into cell `slot`. False when there is no atlas to draw into.
step_pictures_draw :: proc(r: ^Renderer, s: ^Step_Pictures, cmd: ^sdl.GPUCommandBuffer, slot: int, view, proj: Mat4, items: []Draw_Item, background: [4]f32) -> bool {
	debug_group(cmd, "Step picture")
	if s.failed || slot < 0 || slot >= STEP_PICTURE_SLOTS do return false
	if s.atlas == nil {
		SIZE :: STEP_PICTURE_PX * STEP_PICTURE_CELLS
		s.atlas = gpu_create_texture(r.device, {
			type = .D2, format = VIEWPORT_COLOR_FORMAT, usage = {.COLOR_TARGET, .SAMPLER},
			width = SIZE, height = SIZE, layer_count_or_depth = 1, num_levels = 1,
		})
		if s.atlas == nil {
			log.errorf("step pictures: %s", sdl.GetError())
			s.failed = true
			return false
		}
		// A new texture holds anything: every cell starts empty.
		color := sdl.GPUColorTargetInfo{texture = s.atlas, load_op = .CLEAR, store_op = .STORE}
		pass := gpu_begin_render_pass(cmd, &color, 1, nil)
		gpu_end_render_pass(pass)
	}
	drawn := thumbnail_view_draw(r, &s.scratch, cmd, {STEP_PICTURE_PX, STEP_PICTURE_PX}, view, proj, items, background, supersample = 1)
	if drawn == nil {
		s.failed = s.scratch.failed
		return false
	}
	copy_pass := gpu_begin_copy_pass(cmd)
	x, y := u32(slot % STEP_PICTURE_CELLS) * STEP_PICTURE_PX, u32(slot / STEP_PICTURE_CELLS) * STEP_PICTURE_PX
	gpu_copy_texture_to_texture(copy_pass, {texture = drawn}, {texture = s.atlas, x = x, y = y}, STEP_PICTURE_PX, STEP_PICTURE_PX, 1, cycle = false)
	gpu_end_copy_pass(copy_pass)
	return true
}

// Where cell `slot` lies in the atlas, as texture coordinates from 0 to 1.
step_picture_uv :: proc(slot: int) -> (lo, hi: [2]f32) {
	step := 1 / f32(STEP_PICTURE_CELLS)
	lo = {f32(slot % STEP_PICTURE_CELLS) * step, f32(slot / STEP_PICTURE_CELLS) * step}
	return lo, lo + step
}
