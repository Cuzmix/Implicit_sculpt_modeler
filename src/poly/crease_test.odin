package poly

import "core:testing"

@(test)
creasing_edges_and_points_by_hand :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	testing.expect(t, crease_edges(&m, {0, 1}, 2))
	testing.expect(t, !crease_edges(&m, {0, 1}, 2))
	testing.expect_value(t, m.crease[0], f32(2))
	// Past fully sharp is fully sharp.
	crease_edges(&m, {1}, 100)
	testing.expect_value(t, m.crease[1], INFINITE_SHARP)
	testing.expect(t, crease_points(&m, {3}, INFINITE_SHARP))
	edges, points := crease_count(&m)
	testing.expect_value(t, edges, 2)
	testing.expect_value(t, points, 1)
	testing.expect(t, crease_edges(&m, {0}, 0))
	testing.expect_value(t, crease_clear(&m), 2)
	edges, points = crease_count(&m)
	testing.expect_value(t, edges + points, 0)
}

@(test)
creasing_by_angle_and_by_polygroup :: proc(t: ^testing.T) {
	cube := primitive(.Cube)
	defer mesh_destroy(&cube)
	// Every edge of a cube bends a right angle; none bends more than one.
	testing.expect_value(t, crease_by_angle(&cube, 100), 0)
	testing.expect_value(t, crease_by_angle(&cube, 30), 12)
	testing.expect_value(t, crease_by_angle(&cube, 30), 0)
	// A quad sphere bends a little at each edge.
	ball := primitive(.Sphere)
	defer mesh_destroy(&ball)
	testing.expect_value(t, crease_by_angle(&ball, 60), 0)
	// One face in a polygroup of its own is ringed by four group borders.
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	group_faces(&m, {0}, group_next(&m))
	testing.expect_value(t, crease_group_borders(&m), 4)
	testing.expect_value(t, crease_group_borders(&m), 0)
	// Creases survive an edit that keeps their edges.
	r, err := flip_faces(&m, {0, 1, 2, 3, 4, 5})
	edit_result_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	edges, _ := crease_count(&m)
	testing.expect_value(t, edges, 4)
}
