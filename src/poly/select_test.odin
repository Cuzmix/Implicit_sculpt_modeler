package poly

import "core:testing"

import "../geom"

@(test)
growing_and_shrinking_the_selection_on_a_cube :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	count :: proc(m: ^Mesh) -> (n: int) {
		for x in m.selected do if x do n += 1
		return
	}
	testing.expect(t, select_set(&m, {0}, true))
	testing.expect(t, !select_set(&m, {0}, true))
	// One face grows to it and its four neighbours, then to the whole cube.
	testing.expect(t, select_op(&m, .Grow))
	testing.expect_value(t, count(&m), 5)
	select_op(&m, .Grow)
	testing.expect_value(t, count(&m), 6)
	testing.expect(t, !select_op(&m, .Shrink))
	// Five faces shrink to the one across from the face left out.
	select_set(&m, {0}, false)
	select_op(&m, .Shrink)
	testing.expect_value(t, count(&m), 1)
	testing.expect(t, !m.selected[0])
	select_op(&m, .Invert)
	testing.expect_value(t, count(&m), 5)
	select_op(&m, .None)
	testing.expect_value(t, count(&m), 0)
}

@(test)
the_selection_follows_edits_and_files :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	select_set(&m, {2}, true)
	r, d, err := extrude_faces(&m, {2}, false, false)
	face_ring_destroy(&r)
	drag_set_destroy(&d)
	testing.expect_value(t, err, Build_Error.None)
	// The extruded face stays selected; its new sides are not.
	picked := make([dynamic]u32)
	defer delete(picked)
	selected_faces(&m, &picked)
	testing.expect_value(t, len(picked), 1)
	testing.expect_value(t, len(m.selected), len(m.face_he))
	out: [dynamic]u8
	defer delete(out)
	mesh_write(&m, &out)
	rd := geom.byte_reader(out[:])
	back, ok := mesh_read(&rd)
	defer mesh_destroy(&back)
	testing.expect(t, ok)
	again := make([dynamic]u32)
	defer delete(again)
	selected_faces(&back, &again)
	testing.expect(t, len(again) == 1 && again[0] == picked[0])
}

@(test)
similar_faces_share_corners_and_area :: proc(t: ^testing.T) {
	m := primitive(.Cylinder, {around = 8, along = 2})
	defer mesh_destroy(&m)
	out := make([dynamic]u32)
	defer delete(out)
	lid := NONE
	for f in 0 ..< u32(len(m.face_he)) do if face_size(&m, f) == 8 do lid = f
	similar_faces(&m, lid, &out)
	testing.expect_value(t, len(out), 2)
	side := NONE
	for f in 0 ..< u32(len(m.face_he)) do if face_size(&m, f) == 4 do side = f
	similar_faces(&m, side, &out)
	testing.expect_value(t, len(out), 16)
}
