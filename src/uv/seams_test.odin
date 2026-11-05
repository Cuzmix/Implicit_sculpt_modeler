package uv

import "core:math"
import "core:math/linalg"
import "core:testing"

import "../geom"
import "../jobs"

// Each island of `u` is a disc: V - E + F = 1 over its wedges (island_mesh) and a border.
@(private = "file")
all_discs :: proc(u: Uvs, indices: []u32, faces: geom.Vertex_Faces) -> bool {
	order, first := island_triangles(u, context.temp_allocator)
	for i in 0 ..< u.islands {
		tris := order[first[i]:first[i + 1]]
		m := island_mesh(u, indices, faces, tris, context.temp_allocator)
		if !m.border do return false
		borders := 0
		for t in tris do for k in 0 ..< 3 {
			if _, _, ok := island_neighbour(u, indices, faces, t, k); !ok do borders += 1
		}
		if m.wedges - (3 * len(tris) + borders) / 2 + len(tris) != 1 do return false
	}
	return true
}

// A sphere is cut into discs that unwrap with no flips into the square; a cube's seams
// fall on its edges; polygroups become islands; the same bits on any pool.
@(test)
auto_seams_cut_discs :: proc(t: ^testing.T) {
	{
		m := geom.icosphere(3, allocator = context.temp_allocator)
		faces := geom.vertex_faces_build(m, nil, context.temp_allocator)
		u := make_uvs(len(m.indices) / 3, context.temp_allocator)
		r := unwrap(&u, m.positions[:], m.indices[:], faces)
		testing.expectf(t, r.charts >= 4 && r.charts <= 40, "charts %d", r.charts)
		testing.expect(t, all_discs(u, m.indices[:], faces), "every island a disc")
		testing.expect_value(t, r.flatten.closed, 0)
		testing.expect_value(t, r.flatten.flips, 0)
		s := stretch(u, m.positions[:], m.indices[:])
		testing.expectf(t, s.flips == 0 && s.l2 < 1.1, "stretch %v", s)
		for c in u.corner do for p in c do testing.expectf(t, p.x >= 0 && p.y >= 0 && p.x <= 1 && p.y <= 1, "inside: %v", p)
		testing.expect_value(t, check(u, m.indices[:], faces, len(m.positions)), "")
	}
	{
		m, ok := geom.cube_grid(4, 1, nil, context.temp_allocator)
		testing.expect(t, ok)
		faces := geom.vertex_faces_build(m, nil, context.temp_allocator)
		u := make_uvs(len(m.indices) / 3, context.temp_allocator)
		r := unwrap(&u, m.positions[:], m.indices[:], faces)
		testing.expectf(t, r.charts <= 6, "charts %d", r.charts)
		testing.expect(t, all_discs(u, m.indices[:], faces), "every island a disc")
		// Every seam on a cube edge: its two triangles face different ways.
		for s, tri in u.seam do for k in s {
			o, _, _ := across(m.indices[:], faces, u32(tri), k)
			n1 := triangle_normal(m.positions[:], m.indices[:], u32(tri))
			n2 := triangle_normal(m.positions[:], m.indices[:], o)
			testing.expectf(t, n1 != n2, "seam %d.%d inside a face", tri, k)
		}
		testing.expect_value(t, r.flatten.flips, 0)
	}
	{
		// Two groups on a flat grid: two islands.
		positions, indices, faces, u := test_grid(6, same)
		groups := make([]u16, len(indices) / 3, context.temp_allocator)
		for &g, tri in groups do g = 1 if positions[indices[3 * tri]].x >= 3 && positions[indices[3 * tri + 1]].x >= 3 && positions[indices[3 * tri + 2]].x >= 3 else 0
		_ = auto_seams(&u, positions, indices, faces, groups)
		testing.expect_value(t, u.islands, 2)
	}
	{
		m := geom.icosphere(3, allocator = context.temp_allocator)
		faces := geom.vertex_faces_build(m, nil, context.temp_allocator)
		results: [2][][3][2]f32
		for workers, i in ([2]int{0, 3}) {
			pool: jobs.Pool
			jobs.pool_init(&pool, workers)
			defer jobs.pool_destroy(&pool)
			u := make_uvs(len(m.indices) / 3, context.temp_allocator)
			_ = unwrap(&u, m.positions[:], m.indices[:], faces, pool = &pool)
			results[i] = u.corner
		}
		same_bits := true
		for c, i in results[0] do if c != results[1][i] do same_bits = false
		testing.expect(t, same_bits, "the same on every pool")
	}
}

