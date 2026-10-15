// Package sculpt applies brush strokes to a geom.Mesh. It knows nothing about the GPU
// or the UI: callers pass rays and brush settings in, and read back which vertex
// range changed so they can upload just that.
package sculpt

import "core:math"
import "core:math/linalg"

import "../geom"

Vec3 :: geom.Vec3

Brush_Kind :: enum {
	Draw,   // push the surface out along the local average normal (inverted pulls in)
	Smooth, // move vertices toward the average of their neighbours
}

Brush :: struct {
	kind:     Brush_Kind,
	radius:   f32, // world units
	strength: f32, // 0..1
	invert:   bool,
}

// Working state for sculpting one mesh. All scratch buffers are allocated once and
// reused, so applying a dab does not allocate once they have grown to fit.
Sculptor :: struct {
	mesh:      ^geom.Mesh,
	faces:     geom.Vertex_Faces,
	bvh:       geom.Bvh,
	candidates: [dynamic]u32, // triangles from the BVH query, then refit list
	touched:   [dynamic]u32, // vertices moved by the current dab
	weights:   [dynamic]f32, // falloff weight per touched vertex
	affected:  [dynamic]u32, // vertices whose normal must be recomputed
	stamp:     []u32,        // per-vertex marker used to deduplicate `affected`
	stamp_id:  u32,
	tri_stamp: []u32,        // per-triangle marker: face_n is current for this dab
	face_n:    []Vec3,       // unnormalized face normals, valid where tri_stamp matches
	smooth_to: [dynamic]Vec3,

	// Union of vertex indices changed since the last call to sculptor_take_dirty.
	dirty_lo:  u32,
	dirty_hi:  u32, // exclusive; dirty_lo >= dirty_hi means clean
}

sculptor_init :: proc(s: ^Sculptor, mesh: ^geom.Mesh, allocator := context.allocator) {
	s.mesh = mesh
	s.faces = geom.vertex_faces_build(mesh^, allocator)
	s.bvh = geom.bvh_build(mesh^, allocator)
	s.candidates = make([dynamic]u32, 0, 8192, allocator)
	s.stamp = make([]u32, len(mesh.positions), allocator)
	s.tri_stamp = make([]u32, len(mesh.indices) / 3, allocator)
	s.face_n = make([]Vec3, len(mesh.indices) / 3, allocator)
	s.touched = make([dynamic]u32, 0, 4096, allocator)
	s.weights = make([dynamic]f32, 0, 4096, allocator)
	s.affected = make([dynamic]u32, 0, 8192, allocator)
	s.smooth_to = make([dynamic]Vec3, 0, 4096, allocator)
	s.dirty_lo, s.dirty_hi = max(u32), 0
}

sculptor_destroy :: proc(s: ^Sculptor) {
	geom.vertex_faces_destroy(&s.faces)
	geom.bvh_destroy(&s.bvh)
	delete(s.candidates)
	delete(s.stamp)
	delete(s.tri_stamp)
	delete(s.face_n)
	delete(s.touched)
	delete(s.weights)
	delete(s.affected)
	delete(s.smooth_to)
	s^ = {}
}

// Returns and clears the changed vertex range as (first, count).
sculptor_take_dirty :: proc(s: ^Sculptor) -> (first, count: u32) {
	if s.dirty_lo >= s.dirty_hi do return 0, 0
	first, count = s.dirty_lo, s.dirty_hi - s.dirty_lo
	s.dirty_lo, s.dirty_hi = max(u32), 0
	return
}

// Smooth bump: 1 at the centre, 0 at the rim, zero slope at both ends.
falloff :: #force_inline proc(x: f32) -> f32 {
	if x >= 1 do return 0
	t := 1 - x * x
	return t * t
}

