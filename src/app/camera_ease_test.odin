package main

import "core:math"
import "core:testing"

import "../camera"

// The glide's curve: it starts where it was, ends exactly where it was sent, turns each
// angle the shorter way round and zooms by the same factor each step.
@(test)
camera_ease_takes_the_shorter_way :: proc(t: ^testing.T) {
	a := camera.orbit_default()
	b := a
	a.yaw, b.yaw = 3.0, -3.0
	a.distance, b.distance = 1, 4
	b.target = {2, 0, 0}
	mid := camera_ease_at(a, b, 0.5)
	// From 3 to -3 is 0.28 the short way, through pi, not 6 back through 0.
	testing.expectf(t, abs(abs(mid.yaw) - math.PI) < 1e-4, "the yaw went the long way: %v", mid.yaw)
	testing.expectf(t, abs(mid.distance - 2) < 1e-4, "the distance halfway is %v, not 2", mid.distance)
	testing.expectf(t, abs(mid.target.x - 1) < 1e-4, "the target halfway is %v", mid.target)
	testing.expect(t, camera_ease_at(a, b, 1) == b, "the end is not exactly the view sent to")
	start := camera_ease_at(a, b, 0)
	testing.expect(t, abs(start.yaw - a.yaw) < 1e-6 && start.distance == a.distance, "the start moved")
}

// A jump glides from where the camera was, lands exactly on the view asked for, and stops
// where it is under the hand or ends at once for a stroke; with Camera moves off it jumps.
@(test)
camera_ease_glides_and_gives_way :: proc(t: ^testing.T) {
	app: App
	defer free_all(context.temp_allocator)
	app.camera = camera.orbit_default()
	app.camera_ease.allowed = true
	jump :: proc(app: ^App) {
		before := camera_ease_begin(app)
		camera.orbit_axis_view(&app.camera, .Top)
		app.camera.distance = 8
		camera_ease_from(app, before)
	}
	start := app.camera
	jump(&app)
	testing.expect(t, app.camera_ease.on && app.camera == start, "a jump did not start gliding from where it was")
	to := app.camera_ease.to
	app.kit.ctx.time += CAMERA_EASE_TIME / 2
	camera_ease_frame(&app, {})
	testing.expect(t, app.camera != start && app.camera != to && app.camera_ease.on, "halfway it is not between")
	app.kit.ctx.time += CAMERA_EASE_TIME
	camera_ease_frame(&app, {})
	testing.expect(t, !app.camera_ease.on && app.camera == to, "it did not land on the view asked for")

	// A turn on the view stops it where it is.
	app.camera = start
	jump(&app)
	app.kit.ctx.time += CAMERA_EASE_TIME / 2
	camera_ease_frame(&app, {})
	held := app.camera
	camera_ease_frame(&app, {hovered = true, orbit_drag = true, mouse_delta = {4, 0}})
	testing.expect(t, !app.camera_ease.on && app.camera == held, "a turn did not stop the glide where it was")
	testing.expect_value(t, app.camera_ease.cuts, 1)

	// A press that sculpts sends it to the end first.
	app.camera = start
	jump(&app)
	camera_ease_frame(&app, {hovered = true, primary = true})
	testing.expect(t, !app.camera_ease.on && app.camera == app.camera_ease.to, "a stroke did not land on the view asked for")

	// A second jump mid-glide starts from what shows and goes on from where the first went.
	app.camera = start
	jump(&app)
	app.kit.ctx.time += CAMERA_EASE_TIME / 4
	camera_ease_frame(&app, {})
	shown := app.camera
	before := camera_ease_begin(&app)
	testing.expect(t, before == shown && app.camera == app.camera_ease.to, "a second jump did not start from what showed")

	// Camera moves off: a jump lands at once.
	app.kit.ctx.motion_off += {int(Motion_Kind.Camera)}
	app.camera = start
	jump(&app)
	testing.expect(t, !app.camera_ease.on && app.camera.distance == 8, "with Camera moves off it glided")
	testing.expect_value(t, app.camera_ease.eases, 4)
}
