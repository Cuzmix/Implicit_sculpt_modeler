package sculpt

import "base:runtime"
import "core:slice"

import "../geom"
import "../jobs"

// Undo history of one sculptor. A step is one stroke: before a dab first touches a
// node, the node's owned positions are copied into the step, so a step costs
// 12 bytes per vertex of the nodes the stroke reached and nothing for the rest of
// the mesh. Undo and redo swap those positions back in place, which turns the step
// into its own inverse. Mask strokes save the nodes' masks the same way, at 1 byte a
// vertex.
Undo_History :: struct {
	allocator: runtime.Allocator, // for the saved positions
	done:      [dynamic]Undo_Step,
	undone:    [dynamic]Undo_Step,
	current:   Undo_Step,
	recording: bool,
	bytes:     int, // held by done + undone
	limit:     int, // bytes; the oldest steps are dropped beyond it (the newest is always kept)
	// Per node id: the stamp of the step that last recorded it, so each node is saved
	// and listed once per step without clearing anything between steps.
	saved:     []u32,
	changed:   []u32,
	mask_saved:   []u32, // the same for masks
	mask_changed: []u32,
	color_saved:  []u32, // ...and for colours, which list their nodes in mask_changed too
	stamp:     u32,
	last_id:   u64, // the id the newest step was given
	// Steps up to this id are older than a move of the positions no step holds (another
	// level's edits carried here): a History brush target cannot be read back through
	// them (recall.odin).
	sealed:    u64,
}

Undo_Step :: struct {
	id:     u64, // from 1, in the order steps were made, kept through undo and redo
	saved:  [dynamic]Saved_Node,
	nodes:  [dynamic]u32, // nodes whose triangles moved: bounds to refit, normals to update
	painted: [dynamic]u32, // nodes whose mask changed: GPU data to update
	shown:  [dynamic]u32, // nodes whose triangles were hidden or shown (hide.odin)
	grouped: [dynamic]u32, // nodes whose triangles changed group (groups.odin)
	layer_op:  Layer_Op,  // a sculpt layer added or removed (sculpt_layers.odin)
	layer_set: Layer_Set, // a sculpt layer's strength or visibility changed
	layer_move: Layer_Move, // two sculpt layers swapped places
	layer_stack: Layer_Stack, // every sculpt layer taken out at once (Bake all)
	// Adjust last stroke (adjust.odin): set once the newest step is adjusted, with what
	// the stroke left of each saved node, at after_at[i] in the block of its kind.
	adjusting:    bool,
	after_vecs:   []Vec3, // positions, or a recording layer's displacement
	after_masks:  []u8,
	after_colors: []Color,
	after_at:     []int,
}

// A node's owned positions, or its owned vertices' masks, from before the stroke
// changed them. Each node has its own allocation, so a growing stroke never copies
// what it already saved. With dynamic topology, a stroke saves whole nodes (`full`):
// their vertices, triangles and masks.
Saved_Node :: struct {
	node:       u32,
	positions:  []Vec3, // nil when this saves the mask
	// A large save takes one allocation for many nodes' positions: the first of them
	// holds it here and frees it, the others are `borrowed` and free nothing.
	block:      []Vec3,
	borrowed:   bool,
	masks:      []u8,
	hidden:     []bool, // the node's triangles' hidden flags, for a hiding step
	colors:     []Color, // the node's owned vertices' colours, for a painting step
	groups:     []u16,   // the node's triangles' groups, for a grouping step
	// With `is_delta`: the node's displacement in layer `delta_layer` before a recording
	// stroke added to it (nil when it had none).
	delta:       []Vec3,
	delta_layer: i32,
	is_delta:    bool,
	full:       bool,
	indices:    []u32,
	vert_count: u32,
	tri_count:  u32,
}

// Default cap on undo memory per sculptor: about 40 large strokes on a 10M mesh.
UNDO_LIMIT_BYTES :: 512 << 20

@(private)
history_init :: proc(h: ^Undo_History, nodes: int, allocator := context.allocator) {
	h.allocator = allocator
	h.limit = UNDO_LIMIT_BYTES
	h.saved = make([]u32, nodes, allocator)
	h.changed = make([]u32, nodes, allocator)
	h.mask_saved = make([]u32, nodes, allocator)
	h.mask_changed = make([]u32, nodes, allocator)
	h.color_saved = make([]u32, nodes, allocator)
}