@(private = "file")
triangle_normal :: proc(positions: []geom.Vec3, indices: []u32, t: u32) -> [3]i8 {
	tri := indices[3 * t:][:3]
	n := geom.Vec3{}
	e1, e2 := positions[tri[1]] - positions[tri[0]], positions[tri[2]] - positions[tri[0]]
	n = {e1.y * e2.z - e1.z * e2.y, e1.z * e2.x - e1.x * e2.z, e1.x * e2.y - e1.y * e2.x}
	return {i8(math.sign(n.x)), i8(math.sign(n.y)), i8(math.sign(n.z))}
}

// The skyline packs a mixed set (a sphere's charts) apart, inside the square or inside
// its tiles with none crossing a tile's wall, and fills more than the shelf rows do.
@(test)
skyline_packs_tiles :: proc(t: ^testing.T) {
	m := geom.icosphere(4, allocator = context.temp_allocator)
	faces := geom.vertex_faces_build(m, nil, context.temp_allocator)
	base := make_uvs(len(m.indices) / 3, context.temp_allocator)
	opts := DEFAULT_UNWRAP
	opts.seams.cone = 30 // more, smaller charts
	_ = unwrap(&base, m.positions[:], m.indices[:], faces, options = opts)
	testing.expect(t, base.islands > 10)
	fill: [2]f32
	for method, mi in ([2]Pack_Method{.Shelf, .Skyline}) {
		for tiles in ([2]int{1, 3}) {
			u := clone(base, context.temp_allocator)
			filled := pack(&u, m.indices[:], {method, tiles})
			if tiles == 1 do fill[mi] = filled
			lo := make([][2]f32, u.islands, context.temp_allocator)
			hi := make([][2]f32, u.islands, context.temp_allocator)
			for &l in lo do l = {1e9, 1e9}
			for &h in hi do h = {-1e9, -1e9}
			for c, tri in u.corner do for p in c {
				i := u.island[tri]
				lo[i], hi[i] = {min(lo[i].x, p.x), min(lo[i].y, p.y)}, {max(hi[i].x, p.x), max(hi[i].y, p.y)}
			}
			width := f32(tiles) if method == .Skyline else 1
			for i in 0 ..< u.islands {
				testing.expectf(t, lo[i].x >= 0 && lo[i].y >= 0 && hi[i].x <= width && hi[i].y <= 1, "%v tiles %d: island %d inside", method, tiles, i)
				testing.expectf(t, math.floor(lo[i].x) == math.floor(hi[i].x) || hi[i].x == math.floor(hi[i].x), "%v: island %d crosses a tile wall", method, i)
				for j in i + 1 ..< u.islands {
					apart := hi[i].x < lo[j].x || hi[j].x < lo[i].x || hi[i].y < lo[j].y || hi[j].y < lo[i].y
					testing.expectf(t, apart, "%v: islands %d and %d apart", method, i, j)
				}
			}
		}
	}
	testing.expectf(t, fill[1] > fill[0] && fill[1] > 0.7, "skyline %v, shelf %v", fill[1], fill[0])
}

// A mesh with UVs split for drawing: each corner's slot holds its vertex and coordinate,
// a seam splits its vertices (more slots than vertices), and each tangent is a unit
// direction square to the normal.
@(test)
split_follows_the_seams :: proc(t: ^testing.T) {
	m := geom.icosphere(3, allocator = context.temp_allocator)
	faces := geom.vertex_faces_build(m, nil, context.temp_allocator)
	u := make_uvs(len(m.indices) / 3, context.temp_allocator)
	_ = unwrap(&u, m.positions[:], m.indices[:], faces)
	normals := make([]geom.Vec3, len(m.positions), context.temp_allocator)
	for p, v in m.positions do normals[v] = linalg.normalize(p)
	s := split(u, m.positions[:], m.indices[:], normals, context.temp_allocator)
	testing.expectf(t, len(s.vertex) > len(m.positions), "slots %d for %d vertices", len(s.vertex), len(m.positions))
	for c in 0 ..< len(m.indices) {
		slot := s.indices[c]
		testing.expect(t, s.vertex[slot] == m.indices[c] && s.uv[slot] == u.corner[c / 3][c % 3])
	}
	for tan, slot in s.tangents {
		d := linalg.dot(tan.xyz, normals[s.vertex[slot]])
		testing.expectf(t, abs(linalg.length(tan.xyz) - 1) < 1e-4 && abs(d) < 1e-4 && abs(tan.w) == 1, "tangent %v", tan)
	}
}
