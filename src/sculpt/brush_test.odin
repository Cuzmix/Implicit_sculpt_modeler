package sculpt

import "core:math"
import "core:math/linalg"
import "core:testing"

import "../geom"

@(test)
raycast_hits_front_of_sphere :: proc(t: ^testing.T) {
	m := geom.icosphere(3)
	defer geom.mesh_destroy(&m)
	hit, ok := raycast(m, {0, 0, 5}, {0, 0, -1})
	testing.expect(t, ok, "ray missed")
	testing.expect(t, math.abs(hit.z - 1) < 0.01, "hit is not on the near side")
	_, miss := raycast(m, {0, 3, 5}, {0, 0, -1})
	testing.expect(t, !miss, "ray above the sphere should miss")
}

@(test)
draw_dab_raises_only_inside_radius :: proc(t: ^testing.T) {
	m := geom.icosphere(4)
	defer geom.mesh_destroy(&m)
	geom.mesh_sort_vertices_spatially(&m)
	before := make([]Vec3, len(m.positions), context.temp_allocator)
	copy(before, m.positions[:])

	s: Sculptor
	sculptor_init(&s, &m)
	defer sculptor_destroy(&s)

	center := Vec3{0, 0, 1}
	moved := apply_dab(&s, {kind = .Draw, radius = 0.3, strength = 1}, center)
	testing.expect(t, moved > 0, "dab moved nothing")
	for p, i in m.positions {
		dist := linalg.length(before[i] - center)
		if dist >= 0.3 {
			testing.expect_value(t, p, before[i])
		} else if dist < 0.1 {
			testing.expect(t, linalg.length(p) > 1, "vertex near the centre was not pushed out")
		}
	}

	first, count := sculptor_take_dirty(&s)
	testing.expect(t, count > 0 && count < u32(len(m.positions)), "dirty range should be partial")
	for i in 0 ..< u32(len(m.positions)) {
		if m.positions[i] != before[i] {
			testing.expect(t, i >= first && i < first + count, "moved vertex outside dirty range")
		}
	}
	_, again := sculptor_take_dirty(&s)
	testing.expect_value(t, again, 0)
}

@(test)
smooth_dab_reduces_bump :: proc(t: ^testing.T) {
	m := geom.icosphere(4)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m)
	defer sculptor_destroy(&s)

	center := Vec3{0, 0, 1}
	for _ in 0 ..< 5 do apply_dab(&s, {kind = .Draw, radius = 0.25, strength = 1}, center)
	peak_before := max_radius(m)
	for _ in 0 ..< 10 do apply_dab(&s, {kind = .Smooth, radius = 0.4, strength = 1}, center)
	testing.expect(t, max_radius(m) < peak_before, "smoothing did not lower the bump")
}

@(private = "file")
max_radius :: proc(m: geom.Mesh) -> f32 {
	r: f32
	for p in m.positions do r = max(r, linalg.length(p))
	return r
}

@(test)
bvh_raycast_matches_brute_force_after_sculpting :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	geom.mesh_sort_vertices_spatially(&m)
	s: Sculptor
	sculptor_init(&s, &m)
	defer sculptor_destroy(&s)

	// Sculpt a few strong dabs so refit has real work to get right.
	for i in 0 ..< 20 {
		a := f32(i) * 0.3
		apply_dab(&s, {kind = .Draw, radius = 0.3, strength = 1, invert = i % 3 == 0}, linalg.normalize(Vec3{math.cos(a), 0.4, math.sin(a)}))
	}

	misses := 0
	for i in 0 ..< 500 {
		a, b := f32(i) * 0.61803, f32(i) * 0.2914
		origin := 4 * Vec3{math.cos(a) * math.cos(b), math.sin(b), math.sin(a) * math.cos(b)}
		target := Vec3{math.sin(f32(i)), math.cos(f32(i) * 1.3), math.sin(f32(i) * 0.7)} * 1.2
		dir := linalg.normalize(target - origin)
		want, want_ok := raycast(m, origin, dir)
		got, got_ok := sculptor_raycast(&s, origin, dir)
		testing.expect_value(t, got_ok, want_ok)
		if want_ok && got_ok {
			testing.expect(t, linalg.length(got - want) < 1e-4, "BVH hit differs from brute force")
		}
		if !want_ok do misses += 1
	}
	testing.expect(t, misses > 0 && misses < 500, "rays should include hits and misses")
}

@(test)
bvh_gather_matches_linear_scan :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m)
	defer sculptor_destroy(&s)

	center := linalg.normalize(Vec3{0.3, 0.5, 0.8})
	radius: f32 = 0.27
	expected := 0
	for p in m.positions {
		if linalg.length(p - center) < radius do expected += 1
	}
	got := apply_dab(&s, {kind = .Smooth, radius = radius, strength = 0}, center)
	testing.expect_value(t, got, expected)
}