@(private)
history_destroy :: proc(h: ^Undo_History) {
	clear_steps(h, &h.done)
	clear_steps(h, &h.undone)
	step_destroy(h, &h.current)
	delete(h.done)
	delete(h.undone)
	delete(h.saved)
	delete(h.changed)
	delete(h.mask_saved)
	delete(h.mask_changed)
	delete(h.color_saved)
	h^ = {}
}

// Starts recording a stroke. Dabs applied until sculptor_stroke_end form one step.
sculptor_stroke_begin :: proc(s: ^Sculptor) {
	// A new stroke locks its own plane (filters.odin).
	s.locked = {}
	// A new stroke starts a new Layer: earlier heights stop counting.
	s.layer_stroke += 1
	if s.layer_stroke == 0 {
		slice.zero(s.layer)
		s.layer_stroke = 1
	}
	h := &s.history
	if h.recording do return
	h.recording = true
	h.stamp += 1
	if h.stamp == 0 { 	// wrapped: stamps from long ago would look current
		slice.zero(h.saved)
		slice.zero(h.changed)
		slice.zero(h.mask_saved)
		slice.zero(h.mask_changed)
		slice.zero(h.color_saved)
		h.stamp = 1
	}
}

// Ends the stroke. Returns true when it changed the mesh and became an undo step;
// that also discards everything that could have been redone.
sculptor_stroke_end :: proc(s: ^Sculptor) -> bool {
	h := &s.history
	if !h.recording do return false
	h.recording = false
	if len(h.current.nodes) == 0 && len(h.current.painted) == 0 && len(h.current.shown) == 0 && len(h.current.grouped) == 0 && !h.current.layer_op.active && !h.current.layer_set.active && !h.current.layer_move.active && !h.current.layer_stack.active {
		step_reset(h, &h.current)
		return false
	}
	layer_take_stroke(s)
	clear_steps(h, &h.undone)
	// The step that was newest can no longer be adjusted, so the copy an adjust kept goes.
	if len(h.done) > 0 {
		top := &h.done[len(h.done) - 1]
		h.bytes -= adjust_bytes(top^)
		adjust_free(h, top)
	}
	h.last_id += 1
	h.current.id = h.last_id
	append(&h.done, h.current)
	h.current = {}
	h.bytes += step_bytes(h.done[len(h.done) - 1])
	history_trim(h)
	return true
}

// Marks every step so far as older than a move of the positions that no step holds: the
// levels carrying another level's edits here.
@(private)
history_seal :: proc(h: ^Undo_History) {h.sealed = h.last_id}

// Drops the oldest steps while the history holds more than its limit; the newest always
// stays.
@(private)
history_trim :: proc(h: ^Undo_History) {
	for h.bytes > h.limit && len(h.done) > 1 {
		h.bytes -= step_bytes(h.done[0])
		step_destroy(h, &h.done[0])
		ordered_remove(&h.done, 0)
	}
}

sculptor_can_undo :: proc(s: ^Sculptor) -> bool {return len(s.history.done) > 0}
sculptor_can_redo :: proc(s: ^Sculptor) -> bool {return len(s.history.undone) > 0}

