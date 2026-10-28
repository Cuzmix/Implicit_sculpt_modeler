package poly

import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"

@(test)
inserting_a_loop_round_a_cube_splits_its_ring :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	before := mesh_check(&m)
	r, err := insert_loop(&m, 0, 0.25)
	defer loop_insert_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	c := mesh_check(&m)
	// A ring of four sides: four new points, four new faces, eight new edges.
	testing.expectf(t, check_ok(c) && c.border_edges == 0 && c.vertices == before.vertices + 4 && c.faces == before.faces + 4 && c.edges == before.edges + 8 && c.quads == c.faces, "%v then %v", before, c)
	testing.expect_value(t, len(r.verts), 4)
	// Each new point sits a quarter of the way along its edge from the edge's first end.
	for v, i in r.verts {
		a, b := m.positions[r.ends[i][0]], m.positions[r.ends[i][1]]
		testing.expectf(t, linalg.length(m.positions[v] - linalg.lerp(a, b, f32(0.25))) < 1e-5, "point %d off its edge", i)
	}
	// The four points lie in one plane: the loop runs straight round.
	n := linalg.normalize(linalg.cross(m.positions[r.verts[1]] - m.positions[r.verts[0]], m.positions[r.verts[2]] - m.positions[r.verts[0]]))
	for v in r.verts do testing.expect(t, math.abs(linalg.dot(m.positions[v] - m.positions[r.verts[0]], n)) < 1e-5)
	// The slide moves them along their edges and stops short of the ends.
	d := loop_slide(&m, &r)
	defer drag_set_destroy(&d)
	got := drag_apply(&m, &d, 5)
	testing.expectf(t, got < 0.75 && got > 0.7, "slide clamped to %v", got)
	testing.expect(t, check_ok(mesh_check(&m)))
}

@(test)
an_open_ring_gives_its_end_faces_the_new_point :: proc(t: ^testing.T) {
	// A 2 by 2 plane: the ring across one row stops at the border; nothing else to split.
	m := primitive(.Plane, {across = 2})
	defer mesh_destroy(&m)
	before := mesh_check(&m)
	r, err := insert_loop(&m, 0, 0.5)
	defer loop_insert_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	c := mesh_check(&m)
	testing.expectf(t, check_ok(c) && c.faces == before.faces + 2 && c.vertices == before.vertices + 3, "%v then %v", before, c)
}

@(test)
dissolving_an_inserted_loop_gives_the_cube_back :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	before := mesh_check(&m)
	r, _ := insert_loop(&m, 0, 0.5)
	loop := make([dynamic]u32)
	defer delete(loop)
	// The new loop's edges: those joining consecutive new points.
	for i in 0 ..< len(r.verts) {
		h := find_half_edge(&m, r.verts[i], r.verts[(i + 1) % len(r.verts)])
		if h != NONE do append(&loop, edge_of(h))
	}
	loop_insert_destroy(&r)
	testing.expect_value(t, len(loop), 4)
	r2, err := dissolve_edges(&m, loop[:])
	defer edit_result_destroy(&r2)
	testing.expect_value(t, err, Build_Error.None)
	c := mesh_check(&m)
	// The faces join back and the loop's points, left between two edges, go too.
	testing.expectf(t, check_ok(c) && c.vertices == before.vertices && c.faces == before.faces && c.edges == before.edges && c.quads == 6, "%v then %v", before, c)
}

@(test)
dissolving_one_edge_joins_two_faces :: proc(t: ^testing.T) {
	m := primitive(.Plane, {across = 2})
	defer mesh_destroy(&m)
	// An inner edge: one with faces on both sides.
	e := NONE
	for x in 0 ..< u32(len(m.crease)) do if !edge_border(&m, x) {
		e = x
		break
	}
	r, err := dissolve_edges(&m, {e})
	defer edit_result_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	c := mesh_check(&m)
	// Two quads become a hexagon; its middle point keeps its other edges, so it stays.
	testing.expectf(t, check_ok(c) && c.faces == 3 && c.ngons == 1 && c.vertices == 9, "%v", c)
}

