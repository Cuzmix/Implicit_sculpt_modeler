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
		delete(obj.name)
		free(obj)
	}
	delete(app.scene.objects)
	folders_clear(&app.scene.folders)
	delete(app.scene.folders)
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

		// Version 7 had no flags byte and no folder: write a 7-shaped head by dropping the
		// five bytes after the boolean mode.
		head := r.at
		flags := head - 5
		old := make([dynamic]u8, 0, len(out))
		defer delete(old)
		append(&old, ..out[:flags])
		append(&old, ..out[head:])
		seven: Object
		r7 := geom.byte_reader(old[:])
		object_get_fields(&r7, &seven, 7)
		defer delete(seven.name)
		testing.expect(t, r7.ok && !seven.off && !seven.ghost)
		testing.expect_value(t, r7.at, flags)

		out[flags] = 4
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

// The ids in list order and each one's folder, to compare trees by.
@(private = "file")
tree_of :: proc(app: ^App) -> (ids, folders: [8]int) {
	for obj, i in app.scene.objects[:min(len(app.scene.objects), 8)] do ids[i], folders[i] = obj.id, obj.folder
	return
}

// A folder's objects are kept next to each other where its first one is, an unknown
// folder becomes none, and the selected object stays selected wherever it moves.
@(test)
folders_keep_their_objects_together :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	f := folder_new(&app)
	objs[0].folder, objs[2].folder = f.id, f.id
	app.scene.selected = 1
	testing.expect(t, !folders_contiguous(app.scene.objects[:]))
	scene_folders_normalize(&app)
	ids, folders := tree_of(&app)
	testing.expect_value(t, ids, [8]int{1, 3, 2, 0, 0, 0, 0, 0})
	testing.expect_value(t, folders, [8]int{f.id, f.id, 0, 0, 0, 0, 0, 0})
	testing.expect(t, selected_object(&app) == objs[1])

	objs[1].folder = 99
	scene_folders_normalize(&app)
	testing.expect_value(t, objs[1].folder, 0)
}

// The eye and ghost of a folder apply to every object in it, over their own; picking
// an object from its row brings its folder back too.
@(test)
folder_flags_cover_their_objects :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	f := folder_new(&app)
	objs[1].folder, objs[2].folder = f.id, f.id
	scene_view(&app, .Folder_Ghost, f.id)
	testing.expect(t, object_shown(&app, objs[1]) && !object_pickable(&app, objs[2]))
	scene_view(&app, .Folder_Hide, f.id)
	testing.expect(t, !object_shown(&app, objs[1]) && !object_shown(&app, objs[2]))
	off, ghosts := scene_view_counts(&app)
	testing.expect(t, off == 2 && ghosts == 2)
	_, ok := hit_at(&app, 3)
	testing.expect(t, !ok)
	scene_view(&app, .Select, objs[2].id)
	fp := folder_by_id(&app, f.id)
	testing.expect(t, !fp.off && !fp.ghost)
	testing.expect_value(t, app.scene.selected, 2)
	scene_view(&app, .Folder_Hide, f.id)
	testing.expect_value(t, app.scene.selected, 0)
	scene_view(&app, .Show_All, 0)
	testing.expect(t, !fp.off)
}

// Each change to the tree is one undo step that undo and redo walk exactly, among other
// steps: a new folder, moving into it, renaming, ungrouping.
@(test)
arrange_steps_undo_and_redo :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	start_ids, start_folders := tree_of(&app)
	scene_arrange(&app, {kind = .Arrange, arrange = .New_Folder, id = objs[2].id})
	testing.expect_value(t, len(app.scene.folders), 1)
	f := app.scene.folders[0].id
	testing.expect_value(t, history_next_label(app.history.done[:]), "New folder")
	scene_arrange(&app, {kind = .Arrange, arrange = .Into_Folder, id = objs[0].id, folder = f})
	// The folder's objects gather where its first one is.
	ids, folders := tree_of(&app)
	testing.expect_value(t, ids, [8]int{1, 3, 2, 0, 0, 0, 0, 0})
	testing.expect_value(t, folders, [8]int{f, f, 0, 0, 0, 0, 0, 0})
	moved := Transform{position = {1, 2, 3}, scale = 1}
	before := objs[1].transform
	objs[1].transform = moved
	history_record_transform(&app, objs[1], before, "Move")
	rename := Scene_Command{kind = .Arrange, arrange = .Rename_Object, id = objs[0].id}
	copy(rename.name[:], "Left ear")
	scene_arrange(&app, rename)
	testing.expect_value(t, object_label(objs[0]), "Left ear")
	folder_name := Scene_Command{kind = .Arrange, arrange = .Rename_Folder, id = f}
	copy(folder_name.name[:], "  Ears ")
	scene_arrange(&app, folder_name)
	testing.expect_value(t, folder_label(folder_by_id(&app, f)), "Ears")
	scene_arrange(&app, {kind = .Arrange, arrange = .Ungroup, id = f})
	testing.expect_value(t, len(app.scene.folders), 0)
	testing.expect_value(t, len(app.history.done), 6)
	// Renaming to the same name records nothing.
	same := Scene_Command{kind = .Arrange, arrange = .Rename_Object, id = objs[0].id}
	copy(same.name[:], "Left ear")
	scene_arrange(&app, same)
	testing.expect_value(t, len(app.history.done), 6)

	history_undo(&app) // ungroup
	testing.expect_value(t, folder_label(folder_by_id(&app, f)), "Ears")
	ids, folders = tree_of(&app)
	testing.expect_value(t, folders, [8]int{f, f, 0, 0, 0, 0, 0, 0})
	history_undo(&app) // folder name
	history_undo(&app) // object name
	testing.expect_value(t, object_label(objs[0]), "Sphere 1")
	history_undo(&app) // the move
	testing.expect_value(t, objs[1].transform, before)
	history_undo(&app) // into the folder
	history_undo(&app) // the new folder
	ids, folders = tree_of(&app)
	testing.expect_value(t, ids, start_ids)
	testing.expect_value(t, folders, start_folders)
	testing.expect_value(t, len(app.scene.folders), 0)

	for _ in 0 ..< 6 do history_redo(&app)
	ids, folders = tree_of(&app)
	testing.expect_value(t, ids, [8]int{1, 3, 2, 0, 0, 0, 0, 0})
	testing.expect_value(t, folders, [8]int{0, 0, 0, 0, 0, 0, 0, 0})
	testing.expect_value(t, object_label(objs[0]), "Left ear")
	testing.expect_value(t, objs[1].transform, moved)
	// A new step drops the redo list's layouts, which the tracking allocator checks.
	history_undo(&app)
	scene_arrange(&app, {kind = .Arrange, arrange = .New_Folder, id = objs[1].id})
	testing.expect_value(t, len(app.history.undone), 0)
}

