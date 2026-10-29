package sculpt

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

// The point pressed moves exactly by the pull; the pull fades smoothly and nothing past
// ELASTIC_REACH radii moves.
@(test)
elastic_moves_the_press_by_the_pull_and_stops_at_its_reach :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	before := slice.clone(m.positions[:], context.temp_allocator)
	center := m.positions[0]
	radius: f32 = 0.2
	pull := Vec3{0.05, -0.02, 0.08}
	sculptor_stroke_begin(&s)
	_ = sculptor_grab_begin(&s, {kind = .Elastic, radius = radius, strength = 1, volume = 0.8}, center)
	_ = sculptor_grab_move(&s, pull)
	sculptor_grab_end(&s)
	_ = sculptor_stroke_end(&s)
	testing.expectf(t, linalg.length(m.positions[0] - before[0] - pull) < 1e-6, "the press moved %v for a pull of %v", m.positions[0] - before[0], pull)
	far, between: int
	for p, v in m.positions {
		d := linalg.length(before[v] - center)
		moved := p != before[v]
		if d >= ELASTIC_REACH * radius && moved do far += 1
		if d > 1.5 * radius && d < 2 * radius && moved do between += 1
	}
	testing.expectf(t, far == 0 && between > 0, "%d moved past the reach, %d between 1.5 and 2 radii", far, between)
}

// Volume is Poisson's ratio: the more volume the rubber keeps, the more what lies ahead of
// the pull goes with it and the less what lies beside it does, as it thins sideways.
@(test)
elastic_volume_thins_the_sides :: proc(t: ^testing.T) {
	pull := Vec3{1, 0, 0}
	ahead, beside := Vec3{0.2, 0, 0}, Vec3{0, 0.2, 0}
	soft, firm := kelvinlet_make(0.2, 0), kelvinlet_make(0.2, 1)
	soft_ahead, firm_ahead := (kelvinlet_follow(&soft, ahead) * pull).x, (kelvinlet_follow(&firm, ahead) * pull).x
	soft_beside, firm_beside := (kelvinlet_follow(&soft, beside) * pull).x, (kelvinlet_follow(&firm, beside) * pull).x
	testing.expectf(t, firm_ahead > soft_ahead && firm_beside < soft_beside && soft_beside > 0, "ahead %v to %v, beside %v to %v", soft_ahead, firm_ahead, soft_beside, firm_beside)
}

// Elastic gives the same mesh on worker threads as on one, with symmetry: each image
// drags the mirrored way.
@(test)
elastic_parallel_matches_serial :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	run :: proc(pool: ^jobs.Pool) -> []Vec3 {
		m := geom.icosphere(5)
		defer geom.mesh_destroy(&m)
		s: Sculptor
		sculptor_init(&s, &m, pool, 64)
		defer sculptor_destroy(&s)
		sculptor_stroke_begin(&s)
		_ = sculptor_grab_begin(&s, {kind = .Elastic, radius = 0.3, strength = 1, volume = 0.8, symmetry = {.X}}, linalg.normalize(Vec3{0.4, 0.2, 1}))
		_ = sculptor_grab_move(&s, {0.1, 0.05, 0.2})
		sculptor_grab_end(&s)
		_ = sculptor_stroke_end(&s)
		return slice.clone(m.positions[:], context.temp_allocator)
	}
	serial := run(nil)
	testing.expect(t, slice.equal(serial, run(&pool)), "parallel elastic differs from serial")
	// The mirror image moves the mirrored way: the sphere is symmetric across x = 0, so the
	// moved surface is too, a moved vertex's mirror being some vertex's place.
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	checked := 0
	for a in serial {
		if a.x < 0.3 || slice.contains(m.positions[:], a) do continue
		found := false
		for b in serial do if abs(a.x + b.x) < 1e-5 && abs(a.y - b.y) < 1e-5 && abs(a.z - b.z) < 1e-5 {
			found = true
			break
		}
		testing.expectf(t, found, "%v has no mirror", a)
		checked += 1
		if checked >= 50 do break
	}
	testing.expect(t, checked > 0)
}
