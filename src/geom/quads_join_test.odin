package geom

import "core:slice"
import "core:testing"

import "../jobs"

// Shuffles `m`'s triangles by a fixed sequence, so the file's order says nothing of which
// triangles made a quad.
@(private = "file")
shuffle_triangles :: proc(m: ^Mesh) {
	x: u64 = 12345
	for i := len(m.indices) / 3 - 1; i > 0; i -= 1 {
		x = x * 6364136223846793005 + 1442695040888963407
		j := int((x >> 33) % u64(i + 1))
		for k in 0 ..< 3 do m.indices[3 * i + k], m.indices[3 * j + k] = m.indices[3 * j + k], m.indices[3 * i + k]
	}
}

// A torus of quads cut into triangles, as an STL or glTF exporter writes it, comes back as
// its quads: in the file's order, and shuffled (by shape alone); with a pool or without,
// the same triangles in the same order.
@(test)
join_quads_finds_a_quad_meshs_quads :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 4)
	defer jobs.pool_destroy(&pool)
	for shuffled in ([]bool{false, true}) {
		serial := torus_grid(24, 12, 1, 0.3)
		defer mesh_destroy(&serial)
		if shuffled do shuffle_triangles(&serial)
		parallel: Mesh
		parallel.indices = slice.clone_to_dynamic(serial.indices[:])
		parallel.positions = slice.clone_to_dynamic(serial.positions[:])
		defer mesh_destroy(&parallel)
		a, b: [dynamic]u32
		defer delete(a)
		defer delete(b)
		found := mesh_join_quads(&serial, nil, nil, &a, nil)
		found_parallel := mesh_join_quads(&parallel, nil, nil, &b, &pool)
		testing.expectf(t, found.kept && found.pairs == 24 * 12, "shuffled %v: %v", shuffled, found)
		testing.expect(t, found == found_parallel && slice.equal(serial.indices[:], parallel.indices[:]) && slice.equal(a[:], b[:]), "the pool changed the result")
		first, corners, tri_poly := mesh_polygons(serial.indices[:], a[:])
		defer delete(first)
		defer delete(corners)
		defer delete(tri_poly)
		testing.expect_value(t, len(first) - 1, 24 * 12)
		quads := true
		for f in 0 ..< len(first) - 1 do quads &&= first[f + 1] - first[f] == 4
		testing.expect(t, quads, "every polygon a quad")
	}
}

// A mesh of near-equal triangles pairs up as well as quads do (a lattice of triangles is
// one of rhombi cut in two), but its rhombi are far from square, so it stays as it is.
@(test)
join_quads_leaves_a_triangle_mesh :: proc(t: ^testing.T) {
	for shape in 0 ..< 2 {
		m := icosphere(4) if shape == 0 else geodesic_sphere(30)
		defer mesh_destroy(&m)
		before := slice.clone(m.indices[:])
		defer delete(before)
		polys: [dynamic]u32
		defer delete(polys)
		found := mesh_join_quads(&m, nil, nil, &polys)
		testing.expectf(t, !found.kept && found.corner > QUAD_CORNER_MEAN, "shape %d: %v", shape, found)
		testing.expect(t, len(polys) == 0 && slice.equal(before, m.indices[:]), "a triangle mesh was changed")
	}
}

// Two triangles in different polygroups, or whose texture coordinates part along their
// shared edge, stay apart; the groups and coordinates follow their triangles as the pairs
// are put together.
@(test)
join_quads_keeps_groups_and_seams :: proc(t: ^testing.T) {
	m := torus_grid(24, 12, 1, 0.3)
	defer mesh_destroy(&m)
	shuffle_triangles(&m)
	triangles := len(m.indices) / 3
	// A coordinate a corner from its vertex, so it can be checked after; the triangles of
	// the quad at vertex 0 get another polygroup on one side, and those at vertex 50 a seam.
	coord :: proc(v: u32) -> [2]f32 {return {f32(v), f32(v % 7)}}
	groups := make([dynamic]u16, triangles)
	defer delete(groups)
	uvs := make([dynamic][2]f32, 3 * triangles)
	defer delete(uvs)
	split_group, split_seam := -1, -1
	for tr in 0 ..< triangles {
		tri := m.indices[3 * tr:][:3]
		for k in 0 ..< 3 do uvs[3 * tr + k] = coord(tri[k])
		// The torus cuts each quad a, d, c / a, c, b: the first triangle of a quad starts
		// at its own corner a and runs to d.
		if tri[0] == 0 && tri[1] == 1 do split_group = tr
		if tri[0] == 50 && tri[1] == 51 do split_seam = tr
	}
	if !testing.expect(t, split_group >= 0 && split_seam >= 0) do return
	groups[split_group] = 1
	for k in 0 ..< 3 do uvs[3 * split_seam + k].y += 0.5
	seam_tri := [3]u32{m.indices[3 * split_seam], m.indices[3 * split_seam + 1], m.indices[3 * split_seam + 2]}
	polys: [dynamic]u32
	defer delete(polys)
	found := mesh_join_quads(&m, &groups, &uvs, &polys)
	testing.expectf(t, found.kept && found.pairs == 24 * 12 - 2, "%v", found)
	for tr in 0 ..< triangles {
		tri := m.indices[3 * tr:][:3]
		alone := (tr == 0 || polys[tr - 1] != polys[tr]) && (tr + 1 == triangles || polys[tr + 1] != polys[tr])
		if tri[0] == 0 && tri[1] == 1 {
			testing.expect(t, alone && groups[tr] == 1, "the triangle of another polygroup was joined, or lost its group")
		} else if slice.equal(tri, seam_tri[:]) {
			testing.expect(t, alone, "the triangle across a seam was joined")
			for k in 0 ..< 3 do testing.expect_value(t, uvs[3 * tr + k], coord(tri[k]) + {0, 0.5})
		} else {
			for k in 0 ..< 3 do testing.expect_value(t, uvs[3 * tr + k], coord(tri[k]))
		}
	}
}
