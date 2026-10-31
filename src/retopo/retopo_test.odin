package retopo

@(require) import "core:log" // used only where AutoRemesher is not built
import "core:math"
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
	r := compute(shape_view(&m), 1500, {engine = .Auto}, nil)
	defer result_destroy(&r)
	if !testing.expect(t, r.built, "nothing built") do return
	when !quadmesh.AVAILABLE {
		testing.expect_value(t, r.engine, Engine.Own)
		testing.expect(t, r.reason != "", "the own engine ran without saying why")
		return
	}
	testing.expect_value(t, r.engine, Engine.Auto)
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
	r := compute(shape_view(&m), 400, {engine = .Auto}, nil)
	defer result_destroy(&r)
	if !testing.expect(t, r.built, "nothing built") do return
	testing.expect_value(t, r.engine, Engine.Own)
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
	r := compute(shape_view(&m), 400, {engine = .Own}, nil)
	defer result_destroy(&r)
	if !testing.expect(t, r.built, "nothing built") do return
	testing.expect_value(t, r.engine, Engine.Own)
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
	polys_renumber(&polys, old_to_new, tri_from)
	testing.expect_value(t, polys.corners[0], 5)
	testing.expect_value(t, polys.corners[3], 2)
	testing.expect_value(t, polys.corners[4], 4)
	testing.expect_value(t, polys.corners[6], 0)
	testing.expect_value(t, polys.tri_poly[0], 1)
	testing.expect_value(t, polys.tri_poly[1], 1)
	testing.expect_value(t, polys.tri_poly[2], 0)
	testing.expect_value(t, polys.tri_poly[3], 0)
}

// Symmetry: the + half is remeshed and mirrored, so every vertex has its image across the
// plane, the seam lies on it to the bit, and the whole is closed and manifold.
@(test)
quad_remesh_mirrors_one_half :: proc(t: ^testing.T) {
	when !quadmesh.AVAILABLE {
		log.info("quad remesh symmetry: AutoRemesher is not built here, nothing to test")
		return
	}
	m := geom.icosphere(4)
	defer geom.mesh_destroy(&m)
	r := compute(shape_view(&m), 1200, {engine = .Auto, symmetry = .X}, nil)
	defer result_destroy(&r)
	if !testing.expect(t, r.built, "nothing built") do return
	testing.expect_value(t, r.engine, Engine.Auto)
	testing.expect(t, r.mirrored, "not mirrored")
	testing.expect(t, r.quads > 800 && r.quads == r.faces, "not every face a quad")
	check := geom.mesh_check(r.mesh)
	testing.expect(t, check.closed, "not closed")
	testing.expect_value(t, check.non_manifold_edges, 0)
	testing.expect(t, !check.inverted, "inside out")
	// Each vertex's image across the plane is a vertex too, and the seam is exact.
	unmatched, seam := 0, 0
	for p in r.mesh.positions {
		if p.x == 0 do seam += 1
		found := false
		for q in r.mesh.positions do if abs(q.x + p.x) <= 1e-6 && abs(q.y - p.y) <= 1e-6 && abs(q.z - p.z) <= 1e-6 {
			found = true
			break
		}
		if !found do unmatched += 1
	}
	testing.expect_value(t, unmatched, 0)
	testing.expect(t, seam >= 16, "too few seam vertices")
}

// Close first: an open hemisphere keeps its border through AutoRemesher (which fills only
// small holes itself), but with Close first the voxel remesh closes it before the quads
// are made.
@(test)
quad_remesh_closes_an_open_mesh_first :: proc(t: ^testing.T) {
	m := geom.icosphere(4)
	defer geom.mesh_destroy(&m)
	// The upper half: every triangle whose middle is above the equator.
	kept := make([dynamic]u32, 0, len(m.indices))
	defer delete(kept)
	for k := 0; k < len(m.indices); k += 3 {
		a, b, c := m.indices[k], m.indices[k + 1], m.indices[k + 2]
		if (m.positions[a].z + m.positions[b].z + m.positions[c].z) > 0 do append(&kept, a, b, c)
	}
	resize(&m.indices, len(kept))
	copy(m.indices[:], kept[:])
	// Enough quads that the rim is over the 65 edges AutoRemesher fills a hole under.
	open := compute(shape_view(&m), 2000, {engine = .Auto}, nil)
	defer result_destroy(&open)
	closed := compute(shape_view(&m), 2000, {engine = .Auto, close_first = true}, nil)
	defer result_destroy(&closed)
	if !testing.expect(t, open.built && closed.built, "nothing built") do return
	when quadmesh.AVAILABLE {
		testing.expect(t, geom.mesh_check(open.mesh).boundary_edges > 0, "AutoRemesher closed the hemisphere on its own")
		testing.expect_value(t, open.closed, 0)
	}
	testing.expect(t, closed.closed > 0, "Close first did not remesh")
	after := geom.mesh_check(closed.mesh)
	testing.expect(t, after.closed, "not closed after Close first")
	// The bowl is filled where the winding is positive: about the half ball (2.09), not a box.
	testing.expectf(t, after.volume > 1.4 && after.volume < 2.8, "volume %.2f is not a half ball's", after.volume)
}

// Adaptivity trades the count for smaller quads where the surface bends.
@(test)
quad_remesh_adaptivity_makes_fewer_quads :: proc(t: ^testing.T) {
	when !quadmesh.AVAILABLE {
		log.info("quad remesh adaptivity: AutoRemesher is not built here, nothing to test")
		return
	}
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	// A bumpy sphere: the radius waves with the position.
	for &p in m.positions do p *= 1 + 0.12 * math.sin(6 * p.x) * math.sin(6 * p.y) * math.sin(6 * p.z)
	even := compute(shape_view(&m), 3000, {engine = .Auto}, nil)
	defer result_destroy(&even)
	bent := compute(shape_view(&m), 3000, {engine = .Auto, adaptivity = 1}, nil)
	defer result_destroy(&bent)
	if !testing.expect(t, even.built && bent.built, "nothing built") do return
	testing.expectf(t, bent.faces < even.faces, "adaptivity 1 gave %d faces, even %d", bent.faces, even.faces)
}
