package main

import "core:testing"

import "../geom"
import "../sculpt"

// History may use drops the oldest steps until the History fits, but stops at a bookmarked
// step; light changes kept out leave no step yet still count as an edit; the list can leave
// strokes apart; with the camera following, undo puts the view back as the step had it.
@(test)
history_settings_hold_the_history :: proc(t: ^testing.T) {
	app: App
	defer {
		for obj in app.scene.objects {
			sculpt.levels_destroy(&obj.levels)
			free(obj)
		}
		delete(app.scene.objects)
		history_destroy(&app.history)
		results_destroy(&app)
	}
	app.ui.smooth_steps, app.ui.smooth_strength = 1, 0.5
	app.camera = {distance = 3, fov_y = 0.8, near = 0.01, far = 100}
	obj := new(Object)
	obj.id, obj.transform = 1, {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(6), nil, 64)
	append(&app.scene.objects, obj)
	app.scene.selected = 0
	for i in 0 ..< 5 {
		app.camera.yaw = f32(i)
		smooth_command(&app, 1)
	}
	for &e in app.history.done do e.kind, e.what = .Stroke, "Smooth"
	testing.expect_value(t, len(app.history.done), 5)
	testing.expect_value(t, len(history_rows(&app)), 1)
	testing.expect_value(t, len(history_rows(&app, group = false)), 5)
	bytes, _ := history_memory(&app)
	testing.expect(t, bytes > 2 << 20)

	// A megabyte keeps only what fits, but no further than the bookmark on the second step.
	history_bookmark_set(&app, 1, "Kept")
	app.history_limit_mb = 1
	history_cap(&app)
	testing.expect_value(t, len(app.history.done), 4)
	testing.expect_value(t, app.history.done[0].bookmark, "Kept")
	testing.expect_value(t, app.history.held_at, app.history.done[0].at)
	testing.expect_value(t, object_sculptor(obj).history.limit, 1 << 20)
	// Back to Automatic, the stores take their own limits again.
	app.history_limit_mb = 0
	history_cap(&app)
	testing.expect_value(t, object_sculptor(obj).history.limit, sculpt.UNDO_LIMIT_BYTES)

	app.history_camera = true
	app.camera.yaw = 9
	undo_run(&app)
	testing.expect_value(t, app.camera.yaw, f32(4))
	redo_run(&app)
	testing.expect_value(t, app.camera.yaw, f32(4))

	edits := app.history.edits
	app.history_no_lights = true
	history_record_lights(&app, app.scene.lights, "Move light")
	testing.expect_value(t, len(app.history.done), 4)
	testing.expect_value(t, app.history.edits, edits + 1)
}
