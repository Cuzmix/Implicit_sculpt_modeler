package uv

import "core:math"
import "core:math/linalg"

import "../geom"

// Straighten (the Surface plan's UV6b), as Blender's Follow Active Quads, the UV Squares
// add-on and RizomUV's Rectangularize do: each island made of whole quads is laid out as a
// grid of rectangles, every row and column as long as the mean of its edges on the model,
// so texture rows run straight along the quads' loops. An island is walked from its lowest
// quad, each neighbour placed on the far side of the edge it shares, so every corner gets
// a grid point; an island where two walks give a corner different points (a pole inside
// it, a triangle, a quad split across a seam) is no clean grid and stays as it was. Each
// straightened island keeps its area in the square, and then all are packed again.

Straighten_Report :: struct {
	straightened: int, // islands laid out as grids
	kept:         int, // islands left as they were: not a clean grid of whole quads
}

// Straightens the islands of `u` (UVs of the triangles `indices` with `faces`, at
// `positions`) whose triangles are all halves of quads by `partner` (uv.quad_partners),
// then packs every island again. Deterministic: islands, quads and corners are visited in
// their numbering's order.
straighten :: proc(u: ^Uvs, positions: []geom.Vec3, indices: []u32, faces: geom.Vertex_Faces, partner: []i32) -> (r: Straighten_Report) {
	if !has(u^) || len(partner) != len(u.corner) do return
	order, first := island_triangles(u^, context.temp_allocator)
	for i in 0 ..< u.islands {
		tris := order[first[i]:first[i + 1]]
		if straighten_island(u, positions, indices, faces, partner, tris) do r.straightened += 1
		else do r.kept += 1
	}
	if r.straightened > 0 do pack(u, indices)
	return
}