@(test)
collapsing_an_edge_merges_its_ends :: proc(t: ^testing.T) {
	m := primitive(.Cube, {across = 2})
	defer mesh_destroy(&m)
	before := mesh_check(&m)
	r, err := collapse_edges(&m, {0})
	defer edit_result_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	c := mesh_check(&m)
	// The edge's two quads turn into triangles; one point goes, and the shape stays closed.
	testing.expectf(t, check_ok(c) && c.vertices == before.vertices - 1 && c.triangles == 2 && c.border_edges == 0, "%v then %v", before, c)
}

@(test)
spinning_an_edge_turns_it_round_its_faces :: proc(t: ^testing.T) {
	m := primitive(.Plane, {across = 2})
	defer mesh_destroy(&m)
	e := NONE
	for x in 0 ..< u32(len(m.crease)) do if !edge_border(&m, x) {
		e = x
		break
	}
	a, b := edge_verts(&m, e)
	r, err := spin_edge(&m, e)
	defer edit_result_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	c := mesh_check(&m)
	testing.expectf(t, check_ok(c) && c.faces == 4 && c.edges == 12, "%v", c)
	// The old edge is gone: its ends are no longer joined.
	testing.expect_value(t, find_half_edge(&m, r.vert[a], r.vert[b]), NONE)
}

@(test)
closing_a_hole_and_bridging_two :: proc(t: ^testing.T) {
	// A tube: a cylinder without its caps has two border loops.
	m := primitive(.Cylinder, {around = 8, along = 2})
	defer mesh_destroy(&m)
	caps := make([dynamic]u32)
	defer delete(caps)
	for f in 0 ..< u32(len(m.face_he)) do if face_size(&m, f) == 8 do append(&caps, f)
	testing.expect_value(t, len(caps), 2)
	r0, _ := delete_faces(&m, caps[:])
	edit_result_destroy(&r0)
	c := mesh_check(&m)
	testing.expect_value(t, c.border_edges, 16)
	border := NONE
	for e in 0 ..< u32(len(m.crease)) do if edge_border(&m, e) {
		border = e
		break
	}
	r, err := close_hole(&m, border, 0)
	edit_result_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	c = mesh_check(&m)
	testing.expectf(t, check_ok(c) && c.border_edges == 8 && c.ngons == 1, "%v", c)
	// A tube with its middle row of sides taken out is two bands facing each other; the
	// bridge between their facing borders makes the row again.
	m2 := primitive(.Cylinder, {around = 6, along = 3})
	defer mesh_destroy(&m2)
	ys := make([dynamic]f32)
	defer delete(ys)
	for p in m2.positions do if !slice.contains(ys[:], p.y) do append(&ys, p.y)
	slice.sort(ys[:])
	testing.expect_value(t, len(ys), 4)
	gone := make([dynamic]u32)
	defer delete(gone)
	for f in 0 ..< u32(len(m2.face_he)) {
		if face_size(&m2, f) == 6 {
			append(&gone, f)
			continue
		}
		// The middle row: its points all lie on the two inner rings.
		inner := true
		w := face_walk(&m2, f)
		for h in face_walk_next(&w) {
			y := m2.positions[m2.he_vert[h]].y
			if y != ys[1] && y != ys[2] do inner = false
		}
		if inner do append(&gone, f)
	}
	r1, _ := delete_faces(&m2, gone[:])
	edit_result_destroy(&r1)
	sides := mesh_check(&m2).faces
	testing.expect_value(t, sides, 12)
	ring_edge :: proc(m: ^Mesh, y: f32) -> u32 {
		for e in 0 ..< u32(len(m.crease)) {
			a, b := edge_verts(m, e)
			if edge_border(m, e) && m.positions[a].y == y && m.positions[b].y == y do return e
		}
		return NONE
	}
	rb, errb := bridge_borders(&m2, ring_edge(&m2, ys[1]), ring_edge(&m2, ys[2]))
	edit_result_destroy(&rb)
	testing.expect_value(t, errb, Build_Error.None)
	c2 := mesh_check(&m2)
	testing.expectf(t, check_ok(c2) && c2.border_edges == 12 && c2.faces == 18 && c2.quads == 18, "%v", c2)
	// The tube's two ends bridged too: a band inside it closes it into a ring with no border.
	rc, errc := bridge_borders(&m2, ring_edge(&m2, ys[0]), ring_edge(&m2, ys[3]))
	edit_result_destroy(&rc)
	testing.expect_value(t, errc, Build_Error.None)
	c3 := mesh_check(&m2)
	testing.expectf(t, check_ok(c3) && c3.border_edges == 0 && c3.faces == 24, "%v", c3)
}

