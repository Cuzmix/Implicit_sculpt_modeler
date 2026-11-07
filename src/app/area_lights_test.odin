package main

import "core:math"
import "core:math/linalg"
import "core:testing"

import "../camera"
import "../geom"
import "../render"

@(private = "file")
close :: proc(a, b: f32, eps: f32 = 1e-5) -> bool {
	return abs(a - b) < eps
}

// An app whose third light is an area light standing in the scene, aimed at the target
// from above and in front.
@(private = "file")
area_app :: proc() -> (app: App) {
	app.camera = camera.orbit_default()
	app.camera.yaw, app.camera.pitch = 0.4, -0.2
	lights_reset(&app)
	set := &app.scene.lights
	set.count = 3
	set.lights[2] = {on = true, kind = .Area, space = .Scene, dir = linalg.normalize([3]f32{0, 0.5, 1}), pos = {0, 1.5, 3}, ref = 2, strength = 1, color = 1, cone = 45, width = 2, height = 1}
	return
}

// An area light reaches the shader as its face: its kind, the way it faces (its aim), an
// edge level in the scene and across the aim with half its width, half its height, and the
// radius of the disc of its area; a disc as its own radius.
@(test)
area_light_reaches_the_shader_as_a_face :: proc(t: ^testing.T) {
	app := area_app()
	l := viewport_lights(&app)
	testing.expect_value(t, l.pos[2].w, f32(render.LIGHT_AREA))
	facing, edge := l.spot[2].xyz, l.axis[2].xyz
	testing.expect(t, close(linalg.length(edge), 1) && close(linalg.dot(edge, facing), 0))
	testing.expect(t, close(l.axis[2].w, 1) && close(l.extra[2].z, 0.5) && l.extra[2].w == 0)
	testing.expect(t, close(l.shape[2].w, math.sqrt(2 / f32(math.PI))))
	// Level in the scene: the edge turned back out of view space has no height.
	world := linalg.transpose(view_rotation(&app)) * edge
	testing.expectf(t, abs(world.y) < 1e-5, "the edge tilts: %v", world)
	// The face looks the way the light is aimed, from where it stands toward the target.
	testing.expect(t, linalg.dot(linalg.transpose(view_rotation(&app)) * facing, linalg.normalize([3]f32{0, -0.5, -1})) > 0.9999)

	// The mesh draws with the area lights' shader only while one is on.
	testing.expect(t, render.lights_have_area(l))
	app.scene.lights.lights[2].on = false
	testing.expect(t, !render.lights_have_area(viewport_lights(&app)))
	app.scene.lights.lights[2].on = true

	app.scene.lights.lights[2].disc = true
	l = viewport_lights(&app)
	testing.expect(t, l.extra[2].w == 1 && close(l.shape[2].w, 1) && close(l.axis[2].w, 1) && close(l.extra[2].z, 1))
}

// Highlight and Shadows reach every kind's extra; a light that sets neither, and the
// lights a fresh install has, leave it zero, so their pictures are the ones they were.
@(test)
light_highlight_and_shadows_reach_the_shader :: proc(t: ^testing.T) {
	app := area_app()
	l := viewport_lights(&app)
	for e in l.extra[:2] do testing.expect_value(t, e, [4]f32{})
	app.scene.lights.lights[0].shine = 0.5
	app.scene.lights.lights[1].no_shadows = true
	l = viewport_lights(&app)
	testing.expect_value(t, l.extra[0], [4]f32{0.5, 0, 0, 0})
	testing.expect_value(t, l.extra[1], [4]f32{0, 1, 0, 0})
	// The studio's shadow never comes from a light with shadows off.
	app.scene.lights.lights[0].no_shadows = true
	app.scene.lights.lights[2].no_shadows = true
	_, lit := render.lights_key(viewport_lights(&app), {})
	testing.expect(t, !lit)
}

