package main

import "core:testing"

import "../geom"
import "../sculpt"

// A step keeps the view it was made from and its bookmark; a bookmarked stroke reads on
// its own in the list; Delete everything older forgets only the steps before the one
// chosen, bookmark and all kept; View from this step puts the camera there and Previous
// view comes back.
@(test)
history_steps_keep_views_and_bookmarks :: proc(t: ^testing.T) {
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
	sculpt.levels_init(&obj.levels, geom.icosphere(3), nil, 64)
	append(&app.scene.objects, obj)
	app.scene.selected = 0
	for i in 0 ..< 4 {
		app.camera.yaw = f32(i)
		smooth_command(&app, 1)
	}
	testing.expect_value(t, len(app.history.done), 4)
	for e, i in app.history.done do testing.expect_value(t, e.view.yaw, f32(i))

	// Bookmarked, the third step stands apart from the strokes around it.
	for &e in app.history.done do e.kind, e.what = .Stroke, "Clay"
	testing.expect(t, history_same_stroke(app.history.done[1], app.history.done[2]))
	history_bookmark_set(&app, 2, "Before horns")
	testing.expect(t, !history_same_stroke(app.history.done[1], app.history.done[2]))
	testing.expect_value(t, history_bookmarks(&app), 1)
	testing.expect_value(t, history_bookmark_default(&app), "Bookmark 2")
	// Renamed with its own name, it keeps it.
	history_bookmark_set(&app, 2, app.history.done[2].bookmark)
	testing.expect_value(t, app.history.done[2].bookmark, "Before horns")
	head, last, ok := history_step_of(&app, app.history.done[2].at)
	testing.expect(t, ok && head == 2 && last == 2)

	history_delete_before(&app, 2)
	testing.expect_value(t, len(app.history.done), 2)
	testing.expect_value(t, app.history.dropped, 2)
	testing.expect_value(t, app.history.done[0].bookmark, "Before horns")
	_, _, ok = history_step_of(&app, app.history.done[0].at)
	testing.expect(t, ok)

	app.camera.yaw = 9
	camera_go(&app, app.history.done[0].view)
	testing.expect_value(t, app.camera.yaw, f32(2))
	camera_back(&app)
	testing.expect_value(t, app.camera.yaw, f32(9))

	history_bookmark_set(&app, 0, "")
	testing.expect_value(t, history_bookmarks(&app), 0)
	history_bookmark_set(&app, 1, "Kept to the end")
}
