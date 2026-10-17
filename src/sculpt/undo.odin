package sculpt

import "base:runtime"
import "core:slice"

import "../geom"
import "../jobs"

// Undo history of one sculptor. A step is one stroke: before a dab first touches a
// node, the node's owned positions are copied into the step, so a step costs
// 12 bytes per vertex of the nodes the stroke reached and nothing for the rest of
// the mesh. Undo and redo swap those positions back in place, which turns the step
// into its own inverse.
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
	stamp:     u32,
}

Undo_Step :: struct {
	saved:  [dynamic]Saved_Node,
	leaves: [dynamic]u32, // BVH leaves whose triangles moved: bounds to refit, normals to update
}

// A node's owned positions from before the stroke moved them. Each node has its own
// allocation, so a growing stroke never copies what it already saved.
Saved_Node :: struct {
	node:      u32,
	positions: []Vec3,
}

// Default cap on undo memory per sculptor: about 40 large strokes on a 10M mesh.
UNDO_LIMIT_BYTES :: 512 << 20

@(private)
history_init :: proc(h: ^Undo_History, nodes: int, allocator := context.allocator) {
	h.allocator = allocator
	h.limit = UNDO_LIMIT_BYTES
	h.saved = make([]u32, nodes, allocator)
	h.changed = make([]u32, nodes, allocator)
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
		step_reset(h, &h.current)
		return false
	}
	clear_steps(h, &h.undone)
	append(&h.done, h.current)
	h.current = {}
	h.bytes += step_bytes(h.done[len(h.done) - 1])
	for h.bytes > h.limit && len(h.done) > 1 {
		h.bytes -= step_bytes(h.done[0])
		step_destroy(h, &h.done[0])
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
		for &p, i in live do p, sv.positions[i] = sv.positions[i], p
	}
	d := Dab{s = s}
	clear(&s.changed)
	append(&s.changed, ..step.leaves[:])
	verts: u32
	for leaf in s.changed do verts += s.nodes[s.node_of[leaf]].vert_count
	jobs.parallel_for(s.pool if verts >= PARALLEL_MIN_VERTS else nil, len(s.changed), &d, job_leaf_bounds)
	geom.bvh_refit_leaves(&s.bvh, m^, s.changed[:], recompute_leaves = false)
	for leaf in step.leaves do mark_shape_changed(s, s.node_of[leaf])
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
		append(&h.current.saved, Saved_Node{id, slice.clone(s.mesh.positions[n.vert_first:][:n.vert_count], h.allocator)})
	}
}

// Called by apply_dab once s.changed is known: lists the leaves to refit and update
// when the step is undone or redone.
@(private)
record_changed :: proc(s: ^Sculptor) {
	h := &s.history
	for leaf in s.changed {
		id := s.node_of[leaf]
		if h.changed[id] == h.stamp do continue
		h.changed[id] = h.stamp
		append(&h.current.leaves, leaf)
	}
}

@(private)
step_bytes :: proc(step: Undo_Step) -> int {
	bytes := len(step.saved) * size_of(Saved_Node) + len(step.leaves) * size_of(u32)
	for sv in step.saved do bytes += len(sv.positions) * size_of(Vec3)
	return bytes
}

@(private)
step_reset :: proc(h: ^Undo_History, step: ^Undo_Step) {
	for sv in step.saved do delete(sv.positions, h.allocator)
	clear(&step.saved)
	clear(&step.leaves)
}

@(private)
step_destroy :: proc(h: ^Undo_History, step: ^Undo_Step) {
	for sv in step.saved do delete(sv.positions, h.allocator)
	delete(step.saved)
	delete(step.leaves)
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
