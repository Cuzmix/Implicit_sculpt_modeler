package sculpt

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"

@(private = "file")
UP :: Vec3{0, 0, 1}

@(private = "file")
SIDE :: Vec3{1, 0, 0}

@(private = "file")
near :: proc(a, b: []Vec3, eps: f32 = 1e-5) -> bool {
	if len(a) != len(b) do return false
	for p, i in a do if linalg.length(p - b[i]) > eps do return false
	return true
}

@(private = "file")
stroke :: proc(s: ^Sculptor, at: Vec3, kind := Brush_Kind.Draw) -> bool {
	sculptor_stroke_begin(s)
	_ = apply_dab(s, {kind = kind, radius = 0.4, strength = 0.5}, at)
	return sculptor_stroke_end(s)
}

// A recording layer keeps what its strokes moved; its slider scales that, zero taking
// it off and two doubling it, and each change undoes as a step of its own.
@(test)
layer_records_and_its_slider_scales :: proc(t: ^testing.T) {
	m := geom.icosphere(4)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	p0 := slice.clone(m.positions[:], context.temp_allocator)
	testing.expect_value(t, sculptor_layer_add(&s), 0)
	testing.expect_value(t, sculptor_layer_recording(&s), 0)
	testing.expect_value(t, sculptor_layer_name(&s.layers.list[0]), "Layer 1")
	testing.expect(t, stroke(&s, UP))
	p1 := slice.clone(m.positions[:], context.temp_allocator)
	testing.expect(t, !slice.equal(p0, p1), "the stroke moved nothing")
	testing.expect(t, sculptor_layer_used(s.layers.list[0]), "the layer kept nothing")

	testing.expect(t, sculptor_layer_set(&s, 0, 0, true))
	testing.expect(t, sculptor_stroke_end(&s), "the slider change was not a step")
	testing.expect(t, near(m.positions[:], p0), "strength 0 left the layer's work")
	testing.expect_value(t, sculptor_layer_recording(&s), -1)
	// A drag is one step however many times it moves.
	testing.expect(t, sculptor_layer_set(&s, 0, 1.5, true))
	testing.expect(t, sculptor_layer_set(&s, 0, 2, true))
	testing.expect(t, sculptor_stroke_end(&s))
	p2 := make([]Vec3, len(p0), context.temp_allocator)
	for p, v in p0 do p2[v] = p + 2 * (p1[v] - p)
	testing.expect(t, near(m.positions[:], p2), "strength 2 did not double the layer")
	// Hiding takes it off and keeps the strength.
	testing.expect(t, sculptor_layer_set(&s, 0, 2, false))
	testing.expect(t, sculptor_stroke_end(&s))
	testing.expect(t, near(m.positions[:], p0))

	testing.expect(t, sculptor_undo(&s)) // shown again
	testing.expect(t, near(m.positions[:], p2))
	testing.expect(t, sculptor_undo(&s)) // the drag
	testing.expect(t, near(m.positions[:], p0))
	testing.expect_value(t, s.layers.list[0].strength, 0)
	testing.expect(t, sculptor_undo(&s)) // strength 0
	testing.expect(t, slice.equal(m.positions[:], p1))
	testing.expect(t, sculptor_undo(&s)) // the stroke
	testing.expect(t, slice.equal(m.positions[:], p0))
	testing.expect(t, !sculptor_layer_used(s.layers.list[0]), "undoing the stroke left it in the layer")
	testing.expect(t, sculptor_undo(&s)) // the layer
	testing.expect_value(t, len(s.layers.list), 0)
	for _ in 0 ..< 5 do testing.expect(t, sculptor_redo(&s))
	testing.expect(t, near(m.positions[:], p0))
	testing.expect(t, s.layers.list[0].strength == 2 && !s.layers.list[0].visible)
	testing.expect(t, sculptor_layer_set(&s, 0, 1, true))
	_ = sculptor_stroke_end(&s)
	testing.expect(t, near(m.positions[:], p1), "redo lost the layer's work")
	// Undo memory is counted as the steps change what they hold.
	_ = sculptor_undo(&s)
	sculptor_clear_history(&s)
	testing.expect_value(t, sculptor_undo_bytes(&s), 0)
}

