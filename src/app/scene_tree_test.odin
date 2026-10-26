package main

import "core:testing"

import "../geom"
import "../sculpt"

// Three objects with no GPU buffers along x, 3 apart, the first selected; tree_free
// undoes it.
@(private = "file")
tree_scene :: proc(app: ^App) -> [3]^Object {
	out: [3]^Object
	for i in 0 ..< 3 {
		obj := new(Object)
		obj.id = i + 1
		obj.transform = {position = {f32(3 * i), 0, 0}, scale = 1}
		sculpt.levels_init(&obj.levels, geom.icosphere(2), nil, 64)
		append(&app.scene.objects, obj)
		out[i] = obj
	}
	app.scene.selected = 0
	return out
}

@(private = "file")
tree_free :: proc(app: ^App) {
	for obj in app.scene.objects {
		sculpt.levels_destroy(&obj.levels)
		free(obj)
	}
	delete(app.scene.objects)
	history_destroy(&app.history)
	results_destroy(app)
}

// Down the z axis onto the object at `x`.
@(private = "file")
hit_at :: proc(app: ^App, x: f32) -> (index: int, ok: bool) {
	index, _, ok = scene_raycast(app, {x, 0, 5}, {0, 0, -1})
	return
}

// The eye and ghost decide what is drawn and what a press can reach, and the raycasts
// that every press goes through skip what it cannot.
@(test)
view_flags_decide_shown_and_pickable :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	for obj in objs do testing.expect(t, object_shown(&app, obj) && object_pickable(&app, obj))
	i, ok := hit_at(&app, 3)
	testing.expect(t, ok && i == 1)

	objs[1].ghost = true
	testing.expect(t, object_shown(&app, objs[1]) && !object_pickable(&app, objs[1]))
	_, ok = hit_at(&app, 3)
	testing.expect(t, !ok)
	_, _, _, ok = scene_raycast_surface(&app, {3, 0, 5}, {0, 0, -1})
	testing.expect(t, !ok)

	objs[1].ghost, objs[2].off = false, true
	testing.expect(t, !object_shown(&app, objs[2]) && !object_pickable(&app, objs[2]))
	_, ok = hit_at(&app, 6)
	testing.expect(t, !ok)
	i, ok = hit_at(&app, 3)
	testing.expect(t, ok && i == 1)
}

// Hiding or ghosting the selected object moves the selection to the next object in
// reach, past ghosts and hidden ones, or to nothing; picking a hidden one brings it back.
@(test)
hiding_the_selected_moves_the_selection :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	objs[1].ghost = true
	edits := app.view_edits
	scene_view(&app, .Hide, objs[0].id)
	testing.expect(t, objs[0].off)
	testing.expect_value(t, app.scene.selected, 2)
	testing.expect_value(t, app.view_edits, edits + 1)
	testing.expect_value(t, app.scene_edits, 0)
	scene_view(&app, .Ghost, objs[2].id)
	testing.expect_value(t, app.scene.selected, -1)

	scene_view(&app, .Select, objs[0].id)
	testing.expect(t, !objs[0].off)
	testing.expect_value(t, app.scene.selected, 0)
	scene_view(&app, .Select, objs[1].id)
	testing.expect(t, !objs[1].ghost)
	testing.expect_value(t, app.scene.selected, 1)
	scene_view(&app, .Unghost, objs[2].id)
	testing.expect(t, !objs[2].ghost)

	// An unknown id changes nothing.
	edits = app.view_edits
	scene_view(&app, .Hide, 99)
	testing.expect_value(t, app.view_edits, edits)
}