// Puts back everything the stroke being recorded has changed so far and keeps
// recording it, for strokes that redo their one dab as the pointer moves (Drag
// rectangle): the saved copies stay, so the stroke's undo step is still whole. Not
// with dynamic topology, whose strokes change the triangles (false, nothing done).
sculptor_stroke_restore :: proc(s: ^Sculptor) -> bool {
	h := &s.history
	if !h.recording || s.dyn != nil do return false
	m := s.mesh
	for sv in h.current.saved {
		n := s.nodes[sv.node]
		if sv.masks != nil {
			copy(s.mask[n.vert_first:][:n.vert_count], sv.masks)
		} else if sv.colors != nil {
			copy(s.color[n.vert_first:][:n.vert_count], sv.colors)
		} else {
			copy(m.positions[n.vert_first:][:n.vert_count], sv.positions)
		}
	}
	for id in h.current.painted do mark_stale(s, id, .Paint)
	d := Dab{s = s}
	clear(&s.changed)
	verts: u32
	for id in h.current.nodes {
		append(&s.changed, s.nodes[id].leaf)
		verts += s.nodes[id].vert_count
	}
	jobs.parallel_for(s.pool if verts >= PARALLEL_MIN_VERTS else nil, len(s.changed), &d, job_leaf_bounds)
	geom.bvh_refit_leaves(&s.bvh, m^, s.changed[:], recompute_leaves = false)
	for id in h.current.nodes do mark_shape_changed(s, id)
	// A Layer dab starts from nothing again, and the plane is locked again by the first
	// dab laid after it.
	s.locked = {}
	s.layer_stroke += 1
	if s.layer_stroke == 0 {
		slice.zero(s.layer)
		s.layer_stroke = 1
	}
	return true
}

// Puts back everything the stroke being recorded changed and ends it without an undo
// step, for a gesture cancelled part way (a pose Escape or a second finger stopped). Positions,
// masks and colours only; returns false, doing nothing, when the stroke saved whole
// nodes (dynamic topology) or nothing is being recorded, and the caller ends it as usual.
sculptor_stroke_discard :: proc(s: ^Sculptor) -> bool {
	h := &s.history
	if !h.recording do return false
	for sv in h.current.saved do if sv.full || sv.hidden != nil || sv.groups != nil || sv.is_delta do return false
	m := s.mesh
	for sv in h.current.saved {
		n := s.nodes[sv.node]
		if sv.masks != nil {
			copy(s.mask[n.vert_first:][:n.vert_count], sv.masks)
		} else if sv.colors != nil {
			copy(s.color[n.vert_first:][:n.vert_count], sv.colors)
		} else {
			copy(m.positions[n.vert_first:][:n.vert_count], sv.positions)
		}
	}
	for id in h.current.painted do mark_stale(s, id, .Paint)
	sculptor_nodes_moved(s, h.current.nodes[:])
	step_reset(h, &h.current)
	h.recording = false
	return true
}

// Reverts the newest stroke. Positions and BVH bounds are current when it returns;
// normals and GPU data follow at the next sculptor_flush, as after a dab.
sculptor_undo :: proc(s: ^Sculptor) -> bool {
	return step_move(s, &s.history.done, &s.history.undone)
}

// Re-applies the newest undone stroke.
sculptor_redo :: proc(s: ^Sculptor) -> bool {
	return step_move(s, &s.history.undone, &s.history.done)
}

// Bytes the history holds, for the stats panel.
sculptor_undo_bytes :: proc(s: ^Sculptor) -> int {return s.history.bytes}

@(private)
step_move :: proc(s: ^Sculptor, from, to: ^[dynamic]Undo_Step) -> bool {
	_ = sculptor_stroke_end(s)
	if len(from) == 0 do return false
	step := pop(from)
	m := s.mesh
	// Moving a step either way ends adjusting it.
	s.history.bytes -= adjust_bytes(step)
	adjust_free(&s.history, &step)
	// Layer displacement and removed layers trade places with the live ones, which
	// changes what the step holds.
	held := step_bytes(step)
	defer s.history.bytes += step_bytes(step) - held
	if s.dyn != nil do dyn_step_swap(s, &step)
	layer_step_swap(s, &step)
	for &sv in step.saved {
		n := s.nodes[sv.node]
		if sv.full do continue
		if sv.is_delta {
			live := &s.layers.list[sv.delta_layer].delta[sv.node]
			live^, sv.delta = sv.delta, live^
			continue
		}
		if sv.hidden != nil {
			live := s.hide.tris[n.tri_first:][:n.tri_count]
			for &x, i in live do x, sv.hidden[i] = sv.hidden[i], x
			continue
		}
		if sv.masks != nil {
			live := s.mask[n.vert_first:][:n.vert_count]
			for &k, i in live do k, sv.masks[i] = sv.masks[i], k
			continue
		}
		if sv.colors != nil {
			live := s.color[n.vert_first:][:n.vert_count]
			for &c, i in live do c, sv.colors[i] = sv.colors[i], c
			s.color_edited = true
			continue
		}
		if sv.groups != nil {
			live := s.groups.tris[n.tri_first:][:n.tri_count]
			for &g, i in live do g, sv.groups[i] = sv.groups[i], g
			continue
		}
		live := m.positions[n.vert_first:][:n.vert_count]
		for &p, i in live do p, sv.positions[i] = sv.positions[i], p
	}
	for id in step.painted do mark_stale(s, id, .Paint)
	if len(step.shown) > 0 do hide_refresh(s, step.shown[:])
	if len(step.grouped) > 0 {
		groups_refresh(s)
		s.groups.edited = true
	}
	if s.dyn == nil {
		d := Dab{s = s}
		clear(&s.changed)
		verts: u32
		for id in step.nodes {
			append(&s.changed, s.nodes[id].leaf)
			verts += s.nodes[id].vert_count
		}
		jobs.parallel_for(s.pool if verts >= PARALLEL_MIN_VERTS else nil, len(s.changed), &d, job_leaf_bounds)
		geom.bvh_refit_leaves(&s.bvh, m^, s.changed[:], recompute_leaves = false)
		for id in step.nodes do mark_shape_changed(s, id)
	}
	append(to, step)
	return true
}