// Work outside a layer stays when its slider moves: only the layer's own part changes.
@(test)
layer_slider_leaves_other_work :: proc(t: ^testing.T) {
	m := geom.icosphere(4)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	_ = sculptor_layer_add(&s)
	_ = sculptor_layer_add(&s)
	testing.expect_value(t, sculptor_layer_recording(&s), 1)
	before := slice.clone(m.positions[:], context.temp_allocator)
	testing.expect(t, stroke(&s, UP))
	layer := make([]Vec3, len(before), context.temp_allocator)
	for p, v in m.positions do layer[v] = p - before[v]
	_ = sculptor_layer_record(&s, -1)
	testing.expect(t, stroke(&s, linalg.normalize(UP + SIDE), .Inflate))
	testing.expect(t, stroke(&s, SIDE))
	after := slice.clone(m.positions[:], context.temp_allocator)
	testing.expect(t, sculptor_layer_set(&s, 1, -1, true))
	_ = sculptor_stroke_end(&s)
	for p, v in m.positions do testing.expect(t, linalg.length(p - (after[v] - 2 * layer[v])) < 1e-5)
	testing.expect(t, !sculptor_layer_used(s.layers.list[0]), "the layer not recording kept work")
	// Recording again at another strength first sets the layer to full, as a step.
	testing.expect(t, sculptor_layer_record(&s, 1))
	testing.expect(t, near(m.positions[:], after))
}

// Delete takes the layer's work off, Bake keeps it as plain sculpting; both undo.
@(test)
layer_delete_and_bake :: proc(t: ^testing.T) {
	m := geom.icosphere(4)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	p0 := slice.clone(m.positions[:], context.temp_allocator)
	_ = sculptor_layer_add(&s)
	testing.expect(t, stroke(&s, UP))
	p1 := slice.clone(m.positions[:], context.temp_allocator)
	testing.expect(t, sculptor_layer_remove(&s, 0, bake = false))
	testing.expect(t, near(m.positions[:], p0), "delete left the work")
	testing.expect_value(t, len(s.layers.list), 0)
	testing.expect(t, sculptor_undo(&s))
	testing.expect(t, slice.equal(m.positions[:], p1))
	// Recording is a mode, not part of the history: the layer comes back not recording.
	testing.expect_value(t, sculptor_layer_recording(&s), -1)
	testing.expect(t, sculptor_layer_remove(&s, 0, bake = true))
	testing.expect(t, slice.equal(m.positions[:], p1), "bake moved the surface")
	testing.expect_value(t, len(s.layers.list), 0)
	testing.expect(t, sculptor_undo(&s))
	testing.expect(t, sculptor_layer_used(s.layers.list[0]))
	// The step that held the baked layer goes with the redo list.
	testing.expect(t, stroke(&s, SIDE))
	testing.expect(t, !sculptor_can_redo(&s))
}

