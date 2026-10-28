package poly

import "core:math/linalg"
import "core:testing"

// An edge round the middle of a cylinder's side: one whose two faces are side quads.
@(private = "file")
side_ring_edge :: proc(m: ^Mesh) -> u32 {
	for e in 0 ..< u32(len(m.crease)) {
		a, b := edge_verts(m, e)
		pa, pb := m.positions[a], m.positions[b]
		if abs(pa.y - pb.y) < 1e-5 && valence(m, a) == 4 && valence(m, b) == 4 do return e
	}
	return NONE
}

@(test)
rounding_and_flattening_a_loop :: proc(t: ^testing.T) {
	opts := PRIMITIVE_DEFAULTS
	opts.along = 2
	m := primitive(.Cylinder, opts)
	defer mesh_destroy(&m)
	edges := make([dynamic]u32, context.temp_allocator)
	closed := edge_loop(&m, side_ring_edge(&m), &edges)
	testing.expect(t, closed)
	points, ring_closed := loop_points(&m, edges[:], context.temp_allocator)
	testing.expect(t, ring_closed)
	testing.expect_value(t, len(points), len(edges))
	// Knock two points out of the ring, then round it again.
	m.positions[points[0]] += {0.2, 0.1, 0}
	m.positions[points[2]] *= 0.7
	testing.expect(t, shape_loop(&m, points, true, .Circle))
	c: Vec3
	for v in points do c += m.positions[v]
	c /= f32(len(points))
	r := linalg.length(m.positions[points[0]] - c)
	for v in points do testing.expectf(t, abs(linalg.length(m.positions[v] - c) - r) < 1e-4, "%v", m.positions[v])
	// Flattened, every point lies on one plane.
	m.positions[points[1]].y += 0.3
	testing.expect(t, shape_loop(&m, points, true, .Flatten))
	a, b, d := m.positions[points[0]], m.positions[points[1]], m.positions[points[2]]
	n := linalg.normalize(linalg.cross(b - a, d - a))
	for v in points do testing.expect(t, abs(linalg.dot(m.positions[v] - a, n)) < 1e-4)
	testing.expect(t, check_ok(mesh_check(&m)))
}

@(test)
spacing_an_open_loop_evenly :: proc(t: ^testing.T) {
	opts := PRIMITIVE_DEFAULTS
	opts.across = 4
	m := primitive(.Plane, opts)
	defer mesh_destroy(&m)
	// An inner edge's loop runs across the plane from border to border.
	start := NONE
	for e in 0 ..< u32(len(m.crease)) {
		a, b := edge_verts(&m, e)
		if !vert_border(&m, a) && !vert_border(&m, b) {
			start = e
			break
		}
	}
	edges := make([dynamic]u32, context.temp_allocator)
	testing.expect(t, !edge_loop(&m, start, &edges))
	points, closed := loop_points(&m, edges[:], context.temp_allocator)
	testing.expect(t, !closed)
	testing.expect_value(t, len(points), 5)
	ends := [2]Vec3{m.positions[points[0]], m.positions[points[4]]}
	// Slide an inner point along the line, then space them again.
	m.positions[points[1]] = linalg.lerp(ends[0], ends[1], 0.4)
	testing.expect(t, shape_loop(&m, points, false, .Space))
	for v, i in points {
		want := linalg.lerp(ends[0], ends[1], f32(i) / 4)
		testing.expectf(t, linalg.length(m.positions[v] - want) < 1e-4, "%d at %v, not %v", i, m.positions[v], want)
	}
	// A circle needs a closed loop.
	testing.expect(t, !shape_loop(&m, points, false, .Circle))
}

@(test)
a_knife_cut_across_two_faces :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	// From the middle of one edge of face 0, across it, over its next edge and across the
	// face beyond: three points, two faces split.
	h0 := m.face_he[0]
	h1 := m.he_next[m.he_next[h0]] // the edge across face 0 from h0
	// The edge of the face beyond, across from h1.
	h2 := m.he_next[m.he_next[twin(h1)]]
	chain := []Knife_Point{{edge_of(h0), 0.5}, {edge_of(h1), 0.5}, {edge_of(h2), 0.5}}
	before := mesh_check(&m)
	r, err := knife_cut(&m, {chain})
	defer edit_result_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	c := mesh_check(&m)
	testing.expectf(t, check_ok(c) && c.vertices == before.vertices + 3 && c.faces == before.faces + 2 && c.euler == 2, "%v", c)
	// A cut along one edge only splits that edge.
	m2 := primitive(.Cube)
	defer mesh_destroy(&m2)
	r2, err2 := knife_cut(&m2, {[]Knife_Point{{0, 0.25}, {0, 0.75}}})
	defer edit_result_destroy(&r2)
	testing.expect_value(t, err2, Build_Error.None)
	c2 := mesh_check(&m2)
	testing.expectf(t, check_ok(c2) && c2.vertices == 10 && c2.faces == 6, "%v", c2)
}

@(test)
knife_cuts_that_cross_and_creases_they_cut :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	// Two cuts across face 0 from opposite edge middles, as a cut and its mirror image
	// cross: they meet at a new point in the middle, and the face becomes four.
	h0 := m.face_he[0]
	h1 := m.he_next[h0]
	h2 := m.he_next[h1]
	h3 := m.he_next[h2]
	m.crease[edge_of(h0)] = 2
	before := mesh_check(&m)
	r, err := knife_cut(&m, {[]Knife_Point{{edge_of(h0), 0.5}, {edge_of(h2), 0.5}}, []Knife_Point{{edge_of(h1), 0.5}, {edge_of(h3), 0.5}}})
	defer edit_result_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	c := mesh_check(&m)
	testing.expectf(t, check_ok(c) && c.vertices == before.vertices + 5 && c.faces == before.faces + 3 && c.euler == 2, "%v", c)
	// The point where they cross (the edit's fifth new point) has four edges.
	testing.expect_value(t, valence(&m, r.vert[before.vertices + 4]), 4)
	// Both pieces of the creased edge keep its crease.
	edges, _ := crease_count(&m)
	testing.expect_value(t, edges, 2)
}
