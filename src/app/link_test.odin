package main

import "core:os"
import "core:strings"
import "core:testing"

import "../geom"
import "../jobs"
import "../sculpt"

// A selected sphere with no GPU buffers, placed where an import would put it (its file
// placement is not the identity, which the link must not use), at `id`.
@(private = "file")
link_test_object :: proc(app: ^App, id: int) -> ^Object {
	obj := new(Object)
	obj.id = id
	obj.name = strings.clone("Head")
	obj.transform = {position = {1, 2, 3}, scale = 0.5, rotation = {0, 30, 0}}
	obj.file = {position = {10, 0, 0}, scale = 3}
	sculpt.levels_init(&obj.levels, geom.icosphere(2), nil, 64)
	append(&app.scene.objects, obj)
	app.scene.selected = len(app.scene.objects) - 1
	app.scene.next_id = max(app.scene.next_id, id)
	return obj
}

@(private = "file")
link_test_free :: proc(app: ^App) {
	for obj in app.scene.objects {
		sculpt.levels_destroy(&obj.levels)
		delete(obj.name)
		free(obj)
	}
	delete(app.scene.objects)
	history_destroy(&app.history)
	results_destroy(app)
	link_destroy(app)
}

// Writes Blender's side of a send: `positions` and `indices` as `file` and a manifest
// naming it as object `id` of the scene `token`.
@(private = "file")
link_test_blender :: proc(folder: string, token: u64, seq, id: int, positions: []geom.Vec3, indices: []u32, t: Transform, file := "blender-1.ply") {
	out := make([dynamic]u8)
	defer delete(out)
	geom.mesh_write_ply(&out, positions, indices)
	_ = os.write_entire_file(strings.concatenate({folder, "/", file}, context.temp_allocator), out[:])
	objects := make([dynamic]Link_Object, context.temp_allocator)
	append(&objects, Link_Object{id = id, level = 0, name = "Head", file = file, vertices = len(positions), triangles = len(indices) / 3, transform = t})
	text := link_manifest_text("blender_link", {token = token, seq = seq, objects = objects})
	_ = os.write_entire_file(strings.concatenate({folder, "/", LINK_BACK_FILE}, context.temp_allocator), transmute([]u8)text)
}

// A manifest reads back as it was written, names with spaces and floats bit for bit;
// one that is damaged anywhere, or names a file outside the folder, is refused whole.
@(test)
link_manifest_round_trip :: proc(t: ^testing.T) {
	objects := make([dynamic]Link_Object, context.temp_allocator)
	append(&objects, Link_Object{id = 7, level = 2, name = "Big head %1", file = "7.ply", vertices = 42, triangles = 80, transform = {position = {0.1, -1e-7, 3}, rotation = {0, 1.0 / 3.0, 90}, scale = 0.70710677}})
	append(&objects, Link_Object{id = 0, level = 0, name = "", file = "blender-new-1.ply", vertices = 8, triangles = 12, transform = {scale = 1}})
	text := link_manifest_text("sculpt_link", {token = 0xfeed_0000_0000_0001, seq = 12, objects = objects})
	m, ok := link_manifest_parse(text, "sculpt_link")
	defer link_manifest_free(&m)
	testing.expect(t, ok)
	testing.expect_value(t, m.token, 0xfeed_0000_0000_0001)
	testing.expect_value(t, m.seq, 12)
	testing.expect_value(t, len(m.objects), 2)
	if len(m.objects) == 2 {
		testing.expect_value(t, m.objects[0], Link_Object{id = 7, level = 2, name = m.objects[0].name, file = m.objects[0].file, vertices = 42, triangles = 80, transform = objects[0].transform})
		testing.expect_value(t, m.objects[0].name, "Big head %1")
		testing.expect_value(t, m.objects[1].file, "blender-new-1.ply")
	}
	// The other app's head is not this one's.
	_, other := link_manifest_parse(text, "blender_link", context.temp_allocator)
	testing.expect(t, !other)

	LINE :: "object 7 2 Head 7.ply 42 80 0 0 0 0 0 0 1"
	damaged := [?]string {
		"sculpt_link 1\nsent 1\n" + LINE,                                   // no scene
		"sculpt_link 1\nscene 00000000000000ff\n" + LINE,                   // no number
		"sculpt_link 1\nscene ff\nsent 1\n" + LINE,                         // a short token
		"sculpt_link 1\nscene 00000000000000ff\nsent 1\nobject 7 2 Head ../7.ply 42 80 0 0 0 0 0 0 1",
		"sculpt_link 1\nscene 00000000000000ff\nsent 1\nobject 7 2 Head 7.ply 42 80 0 0 0 0 0 0 0", // no scale
		"sculpt_link 1\nscene 00000000000000ff\nsent 1\nobject 7 2 Head 7.ply 42 80 nan 0 0 0 0 0 1",
		"sculpt_link 1\nscene 00000000000000ff\nsent 1\nobject 7 2 Head 7.ply 42 80 0 0 0 0 0 1",   // a field short
		"sculpt_link 1\nscene 00000000000000ff\nsent 1\nobject 7 99 Head 7.ply 42 80 0 0 0 0 0 0 1", // no such level
		"sculpt_link 1\nscene 00000000000000ff\nsent 1\n" + LINE + "\nobject 7 0 Two 8.ply 42 80 0 0 0 0 0 0 1", // an id twice
	}
	for bad in damaged {
		_, read := link_manifest_parse(bad, "sculpt_link", context.temp_allocator)
		testing.expectf(t, !read, "read %q", bad)
	}
	// A line of a later version is skipped.
	_, later := link_manifest_parse("sculpt_link 2\nscene 00000000000000ff\nsent 1\ncolour 1 2 3\n" + LINE, "sculpt_link", context.temp_allocator)
	testing.expect(t, later)

	for name in ([?]string{"7.ply", "blender-12.ply", "A-b-9.ply"}) do testing.expect(t, link_file_ok(name))
	for name in ([?]string{".ply", "7.obj", "../7.ply", "a/7.ply", "a\\7.ply", "7 .ply", "C:7.ply"}) do testing.expectf(t, !link_file_ok(name), "%q", name)
	testing.expect_value(t, link_folder("dir/settings.txt"), "dir/link")
	testing.expect_value(t, link_folder("dir/run.txt"), "dir/run-link")
	testing.expect_value(t, link_folder(""), "")
}