// Layers on every level read back from the file as written.
@(test)
layers_round_trip_the_file :: proc(t: ^testing.T) {
	l: Levels
	levels_init(&l, geom.icosphere(2), nil, 64)
	defer levels_destroy(&l)
	testing.expect(t, levels_subdivide(&l))
	s := &levels_current(&l).sculptor
	p0 := slice.clone(s.mesh.positions[:], context.temp_allocator)
	_ = sculptor_layer_add(s)
	testing.expect(t, stroke(s, UP))
	_ = sculptor_layer_add(s)
	sculptor_layer_rename(s, 1, "Pores")
	testing.expect(t, sculptor_layer_set(s, 1, 0.25, false))
	_ = sculptor_stroke_end(s)
	out := make([dynamic]u8)
	defer delete(out)
	levels_write(&l, &out)

	back: Levels
	r := geom.byte_reader(out[:])
	testing.expect(t, levels_read(&back, &r, nil, 64), "read failed")
	defer levels_destroy(&back)
	b := &levels_current(&back).sculptor
	testing.expect_value(t, len(b.layers.list), 2)
	if len(b.layers.list) != 2 do return
	testing.expect_value(t, sculptor_layer_name(&b.layers.list[1]), "Pores")
	testing.expect(t, b.layers.list[1].strength == 0.25 && !b.layers.list[1].visible)
	testing.expect_value(t, sculptor_layer_recording(b), -1)
	testing.expect_value(t, len(levels_current(&back).sculptor.layers.list), 2)
	testing.expect_value(t, len(back.levels[0].sculptor.layers.list), 0)
	at := make(map[Vec3]int, len(s.mesh.positions), context.temp_allocator)
	for p, v in s.mesh.positions do at[p] = v
	delta :: proc(s: ^Sculptor, v: int) -> Vec3 {
		for n, id in s.nodes {
			if u32(v) < n.vert_first || u32(v) >= n.vert_first + n.vert_count do continue
			d := s.layers.list[0].delta[id]
			return d[u32(v) - n.vert_first] if d != nil else {}
		}
		return {}
	}
	was := make([]int, len(b.mesh.positions), context.temp_allocator)
	for p, v in b.mesh.positions {
		w, found := at[p]
		testing.expect(t, found && delta(b, v) == delta(s, w))
		was[v] = w
	}
	// Turning the layer off on the read copy goes back to the surface as it was.
	testing.expect(t, sculptor_layer_set(b, 0, 0, true))
	_ = sculptor_stroke_end(b)
	for p, v in b.mesh.positions do testing.expect(t, linalg.length(p - p0[was[v]]) < 1e-5)
}

// Dynamic topology bakes the layers, since its edits renumber the vertices.
@(test)
layers_bake_under_dyntopo :: proc(t: ^testing.T) {
	m := geom.icosphere(3)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	_ = sculptor_layer_add(&s)
	testing.expect(t, stroke(&s, UP))
	testing.expect(t, sculptor_dyn_enable(&s))
	testing.expect_value(t, len(s.layers.list), 0)
	testing.expect_value(t, sculptor_layer_add(&s), -1)
	testing.expect(t, stroke(&s, SIDE))
}

// Duplicate adds a hidden copy, so nothing moves until its eye shows it, which doubles the
// layer's work; Invert turns the work the other way and undoes bit for bit.
@(test)
layer_duplicate_and_invert :: proc(t: ^testing.T) {
	m := geom.icosphere(4)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	p0 := slice.clone(m.positions[:], context.temp_allocator)
	_ = sculptor_layer_add(&s)
	testing.expect(t, stroke(&s, UP))
	p1 := slice.clone(m.positions[:], context.temp_allocator)
	testing.expect_value(t, sculptor_layer_duplicate(&s, 0), 1)
	testing.expect_value(t, sculptor_layer_name(&s.layers.list[1]), "Layer 1 copy")
	testing.expect(t, slice.equal(m.positions[:], p1), "duplicating moved the surface")
	testing.expect_value(t, sculptor_layer_recording(&s), 0)
	testing.expect(t, sculptor_layer_set(&s, 1, 1, true))
	_ = sculptor_stroke_end(&s)
	for p, v in m.positions do testing.expect(t, linalg.length(p - (p0[v] + 2 * (p1[v] - p0[v]))) < 1e-5)
	testing.expect(t, sculptor_undo(&s))
	testing.expect(t, sculptor_undo(&s))
	testing.expect_value(t, len(s.layers.list), 1)
	testing.expect(t, slice.equal(m.positions[:], p1))

	testing.expect(t, sculptor_layer_invert(&s, 0))
	for p, v in m.positions do testing.expect(t, linalg.length(p - (p0[v] - (p1[v] - p0[v]))) < 1e-5)
	testing.expect(t, sculptor_undo(&s))
	testing.expect(t, slice.equal(m.positions[:], p1), "undoing an invert did not put the surface back")
	testing.expect(t, sculptor_redo(&s))
	testing.expect(t, sculptor_undo(&s))
	// An invert is the layer's own step, which Adjust last stroke leaves alone.
	testing.expect(t, sculptor_layer_invert(&s, 0))
	testing.expect(t, !sculptor_can_adjust(&s), "an invert offered to Adjust last stroke")
}

