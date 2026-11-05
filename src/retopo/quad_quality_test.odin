package retopo

@(require) import "core:log" // used only where AutoRemesher is not built
import "core:math"
import "core:testing"

import "../geom"
import "../quadmesh"

// Whether every edge of the polygons has exactly two faces, each way round once: closed,
// manifold and consistently wound.
@(private = "file")
polygons_closed :: proc(m: quadmesh.Polygon_Mesh) -> bool {
	seen := make(map[[2]u32]int, context.temp_allocator)
	for f in 0 ..< len(m.first) - 1 {
		corners := m.corners[m.first[f]:m.first[f + 1]]
		for c, k in corners do seen[{c, corners[(k + 1) % len(corners)]}] += 1
	}
	for e, n in seen do if n != 1 || seen[{e[1], e[0]}] != 1 do return false
	return true
}

// Keep symmetry lands the count asked, on one plane, two and three, and every face comes
// back a quad over a closed surface with no fall back to the whole. Through the C++ core
// the flat caps over the cut take none of the count (they took a third more than their
// area's share before), within 5 %. Through the Odin core the half goes in open and lands
// within 2 % from 4,000 quads; below that a hemisphere's cells go in steps (the rows
// between its border and its singular vertices are whole, each a ring of quads, 9 % of
// 1,000 at a time), and it lands within 5 %.
@(test)
quad_remesh_mirrored_lands_the_count :: proc(t: ^testing.T) {
	when !quadmesh.AVAILABLE {
		log.info("quadmesh is not built on this platform")
		return
	}
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	resize(&m.normals, len(m.positions))
	geom.mesh_recompute_normals(&m)
	Case :: struct {
		quads: int,
		axes:  [3]bool,
	}
	cases := []Case {
		{1000, {true, false, false}},
		{2000, {true, false, false}},
		{4000, {true, false, false}},
		{4000, {true, true, false}},
		{8000, {true, false, false}},
		{8000, {true, true, false}},
		{8000, {true, true, true}},
	}
	for core in ([]quadmesh.Core{.Cpp, .Odin}) do for c in cases {
		r := compute(m, c.quads, {engine = .Auto, mirror = {axes = c.axes}, core = core}, nil)
		defer result_destroy(&r)
		check := geom.mesh_check(r.mesh)
		log.infof("%v mirrored %v at %d: %d faces (%.1f %%), %d quads, closed %v", core, c.axes, c.quads, r.faces, 100 * f32(r.faces) / f32(c.quads), r.quads, check.closed)
		testing.expectf(t, r.mirrored, "%v %v at %d was not mirrored: %s", core, c.axes, c.quads, r.unmirrored)
		within := 50 if core == .Odin && c.quads >= 4000 else 20
		testing.expectf(t, abs(r.faces - c.quads) * within <= c.quads, "%v %v gave %d faces for %d asked", core, c.axes, r.faces, c.quads)
		testing.expectf(t, r.quads == r.faces, "%v %v at %d: %d of %d faces are quads", core, c.axes, c.quads, r.quads, r.faces)
		testing.expectf(t, check.closed && check.non_manifold_edges == 0, "%v %v at %d is not closed", core, c.axes, c.quads)
	}
}

