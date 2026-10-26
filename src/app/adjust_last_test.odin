package main

import "core:slice"
import "core:testing"

import "../geom"
import "../sculpt"

// A selected object with no GPU buffers, ready for Smooth all, which needs none.
@(private = "file")
adjust_object :: proc(app: ^App, id: int) -> ^Object {
	obj := new(Object)
	obj.id, obj.transform = id, {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(3), nil, 64)
	append(&app.scene.objects, obj)
	app.scene.selected = len(app.scene.objects) - 1
	return obj
}

@(private = "file")
adjust_scene_free :: proc(app: ^App) {
	for obj in app.scene.objects {
		sculpt.levels_destroy(&obj.levels)
		free(obj)
	}
	delete(app.scene.objects)
	history_destroy(&app.history)
	results_destroy(app)
}

@(private = "file")
adjust_app :: proc(app: ^App) {
	app.ui.smooth_steps, app.ui.smooth_strength = 3, 0.5
}

// Adjusting Smooth all from 3 steps to 10 gives the vertices, bit for bit, that 10 steps
// from the start give, and leaves one undo step, not two.
@(test)
adjust_runs_again_from_before :: proc(t: ^testing.T) {
	adjusted, direct: App
	defer adjust_scene_free(&adjusted)
	defer adjust_scene_free(&direct)
	adjust_app(&adjusted)
	adjust_app(&direct)
	a := adjust_object(&adjusted, 1)
	b := adjust_object(&direct, 1)
	smooth_command(&adjusted, 3)
	testing.expect_value(t, adjust_op_now(&adjusted), Adjust_Op.Smooth_All)
	adjusted.ui.smooth_steps = 10
	smooth_adjust(&adjusted)
	smooth_command(&direct, 10)
	testing.expect(t, slice.equal(object_mesh(a).positions[:], object_mesh(b).positions[:]))
	testing.expect_value(t, len(adjusted.history.done), 1)
	testing.expect_value(t, len(adjusted.history.undone), 0)
	testing.expect_value(t, adjusted.adjustable.adjusts, 1)
	testing.expect_value(t, adjust_op_now(&adjusted), Adjust_Op.Smooth_All)
}

// A newer step, an undo, a move, another object selected, or the operation's step
// buried and brought back on top by forgetting the steps over it, each end the adjust;
// adjusting then warns and changes nothing.
@(test)
adjust_ends_once_anything_follows :: proc(t: ^testing.T) {
	app: App
	defer adjust_scene_free(&app)
	adjust_app(&app)
	obj := adjust_object(&app, 1)
	smooth_command(&app, 3)
	testing.expect(t, adjust_live(&app))
	// A move: undoing a rebuild would put the object back where it was.
	obj.transform.position.x += 1
	testing.expect(t, !adjust_live(&app))
	obj.transform.position.x -= 1
	testing.expect(t, adjust_live(&app))
	// Another object selected.
	other := adjust_object(&app, 2)
	testing.expect(t, !adjust_live(&app))
	app.scene.selected = 0
	testing.expect(t, adjust_live(&app))
	// An undo.
	history_undo(&app)
	testing.expect(t, !adjust_live(&app))
	history_redo(&app)
	// A step over it, forgotten again as leaving HD forgets HD strokes, leaves it on top
	// but no longer the newest thing done.
	append(&app.history.done, History_Entry{id = obj.id, level = HD_LEVEL, kind = .Stroke, what = "Draw"})
	history_forget_level(&app, obj.id, HD_LEVEL)
	testing.expect(t, undo_mark_on_top(app.history.done[:], app.adjustable.mark))
	testing.expect(t, !adjust_live(&app))
	before := slice.clone(object_mesh(obj).positions[:])
	defer delete(before)
	smooth_adjust(&app)
	testing.expect(t, slice.equal(object_mesh(obj).positions[:], before))
	testing.expect(t, .Warning in app.result.flags)
	testing.expect_value(t, app.adjustable.adjusts, 0)
	testing.expect_value(t, len(other.levels.levels), 1)
}

// A re-run that changes nothing (Smooth all at no strength, which the slider never
// gives but a refusal looks the same) records no step, so the earlier result comes back
// and can still be adjusted.
@(test)
adjust_that_changes_nothing_keeps_the_result :: proc(t: ^testing.T) {
	app: App
	defer adjust_scene_free(&app)
	adjust_app(&app)
	obj := adjust_object(&app, 1)
	smooth_command(&app, 3)
	smoothed := slice.clone(object_mesh(obj).positions[:])
	defer delete(smoothed)
	app.ui.smooth_strength = 0
	smooth_adjust(&app)
	testing.expect(t, slice.equal(object_mesh(obj).positions[:], smoothed))
	testing.expect_value(t, len(app.history.done), 1)
	testing.expect_value(t, len(app.history.undone), 0)
	testing.expect(t, .Warning in app.result.flags)
	testing.expect(t, adjust_live(&app))
}
