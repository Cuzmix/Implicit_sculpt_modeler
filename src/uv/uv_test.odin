package uv

import "core:math"
import "core:testing"

import "../geom"

// A cube of n by n quads a side, welded, facing out, with the triangles it is drawn as
// (some quads split along 1-3 when `mixed`) and those triangles round each vertex. All
// made with the temp allocator.
@(private = "file")
Fixture :: struct {
	q:       geom.Quad_Mesh,
	indices: []u32,
	faces:   geom.Vertex_Faces,
}

@(private = "file")
cube_grid :: proc(n: int, mixed: bool) -> (f: Fixture) {
	positions := make([dynamic]geom.Vec3, context.temp_allocator)
	quads := make([dynamic][4]u32, context.temp_allocator)
	key := make(map[[3]i32]u32, context.temp_allocator)
	vertex :: proc(positions: ^[dynamic]geom.Vec3, key: ^map[[3]i32]u32, p: [3]i32, n: int) -> u32 {
		if v, ok := key[p]; ok do return v
		v := u32(len(positions))
		append(positions, geom.Vec3{f32(p.x), f32(p.y), f32(p.z)} / f32(n) - 0.5)
		key[p] = v
		return v
	}
	// Each side as an origin and two steps whose cross product points out.
	Side :: struct {
		o, a, b: [3]i32,
	}
	m := i32(n)
	sides := [6]Side {
		{{m, 0, 0}, {0, 1, 0}, {0, 0, 1}},
		{{0, 0, 0}, {0, 0, 1}, {0, 1, 0}},
		{{0, m, 0}, {0, 0, 1}, {1, 0, 0}},
		{{0, 0, 0}, {1, 0, 0}, {0, 0, 1}},
		{{0, 0, m}, {1, 0, 0}, {0, 1, 0}},
		{{0, 0, 0}, {0, 1, 0}, {1, 0, 0}},
	}
	for s in sides {
		for j in 0 ..< m {
			for i in 0 ..< m {
				c := [4][3]i32{s.o + i * s.a + j * s.b, s.o + (i + 1) * s.a + j * s.b, s.o + (i + 1) * s.a + (j + 1) * s.b, s.o + i * s.a + (j + 1) * s.b}
				append(&quads, [4]u32{vertex(&positions, &key, c[0], n), vertex(&positions, &key, c[1], n), vertex(&positions, &key, c[2], n), vertex(&positions, &key, c[3], n)})
			}
		}
	}
	f.q = {positions = positions[:], quads = quads[:]}
	if mixed {
		f.q.across = make([]bool, len(quads), context.temp_allocator)
		for &a, i in f.q.across do a = i % 3 == 1
	}
	indices := make([dynamic]u32, context.temp_allocator)
	for quad, i in f.q.quads {
		for half in geom.quad_halves(f.q, i) do for k in half do append(&indices, quad[k])
	}
	f.indices = indices[:]
	f.faces = geom.vertex_faces_build({positions = positions, indices = indices}, nil, context.temp_allocator)
	return
}

// A quad layout folded into per-corner UVs and seen as quads again is the same layout,
// bit for bit, whichever diagonal each quad is split along.
@(test)
quad_layouts_come_back_bit_for_bit :: proc(t: ^testing.T) {
	for mixed in ([]bool{false, true}) {
		f := cube_grid(4, mixed)
		layout := geom.quad_uv_unwrap(f.q, 0.01, context.temp_allocator)
		u, ok := from_quads(layout, f.q, f.indices, f.faces, context.temp_allocator)
		if !testing.expect(t, ok) do continue
		testing.expect_value(t, check(u, f.indices, f.faces, len(f.q.positions)), "")
		back, back_ok := to_quads(u, f.q, f.indices, f.faces)
		if !testing.expect(t, back_ok) do continue
		testing.expect_value(t, back.charts, layout.charts)
		testing.expect_value(t, back.filled, layout.filled)
		for i in 0 ..< len(layout.uvs) {
			testing.expectf(t, back.uvs[i] == layout.uvs[i], "quad %d: %v came back as %v", i, layout.uvs[i], back.uvs[i])
			testing.expect_value(t, back.chart[i], layout.chart[i])
		}
	}
}

