package main

import "core:strings"
import "core:testing"

import "../geom"
import "../quadmesh"
import "../sculpt"

// A mesh as object_shape hands it to the engines: with normals of its own.
@(private = "file")
shape_view :: proc(m: ^geom.Mesh) -> geom.Mesh {
	resize(&m.normals, len(m.positions))
	geom.mesh_recompute_normals(m)
	return m^
}

// AutoRemesher on a sphere gives every face a quad, the polygons over the triangles two a
// quad in order, the quads with UVs, closed and outward; where it is not built, the own
// engine stands in and the reason says so.
@(test)
quad_remesh_keeps_the_polygons :: proc(t: ^testing.T) {
	m := geom.icosphere(4)
	defer geom.mesh_destroy(&m)
	r := retopo_compute(shape_view(&m), 1500, .Auto, nil)
	defer retopo_result_destroy(&r)
	if !testing.expect(t, r.built, "nothing built") do return
	when !quadmesh.AVAILABLE {
		testing.expect_value(t, r.engine, Quad_Engine.Own)
		testing.expect(t, r.reason != "", "the own engine ran without saying why")
		return
	}
	testing.expect_value(t, r.engine, Quad_Engine.Auto)
	testing.expect_value(t, r.reason, "")
	testing.expect(t, r.quads > 1000 && r.quads == r.faces, "not every face a quad")
	testing.expect_value(t, len(r.polys.first), r.faces + 1)
	testing.expect_value(t, len(r.polys.corners), 4 * r.faces)
	testing.expect_value(t, len(r.polys.tri_poly), 2 * r.faces)
	testing.expect_value(t, len(r.mesh.indices), 6 * r.faces)
	astray := 0
	for f, k in r.polys.tri_poly do if int(f) != k / 2 do astray += 1
	testing.expect_value(t, astray, 0)
	testing.expect_value(t, len(r.q.quads), r.faces)
	testing.expect_value(t, len(r.uv.uvs), r.faces)
	testing.expect(t, r.uv.charts > 0, "no UV charts")
	check := geom.mesh_check(r.mesh)
	testing.expect(t, check.closed, "not closed")
	testing.expect(t, !check.inverted, "inside out")
	testing.expect_value(t, check.non_manifold_edges, 0)
}

// A mesh with an edge of three faces is refused before AutoRemesher sees it, and the own
// engine makes the quads instead, the reason kept for the report.
@(test)
quad_remesh_falls_back_on_a_non_manifold_mesh :: proc(t: ^testing.T) {
	m := geom.icosphere(3)
	defer geom.mesh_destroy(&m)
	// A fin standing on the first triangle's first edge.
	a, b := m.indices[0], m.indices[1]
	append(&m.positions, (m.positions[a] + m.positions[b]) * 0.8)
	append(&m.indices, a, b, u32(len(m.positions) - 1))
	r := retopo_compute(shape_view(&m), 400, .Auto, nil)
	defer retopo_result_destroy(&r)
	if !testing.expect(t, r.built, "nothing built") do return
	testing.expect_value(t, r.engine, Quad_Engine.Own)
	testing.expect(t, strings.contains(r.reason, "more than two faces"), r.reason)
	testing.expect(t, r.polys.first == nil, "the own engine keeps no polygons")
	testing.expect(t, len(r.q.quads) > 0, "no quads")
	testing.expect_value(t, r.faces, len(r.q.quads))
}

// The own engine, asked for, still works as before.
@(test)
quad_remesh_own_engine_makes_quads :: proc(t: ^testing.T) {
	m := geom.icosphere(3)
	defer geom.mesh_destroy(&m)
	r := retopo_compute(shape_view(&m), 400, .Own, nil)
	defer retopo_result_destroy(&r)
	if !testing.expect(t, r.built, "nothing built") do return
	testing.expect_value(t, r.engine, Quad_Engine.Own)
	testing.expect_value(t, r.reason, "")
	testing.expect(t, len(r.q.quads) > 200, "too few quads")
	testing.expect_value(t, len(r.mesh.indices), 6 * len(r.q.quads))
}

// After the build renumbers vertices and reorders triangles, each corner follows its
// vertex and each triangle keeps its polygon.
@(test)
quad_remesh_polygons_follow_the_renumbering :: proc(t: ^testing.T) {
	// Two quads, 0-1-2-3 and 1-4-5-2, over six vertices and four triangles.
	polys: sculpt.Polys
	polys.first = make([]u32, 3)
	polys.corners = make([]u32, 8)
	polys.tri_poly = make([]u32, 4)
	defer sculpt.polys_destroy(&polys)
	copy(polys.first, []u32{0, 4, 8})
	copy(polys.corners, []u32{0, 1, 2, 3, 1, 4, 5, 2})
	copy(polys.tri_poly, []u32{0, 0, 1, 1})
	old_to_new := []u32{5, 4, 3, 2, 1, 0}
	// New triangle t was old triangle tri_from[t]: the order reversed.
	tri_from := []u32{3, 2, 1, 0}
	retopo_polys_renumber(&polys, old_to_new, tri_from)
	testing.expect_value(t, polys.corners[0], 5)
	testing.expect_value(t, polys.corners[3], 2)
	testing.expect_value(t, polys.corners[4], 4)
	testing.expect_value(t, polys.corners[6], 0)
	testing.expect_value(t, polys.tri_poly[0], 1)
	testing.expect_value(t, polys.tri_poly[1], 1)
	testing.expect_value(t, polys.tri_poly[2], 0)
	testing.expect_value(t, polys.tri_poly[3], 0)
}