// Applies one dab centred on `center`. Returns how many vertices moved.
apply_dab :: proc(s: ^Sculptor, brush: Brush, center: Vec3) -> int {
	m := s.mesh
	clear(&s.touched)
	clear(&s.weights)

	// Gather vertices inside the brush: the BVH narrows the search to triangles near
	// the sphere, then each of their vertices is tested once.
	r2 := brush.radius * brush.radius
	inv_r := 1 / brush.radius
	clear(&s.candidates)
	geom.bvh_query_sphere(&s.bvh, center, brush.radius, &s.candidates)
	stamp := next_stamp(s)
	for tri in s.candidates {
		for c in 0 ..< u32(3) {
			v := m.indices[3 * tri + c]
			if s.stamp[v] == stamp do continue
			s.stamp[v] = stamp
			d := m.positions[v] - center
			d2 := linalg.dot(d, d)
			if d2 < r2 {
				append(&s.touched, v)
				append(&s.weights, falloff(math.sqrt(d2) * inv_r))
			}
		}
	}
	if len(s.touched) == 0 do return 0

	switch brush.kind {
	case .Draw:
		area_normal: Vec3
		for v, k in s.touched {
			area_normal += m.normals[v] * s.weights[k]
		}
		area_normal = linalg.normalize0(area_normal)
		amount := brush.radius * brush.strength * 0.1
		if brush.invert do amount = -amount
		for v, k in s.touched {
			m.positions[v] += area_normal * (amount * s.weights[k])
		}
	case .Smooth:
		// Jacobi step: compute every target first so results do not depend on order.
		resize(&s.smooth_to, len(s.touched))
		for v, k in s.touched {
			sum: Vec3
			n: f32
			for f in geom.vertex_faces_of(s.faces, v) {
				sum += m.positions[m.indices[3 * f]] + m.positions[m.indices[3 * f + 1]] + m.positions[m.indices[3 * f + 2]]
				n += 3
			}
			s.smooth_to[k] = sum / n
		}
		for v, k in s.touched {
			t := clamp(brush.strength * s.weights[k], 0, 1)
			m.positions[v] = linalg.lerp(m.positions[v], s.smooth_to[k], t)
		}
	}

	update_normals_around_touched(s)
	return len(s.touched)
}

// Recomputes normals for every vertex sharing a triangle with a moved vertex, refits
// the BVH over the moved triangles, and widens the dirty range. Each face normal is
// computed once per dab and shared by the vertices around it.
@(private)
update_normals_around_touched :: proc(s: ^Sculptor) {
	m := s.mesh
	stamp := next_stamp(s)
	clear(&s.affected)
	clear(&s.candidates) // reused as the list of triangles that moved
	for v in s.touched {
		for f in geom.vertex_faces_of(s.faces, v) {
			if s.tri_stamp[f] == stamp do continue
			s.tri_stamp[f] = stamp
			s.face_n[f] = face_normal(m^, f)
			append(&s.candidates, f)
			for c in 0 ..< u32(3) {
				w := m.indices[3 * f + c]
				if s.stamp[w] != stamp {
					s.stamp[w] = stamp
					append(&s.affected, w)
				}
			}
		}
	}
	geom.bvh_refit_triangles(&s.bvh, m^, s.candidates[:])

	lo, hi := s.dirty_lo, s.dirty_hi
	for v in s.affected {
		n: Vec3
		for f in geom.vertex_faces_of(s.faces, v) {
			// Faces on the rim of the region did not move but still need a normal.
			if s.tri_stamp[f] != stamp {
				s.tri_stamp[f] = stamp
				s.face_n[f] = face_normal(m^, f)
			}
			n += s.face_n[f]
		}
		m.normals[v] = linalg.normalize0(n)
		lo = min(lo, v)
		hi = max(hi, v + 1)
	}
	s.dirty_lo, s.dirty_hi = lo, hi
}

// Unnormalized: its length is twice the triangle area, which area-weights vertex normals.
@(private)
face_normal :: #force_inline proc(m: geom.Mesh, f: u32) -> Vec3 {
	p0 := m.positions[m.indices[3 * f]]
	p1 := m.positions[m.indices[3 * f + 1]]
	p2 := m.positions[m.indices[3 * f + 2]]
	return linalg.cross(p1 - p0, p2 - p0)
}

@(private)
next_stamp :: proc(s: ^Sculptor) -> u32 {
	s.stamp_id += 1
	if s.stamp_id == 0 { 	// wrapped: reset markers
		for &x in s.stamp do x = 0
		for &x in s.tri_stamp do x = 0
		s.stamp_id = 1
	}
	return s.stamp_id
}

// Closest intersection of a ray with the sculpted mesh, using the BVH.
sculptor_raycast :: proc(s: ^Sculptor, origin, dir: Vec3) -> (hit: Vec3, ok: bool) {
	t: f32
	t, _, ok = geom.bvh_raycast(&s.bvh, s.mesh^, origin, dir)
	if ok do hit = origin + dir * t
	return
}

// Brute-force reference for sculptor_raycast: tests every triangle. Kept for tests.
raycast :: proc(m: geom.Mesh, origin, dir: Vec3) -> (hit: Vec3, ok: bool) {
	best := max(f32)
	for tri in 0 ..< u32(len(m.indices) / 3) {
		if d, h := geom.ray_triangle(m, tri, origin, dir); h && d < best {
			best, ok = d, true
		}
	}
	if ok do hit = origin + dir * best
	return
}
