package sculpt

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

// Strength turns into whole passes and a part of one last, four at full strength, as
// Blender's smooth does; Stable's scale can take it to eight, no further.
@(test)
smooth_strength_turns_into_passes :: proc(t: ^testing.T) {
	testing.expect(t, slice.equal(smooth_passes(0.5), []f32{1, 1}))
	p := smooth_passes(0.3)
	testing.expect(t, len(p) == 2 && p[0] == 1 && abs(p[1] - 0.2) < 1e-5)
	testing.expect(t, slice.equal(smooth_passes(1), []f32{1, 1, 1, 1}))
	testing.expect_value(t, len(smooth_passes(5)), SMOOTH_PASSES_HARD)
	testing.expect_value(t, len(smooth_passes(0)), 0)
	testing.expect(t, abs(smooth_stable_scale(0.8, 0.05) - 4) < 1e-5 && abs(smooth_stable_scale(0.4, 0.05) - 1) < 1e-5)
}

// A flat unit square in a grid of 0.05 in the z = 0 plane, its outline an open border.
@(private = "file")
flat_square :: proc() -> (m: geom.Mesh) {
	N :: 21
	for y in 0 ..< N do for x in 0 ..< N do append(&m.positions, Vec3{f32(x) * 0.05, f32(y) * 0.05, 0})
	for y in 0 ..< N - 1 do for x in 0 ..< N - 1 {
		a := u32(y * N + x)
		append(&m.indices, a, a + 1, a + N + 1, a, a + N + 1, a + N)
	}
	resize(&m.normals, len(m.positions))
	geom.mesh_recompute_normals(&m)
	return
}

// On an open border Smooth averages only the neighbours along the border, so the square's
// straight edge stays on its line rather than being pulled in toward the middle.
@(test)
smooth_keeps_an_open_border_on_its_line :: proc(t: ^testing.T) {
	m := flat_square()
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	before := slice.clone(m.positions[:], context.temp_allocator)
	moved := apply_dab(&s, {kind = .Smooth, radius = 0.2, strength = 1}, {0.5, 0, 0})
	testing.expect(t, moved > 0)
	worst: f32
	for p, v in m.positions do if before[v].y == 0 do worst = max(worst, abs(p.y))
	testing.expectf(t, worst < 1e-6, "the bottom edge moved off its line by %v", worst)
}

// Stable gives a dense mesh more passes and a coarse one fewer, so how much a dab
// shrinks a sphere depends less on its density; workers give the same mesh as one.
@(test)
smooth_stable_follows_the_density :: proc(t: ^testing.T) {
	shrink :: proc(subdiv: int, stable: bool, pool: ^jobs.Pool) -> (f32, []Vec3) {
		m := geom.icosphere(subdiv)
		defer geom.mesh_destroy(&m)
		s: Sculptor
		sculptor_init(&s, &m, pool, 64)
		defer sculptor_destroy(&s)
		center := linalg.normalize(Vec3{0.2, 0.3, 1})
		_ = apply_dab(&s, {kind = .Smooth, radius = 0.4, strength = 0.5, smooth_stable = stable}, center)
		most: f32
		for p in m.positions do most = max(most, 1 - linalg.length(p))
		return most, slice.clone(m.positions[:], context.temp_allocator)
	}
	dense, _ := shrink(6, false, nil)
	dense_stable, serial := shrink(6, true, nil)
	coarse, _ := shrink(3, false, nil)
	coarse_stable, _ := shrink(3, true, nil)
	testing.expectf(t, dense_stable > dense && coarse_stable < coarse, "dense %v to %v, coarse %v to %v", dense, dense_stable, coarse, coarse_stable)
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	_, parallel := shrink(6, true, &pool)
	testing.expect(t, slice.equal(serial, parallel), "parallel Stable smoothing differs from serial")
}