// Lays one island out as a grid, in place; false, changing nothing, when it is none.
@(private = "file")
straighten_island :: proc(u: ^Uvs, positions: []geom.Vec3, indices: []u32, faces: geom.Vertex_Faces, partner: []i32, tris: []u32) -> bool {
	if len(tris) == 0 || len(tris) % 2 != 0 do return false
	m := island_mesh(u^, indices, faces, tris, context.temp_allocator)
	// Each triangle's place in `tris`, for its corners' wedges.
	local := make(map[u32]u32, len(tris), context.temp_allocator)
	for t, i in tris do local[t] = u32(i)
	for t in tris {
		p := partner[t]
		if p < 0 || u.island[p] != u.island[t] do return false
		if _, in_island := local[u32(p)]; !in_island do return false
	}
	// A quad as its first triangle (the lower of the two) and its corners, counter-
	// clockwise: y, z, x from that triangle (its edge x-y the diagonal) and w from the other.
	Quad :: struct {
		tri:     u32,
		corners: [4]u32, // wedges
		edge_of: [4][2]i32, // per quad edge k (corner k to k + 1): the triangle and its edge, -1 for the diagonal
	}
	quad_of := proc(u: ^Uvs, indices: []u32, faces: geom.Vertex_Faces, partner: []i32, m: Island_Mesh, local: map[u32]u32, t: u32) -> (q: Quad, ok: bool) {
		p := u32(partner[t])
		a, b := min(t, p), max(t, p)
		q.tri = a
		// The diagonal: the edge of a whose ends b runs the other way.
		for k in 0 ..< 3 {
			x, y := indices[3 * a + u32(k)], indices[3 * a + u32((k + 1) % 3)]
			for j in 0 ..< 3 {
				if indices[3 * b + u32(j)] != y || indices[3 * b + u32((j + 1) % 3)] != x do continue
				ka, kb := local[a], local[b]
				wa := proc(m: Island_Mesh, i: u32, k: int) -> u32 {return m.wedge[3 * i + u32(k)]}
				q.corners = {wa(m, ka, (k + 1) % 3), wa(m, ka, (k + 2) % 3), wa(m, ka, k), wa(m, kb, (j + 2) % 3)}
				q.edge_of = {{i32(a), i32((k + 1) % 3)}, {i32(a), i32((k + 2) % 3)}, {i32(b), i32((j + 1) % 3)}, {i32(b), i32((j + 2) % 3)}}
				// The partner's corners on the diagonal must be the same wedges as a's,
				// or the quad is cut by a seam.
				if wa(m, kb, j) != wa(m, ka, (k + 1) % 3) || wa(m, kb, (j + 1) % 3) != wa(m, ka, k) do return
				return q, true
			}
		}
		return
	}
	// Grid points per wedge, set as the walk reaches them.
	NONE :: [2]i32{max(i32), max(i32)}
	grid := make([][2]i32, m.wedges, context.temp_allocator)
	for &g in grid do g = NONE
	seen := make(map[u32]bool, len(tris) / 2, context.temp_allocator)
	queue := make([dynamic]Quad, 0, len(tris) / 2, context.temp_allocator)
	seed, ok := quad_of(u, indices, faces, partner, m, local, tris[0])
	if !ok do return false
	square := [4][2]i32{{0, 0}, {1, 0}, {1, 1}, {0, 1}}
	for c, k in seed.corners do grid[c] = square[k]
	seen[seed.tri] = true
	append(&queue, seed)
	quads := make([dynamic]Quad, 0, len(tris) / 2, context.temp_allocator)
	for head := 0; head < len(queue); head += 1 {
		q := queue[head]
		append(&quads, q)
		for k in 0 ..< 4 {
			t, e := u32(q.edge_of[k][0]), int(q.edge_of[k][1])
			o, _, joined := island_neighbour(u^, indices, faces, t, e)
			if !joined do continue
			n := quad_of(u, indices, faces, partner, m, local, o) or_return
			// The neighbour runs this edge the other way: its corners after it lie one
			// step further out, on its left as it runs.
			a, b := q.corners[k], q.corners[(k + 1) % 4]
			at := -1
			for j in 0 ..< 4 do if n.corners[j] == b && n.corners[(j + 1) % 4] == a do at = j
			if at < 0 do return false
			d := grid[a] - grid[b]
			left := [2]i32{-d.y, d.x}
			want := [2][2]i32{grid[a] + left, grid[b] + left}
			for s in 0 ..< 2 {
				c := n.corners[(at + 2 + s) % 4]
				if grid[c] == NONE do grid[c] = want[s]
				else if grid[c] != want[s] do return false
			}
			if !seen[n.tri] {
				seen[n.tri] = true
				append(&queue, n)
			}
		}
	}
	if 2 * len(quads) != len(tris) do return false
	// Each column's width and each row's height: the mean length on the model of the quad
	// edges that span it.
	lo, hi := grid[seed.corners[0]], grid[seed.corners[0]]
	for g in grid {
		if g == NONE do return false
		lo = {min(lo.x, g.x), min(lo.y, g.y)}
		hi = {max(hi.x, g.x), max(hi.y, g.y)}
	}
	cols, rows := int(hi.x - lo.x), int(hi.y - lo.y)
	sum_u := make([]f64, cols, context.temp_allocator)
	sum_v := make([]f64, rows, context.temp_allocator)
	count_u := make([]int, cols, context.temp_allocator)
	count_v := make([]int, rows, context.temp_allocator)
	for q in quads {
		for k in 0 ..< 4 {
			a, b := q.corners[k], q.corners[(k + 1) % 4]
			ga, gb := grid[a], grid[b]
			length := f64(linalg.length(positions[m.vertex[a]] - positions[m.vertex[b]]))
			if ga.y == gb.y {
				c := int(min(ga.x, gb.x) - lo.x)
				sum_u[c] += length
				count_u[c] += 1
			} else {
				c := int(min(ga.y, gb.y) - lo.y)
				sum_v[c] += length
				count_v[c] += 1
			}
		}
	}
	at_u := make([]f64, cols + 1, context.temp_allocator)
	at_v := make([]f64, rows + 1, context.temp_allocator)
	for c in 0 ..< cols do at_u[c + 1] = at_u[c] + (sum_u[c] / f64(count_u[c]) if count_u[c] > 0 else 0)
	for c in 0 ..< rows do at_v[c + 1] = at_v[c] + (sum_v[c] / f64(count_v[c]) if count_v[c] > 0 else 0)
	// The island's area in the square before, which it keeps.
	before: f64
	for t in tris {
		c := u.corner[t]
		d1, d2 := c[1] - c[0], c[2] - c[0]
		before += 0.5 * abs(f64(d1.x * d2.y - d2.x * d1.y))
	}
	after := at_u[cols] * at_v[rows]
	if after <= 0 || before <= 0 do return false
	scale := math.sqrt(before / after)
	for t, i in tris {
		for k in 0 ..< 3 {
			g := grid[m.wedge[3 * i + k]] - lo
			u.corner[t][k] = {f32(at_u[g.x] * scale), f32(at_v[g.y] * scale)}
		}
	}
	return true
}
