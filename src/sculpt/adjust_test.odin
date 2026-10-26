package sculpt

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

@(private = "file")
near :: proc(a, b: []Vec3, eps: f32 = 1e-5) -> bool {
	if len(a) != len(b) do return false
	for p, i in a do if linalg.length(p - b[i]) > eps do return false
	return true
}

@(private = "file")
stroke :: proc(s: ^Sculptor, kind := Brush_Kind.Draw) -> bool {
	sculptor_stroke_begin(s)
	for k in 0 ..< 4 do _ = apply_dab(s, {kind = kind, radius = 0.5, strength = 0.8}, linalg.normalize(Vec3{0.1 * f32(k), 0.2, 1}))
	return sculptor_stroke_end(s)
}

// Adjusting the newest stroke to 0 gives the mesh from before it exactly, to 1 the
// stroke as drawn exactly, and to a half every moved vertex half way; it stays one
// step, which undo takes back to before and redo brings back adjusted. Bounds follow.
@(test)
adjust_sets_a_share_of_the_stroke :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	before := slice.clone(m.positions[:], context.temp_allocator)
	testing.expect(t, !sculptor_can_adjust(&s))
	testing.expect(t, stroke(&s))
	drawn := slice.clone(m.positions[:], context.temp_allocator)
	steps := len(s.history.done)
	testing.expect(t, sculptor_can_adjust(&s))
	testing.expect(t, sculptor_stroke_adjust(&s, 0))
	testing.expect(t, slice.equal(m.positions[:], before))
	testing.expect(t, sculptor_stroke_adjust(&s, 1))
	testing.expect(t, slice.equal(m.positions[:], drawn))
	testing.expect(t, sculptor_stroke_adjust(&s, 0.5))
	half := slice.clone(m.positions[:], context.temp_allocator)
	moved := 0
	for p, v in half {
		if drawn[v] == before[v] do continue
		moved += 1
		testing.expect(t, linalg.length(p - (before[v] + drawn[v]) * 0.5) < 1e-6)
	}
	testing.expect(t, moved > 100)
	testing.expect_value(t, len(s.history.done), steps)
	// The BVH finds the adjusted surface: a ray down the pole meets it where it is now.
	_ = sculptor_flush(&s)
	hit, _, ok := geom.bvh_raycast(&s.bvh, m, {0.02, 0.04, 3}, {0, 0, -1}, nil)
	testing.expect(t, ok)
	top: f32 = -1
	for p in half do if linalg.length(p.xy - [2]f32{0.02, 0.04}) < 0.03 do top = max(top, p.z)
	testing.expect(t, abs(3 - hit - top) < 0.02)
	bytes := sculptor_undo_bytes(&s)
	testing.expect(t, sculptor_undo(&s))
	testing.expect(t, slice.equal(m.positions[:], before))
	testing.expect(t, sculptor_undo_bytes(&s) < bytes)
	testing.expect(t, !sculptor_can_adjust(&s))
	testing.expect(t, sculptor_redo(&s))
	testing.expect(t, slice.equal(m.positions[:], half))
	// Redone, it is the newest again and adjusts from what it now is.
	testing.expect(t, sculptor_stroke_adjust(&s, 0))
	testing.expect(t, slice.equal(m.positions[:], before))
}

// Masks and colours adjust the same way, rounded and kept within a byte; on worker
// threads an adjust lays the same.
@(test)
adjust_masks_colours_and_threads :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	run :: proc(t: ^testing.T, pool: ^jobs.Pool) -> (positions: []Vec3, masks: []u8, colors: []Color) {
		m := geom.icosphere(6)
		defer geom.mesh_destroy(&m)
		s: Sculptor
		sculptor_init(&s, &m, pool, 64)
		defer sculptor_destroy(&s)
		testing.expect(t, stroke(&s))
		testing.expect(t, sculptor_stroke_adjust(&s, 1.7))
		positions = slice.clone(m.positions[:], context.temp_allocator)
		testing.expect(t, stroke(&s, .Mask))
		before := slice.clone(s.mask, context.temp_allocator)
		testing.expect(t, sculptor_stroke_adjust(&s, 2))
		for k, v in s.mask do testing.expect(t, k >= before[v] || before[v] == 0)
		testing.expect(t, sculptor_stroke_adjust(&s, 0.25))
		masks = slice.clone(s.mask, context.temp_allocator)
		testing.expect(t, stroke(&s, .Paint))
		testing.expect(t, sculptor_stroke_adjust(&s, 0.5))
		colors = slice.clone(s.color, context.temp_allocator)
		return
	}
	p1, m1, c1 := run(t, nil)
	p2, m2, c2 := run(t, &pool)
	testing.expect(t, slice.equal(p1, p2))
	testing.expect(t, slice.equal(m1, m2))
	testing.expect(t, slice.equal(c1, c2))
	masked := 0
	for k in m1 do masked += int(k > 0)
	testing.expect(t, masked > 0)
}

