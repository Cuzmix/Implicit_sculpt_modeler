package sculpt

import "core:math/linalg"
import "core:testing"

import "../geom"
import "../jobs"

@(private = "file")
FIND_TOP :: Vec3{0, 1, 0}
@(private = "file")
FIND_SIDE :: Vec3{1, 0, 0}

// One stroke of a few dabs at `at` on the unit sphere.
@(private = "file")
find_stroke :: proc(s: ^Sculptor, kind: Brush_Kind, at: Vec3) {
	sculptor_stroke_begin(s)
	for k in 0 ..< 4 do _ = apply_dab(s, {kind = kind, radius = 0.25, strength = 0.6}, linalg.normalize(at + Vec3{0, 0, f32(k) * 0.02}))
	_ = sculptor_stroke_end(s)
}

// The vertex nearest `at`.
@(private = "file")
find_vertex :: proc(s: ^Sculptor, at: Vec3) -> u32 {
	best, d := u32(0), max(f32)
	for p, i in s.mesh.positions do if l := linalg.length(p - at); l < d do best, d = u32(i), l
	return best
}

// Which steps changed the spot, as bools in the order the steps are returned.
@(private = "file")
changed :: proc(steps: []Step_Seen) -> []bool {
	out := make([]bool, len(steps), context.temp_allocator)
	for st, i in steps do out[i] = st.change == .Changed
	return out
}

@(test)
steps_changing_finds_the_strokes_that_moved_a_spot :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	find_stroke(&s, .Draw, FIND_TOP) // 0: on top
	find_stroke(&s, .Draw, FIND_SIDE) // 1: on the side
	find_stroke(&s, .Inflate, FIND_TOP) // 2: on top again
	find_stroke(&s, .Mask, FIND_TOP) // 3: a mask on top, last, so it shields none of them
	top := find_vertex(&s, FIND_TOP)
	steps, ok := sculptor_steps_changing(&s, {top}, context.temp_allocator)
	testing.expect(t, ok, "not ok")
	testing.expect_value(t, len(steps), 4)
	for st, i in steps do testing.expect_value(t, st.id, u64(i + 1))
	c := changed(steps)
	testing.expectf(t, c[0] && !c[1] && c[2] && c[3], "top %v", c)
	side := find_vertex(&s, FIND_SIDE)
	steps, _ = sculptor_steps_changing(&s, {side}, context.temp_allocator)
	c = changed(steps)
	testing.expectf(t, !c[0] && c[1] && !c[2] && !c[3], "side %v", c)
	// Undone steps are found the same way, from after them, and keep their ids and order.
	testing.expect(t, sculptor_undo(&s), "undo")
	testing.expect(t, sculptor_undo(&s), "undo")
	steps, _ = sculptor_steps_changing(&s, {top}, context.temp_allocator)
	testing.expect_value(t, len(steps), 4)
	for st, i in steps do testing.expect_value(t, st.id, u64(i + 1))
	c = changed(steps)
	testing.expectf(t, c[0] && !c[1] && c[2] && c[3], "top after two undos %v", c)
	// A stroke that left the spot as it was is not found, though it saved the node.
	testing.expect(t, sculptor_redo(&s), "redo")
	testing.expect(t, sculptor_redo(&s), "redo")
	far := find_vertex(&s, linalg.normalize(Vec3{-1, -1, -1}))
	steps, _ = sculptor_steps_changing(&s, {far}, context.temp_allocator)
	for st, i in steps do testing.expectf(t, st.change == .Unchanged, "step %d changed a vertex no stroke reached", i)
}

@(test)
steps_changing_is_the_same_on_threads :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, &pool, 64)
	defer sculptor_destroy(&s)
	find_stroke(&s, .Draw, FIND_TOP)
	find_stroke(&s, .Smooth, FIND_TOP)
	find_stroke(&s, .Draw, FIND_SIDE)
	steps, ok := sculptor_steps_changing(&s, {find_vertex(&s, FIND_TOP)}, context.temp_allocator)
	testing.expect(t, ok, "not ok")
	c := changed(steps)
	testing.expectf(t, c[0] && c[1] && !c[2], "top %v", c)
}

@(test)
steps_changing_refuses_while_a_stroke_records :: proc(t: ^testing.T) {
	m := geom.icosphere(4)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	sculptor_stroke_begin(&s)
	_, ok := sculptor_steps_changing(&s, {0}, context.temp_allocator)
	testing.expect(t, !ok, "answered mid-stroke")
	_ = sculptor_stroke_end(&s)
}

@(test)
steps_from_before_a_seal_are_unknown :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	find_stroke(&s, .Draw, FIND_TOP)
	// The levels carried another level's edits here: positions moved that no step holds.
	history_seal(&s.history)
	find_stroke(&s, .Draw, FIND_TOP)
	steps, _ := sculptor_steps_changing(&s, {find_vertex(&s, FIND_TOP)}, context.temp_allocator)
	testing.expect_value(t, steps[0].change, Step_Change.Unknown)
	testing.expect_value(t, steps[1].change, Step_Change.Changed)
}
