package sculpt

import "core:math"

import "../jobs"

// Adjust last stroke, as ZBrush's Adjust Last: the newest step, a stroke as drawn, is
// set to a share of itself after the fact. Every value the stroke changed (positions,
// a recording layer's displacement, masks, colours) becomes `before + k·(after − before)`,
// `before` being what the step saved and `after` what the stroke left, which the first
// adjust copies beside it. The step stays one step: undo saves what is current, so it
// takes the adjusted stroke back, and moving the step either way ends adjusting it
// (step_move frees the copy). Positions change through sculptor_nodes_moved, so bounds,
// normals, simplified copies and the levels' sync follow as they do after a dab.

// The most an adjust scales a stroke by: above 1 it goes on past what was drawn.
ADJUST_MAX :: f32(2)

// Whether the newest step can be adjusted: a stroke of positions, masks or colours with
// nothing else in it, not under dynamic topology (its steps change triangles), and not
// while another stroke is being recorded.
sculptor_can_adjust :: proc(s: ^Sculptor) -> bool {
	h := &s.history
	if s.dyn != nil || h.recording || len(h.done) == 0 do return false
	step := &h.done[len(h.done) - 1]
	if len(step.shown) > 0 || len(step.grouped) > 0 || step.layer_op.active || step.layer_set.active do return false
	for sv in step.saved {
		if sv.full || sv.hidden != nil || sv.groups != nil || sv.indices != nil do return false
		if sv.is_delta && (int(sv.delta_layer) >= len(s.layers.list) || s.layers.list[sv.delta_layer].delta[sv.node] == nil) do return false
	}
	return len(step.saved) > 0
}

// Sets the newest step to `k` (0 to ADJUST_MAX) of the stroke as drawn. False, changing
// nothing, when it cannot be adjusted (sculptor_can_adjust).
sculptor_stroke_adjust :: proc(s: ^Sculptor, k: f32) -> bool {
	if !sculptor_can_adjust(s) do return false
	h := &s.history
	if top := &h.done[len(h.done) - 1]; !top.adjusting {
		adjust_keep_after(s, top)
		history_trim(h)
	}
	// Taken after the trim, which moves the steps down when it drops the oldest.
	step := &h.done[len(h.done) - 1]
	a := Adjust{s = s, step = step, k = clamp(k, 0, ADJUST_MAX)}
	verts := 0
	for sv in step.saved do verts += int(s.nodes[sv.node].vert_count)
	jobs.parallel_for(s.pool if verts >= PARALLEL_MIN_VERTS else nil, len(step.saved), &a, job_adjust)
	for sv in step.saved do if sv.colors != nil do s.color_edited = true
	for id in step.painted do mark_stale(s, id, .Paint)
	sculptor_nodes_moved(s, step.nodes[:])
	return true
}

@(private = "file")
Adjust :: struct {
	s:    ^Sculptor,
	step: ^Undo_Step,
	k:    f32,
}

