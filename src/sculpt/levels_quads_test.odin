package sculpt

import "core:math"
import "core:slice"
import "core:testing"

import "../geom"
import "../uv"

// A retopologized object's quads and UVs read back from the scene file on the same
// corners, though reading renumbers the vertices.
@(test)
quads_round_trip_the_file :: proc(t: ^testing.T) {
	source := geom.icosphere(4)
	defer geom.mesh_destroy(&source)
	bvh := geom.bvh_build(source)
	defer geom.bvh_destroy(&bvh)
	q, _, ok := geom.mesh_retopo(source, &bvh, 600, nil)
	if !testing.expect(t, ok) do return
	layout := geom.quad_uv_unwrap(q, 0.01)
	old_to_new := make([]u32, len(q.positions), context.temp_allocator)
	l: Levels
	levels_init(&l, geom.quad_mesh_triangulate(q), nil, 64, old_to_new)
	defer levels_destroy(&l)
	delete(q.positions)
	for &f in q.quads do for &v in f do v = old_to_new[v]
	levels_set_quads(&l, q.quads)
	testing.expect(t, levels_set_uvs(&l, layout))
	// A seam and pins of its own, which a layout does not have, come back too.
	l.uvs.pins = make([]u32, 2, l.allocator)
	l.uvs.pins[0], l.uvs.pins[1] = 3, 40
	before, _ := levels_quad_uvs(&l)
	testing.expect(t, levels_subdivide(&l))
	out := make([dynamic]u8)
	defer delete(out)
	levels_write(&l, &out)

	back: Levels
	r := geom.byte_reader(out[:])
	testing.expect(t, levels_read(&back, &r, nil, 64), "read failed")
	defer levels_destroy(&back)
	testing.expect(t, levels_has_quads(&back) && levels_has_uvs(&back), "quads or UVs were lost")
	if !levels_has_uvs(&back) do return
	a, b := levels_quad_mesh(&l), levels_quad_mesh(&back)
	testing.expect_value(t, len(b.quads), len(a.quads))
	after, _ := levels_quad_uvs(&back)
	testing.expect_value(t, after.charts, before.charts)
	testing.expect_value(t, back.uvs.islands, l.uvs.islands)
	for f, i in a.quads {
		for k in 0 ..< 4 do testing.expect(t, a.positions[f[k]] == b.positions[b.quads[i][k]], "a corner moved")
		testing.expect(t, after.uvs[i] == before.uvs[i] && after.chart[i] == before.chart[i])
	}
	// The pins name the same points, though reading renumbers the vertices.
	if testing.expect_value(t, len(back.uvs.pins), 2) {
		pins := [2]Vec3{a.positions[3], a.positions[40]}
		for p in back.uvs.pins do testing.expect(t, b.positions[p] == pins[0] || b.positions[p] == pins[1], "a pin moved")
	}
	testing.expect_value(t, uv.check(back.uvs, back.levels[0].mesh.indices[:], back.levels[0].sculptor.faces, len(b.positions)), "")
	// Deleting the levels above keeps them; dynamic topology drops them.
	levels_set_current(&back, 0)
	levels_delete_higher(&back)
	testing.expect(t, levels_has_quads(&back) && levels_has_uvs(&back))
	testing.expect(t, levels_dyn_enable(&back))
	testing.expect(t, !levels_has_quads(&back), "dynamic topology kept the quads")
	testing.expect(t, !levels_has_uvs(&back), "dynamic topology kept the UVs")
}

// A unit cube as six quads facing out, with `allocator`.
@(private = "file")
cube_quads :: proc(allocator := context.temp_allocator) -> (q: geom.Quad_Mesh) {
	q.positions = make([]geom.Vec3, 8, allocator)
	for &p, i in q.positions do p = {f32(i & 1), f32(i >> 1 & 1), f32(i >> 2)}
	// Corners 2 and 3 swap so each face runs round, not across.
	q.positions[2], q.positions[3] = {1, 1, 0}, {0, 1, 0}
	q.positions[6], q.positions[7] = {1, 1, 1}, {0, 1, 1}
	q.quads = make([][4]u32, 6, allocator)
	copy(q.quads, [][4]u32{{0, 3, 2, 1}, {4, 5, 6, 7}, {0, 1, 5, 4}, {2, 3, 7, 6}, {0, 4, 7, 3}, {1, 2, 6, 5}})
	return
}

// `pairs` are a cube's twelve edges: each once, lower vertex first, in order, three at
// every corner.
@(private = "file")
expect_cube_edges :: proc(t: ^testing.T, pairs: []u32, loc := #caller_location) {
	if !testing.expect_value(t, len(pairs), 24, loc = loc) do return
	degree: [8]int
	for i in 0 ..< 12 {
		lo, hi := pairs[2 * i], pairs[2 * i + 1]
		testing.expect(t, lo < hi && lo < 8 && hi < 8, "an edge is not lower first", loc = loc)
		if i > 0 do testing.expect(t, u64(pairs[2 * i - 2]) << 32 | u64(pairs[2 * i - 1]) < u64(lo) << 32 | u64(hi), "the edges are out of order or one repeats", loc = loc)
		degree[lo] += 1
		degree[hi] += 1
	}
	for d in degree do testing.expect_value(t, d, 3, loc = loc)
}