// The odd faces' mending: a sphere's quads with one edge collapsed (which leaves the two
// faces on it triangles, a few quads apart round the kept vertex) come back all quads,
// closed, with a few quads more for the path cut between the two.
@(test)
quad_fill_odd_joins_two_triangles :: proc(t: ^testing.T) {
	when !quadmesh.AVAILABLE {
		log.info("quadmesh is not built on this platform")
		return
	}
	s := geom.icosphere(4)
	defer geom.mesh_destroy(&s)
	m, _, err, _ := quadmesh.remesh(s.positions[:], s.indices[:], {quads = 600, sharp_degrees = 90, threads = 1})
	defer quadmesh.polygon_mesh_destroy(&m)
	if !testing.expect_value(t, err, quadmesh.Error.None) do return
	start_quads, _, _ := quadmesh.polygon_share(m)
	if !testing.expect(t, start_quads == len(m.first) - 1 && polygons_closed(m), "the remesh itself was not all quads and closed") do return
	// Collapse the first face's first edge: its second corner becomes its first.
	a, b := m.corners[0], m.corners[1]
	first := make([dynamic]u32, 1)
	corners := make([dynamic]u32)
	for f in 0 ..< len(m.first) - 1 {
		start := len(corners)
		face := m.corners[m.first[f]:m.first[f + 1]]
		for c, k in face {
			c := a if c == b else c
			next := face[(k + 1) % len(face)]
			if (next == b ? a : next) == c do continue
			append(&corners, c)
		}
		if len(corners) - start < 3 do resize(&corners, start)
		else do append(&first, u32(len(corners)))
	}
	faces_before := len(first) - 1
	delete(m.first)
	delete(m.corners)
	m.first, m.corners = first[:], corners[:]
	_, collapsed, _ := quadmesh.polygon_share(m)
	if !testing.expect_value(t, collapsed, 2) do return
	mended, left := quad_fill_odd(&m, nil, nil, s, nil, nil)
	quads, triangles, ngons := quadmesh.polygon_share(m)
	log.infof("collapsed edge: %d faces, %d mended, %d left; then %d quads, %d triangles, %d larger", faces_before, mended, left, quads, triangles, ngons)
	testing.expect_value(t, mended, 2)
	testing.expect_value(t, left, 0)
	testing.expect(t, triangles == 0 && ngons == 0, "odd faces left")
	testing.expect(t, polygons_closed(m), "the mended mesh is not closed and manifold")
	testing.expectf(t, quads > faces_before && quads <= faces_before + 20, "%d quads from %d faces", quads, faces_before)
}

// A capped tube along X, `radius` round and reaching `reach` either side in `rings` rings
// of `around` vertices (a sculpt's tube is dense along it too), facing outward, appended
// to `m`.
@(private = "file")
add_rod :: proc(m: ^geom.Mesh, radius, reach: f32, around, rings: int) {
	base := u32(len(m.positions))
	for r in 0 ..< rings do for i in 0 ..< around {
		a := 2 * math.PI * f32(i) / f32(around)
		x := -reach + 2 * reach * f32(r) / f32(rings - 1)
		append(&m.positions, geom.Vec3{x, radius * math.cos(a), radius * math.sin(a)})
	}
	lo, hi := u32(len(m.positions)), u32(len(m.positions)) + 1
	append(&m.positions, geom.Vec3{-reach, 0, 0}, geom.Vec3{reach, 0, 0})
	n := u32(around)
	at :: proc(base, n: u32, r, i: u32) -> u32 {return base + r * n + i % n}
	for r in 0 ..< u32(rings - 1) do for i in 0 ..< n {
		append(&m.indices, at(base, n, r, i), at(base, n, r + 1, i + 1), at(base, n, r + 1, i))
		append(&m.indices, at(base, n, r, i), at(base, n, r, i + 1), at(base, n, r + 1, i + 1))
	}
	last := u32(rings - 1)
	for i in 0 ..< n {
		append(&m.indices, lo, at(base, n, 0, i + 1), at(base, n, 0, i))
		append(&m.indices, hi, at(base, n, last, i), at(base, n, last, i + 1))
	}
}

