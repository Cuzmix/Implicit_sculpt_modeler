package poly

import "core:math"
import "core:math/linalg"
import "core:testing"

import "../geom"

@(private = "file")
closed_volume :: proc(m: ^Mesh) -> (volume: f64, closed: bool) {
	t := geom.Mesh{positions = make([dynamic]Vec3), normals = make([dynamic]Vec3), indices = make([dynamic]u32)}
	defer geom.mesh_destroy(&t)
	tri_face := make([dynamic]u32)
	defer delete(tri_face)
	triangulate(m, &t, &tri_face)
	r := geom.mesh_check(t)
	return r.volume, r.closed && !r.inverted
}

// Subdividing one face of a cube makes four quads of it, and the four faces beside it
// take its edge middles, so the cube stays closed with its volume.
@(test)
subdividing_a_face_splits_it_and_keeps_the_cube_closed :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	v0, _ := closed_volume(&m)
	m.selected[0] = true
	r, err := subdivide_faces(&m, {0})
	defer edit_result_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	c := mesh_check(&m)
	testing.expectf(t, check_ok(c) && c.faces == 9 && c.vertices == 13 && c.border_edges == 0, "%v", c)
	v1, closed := closed_volume(&m)
	testing.expect(t, closed && math.abs(v1 - v0) < 1e-5)
	// The pieces keep the face's selection.
	n := 0
	for s in m.selected do if s do n += 1
	testing.expect_value(t, n, 4)
}

// Poking a cube's face makes four triangles round its middle (which do not pair up into
// quads, since each pair would have a straight corner at the middle); a cube with each
// face cut on a diagonal joins back into six quads.
@(test)
poke_then_tris_to_quads :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	r, err := poke_faces(&m, {0})
	edit_result_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	c := mesh_check(&m)
	testing.expectf(t, check_ok(c) && c.faces == 9 && c.triangles == 4, "%v", c)
	tris := make([dynamic]u32)
	defer delete(tris)
	for f in 0 ..< u32(len(m.face_he)) do if face_size(&m, f) == 3 do append(&tris, f)
	_, joined, err2 := tris_to_quads(&m, tris[:])
	testing.expect_value(t, err2, Build_Error.Degenerate_Face)
	testing.expect_value(t, joined, 0)

	q := primitive(.Cube)
	defer mesh_destroy(&q)
	vs := make([dynamic]u32)
	defer delete(vs)
	for f in 0 ..< u32(6) {
		face_verts(&q, f, &vs)
		r, err = connect_points(&q, f, vs[0], vs[2])
		edit_result_destroy(&r)
		testing.expect_value(t, err, Build_Error.None)
	}
	c = mesh_check(&q)
	testing.expectf(t, c.triangles == 12, "%v", c)
	all := make([dynamic]u32)
	defer delete(all)
	for f in 0 ..< u32(len(q.face_he)) do append(&all, f)
	r2, joined2, err3 := tris_to_quads(&q, all[:])
	edit_result_destroy(&r2)
	testing.expect_value(t, err3, Build_Error.None)
	testing.expect_value(t, joined2, 6)
	c = mesh_check(&q)
	testing.expectf(t, check_ok(c) && c.faces == 6 && c.quads == 6 && c.border_edges == 0, "%v", c)
}

// Splitting a face off a cube gives it its own four points: the cube has a square hole
// and the face lies loose in it.
@(test)
splitting_a_face_detaches_it :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	r, err := split_faces(&m, {0})
	edit_result_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	c := mesh_check(&m)
	testing.expectf(t, check_ok(c) && c.vertices == 12 && c.faces == 6 && c.border_edges == 8, "%v", c)
}

