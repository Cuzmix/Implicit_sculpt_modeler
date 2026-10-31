package main

import "core:math"
import "core:testing"

import "../camera"

// The panorama turns with the lights' Turn but not their Height, and only shows while
// Image is picked and one is loaded.
@(test)
environment_turns_but_never_tilts :: proc(t: ^testing.T) {
	app: App
	lights_reset(&app)
	environment_settings_default(&app)
	app.camera = camera.orbit_default()
	flat := environment_rotation(&app)
	app.light_height = 40
	testing.expect_value(t, environment_rotation(&app), flat)
	app.light_turn = 90
	turned := environment_rotation(&app)
	// A quarter turn about the up axis: the panorama's x axis now points along -z or +z,
	// its up axis stays up.
	testing.expectf(t, abs(abs(turned[0].z) - 1) < 1e-5 && abs(turned[1].y - 1) < 1e-5, "%v", turned)
	environment_view(&app)
	testing.expect(t, app.renderer.environment == nil)
	app.env.kind = .Image
	environment_view(&app)
	testing.expect(t, app.renderer.environment == nil, "no panorama is loaded yet")
}

// Its own Turn adds to the lights' Turn all, Tilt leans the up axis, and the drag turn
// wraps round rather than stopping; the recent list keeps each file once, newest first,
// and no more than its length.
@(test)
environment_controls_turn_tilt_and_remember :: proc(t: ^testing.T) {
	app: App
	lights_reset(&app)
	environment_settings_default(&app)
	defer environment_destroy(&app)
	app.camera = camera.orbit_default()
	app.light_turn = 30
	app.env.turn = 60
	by_both := environment_rotation(&app)
	app.light_turn, app.env.turn = 90, 0
	testing.expect_value(t, environment_rotation(&app), by_both)
	app.env.tilt = 30
	leaned := environment_rotation(&app)
	testing.expectf(t, abs(leaned[1].y - math.cos(math.to_radians(f32(30)))) < 1e-5, "%v", leaned)
	testing.expect_value(t, wrap_degrees(190), f32(-170))
	testing.expect_value(t, wrap_degrees(-190), f32(170))
	testing.expect_value(t, wrap_degrees(540), f32(-180))
	app.env.turn = 170
	app.kit.scale = 1
	environment_drag(&app, {-80, 0})
	testing.expectf(t, abs(app.env.turn - (-170)) < 1e-4, "dragged left past 180 it comes round: %v", app.env.turn)
	for name in ([]string{"a.exr", "b.hdr", "a.exr", "c.png", "d.exr", "e.exr", "f.exr"}) do environment_recent_add(&app, name)
	testing.expect_value(t, len(app.env.recent), ENVIRONMENT_RECENT_MAX)
	testing.expect_value(t, app.env.recent[0], "f.exr")
	testing.expect_value(t, app.env.recent[ENVIRONMENT_RECENT_MAX - 1], "a.exr")
	environment_recent_append(&app, "g.exr")
	testing.expect_value(t, len(app.env.recent), ENVIRONMENT_RECENT_MAX)
	app.env.background, app.env.blur = false, 0.3
	testing.expect_value(t, environment_backdrop(&app.env), Environment_Backdrop.Plain)
	app.env.background = true
	testing.expect_value(t, environment_backdrop(&app.env), Environment_Backdrop.Blurred)
	app.env.blur = 0
	testing.expect_value(t, environment_backdrop(&app.env), Environment_Backdrop.Shown)
}
