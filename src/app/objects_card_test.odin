package main

import "core:testing"
import "core:time"

import "../render"

// Bring to top and Send to bottom keep an object in its folder, moving it to the
// folder's ends, and move a loose object to the list's ends; each is one undo step.
@(test)
to_top_and_bottom_keep_the_folder :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	scene_arrange(&app, {kind = .Arrange, arrange = .New_Folder, id = objs[1].id})
	f := app.scene.folders[0].id
	scene_arrange(&app, {kind = .Arrange, arrange = .Into_Folder, id = objs[2].id, folder = f})
	select_object(&app, objs[2])
	object_to_end(&app, top = true)
	scene_arrange(&app, app.ui.scene_command)
	ids, folders := tree_of(&app)
	testing.expect_value(t, ids, [8]int{1, 3, 2, 0, 0, 0, 0, 0})
	testing.expect_value(t, folders, [8]int{0, f, f, 0, 0, 0, 0, 0})
	testing.expect_value(t, selected_object(&app), objs[2])
	object_to_end(&app, top = false)
	scene_arrange(&app, app.ui.scene_command)
	ids, folders = tree_of(&app)
	testing.expect_value(t, ids, [8]int{1, 2, 3, 0, 0, 0, 0, 0})
	testing.expect_value(t, folders, [8]int{0, f, f, 0, 0, 0, 0, 0})
	// The loose object goes after the folder, to the end of the list.
	select_object(&app, objs[0])
	object_to_end(&app, top = false)
	scene_arrange(&app, app.ui.scene_command)
	ids, folders = tree_of(&app)
	testing.expect_value(t, ids, [8]int{2, 3, 1, 0, 0, 0, 0, 0})
	testing.expect_value(t, folders, [8]int{f, f, 0, 0, 0, 0, 0, 0})
	before := len(app.history.done)
	history_undo(&app)
	ids, _ = tree_of(&app)
	testing.expect_value(t, ids, [8]int{1, 2, 3, 0, 0, 0, 0, 0})
	testing.expect_value(t, len(app.history.done), before - 1)
}

// A folder's polypaint commands set every object in it and nothing else.
@(test)
folder_paint_covers_its_objects :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	scene_arrange(&app, {kind = .Arrange, arrange = .New_Folder, id = objs[1].id})
	f := app.scene.folders[0].id
	scene_view(&app, .Folder_Paint_Hide, f)
	testing.expect(t, !objs[0].paint_off && objs[1].paint_off && !objs[2].paint_off)
	scene_view(&app, .Paint_Hide, objs[2].id)
	scene_view(&app, .Folder_Paint_Show, f)
	testing.expect(t, !objs[1].paint_off && objs[2].paint_off)
}

// A picture's key follows what it shows: the buffers' contents, the paint and its
// toggle, the level and the turn, and not where the object is or how big.
@(test)
thumb_key_follows_what_the_picture_shows :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	obj := objs[0]
	key := thumb_key(obj)
	obj.transform.position, obj.transform.scale = {9, 9, 9}, 4
	testing.expect_value(t, thumb_key(obj), key)
	obj.gpu[0].version += 1
	moved := thumb_key(obj)
	testing.expect(t, moved != key)
	obj.paint_off = true
	testing.expect(t, thumb_key(obj) != moved)
	obj.paint_off = false
	obj.transform.rotation.y = 30
	testing.expect(t, thumb_key(obj) != moved)
}

// A voxel object's key follows its clay's surface buffers, not a mesh level's.
@(test)
thumb_key_of_a_voxel_object_follows_its_clay :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	obj := objs[0]
	vp: Voxel_Part
	obj.voxel = &vp
	defer obj.voxel = nil
	key := thumb_key(obj)
	obj.gpu[0].version += 1
	testing.expect_value(t, thumb_key(obj), key)
	vp.gpu.version += 1
	testing.expect(t, thumb_key(obj) != key)
}

// Each object shown gets its own cell; once every cell is taken, a new object gets the
// one shown longest ago, never one shown this frame.
@(test)
thumb_cells_go_to_the_rows_shown :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	ts := &app.thumb_slots
	_, _, ok := thumb_for(&app, objs[0])
	testing.expect(t, !ok) // nothing drawn yet
	testing.expect_value(t, ts.slots[0].id, objs[0].id)
	// Pretend the frame drew it.
	ts.slots[0].drawn = ts.slots[0].want
	lo, hi, drawn := thumb_for(&app, objs[0])
	testing.expect(t, drawn)
	want_lo, want_hi := render.thumb_uv(0)
	testing.expect(t, lo == want_lo && hi == want_hi)

	// Every other cell taken by objects shown in an earlier frame, the first's this frame.
	for &s, i in ts.slots[1:] do s = {id = 100 + i, used = 0, changed = time.tick_now()}
	ts.slots[5].used = -1 // the one shown longest ago
	_, _, _ = thumb_for(&app, objs[1])
	testing.expect_value(t, ts.slots[5].id, objs[1].id)
	testing.expect_value(t, ts.slots[0].id, objs[0].id)
}