// Merge down leaves the surface as it was with one layer fewer holding both layers' work,
// and undoes to both; Move swaps two layers and undoes to the old order, after which the
// older steps' undo still finds their layers; a recording layer keeps recording through a
// move and its undo and redo.
@(test)
layer_merge_down_and_move :: proc(t: ^testing.T) {
	m := geom.icosphere(4)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	_ = sculptor_layer_add(&s)
	testing.expect(t, stroke(&s, UP))
	_ = sculptor_layer_add(&s)
	testing.expect(t, stroke(&s, SIDE))
	testing.expect(t, sculptor_layer_set(&s, 1, 0.5, true))
	_ = sculptor_stroke_end(&s)
	before := slice.clone(m.positions[:], context.temp_allocator)
	testing.expect(t, !sculptor_layer_merge_down(&s, 0), "merged the lowest layer down")
	testing.expect(t, sculptor_layer_merge_down(&s, 1))
	testing.expect_value(t, len(s.layers.list), 1)
	testing.expect(t, near(m.positions[:], before, 1e-6), "merging moved the surface")
	// At strength 0 the merged layer takes both strokes' work off.
	testing.expect(t, sculptor_layer_set(&s, 0, 0, true))
	_ = sculptor_stroke_end(&s)
	testing.expect(t, sculptor_undo(&s))
	testing.expect(t, sculptor_undo(&s))
	testing.expect_value(t, len(s.layers.list), 2)
	testing.expect(t, slice.equal(m.positions[:], before))
	testing.expect_value(t, s.layers.list[1].strength, 0.5)

	testing.expect(t, sculptor_layer_move(&s, 0, true))
	testing.expect_value(t, sculptor_layer_name(&s.layers.list[0]), "Layer 2")
	testing.expect(t, !sculptor_layer_move(&s, 1, true), "moved the top layer up")
	// Undoing a move puts Layer 2 back on top, so undoing on past the strength change and
	// the side stroke takes the side stroke off Layer 2, not Layer 1.
	testing.expect(t, sculptor_undo(&s))
	testing.expect_value(t, sculptor_layer_name(&s.layers.list[1]), "Layer 2")
	testing.expect(t, sculptor_layer_move(&s, 1, false))
	testing.expect(t, sculptor_undo(&s))
	testing.expect(t, sculptor_undo(&s))
	testing.expect(t, sculptor_undo(&s))
	testing.expect(t, sculptor_layer_used(s.layers.list[0]) && !sculptor_layer_used(s.layers.list[1]), "the side stroke's undo left the wrong layer")
	testing.expect(t, sculptor_redo(&s))
	testing.expect(t, sculptor_redo(&s))

	// Layer 1 records, moves above Layer 2 and keeps recording through the move's undo and
	// redo; the next stroke goes into it, leaving Layer 2 as it was.
	testing.expect(t, !sculptor_layer_record(&s, 0))
	testing.expect(t, sculptor_layer_move(&s, 0, true))
	testing.expect_value(t, sculptor_layer_recording(&s), 1)
	testing.expect(t, sculptor_undo(&s))
	testing.expect_value(t, sculptor_layer_recording(&s), 0)
	testing.expect(t, sculptor_redo(&s))
	testing.expect_value(t, sculptor_layer_recording(&s), 1)
	under, rec := layer_bytes(s.layers.list[0]), layer_bytes(s.layers.list[1])
	testing.expect(t, stroke(&s, -UP))
	testing.expect_value(t, layer_bytes(s.layers.list[0]), under)
	testing.expect(t, layer_bytes(s.layers.list[1]) > rec, "the stroke after the move missed the recording layer")
}