// A layout puts back the objects it lists and leaves alone those it does not: one that
// is gone is skipped, one that came since keeps its place.
@(test)
layout_apply_copes_with_objects_that_came_and_went :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	f := folder_new(&app)
	objs[0].folder = f.id
	l := layout_take(&app)
	defer layout_free(l)
	// Reverse the list, drop the middle object and add a fourth.
	gone := objs[1]
	ordered_remove(&app.scene.objects, 1)
	sculpt.levels_destroy(&gone.levels)
	free(gone)
	extra := new(Object)
	extra.id = 4
	sculpt.levels_init(&extra.levels, geom.icosphere(1), nil, 64)
	inject_at(&app.scene.objects, 0, extra)
	app.scene.objects[1], app.scene.objects[2] = app.scene.objects[2], app.scene.objects[1]
	objs[0].folder = 0
	app.scene.selected = 0
	layout_apply(&app, l)
	ids, folders := tree_of(&app)
	testing.expect_value(t, ids, [8]int{4, 1, 3, 0, 0, 0, 0, 0})
	testing.expect_value(t, folders, [8]int{0, f.id, 0, 0, 0, 0, 0, 0})
	testing.expect(t, selected_object(&app) == extra)
}

// Folders and each object's folder survive the scene file from version 9; damaged
// folder lists are refused whole.
@(test)
folders_round_trip_in_the_file :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	f := folder_new(&app)
	f.name, f.off, f.open = "Ears", true, false
	objs[2].folder = f.id
	defer f.name = ""
	head: [dynamic]u8
	defer delete(head)
	scene_header_put(&app, &head)
	r := geom.byte_reader(head[:])
	r.at = len(head) - (4 + 4 + 4 + len("Ears") + 1 + 4)
	folders, next, ok := folders_get(&r, SCENE_VERSION)
	defer {
		folders_clear(&folders)
		delete(folders)
	}
	testing.expect(t, ok && r.ok && r.at == len(head))
	testing.expect_value(t, len(folders), 1)
	testing.expect(t, folders[0].id == f.id && folders[0].name == "Ears" && folders[0].off && !folders[0].open && !folders[0].ghost)
	testing.expect_value(t, next, app.scene.next_folder_id)
	// The same id twice is damage.
	twice: [dynamic]u8
	defer delete(twice)
	geom.byte_put(&twice, u32(2))
	for _ in 0 ..< 2 {
		geom.byte_put(&twice, i32(1))
		geom.byte_put_string(&twice, "a")
		geom.byte_put(&twice, u8(0))
	}
	geom.byte_put(&twice, i32(1))
	rt := geom.byte_reader(twice[:])
	bad, _, bad_ok := folders_get(&rt, SCENE_VERSION)
	testing.expect(t, !bad_ok && bad == nil)

	out: [dynamic]u8
	defer delete(out)
	testing.expect(t, object_put_bytes(&out, objs[2]))
	back: Object
	ro := geom.byte_reader(out[:])
	object_get_fields(&ro, &back)
	defer delete(back.name)
	testing.expect(t, ro.ok && back.folder == f.id)
}

// Past the swap limit the oldest steps go, and an Arrange entry at the head of a chain
// (Delete folder's) goes with its layouts freed, leaving the swaps after it standing
// alone; the tracking allocator checks nothing leaks.
@(test)
the_swap_limit_drops_an_arrange_head :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	before := layout_take(&app)
	objs[0].folder = folder_new(&app).id
	testing.expect(t, history_record_arrange(&app, before, "Delete folder"))
	history_record_swap(&app, 10, history_snapshot(&app, nil, "delete object"), chain = true)
	history_record_swap(&app, 11, history_snapshot(&app, nil, "delete object"), chain = true)
	testing.expect_value(t, len(app.history.done), 3)
	app.history.swap_bytes = SWAP_LIMIT_BYTES + 1
	history_record_swap(&app, 12, history_snapshot(&app, nil, "add object"))
	testing.expect_value(t, len(app.history.done), 1)
	testing.expect(t, !app.history.done[0].chain && app.history.done[0].id == 12)
}

// A typed name loses the spaces around it and any "##", which would hide what follows.
@(test)
rename_text_is_trimmed_and_shown_whole :: proc(t: ^testing.T) {
	buf: [NAME_BYTES]u8
	copy(buf[:], "  Ear ##2 ")
	testing.expect_value(t, rename_text(buf[:]), "Ear #2")
	blank: [NAME_BYTES]u8
	copy(blank[:], "   ")
	testing.expect_value(t, rename_text(blank[:]), "")
}
