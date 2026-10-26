package main

import "core:math/linalg"
import "core:testing"

import "../geom"
import "../sculpt"

// Four objects with no GPU buffers along x, 3 apart, the first selected; selection_free
// undoes it.
@(private = "file")
selection_scene :: proc(app: ^App) -> [4]^Object {
	out: [4]^Object
	for i in 0 ..< 4 {
		obj := new(Object)
		obj.id = i + 1
		obj.transform = {position = {f32(3 * i), 0, 0}, scale = 1}
		sculpt.levels_init(&obj.levels, geom.icosphere(1), nil, 64)
		append(&app.scene.objects, obj)
		out[i] = obj
	}
	app.scene.selected = 0
	return out
}

@(private = "file")
selection_free :: proc(app: ^App) {
	for obj in app.scene.objects {
		sculpt.levels_destroy(&obj.levels)
		free(obj)
	}
	delete(app.scene.objects)
	delete(app.scene.also)
	delete(app.scene.folders)
	delete(app.move.members)
	delete(app.move.edit_members)
	history_destroy(&app.history)
}

@(private = "file")
ids_of :: proc(app: ^App) -> (out: [4]int) {
	copy(out[:], selection_ids(app))
	return
}

// Adding makes the newest the primary; taking the primary out hands the gizmo back to
// the one before; anything that picks a new primary otherwise leaves it alone.
@(test)
selection_toggles_and_falls_back :: proc(t: ^testing.T) {
	app: App
	defer selection_free(&app)
	objs := selection_scene(&app)
	selection_toggle(&app, 2)
	selection_toggle(&app, 3)
	testing.expect_value(t, ids_of(&app), [4]int{4, 3, 1, 0})
	testing.expect(t, object_in_selection(&app, objs[0]) && !object_in_selection(&app, objs[1]))
	// A press on one of the selection keeps the rest with it.
	selection_make_primary(&app, 0)
	testing.expect_value(t, ids_of(&app), [4]int{1, 3, 4, 0})
	selection_toggle(&app, 0)
	testing.expect_value(t, ids_of(&app), [4]int{3, 4, 0, 0})
	selection_toggle(&app, 3)
	testing.expect_value(t, ids_of(&app), [4]int{3, 0, 0, 0})
	// The last one stays selected.
	selection_toggle(&app, 2)
	testing.expect_value(t, ids_of(&app), [4]int{3, 0, 0, 0})

	// A hidden member leaves the selection; a primary chosen elsewhere ends it.
	selection_toggle(&app, 1)
	selection_toggle(&app, 3)
	objs[1].off = true
	scene_selection_fix(&app)
	testing.expect_value(t, ids_of(&app), [4]int{4, 3, 0, 0})
	app.scene.selected = 0
	scene_selection_fix(&app)
	testing.expect_value(t, ids_of(&app), [4]int{1, 0, 0, 0})
	selection_toggle(&app, 2)
	scene_deselect(&app)
	testing.expect_value(t, ids_of(&app), [4]int{})
}

// The rest of a selection moves, turns and scales as the primary does, about the same
// points; a move leaves their turns and scales exactly as they were.
@(test)
transform_follow_keeps_the_selection_s_shape :: proc(t: ^testing.T) {
	from := Transform{position = {1, 0, 0}, scale = 1}
	other := Transform{position = {4, 1, 0}, rotation = {0, 15, 0}, scale = 2}
	moved := transform_follow(from, {position = {1, 2, 3}, scale = 1}, other)
	testing.expect_value(t, moved.rotation, other.rotation)
	testing.expect_value(t, moved.scale, other.scale)
	testing.expect(t, linalg.length(moved.position - Vec3{4, 3, 3}) < 1e-6)
	// A quarter turn about z through the primary takes the other with it.
	turned := transform_follow(from, turn_about(from, from.position, {0, 0, 1}, 90), other)
	testing.expect(t, linalg.length(turned.position - Vec3{0, 3, 0}) < 1e-5)
	testing.expect_value(t, turned.scale, other.scale)
	// Doubling about the primary doubles the distance and the other's scale.
	scaled := transform_follow(from, scale_about(from, from.position, 2), other)
	testing.expect(t, linalg.length(scaled.position - Vec3{7, 2, 0}) < 1e-6)
	testing.expect_value(t, scaled.scale, f32(4))
	testing.expect_value(t, transform_follow(from, from, other), other)
}

