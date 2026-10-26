package main

import "core:testing"

import "../camera"

// Runs frames of `dt` on the interface's clock for `seconds`.
@(private = "file")
rest :: proc(app: ^App, seconds: f64, dt := 1.0 / 60) {
	for t := 0.0; t < seconds; t += dt {
		app.kit.ctx.time += dt
		camera_history_frame(app)
	}
}

@(private = "file")
turn :: proc(app: ^App, yaw: f32) {
	app.camera.yaw = yaw
	camera_history_frame(app)
}

// A view counts once the camera has rested, not while a drag turns it or before the rest
// is over; back and forward walk the views kept, and a new view drops those ahead.
@(test)
camera_history_keeps_rested_views :: proc(t: ^testing.T) {
	app: App
	app.camera = camera.orbit_default()
	rest(&app, 1)
	testing.expect_value(t, app.views.count, 1)
	// A drag held still is no view.
	app.drag.owner = .Orbit
	turn(&app, 1)
	rest(&app, 1)
	testing.expect_value(t, app.views.count, 1)
	// Let go after holding it still that long, it has rested already.
	app.drag.owner = .None
	rest(&app, 0.05)
	testing.expect_value(t, app.views.count, 2)
	// Not before the rest is over.
	turn(&app, 2)
	rest(&app, 0.2)
	testing.expect_value(t, app.views.count, 2)
	rest(&app, 0.3)
	testing.expect_value(t, app.views.count, 3)
	camera_back(&app)
	testing.expect_value(t, app.camera.yaw, 1)
	camera_back(&app)
	testing.expect_value(t, app.camera.yaw, camera.orbit_default().yaw)
	testing.expect(t, !camera_can_back(&app))
	// Showing a view is no move: resting on it keeps nothing new.
	rest(&app, 1)
	testing.expect_value(t, app.views.count, 3)
	camera_forward(&app)
	testing.expect_value(t, app.camera.yaw, 1)
	// A new view from here drops the one ahead (yaw 2).
	turn(&app, 3)
	testing.expect(t, !camera_can_forward(&app))
	rest(&app, 1)
	testing.expect_value(t, app.views.count, 3)
	testing.expect_value(t, app.views.views[2].yaw, 3)
	testing.expect_value(t, app.views.steps, 3)
}

// Going back from a view not kept yet keeps it first, so forward comes back to it.
@(test)
camera_back_keeps_the_view_it_leaves :: proc(t: ^testing.T) {
	app: App
	app.camera = camera.orbit_default()
	rest(&app, 1)
	turn(&app, 1)
	testing.expect(t, camera_can_back(&app))
	camera_back(&app)
	testing.expect_value(t, app.camera.yaw, camera.orbit_default().yaw)
	testing.expect_value(t, app.views.count, 2)
	camera_forward(&app)
	testing.expect_value(t, app.camera.yaw, 1)
}

// Past CAMERA_VIEWS the oldest goes; clearing forgets them all.
@(test)
camera_history_drops_the_oldest :: proc(t: ^testing.T) {
	app: App
	app.camera = camera.orbit_default()
	for i in 0 ..< CAMERA_VIEWS + 5 {
		turn(&app, f32(i))
		rest(&app, 0.5)
	}
	testing.expect_value(t, app.views.count, CAMERA_VIEWS)
	testing.expect_value(t, app.views.views[0].yaw, 5)
	testing.expect_value(t, app.views.views[CAMERA_VIEWS - 1].yaw, f32(CAMERA_VIEWS + 4))
	camera_history_clear(&app)
	testing.expect_value(t, app.views.count, 0)
	testing.expect(t, !camera_can_back(&app))
}
