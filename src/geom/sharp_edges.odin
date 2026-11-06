package geom

import "core:math"
import "core:math/linalg"

// Sharp edges by angle, as Blender's Shade Auto Smooth (Smooth by Angle) and every game
// engine's hard edges: a vertex where faces meet across an edge sharper than an angle is
// split into one vertex for each fan of faces that meet smoothly round it, so each fan
// gets its own normal and the edge shades hard while the faces either side stay smooth.
// The split vertices share positions; nothing is welded or moved.

// Splits `m`'s vertices along every edge whose two triangles' normals differ by more than
// `angle` degrees (and along any edge more or fewer than two triangles share), appending
// the copies after the mesh's own vertices and pointing the triangles of each fan but the
// first at theirs. Returns, per copy, the vertex it copies. The fan with the lowest
// triangle keeps the vertex, so the result depends only on the mesh. Normals are left
// for the caller to compute (zero for the copies).
mesh_split_sharp :: proc(m: ^Mesh, angle: f32, allocator := context.allocator) -> []u32 {
	n := len(m.positions)
	tris := len(m.indices) / 3
	threshold := math.cos(math.to_radians(clamp(angle, 0, 180)))
	normals := make([]Vec3, tris, context.temp_allocator)
	for t in 0 ..< tris {
		a, b, c := m.positions[m.indices[3 * t]], m.positions[m.indices[3 * t + 1]], m.positions[m.indices[3 * t + 2]]
		normals[t] = linalg.normalize0(linalg.cross(b - a, c - a))
	}
	// Each vertex's triangles, in triangle order.
	first := make([]u32, n + 1, context.temp_allocator)
	for i in m.indices do first[i + 1] += 1
	for v in 0 ..< n do first[v + 1] += first[v]
	fill := make([]u32, n, context.temp_allocator)
	around := make([]u32, len(m.indices), context.temp_allocator)
	for i, k in m.indices {
		around[first[i] + fill[i]] = u32(k / 3)
		fill[i] += 1
	}
	from := make([dynamic]u32, allocator)
	group := make([dynamic]int, context.temp_allocator)
	root :: proc(g: []int, x: int) -> int {
		x := x
		for g[x] != x do x = g[x]
		return x
	}
	for v in 0 ..< n {
		list := around[first[v]:first[v + 1]]
		if len(list) < 2 do continue
		resize(&group, len(list))
		for &g, i in group do g = i
		// Two of its triangles join when they share an edge out of v that only they have
		// and their normals are within the angle.
		for i in 0 ..< len(list) do for j in i + 1 ..< len(list) {
			ti, tj := list[i], list[j]
			if linalg.dot(normals[ti], normals[tj]) < threshold do continue
			for w in m.indices[3 * ti:][:3] {
				if int(w) == v || !tri_has(m, tj, w) do continue
				// The edge v-w must be shared by exactly these two among v's triangles.
				count := 0
				for t in list do if tri_has(m, t, w) do count += 1
				if count != 2 do continue
				ri, rj := root(group[:], i), root(group[:], j)
				if ri != rj do group[max(ri, rj)] = min(ri, rj)
			}
		}
		// The fan of the first triangle keeps v; each other fan gets a copy.
		copy_of := make(map[int]u32, allocator = context.temp_allocator)
		for t, i in list {
			r := root(group[:], i)
			if r == root(group[:], 0) do continue
			id, ok := copy_of[r]
			if !ok {
				id = u32(len(m.positions))
				append(&m.positions, m.positions[v])
				append(&from, u32(v))
				copy_of[r] = id
			}
			for k in 0 ..< 3 do if m.indices[3 * int(t) + k] == u32(v) do m.indices[3 * int(t) + k] = id
		}
	}
	resize(&m.normals, len(m.positions))
	return from[:]
}

@(private = "file")
tri_has :: proc(m: ^Mesh, t: u32, v: u32) -> bool {
	c := m.indices[3 * t:][:3]
	return c[0] == v || c[1] == v || c[2] == v
}
