package geom

import "core:math"
import "core:math/linalg"
import "core:testing"

// Flat square grid of n x n vertices in the z = 0 plane, counter-clockwise from +z.
@(private = "file")
grid :: proc(n: int) -> (positions: [dynamic]Vec3, indices: [dynamic]u32) {
	for y in 0 ..< n do for x in 0 ..< n do append(&positions, Vec3{f32(x), f32(y), 0})
	for y in 0 ..< n - 1 {
		for x in 0 ..< n - 1 {
			a, b := u32(y * n + x), u32(y * n + x + 1)
			c, d := a + u32(n), b + u32(n)
			append(&indices, a, b, d, a, d, c)
		}
	}
	return
}

// Directed edges used by exactly one triangle: the border, and its winding.
@(private = "file")
border_edges :: proc(indices: []u32) -> map[[2]u32]int {
	count := make(map[[2]u32]int, context.temp_allocator)
	for t := 0; t < len(indices); t += 3 {
		for k in 0 ..< 3 do count[{indices[t + k], indices[t + (k + 1) % 3]}] += 1
	}
	border := make(map[[2]u32]int, context.temp_allocator)
	for e, c in count {
		if ([2]u32{e[1], e[0]}) not_in count do border[e] = c
	}
	return border
}

// Largest distance from a vertex of `from` to the surface `to`.
@(private = "file")
distance_to_surface :: proc(positions: []Vec3, from, to: []u32) -> f32 {
	worst: f32
	for v in from {
		p := positions[v]
		best := max(f32)
		for t := 0; t < len(to); t += 3 {
			q, _ := closest_on_triangle(p, positions[to[t]], positions[to[t + 1]], positions[to[t + 2]])
			best = min(best, linalg.length2(q - p))
		}
		worst = max(worst, best)
	}
	return math.sqrt(worst)
}

@(test)
simplify_keeps_a_patch_border :: proc(t: ^testing.T) {
	positions, indices := grid(30)
	defer delete(positions)
	defer delete(indices)
	out: [dynamic]u32
	defer delete(out)
	target := len(indices) / 3 / 4
	error := simplify(positions[:], indices[:], target, &out)

	testing.expectf(t, len(out) / 3 <= target, "%d triangles for a target of %d", len(out) / 3, target)
	testing.expect(t, error < 1e-4, "a flat patch gained error")
	before, after := border_edges(indices[:]), border_edges(out[:])
	testing.expect_value(t, len(after), len(before))
	for e in before do testing.expect(t, e in after, "a border edge was lost")
	for i := 0; i < len(out); i += 3 {
		p0, p1, p2 := positions[out[i]], positions[out[i + 1]], positions[out[i + 2]]
		testing.expect(t, linalg.cross(p1 - p0, p2 - p0).z > 0, "a triangle turned over or collapsed")
	}
}

@(test)
simplify_keeps_a_sphere_closed :: proc(t: ^testing.T) {
	m := icosphere(4)
	defer mesh_destroy(&m)
	out: [dynamic]u32
	defer delete(out)
	target := len(m.indices) / 3 / 4
	error := simplify(m.positions[:], m.indices[:], target, &out)

	testing.expectf(t, len(out) / 3 <= target, "%d triangles for a target of %d", len(out) / 3, target)
	testing.expect_value(t, len(border_edges(out[:])), 0)
	for i := 0; i < len(out); i += 3 {
		p0, p1, p2 := m.positions[out[i]], m.positions[out[i + 1]], m.positions[out[i + 2]]
		testing.expect(t, linalg.dot(linalg.cross(p1 - p0, p2 - p0), p0 + p1 + p2) > 0, "a triangle faces inwards")
	}
	// The coarse sphere stays within its chords' sag of the fine one.
	worst := distance_to_surface(m.positions[:], m.indices[:], out[:])
	testing.expectf(t, worst < 0.01 && error > 0 && error < 0.01, "distance %v, error %v", worst, error)
}

@(test)
simplify_error_tracks_the_distance :: proc(t: ^testing.T) {
	// A sphere with bumps: what simplification removes is the bumps.
	m := icosphere(4)
	defer mesh_destroy(&m)
	for &p in m.positions do p *= 1 + 0.03 * math.sin(9 * p.x) * math.sin(7 * p.y + 1) * math.sin(8 * p.z + 2)
	out: [dynamic]u32
	defer delete(out)
	error := simplify(m.positions[:], m.indices[:], len(m.indices) / 3 / 8, &out)
	worst := distance_to_surface(m.positions[:], m.indices[:], out[:])
	testing.expectf(t, worst <= 3 * error, "the fine surface is %v from the coarse one, error %v", worst, error)
}

@(test)
simplify_leaves_small_inputs_alone :: proc(t: ^testing.T) {
	positions, indices := grid(4)
	defer delete(positions)
	defer delete(indices)
	out: [dynamic]u32
	defer delete(out)
	error := simplify(positions[:], indices[:], 100, &out)
	testing.expect_value(t, error, f32(0))
	testing.expect_value(t, len(out), len(indices))
}
