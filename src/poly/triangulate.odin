package poly

import "core:math/linalg"

import "../geom"

// Cuts every face into triangles over the cage's own vertices, appending to `out` (its
// positions follow any already there, in the cage's order; normals are left to the caller) and the cage face of each triangle to `tri_face`. Triangles wind
// counter-clockwise seen from outside, as the face does. A quad is cut along its shorter
// diagonal, which keeps a bent quad's crease where the eye expects it; a larger face by
// ear clipping in the plane of its Newell normal, so concave polygons stay inside their
// outline, with a fan as the fallback for a face too bent to clip.
triangulate :: proc(m: ^Mesh, out: ^geom.Mesh, tri_face: ^[dynamic]u32) {
	base := u32(len(out.positions))
	append(&out.positions, ..m.positions[:])
	corners := make([dynamic]u32, context.temp_allocator)
	tris := make([dynamic][3]int, context.temp_allocator)
	for f in 0 ..< u32(len(m.face_he)) {
		face_verts(m, f, &corners)
		clear(&tris)
		face_triangles(m, f, corners[:], &tris)
		for t in tris {
			append(&out.indices, base + corners[t[0]], base + corners[t[1]], base + corners[t[2]])
			append(tri_face, f)
		}
	}
}

// The triangles of face f, whose corners are `corners`, as corner positions within it.
face_triangles :: proc(m: ^Mesh, f: u32, corners: []u32, out: ^[dynamic][3]int) {
	n := len(corners)
	switch n {
	case 3:
		append(out, [3]int{0, 1, 2})
		return
	case 4:
		p := m.positions
		d02 := linalg.length2(p[corners[2]] - p[corners[0]])
		d13 := linalg.length2(p[corners[3]] - p[corners[1]])
		if d13 < d02 {
			append(out, [3]int{1, 2, 3}, [3]int{1, 3, 0})
		} else {
			append(out, [3]int{0, 1, 2}, [3]int{0, 2, 3})
		}
		return
	}
	// Ear clipping in the face's plane: u and v span it, and the polygon runs
	// counter-clockwise in (u, v) because the normal is its Newell normal.
	normal := face_normal(m, f)
	u := linalg.normalize0(any_perpendicular(normal))
	v := linalg.cross(normal, u)
	flat := make([][2]f32, n, context.temp_allocator)
	for c, i in corners {
		p := m.positions[c]
		flat[i] = {linalg.dot(p, u), linalg.dot(p, v)}
	}
	left := make([dynamic]int, 0, n, context.temp_allocator)
	for i in 0 ..< n do append(&left, i)
	guard := 0
	for len(left) > 3 && guard < n * n {
		guard += 1
		cut := -1
		for k in 0 ..< len(left) {
			a := left[(k + len(left) - 1) % len(left)]
			b := left[k]
			c := left[(k + 1) % len(left)]
			if cross2(flat[a], flat[b], flat[c]) <= 0 do continue
			inside := false
			for o in left {
				if o == a || o == b || o == c do continue
				if in_triangle(flat[o], flat[a], flat[b], flat[c]) {
					inside = true
					break
				}
			}
			if !inside {
				cut = k
				break
			}
		}
		if cut < 0 do break
		k := cut
		append(out, [3]int{left[(k + len(left) - 1) % len(left)], left[k], left[(k + 1) % len(left)]})
		ordered_remove(&left, k)
	}
	// What is left (a triangle, or a polygon too bent to clip) is fanned from its first corner.
	for i in 1 ..< len(left) - 1 do append(out, [3]int{left[0], left[i], left[i + 1]})
}

// A vector at right angles to n (not unit length): n crossed with the axis it is least along.
any_perpendicular :: proc(n: Vec3) -> Vec3 {
	a := linalg.abs(n)
	axis := Vec3{1, 0, 0}
	if a.y <= a.x && a.y <= a.z do axis = {0, 1, 0}
	else if a.z <= a.x && a.z <= a.y do axis = {0, 0, 1}
	return linalg.cross(n, axis)
}

@(private = "file")
cross2 :: proc(a, b, c: [2]f32) -> f32 {
	return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
}

// Whether p lies inside or on the counter-clockwise triangle abc.
@(private = "file")
in_triangle :: proc(p, a, b, c: [2]f32) -> bool {
	return cross2(a, b, p) >= 0 && cross2(b, c, p) >= 0 && cross2(c, a, p) >= 0
}
