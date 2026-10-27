package main

import "core:math"
import "core:math/linalg"
import "core:os"
import "core:testing"

import "../camera"
import "../render"

@(private = "file")
near :: proc(a, b: [3]f32, eps: f32 = 1e-5) -> bool {
	return linalg.length(a - b) < eps
}

// Reset, the lights are the renderer's default: the key and fill on, the other two off,
// all white, full ambient light, the studio unturned. Turning the set a quarter to the
// right swings the key light from the viewer's left to the right.
@(test)
lights_default_to_the_renderers_lights :: proc(t: ^testing.T) {
	app: App
	app.camera = camera.orbit_default()
	lights_reset(&app)
	got, want := viewport_lights(&app), render.lights_default()
	for c in 0 ..< 3 do testing.expectf(t, linalg.length(got.rig[c] - want.rig[c]) < 1e-6, "studio column %d: %v against %v", c, got.rig[c], want.rig[c])
	for i in 0 ..< LIGHT_COUNT {
		testing.expectf(t, abs(got.dir[i].w - want.dir[i].w) < 1e-6, "light %d strength %v against %v", i + 1, got.dir[i].w, want.dir[i].w)
		if want.dir[i].w > 0 do testing.expectf(t, near(got.dir[i].xyz, want.dir[i].xyz), "light %d at %v against %v", i + 1, got.dir[i].xyz, want.dir[i].xyz)
		testing.expect_value(t, got.color[i], want.color[i])
	}
	key := light_view_dir(&app, 0)
	app.light_turn = 90
	turned := light_view_dir(&app, 0)
	testing.expectf(t, turned.x > 0.5 && abs(turned.y - key.y) < 1e-5, "turned key %v", turned)
	app.light_height = 30
	testing.expect(t, light_view_dir(&app, 0).y > turned.y)
	// Lights that are off send no strength; the colour goes through as it is.
	app.lights[0].on = false
	app.lights[1].color = {1, 0.5, 0.25}
	l := viewport_lights(&app)
	testing.expect_value(t, l.dir[0].w, 0)
	testing.expect_value(t, l.color[1], [4]f32{1, 0.5, 0.25, 0})
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
	before := light_view_dir(&app, 0)
	lights_fix(&app, true)
	testing.expect(t, app.lights_fixed)
	after := light_view_dir(&app, 0)
	testing.expectf(t, near(after, before, 1e-4), "fixing moved the key from %v to %v", before, after)

	// In the scene: the view-space key turned back by the camera's turn is the same.
	world :: proc(app: ^App, dir: [3]f32) -> [3]f32 {
		v := camera.orbit_view(app.camera)
		r := linalg.Matrix3f32{v[0, 0], v[0, 1], v[0, 2], v[1, 0], v[1, 1], v[1, 2], v[2, 0], v[2, 1], v[2, 2]}
		return linalg.transpose(r) * dir
	}
	held := world(&app, after)
	app.camera.yaw += 1.1
	app.camera.pitch = 0.4
	moved := world(&app, light_view_dir(&app, 0))
	testing.expectf(t, near(moved, held, 1e-4), "the key moved in the scene from %v to %v", held, moved)

	lights_fix(&app, false)
	testing.expect(t, !app.lights_fixed)
	testing.expect(t, app.light_turn >= -180 && app.light_turn <= 180)
}

