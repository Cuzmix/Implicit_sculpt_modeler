package sculpt

import "base:runtime"
import "core:slice"

import "../geom"
import "../jobs"

// Sculpt layers, as in ZBrush: while a layer records, every stroke's movement is kept
// in the layer as well as made, so the layer's slider can later dial that work up, down,
// past full or into reverse without touching anything sculpted outside it. A layer is a
// displacement per vertex, scaled by its strength (0 while it is hidden), and the shown
// surface is the work outside the layers plus each layer's displacement times its
// strength; the positions always hold that sum, so drawing and brushes need nothing of
// the layers and a slider change moves only the vertices its layer displaced, by the
// strength's change. Displacement is kept per node and only for the nodes the layer
// moved. Layers belong to one sculptor (one subdivision level); edits on other levels
// reach this one as they always do, under the layers. Adding, deleting, baking and
// slider changes are undo steps, and a recording stroke's undo step takes the layer's
// displacement back with the positions. Not under dynamic topology, whose edits add
// and remove vertices (sculptor_dyn_enable bakes the layers). A layer may have a mask
// (layer_masks.odin) saying how much of it each vertex hides: the shown surface then
// takes each displacement times its strength times what the mask leaves.

// How many layers one sculptor keeps.
MAX_SCULPT_LAYERS :: 32

Sculpt_Layer :: struct {
	name:     [32]u8, // zero-terminated
	strength: f32,
	visible:  bool,
	// Per node id: the displacement of each owned vertex at strength 1, nil where the
	// layer moved nothing.
	delta:    [][]Vec3,
	// Per vertex, how much of the layer it hides, 0 (all shown) to 255 (none); nil for
	// no mask. While the layer's mask is picked for painting it is the sculptor's mask
	// instead and this is nil (layer_mask_of).
	mask:     []u8,
}

Sculpt_Layers :: struct {
	list:      [dynamic]Sculpt_Layer,
	recording: int, // the recording layer's index + 1, 0 for none (so a zeroed stack records nothing)
	named:     int, // layers named so far, for the next "Layer N"
	// The layer whose mask the mask brushes and commands paint (index + 1, 0 for none):
	// its mask is the sculptor's mask meanwhile, and the sculpt mask waits in `held`.
	picked:    int,
	held:      []u8,
}

// A layer added or removed by an undo step; undoing or redoing it removes or puts back
// the layer, which the step holds (`held`) while it is out of the list.
@(private)
Layer_Op :: struct {
	active: bool,
	index:  int,
	held:   bool,
	layer:  Sculpt_Layer,
}

// The strength and visibility a layer had before an undo step changed them, and with
// `masked` its mask (Merge down bakes it); undoing or redoing swaps them with the live ones.
@(private)
Layer_Set :: struct {
	active:   bool,
	index:    int,
	strength: f32,
	visible:  bool,
	masked:   bool,
	mask:     []u8,
}

// Two layers swapped by an undo step (a move up or down); undoing or redoing swaps them
// back, so it is its own inverse.
@(private)
Layer_Move :: struct {
	active: bool,
	a, b:   int,
}

// Every layer at once, taken out by an undo step (Bake all): undoing or redoing swaps
// this list and recording index with the live ones, so it is its own inverse and moves
// no delta.
@(private)
Layer_Stack :: struct {
	active:    bool,
	list:      [dynamic]Sculpt_Layer,
	recording: int,
}

// How far a layer's displacement shows.
layer_weight :: #force_inline proc(l: Sculpt_Layer) -> f32 {return l.strength if l.visible else 0}

sculptor_layers :: proc(s: ^Sculptor) -> []Sculpt_Layer {return s.layers.list[:]}

// The recording layer's index, or -1.
sculptor_layer_recording :: proc(s: ^Sculptor) -> int {return s.layers.recording - 1}

// The layer's name as a string (pointing into the layer).
sculptor_layer_name :: proc(l: ^Sculpt_Layer) -> string {
	n := 0
	for n < len(l.name) && l.name[n] != 0 do n += 1
	return string(l.name[:n])
}

// Renames a layer (not an undo step), cutting the name to fit.
sculptor_layer_rename :: proc(s: ^Sculptor, index: int, name: string) {
	l := &s.layers.list[index]
	l.name = {}
	copy(l.name[:len(l.name) - 1], name)
}

// Whether the layer displaces anything.
sculptor_layer_used :: proc(l: Sculpt_Layer) -> bool {
	for d in l.delta do if d != nil do return true
	return false
}

