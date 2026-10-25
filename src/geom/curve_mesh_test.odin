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

// Resampling gives even steps with the ends kept; a tube along a straight line is
// closed, faces out, and is as big as a cylinder of its size.
@(test)
curve_tube_along_a_line :: proc(t: ^testing.T) {
	line := floor_line(2)
	even := curve_resample(line, 0.05, 2, context.temp_allocator)
	testing.expect_value(t, len(even), 41)
	testing.expect(t, even[0].p == line[0].p && even[40].p == line[len(line) - 1].p, "the ends moved")
	for i in 1 ..< len(even) {
		step := linalg.length(even[i].p - even[i - 1].p)
		testing.expectf(t, abs(step - 0.05) < 0.005, "step %d is %v", i, step)
	}
	tube, ok := curve_tube(even, 0.1, 0.05, 24)
	defer mesh_destroy(&tube)
	if !testing.expect(t, ok) do return
	_ = expect_closed_manifold(t, tube)
	// A 24-gon's area is a little under the circle's.
	want := f32(0.5 * 24 * math.sin(2 * math.PI / 24)) * 0.01 * 2
	got := mesh_volume(tube)
	testing.expectf(t, abs(got - want) < 0.01 * want, "volume %v, want %v", got, want)
	for p in tube.positions do testing.expectf(t, abs(p.y - 0.05) <= 0.1001, "a vertex at height %v", p.y)
	testing.expect(t, curve_resample(line[:2], 0.05, 0, context.temp_allocator) == nil, "a curve under a step resampled")
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