// Separate's half: the faces alone as a cage; Join puts two cages back together.
@(test)
faces_mesh_and_join :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	part, err := faces_mesh(&m, {0, 1})
	defer mesh_destroy(&part)
	testing.expect_value(t, err, Build_Error.None)
	testing.expect_value(t, len(part.face_he), 2)
	moved := matrix[4, 4]f32{1, 0, 0, 3, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}
	both, err2 := join_meshes(&m, &part, moved)
	defer mesh_destroy(&both)
	testing.expect_value(t, err2, Build_Error.None)
	c := mesh_check(&both)
	testing.expectf(t, check_ok(c) && c.faces == 8 && c.vertices == 8 + len(part.positions), "%v", c)
	testing.expect(t, both.positions[8].x > 2)
}

// Deleting a cube's face and filling the hole: four points close with one face; a
// border of eight points closes with a grid of quads.
@(test)
filling_holes :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	r, err := delete_faces(&m, {0})
	edit_result_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	border := u32(0)
	for e in 0 ..< u32(len(m.crease)) do if edge_border(&m, e) {border = e; break}
	r, err = fill_hole(&m, border)
	edit_result_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	c := mesh_check(&m)
	testing.expectf(t, check_ok(c) && c.faces == 6 && c.border_edges == 0, "%v", c)
	v0, closed0 := closed_volume(&m)
	testing.expect(t, closed0)

	// A cube cut once round makes an eight-point border when two side faces go.
	g := primitive(.Cube, {across = 2})
	defer mesh_destroy(&g)
	// The four faces of one side of a 2-across cube leave a border of eight points.
	side := make([dynamic]u32)
	defer delete(side)
	for f in 0 ..< u32(len(g.face_he)) do if face_normal(&g, f).z > 0.9 do append(&side, f)
	testing.expect_value(t, len(side), 4)
	vg0, _ := closed_volume(&g)
	r, err = delete_faces(&g, side[:])
	edit_result_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	for e in 0 ..< u32(len(g.crease)) do if edge_border(&g, e) {border = e; break}
	r, err = fill_hole(&g, border)
	edit_result_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	c = mesh_check(&g)
	testing.expectf(t, check_ok(c) && c.border_edges == 0 && c.quads == c.faces && c.faces == 24, "%v", c)
	vg1, closed := closed_volume(&g)
	testing.expectf(t, closed && math.abs(vg1 - vg0) < 1e-4, "volume %v then %v", vg0, vg1)
	_ = v0
}

// Bevelling a cube's corner cuts it off with a triangle and three points for one.
@(test)
bevelling_a_point_cuts_its_corner :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	v0, _ := closed_volume(&m)
	r, err := bevel_points(&m, {0}, 0.25)
	edit_result_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	c := mesh_check(&m)
	testing.expectf(t, check_ok(c) && c.vertices == 10 && c.faces == 7 && c.triangles == 1 && c.border_edges == 0, "%v", c)
	v1, closed := closed_volume(&m)
	testing.expectf(t, closed && v1 < v0, "volume %v then %v", v0, v1)
}

// Relaxing a point pushed off a flat grid's middle across the surface brings it back to
// the middle and keeps it in the plane; a point lifted off the plane stays lifted under
// Relax and comes down under Smooth.
@(test)
relax_keeps_the_shape_and_smooth_flattens :: proc(t: ^testing.T) {
	m := primitive(.Plane, {across = 2})
	defer mesh_destroy(&m)
	middle := u32(0)
	for v in 0 ..< u32(len(m.positions)) do if !vert_border(&m, v) do middle = v
	n := vert_normal(&m, middle)
	across := Vec3{1, 0, 0} if abs(n.x) < 0.5 else Vec3{0, 1, 0}
	start := m.positions[middle]
	m.positions[middle] += across * 0.1 + n * 0.2
	goals := smooth_goals(&m, {middle}, true)
	defer delete(goals)
	d := goals[0] - start
	testing.expectf(t, abs(linalg.dot(d, across)) < 0.02 && linalg.dot(d, n) > 0.15, "%v from %v", goals[0], start)
	flat := smooth_goals(&m, {middle}, false)
	defer delete(flat)
	testing.expectf(t, linalg.length(flat[0] - start) < 1e-4, "%v", flat[0])
}
