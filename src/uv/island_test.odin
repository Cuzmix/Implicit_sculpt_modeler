package uv

import "core:math"
import "core:testing"

import "../geom"

// A flat grid of n by n squares in the z = 0 plane, each cut along its diagonal, with
// UVs `uv_of` each corner's position, and the triangles round each vertex. Temp memory.
@(private = "file")
grid :: proc(n: int, uv_of: proc(p: geom.Vec3) -> [2]f32) -> (positions: []geom.Vec3, indices: []u32, faces: geom.Vertex_Faces, u: Uvs) {
	m: geom.Mesh
	m.positions = make([dynamic]geom.Vec3, context.temp_allocator)
	m.indices = make([dynamic]u32, context.temp_allocator)
	for y in 0 ..= n do for x in 0 ..= n do append(&m.positions, geom.Vec3{f32(x), f32(y), 0})
	at :: proc(n, x, y: int) -> u32 {return u32(y * (n + 1) + x)}
	for y in 0 ..< n do for x in 0 ..< n {
		append(&m.indices, at(n, x, y), at(n, x + 1, y), at(n, x + 1, y + 1))
		append(&m.indices, at(n, x, y), at(n, x + 1, y + 1), at(n, x, y + 1))
	}
	positions, indices = m.positions[:], m.indices[:]
	faces = geom.vertex_faces_build(m, nil, context.temp_allocator)
	u = make_uvs(len(indices) / 3, context.temp_allocator)
	for &c, t in u.corner do for k in 0 ..< 3 do c[k] = uv_of(positions[indices[3 * t + k]])
	return
}

@(private = "file")
same :: proc(p: geom.Vec3) -> [2]f32 {return p.xy}

// Marks the edge from vertex a to vertex b a seam on both of its triangles.
@(private = "file")
cut :: proc(u: ^Uvs, indices: []u32, a, b: u32) {
	for t in 0 ..< len(u.corner) do for k in 0 ..< 3 {
		p, q := indices[3 * t + k], indices[3 * t + (k + 1) % 3]
		if (p == a && q == b) || (p == b && q == a) do u.seam[t] += {k}
	}
}

// A seam that ends inside the island splits only the vertex on the border: there the
// fan is cut in two, while round the inner end the fan still holds together.
@(test)
wedges_split_where_a_seam_cuts_a_fan :: proc(t: ^testing.T) {
	positions, indices, faces, u := grid(2, same)
	cut(&u, indices, 1, 4) // (1, 0) to (1, 1): from the bottom edge to the middle
	islands_find(&u, indices, faces)
	testing.expect_value(t, u.islands, 1)
	order, first := island_triangles(u, context.temp_allocator)
	m := island_mesh(u, indices, faces, order[first[0]:first[1]], context.temp_allocator)
	testing.expect_value(t, len(positions), 9)
	testing.expect_value(t, m.wedges, 10)
	testing.expect(t, m.border, "a grid has a border")
	// The middle vertex is on the border now, being the seam's end; no other inner one.
	inner := 0
	for on in m.on_edge do if !on do inner += 1
	testing.expect_value(t, inner, 0)
	for w in 0 ..< m.wedges do if m.vertex[w] == 4 do testing.expect(t, m.on_edge[w], "the seam's inner end lies on the border")
	// Each corner's wedge is at its corner's vertex.
	for c, i in m.wedge do testing.expect_value(t, m.vertex[c], indices[3 * m.tris[i / 3] + u32(i % 3)])
}

