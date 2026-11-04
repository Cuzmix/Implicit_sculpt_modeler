package main

import "core:math/linalg"
import "core:testing"

import "../camera"
import "../render"

@(test)
second_view_presets_look_along_their_axis :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	app.camera = camera.orbit_default()
	app.camera.yaw, app.camera.pitch, app.camera.roll = 0.6, 0.35, 0.2

	// Silhouette with the viewport's camera is the zero value of a pane's view.
	sv: Second_View
	testing.expect_value(t, sv.camera, Second_Camera.Follow)
	testing.expect_value(t, second_view_pass(sv.pass), render.View_Pass.Silhouette)
	testing.expect_value(t, second_orbit(app, &sv), app.camera)

	for dir, c in (#partial [Second_Camera][3]f32{.Front = {0, 0, 1}, .Back = {0, 0, -1}, .Right = {1, 0, 0}, .Left = {-1, 0, 0}, .Top = {0, 1, 0}, .Bottom = {0, -1, 0}}) {
		if c == .Follow || c == .Free || c == .Mirror do continue
		sv.camera = c
		o := second_orbit(app, &sv)
		got := linalg.normalize(camera.orbit_eye(o) - o.target)
		testing.expectf(t, linalg.dot(got, dir) > 0.999, "%v: eye direction %v", c, got)
		testing.expectf(t, o.ortho && o.roll == 0 && o.distance == app.camera.distance, "%v is not a level orthographic view at the camera's distance", c)
	}
	// The viewport's camera is never turned by the second view's.
	testing.expect_value(t, app.camera.yaw, f32(0.6))

	// Free before any turn starts from what the view showed, then keeps its own.
	sv.camera = .Top
	top := second_orbit(app, &sv)
	second_free(app, &sv)
	testing.expect_value(t, sv.camera, Second_Camera.Free)
	testing.expect_value(t, second_orbit(app, &sv), top)
	sv.orbit.yaw += 1
	second_free(app, &sv)
	testing.expect_value(t, second_orbit(app, &sv).yaw, top.yaw + 1)
}