// The sphere places a light as the camera sees it, whatever the set's turn or the
// camera: a point on the sphere is where the light then shows, on the side it was on; a
// point past the outline is pulled onto it; a flip sends it behind at the same place.
@(test)
the_light_sphere_places_lights_as_the_camera_sees_them :: proc(t: ^testing.T) {
	app: App
	app.camera = camera.orbit_default()
	app.camera.yaw = 0.8
	app.camera.pitch = -0.3
	lights_reset(&app)
	app.light_turn, app.light_height = 35, -20
	lights_fix(&app, true)

	d := light_sphere_dir({0.3, 0.4}, true)
	testing.expectf(t, near(d, {0.3, 0.4, math.sqrt(f32(0.75))}), "front point %v", d)
	testing.expectf(t, light_sphere_dir({0.3, 0.4}, false).z < 0, "behind")
	edge := light_sphere_dir({3, 4}, true)
	testing.expectf(t, near(edge, {0.6, 0.8, 0}), "past the outline %v", edge)

	light_set_view_dir(&app, 2, d)
	testing.expectf(t, near(light_view_dir(&app, 2), d), "light 3 shows at %v, placed at %v", light_view_dir(&app, 2), d)
	light_flip(&app, 2)
	flipped := light_view_dir(&app, 2)
	testing.expectf(t, near(flipped, {d.x, d.y, -d.z}), "flipped to %v", flipped)
	light_flip(&app, 2)
	testing.expect(t, near(light_view_dir(&app, 2), d))

	// A direction set to nothing (a script setting it number by number) is its default's.
	app.lights[3].dir = {}
	app.lights_fixed, app.light_turn, app.light_height = false, 0, 0
	testing.expect(t, near(light_view_dir(&app, 3), linalg.normalize(LIGHTS_DEFAULT[3].dir)))
}

// A press picks the nearest light that is on within the reach of a finger; lights that
// are off have no marker to press.
@(test)
the_light_sphere_picks_the_nearest_light :: proc(t: ^testing.T) {
	app: App
	app.camera = camera.orbit_default()
	lights_reset(&app)
	centre, radius := [2]f32{100, 100}, f32(80)
	key := light_marker(&app, 0, centre, radius)
	testing.expect_value(t, light_sphere_hit(&app, centre, radius, key + {5, 5}, 22), 0)
	testing.expect_value(t, light_sphere_hit(&app, centre, radius, light_marker(&app, 1, centre, radius), 22), 1)
	testing.expect_value(t, light_sphere_hit(&app, centre, radius, centre, 22), -1)
	testing.expect_value(t, light_sphere_hit(&app, centre, radius, light_marker(&app, 2, centre, radius), 22), -1)
	app.lights[2].on = true
	testing.expect_value(t, light_sphere_hit(&app, centre, radius, light_marker(&app, 2, centre, radius), 22), 2)
}

// The settings file keeps every light, its colour and the ambient light; a file from
// before the four lights keeps its key and fill strengths, the fill's as the share of
// its full strength it was.
@(test)
lights_are_remembered :: proc(t: ^testing.T) {
	path := "build/lights_test.txt"
	defer os.remove(path)
	a: App
	defer results_destroy(&a)
	lights_reset(&a)
	a.lights[2] = {on = true, dir = linalg.normalize([3]f32{0.2, -0.5, -0.6}), strength = 1.4, color = {0.9, 0.3, 0.1}}
	a.lights[0].on = false
	a.light_ambient = 0.4
	testing.expect(t, settings_save(&a, path))
	b: App
	defer results_destroy(&b)
	lights_reset(&b)
	settings_load(&b, path)
	for i in 0 ..< LIGHT_COUNT {
		testing.expect_value(t, b.lights[i].on, a.lights[i].on)
		testing.expectf(t, near(b.lights[i].dir, a.lights[i].dir, 1e-4), "light %d at %v against %v", i + 1, b.lights[i].dir, a.lights[i].dir)
		testing.expectf(t, abs(b.lights[i].strength - a.lights[i].strength) < 1e-5, "light %d strength", i + 1)
		testing.expectf(t, near(b.lights[i].color, a.lights[i].color, 1e-5), "light %d colour %v", i + 1, b.lights[i].color)
	}
	testing.expect_value(t, b.light_ambient, 0.4)

	testing.expect(t, os.write_entire_file(path, transmute([]u8)string("light_key 1.5\nlight_fill 2\n")) == nil)
	c: App
	defer results_destroy(&c)
	lights_reset(&c)
	settings_load(&c, path)
	testing.expect_value(t, c.lights[0].strength, 1.5)
	testing.expectf(t, abs(c.lights[1].strength - 2 * render.FILL_STRENGTH) < 1e-6, "fill %v", c.lights[1].strength)
	// Older scripts still set the first two lights' strengths by their old names.
	for key in ([2]string{"light_key", "light_fill"}) {
		_, found := script_setting(key)
		testing.expectf(t, found, "%s is a script value", key)
	}
	free_all(context.temp_allocator)
}