// A quad cube's wireframe edges are its twelve, each once and lower vertex first, whether
// its quads are the base level's side table or polygons under a Catmull-Clark rule; a
// Loop level above has none, a Catmull-Clark level above has its own quads' edges.
@(test)
polygon_edges_are_each_edge_once :: proc(t: ^testing.T) {
	q := cube_quads()
	old_to_new := make([]u32, len(q.positions), context.temp_allocator)
	tri_from := make([]u32, 2 * len(q.quads), context.temp_allocator)
	l: Levels
	levels_init(&l, geom.quad_mesh_triangulate(q), nil, 64, old_to_new, tri_from)
	defer levels_destroy(&l)
	testing.expect_value(t, levels_polygon_source(&l, 0), Polygon_Source{})
	testing.expect(t, levels_polygon_edges(&l, 0) == nil, "a level of triangles has polygon edges")

	quads := make([][4]u32, len(q.quads))
	for f, i in q.quads do for v, k in f do quads[i][k] = old_to_new[v]
	levels_set_quads(&l, quads)
	testing.expect_value(t, levels_polygon_source(&l, 0).polygons, 6)
	expect_cube_edges(t, levels_polygon_edges(&l, 0))
	if !testing.expect(t, levels_subdivide(&l)) do return
	testing.expect_value(t, levels_polygon_source(&l, 1), Polygon_Source{})
	testing.expect(t, levels_polygon_edges(&l, 1) == nil, "a Loop level has polygon edges")
	levels_set_current(&l, 0)
	levels_delete_higher(&l)

	// The same cube as polygons: each base triangle's polygon is the quad it was cut from.
	polys: Polys
	polys.first = make([]u32, len(quads) + 1)
	for &x, i in polys.first do x = u32(4 * i)
	polys.corners = make([]u32, 4 * len(quads))
	for &f, i in quads do copy(polys.corners[4 * i:], f[:])
	polys.tri_poly = make([]u32, len(tri_from))
	for from, i in tri_from do polys.tri_poly[i] = from / 2
	if !testing.expect(t, levels_set_polys(&l, polys, {}, .Smooth), "the cube's polygons do not fit") do return
	testing.expect_value(t, levels_polygon_source(&l, 0).polygons, 6)
	expect_cube_edges(t, levels_polygon_edges(&l, 0))
	if !testing.expect(t, levels_subdivide(&l)) do return
	testing.expect_value(t, levels_polygon_source(&l, 1).polygons, 24)
	// 24 quads, 26 vertices: 48 edges, closed.
	testing.expect_value(t, len(levels_polygon_edges(&l, 1)), 96)
}

// A damaged UV section is refused, never asserted on: cut short anywhere in it, a seam
// byte out of range, a seam on one side of its edge only, a coordinate that is not
// finite, an island out of range.
@(test)
uvs_refuse_damage :: proc(t: ^testing.T) {
	q := cube_quads(context.allocator)
	defer delete(q.positions)
	old_to_new := make([]u32, len(q.positions), context.temp_allocator)
	l: Levels
	levels_init(&l, geom.quad_mesh_triangulate(q), nil, 64, old_to_new)
	defer levels_destroy(&l)
	for &f in q.quads do for &v in f do v = old_to_new[v]
	levels_set_quads(&l, q.quads)
	if !testing.expect(t, levels_set_uvs(&l, geom.quad_uv_unwrap(levels_quad_mesh(&l), 0.01))) do return
	out := make([dynamic]u8)
	defer delete(out)
	levels_write(&l, &out)
	// The section starts at the triangle count before the first triangle's coordinates.
	first := slice.to_bytes(l.uvs.corner[:1])
	at := -1
	for i in 0 ..= len(out) - len(first) do if slice.equal(out[i:][:len(first)], first) {at = i; break}
	if !testing.expect(t, at > 4, "the UV section was not found") do return
	count := len(l.uvs.corner)
	seams := at + count * size_of([3][2]f32)
	islands := seams + count * size_of(uv.Seams)
	refused :: proc(t: ^testing.T, data: []u8, what: string, loc := #caller_location) {
		back: Levels
		r := geom.byte_reader(data)
		testing.expectf(t, !levels_read(&back, &r, nil, 64), "%s was read", what, loc = loc)
		testing.expect(t, len(back.levels) == 0, loc = loc)
	}
	for cut := at - 5; cut < len(out) - 4; cut += 7 do refused(t, out[:cut], "a file cut in its UVs")
	bad := slice.clone(out[:], context.temp_allocator)
	bad[seams] = 9
	refused(t, bad, "a seam byte past three edges")
	copy(bad, out[:])
	bad[seams] ~= 1
	refused(t, bad, "a seam on one side")
	copy(bad, out[:])
	nan := transmute([4]u8)math.nan_f32()
	copy(bad[at:], nan[:])
	refused(t, bad, "a coordinate that is not a number")
	copy(bad, out[:])
	past := transmute([4]u8)u32(l.uvs.islands)
	copy(bad[islands:], past[:])
	refused(t, bad, "an island out of range")
}
