package sculpt

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

@(private = "file")
UP :: Vec3{0, 0, 1}

@(private = "file")
near :: proc(a, b: []Vec3, eps: f32 = 1e-4) -> bool {
	if len(a) != len(b) do return false
	for p, i in a do if linalg.length(p - b[i]) > eps do return false
	return true
}

@(private = "file")
stroke :: proc(s: ^Sculptor, at: Vec3, kind := Brush_Kind.Draw, invert := false) -> bool {
	sculptor_stroke_begin(s)
	_ = apply_dab(s, {kind = kind, radius = 0.5, strength = 0.6, invert = invert}, at)
	return sculptor_stroke_end(s)
}

// The surface with layer 0's displacement scaled by `k` times what `mask` shows, over the
// work outside it at `base`.
@(private = "file")
expected :: proc(s: ^Sculptor, base: []Vec3, k: f32, mask: []u8) -> []Vec3 {
	out := slice.clone(base, context.temp_allocator)
	for d, id in s.layers.list[0].delta {
		if d == nil do continue
		first := int(s.nodes[id].vert_first)
		for x, v in d do out[first + v] += k * (mask_shows(mask[first + v]) if mask != nil else 1) * x
	}
	return out
}

// Picking a layer's mask makes it the mask the mask tools paint: a fill hides the whole
// layer and the surface goes back to the work outside it, a Mask stroke hides it where it
// passes, and undo and redo take mask and surface back together, even once the sculpt
// mask is back and the strokes' mask waits in the layer.
@(test)
layer_mask_hides_where_painted :: proc(t: ^testing.T) {
	m := geom.icosphere(4)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	base := slice.clone(m.positions[:], context.temp_allocator)
	_ = sculptor_layer_add(&s)
	testing.expect(t, stroke(&s, UP))
	full := slice.clone(m.positions[:], context.temp_allocator)

	testing.expect(t, sculptor_layer_mask_pick(&s, 0))
	testing.expect_value(t, sculptor_layer_mask_picked(&s), 0)
	testing.expect(t, sculptor_mask_command(&s, .Fill))
	testing.expect(t, near(m.positions[:], base), "a full mask left the layer showing")
	testing.expect(t, sculptor_undo(&s))
	testing.expect(t, slice.equal(m.positions[:], full), "undo did not show the layer again")
	testing.expect(t, sculptor_redo(&s))
	testing.expect(t, near(m.positions[:], base))
	testing.expect(t, sculptor_mask_command(&s, .Invert))
	testing.expect(t, near(m.positions[:], full), "an empty mask hid something")

	// A Mask stroke at the top hides the layer there and leaves the rest.
	testing.expect(t, stroke(&s, UP, .Mask))
	painted := slice.clone(s.mask, context.temp_allocator)
	testing.expect(t, slice.any_of_proc(painted, proc(k: u8) -> bool {return k > 0}), "the stroke painted nothing")
	testing.expect(t, near(m.positions[:], expected(&s, base, 1, painted)))
	testing.expect(t, sculptor_layer_has_mask(&s, 0))

	// Back to the sculpt mask: it is as it was (none), and the layer keeps its mask.
	testing.expect(t, sculptor_layer_mask_pick(&s, -1))
	testing.expect(t, s.mask == nil && sculptor_sculpt_mask(&s) == nil)
	testing.expect(t, slice.equal(s.layers.list[0].mask, painted))
	// The slider scales what the mask shows.
	testing.expect(t, sculptor_layer_set(&s, 0, 2, true))
	_ = sculptor_stroke_end(&s)
	testing.expect(t, near(m.positions[:], expected(&s, base, 2, painted)))
	testing.expect(t, sculptor_undo(&s))
	// Undone from outside the pick, the stroke's mask comes off the layer's mask.
	testing.expect(t, sculptor_undo(&s))
	testing.expect(t, near(m.positions[:], full))
	testing.expect(t, !sculptor_layer_has_mask(&s, 0))
	testing.expect(t, s.mask == nil, "undo painted the sculpt mask")
	testing.expect(t, sculptor_redo(&s))
	testing.expect(t, slice.equal(s.layers.list[0].mask, painted))
	testing.expect(t, near(m.positions[:], expected(&s, base, 1, painted)))
}

