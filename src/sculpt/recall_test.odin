package sculpt

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

@(private = "file")
stroke :: proc(s: ^Sculptor, kind := Brush_Kind.Draw, at := Vec3{0.1, 0.2, 1}, radius: f32 = 0.5) -> bool {
	sculptor_stroke_begin(s)
	for k in 0 ..< 4 do _ = apply_dab(s, {kind = kind, radius = radius, strength = 0.8}, linalg.normalize(at + {0.05 * f32(k), 0, 0}))
	return sculptor_stroke_end(s)
}

// A target built some steps back is, bit for bit, the surface as it was before that
// step; it follows its step through undo and redo and goes with it.
@(test)
recall_is_the_surface_before_a_step :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	testing.expect_value(t, sculptor_recall_reach(&s), 0)
	testing.expect(t, !sculptor_recall_build(&s, 1))
	start := slice.clone(m.positions[:], context.temp_allocator)
	testing.expect(t, stroke(&s))
	second := slice.clone(m.positions[:], context.temp_allocator)
	testing.expect(t, stroke(&s, .Clay, {-0.3, 0.1, 1}))
	testing.expect(t, stroke(&s, .Inflate, {0.2, 0.1, 1}))
	testing.expect(t, stroke(&s, .Mask))
	testing.expect_value(t, sculptor_recall_reach(&s), 4)
	testing.expect(t, sculptor_recall_build(&s, 4))
	testing.expect(t, slice.equal(s.recall, start))
	testing.expect(t, sculptor_recall_build(&s, 3, pinned = true))
	testing.expect(t, slice.equal(s.recall, second))
	testing.expect(t, sculptor_recall_pinned(&s))
	back, ok := sculptor_recall_back(&s)
	testing.expect(t, ok && back == 3)
	testing.expect(t, sculptor_undo(&s))
	back, ok = sculptor_recall_back(&s)
	testing.expect(t, ok && back == 2)
	testing.expect(t, sculptor_undo(&s) && sculptor_undo(&s))
	_, ok = sculptor_recall_back(&s)
	testing.expect(t, !ok)
	testing.expect(t, sculptor_redo(&s))
	back, ok = sculptor_recall_back(&s)
	testing.expect(t, ok && back == 1)
}

// History dabs bring what they reach toward the target and leave the rest of the mesh
// alone; a History stroke is a step like any other, and the target stays where it was.
// Worker threads lay the same.
@(test)
recall_brush_paints_back :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	run :: proc(t: ^testing.T, pool: ^jobs.Pool) -> []Vec3 {
		m := geom.icosphere(6)
		defer geom.mesh_destroy(&m)
		s: Sculptor
		sculptor_init(&s, &m, pool, 64)
		defer sculptor_destroy(&s)
		testing.expect(t, stroke(&s, radius = 0.8))
		testing.expect(t, sculptor_recall_build(&s, 1))
		target := slice.clone(s.recall, context.temp_allocator)
		drawn := slice.clone(m.positions[:], context.temp_allocator)
		testing.expect(t, stroke(&s, .History, radius = 0.3))
		closer := 0
		for p, v in m.positions {
			was := linalg.length(drawn[v] - target[v])
			now := linalg.length(p - target[v])
			testing.expect(t, now <= was + 1e-6)
			if now < was do closer += 1
			if linalg.length(drawn[v] - linalg.normalize(Vec3{0.1, 0.2, 1})) > 0.6 do testing.expect(t, p == drawn[v])
		}
		testing.expect(t, closer > 100)
		testing.expect(t, slice.equal(s.recall, target))
		back, ok := sculptor_recall_back(&s)
		testing.expect(t, ok && back == 2)
		return slice.clone(m.positions[:], context.temp_allocator)
	}
	testing.expect(t, slice.equal(run(t, nil), run(t, &pool)))
}

// Dynamic topology renumbers vertices: no target with it on, and it drops the one built;
// turning it off starts the history afresh. Without a target the brush moves nothing.
@(test)
recall_stops_at_dynamic_topology :: proc(t: ^testing.T) {
	m := geom.icosphere(4)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	testing.expect(t, stroke(&s))
	testing.expect(t, sculptor_recall_build(&s, 1))
	testing.expect(t, sculptor_dyn_enable(&s))
	testing.expect(t, s.recall == nil)
	testing.expect(t, stroke(&s))
	testing.expect_value(t, sculptor_recall_reach(&s), 0)
	sculptor_dyn_disable(&s)
	testing.expect(t, stroke(&s))
	testing.expect_value(t, sculptor_recall_reach(&s), 1)
	testing.expect(t, !stroke(&s, .History))
	testing.expect(t, sculptor_recall_build(&s, 1))
	testing.expect(t, stroke(&s, .History))
}

// Another level's edits carried to this one move it outside its steps, so a build reads
// back no further than the strokes made since.
@(test)
recall_stops_where_another_level_moved_it :: proc(t: ^testing.T) {
	l: Levels
	levels_init(&l, geom.icosphere(3), nil, 64)
	defer levels_destroy(&l)
	testing.expect(t, levels_subdivide(&l))
	top := &l.levels[1].sculptor
	testing.expect(t, stroke(top))
	testing.expect_value(t, sculptor_recall_reach(top), 1)
	testing.expect(t, sculptor_recall_build(top, 1))
	levels_set_current(&l, 0)
	testing.expect(t, stroke(&l.levels[0].sculptor, .Inflate))
	levels_set_current(&l, 1)
	testing.expect_value(t, sculptor_recall_reach(top), 0)
	// The target built before is from before the carried edits: out of reach too.
	_, ok := sculptor_recall_back(top)
	testing.expect(t, !ok)
	testing.expect(t, stroke(top, .Clay))
	testing.expect_value(t, sculptor_recall_reach(top), 1)
	// Going away and back with nothing changed carries nothing, and seals nothing.
	levels_set_current(&l, 0)
	levels_set_current(&l, 1)
	testing.expect_value(t, sculptor_recall_reach(top), 1)
}
