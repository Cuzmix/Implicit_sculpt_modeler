package main

import "core:os"
import "core:testing"

import "../render"

// Sculpt studio puts on every part of its look, and Classic gives back the code's
// defaults, which scripted runs and --no-settings keep.
@(test)
look_presets_set_every_part :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	look_apply(&app, .Sculpt_Studio, false)
	grey, _ := material_by_name("studio grey")
	testing.expect_value(t, app.material, grey)
	testing.expect_value(t, app.scene.lights, look_lights_studio())
	testing.expect_value(t, app.start_lights, look_lights_studio())
	testing.expect_value(t, app.background, LOOK_BACKGROUND_STUDIO)
	testing.expect(t, app.styled && app.live_ao_on && app.studio_on && app.look_chosen)
	testing.expect_value(t, app.studio_softness, f32(LOOK_STUDIO_SOFTNESS))
	testing.expect_value(t, look_current(&app), Maybe(Look_Preset)(.Sculpt_Studio))
	// Only with `selected` does it reach the selected objects, through a scene command.
	testing.expect_value(t, app.ui.scene_command.kind, Scene_Command_Kind{})

	look_apply(&app, .Classic, true)
	testing.expect_value(t, app.material, 0)
	testing.expect_value(t, app.ui.scene_command.kind, Scene_Command_Kind.Material)
	testing.expect_value(t, app.scene.lights, LIGHTS_DEFAULT)
	testing.expect_value(t, app.background, BACKGROUND_DEFAULT)
	testing.expect(t, !app.styled && !app.live_ao_on && !app.studio_on)
	testing.expect_value(t, app.cavity, f32(CAVITY_DEFAULT))
	testing.expect_value(t, app.studio_ao, f32(STUDIO_AO_DEFAULT))
	testing.expect_value(t, app.studio_shadow, f32(STUDIO_SHADOW_DEFAULT))
	testing.expect_value(t, app.studio_softness, f32(render.STUDIO_KEY_SOFTNESS))
	testing.expect_value(t, look_current(&app), Maybe(Look_Preset)(.Classic))
	// The style on its own is neither.
	app.styled = true
	testing.expect_value(t, look_current(&app), nil)
}

// The first run puts Sculpt studio on once; the settings then keep that it did, and what
// was changed after it.
@(test)
look_first_run_happens_once :: proc(t: ^testing.T) {
	path := "build/look_test.txt"
	defer os.remove(path)
	a: App
	defer results_destroy(&a)
	look_first_run(&a)
	testing.expect(t, a.studio_on && a.look_chosen)
	a.studio_on = false
	testing.expect(t, settings_save(&a, path))

	b: App
	defer results_destroy(&b)
	settings_load(&b, path)
	look_first_run(&b)
	testing.expect(t, b.look_chosen && b.styled && !b.studio_on)
}