// A stroke recording into a layer under a mask always shows where it is made; the layer
// keeps all of it, so clearing the mask shows the hidden part on top.
@(test)
recording_under_a_mask_keeps_the_whole_stroke :: proc(t: ^testing.T) {
	m := geom.icosphere(4)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	_ = sculptor_layer_add(&s)
	testing.expect(t, sculptor_layer_mask_pick(&s, 0))
	testing.expect(t, sculptor_mask_command(&s, .Fill))
	testing.expect(t, sculptor_layer_mask_pick(&s, -1))
	before := slice.clone(m.positions[:], context.temp_allocator)
	testing.expect(t, stroke(&s, UP))
	after := slice.clone(m.positions[:], context.temp_allocator)
	testing.expect(t, !slice.equal(before, after), "the stroke did not show")
	testing.expect(t, sculptor_layer_used(s.layers.list[0]))
	// Hidden by the mask, the slider moves nothing.
	testing.expect(t, sculptor_layer_set(&s, 0, 0, true))
	_ = sculptor_stroke_end(&s)
	testing.expect(t, near(m.positions[:], after))
	testing.expect(t, sculptor_layer_set(&s, 0, 1, true))
	_ = sculptor_stroke_end(&s)
	// Cleared, the mask shows the whole stroke once more over where it stands.
	testing.expect(t, sculptor_layer_mask_pick(&s, 0))
	testing.expect(t, sculptor_mask_command(&s, .Clear))
	want := slice.clone(after, context.temp_allocator)
	for v in 0 ..< len(want) do want[v] += after[v] - before[v]
	testing.expect(t, near(m.positions[:], want, 1e-3))
	// An all-clear mask is dropped once the sculpt mask is back.
	testing.expect(t, sculptor_layer_mask_pick(&s, -1))
	testing.expect(t, s.layers.list[0].mask == nil)
}

// From the sculpt mask copies it into the picked layer mask as one step; Merge down
// takes the masks into the merged displacement, the surface staying put, and undo puts
// the lower layer's mask back.
@(test)
layer_mask_from_sculpt_and_merge :: proc(t: ^testing.T) {
	m := geom.icosphere(4)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	_ = sculptor_layer_add(&s)
	testing.expect(t, stroke(&s, UP))
	_ = sculptor_layer_add(&s)
	testing.expect(t, stroke(&s, -UP))
	testing.expect(t, stroke(&s, UP, .Mask))
	sculpt := slice.clone(s.mask, context.temp_allocator)
	testing.expect(t, sculptor_layer_mask_pick(&s, 0))
	testing.expect(t, s.mask == nil, "the layer had a mask already")
	testing.expect(t, sculptor_layer_mask_from_sculpt(&s))
	testing.expect(t, slice.equal(s.mask, sculpt))
	testing.expect(t, slice.equal(sculptor_sculpt_mask(&s), sculpt), "the sculpt mask changed")
	shown := slice.clone(m.positions[:], context.temp_allocator)
	testing.expect(t, sculptor_layer_merge_down(&s, 1))
	testing.expect_value(t, sculptor_layer_mask_picked(&s), -1)
	testing.expect(t, near(m.positions[:], shown), "merging moved the surface")
	testing.expect(t, s.layers.list[0].mask == nil && slice.equal(s.mask, sculpt))
	testing.expect(t, sculptor_undo(&s))
	testing.expect(t, slice.equal(s.layers.list[0].mask, sculpt))
	testing.expect(t, near(m.positions[:], shown))
}

// A layer's mask reads back from the file as written, picked or not, and the sculpt mask
// is stored as the mask even while a layer's mask is picked.
@(test)
layer_masks_round_trip_the_file :: proc(t: ^testing.T) {
	l: Levels
	levels_init(&l, geom.icosphere(3), nil, 64)
	defer levels_destroy(&l)
	s := &levels_current(&l).sculptor
	_ = sculptor_layer_add(s)
	testing.expect(t, stroke(s, UP))
	testing.expect(t, sculptor_layer_mask_pick(s, 0))
	testing.expect(t, stroke(s, UP, .Mask))
	layer_mask := slice.clone(s.mask, context.temp_allocator)
	out := make([dynamic]u8)
	defer delete(out)
	testing.expect(t, levels_write(&l, &out))

	back: Levels
	r := geom.byte_reader(out[:])
	testing.expect(t, levels_read(&back, &r, nil, 64), "read failed")
	defer levels_destroy(&back)
	b := &levels_current(&back).sculptor
	testing.expect(t, b.mask == nil, "the layer's mask was read as the sculpt mask")
	testing.expect(t, len(b.layers.list) == 1 && b.layers.list[0].mask != nil)
	if len(b.layers.list) != 1 || b.layers.list[0].mask == nil do return
	// The base level keeps its order in the file, so the mask compares vertex by vertex.
	testing.expect(t, slice.equal(b.layers.list[0].mask, layer_mask))
	testing.expect(t, near(b.mesh.positions[:], s.mesh.positions[:]))
}


