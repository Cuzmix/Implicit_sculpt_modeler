package retopo

@(require) import "core:log" // used only where AutoRemesher is not built
import "core:math"
import "core:math/linalg"
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
	mirror := geom.Remesh_Mirror{axes = {true, false, false}}
	r := compute(shape_view(&m), 1200, {engine = .Auto, mirror = mirror}, nil)
	defer result_destroy(&r)
	if !testing.expect(t, r.built, "nothing built") do return
	testing.expect_value(t, r.engine, Engine.Auto)
	testing.expect(t, r.mirrored, "not mirrored")
	testing.expect(t, r.quads > 800 && r.quads == r.faces, "not every face a quad")
	expect_mirrored(t, r.mesh, mirror, 16)
}

// Keep symmetry follows the brush's: two planes at once, through a centre off the
// origin (Local symmetry), on a shape that is not symmetric itself, with either engine.
@(test)
quad_remesh_keeps_two_planes_off_the_origin :: proc(t: ^testing.T) {
	m := geom.icosphere(4)
	defer geom.mesh_destroy(&m)
	// Moved off the origin and bulged on one side, so only the mirror makes it symmetric.
	for &p in m.positions {
		if p.x > 0.3 do p.x *= 1.25
		p += {0.4, -0.1, 0.25}
	}
	mirror := geom.Remesh_Mirror{axes = {true, false, true}, center = {0.4, -0.1, 0.25}}
	for engine in Engine {
		when !quadmesh.AVAILABLE do if engine == .Auto do continue
		r := compute(shape_view(&m), 1600, {engine = engine, mirror = mirror}, nil)
		defer result_destroy(&r)
		if !testing.expectf(t, r.built, "%v: nothing built", engine) do continue
		testing.expectf(t, r.mirrored, "%v: not mirrored (%s)", engine, r.unmirrored)
		testing.expectf(t, r.quads == r.faces && r.quads > 400, "%v: %d quads of %d faces", engine, r.quads, r.faces)
		expect_mirrored(t, r.mesh, mirror, 8)
	}
}

// The built-in engine keeps one plane as AutoRemesher does.
@(test)
quad_remesh_built_in_mirrors_one_half :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	mirror := geom.Remesh_Mirror{axes = {true, false, false}}
	r := compute(shape_view(&m), 2000, {engine = .Own, mirror = mirror}, nil)
	defer result_destroy(&r)
	if !testing.expect(t, r.built, "nothing built") do return
	testing.expect_value(t, r.engine, Engine.Own)
	testing.expect(t, r.mirrored, "not mirrored")
	testing.expect(t, r.q.quads != nil && len(r.q.quads) > 1000, "too few quads")
	expect_mirrored(t, r.mesh, mirror, 16)
}

