package sculpt

import "base:runtime"
import "core:slice"

import "../jobs"

// Dial back (the History's step menu): a run of past steps, set after the fact to a share of
// what they did, from 0 (as if they were never made) through 1 (as they are) to DIAL_MAX
// (pushed further), while every later step stays. Adjust last stroke does this for the
// newest stroke alone; the dial does it for any run of done steps of positions.
//
// It reads the run's change from the undo data, copying no mesh: per node, B is what the
// oldest step of the run that saved the node holds (the node before the run) and A what the
// first newer step that saved it holds (the node after the run), or, where no newer step
// touched the node, the live positions, which `base` keeps as they were when the dial
// opened. A set writes `base + (k − 1)·(A − B)`, so later strokes over the area ride on the
// change as they would on a layer; where no newer step touched the node it is
// adjust_vec(B, base, k), exact at 0 and 1. Done hands `base` to a new undo step as its
// saved positions (they are what undo needs), so nothing is copied twice.
//
// While a dial is open its B and A are slices into steps' saved positions, which undo and
// redo swap and the memory limit frees: a stroke beginning or a step moving cancels it first,
// and the app holds the History still (history_busy).

// The most a dial pushes a run past what it did.
DIAL_MAX :: f32(1.5)

// Above this many vertices a set is too long for a frame (about 48 bytes of memory traffic a
// vertex, then normals and an upload): the app sets the dial when the slider is let go
// rather than as it is dragged.
DIAL_LIVE_VERTS :: 2_000_000

// Why a dial could not open.
Dial_Refusal :: enum u8 {
	None,
	Busy, // a stroke records, a dial is open already, or the GPU's positions are not back yet
	Dynamic, // dynamic topology: its steps change triangles
	Reach, // the run is not all done, or reaches past a change the steps do not hold (history.sealed)
	Kind, // the run holds a step the dial cannot share out (a sculpt layer's or the skin's)
	Nothing, // the run moved no positions
	Memory, // the step it would make holds more than half of the History's memory
}

// An open dial.
Dial :: struct {
	active: bool,
	nodes:  [dynamic]u32, // the nodes the run moved, in the order the run first saved them
	before: [dynamic][]Vec3, // per node: B
	after:  [dynamic][]Vec3, // per node: A, nil where no newer step saved the node (A is base)
	base:   [dynamic][]Vec3, // per node: the live positions when the dial opened, in `block`
	block:  []Vec3,
	k:      f32,
	verts:  int,
}

// Opens a dial on the done steps from `oldest_back` to `newest_back` steps back (1 is the
// newest step, as sculptor_recall_build counts), at 1. Returns how many vertices it moves,
// or why it could not open.
sculptor_dial_begin :: proc(s: ^Sculptor, oldest_back, newest_back: int) -> (verts: int, refusal: Dial_Refusal) {
	h := &s.history
	switch {
	case s.dial.active || h.recording:
		return 0, .Busy
	case s.dyn != nil:
		return 0, .Dynamic
	case newest_back < 1 || oldest_back < newest_back || oldest_back > sculptor_recall_reach(s):
		return 0, .Reach
	}
	first, last := len(h.done) - oldest_back, len(h.done) - newest_back
	for &step in h.done[first:last + 1] {
		if step.skin_op.active || step.skinned || step.layer_op.active || step.layer_set.active || step.layer_move.active || step.layer_stack.active do return 0, .Kind
		for sv in step.saved do if sv.is_delta || sv.full || sv.heights != nil do return 0, .Kind
	}
	if !sculptor_gpu_sync(s, normals = false) do return 0, .Busy
	// Per node: its place in the dial's lists, -1 while the run has not saved it.
	at := make([]i32, len(s.nodes), context.temp_allocator)
	slice.fill(at, -1)
	d := &s.dial
	for &step in h.done[first:last + 1] {
		for sv in step.saved {
			if !saved_positions(sv) || at[sv.node] >= 0 do continue
			at[sv.node] = i32(len(d.nodes))
			append(&d.nodes, sv.node)
			append(&d.before, sv.positions)
			append(&d.after, nil)
			verts += len(sv.positions)
		}
	}
	if len(d.nodes) == 0 {
		dial_free(s)
		return 0, .Nothing
	}
	if verts * size_of(Vec3) > h.limit / 2 {
		dial_free(s)
		return 0, .Memory
	}
	// The newer steps from the oldest: the first to save a node holds it as the run left it.
	for &step in h.done[last + 1:] {
		for sv in step.saved {
			if !saved_positions(sv) do continue
			if i := at[sv.node]; i >= 0 && d.after[i] == nil do d.after[i] = sv.positions
		}
	}
	// The live positions, in one block laid out as record_hit lays a large save, so Done can
	// hand it to the step as it is.
	raw, _ := runtime.mem_alloc_non_zeroed(verts * size_of(Vec3), align_of(Vec3), h.allocator)
	d.block = slice.reinterpret([]Vec3, raw)
	o := 0
	for id in d.nodes {
		n := s.nodes[id]
		append(&d.base, d.block[o:][:n.vert_count])
		o += int(n.vert_count)
	}
	Copy :: struct {
		s: ^Sculptor,
	}
	c := Copy{s}
	jobs.parallel_for(s.pool if verts >= PARALLEL_MIN_VERTS else nil, len(d.nodes), &c, proc(data: rawptr, i: int) {
		s := (cast(^Copy)data).s
		n := s.nodes[s.dial.nodes[i]]
		copy(s.dial.base[i], s.mesh.positions[n.vert_first:][:n.vert_count])
	})
	d.active, d.k, d.verts = true, 1, verts
	return verts, .None
}

