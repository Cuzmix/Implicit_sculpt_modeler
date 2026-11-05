package retopo

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import "core:testing"

import "../geom"
import "../sculpt"

// A mesh as object_shape hands it to the engines: with normals of its own.
@(private = "file")
shape_view :: proc(m: ^geom.Mesh) -> geom.Mesh {
	resize(&m.normals, len(m.positions))
	geom.mesh_recompute_normals(m)
	return m^
}

// AutoRemesher on a sphere gives every face a quad, the polygons over the triangles two a
// quad in order, the quads with UVs, closed and outward.
@(test)
quad_remesh_keeps_the_polygons :: proc(t: ^testing.T) {
	m := geom.icosphere(4)
	defer geom.mesh_destroy(&m)
	r := compute(shape_view(&m), 1500, {engine = .Flow}, nil)
	defer result_destroy(&r)
	if !testing.expect(t, r.built, "nothing built") do return
	testing.expect_value(t, r.engine, Engine.Flow)
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
	r := compute(shape_view(&m), 400, {engine = .Flow}, nil)
	defer result_destroy(&r)
	if !testing.expect(t, r.built, "nothing built") do return
	testing.expect_value(t, r.engine, Engine.Fast)
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
	r := compute(shape_view(&m), 400, {engine = .Fast}, nil)
	defer result_destroy(&r)
	if !testing.expect(t, r.built, "nothing built") do return
	testing.expect_value(t, r.engine, Engine.Fast)
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
	m := geom.icosphere(4)
	defer geom.mesh_destroy(&m)
	mirror := geom.Remesh_Mirror{axes = {true, false, false}}
	r := compute(shape_view(&m), 1200, {engine = .Flow, mirror = mirror}, nil)
	defer result_destroy(&r)
	if !testing.expectf(t, r.built, "nothing built") do return
	testing.expect_value(t, r.engine, Engine.Flow)
	testing.expectf(t, r.mirrored, "not mirrored (%s)", r.unmirrored)
	testing.expectf(t, r.quads > 800 && r.quads == r.faces, "%d quads of %d faces", r.quads, r.faces)
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
	r := compute(shape_view(&m), 2000, {engine = .Fast, mirror = mirror}, nil)
	defer result_destroy(&r)
	if !testing.expect(t, r.built, "nothing built") do return
	testing.expect_value(t, r.engine, Engine.Fast)
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
	open := compute(shape_view(&m), 2000, {engine = .Flow}, nil)
	defer result_destroy(&open)
	closed := compute(shape_view(&m), 2000, {engine = .Flow, close_first = true}, nil)
	defer result_destroy(&closed)
	if !testing.expect(t, open.built && closed.built, "nothing built") do return
	testing.expect(t, geom.mesh_check(open.mesh).boundary_edges > 0, "Flow closed the hemisphere on its own")
	testing.expect_value(t, open.closed, 0)
	testing.expect(t, closed.closed > 0, "Close first did not remesh")
	after := geom.mesh_check(closed.mesh)
	testing.expect(t, after.closed, "not closed after Close first")
	// The bowl is filled where the winding is positive: about the half ball (2.09), not a box.
	testing.expectf(t, after.volume > 1.4 && after.volume < 2.8, "volume %.2f is not a half ball's", after.volume)
}

