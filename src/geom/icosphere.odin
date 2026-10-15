package geom

import "core:math"
import "core:math/linalg"

import "../jobs"

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

// Frequency whose geodesic sphere has the vertex count closest to `vertices`.
geodesic_frequency_for :: proc(vertices: int) -> int {
	return max(1, int(math.round(math.sqrt(f64(max(vertices - 2, 10)) / 10))))
}

// Builds a unit geodesic sphere by splitting each icosahedron face into a triangular
// grid of `frequency` segments per edge, so any size can be produced directly (no
// repeated subdivision, no hash map). Vertex count is 10*f^2 + 2, triangles 20*f^2.
// Vertices shared by neighbouring faces get one global index via per-edge numbering.
// With a pool, the 20 faces are filled in parallel.
geodesic_sphere :: proc(frequency: int, pool: ^jobs.Pool = nil, allocator := context.allocator) -> Mesh {
	Sphere :: struct {
		n:       int,
		corners: [12]Vec3,
		faces:   [20][3]u32,
		edge_of: [12][12]i32, // corner pair -> edge number 1..30
		m:       Mesh,
	}
	t := f32((1 + math.sqrt(f64(5))) / 2)
	sp := Sphere {
		n = max(frequency, 1),
		corners = {
			{-1, t, 0}, {1, t, 0}, {-1, -t, 0}, {1, -t, 0},
			{0, -1, t}, {0, 1, t}, {0, -1, -t}, {0, 1, -t},
			{t, 0, -1}, {t, 0, 1}, {-t, 0, -1}, {-t, 0, 1},
		},
		faces = {
			{0, 11, 5}, {0, 5, 1}, {0, 1, 7}, {0, 7, 10}, {0, 10, 11},
			{1, 5, 9}, {5, 11, 4}, {11, 10, 2}, {10, 7, 6}, {7, 1, 8},
			{3, 9, 4}, {3, 4, 2}, {3, 2, 6}, {3, 6, 8}, {3, 8, 9},
			{4, 9, 5}, {2, 4, 11}, {6, 2, 10}, {8, 6, 7}, {9, 8, 1},
		},
	}
	n := sp.n
	vcount := 10 * n * n + 2
	sp.m = Mesh {
		positions = make([dynamic]Vec3, vcount, allocator),
		normals   = make([dynamic]Vec3, vcount, allocator),
		indices   = make([dynamic]u32, 60 * n * n, allocator),
	}

	// Corners, then the 30 edges: each owns n-1 vertices ordered from its lower corner.
	for c, i in sp.corners do sp.m.positions[i] = linalg.normalize(c)
	edge_count := 0
	for f in sp.faces {
		for k in 0 ..< 3 {
			a, b := f[k], f[(k + 1) % 3]
			if sp.edge_of[a][b] != 0 do continue
			edge_count += 1
			sp.edge_of[a][b], sp.edge_of[b][a] = i32(edge_count), i32(edge_count)
			lo, hi := min(a, b), max(a, b)
			for s in 1 ..< n {
				p := sp.corners[lo] + (sp.corners[hi] - sp.corners[lo]) * (f32(s) / f32(n))
				sp.m.positions[edge_base(i32(edge_count), n) + u32(s - 1)] = linalg.normalize(p)
			}
		}
	}
	assert(edge_count == 30)

	jobs.parallel_for(pool, len(sp.faces), &sp, proc(data: rawptr, fi: int) {
		sp := cast(^Sphere)data
		n := sp.n
		f := sp.faces[fi]
		a, b, c := sp.corners[f[0]], sp.corners[f[1]], sp.corners[f[2]]
		for j in 1 ..< n {
			for i in 1 ..< n - j {
				p := a + (b - a) * (f32(i) / f32(n)) + (c - a) * (f32(j) / f32(n))
				sp.m.positions[grid_vertex(sp.edge_of, f, fi, i, j, n)] = linalg.normalize(p)
			}
		}
		out := sp.m.indices[fi * 3 * n * n:]
		k := 0
		for j in 0 ..< n {
			for i in 0 ..< n - j {
				p00 := grid_vertex(sp.edge_of, f, fi, i, j, n)
				p10 := grid_vertex(sp.edge_of, f, fi, i + 1, j, n)
				p01 := grid_vertex(sp.edge_of, f, fi, i, j + 1, n)
				out[k], out[k + 1], out[k + 2] = p00, p10, p01
				k += 3
				if i + j < n - 1 {
					p11 := grid_vertex(sp.edge_of, f, fi, i + 1, j + 1, n)
					out[k], out[k + 1], out[k + 2] = p10, p11, p01
					k += 3
				}
			}
		}
	})
	copy(sp.m.normals[:], sp.m.positions[:])
	return sp.m
}

@(private)
edge_base :: #force_inline proc(edge: i32, n: int) -> u32 {
	return u32(12 + (int(edge) - 1) * (n - 1))
}

// Global index of grid point (i, j) of face fi with corners f: i steps from f[0]
// toward f[1], j from f[0] toward f[2]. Interior points are numbered row by row after
// all corner and edge vertices.
@(private)
grid_vertex :: #force_inline proc(edge_of: [12][12]i32, f: [3]u32, fi, i, j, n: int) -> u32 {
	on_edge :: #force_inline proc(edge_of: [12][12]i32, from, to: u32, k, n: int) -> u32 {
		e := edge_of[from][to]
		if from < to do return edge_base(e, n) + u32(k - 1)
		return edge_base(e, n) + u32(n - k - 1)
	}
	switch {
	case i == 0 && j == 0: return f[0]
	case i == n:           return f[1]
	case j == n:           return f[2]
	case j == 0:           return on_edge(edge_of, f[0], f[1], i, n)
	case i == 0:           return on_edge(edge_of, f[0], f[2], j, n)
	case i + j == n:       return on_edge(edge_of, f[1], f[2], j, n)
	}
	face_interior := (n - 1) * (n - 2) / 2
	row := (j - 1) * (n - 1) - (j - 1) * j / 2 // interior points in rows 1..j-1
	return u32(12 + 30 * (n - 1) + fi * face_interior + row + i - 1)
}