// Merging a small top layer into a full lower one at strength 1 keeps only the nodes the
// top layer touches in the step, and a merge that zeroes a node leaves it nil.
@(test)
layer_merge_down_saves_only_what_changes :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	_ = sculptor_layer_add(&s)
	sculptor_stroke_begin(&s)
	_ = apply_dab(&s, {kind = .Inflate, radius = 4, strength = 0.2}, UP)
	_ = sculptor_stroke_end(&s)
	full := layer_bytes(s.layers.list[0])
	_ = sculptor_layer_add(&s)
	testing.expect(t, stroke(&s, UP))
	top := layer_bytes(s.layers.list[1])
	testing.expect(t, top < full / 4, "the top layer is not small")
	testing.expect(t, sculptor_layer_merge_down(&s, 1))
	step := s.history.done[len(s.history.done) - 1]
	testing.expect(t, step_bytes(step) < top + full / 4, "the merge saved nodes it left alone")
	testing.expect(t, sculptor_undo(&s))

	// Hidden, the lower layer weighs nothing, so merging an empty top layer zeroes it.
	testing.expect(t, sculptor_layer_set(&s, 0, 1, false))
	_ = sculptor_stroke_end(&s)
	_ = sculptor_layer_remove(&s, 1, bake = false)
	_ = sculptor_layer_add(&s)
	testing.expect(t, sculptor_layer_merge_down(&s, 1))
	testing.expect(t, !sculptor_layer_used(s.layers.list[0]), "a zeroed merge kept slices")
	testing.expect(t, !sculptor_layer_invert(&s, 0), "inverted a layer that moves nothing")
}

// Bake all is one step holding every layer, so one undo puts them all back even when the
// history's limit trims older steps, and the surface stays as it was throughout.
@(test)
layers_bake_all_is_one_step :: proc(t: ^testing.T) {
	m := geom.icosphere(4)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	for at in ([3]Vec3{UP, SIDE, -UP}) {
		_ = sculptor_layer_add(&s)
		testing.expect(t, stroke(&s, at))
	}
	before := slice.clone(m.positions[:], context.temp_allocator)
	s.history.limit = 1
	testing.expect(t, sculptor_layers_bake(&s))
	testing.expect_value(t, len(s.layers.list), 0)
	testing.expect_value(t, len(s.history.done), 1)
	testing.expect(t, slice.equal(m.positions[:], before))
	testing.expect(t, sculptor_undo(&s))
	testing.expect_value(t, len(s.layers.list), 3)
	testing.expect_value(t, sculptor_layer_recording(&s), 2)
	for l in s.layers.list do testing.expect(t, sculptor_layer_used(l))
	testing.expect(t, sculptor_redo(&s))
	testing.expect_value(t, len(s.layers.list), 0)
	testing.expect(t, !sculptor_layers_bake(&s), "baked with no layers")
	testing.expect(t, slice.equal(m.positions[:], before))
}

// Under dynamic topology the layers are baked, so the layer calls refuse rather than index
// an empty list.
@(test)
layer_calls_refuse_under_dyntopo :: proc(t: ^testing.T) {
	m := geom.icosphere(3)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	_ = sculptor_layer_add(&s)
	testing.expect(t, stroke(&s, UP))
	testing.expect(t, sculptor_dyn_enable(&s))
	testing.expect(t, !sculptor_layer_invert(&s, 0))
	testing.expect(t, !sculptor_layer_merge_down(&s, 1))
	testing.expect(t, !sculptor_layer_move(&s, 0, true))
	testing.expect_value(t, sculptor_layer_duplicate(&s, 0), -1)
	testing.expect(t, !sculptor_layers_bake(&s))
}

// A layer's box holds what its strokes moved and nothing a stroke outside it moved; an
// empty layer has none.
@(test)
layer_bounds_hold_what_it_moved :: proc(t: ^testing.T) {
	m := geom.icosphere(4)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	testing.expect_value(t, sculptor_layer_add(&s), 0)
	b := sculptor_layer_bounds(&s, 0)
	testing.expect(t, b.lo.x > b.hi.x, "an empty layer has a box")
	testing.expect(t, stroke(&s, UP))
	_ = sculptor_layer_record(&s, -1)
	_ = sculptor_stroke_end(&s)
	testing.expect(t, stroke(&s, SIDE))
	b = sculptor_layer_bounds(&s, 0)
	testing.expect(t, b.lo.x <= b.hi.x)
	testing.expect(t, b.hi.z > 0.8, "the box misses the top the layer moved")
	testing.expect(t, b.hi.x < 0.6, "the box holds the side the layer never moved")
	testing.expect(t, sculptor_layer_bounds(&s, 3).lo.x > sculptor_layer_bounds(&s, 3).hi.x)
}
