package main

import "core:math"
import "core:slice"
import "core:testing"

import "../geom"
import "../sculpt"

@(private = "file")
deform_object :: proc(app: ^App) -> ^Object {
	obj := new(Object)
	obj.id, obj.transform = 1, {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(3), nil, 64)
	append(&app.scene.objects, obj)
	app.scene.selected = 0
	app.ui.deform = {kind = .Twist, along = .Y}
	return obj
}

@(private = "file")
deform_scene_free :: proc(app: ^App) {
	for obj in app.scene.objects {
		sculpt.levels_destroy(&obj.levels)
		free(obj)
	}
	delete(app.scene.objects)
	history_destroy(&app.history)
	results_destroy(app)
}

// Drags Amount through `values` and lets go.
@(private = "file")
deform_drag :: proc(app: ^App, obj: ^Object, values: ..f32) {
	for v in values {
		app.ui.deform.amount = v
		deform_drag_to(app, obj)
	}
	deform_drag_end(app)
}

// A drag of Amount is one undo step that ends where its last value puts it, as a single
// deformation by that value does; the slider springs back to 0, and the step can be
// adjusted.
@(test)
deform_drag_is_one_step :: proc(t: ^testing.T) {
	dragged, direct: App
	defer deform_scene_free(&dragged)
	defer deform_scene_free(&direct)
	a := deform_object(&dragged)
	b := deform_object(&direct)
	before := slice.clone(object_mesh(a).positions[:], context.temp_allocator)
	deform_drag(&dragged, a, 30, 75, 60)
	testing.expect_value(t, len(dragged.history.done), 1)
	testing.expect_value(t, dragged.history.done[0].what, "Twist")
	testing.expect_value(t, dragged.ui.deform.amount, 0)
	testing.expect_value(t, dragged.ui.deform.count, 1)
	testing.expect_value(t, adjust_op_now(&dragged), Adjust_Op.Deformer)
	d, ok := deform_of(&direct, b)
	testing.expect(t, ok)
	d.amount = math.to_radians(f32(60))
	testing.expect(t, deform_run(&direct, b, d))
	testing.expect(t, slice.equal(object_mesh(a).positions[:], object_mesh(b).positions[:]))
	history_undo(&dragged)
	testing.expect(t, slice.equal(object_mesh(a).positions[:], before))
}

// Adjusting the last deformation from 30° to 90° gives what 90° from the start gives,
// still as one step.
@(test)
deform_adjust_runs_again_from_before :: proc(t: ^testing.T) {
	adjusted, direct: App
	defer deform_scene_free(&adjusted)
	defer deform_scene_free(&direct)
	a := deform_object(&adjusted)
	b := deform_object(&direct)
	adjusted.ui.deform.kind, direct.ui.deform.kind = .Bend, .Bend
	deform_drag(&adjusted, a, 30)
	adjusted.adjustable.deform.amount = math.to_radians(f32(90))
	deform_adjust(&adjusted)
	deform_drag(&direct, b, 90)
	testing.expect(t, slice.equal(object_mesh(a).positions[:], object_mesh(b).positions[:]))
	testing.expect_value(t, len(adjusted.history.done), 1)
	testing.expect_value(t, adjust_op_now(&adjusted), Adjust_Op.Deformer)
}

// While Amount is held nothing undoes beneath it, and a command ends it first as its own
// step.
@(test)
deform_drag_ends_before_a_command :: proc(t: ^testing.T) {
	app: App
	defer deform_scene_free(&app)
	obj := deform_object(&app)
	app.ui.smooth_steps, app.ui.smooth_strength = 1, 0.5
	app.ui.deform.amount = 45
	deform_drag_to(&app, obj)
	testing.expect(t, app.ui.deform.drag.active)
	testing.expect(t, !history_can_undo(&app))
	testing.expect(t, command_run(&app, .Smooth_All))
	testing.expect(t, !app.ui.deform.drag.active)
	testing.expect_value(t, len(app.history.done), 2)
	testing.expect_value(t, app.history.done[0].what, "Twist")
	testing.expect_value(t, app.history.done[1].what, "Smooth all")
}

// Auto keeps the end at the mask's soft edge: with the lower half masked, the free upper
// half's bottom stays; with the upper half masked, the free lower half's top.
@(test)
deform_auto_keeps_the_masked_end :: proc(t: ^testing.T) {
	for upper in ([2]bool{false, true}) {
		app: App
		defer deform_scene_free(&app)
		obj := deform_object(&app)
		s := object_sculptor(obj)
		values := make([]u8, len(s.mesh.positions), context.temp_allocator)
		for p, v in s.mesh.positions do values[v] = 255 if (p.y > 0) == upper else 0
		testing.expect(t, sculpt.sculptor_mask_values(s, values, .Replace))
		history_record(&app, obj, .Mask, "Mask")
		d, ok := deform_of(&app, obj)
		testing.expect(t, ok)
		testing.expectf(t, d.from_plus == upper, "upper half masked %v: from the + end %v", upper, d.from_plus)
	}
}

// A drag ended by a command while the pointer still holds the slider does not start again
// at the same value (which would deform the result as far again) until it is let go.
@(test)
deform_held_after_a_command_waits_for_release :: proc(t: ^testing.T) {
	app: App
	defer deform_scene_free(&app)
	obj := deform_object(&app)
	app.ui.smooth_steps, app.ui.smooth_strength = 1, 0.5
	app.device.down = {.Left}
	app.ui.deform.amount = 40
	deform_drag_to(&app, obj)
	testing.expect(t, command_run(&app, .Smooth_All))
	app.ui.deform.amount = 40
	deform_drag_to(&app, obj)
	testing.expect(t, !app.ui.deform.drag.active)
	testing.expect_value(t, app.ui.deform.amount, 0)
	app.device.down = {}
	deform_drag_end(&app)
	app.ui.deform.amount = 10
	deform_drag_to(&app, obj)
	testing.expect(t, app.ui.deform.drag.active)
	deform_drag_end(&app)
	testing.expect_value(t, app.ui.deform.count, 2)
	testing.expect_value(t, len(app.history.done), 3)
}

// The last deformation can no longer be adjusted once another level is shown: its bounds
// were that level's.
@(test)
deform_adjust_keeps_to_its_level :: proc(t: ^testing.T) {
	app: App
	defer deform_scene_free(&app)
	obj := deform_object(&app)
	testing.expect(t, sculpt.levels_subdivide(&obj.levels))
	deform_drag(&app, obj, 30)
	testing.expect_value(t, adjust_op_now(&app), Adjust_Op.Deformer)
	obj.levels.current = 0
	testing.expect_value(t, adjust_op_now(&app), Adjust_Op.None)
	obj.levels.current = 1
	testing.expect_value(t, adjust_op_now(&app), Adjust_Op.Deformer)
}