// Thin parts: a rod a thirtieth of a sphere's width through it came back gone (a few
// vertices at one end) at 2,000 quads; asked for six quads round, it comes back whole, out
// to both ends, its vertices on its surface, with the count kept and every face a quad.
@(test)
quad_remesh_keeps_thin_parts :: proc(t: ^testing.T) {
	when !quadmesh.AVAILABLE {
		log.info("quadmesh is not built on this platform")
		return
	}
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	add_rod(&m, 0.03, 1.3, 24, 61)
	resize(&m.normals, len(m.positions))
	geom.mesh_recompute_normals(&m)
	r := compute(m, 2000, {engine = .Auto}, nil)
	defer result_destroy(&r)
	if !testing.expect(t, r.built && r.engine == .Auto, "AutoRemesher did not build it") do return
	outside, ends: [2]int
	off: f32
	for p in r.mesh.positions {
		if abs(p.x) < 1.05 do continue
		side := 0 if p.x < 0 else 1
		outside[side] += 1
		if abs(p.x) > 1.25 do ends[side] += 1
		if abs(p.x) < 1.29 do off = max(off, abs(math.sqrt(p.y * p.y + p.z * p.z) - 0.03))
	}
	check := geom.mesh_check(r.mesh)
	log.infof("rod: %d faces, %d thin vertices; outside the sphere %v vertices, %v by the ends, at most %.4f off its surface", r.faces, r.thin, outside, ends, off)
	testing.expect(t, r.thin > 0, "nothing was found thin")
	testing.expectf(t, outside[0] >= 30 && outside[1] >= 30, "the rod outside the sphere has %v vertices", outside)
	testing.expectf(t, ends[0] > 0 && ends[1] > 0, "the rod does not reach its ends: %v", ends)
	testing.expectf(t, off < 0.006, "the rod's vertices lie %.4f off it", off)
	testing.expectf(t, abs(r.faces - 2000) * 20 <= 2000, "%d faces for 2000 asked", r.faces)
	testing.expectf(t, r.quads == r.faces, "%d of %d faces are quads", r.quads, r.faces)
	testing.expect(t, check.closed && check.non_manifold_edges == 0, "not closed")
}

// A doublet (a vertex two quads meet at, sharing both its edges, as the extractor leaves
// where its cells fold) dissolves into the one quad it split: a cube whose top was cut in
// two through a vertex comes back the cube, its planes dropping the vertex's entry too.
@(test)
dissolve_doublets_mends_a_split_quad :: proc(t: ^testing.T) {
	positions := make([]geom.Vec3, 9)
	for &p, i in positions[:8] do p = {f32(i & 1), f32((i >> 1) & 1), f32((i >> 2) & 1)}
	positions[8] = {0.5, 0.5, 1}
	faces := [][]u32{{0, 2, 3, 1}, {4, 5, 7, 6}, {0, 1, 5, 4}, {2, 6, 7, 3}, {0, 4, 6, 2}, {1, 3, 7, 5}}
	m: quadmesh.Polygon_Mesh
	m.positions = positions
	first := make([dynamic]u32)
	corners := make([dynamic]u32)
	append(&first, 0)
	for f, i in faces {
		// The top (4, 5, 7, 6) cut in two through vertex 8 on its diagonal 4 to 7.
		if i == 1 {
			append(&corners, 4, 5, 7, 8)
			append(&first, u32(len(corners)))
			append(&corners, 7, 6, 4, 8)
		} else {
			append(&corners, ..f)
		}
		append(&first, u32(len(corners)))
	}
	m.first, m.corners = first[:], corners[:]
	defer quadmesh.polygon_mesh_destroy(&m)
	planes := make([dynamic]u8, 9)
	defer delete(planes)
	planes[8] = 1
	n := dissolve_doublets(&m, &planes)
	quads, triangles, ngons := quadmesh.polygon_share(m)
	testing.expectf(t, n == 1, "%d dissolved", n)
	testing.expectf(t, len(m.positions) == 8 && len(planes) == 8, "%d vertices, %d plane entries", len(m.positions), len(planes))
	testing.expectf(t, quads == 6 && triangles == 0 && ngons == 0, "%d quads, %d triangles, %d larger", quads, triangles, ngons)
	testing.expect(t, polygons_closed(m), "the cube is not closed")
	for p in planes do testing.expect(t, p == 0, "the dissolved vertex's plane entry stayed")
}
