package main

import "core:math"
import "core:math/linalg"
import "core:testing"

import "../camera"
import "../geom"

// Each shape sits round its middle at the size asked: the circle's points on the circle and
// its curve close to it between them, the line's and the spiral's ends at the size, the helix
// from the bottom to the top.
@(test)
curve_shapes_have_their_size :: proc(t: ^testing.T) {
	middle := Vec3{1, 2, 3}
	right, up, back := Vec3{1, 0, 0}, Vec3{0, 1, 0}, Vec3{0, 0, 1}
	size: f32 = 2
	{
		pts, closed := curve_shape_points(.Circle, middle, right, up, back, size, 0.1)
		testing.expect(t, closed, "the circle is open")
		testing.expect_value(t, len(pts), 4)
		for k in 0 ..< 64 {
			u := f32(k) / 16
			d := linalg.length(geom.bezier_at(pts, true, u) - middle)
			testing.expectf(t, abs(d - size) < 0.002 * size, "the circle is %v from its middle at %v", d, u)
		}
	}
	{
		pts, closed := curve_shape_points(.Line, middle, right, up, back, size, 0.1)
		testing.expect(t, !closed && len(pts) == 2, "not a line of two points")
		testing.expectf(t, linalg.length(pts[1].p - pts[0].p - right * 2 * size) < 1e-5, "line from %v to %v", pts[0].p, pts[1].p)
		mid := geom.bezier_at(pts, false, 0.5)
		testing.expectf(t, linalg.length(mid - middle) < 1e-5, "the line bends to %v", mid)
	}
	{
		pts, _ := curve_shape_points(.Spiral, middle, right, up, back, size, 0.1)
		last := pts[len(pts) - 1].p
		testing.expectf(t, abs(linalg.length(last - middle) - size) < 1e-4, "the spiral ends at %v", last)
		for p in pts do testing.expectf(t, abs(linalg.dot(p.p - middle, back)) < 1e-5, "the spiral leaves its plane at %v", p.p)
	}
	{
		pts, _ := curve_shape_points(.Helix, middle, right, up, back, size, 0.1)
		testing.expectf(t, abs(pts[0].p.y - (middle.y - size)) < 1e-4 && abs(pts[len(pts) - 1].p.y - (middle.y + size)) < 1e-4, "the helix runs from %v to %v", pts[0].p, pts[len(pts) - 1].p)
		// Its curve keeps to its cylinder between points.
		for k in 0 ..< 48 {
			q := geom.bezier_at(pts, false, f32(k) / 4) - middle
			r := math.sqrt(q.x * q.x + q.z * q.z)
			testing.expectf(t, abs(r - 0.6 * size) < 0.01 * size, "the helix is %v round at %v", r, k)
		}
	}
	for shape in Curve_Shape {
		pts, _ := curve_shape_points(shape, middle, right, up, back, size, 0.25)
		for p in pts do testing.expect(t, p.radius == 0.25 && p.intensity == 1, "a point's values are not set")
	}
}

// Add › Curve adds a curve object at the view's centre, facing the view, selected, one undo
// step, with its last point picked.
@(test)
curve_shape_added_at_the_view_centre :: proc(t: ^testing.T) {
	app: App
	defer {
		for obj in app.scene.objects {
			curve_part_free(obj)
			delete(obj.name)
			free(obj)
		}
		delete(app.scene.objects)
		curve_tool_destroy(&app.curve)
		history_destroy(&app.history)
		results_destroy(&app)
	}
	app.camera = camera.orbit_default()
	app.camera.target = {0.5, 0.2, -0.3}
	app.ui.viewport_size = {1000, 800}
	app.curve = CURVE_DEFAULTS
	app.brush.radius_px = 40
	testing.expect(t, scene_run(&app, {kind = .Add, curve_shape = .Spiral}), "the command failed")
	obj := selected_object(&app)
	if !object_is_curve(obj) do testing.fail_now(t, "no curve selected")
	testing.expect_value(t, len(obj.curve.points), CURVE_SPIRAL_TURNS * CURVE_TURN_POINTS + 1)
	testing.expect_value(t, app.curve.picked, len(obj.curve.points))
	testing.expect_value(t, len(app.history.done), 1)
	_, _, back := camera.orbit_basis(app.camera)
	for p in obj.curve.points {
		w := to_world(obj.transform, p.p)
		testing.expectf(t, abs(linalg.dot(w - app.camera.target, back)) < 1e-4, "point %v does not face the view", w)
	}
}
