package main

import "core:math"
import "core:math/linalg"
import "core:testing"

import "../camera"
import "../render"

// Unturned, at full strength and fixed to the camera, the rig is the renderer's default
// exactly, so the default look is unchanged; turning it a quarter to the right swings the
// key light from the viewer's left to the right.
@(test)
lights_default_to_the_renderers_rig :: proc(t: ^testing.T) {
	app: App
	app.camera = camera.orbit_default()
	lights_reset(&app)
	testing.expect_value(t, viewport_lights(&app), render.DEFAULT_LIGHTS)
	key := linalg.normalize([3]f32{-0.5, 0.6, 0.6})
	app.light_turn = 90
	turned := render.lights_turn(viewport_lights(&app), key)
	testing.expectf(t, turned.x > 0.5 && abs(turned.y - key.y) < 1e-5, "turned key %v", turned)
	app.light_height = 30
	testing.expect(t, render.lights_turn(viewport_lights(&app), key).y > turned.y)
}

// Fixing the lights to the scene keeps them where they are for a camera turned about the
// up axis, and they then stay put in the scene while the camera turns further.
@(test)
lights_fixed_to_the_scene_stay_put :: proc(t: ^testing.T) {
	app: App
	app.camera = camera.orbit_default()
	app.camera.yaw = math.to_radians(f32(70))
	app.camera.pitch = 0
	lights_reset(&app)
	app.light_turn = 20
	key := [3]f32{0, 0, 1}
	before := render.lights_turn(viewport_lights(&app), key)
	lights_fix(&app, true)
	testing.expect(t, app.lights_fixed)
	after := render.lights_turn(viewport_lights(&app), key)
	testing.expectf(t, linalg.length(after - before) < 1e-4, "fixing moved the key from %v to %v", before, after)

	// In the scene: the view-space key turned back by the camera's turn is the same.
	world :: proc(app: ^App, dir: [3]f32) -> [3]f32 {
		v := camera.orbit_view(app.camera)
		r := linalg.Matrix3f32{v[0, 0], v[0, 1], v[0, 2], v[1, 0], v[1, 1], v[1, 2], v[2, 0], v[2, 1], v[2, 2]}
		return linalg.transpose(r) * dir
	}
	held := world(&app, after)
	app.camera.yaw += 1.1
	app.camera.pitch = 0.4
	moved := world(&app, render.lights_turn(viewport_lights(&app), key))
	testing.expectf(t, linalg.length(moved - held) < 1e-4, "the key moved in the scene from %v to %v", held, moved)

	lights_fix(&app, false)
	testing.expect(t, !app.lights_fixed)
	testing.expect(t, app.light_turn >= -180 && app.light_turn <= 180)
}