// Keep borders: an open hemisphere comes back with every vertex of its rim where it was
// and one quad edge between each two, all quads (the finish pairs the triangles the
// extraction left by paths inside, never through the rim), whole or as a mirrored half.
@(test)
quad_remesh_keeps_the_border :: proc(t: ^testing.T) {
	m := geom.icosphere(4)
	defer geom.mesh_destroy(&m)
	kept := make([dynamic]u32, 0, len(m.indices))
	defer delete(kept)
	for k := 0; k < len(m.indices); k += 3 {
		a, b, c := m.indices[k], m.indices[k + 1], m.indices[k + 2]
		if (m.positions[a].z + m.positions[b].z + m.positions[c].z) > 0 do append(&kept, a, b, c)
	}
	resize(&m.indices, len(kept))
	copy(m.indices[:], kept[:])
	rim := geom.mesh_check(m).boundary_edges
	// The rim's vertices: those on an edge of one triangle.
	uses := make(map[[2]u32]int, len(m.indices), context.temp_allocator)
	for k := 0; k < len(m.indices); k += 3 do for j in 0 ..< 3 {
		a, b := m.indices[k + j], m.indices[k + (j + 1) % 3]
		uses[{min(a, b), max(a, b)}] += 1
	}
	border := make(map[geom.Vec3]bool, 2 * rim, context.temp_allocator)
	for e, n in uses do if n == 1 do border[m.positions[e[0]]], border[m.positions[e[1]]] = true, true
	for mirror in ([2]geom.Remesh_Mirror{{}, {axes = {true, false, false}}}) {
		r := compute(shape_view(&m), 600, {engine = .Flow, keep_borders = true, mirror = mirror}, nil)
		defer result_destroy(&r)
		if !testing.expectf(t, r.built && r.engine == .Flow, "mirror %v: nothing built by Flow (%s)", mirror.axes, r.reason) do continue
		testing.expectf(t, r.mirrored == (mirror.axes != {}), "mirror %v: mirrored %v (%s)", mirror.axes, r.mirrored, r.unmirrored)
		at := make(map[geom.Vec3]bool, len(r.mesh.positions), context.temp_allocator)
		for p in r.mesh.positions do at[p] = true
		missing := 0
		for p in border do if !at[p] do missing += 1
		check := geom.mesh_check(r.mesh)
		log.infof("keep borders, mirror %v: %d quads of %d faces, %d of %d rim vertices kept, %d boundary edges for %d, %d border vertices held", mirror.axes, r.quads, r.faces, len(border) - missing, len(border), check.boundary_edges, rim, r.borders)
		testing.expectf(t, missing == 0, "mirror %v: %d of %d rim vertices moved", mirror.axes, missing, len(border))
		testing.expectf(t, check.boundary_edges == rim && check.non_manifold_edges == 0, "mirror %v: %d boundary edges for %d, %d non-manifold", mirror.axes, check.boundary_edges, rim, check.non_manifold_edges)
		testing.expectf(t, r.faces - r.quads <= 1, "mirror %v: %d quads of %d faces", mirror.axes, r.quads, r.faces)
	}
}

// Adaptive size puts smaller quads where the surface bends and larger ones where it is
// flat, and the count stays what was asked: the triangles' areas spread wider than at Even.
@(test)
quad_remesh_adaptive_size_keeps_the_count :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	// A bumpy sphere: the radius waves with the position.
	for &p in m.positions do p *= 1 + 0.12 * math.sin(6 * p.x) * math.sin(6 * p.y) * math.sin(6 * p.z)
	even := compute(shape_view(&m), 3000, {engine = .Flow}, nil)
	defer result_destroy(&even)
	bent := compute(shape_view(&m), 3000, {engine = .Flow, adaptivity = 1}, nil)
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
// there, the count staying what was asked; off, the paint changes nothing, to the bit. Use
// mask: the masked half gets about twice as many. With the mirror on, the half goes in with
// its paint. The ratios are loose because a sphere's own layout is not even: a plain one's
// quads come out up to a third larger on the side where its singular vertices crowd.
@(test)
quad_remesh_paint_and_mask_move_the_quads :: proc(t: ^testing.T) {
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
	painted := compute(shape_view(&m), 2000, {engine = .Flow, use_paint = true}, nil, source = source)
	defer result_destroy(&painted)
	plain := compute(shape_view(&m), 2000, {engine = .Flow}, nil, source = source)
	defer result_destroy(&plain)
	none := compute(shape_view(&m), 2000, {engine = .Flow}, nil)
	defer result_destroy(&none)
	masked := compute(shape_view(&m), 2000, {engine = .Flow, use_mask = true}, nil, source = source)
	defer result_destroy(&masked)
	mirrored := compute(shape_view(&m), 2000, {engine = .Flow, use_paint = true, mirror = {axes = {true, false, false}}}, nil, source = source)
	defer result_destroy(&mirrored)
	if !testing.expectf(t, painted.built && plain.built && masked.built && mirrored.built, "nothing built") do return
	log.infof("paint: %d faces, %.2f times above; plain %d, %.2f; mask %d, %.2f; mirrored paint %d, %.2f", painted.faces, halves(painted.mesh), plain.faces, halves(plain.mesh), masked.faces, halves(masked.mesh), mirrored.faces, halves(mirrored.mesh))
	for r in ([4]^Result{&painted, &plain, &masked, &mirrored}) {
		testing.expectf(t, r.faces >= 1900 && r.faces <= 2100, "%d faces for 2000 asked", r.faces)
		testing.expectf(t, r.quads == r.faces, "%d of %d faces are quads", r.quads, r.faces)
	}
	testing.expectf(t, halves(painted.mesh) >= 2.5 && halves(painted.mesh) <= 5, "red above gave %.2f times the quads", halves(painted.mesh))
	testing.expectf(t, slice.equal(plain.mesh.positions[:], none.mesh.positions[:]) && slice.equal(plain.mesh.indices[:], none.mesh.indices[:]), "paint not used changed the quads")
	testing.expectf(t, halves(masked.mesh) >= 1.5 && halves(masked.mesh) <= 2.5, "the mask above gave %.2f times the quads", halves(masked.mesh))
	testing.expectf(t, halves(mirrored.mesh) >= 2.5 && halves(mirrored.mesh) <= 5, "red above, mirrored, gave %.2f times the quads", halves(mirrored.mesh))
}

