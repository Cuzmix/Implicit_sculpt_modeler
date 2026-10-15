package geom

import "core:math"
import "core:math/linalg"

// Builds a unit-radius icosphere by repeatedly splitting each triangle into four.
// Vertex count is 10*4^subdivisions + 2; triangle count is 20*4^subdivisions.
// The returned mesh is allocated with `allocator`; scratch uses the temp allocator.
icosphere :: proc(subdivisions: int, radius: f32 = 1, allocator := context.allocator) -> Mesh {
	t := f32((1 + math.sqrt(f64(5))) / 2)
	base_positions := [12]Vec3 {
		{-1, t, 0}, {1, t, 0}, {-1, -t, 0}, {1, -t, 0},
		{0, -1, t}, {0, 1, t}, {0, -1, -t}, {0, 1, -t},
		{t, 0, -1}, {t, 0, 1}, {-t, 0, -1}, {-t, 0, 1},
	}
	base_indices := [60]u32 {
		0, 11, 5,  0, 5, 1,   0, 1, 7,    0, 7, 10,  0, 10, 11,
		1, 5, 9,   5, 11, 4,  11, 10, 2,  10, 7, 6,  7, 1, 8,
		3, 9, 4,   3, 4, 2,   3, 2, 6,    3, 6, 8,   3, 8, 9,
		4, 9, 5,   2, 4, 11,  6, 2, 10,   8, 6, 7,   9, 8, 1,
	}

	final_vertices := 10 * (1 << uint(2 * subdivisions)) + 2
	final_triangles := 20 * (1 << uint(2 * subdivisions))

	m := Mesh {
		positions = make([dynamic]Vec3, 0, final_vertices, allocator),
		normals   = make([dynamic]Vec3, 0, final_vertices, allocator),
		indices   = make([dynamic]u32, 0, final_triangles * 3, allocator),
	}
	for p in base_positions {
		append(&m.positions, linalg.normalize(p))
	}
	append(&m.indices, ..base_indices[:])

	scratch := make([dynamic]u32, 0, final_triangles * 3, context.temp_allocator)
	midpoints := make(map[u64]u32, final_vertices, context.temp_allocator)

	for _ in 0 ..< subdivisions {
		clear(&scratch)
		clear(&midpoints)
		for tri := 0; tri < len(m.indices); tri += 3 {
			a, b, c := m.indices[tri], m.indices[tri + 1], m.indices[tri + 2]
			ab := midpoint(&m, &midpoints, a, b)
			bc := midpoint(&m, &midpoints, b, c)
			ca := midpoint(&m, &midpoints, c, a)
			append(&scratch, a, ab, ca, b, bc, ab, c, ca, bc, ab, bc, ca)
		}
		clear(&m.indices)
		append(&m.indices, ..scratch[:])
	}

	// On a sphere the normal is the normalized position, so no face pass is needed.
	resize(&m.normals, len(m.positions))
	for p, i in m.positions {
		m.normals[i] = p
	}
	if radius != 1 {
		for &p in m.positions {
			p *= radius
		}
	}
	return m
}

@(private)
midpoint :: proc(m: ^Mesh, cache: ^map[u64]u32, a, b: u32) -> u32 {
	lo, hi := min(a, b), max(a, b)
	key := u64(lo) << 32 | u64(hi)
	if idx, ok := cache[key]; ok {
		return idx
	}
	idx := u32(len(m.positions))
	append(&m.positions, linalg.normalize((m.positions[a] + m.positions[b]) * 0.5))
	cache[key] = idx
	return idx
}
