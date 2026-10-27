package main

import "core:testing"

import "../camera"
import "../geom"
import "../sculpt"

// The Layers section's actions act on the selected layer as History steps, are offered
// only where they can run, and Bake all is one step that one undo takes back.
@(test)
layer_actions_are_steps_and_bake_all_is_one :: proc(t: ^testing.T) {
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
	app.scene.selected = 0
	s := object_sculptor(obj)
	testing.expect(t, !command_enabled(&app, .Layer_Edit, int(Layer_Action.Bake_All)), "bake all offered with no layers")
	layer_add(&app)
	layer_add(&app)
	testing.expect_value(t, app.ui.layer_selected, 1)
	testing.expect(t, !command_enabled(&app, .Layer_Edit, int(Layer_Action.Move_Up)), "the top layer offered to move up")
	testing.expect(t, !command_enabled(&app, .Layer_Edit, int(Layer_Action.Invert)), "an empty layer offered to invert")
	COMMANDS[.Layer_Edit].run(&app, int(Layer_Action.Move_Down))
	testing.expect_value(t, app.ui.layer_selected, 0)
	testing.expect_value(t, sculpt.sculptor_layer_name(&sculpt.sculptor_layers(s)[0]), "Layer 2")
	COMMANDS[.Layer_Edit].run(&app, int(Layer_Action.Duplicate))
	testing.expect_value(t, len(sculpt.sculptor_layers(s)), 3)
	steps := len(app.history.done)
	COMMANDS[.Layer_Edit].run(&app, int(Layer_Action.Bake_All))
	testing.expect_value(t, len(sculpt.sculptor_layers(s)), 0)
	history_undo(&app)
	testing.expect_value(t, len(sculpt.sculptor_layers(s)), 3)
	testing.expect_value(t, len(app.history.done), steps)
	testing.expect_value(t, app.history.done[steps - 1].what, "Duplicate layer")
}

// Stepping the timeline back into a chain of entries (as a Slice or a boolean records)
// undoes the whole chain and stops there instead of redoing and undoing it each frame.
@(test)
timeline_step_back_over_a_chain_stops :: proc(t: ^testing.T) {
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
	app.scene.selected = 0
	layer_add(&app)
	layer_add(&app)
	app.history.done[len(app.history.done) - 1].chain = true
	app.timeline.target, app.timeline.seeking = len(app.history.done) - 1, true
	timeline_frame(&app)
	testing.expect(t, !timeline_busy(&app), "the timeline kept seeking into a chain")
	testing.expect_value(t, len(app.history.done), 0)
}
