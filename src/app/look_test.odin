package main

import "core:os"
import "core:testing"

// The studio look puts on every part of it but the Render switch, Rendered being a shading
// mode of its own; it touches no object, only what new ones take.
@(test)
look_studio_sets_every_part :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	look_studio_apply(&app)
	grey, _ := material_by_name("studio grey")
	testing.expect_value(t, app.material, grey)
	testing.expect_value(t, app.scene.lights, look_lights_studio())
	testing.expect_value(t, app.start_lights, look_lights_studio())
	testing.expect_value(t, app.background, LOOK_BACKGROUND_STUDIO)
	testing.expect(t, app.styled && app.live_ao_on && !render_switch_on(&app) && app.look_chosen)
	testing.expect_value(t, app.studio_softness, f32(LOOK_STUDIO_SOFTNESS))
	testing.expect_value(t, app.ui.scene_command.kind, Scene_Command_Kind{})
	testing.expect_value(t, main_shading_mode(&app), Shading_Mode.Solid)
}

// The first run puts the studio look on once; the settings then keep that it did, and what
// was changed after it.
@(test)
look_first_run_happens_once :: proc(t: ^testing.T) {
	path := "build/look_test.txt"
	defer os.remove(path)
	a: App
	defer results_destroy(&a)
	look_first_run(&a)
	testing.expect(t, a.styled && a.look_chosen)
	a.styled = false
	testing.expect(t, settings_save(&a, path))

	b: App
	defer results_destroy(&b)
	settings_load(&b, path)
	look_first_run(&b)
	testing.expect(t, b.look_chosen && !b.styled)
}
