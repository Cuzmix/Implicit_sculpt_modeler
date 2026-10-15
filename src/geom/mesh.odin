// Package geom owns the CPU-side sculpt geometry. It has no knowledge of
// rendering or UI; other packages read from it and upload what changed.
package geom

import "core:math/linalg"

Vec3 :: [3]f32

// Triangle mesh stored as parallel arrays (structure of arrays), so passes that
// touch only positions or only normals stream through contiguous memory.
// The mesh owns all three arrays; free them with mesh_destroy.
Mesh :: struct {
	positions: [dynamic]Vec3,
	normals:   [dynamic]Vec3,
	indices:   [dynamic]u32, // 3 per triangle, counter-clockwise when viewed from outside
}

// A run of consecutive vertices, e.g. the part of a mesh that changed.
Vertex_Range :: struct {
	first: u32,
	count: u32,
}

mesh_destroy :: proc(m: ^Mesh) {
	delete(m.positions)
	delete(m.normals)
	delete(m.indices)
	m^ = {}
}

mesh_vertex_count :: proc(m: Mesh) -> int {
	return len(m.positions)
}

mesh_triangle_count :: proc(m: Mesh) -> int {
	return len(m.indices) / 3
}

// Recomputes every vertex normal as the area-weighted sum of adjacent face normals.
mesh_recompute_normals :: proc(m: ^Mesh) {
	for &n in m.normals {
		n = {}
	}
	for t := 0; t < len(m.indices); t += 3 {
		i0, i1, i2 := m.indices[t], m.indices[t + 1], m.indices[t + 2]
		p0, p1, p2 := m.positions[i0], m.positions[i1], m.positions[i2]
		// Unnormalized cross product: length is twice the triangle area.
		fn := linalg.cross(p1 - p0, p2 - p0)
		m.normals[i0] += fn
		m.normals[i1] += fn
		m.normals[i2] += fn
	}
	for &n in m.normals {
		n = linalg.normalize0(n)
	}
}
