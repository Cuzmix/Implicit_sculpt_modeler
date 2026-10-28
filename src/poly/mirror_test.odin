package poly

import "core:math/linalg"
import "core:testing"

@(test)
a_cube_face_mirrors_to_its_opposite :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	// The face whose centre lies furthest along +x.
	right := NONE
	for f in 0 ..< u32(len(m.face_he)) do if face_center(&m, f).x > 0.1 do right = f
	testing.expect(t, right != NONE)
	faces := mirror_faces(&m, {right}, {.X})
	defer delete(faces)
	testing.expect_value(t, len(faces), 2)
	other := faces[0] if faces[0] != right else faces[1]
	testing.expect(t, face_center(&m, other).x < -0.1)
	// Across a plane the face lies on no side of (y and z), it is its own image.
	same := mirror_faces(&m, {right}, {.Y, .Z})
	defer delete(same)
	testing.expect_value(t, len(same), 1)
}

@(test)
mirrored_edges_and_points_on_a_cube :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	// Every axis: one corner's images are all eight corners.
	points := mirror_points(&m, {0}, {.X, .Y, .Z})
	defer delete(points)
	testing.expect_value(t, len(points), 8)
	// An edge along x has one image across y and one across z, and itself across x.
	along := NONE
	for e in 0 ..< u32(len(m.crease)) {
		a, b := edge_verts(&m, e)
		if m.positions[a].x != m.positions[b].x {
			along = e
			break
		}
	}
	edges := mirror_edges(&m, {along}, {.X, .Y, .Z})
	defer delete(edges)
	testing.expect_value(t, len(edges), 4)
	testing.expect_value(t, edges[0], along)
}

@(test)
extruding_a_face_and_its_mirror_keeps_the_cage_symmetric :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	right := NONE
	for f in 0 ..< u32(len(m.face_he)) do if face_center(&m, f).x > 0.1 do right = f
	faces := mirror_faces(&m, {right}, {.X})
	defer delete(faces)
	r, d, err := extrude_faces(&m, faces, false, false)
	defer face_ring_destroy(&r)
	defer drag_set_destroy(&d)
	testing.expect_value(t, err, Build_Error.None)
	drag_apply(&m, &d, 0.5)
	b := mesh_bounds(&m)
	// Out by the same on both sides.
	testing.expectf(t, abs(b.hi.x + b.lo.x) < 1e-5, "bounds %v", b)
	testing.expect(t, check_ok(mesh_check(&m)))
}

@(test)
a_mirrored_loop_finds_the_edge_it_goes_on :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	along := NONE
	for e in 0 ..< u32(len(m.crease)) {
		a, b := edge_verts(&m, e)
		if m.positions[a].x != m.positions[b].x {
			along = e
			break
		}
	}
	r, err := insert_loop(&m, along, 0.25)
	defer loop_insert_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	v := r.verts[r.pressed]
	p := m.positions[v]
	ends := r.ends[r.pressed]
	way := m.positions[ends[1]] - m.positions[ends[0]]
	flip := Vec3{-1, 1, 1}
	// The new point has no image yet; the corner it started from has one.
	each := mirror_point_each(&m, v, {.X})
	testing.expect_value(t, len(each), 2)
	testing.expect_value(t, each[0], v)
	testing.expect_value(t, each[1], NONE)
	corners := mirror_point_each(&m, ends[0], {.X})
	testing.expect(t, corners[1] != NONE && m.positions[corners[1]] == m.positions[ends[0]] * flip)
	// Its mirror lies inside the part of the split edge the loop left.
	e, share, found := edge_through(&m, p * flip, way * flip, mirror_slack(&m))
	testing.expect(t, found)
	a, b := edge_verts(&m, e)
	at := linalg.lerp(m.positions[a], m.positions[b], share)
	testing.expectf(t, linalg.length(at - p * flip) < 1e-5, "%v is not %v", at, p * flip)
	// The new point itself is no edge's inside.
	_, _, on_point := edge_through(&m, p, way, mirror_slack(&m))
	testing.expect(t, !on_point)
}
