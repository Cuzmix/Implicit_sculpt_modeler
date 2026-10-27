package main

import "core:slice"
import "core:testing"

import "../geom"
import "../sculpt"

// Two spheres side by side as one object: a merge of the scene's first two.
@(private = "file")
merged_object :: proc(app: ^App, objs: [3]^Object) -> ^Object {
	pair := [2]^Object{objs[0], objs[1]}
	mesh, surface, ok := merge_meshes(pair[:], objs[0].transform)
	assert(ok)
	defer delete(surface.groups)
	obj := new(Object)
	obj.id = 9
	obj.transform = {scale = 1}
	old_to_new := make([]u32, len(mesh.positions), context.temp_allocator)
	tri_from := make([]u32, len(mesh.indices) / 3, context.temp_allocator)
	sculpt.levels_init(&obj.levels, mesh, nil, 64, old_to_new = old_to_new, tri_from = tri_from)
	sculpt.levels_take_surface(&obj.levels, nil, surface.groups, old_to_new, tri_from)
	append(&app.scene.objects, obj)
	return obj
}

// A merge keeps each object's part as a polygroup of its own, numbered on densely (one
// object's two groups become two numbers after the first object's one), and Groups split
// and Split to parts each find the parts again.
@(test)
merge_keeps_parts_that_split_finds_again :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	// The second sphere's lower half masked and made a group of its own.
	s := object_sculptor(objs[1])
	testing.expect(t, sculpt.sculptor_mask_command(s, .Fill))
	for p, v in s.mesh.positions do if p.y > 0 do s.mask[v] = 0
	testing.expect(t, sculpt.sculptor_group_command(s, .Masked))
	obj := merged_object(&app, objs)
	m := object_mesh(obj)
	testing.expect_value(t, len(m.positions), len(object_mesh(objs[0]).positions) + len(object_mesh(objs[1]).positions))
	groups := sculpt.sculptor_groups(object_sculptor(obj))
	kinds := slice.clone(groups, context.temp_allocator)
	slice.sort(kinds)
	testing.expect_value(t, len(slice.unique(kinds)), 3)
	testing.expect_value(t, kinds[0], 0)

	part, count, why := split_parts(obj, .Groups)
	testing.expect_value(t, why, "")
	testing.expect_value(t, count, 3)
	testing.expect_value(t, len(part), len(m.indices) / 3)
	_, count, why = split_parts(obj, .Parts)
	testing.expect_value(t, why, "")
	testing.expect_value(t, count, 2)
	// Nothing hidden or masked: nothing to split, with the reason.
	_, count, why = split_parts(obj, .Hidden)
	testing.expect(t, count == 0 && why != "")
	_, _, why = split_parts(obj, .Masked)
	testing.expect(t, why != "")
	// One sphere is in one piece.
	_, count, why = split_parts(objs[0], .Parts)
	testing.expect(t, count == 0 && why != "")
}

// Masked splits by triangles masked at every corner; all of it masked is refused.
@(test)
split_masked_takes_the_masked_triangles :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	s := object_sculptor(objs[0])
	testing.expect(t, sculpt.sculptor_mask_command(s, .Fill))
	_, _, why := split_parts(objs[0], .Masked)
	testing.expect_value(t, why, "all of it is masked")
	for p, v in s.mesh.positions do if p.x < 0.2 do s.mask[v] = 0
	part, count, none := split_parts(objs[0], .Masked)
	testing.expect_value(t, none, "")
	testing.expect_value(t, count, 2)
	m := s.mesh
	for k, tri in part {
		every := true
		for c in 0 ..< 3 do every &&= s.mask[m.indices[3 * tri + c]] >= sculpt.MASK_HALF
		testing.expect_value(t, k == 1, every)
	}
}

// Align: one object alone goes to the edge of everything shown; several line up with
// the first selected; each moved object is one entry of one step, which undo takes back.
@(test)
align_lines_objects_up :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	all := geom.AABB_EMPTY
	for obj in objs do all = geom.aabb_union(all, object_world_bounds(obj))
	select_object(&app, objs[0])
	align_objects(&app, 0, 2)
	testing.expect(t, abs(object_world_bounds(objs[0]).hi.x - all.hi.x) < 1e-4)
	testing.expect_value(t, len(app.history.done), 1)
	history_undo(&app)
	testing.expect_value(t, objs[0].transform.position.x, 0)

	selection_set(&app, {objs[1].id, objs[0].id, objs[2].id})
	align_objects(&app, 0, 0)
	want := object_world_bounds(objs[1]).lo.x
	for obj in objs do testing.expect(t, abs(object_world_bounds(obj).lo.x - want) < 1e-4)
	testing.expect_value(t, len(app.history.done), 2)
	testing.expect(t, app.history.done[1].chain && !app.history.done[0].chain)
	testing.expect_value(t, objs[1].transform.position.x, 3)
	history_undo(&app)
	testing.expect_value(t, objs[0].transform.position.x, 0)
	testing.expect_value(t, objs[2].transform.position.x, 6)
}

