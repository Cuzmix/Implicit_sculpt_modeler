package uv

import "core:slice"

import "../geom"

// An island as a mesh of its own, which the flattening solves over: its corners joined
// into "wedges", one a vertex of the flat island. A vertex on a seam is a wedge on each
// side of it, and so is a vertex where two fans of the island only touch (a bowtie),
// since corners join only across an edge both triangles share.

Island_Mesh :: struct {
	tris:    []u32,  // the island's triangles, ascending (not owned)
	wedge:   []u32,  // per corner of those triangles, in order: 3 * i + k for triangle i
	vertex:  []u32,  // per wedge, its mesh vertex
	on_edge: []bool, // per wedge, whether it lies on the island's border
	wedges:  int,
	border:  bool,   // whether the island has a border at all
}

island_mesh_free :: proc(m: ^Island_Mesh, allocator := context.allocator) {
	delete(m.wedge, allocator)
	delete(m.vertex, allocator)
	delete(m.on_edge, allocator)
	m^ = {}
}

// The triangles of each island, ascending: island i's are order[first[i]:first[i + 1]].
island_triangles :: proc(u: Uvs, allocator := context.allocator) -> (order, first: []u32) {
	first = make([]u32, u.islands + 1, allocator)
	for i in u.island do first[i + 1] += 1
	for i in 0 ..< u.islands do first[i + 1] += first[i]
	fill := make([]u32, u.islands, allocator)
	defer delete(fill, allocator)
	copy(fill, first[:u.islands])
	order = make([]u32, len(u.island), allocator)
	for i, t in u.island {
		order[fill[i]] = u32(t)
		fill[i] += 1
	}
	return
}

// The edge across which triangle `t`'s edge `k` joins another inside the island: only
// when that triangle's own edge leads back to `t` (so where more than two triangles share
// an edge, the pair `across` matches from both sides joins and the others are borders, as
// check treats them), the edge is no seam and both are in one island.
@(private)
island_neighbour :: proc(u: Uvs, indices: []u32, faces: geom.Vertex_Faces, t: u32, k: int) -> (o: u32, j: int, ok: bool) {
	if k in u.seam[t] do return
	o, j = across(indices, faces, t, k) or_return
	if u.island[o] != u.island[t] do return
	back, _ := across(indices, faces, o, j) or_return
	return o, j, back == t
}

// Builds the island of triangles `tris` (ascending, all of one island). Wedges are
// numbered in the order their first corner comes, so the numbering follows from the mesh
// alone. Made with `allocator`; its scratch too, so a job passes its heap allocator.
island_mesh :: proc(u: Uvs, indices: []u32, faces: geom.Vertex_Faces, tris: []u32, allocator := context.allocator) -> (m: Island_Mesh) {
	m.tris = tris
	n := len(tris)
	parent := make([]u32, 3 * n, allocator)
	defer delete(parent, allocator)
	for &p, c in parent do p = u32(c)
	root :: proc(parent: []u32, c: u32) -> u32 {
		c := c
		for parent[c] != c {
			parent[c] = parent[parent[c]]
			c = parent[c]
		}
		return c
	}
	join :: proc(parent: []u32, a, b: u32) {
		ra, rb := root(parent, a), root(parent, b)
		// The lower root wins, so the numbering below never depends on the order of joins.
		if ra < rb do parent[rb] = ra
		else if rb < ra do parent[ra] = rb
	}
	edge := make([]bool, 3 * n, allocator)
	defer delete(edge, allocator)
	for t, li in tris {
		for k in 0 ..< 3 {
			o, j, ok := island_neighbour(u, indices, faces, t, k)
			if !ok {
				// Both ends of a border edge are on the border.
				edge[3 * li + k], edge[3 * li + (k + 1) % 3] = true, true
				m.border = true
				continue
			}
			lo, found := slice.binary_search(tris, o)
			assert(found, "an island's neighbour is in the island")
			// Corner k of t is corner j + 1 of o, and corner k + 1 of t is corner j of o.
			join(parent, u32(3 * li + k), u32(3 * lo + (j + 1) % 3))
			join(parent, u32(3 * li + (k + 1) % 3), u32(3 * lo + j))
		}
	}
	m.wedge = make([]u32, 3 * n, allocator)
	number := make([]u32, 3 * n, allocator)
	defer delete(number, allocator)
	vertex := make([dynamic]u32, allocator)
	for c in 0 ..< 3 * n {
		r := root(parent, u32(c))
		if r == u32(c) {
			number[c] = u32(len(vertex))
			append(&vertex, indices[3 * tris[c / 3] + u32(c % 3)])
		}
		m.wedge[c] = number[r]
	}
	m.wedges = len(vertex)
	shrink(&vertex)
	m.vertex = vertex[:]
	m.on_edge = make([]bool, m.wedges, allocator)
	for c in 0 ..< 3 * n do if edge[c] do m.on_edge[m.wedge[c]] = true
	return
}
