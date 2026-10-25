package geom

import "core:math"

Vec2 :: [2]f32

import "../jobs"

// Starting shapes besides the sphere, each closed, wound outward and about as big as the
// unit sphere, with zero normals for the sculptor to compute.
Primitive :: enum u8 {
	Sphere,
	Cube,
	Cylinder,
	Cone,
	Torus,
}

// Builds `shape` with about `vertices` vertices. The cube and torus are grids, so their
// triangles line up with their edges; the cylinder and cone are turned faceted outlines
// voxel remeshed to the count, which gives even triangles across the caps and rims.
primitive :: proc(shape: Primitive, vertices: int, pool: ^jobs.Pool, allocator := context.allocator) -> (m: Mesh, ok: bool) {
	switch shape {
	case .Sphere:
		return geodesic_sphere(geodesic_frequency_for(vertices), pool, allocator), true
	case .Cube:
		// 6 n² + 2 vertices.
		n := max(1, int(math.round(math.sqrt(f64(max(vertices - 2, 6)) / 6))))
		return cube_grid(n, 0.8, pool, allocator)
	case .Torus:
		// The tube's rings and the turns around it in the radii's ratio, so the
		// triangles are about square on the outside.
		major, minor: f32 = 0.75, 0.3
		around_tube := max(3, int(math.round(math.sqrt(f64(vertices) * f64(minor / major)))))
		around_axis := max(3, int(math.round(f64(vertices) / f64(around_tube))))
		return torus_grid(around_axis, around_tube, major, minor, allocator), true
	case .Cylinder, .Cone:
		top: f32 = 0.7 if shape == .Cylinder else 0
		outline := lathe({{0, -0.8}, {0.7, -0.8}, {top, 0.8}, {0, 0.8}} if top > 0 else {{0, -0.8}, {0.8, -0.8}, {0, 0.8}}, 512, context.temp_allocator)
		return remesh_voxel(outline, vertices, pool, allocator)
	}
	return {}, false
}

// A cube from -half to half on each axis, each face an n × n grid of squares cut in two.
cube_grid :: proc(n: int, half: f32, pool: ^jobs.Pool, allocator := context.allocator) -> (m: Mesh, ok: bool) {
	assert(n >= 1)
	// One coordinate table, made symmetric, so the faces meeting at an edge compute its
	// points to the same bits and weld.
	at := make([]f32, n + 1, context.temp_allocator)
	for i in 0 ..= n do at[i] = -1 + 2 * f32(i) / f32(n)
	for i in 0 ..= n / 2 do at[n - i] = -at[i]
	// Each face's normal and the grid's two directions, with u × v = normal.
	Face :: struct {
		normal, u, v: Vec3,
	}
	faces := [6]Face {
		{{1, 0, 0}, {0, 0, -1}, {0, 1, 0}},
		{{-1, 0, 0}, {0, 0, 1}, {0, 1, 0}},
		{{0, 1, 0}, {1, 0, 0}, {0, 0, -1}},
		{{0, -1, 0}, {1, 0, 0}, {0, 0, 1}},
		{{0, 0, 1}, {1, 0, 0}, {0, 1, 0}},
		{{0, 0, -1}, {-1, 0, 0}, {0, 1, 0}},
	}
	side := n + 1
	m.positions = make([dynamic]Vec3, 0, 6 * side * side, allocator)
	m.indices = make([dynamic]u32, 0, 36 * n * n, allocator)
	for f in faces {
		first := u32(len(m.positions))
		for j in 0 ..= n {
			for i in 0 ..= n {
				p := half * (f.normal + f.u * at[i] + f.v * at[j])
				for &c in p do if c == 0 do c = 0 // no -0, which would not weld with +0
				append(&m.positions, p)
			}
		}
		for j in 0 ..< n {
			for i in 0 ..< n {
				a := first + u32(j * side + i)
				b, c, d := a + 1, a + 1 + u32(side), a + u32(side)
				append(&m.indices, a, b, c, a, c, d)
			}
		}
	}
	m.normals = make([dynamic]Vec3, len(m.positions), allocator)
	if _, err := mesh_clean(&m, pool); err != .None {
		mesh_destroy(&m)
		return {}, false
	}
	return m, true
}

// A ring around the y axis `major` from it, of a tube `minor` thick: around_axis rings
// of around_tube vertices each.
torus_grid :: proc(around_axis, around_tube: int, major, minor: f32, allocator := context.allocator) -> Mesh {
	assert(around_axis >= 3 && around_tube >= 3)
	m: Mesh
	m.positions = make([dynamic]Vec3, 0, around_axis * around_tube, allocator)
	m.indices = make([dynamic]u32, 0, 6 * around_axis * around_tube, allocator)
	for i in 0 ..< around_axis {
		u := 2 * math.PI * f32(i) / f32(around_axis)
		for j in 0 ..< around_tube {
			v := 2 * math.PI * f32(j) / f32(around_tube)
			r := major + minor * math.cos(v)
			append(&m.positions, Vec3{r * math.cos(u), minor * math.sin(v), r * math.sin(u)})
		}
	}
	for i in 0 ..< around_axis {
		for j in 0 ..< around_tube {
			a := u32(i * around_tube + j)
			b := u32(((i + 1) % around_axis) * around_tube + j)
			c := u32(((i + 1) % around_axis) * around_tube + (j + 1) % around_tube)
			d := u32(i * around_tube + (j + 1) % around_tube)
			append(&m.indices, a, d, c, a, c, b)
		}
	}
	m.normals = make([dynamic]Vec3, len(m.positions), allocator)
	return m
}

// Turns an outline about the y axis: `profile` is (radius, height) from the bottom pole
// to the top pole, both on the axis, and each point between becomes a ring of
// `segments` vertices.
lathe :: proc(profile: []Vec2, segments: int, allocator := context.allocator) -> Mesh {
	assert(len(profile) >= 3 && segments >= 3)
	assert(profile[0].x == 0 && profile[len(profile) - 1].x == 0)
	rings := len(profile) - 2
	m: Mesh
	m.positions = make([dynamic]Vec3, 0, rings * segments + 2, allocator)
	m.indices = make([dynamic]u32, 0, 6 * segments * rings, allocator)
	append(&m.positions, Vec3{0, profile[0].y, 0})
	for k in 1 ..= rings {
		for s in 0 ..< segments {
			a := 2 * math.PI * f32(s) / f32(segments)
			append(&m.positions, Vec3{profile[k].x * math.cos(a), profile[k].y, profile[k].x * math.sin(a)})
		}
	}
	top := u32(len(m.positions))
	append(&m.positions, Vec3{0, profile[len(profile) - 1].y, 0})
	ring :: proc(k, s, segments: int) -> u32 {return u32(1 + (k - 1) * segments + s % segments)}
	for s in 0 ..< segments {
		append(&m.indices, 0, ring(1, s, segments), ring(1, s + 1, segments))
		for k in 1 ..< rings {
			a, b := ring(k, s, segments), ring(k, s + 1, segments)
			c, d := ring(k + 1, s + 1, segments), ring(k + 1, s, segments)
			append(&m.indices, a, d, c, a, c, b)
		}
		append(&m.indices, top, ring(rings, s + 1, segments), ring(rings, s, segments))
	}
	m.normals = make([dynamic]Vec3, len(m.positions), allocator)
	return m
}