// The layer's displacement at strength 1 as the vertices it moves, in increasing order,
// and how far, its mask taken in: the vertices of the nodes it moved, less those it (or
// its mask) leaves exactly where they were. For exports, which store a layer only where
// it acts.
sculptor_layer_sparse :: proc(s: ^Sculptor, index: int, allocator := context.allocator) -> (vertices: []u32, deltas: []Vec3) {
	l := s.layers.list[index]
	mask := layer_mask_of(s, index)
	shown :: #force_inline proc(s: ^Sculptor, mask: []u8, id, v: int, x: Vec3) -> Vec3 {
		return x if mask == nil else mask_shows(mask[int(s.nodes[id].vert_first) + v]) * x
	}
	count := 0
	for d, id in l.delta do for x, v in d do if shown(s, mask, id, v, x) != {} do count += 1
	vertices = make([]u32, count, allocator)
	deltas = make([]Vec3, count, allocator)
	k := 0
	// Nodes own vertex ranges in id order (sculptor_init and sculptor_init_laid_out), so
	// this is increasing.
	for d, id in l.delta {
		for x, v in d {
			y := shown(s, mask, id, v, x)
			if y == {} do continue
			vertices[k], deltas[k] = s.nodes[id].vert_first + u32(v), y
			k += 1
		}
	}
	return
}

// Adds an empty layer at full strength above the others, as an undo step, and starts it
// recording. Returns its index, or -1 when there are already MAX_SCULPT_LAYERS or
// dynamic topology is on.
sculptor_layer_add :: proc(s: ^Sculptor) -> int {
	_ = sculptor_stroke_end(s)
	if s.dyn != nil || len(s.layers.list) >= MAX_SCULPT_LAYERS do return -1
	s.layers.named += 1
	l := Sculpt_Layer{strength = 1, visible = true, delta = make([][]Vec3, len(s.nodes), s.history.allocator)}
	copy(l.name[:len(l.name) - 1], "Layer ")
	digits: [8]u8
	k, n := len(digits), s.layers.named
	for {
		k -= 1
		digits[k] = u8('0' + n % 10)
		n /= 10
		if n == 0 || k == 0 do break
	}
	copy(l.name[6:len(l.name) - 1], digits[k:])
	sculptor_stroke_begin(s)
	index := len(s.layers.list)
	append(&s.layers.list, l)
	s.history.current.layer_op = {active = true, index = index}
	_ = sculptor_stroke_end(s)
	s.layers.recording = index + 1
	return index
}

// Takes a layer out as an undo step: with `bake`, its displacement stays in the surface
// as plain sculpting; without, the surface loses it (Delete). Returns false when dynamic
// topology is on.
sculptor_layer_remove :: proc(s: ^Sculptor, index: int, bake: bool) -> bool {
	_ = sculptor_layer_mask_pick(s, -1)
	if s.dyn != nil do return false
	sculptor_stroke_begin(s)
	if !bake do layer_displace(s, index, -layer_weight(s.layers.list[index]))
	s.history.current.layer_op = {active = true, index = index, held = true, layer = s.layers.list[index]}
	ordered_remove(&s.layers.list, index)
	layer_shift_recording(s, index, removed = true)
	_ = sculptor_stroke_end(s)
	return true
}

// Sets a layer's strength and visibility, moving the vertices it displaced. Part of
// the stroke being recorded, or of one this begins: a slider drag calls it each frame
// and ends the stroke on release (sculptor_stroke_end), making one undo step. Setting
// the recording layer stops the recording, since what it records is at strength 1.
// Returns false when dynamic topology is on.
sculptor_layer_set :: proc(s: ^Sculptor, index: int, strength: f32, visible: bool) -> bool {
	if s.dyn != nil do return false
	h := &s.history
	// A drag of another slider, or anything but a drag, is a step of its own.
	if h.recording && !(h.current.layer_set.active && h.current.layer_set.index == index) do _ = sculptor_stroke_end(s)
	if !h.recording do sculptor_stroke_begin(s)
	l := &s.layers.list[index]
	if !h.current.layer_set.active do h.current.layer_set = {active = true, index = index, strength = l.strength, visible = l.visible}
	if s.layers.recording == index + 1 do s.layers.recording = 0
	before := layer_weight(l^)
	l.strength, l.visible = strength, visible
	layer_displace(s, index, layer_weight(l^) - before)
	return true
}