// Called by apply_dab before the dab changes anything: saves the owned positions of
// every hit node this stroke has not saved yet, or with `masks`, their masks.
@(private)
record_hit :: proc(s: ^Sculptor, masks: bool) {
	h := &s.history
	first := len(h.current.saved)
	verts := 0
	for leaf in s.hit {
		if masks {
			record_mask(s, s.node_of[leaf])
			continue
		}
		id := s.node_of[leaf]
		if s.dyn != nil {
			record_full(s, id)
			continue
		}
		if h.saved[id] == h.stamp do continue
		h.saved[id] = h.stamp
		append(&h.current.saved, Saved_Node{node = id})
		verts += int(s.nodes[id].vert_count)
	}
	if masks || s.dyn != nil || verts == 0 do return
	// The copies are filled below, after allocating: a hit as large as a whole-mesh clip
	// saves millions of positions, which one allocation and a parallel copy make quick
	// where an allocation and a copy per node do not.
	fresh := h.current.saved[first:]
	if verts >= RECORD_PARALLEL_VERTS {
		// Unzeroed: the copy below writes all of it, in parallel, page faults and all.
		raw, _ := runtime.mem_alloc_non_zeroed(verts * size_of(Vec3), align_of(Vec3), h.allocator)
		block := slice.reinterpret([]Vec3, raw)
		at := 0
		for &sv, i in fresh {
			count := int(s.nodes[sv.node].vert_count)
			sv.positions = block[at:][:count]
			at += count
			if i == 0 do sv.block = block
			else do sv.borrowed = true
		}
	} else {
		for &sv in fresh do sv.positions = make([]Vec3, s.nodes[sv.node].vert_count, h.allocator)
	}
	Copy :: struct {
		s:     ^Sculptor,
		saved: []Saved_Node,
	}
	c := Copy{s, fresh}
	jobs.parallel_for(s.pool if verts >= RECORD_PARALLEL_VERTS else nil, len(c.saved), &c, proc(data: rawptr, i: int) {
		c := cast(^Copy)data
		sv := c.saved[i]
		copy(sv.positions, c.s.mesh.positions[c.s.nodes[sv.node].vert_first:][:len(sv.positions)])
	})
}

// Saved positions from one dab past this many share an allocation and copy in parallel.
@(private)
RECORD_PARALLEL_VERTS :: 1 << 16

// Saves a node's masks before the stroke first changes them, and lists the node as
// painted. The sculptor must have a mask.
@(private)
record_mask :: proc(s: ^Sculptor, id: u32) {
	h := &s.history
	if h.mask_saved[id] == h.stamp do return
	h.mask_saved[id] = h.stamp
	n := s.nodes[id]
	append(&h.current.saved, Saved_Node{node = id, masks = slice.clone(s.mask[n.vert_first:][:n.vert_count], h.allocator)})
}

