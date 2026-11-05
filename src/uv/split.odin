package uv

import "core:math/linalg"

import "../geom"

// A triangle mesh with UVs as a GPU or a file wants it: a vertex wherever a vertex takes a
// coordinate of its own (each vertex once for each island and coordinate its corners hold,
// so a seam splits it), with its smooth normal, its coordinate and its tangent, and the
// triangles as those slots in their own order and corner order. The same frame the bake
// and the textured preview of a quad object use (geom.quad_mesh_tangents): per-triangle
// UV gradients summed at each slot, made square to its normal, the sign of the bitangent
// in w, so a normal map reads back the same way on either.
Split :: struct {
	vertex:   []u32,      // per slot: its vertex
	uv:       [][2]f32,   // per slot
	tangents: [][4]f32,   // per slot: xyz unit, w ±1
	indices:  []u32,      // per triangle corner: its slot
}

// Splits the mesh `positions` and `indices` with UVs `u` and smooth `normals` (one a
// vertex). Slots are numbered in the order their first corner comes, so the result follows
// from the mesh alone. Made with `allocator`.
split :: proc(u: Uvs, positions: []geom.Vec3, indices: []u32, normals: []geom.Vec3, allocator := context.allocator) -> (s: Split) {
	assert(len(u.corner) == len(indices) / 3)
	Key :: struct {
		vertex: u32,
		island: u32,
		at:     [2]f32,
	}
	// Only looked up, so its order decides nothing.
	slot_of := make(map[Key]u32, len(positions), context.temp_allocator)
	vertex := make([dynamic]u32, 0, len(positions), allocator)
	coords := make([dynamic][2]f32, 0, len(positions), allocator)
	sums := make([dynamic][2]geom.Vec3, 0, len(positions), context.temp_allocator)
	s.indices = make([]u32, len(indices), allocator)
	for t in 0 ..< len(u.corner) {
		for k in 0 ..< 3 {
			key := Key{indices[3 * t + k], u.island[t], u.corner[t][k]}
			slot, found := slot_of[key]
			if !found {
				slot = u32(len(sums))
				append(&sums, [2]geom.Vec3{})
				append(&vertex, key.vertex)
				append(&coords, key.at)
				slot_of[key] = slot
			}
			s.indices[3 * t + k] = slot
		}
		p0, p1, p2 := positions[indices[3 * t]], positions[indices[3 * t + 1]], positions[indices[3 * t + 2]]
		t0, t1, t2 := u.corner[t][0], u.corner[t][1], u.corner[t][2]
		e1, e2 := p1 - p0, p2 - p0
		d1, d2 := t1 - t0, t2 - t0
		det := d1.x * d2.y - d2.x * d1.y
		if abs(det) < 1e-20 do continue
		r := 1 / det
		tangent := (e1 * d2.y - e2 * d1.y) * r
		bitangent := (e2 * d1.x - e1 * d2.x) * r
		for k in 0 ..< 3 {
			sums[s.indices[3 * t + k]][0] += tangent
			sums[s.indices[3 * t + k]][1] += bitangent
		}
	}
	s.vertex, s.uv = vertex[:], coords[:]
	s.tangents = make([][4]f32, len(sums), allocator)
	for sum, slot in sums {
		n := normals[s.vertex[slot]]
		t := linalg.normalize0(sum[0] - linalg.dot(sum[0], n) * n)
		if t == {} do t, _ = geom.perpendicular_pair(n)
		w: f32 = 1 if linalg.dot(linalg.cross(n, t), sum[1]) >= 0 else -1
		s.tangents[slot] = {t.x, t.y, t.z, w}
	}
	return
}

split_destroy :: proc(s: ^Split, allocator := context.allocator) {
	delete(s.vertex, allocator)
	delete(s.uv, allocator)
	delete(s.tangents, allocator)
	delete(s.indices, allocator)
	s^ = {}
}
