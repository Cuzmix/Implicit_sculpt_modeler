package geom

import "base:runtime"

import "../jobs"

// Mesh booleans, as ZBrush's DynaMesh booleans and Live Boolean's Make Boolean Mesh
// give: union, subtract and intersect of two closed meshes, made by the voxel remesh
// (remesh_run) classifying every lattice point as inside A, B, both or neither from one
// winding number, so any two closed meshes combine, overlapping or not, into one closed
// manifold surface. The voxels round the surface off at their size; then each vertex is
// put back onto the nearer of the two input surfaces along its normal when one is
// within a voxel, which brings back the inputs' detail and flat faces between the
// voxels, and leaves only the seam where they meet at voxel resolution.

// The `op` of `a` and `b` (in one space), with about `target` vertices, put back onto
// the inputs with `project`. ok is false when the result is empty (two parts that do
// not meet, intersected; everything subtracted).
mesh_boolean :: proc(a, b: Mesh, op: Remesh_Op, target: int, project := true, pool: ^jobs.Pool = nil, allocator := context.allocator) -> (out: Mesh, ok: bool) {
	both := mesh_join({a, b}, context.temp_allocator)
	area, bounds := mesh_area_bounds(both, pool)
	h, _ := remesh_lattice(area, bounds, target) or_return
	out = remesh_run(both, h, bounds, len(a.indices) / 3, op, pool, allocator) or_return
	if project {
		bvh := bvh_build_morton(both, BVH_LEAF_SIZE, pool, context.temp_allocator)
		mesh_project_onto(&out, both, &bvh, h, pool)
	}
	return out, true
}

// One mesh holding all of `parts` (their vertices and triangles one after another).
mesh_join :: proc(parts: []Mesh, allocator := context.allocator) -> (m: Mesh) {
	verts, indices := 0, 0
	for p in parts {
		verts += len(p.positions)
		indices += len(p.indices)
	}
	m.positions = make([dynamic]Vec3, 0, verts, allocator)
	m.normals = make([dynamic]Vec3, 0, verts, allocator)
	m.indices = make([dynamic]u32, 0, indices, allocator)
	for p in parts {
		base := u32(len(m.positions))
		append(&m.positions, ..p.positions[:])
		if len(p.normals) == len(p.positions) {
			append(&m.normals, ..p.normals[:])
		} else {
			resize(&m.normals, len(m.positions))
		}
		for i in p.indices do append(&m.indices, base + i)
	}
	return
}

// Moves each vertex of `m` onto `onto` (with `bvh` over its triangles) along the vertex
// normal, to the nearer hit either way when one is within `reach`, then recomputes
// the normals.
mesh_project_onto :: proc(m: ^Mesh, onto: Mesh, bvh: ^Bvh, reach: f32, pool: ^jobs.Pool) {
	next := make([]Vec3, len(m.positions), context.temp_allocator)
	_ = project_along_normals(m.positions[:], m.normals[:], onto, bvh, reach, pool, next, nil)
	copy(m.positions[:], next)
	mesh_recompute_normals(m)
}

// Where each point of `positions` lands on `onto` (with `bvh` over its triangles) along
// its normal: the nearer hit either way within `reach`, into `next`, and the triangle hit
// into `tris` when given (max(u32) for none). A point with a zero normal or no hit stays
// where it is. Returns how many found the surface.
project_along_normals :: proc(positions, normals: []Vec3, onto: Mesh, bvh: ^Bvh, reach: f32, pool: ^jobs.Pool, next: []Vec3, tris: []u32) -> int {
	Job :: struct {
		positions, normals: []Vec3,
		onto:               Mesh,
		bvh:                Bvh,
		reach:              f32,
		next:               []Vec3,
		tris:               []u32,
		hits:               []int, // per range
	}
	ranges := (len(positions) + RANGE_GRAIN - 1) / RANGE_GRAIN
	job := Job{positions, normals, onto, bvh^, reach, next, tris, make([]int, max(ranges, 1), context.temp_allocator)}
	jobs.parallel_ranges(pool, len(positions), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		stack := make([dynamic]u32, 0, 64, runtime.heap_allocator())
		defer delete(stack)
		hits := 0
		for v in lo ..< hi {
			p, n := job.positions[v], job.normals[v]
			job.next[v] = p
			if job.tris != nil do job.tris[v] = max(u32)
			if n == {} do continue
			// A direction with a zero part gives the box tests 0 × ∞ where the point lies
			// on a box's face, as points on a mirror plane do; a tiny part instead keeps
			// them exact.
			for &c in n do if c == 0 do c = 1e-9
			// Each ray starts a hair behind the point, so a point already on the surface
			// finds it.
			eps := 1e-3 * job.reach
			out_t, out_tri, out_hit := bvh_raycast_with(job.bvh, job.onto, p - eps * n, n, job.reach + eps, &stack)
			in_t, in_tri, in_hit := bvh_raycast_with(job.bvh, job.onto, p + eps * n, -n, job.reach + eps, &stack)
			out_t -= eps
			in_t -= eps
			switch {
			case out_hit && (!in_hit || out_t <= in_t):
				job.next[v] = p + out_t * n
				if job.tris != nil do job.tris[v] = out_tri
				hits += 1
			case in_hit:
				job.next[v] = p - in_t * n
				if job.tris != nil do job.tris[v] = in_tri
				hits += 1
			}
		}
		job.hits[lo / RANGE_GRAIN] += hits
	}, RANGE_GRAIN)
	total := 0
	for h in job.hits do total += h
	return total
}