@(test)
extruding_a_border_grows_a_strip :: proc(t: ^testing.T) {
	m := primitive(.Plane, {across = 2})
	defer mesh_destroy(&m)
	before := mesh_check(&m)
	loop := make([dynamic]u32)
	defer delete(loop)
	e := NONE
	for x in 0 ..< u32(len(m.crease)) do if edge_border(&m, x) {
		e = x
		break
	}
	border_loop(&m, e, &loop)
	testing.expect_value(t, len(loop), 8)
	r, d, err := extrude_border(&m, loop[:], false)
	defer border_extrude_destroy(&r)
	defer drag_set_destroy(&d)
	testing.expect_value(t, err, Build_Error.None)
	drag_apply(&m, &d, 0.2)
	c := mesh_check(&m)
	testing.expectf(t, check_ok(c) && c.faces == before.faces + 8 && c.vertices == before.vertices + 8 && c.border_edges == 8, "%v then %v", before, c)
	// The strip grows outward: the plane's outline is bigger.
	b0 := mesh_bounds(&m)
	testing.expect(t, b0.hi.x - b0.lo.x > 2.1 || b0.hi.z - b0.lo.z > 2.1)
}

@(test)
connecting_points_splits_a_face :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	vs := make([dynamic]u32)
	defer delete(vs)
	face_verts(&m, 0, &vs)
	r, err := connect_points(&m, 0, vs[0], vs[2])
	defer edit_result_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	c := mesh_check(&m)
	testing.expectf(t, check_ok(c) && c.faces == 7 && c.triangles == 2 && c.border_edges == 0, "%v", c)
	// Neighbours cannot be connected.
	_, err2 := connect_points(&m, 1, m.he_vert[m.face_he[1]], he_tip(&m, m.face_he[1]))
	testing.expect(t, err2 != .None)
}

@(test)
dissolving_a_point_and_flat_faces :: proc(t: ^testing.T) {
	m := primitive(.Cube, {across = 2})
	defer mesh_destroy(&m)
	// The middle point of a side has four faces round it, all in one plane.
	middle := NONE
	for v in 0 ..< u32(len(m.positions)) do if valence(&m, v) == 4 {
		p := m.positions[v]
		zeros := 0
		for k in 0 ..< 3 do if math.abs(p[k]) < 1e-5 do zeros += 1
		if zeros == 2 {
			middle = v
			break
		}
	}
	testing.expect(t, middle != NONE)
	r, err := dissolve_point(&m, middle)
	edit_result_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	c := mesh_check(&m)
	testing.expectf(t, check_ok(c) && c.faces == 21 && c.ngons == 1, "%v", c)
	// Every flat stretch dissolves: a cube of six faces, whose sides are octagons.
	r2, err2 := dissolve_by_angle(&m, 5)
	edit_result_destroy(&r2)
	testing.expect_value(t, err2, Build_Error.None)
	c2 := mesh_check(&m)
	testing.expectf(t, check_ok(c2) && c2.faces == 6 && c2.border_edges == 0, "%v", c2)
}

@(test)
merging_by_distance_welds_close_points :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	// Pull one corner almost onto its neighbour.
	a, b := edge_verts(&m, 0)
	m.positions[b] = m.positions[a] + {1e-4, 0, 0}
	r, merged, err := merge_by_distance(&m, 1e-3)
	defer edit_result_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	testing.expect_value(t, merged, 1)
	c := mesh_check(&m)
	testing.expectf(t, check_ok(c) && c.vertices == 7 && c.border_edges == 0, "%v", c)
}