// A stroke recorded into a sculpt layer adjusts the layer's displacement with the
// surface, so turning the layer off afterwards still leaves the base as it was.
@(test)
adjust_follows_a_recording_layer :: proc(t: ^testing.T) {
	m := geom.icosphere(4)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	base := slice.clone(m.positions[:], context.temp_allocator)
	testing.expect_value(t, sculptor_layer_add(&s), 0)
	testing.expect(t, stroke(&s))
	testing.expect(t, sculptor_stroke_adjust(&s, 0.4))
	testing.expect(t, sculptor_layer_set(&s, 0, 0, true))
	testing.expect(t, near(m.positions[:], base))
}

// What cannot be adjusted is refused: nothing done yet, a hiding step, and any step under
// dynamic topology.
@(test)
adjust_refuses_other_steps :: proc(t: ^testing.T) {
	m := geom.icosphere(4)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	testing.expect(t, !sculptor_stroke_adjust(&s, 0.5))
	testing.expect(t, stroke(&s, .Mask))
	testing.expect(t, sculptor_hide_command(&s, .Masked))
	testing.expect(t, !sculptor_can_adjust(&s))
	testing.expect(t, sculptor_dyn_enable(&s))
	defer sculptor_dyn_disable(&s)
	testing.expect(t, stroke(&s))
	testing.expect(t, !sculptor_stroke_adjust(&s, 0.5))
}

// An adjusted stroke on a subdivision level reaches the levels below as an adjust: set
// to nothing, the base comes back as it was; left as drawn, the base moves.
@(test)
adjust_reaches_the_other_levels :: proc(t: ^testing.T) {
	run :: proc(t: ^testing.T, k: f32) -> (moved: f32) {
		l: Levels
		levels_init(&l, geom.icosphere(3), nil, 64)
		defer levels_destroy(&l)
		testing.expect(t, levels_subdivide(&l))
		base := slice.clone(l.levels[0].mesh.positions[:], context.temp_allocator)
		s := &l.levels[1].sculptor
		testing.expect(t, stroke(s))
		testing.expect(t, sculptor_stroke_adjust(s, k))
		levels_set_current(&l, 0)
		for p, v in l.levels[0].mesh.positions do moved = max(moved, linalg.length(p - base[v]))
		return
	}
	testing.expect(t, run(t, 0) < 1e-5)
	testing.expect(t, run(t, 1) > 0.01)
}

// The undo memory counts an adjust's copy for as long as it is kept: the count is the
// sum of the steps' own through adjusting, undo, redo, a newer stroke and a trim to the
// limit, and a newer stroke drops the copy of the step it covers.
@(test)
adjust_keeps_the_undo_memory_count :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	counted :: proc(s: ^Sculptor) -> bool {
		bytes := 0
		for step in s.history.done do bytes += step_bytes(step)
		for step in s.history.undone do bytes += step_bytes(step)
		return bytes == s.history.bytes
	}
	testing.expect(t, stroke(&s))
	plain := sculptor_undo_bytes(&s)
	testing.expect(t, sculptor_stroke_adjust(&s, 0.5))
	testing.expect(t, counted(&s) && sculptor_undo_bytes(&s) > plain)
	testing.expect(t, sculptor_undo(&s) && counted(&s))
	testing.expect(t, sculptor_redo(&s) && counted(&s))
	testing.expect(t, sculptor_stroke_adjust(&s, 1.5))
	testing.expect(t, stroke(&s, .Mask))
	testing.expect(t, counted(&s) && !s.history.done[0].adjusting)
	testing.expect(t, sculptor_stroke_adjust(&s, 0.2))
	// A limit that holds only one step: a newer stroke drops the older ones, and the one
	// left still adjusts, its copy counted.
	s.history.limit = step_bytes(s.history.done[len(s.history.done) - 1]) + 1
	testing.expect(t, stroke(&s))
	testing.expect_value(t, len(s.history.done), 1)
	testing.expect(t, sculptor_stroke_adjust(&s, 0))
	testing.expect(t, counted(&s) && s.history.done[0].adjusting)
	sculptor_clear_history(&s)
	testing.expect_value(t, sculptor_undo_bytes(&s), 0)
}