// A send writes the object's own positions (not its file placement) and a manifest; a
// return with one vertex moved and the object turned moves that vertex and the turn as
// one undo step, which undoes and redoes bit for bit; the same send is not taken twice;
// an untouched return records nothing.
@(test)
link_round_trip_moves_and_undoes :: proc(t: ^testing.T) {
	FOLDER :: "build/link_test"
	_ = os.remove_all(FOLDER)
	defer os.remove_all(FOLDER)
	app: App
	defer link_test_free(&app)
	link_init(&app, FOLDER, false)
	obj := link_test_object(&app, 3)
	mesh := object_mesh(obj)
	original := make([]geom.Vec3, len(mesh.positions))
	defer delete(original)
	copy(original, mesh.positions[:])

	link_send(&app)
	testing.expect_value(t, app.link.sends, 1)
	testing.expect(t, app.scene.link_token != 0)
	data, err := os.read_entire_file(FOLDER + "/3.ply", context.allocator)
	testing.expect(t, err == nil)
	sent, failed, _ := geom.mesh_read_ply(data, nil)
	delete(data)
	defer geom.mesh_destroy(&sent)
	testing.expect_value(t, failed, geom.Mesh_File_Error.None)
	testing.expect(t, len(sent.positions) == len(original) && link_count_moved(sent.positions[:], original, nil) == 0)
	testing.expect(t, link_same_triangles(sent.indices[:], mesh.indices[:], nil))

	// Blender moves vertex 5 and turns the object.
	moved := make([]geom.Vec3, len(original))
	defer delete(moved)
	copy(moved, original)
	moved[5] += {0, 0.25, 0}
	turned := obj.transform
	turned.rotation.y = 45
	link_test_blender(FOLDER, app.scene.link_token, 1, 3, moved, sent.indices[:], turned)
	testing.expect(t, link_get(&app))
	testing.expect_value(t, app.link.moved, 1)
	testing.expect_value(t, len(app.history.done), 2)
	testing.expect_value(t, obj.transform, turned)
	testing.expect_value(t, link_count_moved(mesh.positions[:], moved, nil), 0)
	testing.expect(t, strings.contains(app.result.text, "moved 1 vertex)"))

	history_undo(&app)
	testing.expect_value(t, len(app.history.done), 0)
	testing.expect_value(t, link_count_moved(mesh.positions[:], original, nil), 0)
	testing.expect_value(t, obj.transform.rotation.y, 30)
	history_redo(&app)
	testing.expect_value(t, link_count_moved(mesh.positions[:], moved, nil), 0)
	testing.expect_value(t, obj.transform, turned)

	// Taken already: nothing happens.
	testing.expect(t, link_get(&app))
	testing.expect_value(t, len(app.history.done), 2)
	testing.expect(t, strings.contains(app.result.text, "Nothing new"))

	// A later send of the same shape: nothing to record.
	link_test_blender(FOLDER, app.scene.link_token, 2, 3, moved, sent.indices[:], turned)
	testing.expect(t, link_get(&app))
	testing.expect_value(t, len(app.history.done), 2)
	testing.expect(t, strings.contains(app.result.text, "unchanged"))
}