// Starts the layer recording (or with -1, stops any): later strokes add their movement
// to it. Recording works at full strength, so a layer shown at another strength is set
// to full first, as an undo step: returns true when that made one.
sculptor_layer_record :: proc(s: ^Sculptor, index: int) -> bool {
	_ = sculptor_stroke_end(s)
	if index < 0 || s.dyn != nil {
		s.layers.recording = 0
		return false
	}
	stepped := false
	if layer_weight(s.layers.list[index]) != 1 {
		_ = sculptor_layer_set(s, index, 1, true)
		stepped = sculptor_stroke_end(s)
	}
	s.layers.recording = index + 1
	return stepped
}

// Moves every vertex the layer displaced by `k` times its displacement (times what its
// mask leaves shown), saving the positions for the stroke being recorded.
@(private)
layer_displace :: proc(s: ^Sculptor, index: int, k: f32) {
	if k == 0 do return
	l := s.layers.list[index]
	clear(&s.hit)
	ids := make([dynamic]u32, 0, len(s.nodes), context.temp_allocator)
	verts: u32
	for d, id in l.delta {
		if d == nil do continue
		append(&s.hit, s.nodes[id].leaf)
		append(&ids, u32(id))
		verts += s.nodes[id].vert_count
	}
	if len(ids) == 0 do return
	if s.history.recording do record_hit(s, false)
	Job :: struct {
		s:     ^Sculptor,
		delta: [][]Vec3,
		mask:  []u8,
		ids:   []u32,
		k:     f32,
	}
	job := Job{s, l.delta, layer_mask_of(s, index), ids[:], k}
	jobs.parallel_for(s.pool if verts >= PARALLEL_MIN_VERTS else nil, len(ids), &job, proc(data: rawptr, i: int) {
		job := cast(^Job)data
		id := job.ids[i]
		n := job.s.nodes[id]
		live := job.s.mesh.positions[n.vert_first:][:n.vert_count]
		if job.mask == nil {
			for &p, v in live do p += job.k * job.delta[id][v]
			return
		}
		shows := job.mask[n.vert_first:][:n.vert_count]
		for &p, v in live do p += job.k * mask_shows(shows[v]) * job.delta[id][v]
	})
	sculptor_nodes_moved(s, ids[:])
	if s.history.recording do for leaf in s.changed do record_changed_node(s, s.node_of[leaf])
}

// Called as a stroke ends: adds what the stroke moved to the recording layer, saving
// the nodes' earlier displacement in the step so undo takes both back.
@(private)
layer_take_stroke :: proc(s: ^Sculptor) {
	h := &s.history
	r := s.layers.recording - 1
	if r < 0 || r >= len(s.layers.list) || s.dyn != nil do return
	if h.current.layer_op.active || h.current.layer_set.active || h.current.layer_move.active || h.current.layer_stack.active do return
	// Painting a layer's mask moves the surface by the layers, never into them.
	if h.current.mask_moved do return
	l := &s.layers.list[r]
	m := s.mesh
	saved := len(h.current.saved)
	for i in 0 ..< saved {
		sv := h.current.saved[i]
		if sv.positions == nil || sv.full do continue
		n := s.nodes[sv.node]
		live := m.positions[n.vert_first:][:n.vert_count]
		moved := false
		for p, v in live do if p != sv.positions[v] {
			moved = true
			break
		}
		if !moved do continue
		old := l.delta[sv.node]
		next := slice.clone(old, h.allocator) if old != nil else make([]Vec3, n.vert_count, h.allocator)
		for p, v in live do next[v] += p - sv.positions[v]
		l.delta[sv.node] = next
		append(&h.current.saved, Saved_Node{node = sv.node, delta = old, delta_layer = i32(r), is_delta = true})
	}
}

// Undo or redo of a step's layer changes, before its saved nodes swap.
@(private)
layer_step_swap :: proc(s: ^Sculptor, step: ^Undo_Step) {
	if op := &step.layer_op; op.active {
		if op.held {
			inject_at(&s.layers.list, op.index, op.layer)
			op.layer, op.held = {}, false
			layer_shift_recording(s, op.index, removed = false)
		} else {
			op.layer, op.held = s.layers.list[op.index], true
			ordered_remove(&s.layers.list, op.index)
			layer_shift_recording(s, op.index, removed = true)
		}
	}
	if set := &step.layer_set; set.active {
		l := &s.layers.list[set.index]
		l.strength, set.strength = set.strength, l.strength
		l.visible, set.visible = set.visible, l.visible
		if set.masked do l.mask, set.mask = set.mask, l.mask
	}
	if mv := step.layer_move; mv.active do layer_swap(s, mv.a, mv.b)
	if st := &step.layer_stack; st.active {
		s.layers.list, st.list = st.list, s.layers.list
		s.layers.recording, st.recording = st.recording, s.layers.recording
	}
}