// Distribute spaces the middles evenly between the outermost two, which stay; with
// fewer than three objects it refuses.
@(test)
distribute_spaces_objects_evenly :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	objs[1].transform.position.x = 1
	objs[2].transform.position.x = 10
	select_object(&app, objs[0])
	distribute_objects(&app, 0, 1)
	testing.expect_value(t, objs[0].transform.position.x, 0)
	testing.expect(t, abs(objs[1].transform.position.x - 5) < 1e-4)
	testing.expect_value(t, objs[2].transform.position.x, 10)
	testing.expect_value(t, len(app.history.done), 1)
	objs[2].off = true
	before := len(app.history.done)
	distribute_objects(&app, 0, 1)
	testing.expect_value(t, len(app.history.done), before)
}

// Stored visibility: each slot keeps its own eyes, a slot never chosen takes the eyes as
// they are, and the selected object stays in view whatever its slot says.
@(test)
visibility_slots_keep_their_own_eyes :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	select_object(&app, objs[0])
	scene_view(&app, .Visibility_Slot, 1)
	scene_view(&app, .Hide, objs[1].id)
	scene_view(&app, .Visibility_Slot, 2)
	testing.expect(t, objs[1].off && !objs[2].off)
	scene_view(&app, .Show, objs[1].id)
	scene_view(&app, .Hide, objs[2].id)
	scene_view(&app, .Visibility_Slot, 1)
	testing.expect(t, objs[1].off && !objs[2].off)
	scene_view(&app, .Visibility_Slot, 2)
	testing.expect(t, !objs[1].off && objs[2].off)
	testing.expect_value(t, app.scene.vis_used, 3)
	// V1 hid the object selected now; it stays shown.
	select_object(&app, objs[1])
	scene_view(&app, .Visibility_Slot, 1)
	testing.expect(t, !objs[1].off)
	testing.expect_value(t, app.scene.vis_slot, 1)
}

// The stored eyes go into the file and come back, older files read with none, and a
// header naming a slot it never filled is damage.
@(test)
visibility_slots_round_trip_in_the_file :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	objs[0].vis_off = 0b1010_0001
	out: [dynamic]u8
	defer delete(out)
	testing.expect(t, object_put_bytes(&out, objs[0]))
	back: Object
	r := geom.byte_reader(out[:])
	object_get_fields(&r, &back)
	defer delete(back.name)
	testing.expect(t, r.ok)
	testing.expect_value(t, back.vis_off, objs[0].vis_off)
	// Version 11 had no such byte: it reads one byte less and keeps none.
	eleven: Object
	r11 := geom.byte_reader(out[:])
	object_get_fields(&r11, &eleven, 11)
	defer delete(eleven.name)
	testing.expect(t, r11.ok && eleven.vis_off == 0)
	testing.expect_value(t, r11.at, r.at - 1)

	app.scene.vis_slot, app.scene.vis_used = 3, 0b100
	head: [dynamic]u8
	defer delete(head)
	scene_header_put(&app, &head)
	testing.expect_value(t, head[len(head) - 2], 3)
	testing.expect_value(t, head[len(head) - 1], 0b100)
}

// Past the swap limit the newest step stays whole however large it is, so a merge's
// rebuild and the delete chained to it always undo together.
@(test)
the_swap_limit_keeps_the_newest_step_whole :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	_ = tree_scene(&app)
	app.history.swap_limit = 1
	history_record_swap(&app, 1, history_snapshot(&app, app.scene.objects[0], "merge down"))
	history_record_swap(&app, 2, history_snapshot(&app, app.scene.objects[1], "merge down"), chain = true)
	testing.expect_value(t, len(app.history.done), 2)
	testing.expect(t, app.history.done[1].chain)
	// A newer step drops the older one whole, chained entry and all.
	history_record_swap(&app, 3, history_snapshot(&app, app.scene.objects[2], "remesh"))
	testing.expect_value(t, len(app.history.done), 1)
	testing.expect_value(t, app.history.done[0].id, 3)
}