// What a get plans for each object: a new object for one Blender made, one of another
// scene and one deleted here; a new mesh for other triangles; moved vertices for the
// same triangles at the level sent. A file that is short of what the manifest says
// changes nothing, and is not taken.
@(test)
link_plans_and_refuses :: proc(t: ^testing.T) {
	FOLDER :: "build/link_plan_test"
	_ = os.remove_all(FOLDER)
	defer os.remove_all(FOLDER)
	app: App
	defer link_test_free(&app)
	link_init(&app, FOLDER, false)
	obj := link_test_object(&app, 4)
	app.scene.link_token = 0xabc
	mesh := object_mesh(obj)^
	same := geom.Mesh{positions = mesh.positions, indices = mesh.indices}
	o := Link_Object{id = 4, level = 0, vertices = len(mesh.positions), triangles = len(mesh.indices) / 3, transform = obj.transform}

	action, target, why := link_plan(&app, o, 0xabc, same)
	testing.expect_value(t, action, Link_Action.Project)
	testing.expect(t, target == obj)
	_, _, why = link_plan(&app, o, 0xdef, same)
	testing.expect_value(t, why, Link_Why.Other_Scene)
	_, _, why = link_plan(&app, {id = 0}, 0xabc, same)
	testing.expect_value(t, why, Link_Why.Made)
	_, _, why = link_plan(&app, {id = 9}, 0xabc, same)
	testing.expect_value(t, why, Link_Why.Gone)
	_, _, why = link_plan(&app, {id = 4, level = 1}, 0xabc, same)
	testing.expect_value(t, why, Link_Why.Level_Gone)
	flipped := make([dynamic]u32, len(mesh.indices))
	defer delete(flipped)
	copy(flipped[:], mesh.indices[:])
	flipped[0], flipped[1] = flipped[1], flipped[0]
	action, _, why = link_plan(&app, o, 0xabc, {positions = mesh.positions, indices = flipped})
	testing.expect_value(t, action, Link_Action.Swap)
	testing.expect_value(t, why, Link_Why.Topology)

	// Serial and parallel compares agree.
	pool: jobs.Pool
	jobs.pool_init(&pool, 4)
	defer jobs.pool_destroy(&pool)
	big := make([]u32, 3 << 20)
	defer delete(big)
	for &x, i in big do x = u32(i)
	other := make([]u32, len(big))
	defer delete(other)
	copy(other, big)
	testing.expect(t, link_same_triangles(big, other, &pool) && link_same_triangles(big, other, nil))
	other[len(other) - 2] += 1
	testing.expect(t, !link_same_triangles(big, other, &pool) && !link_same_triangles(big, other, nil))

	// Blender says more vertices than its file holds: still being written.
	testing.expect(t, os.make_directory_all(FOLDER) == nil)
	link_test_blender(FOLDER, 0xabc, 1, 4, mesh.positions[:10], mesh.indices[:9], obj.transform)
	short := make([dynamic]Link_Object, context.temp_allocator)
	append(&short, Link_Object{id = 4, name = "Head", file = "blender-1.ply", vertices = 11, triangles = 3, transform = obj.transform})
	text := link_manifest_text("blender_link", {token = 0xabc, seq = 1, objects = short})
	_ = os.write_entire_file(FOLDER + "/" + LINK_BACK_FILE, transmute([]u8)text)
	testing.expect(t, link_get(&app))
	testing.expect_value(t, len(app.history.done), 0)
	testing.expect_value(t, app.link.taken, 0)
	testing.expect(t, strings.contains(app.result.text, "still being written"))
}

// The focus check waits while a request is pending, and asks for a get only of a new send
// for this scene.
@(test)
link_focus_waits_and_asks :: proc(t: ^testing.T) {
	FOLDER :: "build/link_focus_test"
	_ = os.remove_all(FOLDER)
	defer os.remove_all(FOLDER)
	testing.expect(t, os.make_directory_all(FOLDER) == nil)
	app: App
	defer link_test_free(&app)
	link_init(&app, FOLDER, true)
	obj := link_test_object(&app, 2)
	mesh := object_mesh(obj)
	link_test_blender(FOLDER, 0x77, 1, 2, mesh.positions[:], mesh.indices[:], obj.transform)

	// Another scene's send is left for Get from Blender.
	app.scene.link_token = 0x55
	link_focus(&app)
	link_frame(&app)
	testing.expect(t, !app.link.check)
	testing.expect_value(t, file_pending_kind(), File_Kind.None)

	app.scene.link_token = 0x77
	file_post(.Import, "rock.obj")
	link_focus(&app)
	link_frame(&app)
	testing.expect(t, app.link.check)
	req, taken := file_take(&app)
	testing.expect(t, taken)
	file_request_free(req)
	link_frame(&app)
	testing.expect(t, !app.link.check)
	req, taken = file_take(&app)
	testing.expect(t, taken && req.kind == .Link_Get && req.path == LINK_AUTO)
	file_request_free(req)
	// Without a person (auto off) focus does nothing.
	app.link.auto = false
	link_focus(&app)
	testing.expect(t, !app.link.check)
}
