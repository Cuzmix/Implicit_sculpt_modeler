package main

import "core:testing"

import "../render"

// A change of pass, material or shading switch is a new look and fades; a slider moving
// (cavity, a light, the background's colour) is not, since a drag would fade every frame.
// A fade needs last frame's picture at this frame's size, and lasts its run.
@(test)
look_changes_fade_and_slider_moves_do_not :: proc(t: ^testing.T) {
	app: App
	base := look_key(&app)
	app.cavity, app.background.top = 0.3, {1, 0, 0}
	testing.expect_value(t, look_key(&app), base)
	app.wireframe = true
	testing.expect(t, look_key(&app) != base, "wireframe is no new look")
	app.wireframe = false
	pass_set(&app.kit, .Curvature)
	testing.expect(t, look_key(&app) != base, "a new pass is no new look")
	pass_set(&app.kit, .Shaded)
	app.material = 3
	testing.expect(t, look_key(&app) != base, "a new material is no new look")

	cross_fade_start(&app, .Look_Fade)
	testing.expect(t, !app.cross_fade.on, "a fade began with no picture to fade from")
	app.target.width, app.target.height = 64, 32
	app.target.color = render.Texture(rawptr(uintptr(16)))
	cross_fade_shown(&app, app.target.color)
	cross_fade_start(&app, .Look_Fade)
	testing.expect(t, app.cross_fade.on && app.cross_fade.copy && app.cross_fade.looks == 1, "a look change did not fade")
	testing.expect_value(t, cross_fade_alpha(&app), 1)
	app.kit.ctx.time += LOOK_FADE_SECONDS * 0.25
	a := cross_fade_alpha(&app)
	testing.expectf(t, a > 0 && a < 1, "a quarter in, %v of the old picture shows", a)
	app.camera.distance += 1
	testing.expect_value(t, cross_fade_alpha(&app), 0)
	testing.expect(t, !app.cross_fade.on, "a camera move did not end the fade")
	cross_fade_start(&app, .Mesh_Fade)
	app.kit.ctx.time += MESH_FADE_SECONDS
	testing.expect(t, cross_fade_alpha(&app) == 0 && !app.cross_fade.on && app.cross_fade.meshes == 1, "a mesh fade outlived its run")
}