// Swaps layers a and b, the recording one staying recording.
@(private = "file")
layer_swap :: proc(s: ^Sculptor, a, b: int) {
	list := s.layers.list[:]
	list[a], list[b] = list[b], list[a]
	r := &s.layers.recording
	if r^ == a + 1 do r^ = b + 1
	else if r^ == b + 1 do r^ = a + 1
}

// Adds a copy of layer `index` just above it, hidden so the surface stays as it is (its
// eye shows it), as an undo step. Returns the copy's index, or -1 when there are already
// MAX_SCULPT_LAYERS or dynamic topology is on.
sculptor_layer_duplicate :: proc(s: ^Sculptor, index: int) -> int {
	_ = sculptor_layer_mask_pick(s, -1)
	if s.dyn != nil || index < 0 || index >= len(s.layers.list) || len(s.layers.list) >= MAX_SCULPT_LAYERS do return -1
	from := s.layers.list[index]
	a := s.history.allocator
	l := Sculpt_Layer{strength = from.strength, visible = false, delta = make([][]Vec3, len(from.delta), a)}
	for d, id in from.delta do if d != nil do l.delta[id] = slice.clone(d, a)
	if from.mask != nil do l.mask = slice.clone(from.mask, a)
	name := sculptor_layer_name(&from)
	copy(l.name[:len(l.name) - 1], name)
	copy(l.name[min(len(name), len(l.name) - 1):len(l.name) - 1], " copy")
	sculptor_stroke_begin(s)
	at := index + 1
	inject_at(&s.layers.list, at, l)
	layer_shift_recording(s, at, removed = false)
	s.history.current.layer_op = {active = true, index = at}
	_ = sculptor_stroke_end(s)
	return at
}

// Turns layer `index`'s displacement the other way at the same strength, as an undo
// step: the surface moves by twice what the layer shows. False when the layer moves
// nothing or dynamic topology is on.
sculptor_layer_invert :: proc(s: ^Sculptor, index: int) -> bool {
	_ = sculptor_stroke_end(s)
	// Under dynamic topology the list is empty (sculptor_dyn_enable bakes the layers).
	if s.dyn != nil || index < 0 || index >= len(s.layers.list) do return false
	l := &s.layers.list[index]
	if !sculptor_layer_used(l^) do return false
	sculptor_stroke_begin(s)
	h := &s.history
	// Marks the step as the layer's own, not a stroke a recording layer takes in or Adjust
	// last stroke rescales; strength and visibility stay as they are.
	h.current.layer_set = {active = true, index = index, strength = l.strength, visible = l.visible}
	layer_displace(s, index, -2 * layer_weight(l^))
	for &d, id in l.delta {
		if d == nil do continue
		flipped := make([]Vec3, len(d), h.allocator)
		for x, v in d do flipped[v] = -x
		append(&h.current.saved, Saved_Node{node = u32(id), delta = d, delta_layer = i32(index), is_delta = true})
		d = flipped
	}
	return sculptor_stroke_end(s)
}

// Merges layer `index` into the one below it, as an undo step: that one takes what both
// show (each displacement times its weight, so a hidden layer adds nothing) at full
// strength and shown, and `index` goes; the surface does not move. False for the lowest
// layer or under dynamic topology.
sculptor_layer_merge_down :: proc(s: ^Sculptor, index: int) -> bool {
	_ = sculptor_layer_mask_pick(s, -1)
	if s.dyn != nil || index < 1 || index >= len(s.layers.list) do return false
	sculptor_stroke_begin(s)
	h := &s.history
	top, below := s.layers.list[index], &s.layers.list[index - 1]
	wt, wb := layer_weight(top), layer_weight(below^)
	// Masks are taken into what each shows, so the merged layer has none.
	mt, mb := top.mask, below.mask
	for id in 0 ..< len(below.delta) {
		d, t := below.delta[id], top.delta[id]
		below_moves, top_moves := d != nil && wb != 0, t != nil && wt != 0
		// A node the merge leaves as it is keeps its slice, and one it zeroes becomes nil,
		// as a layer holds nil where it moves nothing (sculptor_layer_used).
		if !top_moves && (d == nil || (wb == 1 && mb == nil)) do continue
		if !below_moves && !top_moves {
			append(&h.current.saved, Saved_Node{node = u32(id), delta = d, delta_layer = i32(index - 1), is_delta = true})
			below.delta[id] = nil
			continue
		}
		n := s.nodes[id].vert_count
		first := int(s.nodes[id].vert_first)
		merged := make([]Vec3, n, h.allocator)
		for v in 0 ..< int(n) {
			x: Vec3
			if below_moves do x += wb * (mask_shows(mb[first + v]) if mb != nil else 1) * d[v]
			if top_moves do x += wt * (mask_shows(mt[first + v]) if mt != nil else 1) * t[v]
			merged[v] = x
		}
		append(&h.current.saved, Saved_Node{node = u32(id), delta = d, delta_layer = i32(index - 1), is_delta = true})
		below.delta[id] = merged
	}
	h.current.layer_set = {active = true, index = index - 1, strength = below.strength, visible = below.visible, masked = mb != nil, mask = mb}
	below.strength, below.visible = 1, true
	if mb != nil do below.mask = nil
	h.current.layer_op = {active = true, index = index, held = true, layer = top}
	ordered_remove(&s.layers.list, index)
	layer_shift_recording(s, index, removed = true)
	return sculptor_stroke_end(s)
}

