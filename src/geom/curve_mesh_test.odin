package geom

import "core:math"
import "core:math/linalg"
import "core:testing"

@(private = "file")
mesh_volume :: proc(m: Mesh) -> f32 {
	v: f32
	for i := 0; i < len(m.indices); i += 3 {
		v += linalg.dot(m.positions[m.indices[i]], linalg.cross(m.positions[m.indices[i + 1]], m.positions[m.indices[i + 2]])) / 6
	}
	return v
}

// A drawn line along a flat floor, wobbling, with points bunched unevenly.
@(private = "file")
floor_line :: proc(length: f32) -> []Curve_Point {
	points := make([dynamic]Curve_Point, context.temp_allocator)
	x: f32
	for i := 0; x < length; i += 1 {
		append(&points, Curve_Point{{x, 0, 0.002 * math.sin(f32(i))}, {0, 1, 0}})
		x += 0.01 if i % 3 == 0 else 0.03
	}
	append(&points, Curve_Point{{length, 0, 0}, {0, 1, 0}})
	return points[:]
}

// Stitches and teeth: one closed copy per point, turned to the curve, the teeth on
// alternate sides.
@(test)
curve_place_parts :: proc(t: ^testing.T) {
	even := curve_resample(floor_line(1), 0.1, 0, context.temp_allocator)
	for part_kind in 0 ..< 2 {
		part := curve_stitch_part(0.2) if part_kind == 0 else curve_tooth_part(0.2)
		defer mesh_destroy(&part)
		placed, ok := curve_place(even, part, 0, alternate = part_kind == 1)
		defer mesh_destroy(&placed)
		if !testing.expect(t, ok) do continue
		testing.expect_value(t, len(placed.positions), len(even) * len(part.positions))
		_ = expect_closed_manifold(t, placed)
		testing.expectf(t, abs(mesh_volume(placed) - f32(len(even)) * mesh_volume(part)) < 1e-3 * abs(mesh_volume(placed)), "kind %d: copies change size", part_kind)
		testing.expect(t, mesh_volume(part) > 0, "a part faces in")
		if part_kind == 1 {
			// The first tooth reaches to one side (B = T × N = x × y = z), the second to the other.
			n := len(part.positions)
			sum := [2]f32{}
			for k in 0 ..< 2 do for v in 0 ..< n do sum[k] += placed.positions[k * n + v].z
			testing.expectf(t, sum[0] > 0 && sum[1] < 0, "teeth sides %v", sum)
		}
	}
}
