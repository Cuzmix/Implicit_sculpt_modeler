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
