package sculpt

import "core:slice"

import "../jobs"

// Layer masks (panels round, P2): a mask on a sculpt layer says, vertex by vertex, how
// much of the layer each hides, as Photoshop's layer masks and Blender's shape keys under
// a vertex group do, so an expression sculpted on a layer can be kept to the mouth. The
// surface is the work outside the layers plus each layer's displacement times its
// strength times what its mask leaves shown, and the positions hold that sum as before.
//
// A layer's mask is painted with every mask tool there is: picking it
// (sculptor_layer_mask_pick) makes it the sculptor's mask for the time being, the sculpt
// mask waiting aside, so the mask brushes, shapes, commands and their undo work on it
// unchanged and the view shades it. While it is picked, each change of it moves the
// vertices the layer displaced by what it hides or shows more (in job_mask and
// mask_commit), saving their positions in the same undo step, so undo takes back mask
// and surface together. A step remembers which mask it painted (Undo_Step.mask_layer),
// so it finds that mask wherever it waits when it is undone. A mask all zero is no mask.
//
// A stroke that records into a layer under a mask keeps the whole movement in the layer
// and lets the part the mask hides stay in the surface (the positions are the truth and
// the work outside the layers is what is left), so a stroke always shows where it is
// made, and painting the mask away later shows all of it.

// How much of a layer's displacement shows at a vertex whose mask is `k`.
mask_shows :: #force_inline proc(k: u8) -> f32 {return 1 - f32(k) * (1.0 / 255)}

// Layer `index`'s mask wherever it is: the sculptor's while it is picked; nil for none.
layer_mask_of :: proc(s: ^Sculptor, index: int) -> []u8 {
	if index < 0 || index >= len(s.layers.list) do return nil
	if s.layers.picked == index + 1 do return s.mask
	return s.layers.list[index].mask
}

// The layer whose mask is picked for painting, or -1.
sculptor_layer_mask_picked :: proc(s: ^Sculptor) -> int {return s.layers.picked - 1}

// Whether layer `index` has a mask that hides anything.
sculptor_layer_has_mask :: proc(s: ^Sculptor, index: int) -> bool {
	m := layer_mask_of(s, index)
	return m != nil && !mask_all_zero(m)
}

// The sculpt mask, whichever mask is picked: what files store as the mask.
sculptor_sculpt_mask :: proc(s: ^Sculptor) -> []u8 {
	return s.layers.held if s.layers.picked != 0 else s.mask
}

@(private = "file")
mask_all_zero :: proc(m: []u8) -> bool {
	return slice.all_of(m, 0)
}

// Picks layer `index`'s mask for the mask tools to paint (-1 puts the sculpt mask back).
// Ends any stroke first; not an undo step, as choosing a brush is not. A mask left all
// zero is dropped. False when there is no such layer or dynamic topology is on.
sculptor_layer_mask_pick :: proc(s: ^Sculptor, index: int) -> bool {
	_ = sculptor_stroke_end(s)
	ls := &s.layers
	if index >= 0 && index == ls.picked - 1 do return true
	if ls.picked != 0 {
		if ls.picked <= len(ls.list) {
			l := &ls.list[ls.picked - 1]
			l.mask = s.mask
			if l.mask != nil && mask_all_zero(l.mask) {
				delete(l.mask, s.history.allocator)
				l.mask = nil
			}
		} else {
			delete(s.mask, s.history.allocator)
		}
		s.mask, ls.held, ls.picked = ls.held, nil, 0
		mask_shading_changed(s)
	}
	if index < 0 do return true
	if index >= len(ls.list) || s.dyn != nil do return false
	l := &ls.list[index]
	ls.held, s.mask, l.mask, ls.picked = s.mask, l.mask, nil, index + 1
	mask_shading_changed(s)
	return true
}

// Every node's mask shading goes to the GPU again, as the mask shown changed.
@(private = "file")
mask_shading_changed :: proc(s: ^Sculptor) {
	for _, id in s.nodes do mark_stale(s, u32(id), .Paint)
}

// The mask an undo step painted, for undo and redo to swap its saved values with:
// `layer` is the step's mask_layer (0 the sculpt mask, else a layer's index + 1). A mask
// that went (all zero, dropped) comes back as zeros.
@(private)
step_mask :: proc(s: ^Sculptor, layer: int) -> []u8 {
	ls := &s.layers
	n := len(s.mesh.positions)
	if layer == ls.picked {
		mask_ensure(s)
		return s.mask
	}
	if layer == 0 {
		if ls.held == nil do ls.held = make([]u8, n, s.history.allocator)
		return ls.held
	}
	if layer > len(ls.list) do return nil
	l := &ls.list[layer - 1]
	if l.mask == nil do l.mask = make([]u8, n, s.history.allocator)
	return l.mask
}

