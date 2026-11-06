package main

import "core:slice"
import "core:testing"

import "../geom"
import "../sculpt"

@(private = "file")
dial_scene_free :: proc(app: ^App) {
	for obj in app.scene.objects {
		sculpt.levels_destroy(&obj.levels)
		free(obj)
	}
	delete(app.scene.objects)
	history_destroy(&app.history)
	timeline_destroy(&app.timeline)
	results_destroy(app)
}

// Two Smooth alls; the newest dialled to nothing leaves the first's result, and Done makes
// it one undo step that undo takes back to both.
@(test)
history_dial_takes_a_step_away_as_one_step :: proc(t: ^testing.T) {
	app: App
	defer dial_scene_free(&app)
	app.ui.smooth_steps, app.ui.smooth_strength = 3, 0.5
	obj := new(Object)
	obj.id, obj.transform = 1, {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(3), nil, 64)
	append(&app.scene.objects, obj)
	smooth_command(&app, 3)
	first := slice.clone(object_mesh(obj).positions[:])
	defer delete(first)
	smooth_command(&app, 3)
	both := slice.clone(object_mesh(obj).positions[:])
	defer delete(both)
	testing.expect_value(t, history_dial_reason(&app, 1, 1), "")
	history_dial_begin(&app, 1, 1)
	testing.expect(t, history_dial_open(&app), "the dial did not open")
	testing.expect(t, history_busy(&app), "the History moves under an open dial")
	app.timeline.dial.k = 0
	app.timeline.dial.pending = true
	history_dial_done(&app)
	testing.expect(t, !history_dial_open(&app), "still open")
	testing.expect(t, slice.equal(object_mesh(obj).positions[:], first), "at 0 the step is not gone")
	testing.expect_value(t, len(app.history.done), 3)
	e := app.history.done[2]
	testing.expect(t, e.adjusted && e.amount == 0 && e.step_id != 0, "the dial's entry")
	history_undo(&app)
	testing.expect(t, slice.equal(object_mesh(obj).positions[:], both), "undo did not take the dial back")
	// An undone step cannot be dialled.
	testing.expect(t, history_dial_reason(&app, 2, 2) != "", "an undone step was offered")
}

// Cancel, and a scene command, put the model back as the dial found it.
@(test)
history_dial_cancel_puts_the_model_back :: proc(t: ^testing.T) {
	app: App
	defer dial_scene_free(&app)
	app.ui.smooth_steps, app.ui.smooth_strength = 3, 0.5
	obj := new(Object)
	obj.id, obj.transform = 1, {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(3), nil, 64)
	append(&app.scene.objects, obj)
	smooth_command(&app, 3)
	smooth_command(&app, 3)
	both := slice.clone(object_mesh(obj).positions[:])
	defer delete(both)
	// Both steps at once, as a group of strokes is dialled.
	history_dial_begin(&app, 0, 1)
	testing.expect(t, history_dial_open(&app), "the dial did not open")
	testing.expect_value(t, app.timeline.dial.steps, 2)
	app.timeline.dial.k = 0.3
	app.timeline.dial.pending = true
	history_dial_done(&app)
	history_undo(&app)
	testing.expect(t, slice.equal(object_mesh(obj).positions[:], both), "undo")
	history_dial_begin(&app, 1, 1)
	sculpt.sculptor_dial_set(object_sculptor(obj), 0)
	history_dial_cancel(&app)
	testing.expect(t, !history_dial_open(&app), "still open")
	testing.expect(t, slice.equal(object_mesh(obj).positions[:], both), "cancel")
	testing.expect_value(t, len(app.history.done), 2)
}