// Closed, manifold, facing out, and its own mirror image across every plane of `mirror`:
// each vertex's image is a vertex, and at least `seam` vertices lie on each plane to the bit.
@(private = "file")
expect_mirrored :: proc(t: ^testing.T, mesh: geom.Mesh, mirror: geom.Remesh_Mirror, seam: int, loc := #caller_location) {
	check := geom.mesh_check(mesh)
	testing.expect(t, check.closed, "not closed", loc = loc)
	testing.expect_value(t, check.non_manifold_edges, 0, loc = loc)
	testing.expect(t, !check.inverted, "inside out", loc = loc)
	for a in 0 ..< 3 {
		if !mirror.axes[a] do continue
		c := mirror.center[a]
		unmatched, on := 0, 0
		for p in mesh.positions {
			if p[a] == c do on += 1
			image := p
			image[a] = 2 * c - p[a]
			found := false
			for q in mesh.positions do if abs(q.x - image.x) <= 1e-5 && abs(q.y - image.y) <= 1e-5 && abs(q.z - image.z) <= 1e-5 {
				found = true
				break
			}
			if !found do unmatched += 1
		}
		testing.expectf(t, unmatched == 0, "axis %d: %d vertices without their image", a, unmatched, loc = loc)
		testing.expectf(t, on >= seam, "axis %d: %d seam vertices", a, on, loc = loc)
	}
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

// Adaptive size puts smaller quads where the surface bends and larger ones where it is
// flat, and the count stays what was asked: the triangles' areas spread wider than at Even.
@(test)
quad_remesh_adaptive_size_keeps_the_count :: proc(t: ^testing.T) {
	when !quadmesh.AVAILABLE {
		log.info("quadmesh is not built on this platform")
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
	spread :: proc(m: geom.Mesh) -> f32 {
		n := len(m.indices) / 3
		areas := make([]f32, n, context.temp_allocator)
		mean: f32
		for tri in 0 ..< n {
			a, b, c := m.positions[m.indices[3 * tri]], m.positions[m.indices[3 * tri + 1]], m.positions[m.indices[3 * tri + 2]]
			areas[tri] = 0.5 * linalg.length(linalg.cross(b - a, c - a))
			mean += areas[tri] / f32(n)
		}
		variance: f32
		for a in areas do variance += (a - mean) * (a - mean) / f32(n)
		return math.sqrt(variance) / mean
	}
	log.infof("adaptive size: even %d faces, area spread %.2f; adaptive %d faces, spread %.2f", even.faces, spread(even.mesh), bent.faces, spread(bent.mesh))
	testing.expectf(t, bent.faces >= 2850 && bent.faces <= 3150, "adaptive size gave %d faces for 3000 asked", bent.faces)
	testing.expectf(t, spread(bent.mesh) > 1.3 * spread(even.mesh), "adaptive size spread the areas %.2f against %.2f at Even", spread(bent.mesh), spread(even.mesh))
}

// Use paint: a sphere painted red on its upper half gets about four times the quads per area
// there, the count staying what was asked; off, the paint changes nothing. Use mask: the
// masked half gets about twice as many. With the mirror on, the half goes in with its paint.
@(test)
quad_remesh_paint_and_mask_move_the_quads :: proc(t: ^testing.T) {
	when !quadmesh.AVAILABLE {
		log.info("quadmesh is not built on this platform")
		return
	}
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	paint := make([]sculpt.Color, len(m.positions))
	defer delete(paint)
	mask := make([]u8, len(m.positions))
	defer delete(mask)
	for p, v in m.positions do if p.z > 0 {
		paint[v] = {255, 0, 0, 255}
		mask[v] = 255
	}
	// Triangles above and below the equator: the halves have the same area, so their
	// ratio is the ratio of quads per area.
	halves :: proc(m: geom.Mesh) -> f32 {
		upper, lower: int
		for tri in 0 ..< len(m.indices) / 3 {
			z := (m.positions[m.indices[3 * tri]].z + m.positions[m.indices[3 * tri + 1]].z + m.positions[m.indices[3 * tri + 2]].z) / 3
			if z > 0 do upper += 1
			else do lower += 1
		}
		return f32(upper) / f32(max(lower, 1))
	}
	source := Source{paint = paint, mask = mask}
	painted := compute(shape_view(&m), 2000, {engine = .Auto, use_paint = true}, nil, source = source)
	defer result_destroy(&painted)
	plain := compute(shape_view(&m), 2000, {engine = .Auto}, nil, source = source)
	defer result_destroy(&plain)
	masked := compute(shape_view(&m), 2000, {engine = .Auto, use_mask = true}, nil, source = source)
	defer result_destroy(&masked)
	mirrored := compute(shape_view(&m), 2000, {engine = .Auto, use_paint = true, mirror = {axes = {true, false, false}}}, nil, source = source)
	defer result_destroy(&mirrored)
	if !testing.expect(t, painted.built && plain.built && masked.built && mirrored.built, "nothing built") do return
	log.infof("paint: %d faces, %.2f times above; plain %d, %.2f; mask %d, %.2f; mirrored paint %d, %.2f", painted.faces, halves(painted.mesh), plain.faces, halves(plain.mesh), masked.faces, halves(masked.mesh), mirrored.faces, halves(mirrored.mesh))
	for r in ([4]^Result{&painted, &plain, &masked, &mirrored}) {
		testing.expectf(t, r.faces >= 1900 && r.faces <= 2100, "%d faces for 2000 asked", r.faces)
		testing.expectf(t, r.quads == r.faces, "%d of %d faces are quads", r.quads, r.faces)
	}
	testing.expectf(t, halves(painted.mesh) >= 3 && halves(painted.mesh) <= 5, "red above gave %.2f times the quads", halves(painted.mesh))
	testing.expectf(t, halves(plain.mesh) >= 0.85 && halves(plain.mesh) <= 1.15, "paint not used gave %.2f times the quads", halves(plain.mesh))
	testing.expectf(t, halves(masked.mesh) >= 1.5 && halves(masked.mesh) <= 2.5, "the mask above gave %.2f times the quads", halves(masked.mesh))
	testing.expectf(t, halves(mirrored.mesh) >= 3 && halves(mirrored.mesh) <= 5, "red above, mirrored, gave %.2f times the quads", halves(mirrored.mesh))
}

// Keep groups: a sphere whose top is one polygroup and the rest another hands the border
// to AutoRemesher as feature edges (one per edge between the groups) and the quads come
// back as before; with the mirror on, the half's border goes in too. Off, or without
// groups, nothing is handed over.
@(test)
quad_remesh_keeps_group_borders :: proc(t: ^testing.T) {
	when !quadmesh.AVAILABLE {
		log.info("quadmesh is not built on this platform")
		return
	}
	m := geom.icosphere(4)
	defer geom.mesh_destroy(&m)
	groups := make([]u16, len(m.indices) / 3)
	defer delete(groups)
	border := 0
	side := make(map[u64]bool, len(m.indices), context.temp_allocator)
	for tri in 0 ..< len(groups) {
		c := (m.positions[m.indices[3 * tri]] + m.positions[m.indices[3 * tri + 1]] + m.positions[m.indices[3 * tri + 2]]) / 3
		groups[tri] = 1 if c.z > 0.3 else 0
		for k in 0 ..< 3 {
			a, b := m.indices[3 * tri + k], m.indices[3 * tri + (k + 1) % 3]
			key := sculpt.sharp_key(a, b)
			if other, seen := side[key]; seen {
				if other != (groups[tri] == 1) do border += 1
			} else {
				side[key] = groups[tri] == 1
			}
		}
	}
	view := shape_view(&m)
	r := compute(view, 1500, {engine = .Auto, keep_groups = true}, nil, source = {groups = groups})
	defer result_destroy(&r)
	if !testing.expect(t, r.built, "nothing built") do return
	testing.expect_value(t, r.engine, Engine.Auto)
	testing.expect_value(t, r.features, border)
	testing.expectf(t, r.quads >= 1350 && r.quads <= 1650 && r.quads == r.faces, "%d quads of %d faces for 1500 asked", r.quads, r.faces)
	off := compute(view, 1500, {engine = .Auto, keep_groups = false}, nil, source = {groups = groups})
	defer result_destroy(&off)
	testing.expect_value(t, off.features, 0)
	half := compute(view, 1500, {engine = .Auto, keep_groups = true, mirror = {axes = {true, false, false}}}, nil, source = {groups = groups})
	defer result_destroy(&half)
	if !testing.expect(t, half.built, "nothing built with the mirror") do return
	testing.expect(t, half.mirrored, "not mirrored")
	// The half carries its share of the border and its cap's rim, which goes in as a group border too.
	testing.expectf(t, half.features > border / 3, "%d feature edges on the half for %d on the whole", half.features, border)
}