// The studio's shadow samples never pick a light with shadows off: it goes to the shader
// with its chance negated, and the others' samples weigh more by the chance it gave up.
// With every light casting shadows the weights are exactly as they were.
@(test)
studio_samples_skip_lights_without_shadows :: proc(t: ^testing.T) {
	app := area_app()
	app.scene.lights.lights[0].no_shadows = true
	l := viewport_lights(&app)
	view := camera.orbit_view(app.camera)
	for k in 0 ..< 400 {
		sl := render.studio_light(l, view, {}, 0.1, k)
		if !sl.lit do continue
		testing.expectf(t, int(sl.shadow.pick.x) != 0, "sample %d picked the light with shadows off", k)
		testing.expect(t, sl.shadow.shape[0].w < 0 && sl.shadow.shape[1].w > 0 && sl.shadow.shape[2].w > 0)
		testing.expect(t, close(sl.shadow.pick.y, sl.shadow.shape[1].w + sl.shadow.shape[2].w))
	}
	app.scene.lights.lights[0].no_shadows = false
	sl := render.studio_light(viewport_lights(&app), view, {}, 0.1, 7)
	testing.expect_value(t, sl.shadow.pick.y, f32(1))
}


// The scene file keeps an area light, its size, its highlight and its shadows, and refuses
// damaged ones; a light that lacks them (a file before area lights had them) reads as
// a light with none.
@(test)
area_lights_round_trip_in_the_scene_file :: proc(t: ^testing.T) {
	app := area_app()
	set := app.scene.lights
	set.lights[2].disc = true
	set.lights[2].shine = -0.25
	set.lights[1].no_shadows = true
	out: [dynamic]u8
	defer delete(out)
	lights_put(&out, set)
	rec := geom.record_of(out[:])
	back, ok := lights_get(&rec, LIGHTS_DEFAULT)
	testing.expect(t, ok)
	testing.expect_value(t, back, set)

	damage :: proc(t: ^testing.T, set: Light_Set, light: int, tag: Light_Tag, value: []u8, loc := #caller_location) {
		out: [dynamic]u8
		defer delete(out)
		lights_put(&out, set)
		rec := geom.record_of(out[:])
		at := 0
		payload: []u8
		for _ in 0 ..= light do payload, _ = geom.rec_next(&rec, Light_Set_Tag.Light, &at)
		lr := geom.record_of(payload)
		field, _ := geom.rec_find(&lr, tag)
		for &b, i in field do b = value[i % len(value)]
		_, ok := lights_get(&rec, LIGHTS_DEFAULT)
		testing.expectf(t, !ok, "light %d's %v set to %v was read", light, tag, value, loc = loc)
	}
	damage(t, set, 2, .Disc, {2}) // `disc` not 0 or 1
	damage(t, set, 2, .Shine, {0, 0, 0, 0x7f}) // the highlight far past 1
	damage(t, set, 2, .No_Shadows, {2}) // `no_shadows` not 0 or 1
	damage(t, set, 2, .Width, {0xff}) // the width a NaN
}

// An exported area light is the file's area light, turned whole: its -Z the way it
// shines and its x along its width, so the rectangle stands in the file as in the scene.
@(test)
area_light_exports_its_size_and_turn :: proc(t: ^testing.T) {
	app := area_app()
	lights := export_lights(&app)
	testing.expect_value(t, len(lights), 3)
	e := lights[2]
	testing.expect(t, e.kind == .Area && close(e.width, 2) && close(e.height, 1) && !e.disc)
	testing.expect(t, close(linalg.dot(e.edge, e.direction), 0) && abs(e.edge.y) < 1e-5)
	_, turn, _, _ := geom.export_light_place({scale = 1}, e)
	shines := linalg.quaternion128_mul_vector3(turn, [3]f32{0, 0, -1})
	across := linalg.quaternion128_mul_vector3(turn, [3]f32{1, 0, 0})
	testing.expect(t, linalg.dot(shines, e.direction) > 0.9999 && linalg.dot(across, e.edge) > 0.9999)
}
