package main

import "core:testing"

import "../camera"
import "../geom"
import "../sculpt"

// Grow and Shrink visibility and the new polygroup commands are each one History step by
// their name, and offered only where they can do something.
@(test)
visibility_and_group_commands_are_steps :: proc(t: ^testing.T) {
	app: App
	app.ui = ui_state_default()
	app.camera = camera.orbit_default()
	obj := new(Object)
	obj.id, obj.transform = 1, {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(3), nil, 64)
	append(&app.scene.objects, obj)
	defer {
		sculpt.levels_destroy(&obj.levels)
		free(obj)
		delete(app.scene.objects)
		history_destroy(&app.history)
		results_destroy(&app)
	}
	s := object_sculptor(obj)
	testing.expect(t, !command_enabled(&app, .Grow_Visible, 0), "grow offered with nothing selected")
	app.scene.selected = 0
	testing.expect(t, !command_enabled(&app, .Grow_Visible, 0), "grow offered with nothing hidden")
	testing.expect(t, !command_enabled(&app, .Group, int(sculpt.Group_Command.Uv_Charts)), "UV groups offered without UVs")
	clip: matrix[4, 4]f32
	clip[0, 0], clip[1, 1], clip[2, 2], clip[3, 3] = 1, 1, 0.1, 1
	testing.expect(t, sculpt.sculptor_hide_shape(s, clip, {{0, -10}, {10, -10}, {10, 10}, {0, 10}}, .Show_Only))
	hidden := sculpt.sculptor_hidden_count(s)
	testing.expect(t, command_enabled(&app, .Grow_Visible, 0))
	COMMANDS[.Grow_Visible].run(&app, 0)
	testing.expect(t, sculpt.sculptor_hidden_count(s) < hidden)
	COMMANDS[.Shrink_Visible].run(&app, 0)
	COMMANDS[.Group].run(&app, int(sculpt.Group_Command.Pieces))
	testing.expect_value(t, len(app.history.done), 3)
	if len(app.history.done) == 3 {
		testing.expect_value(t, app.history.done[0].what, "grow visibility")
		testing.expect_value(t, app.history.done[1].what, "shrink visibility")
		testing.expect_value(t, app.history.done[2].what, "Group by pieces")
	}
}