// Takes every layer out as one undo step, their work staying in the surface as plain
// sculpting (Bake all): the step holds the list as it was, so nothing is copied and one
// undo puts every layer back. False with no layers or under dynamic topology.
sculptor_layers_bake :: proc(s: ^Sculptor) -> bool {
	_ = sculptor_layer_mask_pick(s, -1)
	if s.dyn != nil || len(s.layers.list) == 0 do return false
	sculptor_stroke_begin(s)
	s.history.current.layer_stack = {active = true, list = s.layers.list, recording = s.layers.recording}
	s.layers.list, s.layers.recording = {}, 0
	return sculptor_stroke_end(s)
}

// Swaps layer `index` with the one above (`up`) or below it, as an undo step: older steps
// name layers by their place, so the order changes only through the history. False at
// either end or under dynamic topology.
sculptor_layer_move :: proc(s: ^Sculptor, index: int, up: bool) -> bool {
	_ = sculptor_layer_mask_pick(s, -1)
	other := index + 1 if up else index - 1
	if s.dyn != nil || other < 0 || other >= len(s.layers.list) do return false
	sculptor_stroke_begin(s)
	layer_swap(s, index, other)
	s.history.current.layer_move = {active = true, a = index, b = other}
	return sculptor_stroke_end(s)
}

// Keeps the recording index on the same layer when one is removed or put back at `at`.
@(private)
layer_shift_recording :: proc(s: ^Sculptor, at: int, removed: bool) {
	r := &s.layers.recording
	if r^ == 0 do return
	if removed {
		if r^ == at + 1 do r^ = 0
		else if r^ > at + 1 do r^ -= 1
	} else if r^ >= at + 1 {
		r^ += 1
	}
}

@(private)
layer_destroy :: proc(l: ^Sculpt_Layer, allocator: runtime.Allocator) {
	for d in l.delta do delete(d, allocator)
	delete(l.delta, allocator)
	delete(l.mask, allocator)
	l.delta, l.mask = nil, nil
}

@(private)
layer_bytes :: proc(l: Sculpt_Layer) -> int {
	bytes := len(l.delta) * size_of([]Vec3)
	for d in l.delta do bytes += len(d) * size_of(Vec3)
	return bytes + len(l.mask)
}

// Drops every layer, keeping the surface as it is (their work stays as plain sculpting).
// Not an undo step: for changes that clear the history anyway.
sculptor_layers_bake_all :: proc(s: ^Sculptor) {
	if s.layers.picked != 0 do _ = sculptor_layer_mask_pick(s, -1)
	for &l in s.layers.list do layer_destroy(&l, s.history.allocator)
	clear(&s.layers.list)
	s.layers.recording = 0
}

@(private)
layers_destroy :: proc(s: ^Sculptor) {
	sculptor_layers_bake_all(s)
	delete(s.layers.list)
	s.layers = {}
}

// Bytes the layers hold, for the stats panel.
sculptor_layers_bytes :: proc(s: ^Sculptor) -> int {
	bytes := 0
	for l in s.layers.list do bytes += layer_bytes(l)
	return bytes
}

// The box round the vertices layer `index` moves, in the mesh's space, where they stand
// now; AABB_EMPTY when it moves none. What the Layers panel tints and pictures.
sculptor_layer_bounds :: proc(s: ^Sculptor, index: int) -> geom.Aabb {
	b := geom.AABB_EMPTY
	if index < 0 || index >= len(s.layers.list) do return b
	positions := s.mesh.positions[:]
	for d, id in s.layers.list[index].delta {
		if d == nil || id >= len(s.nodes) do continue
		first := int(s.nodes[id].vert_first)
		for x, v in d do if x != {} && first + v < len(positions) do geom.aabb_grow(&b, positions[first + v])
	}
	return b
}
