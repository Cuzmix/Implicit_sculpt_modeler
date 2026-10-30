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

// A row's mask square picks the layer's mask and the Mask brush, and a tap again puts
// the sculpt mask and the brush back; picking another brush ends the pick and keeps that
// brush. A mask command on the picked mask names it in the History, and the menu's
// Invert works on a layer's mask that is not picked, leaving the sculpt mask alone.
@(test)
layer_mask_square_picks_the_mask_brush :: proc(t: ^testing.T) {
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
	app.tool, app.brush.kind = .Brush, .Clay
	s := object_sculptor(obj)
	layer_add(&app)
	layer_add(&app)

	layer_mask_paint(&app, obj, 0)
	testing.expect_value(t, layer_mask_painting(&app, obj), 0)
	testing.expect_value(t, app.brush.kind, sculpt.Brush_Kind.Mask)
	testing.expect_value(t, app.ui.layer_selected, 0)
	mask_command(&app, .Fill)
	e := app.history.done[len(app.history.done) - 1]
	testing.expect(t, e.layer_mask, "the step was not the layer mask's")
	testing.expect_value(t, entry_label(e), "Mask all (layer mask)")
	testing.expect(t, sculpt.sculptor_layer_has_mask(s, 0))
	layer_mask_frame(&app)
	testing.expect_value(t, layer_mask_painting(&app, obj), 0)

	// A tap again: the sculpt mask (none) and Clay are back.
	layer_mask_stop(&app, restore = true)
	testing.expect_value(t, layer_mask_painting(&app, obj), -1)
	testing.expect_value(t, app.brush.kind, sculpt.Brush_Kind.Clay)
	testing.expect(t, s.mask == nil, "the layer's mask stayed the sculpt mask")
	testing.expect(t, sculpt.sculptor_layer_has_mask(s, 0))

	// Another brush ends the pick and stays.
	layer_mask_paint(&app, obj, 1)
	app.brush.kind = .Smooth
	layer_mask_frame(&app)
	testing.expect_value(t, layer_mask_painting(&app, obj), -1)
	testing.expect_value(t, app.brush.kind, sculpt.Brush_Kind.Smooth)

	// Invert from the menu on layer 1, not picked: it hides that layer whole, as one
	// step that one undo takes back, and the sculpt mask stays empty.
	steps := len(app.history.done)
	layer_mask_edit(&app, obj, 1, .Invert)
	testing.expect_value(t, len(app.history.done), steps + 1)
	testing.expect(t, sculpt.sculptor_layer_has_mask(s, 1))
	testing.expect_value(t, sculpt.sculptor_layer_mask_picked(s), -1)
	testing.expect(t, s.mask == nil, "invert painted the sculpt mask")
	history_undo(&app)
	testing.expect(t, !sculpt.sculptor_layer_has_mask(s, 1))
	testing.expect(t, sculpt.sculptor_layer_has_mask(s, 0))
}