// Keep groups: a sphere whose top is one polygroup and the rest another hands the border
// to AutoRemesher as feature edges (one per edge between the groups) and the quads come
// back as before; with the mirror on, the half's border goes in too. Off, or without
// groups, nothing is handed over.
@(test)
quad_remesh_keeps_group_borders :: proc(t: ^testing.T) {
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
	r := compute(view, 1500, {engine = .Flow, keep_groups = true}, nil, source = {groups = groups})
	defer result_destroy(&r)
	if !testing.expect(t, r.built, "nothing built") do return
	testing.expect_value(t, r.engine, Engine.Flow)
	testing.expect_value(t, r.features, border)
	testing.expectf(t, r.quads >= 1350 && r.quads <= 1650 && r.quads == r.faces, "%d quads of %d faces for 1500 asked", r.quads, r.faces)
	off := compute(view, 1500, {engine = .Flow, keep_groups = false}, nil, source = {groups = groups})
	defer result_destroy(&off)
	testing.expect_value(t, off.features, 0)
	half := compute(view, 1500, {engine = .Flow, keep_groups = true, mirror = {axes = {true, false, false}}}, nil, source = {groups = groups})
	defer result_destroy(&half)
	if !testing.expect(t, half.built, "nothing built with the mirror") do return
	testing.expect(t, half.mirrored, "not mirrored")
	// The half carries its share of the border and its cap's rim, which goes in as a group border too.
	testing.expectf(t, half.features > border / 3, "%d feature edges on the half for %d on the whole", half.features, border)
}

// A circle of `n` points round the axis `axis` at `degrees` from it on the unit sphere,
// closed (its last point is its first), each point then put out to `radius_at` of it.
@(private = "file")
guide_circle :: proc(axis: geom.Vec3, degrees: f32, n: int, radius_at: proc(p: geom.Vec3) -> f32, allocator := context.allocator) -> []geom.Vec3 {
	w := linalg.normalize(axis)
	u := linalg.normalize(linalg.cross(w, geom.Vec3{0, 1, 0} if abs(w.y) < 0.9 else geom.Vec3{1, 0, 0}))
	v := linalg.cross(w, u)
	a := degrees * math.PI / 180
	line := make([]geom.Vec3, n + 1, allocator)
	for k in 0 ..= n {
		t := 2 * math.PI * f32(k % n) / f32(n)
		p := w * math.cos(a) + (u * math.cos(t) + v * math.sin(t)) * math.sin(a)
		line[k] = p * radius_at(p)
	}
	return line
}

// The mean angle in degrees between the quads' edges lying near `line` (their middles
// within `near` of it) and its direction there, folded to 0..45 (an edge along or
// square to it counts as 0), and how many edges were measured.
@(private = "file")
guide_alignment :: proc(r: Result, line: []geom.Vec3, near: f32) -> (mean: f32, edges: int) {
	sum: f32
	for quad in r.q.quads do for k in 0 ..< 4 {
		a, b := r.mesh.positions[quad[k]], r.mesh.positions[quad[(k + 1) % 4]]
		mid := (a + b) / 2
		best := near
		tangent: geom.Vec3
		for s in 1 ..< len(line) {
			p, q := line[s - 1], line[s]
			along := clamp(linalg.dot(mid - p, q - p) / max(linalg.dot(q - p, q - p), 1e-12), 0, 1)
			if d := linalg.length(p + (q - p) * along - mid); d < best {
				best = d
				tangent = linalg.normalize(q - p)
			}
		}
		if tangent == {} do continue
		theta := math.acos(clamp(abs(linalg.dot(linalg.normalize(b - a), tangent)), 0, 1)) * 180 / math.PI
		sum += min(theta, 90 - theta)
		edges += 1
	}
	return sum / f32(max(edges, 1)), edges
}