// Solo shows only the selected object and follows the selection; the eyes stay as they
// were, so turning it off brings back exactly the view there was. Show all objects
// turns every eye on and Solo off, and leaves ghosts as they are.
@(test)
solo_follows_the_selection_and_keeps_the_eyes :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	objs[2].off = true
	objs[1].ghost = true
	scene_view(&app, .Solo, objs[0].id)
	testing.expect(t, app.scene.solo)
	testing.expect(t, object_shown(&app, objs[0]) && !object_shown(&app, objs[1]))
	_, ok := hit_at(&app, 3)
	testing.expect(t, !ok)

	scene_view(&app, .Select, objs[1].id)
	testing.expect(t, app.scene.solo && object_shown(&app, objs[1]) && !object_shown(&app, objs[0]))
	scene_view(&app, .Solo, 0)
	testing.expect(t, !app.scene.solo)
	testing.expect(t, object_shown(&app, objs[0]) && object_shown(&app, objs[1]) && !object_shown(&app, objs[2]))

	// A tap on empty space keeps the soloed object selected rather than end Solo.
	objs[1].ghost = true
	app.scene.selected = 0
	scene_view(&app, .Solo, 0)
	scene_deselect(&app)
	testing.expect_value(t, app.scene.selected, 0)
	scene_view(&app, .Show_All, 0)
	scene_deselect(&app)
	testing.expect_value(t, app.scene.selected, -1)
	app.scene.selected = 0
	testing.expect(t, !app.scene.solo && !objs[2].off && objs[1].ghost)

	// Hiding the soloed object hands Solo to the next object in reach, and with none
	// left Solo goes off rather than leave nothing to show.
	scene_view(&app, .Solo, 0)
	scene_view(&app, .Hide, objs[0].id)
	testing.expect_value(t, app.scene.selected, 2)
	testing.expect(t, app.scene.solo && object_shown(&app, objs[2]) && !object_shown(&app, objs[1]))
	scene_view(&app, .Hide, objs[2].id)
	testing.expect_value(t, app.scene.selected, -1)
	testing.expect(t, !app.scene.solo)
}

// The scene file keeps each object's eye and ghost from version 8, reads older files
// with everything in view, and refuses flags it does not know.
@(test)
view_flags_round_trip_in_the_file :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	objs[0].off, objs[1].ghost = true, true
	for obj in objs {
		out: [dynamic]u8
		defer delete(out)
		testing.expect(t, object_put_bytes(&out, obj))
		back: Object
		r := geom.byte_reader(out[:])
		object_get_fields(&r, &back)
		defer delete(back.name)
		testing.expect(t, r.ok)
		testing.expect_value(t, back.off, obj.off)
		testing.expect_value(t, back.ghost, obj.ghost)
		testing.expect_value(t, back.transform, obj.transform)

		// Version 7 had no flags byte: the same bytes read as 7 take the flags for the
		// start of the levels, so write a 7-shaped head by dropping it.
		head := r.at
		old := make([dynamic]u8, 0, len(out))
		defer delete(old)
		append(&old, ..out[:head - 1])
		append(&old, ..out[head:])
		seven: Object
		r7 := geom.byte_reader(old[:])
		object_get_fields(&r7, &seven, 7)
		defer delete(seven.name)
		testing.expect(t, r7.ok && !seven.off && !seven.ghost)
		testing.expect_value(t, r7.at, head - 1)

		out[head - 1] = 4
		damaged: Object
		rd := geom.byte_reader(out[:])
		object_get_fields(&rd, &damaged)
		defer delete(damaged.name)
		testing.expect(t, !rd.ok)
	}
}

// The live boolean's preview stands in for its base and cutters only while it is drawn:
// with the base out of view the cutters draw as themselves, since a press still
// reaches them.
@(test)
a_hidden_base_lets_the_cutters_draw :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	objs[1].boolean = .Subtract
	app.ui.boolean.shown, app.ui.boolean.base = true, objs[0].id
	testing.expect(t, boolean_hides(&app, objs[1], 1) && boolean_hides(&app, objs[0], 0))
	testing.expect(t, !boolean_hides(&app, objs[2], 2))
	objs[0].off = true
	testing.expect(t, !boolean_hides(&app, objs[1], 1))
	objs[0].off = false
	app.scene.selected, app.scene.solo = 1, true
	testing.expect(t, !boolean_hides(&app, objs[1], 1))
}