// What a change of the picked layer mask moves: the layer's displacement and its weight
// over 255, so a vertex whose mask goes from a to b moves by (a - b) times that.
@(private)
Mask_Move :: struct {
	delta: [][]Vec3,
	k:     f32,
}

// The picked layer's displacement and weight, or a zero Mask_Move when no layer mask is
// picked or the layer shows nothing.
@(private)
mask_move_of :: proc(s: ^Sculptor) -> Mask_Move {
	if s.layers.picked == 0 || s.layers.picked > len(s.layers.list) do return {}
	l := s.layers.list[s.layers.picked - 1]
	w := layer_weight(l)
	if w == 0 do return {}
	return {l.delta, w * (1.0 / 255)}
}

// Moves node `id`'s vertices for its mask going from `before` to `after` (both its own
// slices), by the picked layer's displacement; true when it moved any.
@(private)
mask_move_node :: proc(s: ^Sculptor, mm: Mask_Move, id: u32, before, after: []u8) -> bool {
	if mm.delta == nil || mm.delta[id] == nil do return false
	d := mm.delta[id]
	n := s.nodes[id]
	live := s.mesh.positions[n.vert_first:][:n.vert_count]
	moved := false
	for &p, v in live {
		if before[v] == after[v] do continue
		p += (f32(before[v]) - f32(after[v])) * mm.k * d[v]
		moved = true
	}
	return moved
}

// Saves the positions of nodes `ids` in the stroke being recorded, before a change of the
// picked layer mask moves them.
@(private)
mask_move_record :: proc(s: ^Sculptor, ids: []u32) {
	s.history.current.mask_moved = true
	clear(&s.hit)
	for id in ids do append(&s.hit, s.nodes[id].leaf)
	record_hit(s, false)
}

// After a change of the picked layer mask moved nodes `ids`: their bounds, normals and
// GPU data follow, and the step lists them, as after a dab.
@(private)
mask_move_done :: proc(s: ^Sculptor, ids: []u32) {
	if len(ids) == 0 do return
	sculptor_nodes_moved(s, ids)
	if s.history.recording do for leaf in s.changed do record_changed_node(s, s.node_of[leaf])
}

// Moves the nodes `ids` of a mask command for the picked layer mask going from the
// sculptor's mask to `after`, saving their positions first; for mask_commit, before it
// writes `after`.
@(private)
mask_commit_move :: proc(s: ^Sculptor, ids: []u32, after: []u8) {
	mm := mask_move_of(s)
	if mm.delta == nil do return
	reach := make([dynamic]u32, 0, len(ids), context.temp_allocator)
	for id in ids do if mm.delta[id] != nil do append(&reach, id)
	if len(reach) == 0 do return
	mask_move_record(s, reach[:])
	Job :: struct {
		s:     ^Sculptor,
		mm:    Mask_Move,
		ids:   []u32,
		after: []u8,
	}
	job := Job{s, mm, reach[:], after}
	jobs.parallel_for(s.pool, len(reach), &job, proc(data: rawptr, i: int) {
		job := cast(^Job)data
		n := job.s.nodes[job.ids[i]]
		_ = mask_move_node(job.s, job.mm, job.ids[i], job.s.mask[n.vert_first:][:n.vert_count], job.after[n.vert_first:][:n.vert_count])
	})
	mask_move_done(s, reach[:])
}

// Copies the sculpt mask into the picked layer's mask as one undo step (From the sculpt
// mask), moving the surface to match. False when no layer mask is picked or nothing changed.
sculptor_layer_mask_from_sculpt :: proc(s: ^Sculptor) -> bool {
	_ = sculptor_stroke_end(s)
	if s.layers.picked == 0 do return false
	from := s.layers.held
	after := make([]u8, len(s.mesh.positions), context.temp_allocator)
	if from != nil do copy(after, from)
	mask_ensure(s)
	changes := make([]bool, len(s.nodes), context.temp_allocator)
	slice.fill(changes, true)
	return mask_commit_values(s, after, changes)
}

// Takes every layer's mask into its displacement (each displacement times what its mask
// shows) and drops the masks, the surface staying as it is: for carrying layers onto
// another surface, which carries displacements alone. Not an undo step: the carries are
// parts of rebuilds that are.
@(private)
layer_masks_bake :: proc(s: ^Sculptor) {
	if s.layers.picked != 0 do _ = sculptor_layer_mask_pick(s, -1)
	for &l in s.layers.list {
		if l.mask == nil do continue
		for d, id in l.delta {
			if d == nil do continue
			first := int(s.nodes[id].vert_first)
			for &x, v in d do x *= mask_shows(l.mask[first + v])
		}
		delete(l.mask, s.history.allocator)
		l.mask = nil
	}
}
