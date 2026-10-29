package sculpt

import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

// Hardness keeps the inner share of the radius at full strength and squeezes the falloff
// into the ring outside it: at half hardness the weight three quarters out is the plain
// falloff's half way out, and the rim stays 0.
@(test)
hardness_squeezes_the_falloff :: proc(t: ^testing.T) {
	hard: Falloff
	falloff_set_shaped(&hard, nil, 0, 0.5)
	testing.expect_value(t, hard.table[0], 1)
	testing.expect_value(t, hard.table[FALLOFF_STEPS], 0)
	testing.expectf(t, falloff_drawn(&hard, 0.4 * 0.4) == 1, "inside the hard part: %v", falloff_drawn(&hard, 0.16))
	got, want := falloff_drawn(&hard, 0.75 * 0.75), falloff(0.5 * 0.5)
	testing.expectf(t, abs(got - want) < 0.01, "three quarters out: %v, not %v", got, want)
	for i in 1 ..= FALLOFF_STEPS do testing.expectf(t, hard.table[i] <= hard.table[i - 1], "rises at %d", i)
	// With a drawn curve and a focal shift too, every shape still falls from 1 to 0.
	shaped: Falloff
	falloff_set_shaped(&shaped, geom.CURVE_LINEAR, -40, 0.3)
	testing.expect_value(t, shaped.table[0], 1)
	testing.expect_value(t, shaped.table[FALLOFF_STEPS], 0)
	testing.expectf(t, falloff_drawn(&shaped, 0.25 * 0.25) == 1, "a hard drawn shape at a quarter: %v", falloff_drawn(&shaped, 0.0625))
}

// Projected measures the falloff across the view: a Draw dab at the top of a sphere seen
// from above moves what lies within its radius on screen, more of the sphere than the
// ball does where it curves away, but nothing of the far side; serial and parallel agree.
@(test)
projected_reaches_the_ring_on_screen :: proc(t: ^testing.T) {
	moved :: proc(view: Vec3, pool: ^jobs.Pool) -> (count: int, far: int, out: []Vec3) {
		m := geom.icosphere(5)
		defer geom.mesh_destroy(&m)
		s: Sculptor
		sculptor_init(&s, &m, pool, 64)
		defer sculptor_destroy(&s)
		before := slice.clone(m.positions[:], context.temp_allocator)
		_ = apply_dab(&s, {kind = .Draw, radius = 0.6, strength = 0.5, projected = view}, {0, 0, 1})
		for p, v in m.positions {
			if p == before[v] do continue
			count += 1
			if before[v].z < 0.2 do far += 1
		}
		out = slice.clone(m.positions[:], context.temp_allocator)
		return
	}
	ball, ball_far, _ := moved({}, nil)
	ring, ring_far, serial := moved({0, 0, -1}, nil)
	testing.expectf(t, ring > ball && ball_far == 0 && ring_far == 0, "ball %v (%v far), projected %v (%v far)", ball, ball_far, ring, ring_far)
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	_, _, parallel := moved({0, 0, -1}, &pool)
	testing.expect(t, slice.equal(serial, parallel))
}