// A shell made from the triangles of `m` that `keep` marks (one entry per vertex: a
// triangle is kept when all its corners are), as ZBrush's Extract makes one from the
// masked part: the part as it lies, facing in, and a copy moved `thickness` out along
// the normals, facing out, the two joined along the part's open edges by a band of
// quads, so the shell is closed where the part was a single piece. `smooth` rounds of
// smoothing even the outer copy's open edge first. Returns false when nothing is kept.
mesh_extract_shell :: proc(m: Mesh, keep: []bool, thickness: f32, smooth: int, allocator := context.allocator) -> (out: Mesh, ok: bool) {
	count := len(m.indices) / 3
	renumber := make([]u32, len(m.positions), context.temp_allocator)
	for &r in renumber do r = max(u32)
	positions := make([dynamic]Vec3, 0, 1024, context.temp_allocator)
	tris := make([dynamic]u32, 0, 3 * 1024, context.temp_allocator)
	for t in 0 ..< count {
		c := [3]u32{m.indices[3 * t], m.indices[3 * t + 1], m.indices[3 * t + 2]}
		if !keep[c[0]] || !keep[c[1]] || !keep[c[2]] do continue
		for v in c {
			if renumber[v] == max(u32) {
				renumber[v] = u32(len(positions))
				append(&positions, m.positions[v])
			}
			append(&tris, renumber[v])
		}
	}
	n := len(positions)
	if n == 0 do return {}, false
	part := Mesh{positions = positions, indices = tris, normals = make([dynamic]Vec3, n, context.temp_allocator)}
	mesh_recompute_normals(&part)

	// Open edges: those used once, in the direction their triangle runs them.
	uses := make(map[u64]i32, len(tris), context.temp_allocator)
	for t := 0; t < len(tris); t += 3 {
		for k in 0 ..< 3 {
			a, b := tris[t + k], tris[t + (k + 1) % 3]
			uses[u64(a) << 32 | u64(b)] += 1
		}
	}
	open := make([dynamic][2]u32, 0, 256, context.temp_allocator)
	on_edge := make([]bool, n, context.temp_allocator)
	for t := 0; t < len(tris); t += 3 {
		for k in 0 ..< 3 {
			a, b := tris[t + k], tris[t + (k + 1) % 3]
			if u64(b) << 32 | u64(a) in uses do continue
			append(&open, [2]u32{a, b})
			on_edge[a], on_edge[b] = true, true
		}
	}
	// The outer copy, its open edge smoothed along the edge so it does not keep the
	// mask's jagged outline.
	outer := make([]Vec3, n, context.temp_allocator)
	for p, v in positions do outer[v] = p + thickness * part.normals[v]
	if smooth > 0 && len(open) > 0 {
		along := make([][2]u32, n, context.temp_allocator)
		for &x in along do x = {max(u32), max(u32)}
		for e in open {
			along[e[0]][1] = e[1]
			along[e[1]][0] = e[0]
		}
		next := make([]Vec3, n, context.temp_allocator)
		for _ in 0 ..< smooth {
			copy(next, outer)
			for v in 0 ..< n {
				l := along[v]
				if !on_edge[v] || l[0] == max(u32) || l[1] == max(u32) do continue
				next[v] = 0.5 * outer[v] + 0.25 * (outer[l[0]] + outer[l[1]])
			}
			copy(outer, next)
		}
	}

	out.positions = make([dynamic]Vec3, 0, 2 * n, allocator)
	out.normals = make([dynamic]Vec3, 2 * n, allocator)
	out.indices = make([dynamic]u32, 0, 2 * len(tris) + 6 * len(open), allocator)
	append(&out.positions, ..positions[:])
	append(&out.positions, ..outer)
	N := u32(n)
	for t := 0; t < len(tris); t += 3 {
		// Inner: the part turned to face in. Outer: as it was, facing out.
		append(&out.indices, tris[t], tris[t + 2], tris[t + 1])
		append(&out.indices, tris[t] + N, tris[t + 1] + N, tris[t + 2] + N)
	}
	// Along each open edge a-b (run that way by its triangle on the outer copy), the
	// band's quad faces outward: a-b on the outer copy, then down to the inner.
	for e in open {
		a, b := e[0], e[1]
		append(&out.indices, b + N, a + N, a)
		append(&out.indices, b + N, a, b)
	}
	mesh_recompute_normals(&out)
	return out, true
}