// Guides: a circle drawn round a sphere 30 degrees off its pole pulls the quads' edges
// along it (under 10 degrees on average at full strength, where with no guide they lie at
// random to it, about 27); a circle across the bumpy sphere likewise; with the mirror on,
// the same circle guides the half; the count stays what was asked, the mirrored half's too.
@(test)
quad_remesh_follows_guides :: proc(t: ^testing.T) {
	one :: proc(p: geom.Vec3) -> f32 {return 1}
	bump :: proc(p: geom.Vec3) -> f32 {return 1 + 0.12 * math.sin(6 * p.x) * math.sin(6 * p.y) * math.sin(6 * p.z)}
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	circle := guide_circle({0.5, 0, 0.866}, 50, 200, one)
	defer delete(circle)
	lines := [][]geom.Vec3{circle}
	near := f32(math.sqrt(4 * math.PI / 2000)) / 2
	bumpy := geom.icosphere(5)
	defer geom.mesh_destroy(&bumpy)
	for &p in bumpy.positions do p *= bump(p)
	across := guide_circle({0.3, 0.9, 0.3}, 70, 300, bump)
	defer delete(across)
	plain := compute(shape_view(&m), 2000, {engine = .Flow}, nil)
	defer result_destroy(&plain)
	half := compute(shape_view(&m), 2000, {engine = .Flow, guide_strength = 0.5}, nil, source = {guides = lines})
	defer result_destroy(&half)
	full := compute(shape_view(&m), 2000, {engine = .Flow, guide_strength = 1}, nil, source = {guides = lines})
	defer result_destroy(&full)
	mirrored := compute(shape_view(&m), 2000, {engine = .Flow, guide_strength = 1, mirror = {axes = {false, true, false}}}, nil, source = {guides = lines})
	defer result_destroy(&mirrored)
	bumpy_plain := compute(shape_view(&bumpy), 3000, {engine = .Flow}, nil)
	defer result_destroy(&bumpy_plain)
	bumpy_guided := compute(shape_view(&bumpy), 3000, {engine = .Flow, guide_strength = 1}, nil, source = {guides = {across}})
	defer result_destroy(&bumpy_guided)
	results := [?]^Result{&plain, &half, &full, &mirrored, &bumpy_plain, &bumpy_guided}
	built := true
	for r in results do built &&= r.built && r.q.quads != nil
	if !testing.expectf(t, built, "nothing built, or not all quads") do return
	a0, n0 := guide_alignment(plain, circle, near)
	a1, n1 := guide_alignment(half, circle, near)
	a2, n2 := guide_alignment(full, circle, near)
	a3, n3 := guide_alignment(mirrored, circle, near)
	near_bumpy := f32(math.sqrt(4 * math.PI / 3000)) / 2
	b0, m0 := guide_alignment(bumpy_plain, across, near_bumpy)
	b1, m1 := guide_alignment(bumpy_guided, across, near_bumpy)
	log.infof("guides: none %.1f° (%d edges), half %.1f° (%d), full %.1f° (%d), mirrored %.1f° (%d); bumpy none %.1f° (%d), full %.1f° (%d); faces %d %d %d %d %d %d; guides %d %d %d",
		a0, n0, a1, n1, a2, n2, a3, n3, b0, m0, b1, m1, plain.faces, half.faces, full.faces, mirrored.faces, bumpy_plain.faces, bumpy_guided.faces, half.guides, full.guides, mirrored.guides)
	testing.expectf(t, full.guides == 1 && mirrored.guides == 1 && plain.guides == 0, "guides kept: %d, %d mirrored, %d with none", full.guides, mirrored.guides, plain.guides)
	testing.expectf(t, a2 < 10 && a3 < 10 && b1 < 10, "at full strength the edges lie %.1f°, %.1f° mirrored and %.1f° on the bumpy sphere from the guide", a2, a3, b1)
	testing.expectf(t, a1 < a0 && a2 <= a1 + 1 && a0 > 12 && b0 > 12, "the edges lie %.1f° from the guide with none, %.1f° at half and %.1f° at full (bumpy: %.1f° with none)", a0, a1, a2, b0)
	for r in results[1:4] do testing.expectf(t, r.faces >= 1900 && r.faces <= 2100, "%d faces for 2000 asked", r.faces)
	testing.expectf(t, bumpy_guided.faces >= 2850 && bumpy_guided.faces <= 3150, "%d faces for 3000 asked on the bumpy sphere", bumpy_guided.faces)
}
