package poly

import "core:math/linalg"
import "core:testing"

@(test)
bevel_creases_live_on_a_cube :: proc(t: ^testing.T) {
	// Every edge of a cube creased and bevelled with two segments: each edge a strip of two
	// faces, each corner a patch, the cube's six faces kept and still their own.
	cube := primitive(.Cube)
	defer mesh_destroy(&cube)
	testing.expect_value(t, crease_by_angle(&cube, 30), 12)
	lm, err := live_build(&cube, {bevel = 0.1, bevel_segments = 2})
	defer live_mesh_destroy(&lm)
	testing.expect_value(t, err, Build_Error.None)
	testing.expect(t, !lm.bevel_refused)
	c := mesh_check(&lm.mesh)
	testing.expect(t, check_ok(c))
	testing.expect_value(t, c.border_edges, 0)
	testing.expect_value(t, c.faces, 6 + 12 * 2 + 8)
	// The cube's faces first, as they were; each strip takes the face beside its edge; the
	// eight corner patches take none.
	for f in 0 ..< u32(6) do testing.expect_value(t, lm.face_from[f], f)
	kept := 0
	for f in lm.face_from do if f != NONE do kept += 1
	testing.expect_value(t, kept, 6 + 12 * 2)
	// The bevelled edges are gone, so no crease is left to sharpen the strips.
	creased := 0
	for e in lm.mesh.crease do if e > 0 do creased += 1
	testing.expect_value(t, creased, 0)
	// Each cube corner had three bevelled edges, so the bevel replaced it by the corner
	// patch's points, and every edge is a strip.
	for v in 0 ..< len(cube.positions) do testing.expect(t, lm.vert_first[v + 1] - lm.vert_first[v] >= 3)
	for e in lm.edge do testing.expect_value(t, e, NONE)
	// Off, or with nothing creased, the stack is the cage.
	plain := primitive(.Cube)
	defer mesh_destroy(&plain)
	same, _ := live_build(&plain, {bevel = 0.1, bevel_segments = 2})
	defer live_mesh_destroy(&same)
	testing.expect_value(t, len(same.mesh.face_he), 6)
	for v, i in same.vert_ids do testing.expect_value(t, v, u32(i))
	for h, e in same.edge {
		a, b := edge_verts(&plain, u32(e))
		testing.expect(t, same.mesh.he_vert[h] == a && he_tip(&same.mesh, h) == b)
	}
}

@(test)
bevel_creases_live_refuses_a_border :: proc(t: ^testing.T) {
	// A crease on a plane's border cannot be bevelled; the stack draws the cage without the
	// bevel and says so.
	plane := primitive(.Plane)
	defer mesh_destroy(&plane)
	for &c in plane.crease do c = 1
	lm, err := live_build(&plane, {bevel = 0.05, bevel_segments = 1})
	defer live_mesh_destroy(&lm)
	testing.expect_value(t, err, Build_Error.None)
	testing.expect(t, lm.bevel_refused)
	testing.expect_value(t, len(lm.mesh.face_he), len(plane.face_he))
}

