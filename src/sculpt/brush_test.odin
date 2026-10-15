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