// The seams of a folded layout run along its chart borders, and only there, on both
// sides of each edge; finding islands from those seams gives as many as the charts.
@(test)
seams_follow_the_chart_borders :: proc(t: ^testing.T) {
	f := cube_grid(3, true)
	layout := geom.quad_uv_unwrap(f.q, 0.01, context.temp_allocator)
	u, ok := from_quads(layout, f.q, f.indices, f.faces, context.temp_allocator)
	if !testing.expect(t, ok) do return
	for tri in 0 ..< len(u.corner) {
		for k in 0 ..< 3 {
			o, _, has := across(f.indices, f.faces, u32(tri), k)
			if !testing.expect(t, has, "a closed cube has no border") do continue
			testing.expect_value(t, k in u.seam[tri], u.island[tri] != u.island[o])
		}
	}
	charts := u.islands
	islands_find(&u, f.indices, f.faces)
	testing.expect_value(t, u.islands, charts)
}

// A file's coordinates (v down) are kept per corner (v up) through a renumbering of the
// triangles, and a cut in them becomes a seam on both sides.
@(test)
file_coordinates_cut_where_they_disagree :: proc(t: ^testing.T) {
	f := cube_grid(2, false)
	count := len(f.indices) / 3
	// Each side gets its own square of coordinates, so the cube's twelve edges are cuts.
	file := make([][2]f32, len(f.indices), context.temp_allocator)
	for c, i in f.indices {
		p := f.q.positions[c]
		side := i / 3 / 8
		switch side {
		case 0, 1: file[i] = {p.y, p.z}
		case 2, 3: file[i] = {p.x, p.z}
		case:      file[i] = {p.x, p.y}
		}
		file[i].y += 2 * f32(side)
	}
	// The mesh numbers its triangles backwards from the file's.
	tri_from := make([]u32, count, context.temp_allocator)
	for &from, i in tri_from do from = u32(count - 1 - i)
	reversed := make([]u32, len(f.indices), context.temp_allocator)
	for i in 0 ..< count do copy(reversed[3 * i:][:3], f.indices[3 * int(tri_from[i]):][:3])
	rfaces := geom.vertex_faces_build(geom.Mesh{positions = make([dynamic]geom.Vec3, len(f.q.positions), context.temp_allocator), indices = to_dynamic(reversed)}, nil, context.temp_allocator)
	u := from_corners(reversed, file, tri_from, rfaces, context.temp_allocator)
	testing.expect_value(t, check(u, reversed, rfaces, len(f.q.positions)), "")
	testing.expect_value(t, u.islands, 6)
	for tri in 0 ..< count {
		for k in 0 ..< 3 {
			p := file[3 * tri_from[tri] + u32(k)]
			testing.expect_value(t, u.corner[tri][k], [2]f32{p.x, 1 - p.y})
		}
	}
	seams := 0
	for s in u.seam do seams += card(s)
	// Twelve cube edges, each two quad edges long, cut on both sides.
	testing.expect_value(t, seams, 12 * 2 * 2)
}

@(private = "file")
to_dynamic :: proc(s: []u32) -> [dynamic]u32 {
	d := make([dynamic]u32, len(s), context.temp_allocator)
	copy(d[:], s)
	return d
}

// Islands are numbered by their lowest triangle, whatever order the edges join them in.
@(test)
islands_are_numbered_by_their_first_triangle :: proc(t: ^testing.T) {
	f := cube_grid(2, false)
	u := make_uvs(len(f.indices) / 3, context.temp_allocator)
	// A seam round the first side only: two islands, the first side's triangles being 0.
	for tri in 0 ..< len(u.corner) do for k in 0 ..< 3 {
		o, j, ok := across(f.indices, f.faces, u32(tri), k)
		if ok && (tri < 8) != (o < 8) {
			u.seam[tri] += {k}
			u.seam[o] += {j}
		}
	}
	islands_find(&u, f.indices, f.faces)
	testing.expect_value(t, u.islands, 2)
	for i, tri in u.island do testing.expect_value(t, i, 0 if tri < 8 else 1)
}