// Painting a layer's mask and its commands move the surface the same, bit for bit, on
// one thread and on several.
@(test)
layer_mask_serial_and_parallel_agree :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 4)
	defer jobs.pool_destroy(&pool)
	run :: proc(pool: ^jobs.Pool) -> []Vec3 {
		m := geom.icosphere(5)
		s: Sculptor
		sculptor_init(&s, &m, pool, 64)
		defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
		_ = sculptor_layer_add(&s)
		_ = stroke(&s, UP)
		_ = sculptor_layer_mask_pick(&s, 0)
		_ = stroke(&s, UP, .Mask)
		_ = sculptor_mask_command(&s, .Blur, 3)
		_ = stroke(&s, {0.3, 0, 0.95}, .Mask, invert = true)
		return slice.clone(m.positions[:], context.temp_allocator)
	}
	testing.expect(t, slice.equal(run(nil), run(&pool)), "serial and parallel differ")
}

// A rebuild carries each layer's mask with its layer: onto a copy of the same surface the
// mask comes across as it was, and taking the layer off moves both surfaces alike.
@(test)
layer_masks_carry_onto_a_rebuilt_surface :: proc(t: ^testing.T) {
	ma := geom.icosphere(4)
	a: Sculptor
	sculptor_init(&a, &ma, nil, 64)
	defer {sculptor_destroy(&a); geom.mesh_destroy(&ma)}
	_ = sculptor_layer_add(&a)
	testing.expect(t, stroke(&a, UP))
	testing.expect(t, sculptor_layer_mask_pick(&a, 0))
	testing.expect(t, stroke(&a, UP, .Mask))
	painted := slice.clone(a.mask, context.temp_allocator)
	mb := geom.icosphere(4)
	copy(mb.positions[:], ma.positions[:])
	b: Sculptor
	sculptor_init(&b, &mb, nil, 64)
	defer {sculptor_destroy(&b); geom.mesh_destroy(&mb)}
	sm := surface_map_build(&a, &b)
	defer surface_map_destroy(&sm)
	testing.expect_value(t, sculptor_layers_project(&a, &b, sm), 1)
	testing.expect_value(t, sculptor_layer_mask_picked(&a), -1)
	testing.expect(t, b.mask == nil, "the layer's mask came across as the sculpt mask")
	// Laying out the copy numbers its vertices its own way: match them by place.
	of_a := make(map[Vec3]int, len(ma.positions), context.temp_allocator)
	for p, v in ma.positions do of_a[p] = v
	same := make([]int, len(mb.positions), context.temp_allocator)
	for p, v in mb.positions do same[v] = of_a[p] or_else -1
	for k, v in b.layers.list[0].mask {
		if same[v] < 0 || painted[same[v]] != k {
			testing.expectf(t, false, "vertex %d's mask came across as %d", v, k)
			break
		}
	}
	for s in ([]^Sculptor{&a, &b}) {
		testing.expect(t, sculptor_layer_set(s, 0, 0, true))
		_ = sculptor_stroke_end(s)
	}
	for p, v in mb.positions {
		if linalg.length(p - ma.positions[same[v]]) > 1e-4 {
			testing.expectf(t, false, "taking the layer off moved vertex %d differently", v)
			break
		}
	}
}

// Subdivide takes a layer's mask up with its layer, even while it is picked (the sculpt
// mask going up as the mask), and Delete higher brings it back down as it was.
@(test)
layer_masks_go_up_and_down_the_levels :: proc(t: ^testing.T) {
	l: Levels
	levels_init(&l, geom.icosphere(3), nil, 64)
	defer levels_destroy(&l)
	s := &levels_current(&l).sculptor
	_ = sculptor_layer_add(s)
	testing.expect(t, stroke(s, UP))
	testing.expect(t, sculptor_layer_mask_pick(s, 0))
	testing.expect(t, stroke(s, UP, .Mask))
	painted := slice.clone(s.mask, context.temp_allocator)
	testing.expect(t, levels_subdivide(&l, carry_layers = true))
	top := &levels_current(&l).sculptor
	testing.expect(t, top.mask == nil || slice.all_of(top.mask, 0), "the layer's mask went up as the sculpt mask")
	testing.expect(t, len(top.layers.list) == 1 && len(top.layers.list[0].mask) == len(top.mesh.positions))
	testing.expect(t, sculptor_layer_has_mask(top, 0))
	levels_set_current(&l, 0)
	_, _ = levels_delete_higher(&l)
	base := &levels_current(&l).sculptor
	testing.expect(t, len(base.layers.list) == 1)
	if len(base.layers.list) != 1 do return
	testing.expect(t, slice.equal(base.layers.list[0].mask, painted), "the mask came down changed")
}
