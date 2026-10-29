package poly

import "core:math/linalg"
import "core:testing"

@(test)
topo_builds_a_strip_face_by_face :: proc(t: ^testing.T) {
	// One quad, then a second sharing its right edge with two new points: a strip of two
	// quads, six points, sound; the second added the wrong way round is refused.
	m, err := polygon_mesh({{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}}, 0)
	defer mesh_destroy(&m)
	testing.expect_value(t, err, Build_Error.None)
	r, add_err := add_polygon(&m, {{point = 1}, {point = NONE, at = {2, 0, 0}}, {point = NONE, at = {2, 1, 0}}, {point = 2}}, 0)
	defer edit_result_destroy(&r)
	testing.expect_value(t, add_err, Build_Error.None)
	c := mesh_check(&m)
	testing.expect(t, check_ok(c))
	testing.expect_value(t, c.vertices, 6)
	testing.expect_value(t, c.faces, 2)
	testing.expect_value(t, c.border_edges, 6)
	testing.expect_value(t, m.positions[4], Vec3{2, 0, 0})
	wrong, wrong_err := add_polygon(&m, {{point = 3}, {point = 0}, {point = NONE, at = {-1, 0.5, 0}}}, 0)
	defer edit_result_destroy(&wrong)
	testing.expect(t, wrong_err != .None)
	testing.expect_value(t, len(m.face_he), 2)
	// A corner named twice is refused.
	twice, twice_err := add_polygon(&m, {{point = 0}, {point = 0}, {point = 3}}, 0)
	defer edit_result_destroy(&twice)
	testing.expect_value(t, twice_err, Build_Error.Degenerate_Face)
}

@(test)
relax_keeps_a_border_a_border :: proc(t: ^testing.T) {
	// A plane of four quads with its middle point pulled aside: relaxed, it goes back to
	// the middle; a border point between two border points goes between them.
	m := primitive(.Plane, {across = 2})
	defer mesh_destroy(&m)
	middle := NONE
	for v in 0 ..< u32(len(m.positions)) do if !vert_border(&m, v) do middle = v
	testing.expect(t, middle != NONE)
	want := m.positions[middle]
	m.positions[middle] += {0.3, 0, 0.2}
	got := relax_points(&m, {middle}, context.temp_allocator)
	testing.expect(t, linalg.length(got[0] - want) < 1e-5)
	// A border point's two border neighbours, and where it goes: their middle.
	edge_point := NONE
	for v in 0 ..< u32(len(m.positions)) do if vert_border(&m, v) && valence(&m, v) == 3 {
		edge_point = v
		break
	}
	ends: [dynamic]Vec3
	defer delete(ends)
	w := vertex_walk(&m, edge_point)
	for h in vertex_walk_next(&w) do if edge_border(&m, edge_of(h)) do append(&ends, m.positions[he_tip(&m, h)])
	testing.expect_value(t, len(ends), 2)
	moved := relax_points(&m, {edge_point}, context.temp_allocator)
	testing.expect(t, linalg.length(moved[0] - (ends[0] + ends[1]) / 2) < 1e-5)
}