// Lists a node whose mask the stroke changed, for undo to update its GPU data.
@(private)
record_painted :: proc(s: ^Sculptor, id: u32) {
	h := &s.history
	if h.mask_changed[id] == h.stamp do return
	h.mask_changed[id] = h.stamp
	append(&h.current.painted, id)
}

// Called by apply_dab once s.changed is known: lists the leaves to refit and update
// when the step is undone or redone.
@(private)
record_changed :: proc(s: ^Sculptor) {
	for leaf in s.changed do record_changed_node(s, s.node_of[leaf])
}

@(private)
record_changed_node :: proc(s: ^Sculptor, id: u32) {
	h := &s.history
	if h.changed[id] == h.stamp do return
	h.changed[id] = h.stamp
	append(&h.current.nodes, id)
}

@(private)
step_bytes :: proc(step: Undo_Step) -> int {
	bytes := len(step.saved) * size_of(Saved_Node) + (len(step.nodes) + len(step.painted) + len(step.shown) + len(step.grouped)) * size_of(u32)
	for sv in step.saved {
		bytes += len(sv.positions) * size_of(Vec3) + len(sv.masks) + len(sv.hidden) + len(sv.indices) * size_of(u32)
		bytes += len(sv.colors) * size_of(Color) + len(sv.groups) * size_of(u16) + len(sv.delta) * size_of(Vec3)
	}
	if step.layer_op.held do bytes += layer_bytes(step.layer_op.layer)
	for l in step.layer_stack.list do bytes += layer_bytes(l)
	return bytes + adjust_bytes(step)
}

@(private)
step_reset :: proc(h: ^Undo_History, step: ^Undo_Step) {
	for sv in step.saved {
		if sv.block != nil {
			delete(sv.block, h.allocator)
		} else if !sv.borrowed {
			delete(sv.positions, h.allocator)
		}
		delete(sv.masks, h.allocator)
		delete(sv.hidden, h.allocator)
		delete(sv.colors, h.allocator)
		delete(sv.groups, h.allocator)
		delete(sv.indices, h.allocator)
		delete(sv.delta, h.allocator)
	}
	if step.layer_op.held do layer_destroy(&step.layer_op.layer, h.allocator)
	for &l in step.layer_stack.list do layer_destroy(&l, h.allocator)
	delete(step.layer_stack.list)
	adjust_free(h, step)
	clear(&step.saved)
	clear(&step.nodes)
	clear(&step.painted)
	clear(&step.shown)
	clear(&step.grouped)
	step.layer_op, step.layer_set, step.layer_move, step.layer_stack = {}, {}, {}, {}
}

@(private)
step_destroy :: proc(h: ^Undo_History, step: ^Undo_Step) {
	for sv in step.saved {
		if sv.block != nil {
			delete(sv.block, h.allocator)
		} else if !sv.borrowed {
			delete(sv.positions, h.allocator)
		}
		delete(sv.masks, h.allocator)
		delete(sv.hidden, h.allocator)
		delete(sv.colors, h.allocator)
		delete(sv.groups, h.allocator)
		delete(sv.indices, h.allocator)
		delete(sv.delta, h.allocator)
	}
	if step.layer_op.held do layer_destroy(&step.layer_op.layer, h.allocator)
	for &l in step.layer_stack.list do layer_destroy(&l, h.allocator)
	delete(step.layer_stack.list)
	adjust_free(h, step)
	delete(step.saved)
	delete(step.nodes)
	delete(step.painted)
	delete(step.shown)
	delete(step.grouped)
	step^ = {}
}

@(private)
clear_steps :: proc(h: ^Undo_History, steps: ^[dynamic]Undo_Step) {
	for &step in steps {
		h.bytes -= step_bytes(step)
		step_destroy(h, &step)
	}
	clear(steps)
}

// Discards the strokes that could be redone.
sculptor_clear_redo :: proc(s: ^Sculptor) {
	clear_steps(&s.history, &s.history.undone)
}

// Discards every stroke, done and undone.
sculptor_clear_history :: proc(s: ^Sculptor) {
	_ = sculptor_stroke_end(s)
	clear_steps(&s.history, &s.history.done)
	clear_steps(&s.history, &s.history.undone)
}
