package main

import "core:math/linalg"
import "core:testing"

import "../geom"

// A cage object at the origin (scale `scale`) and a curve object of `points` placed at
// `at`, for model_follow_path.
@(private = "file")
follow_pair :: proc(points: []geom.Bezier_Point, closed: bool, at: Vec3, scale: f32 = 1) -> (cage, curve: Object) {
	cage.transform = {scale = scale}
	cp := new(Curve_Part, context.temp_allocator)
	cp.points = make([dynamic]geom.Bezier_Point, context.temp_allocator)
	append(&cp.points, ..points)
	cp.closed = closed
	curve.transform = {position = at, scale = 1}
	curve.curve = cp
	return
}

@(test)
a_followed_curve_starts_at_the_faces_from_its_nearer_end :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	pts := []geom.Bezier_Point{{p = {-1, 0, 0}, radius = 0.1, intensity = 1}, {p = {1, 0, 0}, radius = 0.2, intensity = 1}}
	cage, curve := follow_pair(pts, false, {3, 0, 0})
	// The curve runs from x 2 to 4: its first end is nearer the faces at the origin.
	path, scale := model_follow_path(&cage, &curve, {}, {1, 0, 0})
	testing.expect(t, len(path) >= 2 && len(path) == len(scale))
	testing.expect(t, linalg.length(path[0]) < 1e-5)
	testing.expectf(t, linalg.length(path[len(path) - 1] - {2, 0, 0}) < 1e-3, "end %v", path[len(path) - 1])
	testing.expectf(t, abs(scale[len(scale) - 1] - 2) < 1e-3, "end scale %v", scale[len(scale) - 1])
	// Faces beyond its far end follow it from there, back the other way, narrowing.
	path, scale = model_follow_path(&cage, &curve, {6, 1, 0}, {-1, 0, 0})
	testing.expect(t, linalg.length(path[0] - {6, 1, 0}) < 1e-5)
	testing.expectf(t, linalg.length(path[len(path) - 1] - {4, 1, 0}) < 1e-3, "end %v", path[len(path) - 1])
	testing.expectf(t, abs(scale[len(scale) - 1] - 0.5) < 1e-3, "end scale %v", scale[len(scale) - 1])
}

@(test)
a_followed_curve_is_measured_in_the_cages_space :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	pts := []geom.Bezier_Point{{p = {-1, 0, 0}, radius = 0.1, intensity = 1}, {p = {1, 0, 0}, radius = 0.1, intensity = 1}}
	cage, curve := follow_pair(pts, false, {3, 0, 0}, scale = 2)
	path, scale := model_follow_path(&cage, &curve, {}, {1, 0, 0})
	// Two world units are one of a cage scaled twice; an even radius keeps the size.
	testing.expectf(t, linalg.length(path[len(path) - 1] - {1, 0, 0}) < 1e-3, "end %v", path[len(path) - 1])
	for s in scale do testing.expect(t, abs(s - 1) < 1e-4)
}

@(test)
a_followed_loop_starts_and_ends_at_its_nearest_point :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	pts := make([]geom.Bezier_Point, 4, context.temp_allocator)
	corners := [4]Vec3{{1, 0, 0}, {0, 0, 1}, {-1, 0, 0}, {0, 0, -1}}
	for c, i in corners do pts[i] = {p = c, radius = 0.1, intensity = 1}
	for i in 0 ..< 4 do geom.bezier_make_smooth(pts, true, i)
	cage, curve := follow_pair(pts, true, {0, 2, 0})
	// Faces just beside the loop's -x point start there and come back to it.
	middle := Vec3{-1.5, 2, 0}
	// Faces facing +z leave the loop's -x point toward +z, and stop a piece short of it.
	path, _ := model_follow_path(&cage, &curve, middle, {0, 0, 1})
	testing.expect(t, len(path) > 8)
	testing.expect(t, linalg.length(path[0] - middle) < 1e-5)
	testing.expectf(t, path[1].z > 0, "leaves toward %v", path[1])
	end := path[len(path) - 1]
	testing.expectf(t, end.z < 0 && linalg.length(end - middle) < 0.2, "end %v", end)
	// Facing -z, it goes round the other way.
	back, _ := model_follow_path(&cage, &curve, middle, {0, 0, -1})
	testing.expectf(t, back[1].z < 0, "leaves toward %v", back[1])
	// Half way round it is the loop's far side, two across.
	half := path[len(path) / 2]
	testing.expectf(t, abs(half.x - (middle.x + 2)) < 0.1, "half way %v", half)
}

@(test)
a_curve_with_no_length_gives_no_path :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	pts := []geom.Bezier_Point{{p = {}, radius = 0.1, intensity = 1}, {p = {}, radius = 0.1, intensity = 1}}
	cage, curve := follow_pair(pts, false, {})
	path, _ := model_follow_path(&cage, &curve, {}, {1, 0, 0})
	testing.expect(t, path == nil)
}