@(test)
thickness_closes_a_plane :: proc(t: ^testing.T) {
	// A plane of four faces, 0.1 thick with two rim segments: both sides, a rim of 8 border
	// edges by 2, closed and sound, the cage's points where they were.
	plane := primitive(.Plane, {across = 2})
	defer mesh_destroy(&plane)
	for side in Thickness_Side {
		lm, err := live_build(&plane, {thickness = 0.1, thickness_segments = 2, side = side})
		defer live_mesh_destroy(&lm)
		testing.expect_value(t, err, Build_Error.None)
		c := mesh_check(&lm.mesh)
		testing.expect(t, check_ok(c))
		testing.expect_value(t, c.border_edges, 0)
		testing.expect_value(t, c.faces, 2 * 4 + 8 * 2)
		testing.expect_value(t, len(lm.face_from), c.faces)
		for v, i in lm.vert_ids do testing.expect_value(t, v, u32(i))
		// The shell's sides lie the thickness apart along the plane's normal, the side
		// facing out first, at the cage's points' ids.
		n := vert_normal(&plane, 0)
		near := linalg.dot(lm.mesh.positions[0] - plane.positions[0], n)
		far := linalg.dot(lm.mesh.positions[len(plane.positions)] - plane.positions[0], n)
		want_near, want_far: f32 = 0.1, 0
		if side == .In do want_near, want_far = 0, -0.1
		if side == .Centre do want_near, want_far = 0.05, -0.05
		testing.expect(t, abs(near - want_near) < 1e-5 && abs(far - want_far) < 1e-5)
		// Every face faces out of the shell: away from the middle of the two sides.
		mid := (lm.mesh.positions[0] + lm.mesh.positions[len(plane.positions)]) / 2
		for f in 0 ..< u32(4) {
			out := linalg.dot(face_normal(&lm.mesh, f), face_center(&lm.mesh, f) - mid)
			back := linalg.dot(face_normal(&lm.mesh, f + 4), face_center(&lm.mesh, f + 4) - mid)
			testing.expect(t, out > 0 && back > 0)
		}
	}
}

@(test)
bevel_follows_the_cage_edges_it_shortens :: proc(t: ^testing.T) {
	// One creased edge of a cube bevelled: the four edges meeting its ends still map to
	// live edges, running the same way, from the strip's side points.
	cube := primitive(.Cube)
	defer mesh_destroy(&cube)
	cube.crease[0] = 1
	lm, _ := live_build(&cube, {bevel = 0.1, bevel_segments = 1})
	defer live_mesh_destroy(&lm)
	testing.expect_value(t, lm.edge[0], NONE)
	for h, e in lm.edge {
		if e == 0 do continue
		testing.expect(t, h != NONE)
		a, b := edge_verts(&cube, u32(e))
		way := linalg.normalize(cube.positions[b] - cube.positions[a])
		got := linalg.normalize(lm.mesh.positions[he_tip(&lm.mesh, h)] - lm.mesh.positions[lm.mesh.he_vert[h]])
		testing.expect(t, linalg.dot(way, got) > 0.99)
	}
	// The thickened plane's rim loops are creased, so a bevel rounds the plate's edges.
	plane := primitive(.Plane)
	defer mesh_destroy(&plane)
	plate, err := live_build(&plane, {thickness = 0.1, thickness_segments = 1, bevel = 0.02, bevel_segments = 2})
	defer live_mesh_destroy(&plate)
	testing.expect_value(t, err, Build_Error.None)
	testing.expect(t, !plate.bevel_refused)
	c := mesh_check(&plate.mesh)
	testing.expect(t, check_ok(c) && c.border_edges == 0)
	testing.expect(t, c.faces > 2 + 4)
}

@(test)
live_stack_bevels_then_thickens :: proc(t: ^testing.T) {
	// A closed cube with one crease bevelled and then a hollow shell: two closed surfaces,
	// the same both times it is built.
	cube := primitive(.Cube)
	defer mesh_destroy(&cube)
	cube.crease[0] = INFINITE_SHARP
	l := Live{bevel = 0.1, bevel_segments = 3, thickness = 0.05, thickness_segments = 1, side = .In}
	a, a_err := live_build(&cube, l)
	defer live_mesh_destroy(&a)
	b, _ := live_build(&cube, l)
	defer live_mesh_destroy(&b)
	testing.expect_value(t, a_err, Build_Error.None)
	c := mesh_check(&a.mesh)
	testing.expect(t, check_ok(c))
	testing.expect_value(t, c.border_edges, 0)
	testing.expect_value(t, len(a.mesh.positions), len(b.mesh.positions))
	for p, i in a.mesh.positions do testing.expect_value(t, p, b.mesh.positions[i])
	for f, i in a.face_from do testing.expect_value(t, f, b.face_from[i])
}

