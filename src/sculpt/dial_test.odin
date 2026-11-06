package sculpt

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

// One stroke of a few dabs at `at` on the unit sphere.
@(private = "file")
dial_stroke :: proc(s: ^Sculptor, kind: Brush_Kind, at: Vec3) {
	sculptor_stroke_begin(s)
	for k in 0 ..< 4 do _ = apply_dab(s, {kind = kind, radius = 0.25, strength = 0.6}, linalg.normalize(at + Vec3{0, 0, f32(k) * 0.02}))
	_ = sculptor_stroke_end(s)
}

@(private = "file")
DIAL_TOP :: Vec3{0, 1, 0}
@(private = "file")
DIAL_SIDE :: Vec3{1, 0, 0}

@(private = "file")
positions_of :: proc(s: ^Sculptor) -> []Vec3 {
	_ = sculptor_flush(s)
	return slice.clone(s.mesh.positions[:], context.temp_allocator)
}

@(test)
dial_at_zero_takes_the_newest_step_away_exactly :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	dial_stroke(&s, .Draw, DIAL_TOP)
	before := positions_of(&s)
	dial_stroke(&s, .Draw, DIAL_TOP)
	after := positions_of(&s)
	verts, refusal := sculptor_dial_begin(&s, 1, 1)
	testing.expect_value(t, refusal, Dial_Refusal.None)
	testing.expect(t, verts > 0, "moves nothing")
	testing.expect(t, sculptor_dial_set(&s, 0), "set")
	testing.expect(t, slice.equal(positions_of(&s), before), "at 0 the stroke is not gone")
	testing.expect(t, sculptor_dial_set(&s, 1), "set")
	testing.expect(t, slice.equal(positions_of(&s), after), "at 1 the mesh is not as it was")
	testing.expect(t, sculptor_dial_set(&s, 0.5), "set")
	half := positions_of(&s)
	testing.expect(t, sculptor_dial_end(&s), "the dial made no step")
	testing.expect_value(t, len(s.history.done), 3)
	// Undo puts back the mesh as the dial found it, and redo the dial's half.
	testing.expect(t, sculptor_undo(&s), "undo")
	testing.expect(t, slice.equal(positions_of(&s), after), "undo of the dial")
	testing.expect(t, sculptor_redo(&s), "redo")
	testing.expect(t, slice.equal(positions_of(&s), half), "redo of the dial")
}

@(test)
dial_rides_later_strokes_on_the_change :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	dial_stroke(&s, .Draw, DIAL_TOP)
	a := positions_of(&s)
	dial_stroke(&s, .Inflate, DIAL_TOP)
	b := positions_of(&s)
	dial_stroke(&s, .Draw, DIAL_TOP + Vec3{0.1, 0, 0})
	dial_stroke(&s, .Draw, DIAL_SIDE)
	live := positions_of(&s)
	// The middle stroke, the Inflate, dialled out: what it moved comes off the strokes made
	// after it, as a layer taken away would.
	_, refusal := sculptor_dial_begin(&s, 3, 3)
	testing.expect_value(t, refusal, Dial_Refusal.None)
	_ = sculptor_dial_set(&s, 0)
	got := positions_of(&s)
	for p, v in got {
		want := live[v] + (0 - 1) * (b[v] - a[v])
		// Where no later step saved the node, the dial goes back to the stroke's before
		// exactly; elsewhere it takes its change off what came after.
		if b[v] == a[v] do want = live[v]
		if p != want && p != a[v] {
			testing.expectf(t, false, "vertex %d: %v, want %v or %v", v, p, want, a[v])
			break
		}
	}
	testing.expect(t, !slice.equal(got, live), "the dial moved nothing")
	sculptor_dial_cancel(&s)
	testing.expect(t, slice.equal(positions_of(&s), live), "cancel did not put the mesh back")
	testing.expect_value(t, len(s.history.done), 4)
}

@(test)
dial_is_the_same_on_threads :: proc(t: ^testing.T) {
	run :: proc(pool: ^jobs.Pool) -> []Vec3 {
		m := geom.icosphere(5)
		defer geom.mesh_destroy(&m)
		s: Sculptor
		sculptor_init(&s, &m, pool, 64)
		defer sculptor_destroy(&s)
		dial_stroke(&s, .Draw, DIAL_TOP)
		dial_stroke(&s, .Clay, DIAL_TOP)
		dial_stroke(&s, .Draw, DIAL_TOP)
		_, _ = sculptor_dial_begin(&s, 3, 2)
		_ = sculptor_dial_set(&s, 1.37)
		_ = sculptor_dial_end(&s)
		return positions_of(&s)
	}
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	testing.expect(t, slice.equal(run(nil), run(&pool)), "serial and parallel differ")
}

@(test)
dial_refuses_what_it_cannot_share_out :: proc(t: ^testing.T) {
	m := geom.icosphere(4)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	_, refusal := sculptor_dial_begin(&s, 1, 1)
	testing.expect_value(t, refusal, Dial_Refusal.Reach)
	dial_stroke(&s, .Mask, DIAL_TOP)
	_, refusal = sculptor_dial_begin(&s, 1, 1)
	testing.expect_value(t, refusal, Dial_Refusal.Nothing)
	dial_stroke(&s, .Draw, DIAL_TOP)
	s.history.limit = 64
	_, refusal = sculptor_dial_begin(&s, 1, 1)
	testing.expect_value(t, refusal, Dial_Refusal.Memory)
	s.history.limit = UNDO_LIMIT_BYTES
	history_seal(&s.history)
	_, refusal = sculptor_dial_begin(&s, 1, 1)
	testing.expect_value(t, refusal, Dial_Refusal.Reach)
	dial_stroke(&s, .Draw, DIAL_SIDE)
	_, refusal = sculptor_dial_begin(&s, 1, 1)
	testing.expect_value(t, refusal, Dial_Refusal.None)
	// A stroke beginning closes it as if it never opened.
	before := positions_of(&s)
	_ = sculptor_dial_set(&s, 0)
	sculptor_stroke_begin(&s)
	testing.expect(t, !s.dial.active, "still open")
	testing.expect(t, slice.equal(s.mesh.positions[:], before), "the stroke began on the dialled mesh")
	_ = sculptor_stroke_end(&s)
}