// Sets an open dial to `k` (0 to DIAL_MAX) of what its run did. False when no dial is open.
sculptor_dial_set :: proc(s: ^Sculptor, k: f32) -> bool {
	d := &s.dial
	if !d.active do return false
	d.k = clamp(k, 0, DIAL_MAX)
	Set :: struct {
		s: ^Sculptor,
	}
	job := Set{s}
	jobs.parallel_for(s.pool if d.verts >= PARALLEL_MIN_VERTS else nil, len(d.nodes), &job, proc(data: rawptr, i: int) {
		s := (cast(^Set)data).s
		d := &s.dial
		n := s.nodes[d.nodes[i]]
		live := s.mesh.positions[n.vert_first:][:n.vert_count]
		b, base, a := d.before[i], d.base[i], d.after[i]
		if a == nil {
			for &p, v in live do p = adjust_vec(b[v], base[v], d.k)
		} else {
			for &p, v in live do p = base[v] + (d.k - 1) * (a[v] - b[v])
		}
	})
	sculptor_nodes_moved(s, d.nodes[:])
	return true
}

// Closes an open dial: away from 1, as a new undo step holding the positions from before it
// (which takes away anything that could be redone, as a stroke does); at 1, as nothing.
// Returns whether it made a step.
sculptor_dial_end :: proc(s: ^Sculptor) -> bool {
	d := &s.dial
	if !d.active do return false
	if d.k == 1 {
		dial_free(s)
		return false
	}
	d.active = false
	// The nodes sharing the dial's vertices, as the last set's sculptor_nodes_moved found
	// them, before the stroke's beginning reuses that list.
	neighbours := make([]u32, len(s.changed), context.temp_allocator)
	for leaf, i in s.changed do neighbours[i] = s.node_of[leaf]
	sculptor_stroke_begin(s)
	h := &s.history
	for id, i in d.nodes {
		h.saved[id] = h.stamp
		sv := Saved_Node{node = id, positions = d.base[i]}
		if i == 0 do sv.block = d.block
		else do sv.borrowed = true
		append(&h.current.saved, sv)
	}
	// The step owns the block now.
	d.block = nil
	// Undo refits and brings up to date the nodes whose triangles moved: the dial's, and the
	// nodes sharing their vertices, as sculptor_nodes_moved found them.
	for id in d.nodes do record_changed_node(s, id)
	for id in neighbours do record_changed_node(s, id)
	dial_free(s)
	return sculptor_stroke_end(s)
}

// Closes an open dial as if it never opened: the positions go back to how they were.
sculptor_dial_cancel :: proc(s: ^Sculptor) {
	d := &s.dial
	if !d.active do return
	for id, i in d.nodes {
		n := s.nodes[id]
		copy(s.mesh.positions[n.vert_first:][:n.vert_count], d.base[i])
	}
	sculptor_nodes_moved(s, d.nodes[:])
	dial_free(s)
}

// What an open dial is at, and how many vertices it moves; 0, 0 with none open.
sculptor_dial_state :: proc(s: ^Sculptor) -> (k: f32, verts: int) {
	if !s.dial.active do return 0, 0
	return s.dial.k, s.dial.verts
}

@(private)
dial_free :: proc(s: ^Sculptor) {
	d := &s.dial
	delete(d.block, s.history.allocator)
	delete(d.nodes)
	delete(d.before)
	delete(d.after)
	delete(d.base)
	d^ = {}
}
