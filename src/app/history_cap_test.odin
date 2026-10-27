package main

import "core:slice"
import "core:testing"

import "../geom"
import "../sculpt"

@(private = "file")
cap_object :: proc(app: ^App, id: int) -> ^Object {
	obj := new(Object)
	obj.id, obj.transform = id, {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(3), nil, 64)
	append(&app.scene.objects, obj)
	app.scene.selected = len(app.scene.objects) - 1
	return obj
}

@(private = "file")
cap_scene_free :: proc(app: ^App) {
	for obj in app.scene.objects {
		sculpt.levels_destroy(&obj.levels)
		free(obj)
	}
	delete(app.scene.objects)
	history_destroy(&app.history)
	results_destroy(app)
}

@(private = "file")
cap_select :: proc(app: ^App, obj: ^Object) {
	for o, i in app.scene.objects do if o == obj do app.scene.selected = i
}

// With Undo steps kept at 3, five steps leave three: the sculptor holds no more steps
// than the History names, so three undos go back to after the second step and a fourth
// finds nothing.
@(test)
the_history_keeps_its_newest_steps :: proc(t: ^testing.T) {
	app: App
	defer cap_scene_free(&app)
	app.ui.smooth_steps, app.ui.smooth_strength = 1, 0.5
	obj := cap_object(&app, 1)
	after_two: []geom.Vec3
	defer delete(after_two)
	for i in 0 ..< 5 {
		smooth_command(&app, 1)
		if i == 1 do after_two = slice.clone(object_mesh(obj).positions[:])
	}
	app.undo_steps = 3
	history_cap(&app)
	testing.expect_value(t, len(app.history.done), 3)
	s := object_sculptor(obj)
	testing.expect_value(t, len(s.history.done), 3)
	for _ in 0 ..< 3 do history_undo(&app)
	testing.expect(t, slice.equal(object_mesh(obj).positions[:], after_two))
	testing.expect(t, !history_can_undo(&app))
	// Redo still runs every step forward.
	for _ in 0 ..< 3 do history_redo(&app)
	testing.expect_value(t, len(app.history.done), 3)
}

// A step and the entries chained to it count once and go together; each object keeps
// as many of its own steps as the History still names.
@(test)
the_history_cap_counts_steps_and_objects_apart :: proc(t: ^testing.T) {
	app: App
	defer cap_scene_free(&app)
	app.ui.smooth_steps, app.ui.smooth_strength = 1, 0.5
	a := cap_object(&app, 1)
	b := cap_object(&app, 2)
	cap_select(&app, a)
	smooth_command(&app, 1) // a
	cap_select(&app, b)
	smooth_command(&app, 1) // b
	cap_select(&app, a)
	smooth_command(&app, 1) // a
	// One step of two entries: both objects moved together.
	before_a, before_b := a.transform, b.transform
	a.transform.position.x += 1
	b.transform.position.x += 1
	history_record_transform(&app, a, before_a, "move")
	history_record_transform(&app, b, before_b, "move", chain = true)
	cap_select(&app, b)
	smooth_command(&app, 1) // b
	testing.expect_value(t, history_step_count(app.history.done[:]), 5)
	app.undo_steps = 3
	history_cap(&app)
	// The first a and the first b went; the move stays whole.
	testing.expect_value(t, history_step_count(app.history.done[:]), 3)
	testing.expect_value(t, len(app.history.done), 4)
	testing.expect_value(t, len(object_sculptor(a).history.done), 1)
	testing.expect_value(t, len(object_sculptor(b).history.done), 1)
	app.undo_steps = 2
	history_cap(&app)
	// The second a went with the step it was; the move is now the oldest, both entries.
	testing.expect_value(t, len(app.history.done), 3)
	testing.expect_value(t, len(object_sculptor(a).history.done), 0)
	testing.expect(t, !app.history.done[0].chain && app.history.done[1].chain)
}

// Strokes on two levels each keep their own: dropping the oldest steps leaves each
// level's sculptor as many steps as the History names on that level.
@(test)
the_history_cap_keeps_each_levels_steps :: proc(t: ^testing.T) {
	app: App
	defer cap_scene_free(&app)
	app.ui.smooth_steps, app.ui.smooth_strength = 1, 0.5
	obj := cap_object(&app, 1)
	testing.expect(t, sculpt.levels_subdivide(&obj.levels))
	sculpt.levels_set_current(&obj.levels, 1)
	smooth_command(&app, 1)
	smooth_command(&app, 1)
	sculpt.levels_set_current(&obj.levels, 0)
	smooth_command(&app, 1)
	smooth_command(&app, 1)
	app.undo_steps = 3
	history_cap(&app)
	testing.expect_value(t, len(obj.levels.levels[1].sculptor.history.done), 1)
	testing.expect_value(t, len(obj.levels.levels[0].sculptor.history.done), 2)
}

// Delete older history forgets every step that can be undone, frees their memory and
// the History brush's target, and keeps the steps to redo working.
@(test)
delete_older_history_keeps_redo :: proc(t: ^testing.T) {
	app: App
	defer cap_scene_free(&app)
	app.ui.smooth_steps, app.ui.smooth_strength = 1, 0.5
	obj := cap_object(&app, 1)
	for _ in 0 ..< 3 do smooth_command(&app, 1)
	after_three := slice.clone(object_mesh(obj).positions[:])
	defer delete(after_three)
	history_undo(&app)
	s := object_sculptor(obj)
	testing.expect(t, sculpt.sculptor_recall_build(s, 1))
	bytes := sculpt.sculptor_undo_bytes(s)
	history_delete_older(&app)
	testing.expect_value(t, len(app.history.done), 0)
	testing.expect_value(t, len(s.history.done), 0)
	testing.expect(t, sculpt.sculptor_undo_bytes(s) < bytes)
	testing.expect(t, s.recall == nil)
	testing.expect(t, history_can_redo(&app))
	history_redo(&app)
	testing.expect(t, slice.equal(object_mesh(obj).positions[:], after_three))
	testing.expect_value(t, len(app.history.done), 1)
}

// Steps the sculptor's own memory limit already dropped (out of reach of the History's
// oldest entries) are counted right: the cap keeps the newest steps working.
@(test)
the_history_cap_follows_the_memory_limit :: proc(t: ^testing.T) {
	app: App
	defer cap_scene_free(&app)
	app.ui.smooth_steps, app.ui.smooth_strength = 1, 0.5
	obj := cap_object(&app, 1)
	s := object_sculptor(obj)
	s.history.limit = 1 // only the newest step stays in the sculptor
	for _ in 0 ..< 5 do smooth_command(&app, 1)
	testing.expect_value(t, len(s.history.done), 1)
	app.undo_steps = 2
	history_cap(&app)
	testing.expect_value(t, len(app.history.done), 2)
	testing.expect_value(t, len(s.history.done), 1)
	history_undo(&app)
	testing.expect_value(t, len(s.history.done), 0)
	testing.expect_value(t, len(s.history.undone), 1)
}
