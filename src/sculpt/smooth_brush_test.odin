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

// Relax moves vertices only across the surface: on a flat square jittered in its plane
// it leaves every vertex in the plane and evens out the edge lengths.
@(test)
smooth_relax_evens_the_spacing_and_keeps_the_shape :: proc(t: ^testing.T) {
	m := flat_square()
	defer geom.mesh_destroy(&m)
	// A fixed jitter of the inner vertices, under a third of the grid step.
	for &p, v in m.positions {
		if p.x <= 0 || p.y <= 0 || p.x >= 0.999 || p.y >= 0.999 do continue
		h := u32(v) * 2654435761
		p.x += (f32(h & 1023) / 1023 - 0.5) * 0.03
		p.y += (f32((h >> 10) & 1023) / 1023 - 0.5) * 0.03
	}
	spread :: proc(m: geom.Mesh) -> f32 {
		lengths := make([dynamic]f32, context.temp_allocator)
		for f in 0 ..< len(m.indices) / 3 {
			a, b := m.positions[m.indices[3 * f]], m.positions[m.indices[3 * f + 1]]
			if linalg.length(a.xy - {0.5, 0.5}) < 0.2 do append(&lengths, linalg.length(a - b))
		}
		mean, sq: f32
		for l in lengths do mean += l
		mean /= f32(len(lengths))
		for l in lengths do sq += (l - mean) * (l - mean)
		return sq / f32(len(lengths))
	}
	before := spread(m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	_ = apply_dab(&s, {kind = .Smooth, radius = 0.35, strength = 1, smooth_mode = .Relax}, {0.5, 0.5, 0})
	off: f32
	for p in m.positions do off = max(off, abs(p.z))
	after := spread(m)
	testing.expectf(t, off < 1e-6 && after < before * 0.7, "off the plane %v; edge spread %v to %v", off, before, after)
}

// Polish takes roughness off a noisy sphere while keeping its volume, where Smooth
// shrinks it; workers give the same mesh as one.
@(test)
smooth_polish_keeps_the_volume :: proc(t: ^testing.T) {
	volume :: proc(m: geom.Mesh) -> f32 {
		v: f32
		for f in 0 ..< len(m.indices) / 3 {
			a, b, c := m.positions[m.indices[3 * f]], m.positions[m.indices[3 * f + 1]], m.positions[m.indices[3 * f + 2]]
			v += linalg.dot(a, linalg.cross(b, c)) / 6
		}
		return v
	}
	run :: proc(mode: Smooth_Mode, pool: ^jobs.Pool) -> (lost, rough: f32, out: []Vec3) {
		m := geom.icosphere(4)
		defer geom.mesh_destroy(&m)
		for &p, v in m.positions {
			h := u32(v) * 2654435761
			p *= 1 + (f32(h & 1023) / 1023 - 0.5) * 0.04
		}
		geom.mesh_recompute_normals(&m)
		start := volume(m)
		s: Sculptor
		sculptor_init(&s, &m, pool, 64)
		defer sculptor_destroy(&s)
		// One dab over the whole sphere, at full strength (four passes), twice.
		for _ in 0 ..< 2 do _ = apply_dab(&s, {kind = .Smooth, radius = 3, strength = 1, smooth_mode = mode}, {0, 0, 1})
		mean: f32
		for p in m.positions do mean += linalg.length(p)
		mean /= f32(len(m.positions))
		for p in m.positions do rough = max(rough, abs(linalg.length(p) - mean))
		return 1 - volume(m) / start, rough, slice.clone(m.positions[:], context.temp_allocator)
	}
	smooth_lost, smooth_rough, _ := run(.Smooth, nil)
	polish_lost, polish_rough, serial := run(.Polish, nil)
	testing.expectf(t, polish_lost < smooth_lost / 3 && polish_rough < 0.02, "volume lost: Smooth %v, Polish %v; roughness: Smooth %v, Polish %v (from 0.02)", smooth_lost, polish_lost, smooth_rough, polish_rough)
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	_, _, parallel := run(.Polish, &pool)
	testing.expect(t, slice.equal(serial, parallel), "parallel Polish differs from serial")
}