// Copies what the stroke left of every node it saved beside the step: one allocation
// for each kind of value, made here, then filled in parallel.
@(private = "file")
adjust_keep_after :: proc(s: ^Sculptor, step: ^Undo_Step) {
	h := &s.history
	vecs, bytes, colors := 0, 0, 0
	for sv in step.saved {
		n := int(s.nodes[sv.node].vert_count)
		switch {
		case sv.masks != nil:  bytes += n
		case sv.colors != nil: colors += n
		case:                  vecs += n
		}
	}
	step.after_vecs = make([]Vec3, vecs, h.allocator)
	step.after_masks = make([]u8, bytes, h.allocator)
	step.after_colors = make([]Color, colors, h.allocator)
	step.after_at = make([]int, len(step.saved), h.allocator)
	vecs, bytes, colors = 0, 0, 0
	for sv, i in step.saved {
		n := int(s.nodes[sv.node].vert_count)
		switch {
		case sv.masks != nil:
			step.after_at[i] = bytes
			bytes += n
		case sv.colors != nil:
			step.after_at[i] = colors
			colors += n
		case:
			step.after_at[i] = vecs
			vecs += n
		}
	}
	step.adjusting = true
	h.bytes += adjust_bytes(step^)
	a := Adjust{s = s, step = step}
	verts := vecs + bytes + colors
	jobs.parallel_for(s.pool if verts >= PARALLEL_MIN_VERTS else nil, len(step.saved), &a, proc(data: rawptr, i: int) {
		a := cast(^Adjust)data
		s, step := a.s, a.step
		sv := step.saved[i]
		n := s.nodes[sv.node]
		at := step.after_at[i]
		switch {
		case sv.masks != nil:  copy(step.after_masks[at:][:n.vert_count], s.mask[n.vert_first:][:n.vert_count])
		case sv.colors != nil: copy(step.after_colors[at:][:n.vert_count], s.color[n.vert_first:][:n.vert_count])
		case sv.is_delta:      copy(step.after_vecs[at:][:n.vert_count], s.layers.list[sv.delta_layer].delta[sv.node])
		case:                  copy(step.after_vecs[at:][:n.vert_count], s.mesh.positions[n.vert_first:][:n.vert_count])
		}
	})
}

// One saved node: its values set to the share of the way from before to after.
@(private = "file")
job_adjust :: proc(data: rawptr, i: int) {
	a := cast(^Adjust)data
	s, step, k := a.s, a.step, a.k
	sv := step.saved[i]
	n := s.nodes[sv.node]
	at := step.after_at[i]
	count := int(n.vert_count)
	switch {
	case sv.masks != nil:
		live := s.mask[n.vert_first:][:count]
		after := step.after_masks[at:][:count]
		for &m, j in live do m = adjust_byte(sv.masks[j], after[j], k)
	case sv.colors != nil:
		live := s.color[n.vert_first:][:count]
		after := step.after_colors[at:][:count]
		for &c, j in live do for ch in 0 ..< 4 do c[ch] = adjust_byte(sv.colors[j][ch], after[j][ch], k)
	case sv.is_delta:
		// A node with no displacement before the stroke saved none: it started at zero.
		live := s.layers.list[sv.delta_layer].delta[sv.node]
		after := step.after_vecs[at:][:count]
		for &p, j in live {
			before := sv.delta[j] if sv.delta != nil else Vec3{}
			p = adjust_vec(before, after[j], k)
		}
	case:
		live := s.mesh.positions[n.vert_first:][:count]
		after := step.after_vecs[at:][:count]
		for &p, j in live do p = adjust_vec(sv.positions[j], after[j], k)
	}
}

// The share k of the way from before to after, measured from the nearer end, so 0 gives
// before and 1 after exactly.
@(private = "file")
adjust_vec :: #force_inline proc(before, after: Vec3, k: f32) -> Vec3 {
	return before + k * (after - before) if k <= 0.5 else after + (1 - k) * (before - after)
}

@(private = "file")
adjust_byte :: #force_inline proc(before, after: u8, k: f32) -> u8 {
	v := f32(before) + k * (f32(after) - f32(before))
	return u8(clamp(math.round(v), 0, 255))
}

// What the copies an adjust keeps beside a step take.
@(private)
adjust_bytes :: proc(step: Undo_Step) -> int {
	return len(step.after_vecs) * size_of(Vec3) + len(step.after_masks) + len(step.after_colors) * size_of(Color) + len(step.after_at) * size_of(int)
}

// Drops the copies an adjust kept, ending it: the step moved to the other list, or went.
@(private)
adjust_free :: proc(h: ^Undo_History, step: ^Undo_Step) {
	if !step.adjusting do return
	delete(step.after_vecs, h.allocator)
	delete(step.after_masks, h.allocator)
	delete(step.after_colors, h.allocator)
	delete(step.after_at, h.allocator)
	step.after_vecs, step.after_masks, step.after_colors, step.after_at = nil, nil, nil, nil
	step.adjusting = false
}
