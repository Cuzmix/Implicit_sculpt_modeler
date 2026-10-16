package sculpt

import "core:slice"

import "../geom"
import "../jobs"

// Undo history of one sculptor. A step is one stroke: before a dab first touches a
// node, the node's owned positions are copied into the step, so a step costs
// 12 bytes per vertex of the nodes the stroke reached and nothing for the rest of
// the mesh. Undo and redo swap those positions back in place, which turns the step
// into its own inverse.
Undo_History :: struct {
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
	dirty:     []u32,
	stamp:     u32,
}

Undo_Step :: struct {
	saved:     [dynamic]Saved_Node,
	positions: [dynamic]Vec3, // owned positions of the saved nodes, back to back
	leaves:    [dynamic]u32,  // BVH leaves whose triangles moved: bounds to refit
	nodes:     [dynamic]u32,  // nodes whose normals and GPU data change
}

Saved_Node :: struct {
	node:   u32,
	offset: u32, // into Undo_Step.positions
}

// Default cap on undo memory per sculptor: about 40 large strokes on a 10M mesh.
UNDO_LIMIT_BYTES :: 512 << 20

@(private)
history_init :: proc(h: ^Undo_History, nodes: int, allocator := context.allocator) {
	h.limit = UNDO_LIMIT_BYTES
	h.saved = make([]u32, nodes, allocator)
	h.changed = make([]u32, nodes, allocator)
	h.dirty = make([]u32, nodes, allocator)
}

@(private)
history_destroy :: proc(h: ^Undo_History) {
	clear_steps(h, &h.done)
	clear_steps(h, &h.undone)
	step_destroy(&h.current)
	delete(h.done)
	delete(h.undone)
	delete(h.saved)
	delete(h.changed)
	delete(h.dirty)
	h^ = {}
}

// Starts recording a stroke. Dabs applied until sculptor_stroke_end form one step.
sculptor_stroke_begin :: proc(s: ^Sculptor) {
	h := &s.history
	if h.recording do return
	h.recording = true
	h.stamp += 1
	if h.stamp == 0 { 	// wrapped: stamps from long ago would look current
		slice.zero(h.saved)
		slice.zero(h.changed)
		slice.zero(h.dirty)
		h.stamp = 1
	}
}

// Ends the stroke. Returns true when it changed the mesh and became an undo step;
// that also discards everything that could have been redone.
sculptor_stroke_end :: proc(s: ^Sculptor) -> bool {
	h := &s.history
	if !h.recording do return false
	h.recording = false
	if len(h.current.leaves) == 0 {
		step_reset(&h.current)
		return false
	}
	clear_steps(h, &h.undone)
	append(&h.done, h.current)
	h.current = {}
	h.bytes += step_bytes(h.done[len(h.done) - 1])
	for h.bytes > h.limit && len(h.done) > 1 {
		h.bytes -= step_bytes(h.done[0])
		step_destroy(&h.done[0])
		ordered_remove(&h.done, 0)
	}
	return true
}

sculptor_can_undo :: proc(s: ^Sculptor) -> bool {return len(s.history.done) > 0}
sculptor_can_redo :: proc(s: ^Sculptor) -> bool {return len(s.history.undone) > 0}

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
	for sv in step.saved {
		n := s.nodes[sv.node]
		live := m.positions[n.vert_first:][:n.vert_count]
		kept := step.positions[sv.offset:][:n.vert_count]
		for &p, i in live do p, kept[i] = kept[i], p
	}
	d := Dab{s = s}
	clear(&s.changed)
	append(&s.changed, ..step.leaves[:])
	verts: u32
	for leaf in s.changed do verts += s.nodes[s.node_of[leaf]].vert_count
	jobs.parallel_for(s.pool if verts >= PARALLEL_MIN_VERTS else nil, len(s.changed), &d, job_leaf_bounds)
	geom.bvh_refit_leaves(&s.bvh, m^, s.changed[:], recompute_leaves = false)
	for id in step.nodes do mark_dirty(s, id)
	append(to, step)
	return true
}

// Called by apply_dab before the dab moves anything: saves the owned positions of
// every hit node this stroke has not saved yet.
@(private)
record_hit :: proc(s: ^Sculptor) {
	h := &s.history
	for leaf in s.hit {
		id := s.node_of[leaf]
		if h.saved[id] == h.stamp do continue
		h.saved[id] = h.stamp
		n := s.nodes[id]
		append(&h.current.saved, Saved_Node{id, u32(len(h.current.positions))})
		append(&h.current.positions, ..s.mesh.positions[n.vert_first:][:n.vert_count])
	}
}

// Called by apply_dab once s.changed is known: lists the leaves to refit and the
// nodes to mark dirty when the step is undone or redone.
@(private)
record_changed :: proc(s: ^Sculptor) {
	h := &s.history
	for leaf in s.changed {
		id := s.node_of[leaf]
		if h.changed[id] != h.stamp {
			h.changed[id] = h.stamp
			append(&h.current.leaves, leaf)
		}
		n := s.nodes[id]
		record_dirty(h, id)
		for owner in s.owners[n.owner_first:][:n.owner_count] do record_dirty(h, owner)
	}
}

@(private)
record_dirty :: #force_inline proc(h: ^Undo_History, id: u32) {
	if h.dirty[id] == h.stamp do return
	h.dirty[id] = h.stamp
	append(&h.current.nodes, id)
}

@(private)
step_bytes :: proc(step: Undo_Step) -> int {
	return len(step.positions) * size_of(Vec3) + len(step.saved) * size_of(Saved_Node) +
		(len(step.leaves) + len(step.nodes)) * size_of(u32)
}

@(private)
step_reset :: proc(step: ^Undo_Step) {
	clear(&step.saved)
	clear(&step.positions)
	clear(&step.leaves)
	clear(&step.nodes)
}

@(private)
step_destroy :: proc(step: ^Undo_Step) {
	delete(step.saved)
	delete(step.positions)
	delete(step.leaves)
	delete(step.nodes)
	step^ = {}
}

@(private)
clear_steps :: proc(h: ^Undo_History, steps: ^[dynamic]Undo_Step) {
	for &step in steps {
		h.bytes -= step_bytes(step)
		step_destroy(&step)
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