@(test)
mirror_live_closes_a_half_box :: proc(t: ^testing.T) {
	// A cube without its -x face, moved so the opening lies on x = 0, one of its far edges
	// creased: mirrored across X it is a closed box twice as long, the seam's four points
	// shared, the cage's faces first and their images after, the crease on both halves.
	box := primitive(.Cube)
	defer mesh_destroy(&box)
	side := NONE
	for f in 0 ..< u32(len(box.face_he)) do if face_normal(&box, f).x < -0.9 do side = f
	r, err := delete_faces(&box, {side})
	edit_result_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	length := mesh_bounds(&box).hi.x
	for &p in box.positions do p.x += length
	length *= 2
	far := NONE
	for e in 0 ..< u32(len(box.crease)) {
		a, b := edge_verts(&box, e)
		if box.positions[a].x > length / 2 && box.positions[b].x > length / 2 {
			far = e
			break
		}
	}
	box.crease[far] = 1
	// A seam point a little off the plane still joins it, and is put on it.
	seam := NONE
	for p, v in box.positions do if p.x < length / 2 do seam = u32(v)
	box.positions[seam].x = 1e-4
	lm, build_err := live_build(&box, {mirror = {.X}})
	defer live_mesh_destroy(&lm)
	testing.expect_value(t, build_err, Build_Error.None)
	testing.expect(t, !lm.mirror_refused)
	c := mesh_check(&lm.mesh)
	testing.expect(t, check_ok(c))
	testing.expect_value(t, c.vertices, 12)
	testing.expect_value(t, c.faces, 10)
	testing.expect_value(t, c.border_edges, 0)
	for f in 0 ..< 5 do testing.expect_value(t, lm.face_from[f], u32(f))
	for f in 5 ..< 10 do testing.expect_value(t, lm.face_from[f], NONE)
	testing.expect_value(t, lm.mesh.positions[seam].x, 0)
	creased := 0
	for e in lm.mesh.crease do if e > 0 do creased += 1
	testing.expect_value(t, creased, 2)
	b := mesh_bounds(&lm.mesh)
	testing.expect(t, abs(b.lo.x + length) < 1e-5 && abs(b.hi.x - length) < 1e-5)
	// With Thickness too the shell is closed round both halves; the cage's points still
	// come first.
	shell, shell_err := live_build(&box, {mirror = {.X}, thickness = 0.1, thickness_segments = 1})
	defer live_mesh_destroy(&shell)
	testing.expect_value(t, shell_err, Build_Error.None)
	testing.expect(t, check_ok(mesh_check(&shell.mesh)))
	for v, i in shell.vert_ids do testing.expect_value(t, v, u32(i))
}

@(test)
mirror_live_refuses_a_face_across_the_plane :: proc(t: ^testing.T) {
	// A plane of two by two faces on y = 0 lies across x = 0: its middle edges already have
	// two faces, so across X the mirror is left out and the stack is the plane; across Y,
	// the plane it lies in, the same. Moved off x = 0, its image across X is a second plane
	// beside it.
	plane := primitive(.Plane, {across = 2})
	defer mesh_destroy(&plane)
	for axes in ([2]Mirror_Axes{{.X}, {.Y}}) {
		lm, err := live_build(&plane, {mirror = axes})
		defer live_mesh_destroy(&lm)
		testing.expect_value(t, err, Build_Error.None)
		testing.expect(t, lm.mirror_refused)
		testing.expect_value(t, len(lm.mesh.face_he), 4)
	}
	for &p in plane.positions do p.x += 3
	apart, apart_err := live_build(&plane, {mirror = {.X}})
	defer live_mesh_destroy(&apart)
	testing.expect_value(t, apart_err, Build_Error.None)
	testing.expect(t, !apart.mirror_refused)
	c := mesh_check(&apart.mesh)
	testing.expect(t, check_ok(c))
	testing.expect_value(t, c.vertices, 18)
	testing.expect_value(t, c.faces, 8)
}
