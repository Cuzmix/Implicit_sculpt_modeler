package sculpt

import "base:runtime"
import "core:slice"

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
// and remove vertices (sculptor_dyn_enable bakes the layers).

// How many layers one sculptor keeps.
MAX_SCULPT_LAYERS :: 32

Sculpt_Layer :: struct {
	name:     [32]u8, // zero-terminated
	strength: f32,
	visible:  bool,
	// Per node id: the displacement of each owned vertex at strength 1, nil where the
	// layer moved nothing.
	delta:    [][]Vec3,
}

Sculpt_Layers :: struct {
	list:      [dynamic]Sculpt_Layer,
	recording: int, // the recording layer's index + 1, 0 for none (so a zeroed stack records nothing)
	named:     int, // layers named so far, for the next "Layer N"
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

// The strength and visibility a layer had before an undo step changed them; undoing or
// redoing swaps them with the live ones.
@(private)
Layer_Set :: struct {
	active:   bool,
	index:    int,
	strength: f32,
	visible:  bool,
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
	_ = sculptor_stroke_end(s)
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

// Moves every vertex the layer displaced by `k` times its displacement, saving the
// positions for the stroke being recorded.
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
		ids:   []u32,
		k:     f32,
	}
	job := Job{s, l.delta, ids[:], k}
	jobs.parallel_for(s.pool if verts >= PARALLEL_MIN_VERTS else nil, len(ids), &job, proc(data: rawptr, i: int) {
		job := cast(^Job)data
		id := job.ids[i]
		n := job.s.nodes[id]
		live := job.s.mesh.positions[n.vert_first:][:n.vert_count]
		for &p, v in live do p += job.k * job.delta[id][v]
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
	if h.current.layer_op.active || h.current.layer_set.active do return
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
	}
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
	l.delta = nil
}

@(private)
layer_bytes :: proc(l: Sculpt_Layer) -> int {
	bytes := len(l.delta) * size_of([]Vec3)
	for d in l.delta do bytes += len(d) * size_of(Vec3)
	return bytes
}

// Drops every layer, keeping the surface as it is (their work stays as plain sculpting).
// Not an undo step: for changes that clear the history anyway.
sculptor_layers_bake_all :: proc(s: ^Sculptor) {
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