// Two triangles that share only a vertex are islands of their own, each with its wedge
// there; three triangles on one edge join the pair `across` finds from both sides and
// leave the third on its own.
@(test)
wedges_part_at_bowties_and_non_manifold_edges :: proc(t: ^testing.T) {
	{
		m: geom.Mesh
		m.positions = make([dynamic]geom.Vec3, context.temp_allocator)
		m.indices = make([dynamic]u32, context.temp_allocator)
		append(&m.positions, geom.Vec3{0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {-1, 0, 0}, {0, -1, 0})
		append(&m.indices, 0, 1, 2, 0, 3, 4)
		faces := geom.vertex_faces_build(m, nil, context.temp_allocator)
		u := make_uvs(2, context.temp_allocator)
		islands_find(&u, m.indices[:], faces)
		testing.expect_value(t, u.islands, 2)
	}
	{
		m: geom.Mesh
		m.positions = make([dynamic]geom.Vec3, context.temp_allocator)
		m.indices = make([dynamic]u32, context.temp_allocator)
		append(&m.positions, geom.Vec3{0, 0, 0}, {1, 0, 0}, {0.5, 1, 0}, {0.5, -1, 0}, {0.5, 0, 1})
		// The edge 0-1 is shared by three triangles: two run it 1 to 0, one 0 to 1.
		append(&m.indices, 0, 1, 2, 1, 0, 3, 1, 0, 4)
		faces := geom.vertex_faces_build(m, nil, context.temp_allocator)
		u := make_uvs(3, context.temp_allocator)
		islands_find(&u, m.indices[:], faces)
		order, first := island_triangles(u, context.temp_allocator)
		for i in 0 ..< u.islands {
			island := island_mesh(u, m.indices[:], faces, order[first[i]:first[i + 1]], context.temp_allocator)
			testing.expect(t, island.border, "every piece here has a border")
			if len(island.tris) == 3 do testing.expect_value(t, island.wedges, 7)
		}
		wedges := 0
		for i in 0 ..< u.islands {
			island := island_mesh(u, m.indices[:], faces, order[first[i]:first[i + 1]], context.temp_allocator)
			wedges += island.wedges
		}
		// 0-1-2 and 1-0-3 join along the edge (4 wedges); 1-0-4 keeps its own 3.
		testing.expect_value(t, wedges, 7)
	}
}

// A closed surface with no seam is one island with no border, a wedge a vertex.
@(test)
closed_islands_have_no_border :: proc(t: ^testing.T) {
	m := geom.icosphere(1, allocator = context.temp_allocator)
	faces := geom.vertex_faces_build(m, nil, context.temp_allocator)
	u := make_uvs(len(m.indices) / 3, context.temp_allocator)
	islands_find(&u, m.indices[:], faces)
	order, first := island_triangles(u, context.temp_allocator)
	island := island_mesh(u, m.indices[:], faces, order[first[0]:first[1]], context.temp_allocator)
	testing.expect(t, !island.border)
	testing.expect_value(t, island.wedges, len(m.positions))
}

// The UVs of a flat grid laid as it lies have no stretch; stretched twice across they
// have the singular values a known affine map has, and mirrored they all flip.
@(test)
stretch_of_known_maps :: proc(t: ^testing.T) {
	positions, indices, _, u := grid(4, same)
	s := stretch(u, positions, indices)
	testing.expect_value(t, s.triangles, 32)
	testing.expect(t, abs(s.l2 - 1) < 1e-9 && abs(s.worst - 1) < 1e-9 && s.angle < 1e-6, "an exact copy")
	testing.expect_value(t, s.flips, 0)

	_, _, _, wide := grid(4, proc(p: geom.Vec3) -> [2]f32 {return {2 * p.x, p.y}})
	// Scaled to the surface's area, the texture is √2 across and 1/√2 up, so the map back
	// to the surface has singular values √2 and 1/√2.
	s = stretch(wide, positions, indices)
	testing.expectf(t, abs(s.l2 - math.sqrt(f64(1.25))) < 1e-9, "L2 %v", s.l2)
	testing.expectf(t, abs(s.worst - 2) < 1e-9, "worst %v", s.worst)
	testing.expect(t, s.angle > 1, "the diagonals' corners change")

	_, _, _, mirrored := grid(4, proc(p: geom.Vec3) -> [2]f32 {return {-p.x, p.y}})
	s = stretch(mirrored, positions, indices)
	testing.expect_value(t, s.flips, 32)

	// Only the triangles asked for are measured.
	s = stretch(u, positions, indices, []u32{0, 5})
	testing.expect_value(t, s.triangles, 2)
}