// A gizmo drag, the inspector's values, a typed value and Reset move the whole selection
// as one undo step each.
@(test)
selection_moves_as_one_step :: proc(t: ^testing.T) {
	app: App
	defer selection_free(&app)
	objs := selection_scene(&app)
	selection_toggle(&app, 2)
	selection_make_primary(&app, 0) // the first carries the gizmo again
	start := [4]Transform{objs[0].transform, objs[1].transform, objs[2].transform, objs[3].transform}

	// The gizmo, as move_tool_frame leaves it.
	app.move.drag = {handle = .X, id = objs[0].id, start = objs[0].transform}
	members_take(&app, &app.move.members)
	objs[0].transform.position.x += 1
	members_follow(&app, app.move.members[:], app.move.drag.start, objs[0].transform)
	move_end(&app)
	testing.expect_value(t, objs[2].transform.position, Vec3{7, 0, 0})
	testing.expect_value(t, objs[1].transform, start[1])
	testing.expect_value(t, len(app.history.done), 2)
	history_undo(&app)
	testing.expect_value(t, len(app.history.done), 0)
	testing.expect_value(t, objs[0].transform, start[0])
	testing.expect_value(t, objs[2].transform, start[2])
	history_redo(&app)
	testing.expect_value(t, objs[2].transform.position, Vec3{7, 0, 0})

	// The inspector's values, over several frames.
	app.device.down = {.Left}
	for _ in 0 ..< 3 {
		before := objs[0].transform
		objs[0].transform.scale *= 1.25
		transform_drag_changed(&app, objs[0], before)
		transform_drag_end(&app)
	}
	app.device.down = {}
	transform_drag_end(&app)
	testing.expect(t, abs(objs[2].transform.scale - 1.953125) < 1e-5)
	testing.expect_value(t, len(app.history.done), 4)
	history_undo(&app)
	testing.expect_value(t, objs[2].transform.position, Vec3{7, 0, 0})
	testing.expect_value(t, objs[2].transform.scale, f32(1))

	// A typed value, then Reset.
	testing.expect(t, gizmo_entry_apply(&app, objs[0], .Y, "2"))
	testing.expect_value(t, objs[2].transform.position, Vec3{7, 2, 0})
	transform_reset(&app)
	testing.expect_value(t, objs[2].transform, Transform{scale = 1})
	history_undo(&app)
	testing.expect_value(t, objs[2].transform.position, Vec3{7, 2, 0})
	history_undo(&app)
	testing.expect_value(t, objs[2].transform.position, Vec3{7, 0, 0})
	testing.expect_value(t, objs[3].transform, start[3])
}

// A scale of the selection stops where any of it reaches its limit, from the gizmo, the
// inspector or a typed value alike.
@(test)
selection_scale_stops_at_the_first_limit :: proc(t: ^testing.T) {
	members := []Member_Start{{id = 2, start = {scale = 50}}}
	testing.expect_value(t, selection_scale_clamp(4, 1, members), f32(2))
	testing.expect_value(t, selection_scale_clamp(1.5, 1, members), f32(1.5))
	testing.expect_value(t, selection_scale_clamp(0.0001, 1, members), f32(MIN_OBJECT_SCALE))
	testing.expect_value(t, selection_scale_clamp(4, 1, nil), f32(4))

	app: App
	defer selection_free(&app)
	objs := selection_scene(&app)
	objs[2].transform.scale = 50
	selection_toggle(&app, 2)
	selection_make_primary(&app, 0)
	testing.expect(t, gizmo_entry_apply(&app, objs[0], .Scale, "*4"))
	testing.expect_value(t, objs[0].transform.scale, f32(2))
	testing.expect_value(t, objs[2].transform.scale, f32(100))
	testing.expect_value(t, objs[2].transform.position, Vec3{12, 0, 0})
}

// Solo shows only the primary, so the rest of the selection goes; a hidden primary hands
// the selection on alone.
@(test)
selection_ends_under_solo :: proc(t: ^testing.T) {
	app: App
	defer selection_free(&app)
	objs := selection_scene(&app)
	selection_toggle(&app, 1)
	app.scene.solo = true
	scene_selection_fix(&app)
	testing.expect_value(t, ids_of(&app), [4]int{2, 0, 0, 0})
	app.scene.solo = false
	selection_toggle(&app, 3)
	objs[3].off = true
	scene_selection_fix(&app)
	testing.expect_value(t, len(selection_ids(&app)), 1)
	testing.expect(t, selected_object(&app) != objs[3])
}
