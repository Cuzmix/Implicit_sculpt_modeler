package voxel

import "base:runtime"

import "../geom"

// Undo keeps, per stroke, a copy of every brick the stroke touched as it was before the
// stroke: its values, or the tile it was. A step is its own inverse: undo swaps each saved
// brick with the live one (a brick the stroke made goes back to its tile and the saved
// copy now holds the stroke's values), so redo is the same swap again. Only the bricks a
// stroke touched are saved, never the volume, so a step costs 1 KiB a brick.

// The most memory the steps may hold before the oldest are dropped, as the mesh sculptor's.
UNDO_LIMIT_BYTES :: 512 << 20

Saved_Brick :: struct {
	coord: [3]i32,
	tile:  Tile, // Empty or Inside: the brick was that tile and `values` is unused
	mask:  i32, // the brick's mask, an index into the step's masks, or -1 for none
	d:     [BRICK_VOXELS]i16,
}

// A brick appears once a stroke while it stays a brick (Volume.saved holds the stroke
// that saved each slot); a brick that collapsed to a tile and was made again in the same
// stroke appears again. Undo applies the list backwards and redo forwards, so repeated
// entries unwind in the order they were made and the step stays its own inverse.
Undo_Step :: struct {
	bricks: [dynamic]Saved_Brick,
	masks:  [dynamic]Mask_Brick, // the saved bricks' masks, those that had one
}

Undo_History :: struct {
	steps:     [dynamic]Undo_Step,
	cursor:    int, // steps[:cursor] are undoable, steps[cursor:] redoable
	bytes:     int,
	stroke:    u32, // the recording stroke's id, stamped on the slots it saved; never 0
	recording: bool, // between clay_stroke_begin and clay_stroke_end
	allocator: runtime.Allocator,
}

@(private)
undo_init :: proc(h: ^Undo_History, allocator: runtime.Allocator) {
	h.allocator = allocator
	h.steps = make([dynamic]Undo_Step, allocator)
}

@(private)
undo_destroy :: proc(h: ^Undo_History) {
	for &s in h.steps do undo_step_destroy(&s)
	delete(h.steps)
	h^ = {}
}

@(private)
undo_step_destroy :: proc(s: ^Undo_Step) {
	delete(s.bricks)
	delete(s.masks)
	s^ = {}
}

@(private)
undo_step_bytes :: proc(s: ^Undo_Step) -> int {
	return len(s.bricks) * size_of(Saved_Brick) + len(s.masks) * size_of(Mask_Brick)
}

// Starts a stroke's step: the redo steps are dropped, as a new stroke makes them unreachable.
@(private)
undo_begin :: proc(h: ^Undo_History) {
	assert(!h.recording, "a stroke is already recording")
	for i in h.cursor ..< len(h.steps) {
		h.bytes -= undo_step_bytes(&h.steps[i])
		undo_step_destroy(&h.steps[i])
	}
	resize(&h.steps, h.cursor)
	append(&h.steps, Undo_Step{bricks = make([dynamic]Saved_Brick, h.allocator), masks = make([dynamic]Mask_Brick, h.allocator)})
	h.stroke += 1
	h.recording = true
}

// The step being recorded.
@(private)
undo_current :: #force_inline proc(h: ^Undo_History) -> ^Undo_Step {
	assert(h.recording, "no stroke is recording")
	return &h.steps[len(h.steps) - 1]
}

// Saves brick `bc` as it is now, the first time the stroke touches it; later calls do
// nothing while it stays a brick. A tile is saved every time, since it has no slot to
// stamp: the dab that records it makes it a brick right after, so that is once too.
@(private)
undo_record :: proc(h: ^Undo_History, v: ^Volume, bc: [3]i32) {
	step := undo_current(h)
	saved := Saved_Brick {
		coord = bc,
		mask  = -1,
	}
	tile, brick := volume_tile(v, bc)
	saved.tile = tile
	if brick != nil {
		slot := volume_slot(v, bc)
		if v.saved[slot] == h.stroke do return
		v.saved[slot] = h.stroke
		saved.d = brick.d
		if m := mask_of(v, slot); m != nil {
			saved.mask = i32(len(step.masks))
			append(&step.masks, m^)
			h.bytes += size_of(Mask_Brick)
		}
	}
	append(&step.bricks, saved)
	h.bytes += size_of(Saved_Brick)
}

// Ends the stroke's step; an empty one (the stroke changed nothing) is dropped. Returns
// whether a step was kept. The oldest steps go when the limit is passed.
@(private)
undo_end :: proc(h: ^Undo_History) -> bool {
	step := undo_current(h)
	h.recording = false
	if len(step.bricks) == 0 {
		undo_step_destroy(step)
		pop(&h.steps)
		return false
	}
	h.cursor = len(h.steps)
	dropped := 0
	for h.bytes > UNDO_LIMIT_BYTES && h.cursor - dropped > 1 {
		h.bytes -= undo_step_bytes(&h.steps[dropped])
		undo_step_destroy(&h.steps[dropped])
		dropped += 1
	}
	if dropped > 0 {
		copy(h.steps[:], h.steps[dropped:])
		resize(&h.steps, len(h.steps) - dropped)
		h.cursor -= dropped
	}
	return true
}

