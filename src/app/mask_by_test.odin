package main

import "core:strings"
import "core:testing"

import "../camera"
import "../geom"
import "../sculpt"

// A selected sphere with no GPU buffers, seen by the default camera.
@(private = "file")
mask_by_scene :: proc(app: ^App) -> ^Object {
	app.ui = ui_state_default()
	app.camera = camera.orbit_default()
	obj := new(Object)
	obj.id, obj.transform = 1, {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(3), nil, 64)
	append(&app.scene.objects, obj)
	app.scene.selected = 0
	return obj
}

@(private = "file")
mask_by_scene_free :: proc(app: ^App) {
	for obj in app.scene.objects {
		sculpt.levels_destroy(&obj.levels)
		free(obj)
	}
	delete(app.scene.objects)
	history_destroy(&app.history)
	results_destroy(app)
}

@(private = "file")
mask_sum :: proc(obj: ^Object) -> (sum: int) {
	for k in object_sculptor(obj).mask do sum += int(k)
	return
}

// Mask by, Mask adjust and Mask region each leave one History step by their name; one
// that changes nothing leaves none and says why.
@(test)
mask_by_commands_are_one_step_each :: proc(t: ^testing.T) {
	app: App
	obj := mask_by_scene(&app)
	defer mask_by_scene_free(&app)
	COMMANDS[.Mask_By].run(&app, int(sculpt.Mask_By.Facing_Away))
	testing.expect_value(t, len(app.history.done), 1)
	testing.expect_value(t, app.history.done[0].what, "Mask by facing away")
	before := mask_sum(obj)
	testing.expect(t, before > 0)
	app.ui.mask_by.adjust_curve = {{0, 0.6}, {0.4, 1}}
	COMMANDS[.Mask_Adjust].run(&app, 0)
	testing.expect_value(t, len(app.history.done), 2)
	testing.expect_value(t, app.history.done[1].what, "Mask adjust")
	testing.expect(t, mask_sum(obj) > before)
	history_undo(&app)
	testing.expect_value(t, mask_sum(obj), before)
	// The sphere has no polygroups.
	COMMANDS[.Mask_By].run(&app, int(sculpt.Mask_By.Group_Borders))
	testing.expect_value(t, len(app.history.done), 1)
	testing.expect(t, strings.contains(app.result.text, "no polygroups"), app.result.text)
	testing.expect_value(t, command_label(.Mask_By, int(sculpt.Mask_By.Creases)), "Mask by creases")
	testing.expect_value(t, mask_by_label(.Color_Hue), "Colour hue")
}