// check names each kind of damage.
@(test)
check_refuses_damage :: proc(t: ^testing.T) {
	f := cube_grid(2, false)
	layout := geom.quad_uv_unwrap(f.q, 0.01, context.temp_allocator)
	good, ok := from_quads(layout, f.q, f.indices, f.faces, context.temp_allocator)
	if !testing.expect(t, ok) do return
	vertices := len(f.q.positions)
	testing.expect_value(t, check(good, f.indices, f.faces, vertices), "")

	u := clone(good, context.temp_allocator)
	u.corner[3][1].x = math.nan_f32()
	testing.expect_value(t, check(u, f.indices, f.faces, vertices), "a coordinate is not finite")

	u = clone(good, context.temp_allocator)
	for &s in u.seam do s = {}
	u.seam[0] = {0}
	testing.expect_value(t, check(u, f.indices, f.faces, vertices), "a seam is on one side of its edge only")

	u = clone(good, context.temp_allocator)
	u.island[5] = u32(u.islands)
	testing.expect_value(t, check(u, f.indices, f.faces, vertices), "an island is out of range")

	u = clone(good, context.temp_allocator)
	u.pins = []u32{4, 2}
	testing.expect_value(t, check(u, f.indices, f.faces, vertices), "the pins are not in order")
	u.pins = []u32{2, u32(vertices)}
	testing.expect_value(t, check(u, f.indices, f.faces, vertices), "a pin is out of range")

	u = clone(good, context.temp_allocator)
	u.island = u.island[1:]
	testing.expect_value(t, check(u, f.indices, f.faces, vertices), "the counts differ from the triangles'")
}

// An OBJ strip of three quads with texture coordinates, read as an import reads it: the
// first two quads share their edge's coordinates and make one island, the third is cut off
// by a seam (other `vt` lines on the same edge) and makes a second; v comes back running
// up, as the file has it.
@(test)
obj_coordinates_keep_their_seams :: proc(t: ^testing.T) {
	text := `v 0 0 0
v 1 0 0
v 2 0 0
v 3 0 0
v 0 1 0
v 1 1 0
v 2 1 0
v 3 1 0
vt 0 0
vt 0.25 0
vt 0.5 0
vt 0 0.5
vt 0.25 0.5
vt 0.5 0.5
vt 0.75 0
vt 1 0
vt 0.75 0.5
vt 1 0.5
f 1/1 2/2 6/5 5/4
f 2/2 3/3 7/6 6/5
f 3/7 4/8 8/10 7/9
`
	parts: [dynamic]geom.Mesh_Part
	defer geom.mesh_parts_destroy(&parts)
	err, _ := geom.mesh_read_obj_parts(&parts, transmute([]u8)text, nil)
	if !testing.expect_value(t, err, geom.Mesh_File_Error.None) do return
	p := &parts[0]
	_, clean_err := geom.mesh_clean(&p.mesh, nil, &p.colors, &p.groups, &p.polys, &p.uvs)
	testing.expect_value(t, clean_err, geom.Mesh_File_Error.None)
	first, corners, tri_poly := geom.mesh_polygons(p.mesh.indices[:], p.polys[:])
	defer {
		delete(first)
		delete(corners)
		delete(tri_poly)
	}
	faces := geom.vertex_faces_build(p.mesh, nil, context.temp_allocator)
	indices := p.mesh.indices[:]
	u := from_corners(indices, p.uvs[:], nil, faces, context.temp_allocator)
	testing.expect_value(t, check(u, indices, faces, len(p.mesh.positions)), "")
	testing.expect_value(t, u.islands, 2)
	testing.expect(t, abs(u.filled - 0.375) < 1e-6, "two boxes of 0.5 by 0.5 and 0.25 by 0.5")
	for q, tri in tri_poly {
		testing.expect_value(t, u.island[tri], 0 if q < 2 else 1)
		for k in 0 ..< 3 {
			pos := p.mesh.positions[indices[3 * tri + k]]
			// The first two quads lie on the texture as the strip lies in space, a quarter
			// across and a half up a unit; the third's corner at (3, 0) is the texture's (1, 0).
			if q < 2 do testing.expectf(t, u.corner[tri][k] == [2]f32{pos.x / 4, pos.y / 2}, "triangle %d corner %d: %v", tri, k, u.corner[tri][k])
			else if pos.xy == {3, 0} do testing.expect_value(t, u.corner[tri][k], [2]f32{1, 0})
		}
	}
}

