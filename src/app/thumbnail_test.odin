package main

import "core:math/linalg"
import "core:os"
import "core:testing"

import "../camera"
import "../render"

@(test)
second_view_presets_look_along_their_axis :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	app.camera = camera.orbit_default()
	app.camera.yaw, app.camera.pitch, app.camera.roll = 0.6, 0.35, 0.2

	// Silhouette with the viewport's camera is the zero value, as the thumbnail was.
	testing.expect_value(t, app.kit.second.camera, Second_Camera.Follow)
	testing.expect_value(t, second_view_pass(app.kit.second.pass), render.View_Pass.Silhouette)
	testing.expect_value(t, second_orbit(app, &app.kit.second), app.camera)

	for dir, c in (#partial [Second_Camera][3]f32{.Front = {0, 0, 1}, .Back = {0, 0, -1}, .Right = {1, 0, 0}, .Left = {-1, 0, 0}, .Top = {0, 1, 0}, .Bottom = {0, -1, 0}}) {
		if c == .Follow || c == .Free || c == .Mirror do continue
		app.kit.second.camera = c
		o := second_orbit(app, &app.kit.second)
		got := linalg.normalize(camera.orbit_eye(o) - o.target)
		testing.expectf(t, linalg.dot(got, dir) > 0.999, "%v: eye direction %v", c, got)
		testing.expectf(t, o.ortho && o.roll == 0 && o.distance == app.camera.distance, "%v is not a level orthographic view at the camera's distance", c)
	}
	// The viewport's camera is never turned by the second view's.
	testing.expect_value(t, app.camera.yaw, f32(0.6))

	// Free before any turn starts from what the view showed, then keeps its own.
	app.kit.second.camera = .Top
	top := second_orbit(app, &app.kit.second)
	second_free(app, &app.kit.second)
	testing.expect_value(t, app.kit.second.camera, Second_Camera.Free)
	testing.expect_value(t, second_orbit(app, &app.kit.second), top)
	app.kit.second.orbit.yaw += 1
	second_free(app, &app.kit.second)
	testing.expect_value(t, second_orbit(app, &app.kit.second).yaw, top.yaw + 1)
}

@(test)
second_view_is_remembered_and_reads_the_old_shaded_switch :: proc(t: ^testing.T) {
	path := "build/second_view_test.txt"
	defer os.remove(path)
	a := new(App)
	defer free(a)
	defer results_destroy(a)
	a.kit.second.camera, a.kit.second.pass, a.kit.second.max = .Left, .Curvature, true
	testing.expect(t, settings_save(a, path))
	b := new(App)
	defer free(b)
	defer results_destroy(b)
	settings_load(b, path)
	testing.expect_value(t, b.kit.second.camera, Second_Camera.Left)
	testing.expect_value(t, b.kit.second.pass, Second_Pass.Curvature)
	testing.expect(t, !b.kit.second.max, "a maximised view was remembered")

	// A file from before the passes said Shaded with a switch over the silhouette.
	for test in ([?]struct {
		text: string,
		want: Second_Pass,
	}{{"thumbnail_shaded 1\n", .Shaded}, {"thumbnail_shaded 0\n", .Silhouette}, {"second_pass Normals\n", .Normals}}) {
		testing.expect(t, os.write_entire_file(path, transmute([]u8)test.text) == nil)
		c := new(App)
		defer free(c)
		settings_load(c, path)
		testing.expectf(t, c.kit.second.pass == test.want, "%q: read %v", test.text, c.kit.second.pass)
	}
}
