package main

import "core:math"
import "core:math/linalg"
import "core:testing"

import "../camera"
import "../geom"
import "../sculpt"

@(private = "file")
PLANE_SIZE :: [2]f32{1000, 800}

// A selected sphere of radius 1 at the origin with no GPU buffers, and the Curve tool on
// with its Curve kind and `plane`.
@(private = "file")
plane_scene :: proc(app: ^App, plane: Curve_Plane) {
	obj := new(Object)
	obj.id = 1
	obj.transform = {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(4), nil, 64)
	append(&app.scene.objects, obj)
	app.scene.selected, app.scene.next_id = 0, 1
	app.camera = camera.orbit_default()
	app.tool = .Curve
	app.curve = CURVE_DEFAULTS
	app.curve.kind = .Curve
	app.curve.plane = plane
	app.brush.radius_px = 40
}

@(private = "file")
plane_scene_free :: proc(app: ^App) {
	for obj in app.scene.objects {
		curve_part_free(obj)
		sculpt.levels_destroy(&obj.levels)
		delete(obj.name)
		delete(obj.group_materials)
		free(obj)
	}
	delete(app.scene.objects)
	curve_tool_destroy(&app.curve)
	history_destroy(&app.history)
	results_destroy(app)
}

@(private = "file")
plane_press :: proc(app: ^App, p: [2]f32, held, press: bool) {
	_ = curve_tool_frame(app, {size = PLANE_SIZE, mouse_pos = p, hovered = true, primary = held, press = press})
}

@(private = "file")
plane_tap :: proc(app: ^App, p: [2]f32) {
	plane_press(app, p, true, true)
	plane_press(app, p, false, false)
}

// The world positions of the selected curve's points.
@(private = "file")
plane_points :: proc(app: ^App) -> []Vec3 {
	obj := selected_object(app)
	if !object_is_curve(obj) do return nil
	out := make([]Vec3, len(obj.curve.points), context.temp_allocator)
	for p, i in obj.curve.points do out[i] = to_world(obj.transform, p.p)
	return out
}

// With Surface, a drag that never touches the model still makes a curve, on the plane
// facing the view through the view's centre (before, it made nothing).
@(test)
curve_drag_off_the_model_lands_on_the_view_plane :: proc(t: ^testing.T) {
	app: App
	defer plane_scene_free(&app)
	plane_scene(&app, .Surface)
	for i in 0 ..= 40 {
		x := 40 + f32(i) * 4
		y := 120 + 40 * math.sin(f32(i) / 8)
		plane_press(&app, {x, y}, true, i == 0)
	}
	plane_press(&app, {200, 120}, false, false)
	pts := plane_points(&app)
	testing.expectf(t, len(pts) >= 2, "%d points", len(pts))
	toward := camera.orbit_toward(app.camera, app.camera.target)
	for p in pts do testing.expectf(t, abs(linalg.dot(p - app.camera.target, toward)) < 1e-3, "point %v is off the view plane by %v (%v)", p, linalg.dot(p - app.camera.target, toward), pts)
}

// Taps on the floor with Floor land at the floor grid's height (the sphere's bottom), on
// the model or off it, and Enter makes them a curve.
@(test)
curve_taps_land_on_the_floor :: proc(t: ^testing.T) {
	app: App
	defer plane_scene_free(&app)
	plane_scene(&app, .Floor)
	for p in ([3][2]f32{{300, 650}, {500, 400}, {700, 700}}) do plane_tap(&app, p)
	testing.expect_value(t, len(app.curve.placing), 3)
	curve_place_finish(&app, false)
	pts := plane_points(&app)
	testing.expect_value(t, len(pts), 3)
	for p in pts do testing.expectf(t, abs(p.y + 1) < 0.02, "point %v is not on the floor", p)
}

// Front keeps every point at the view centre's depth along Z; a point dragged later moves
// on the same plane through where it is.
@(test)
curve_front_plane_keeps_z :: proc(t: ^testing.T) {
	app: App
	defer plane_scene_free(&app)
	plane_scene(&app, .Front)
	app.camera.target = {0, 0, 0.5}
	for p in ([3][2]f32{{100, 100}, {200, 700}, {900, 150}}) do plane_tap(&app, p)
	curve_place_finish(&app, false)
	pts := plane_points(&app)
	testing.expect_value(t, len(pts), 3)
	for p in pts do testing.expectf(t, abs(p.z - 0.5) < 1e-3, "point %v is off the front plane", p)
	moved, _, ok := curve_land(&app, {800, 600}, PLANE_SIZE, pts[1])
	testing.expect(t, ok, "no landing")
	testing.expectf(t, abs(moved.z - 0.5) < 1e-3, "dragged point %v left the plane", moved)
}

// A plane seen edge on (the floor from a level camera) gives way to the plane facing the
// view, so a tap still lands, and near the view's centre.
@(test)
curve_edge_on_plane_falls_back_to_the_view :: proc(t: ^testing.T) {
	app: App
	defer plane_scene_free(&app)
	plane_scene(&app, .Floor)
	app.camera.pitch = 0
	origin, dir := mouse_ray(app.camera, PLANE_SIZE * 0.5, PLANE_SIZE)
	p, n, ok := curve_plane_hit(&app, origin, dir, .Floor, app.camera.target)
	testing.expect(t, ok, "no landing")
	testing.expectf(t, linalg.length(p - app.camera.target) < 1e-3, "landed at %v", p)
	testing.expectf(t, abs(n.y) < 0.5, "kept the floor's normal %v", n)
}