// Unwrap keeps a quad object's quads whole: on a ball of quads (split both ways) no seam
// cuts a diagonal, so both halves of each quad agree on their shared corners and the UVs
// read as the quads' layout.
@(test)
unwrap_keeps_quads_whole :: proc(t: ^testing.T) {
	f := cube_grid(6, true)
	for &p in f.q.positions do p = geom.Vec3(p / max(f32(1e-9), math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)))
	partner, ok := quad_partners(f.q, f.indices, f.faces, context.temp_allocator)
	testing.expect(t, ok)
	for p, tri in partner do testing.expectf(t, p >= 0 && partner[p] == i32(tri), "partner of %d", tri)
	u := make_uvs(len(f.indices) / 3, context.temp_allocator)
	r := unwrap(&u, f.q.positions, f.indices, f.faces, partner = partner)
	testing.expect_value(t, r.flatten.flips, 0)
	testing.expect_value(t, check(u, f.indices, f.faces, len(f.q.positions)), "")
	for s, tri in u.seam do for k in s {
		o, _, _ := across(f.indices, f.faces, u32(tri), k)
		testing.expectf(t, i32(o) != partner[tri], "a seam cuts the diagonal of triangle %d", tri)
	}
	layout, folded := to_quads(u, f.q, f.indices, f.faces)
	testing.expect(t, folded)
	back, again := from_quads(layout, f.q, f.indices, f.faces, context.temp_allocator)
	testing.expect(t, again)
	for c, tri in u.corner do testing.expectf(t, c == back.corner[tri], "triangle %d's corners differ from its quad's", tri)
}

// Straighten lays each island of a box's unwrap out as a grid: every quad a rectangle
// with sides along u and v, as long against each other as on the model (the box is twice
// as long in x), the islands keeping their areas, nothing folded, and the layout still
// checking. A pole inside an island (the sphere's cube corners) keeps its shape.
@(test)
straighten_lays_quads_on_a_grid :: proc(t: ^testing.T) {
	f := cube_grid(4, true)
	for &p in f.q.positions do p.x *= 2
	partner, ok := quad_partners(f.q, f.indices, f.faces, context.temp_allocator)
	if !testing.expect(t, ok) do return
	u := make_uvs(len(f.indices) / 3, context.temp_allocator)
	_ = unwrap(&u, f.q.positions, f.indices, f.faces, partner = partner)
	r := straighten(&u, f.q.positions, f.indices, f.faces, partner)
	testing.expect_value(t, r.kept, 0)
	testing.expect_value(t, r.straightened, u.islands)
	testing.expect_value(t, check(u, f.indices, f.faces, len(f.q.positions)), "")
	layout, folded := to_quads(u, f.q, f.indices, f.faces)
	if !testing.expect(t, folded) do return
	for c, i in layout.uvs {
		quad := f.q.quads[i]
		for k in 0 ..< 4 {
			d := c[(k + 1) % 4] - c[k]
			testing.expectf(t, abs(d.x) < 1e-5 || abs(d.y) < 1e-5, "quad %d's edge %d runs across the grid: %v", i, k, d)
		}
		// Neighbouring sides keep the model's ratio.
		e0 := geom.Vec3(f.q.positions[quad[1]] - f.q.positions[quad[0]])
		e1 := geom.Vec3(f.q.positions[quad[2]] - f.q.positions[quad[1]])
		d0, d1 := c[1] - c[0], c[2] - c[1]
		model := math.sqrt(e0.x * e0.x + e0.y * e0.y + e0.z * e0.z) / math.sqrt(e1.x * e1.x + e1.y * e1.y + e1.z * e1.z)
		laid := math.sqrt(d0.x * d0.x + d0.y * d0.y) / math.sqrt(d1.x * d1.x + d1.y * d1.y)
		testing.expectf(t, abs(laid - model) < 1e-3 * model, "quad %d is %v to 1, on the model %v", i, laid, model)
	}

	// On the sphere the unwrap's charts hold the cube's corners, three quads round each.
	g := cube_grid(6, false)
	for &p in g.q.positions do p = geom.Vec3(p / max(f32(1e-9), math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)))
	pg, _ := quad_partners(g.q, g.indices, g.faces, context.temp_allocator)
	w := make_uvs(len(g.indices) / 3, context.temp_allocator)
	_ = unwrap(&w, g.q.positions, g.indices, g.faces, partner = pg)
	s := straighten(&w, g.q.positions, g.indices, g.faces, pg)
	testing.expect(t, s.kept > 0 && s.straightened + s.kept == w.islands, "the poles' islands were straightened")
	testing.expect_value(t, check(w, g.indices, g.faces, len(g.q.positions)), "")
}