// Swaps every brick of the step with the volume, backwards for undo and forwards for redo:
// the step then holds what the volume held. The bricks' nodes are marked for remeshing.
@(private)
undo_swap :: proc(c: ^Clay, s: ^Undo_Step, backwards: bool) {
	v := &c.volume
	for k in 0 ..< len(s.bricks) {
		saved := &s.bricks[len(s.bricks) - 1 - k if backwards else k]
		bc := saved.coord
		live_tile, live := volume_tile(v, bc)
		live_d: [BRICK_VOXELS]i16
		live_mask: Mask_Brick
		had_mask := false
		if live != nil {
			live_d = live.d
			if m := mask_of(v, volume_slot(v, bc)); m != nil {
				live_mask, had_mask = m^, true
			}
		}
		if saved.tile == .Brick {
			slot, b := volume_brick_make(v, bc, 0)
			b.d = saved.d
			if saved.mask >= 0 do mask_make(v, slot)^ = s.masks[saved.mask]
			else do mask_drop(v, slot)
		} else {
			volume_brick_collapse(v, bc, saved.tile)
		}
		saved.tile = live_tile
		saved.d = live_d
		// The live mask takes the saved one's place in the step, or a place of its own.
		if had_mask {
			if saved.mask < 0 {
				saved.mask = i32(len(s.masks))
				append(&s.masks, live_mask)
				c.history.bytes += size_of(Mask_Brick)
			} else {
				s.masks[saved.mask] = live_mask
			}
		} else {
			saved.mask = -1
		}
		surface_mark_brick(c, bc)
	}
}

clay_can_undo :: proc(c: ^Clay) -> bool {
	return !c.history.recording && c.history.cursor > 0
}

clay_can_redo :: proc(c: ^Clay) -> bool {
	return !c.history.recording && c.history.cursor < len(c.history.steps)
}

clay_undo :: proc(c: ^Clay) -> bool {
	if !clay_can_undo(c) do return false
	c.history.cursor -= 1
	undo_swap(c, &c.history.steps[c.history.cursor], true)
	return true
}

clay_redo :: proc(c: ^Clay) -> bool {
	if !clay_can_redo(c) do return false
	undo_swap(c, &c.history.steps[c.history.cursor], false)
	c.history.cursor += 1
	return true
}

// What the undo steps hold.
clay_undo_bytes :: proc(c: ^Clay) -> int {
	return c.history.bytes
}

// What the newest done step holds, in bytes (0 with none): the History panel's size for the
// step just recorded.
clay_last_step_bytes :: proc(c: ^Clay) -> int {
	if c.history.cursor <= 0 do return 0
	return undo_step_bytes(&c.history.steps[c.history.cursor - 1])
}

// The object-space box round the bricks the newest done step saved; empty (lo > hi) with
// none. The History panel tints it.
clay_last_step_bounds :: proc(c: ^Clay) -> (b: geom.Aabb) {
	b = geom.AABB_EMPTY
	if c.history.cursor <= 0 do return
	v := &c.volume
	for sb in c.history.steps[c.history.cursor - 1].bricks {
		lo := v.origin + Vec3{f32(sb.coord.x), f32(sb.coord.y), f32(sb.coord.z)} * (BRICK * v.voxel) - 0.5 * v.voxel
		geom.aabb_grow(&b, lo)
		geom.aabb_grow(&b, lo + BRICK * v.voxel)
	}
	return
}

// Drops the redo steps: the app's history did, after a change elsewhere.
clay_clear_redo :: proc(c: ^Clay) {
	h := &c.history
	for i in h.cursor ..< len(h.steps) {
		h.bytes -= undo_step_bytes(&h.steps[i])
		undo_step_destroy(&h.steps[i])
	}
	resize(&h.steps, h.cursor)
}

// Drops the oldest done steps (those before the cursor) until at most `keep` are left,
// leaving the steps to redo as they are, as the app's History dropped the entries that
// named them. Returns the bytes freed.
clay_drop_oldest :: proc(c: ^Clay, keep: int) -> int {
	h := &c.history
	n := h.cursor - max(keep, 0)
	if n <= 0 || h.recording do return 0
	before := h.bytes
	for i in 0 ..< n {
		h.bytes -= undo_step_bytes(&h.steps[i])
		undo_step_destroy(&h.steps[i])
	}
	remove_range(&h.steps, 0, n)
	h.cursor -= n
	return before - h.bytes
}

// Drops every step: the object was rebuilt and the app's history forgot it.
clay_clear_history :: proc(c: ^Clay) {
	h := &c.history
	assert(!h.recording, "a stroke is recording")
	for &s in h.steps do undo_step_destroy(&s)
	clear(&h.steps)
	h.cursor, h.bytes = 0, 0
}
