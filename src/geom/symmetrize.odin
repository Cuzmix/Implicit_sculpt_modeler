package geom

import "../jobs"

// Mirror and weld, as ZBrush's Mirror And Weld and Blender's Symmetrize do: the mesh is
// cut by the plane through the origin across `axis` (0 x, 1 y, 2 z), the half on the
// `keep_positive` side (or the other) is kept, and a mirror image of it replaces the
// other half, joined along the cut. Triangles that cross the plane are clipped to it;
// the points where their edges meet the plane are worked out from each edge's ends in a
// fixed order, so the two triangles of an edge make the same point and it welds. The
// result is a closed mesh when the input is, with normals zero for the sculptor to
// compute. Returns ok false when nothing of the mesh is on the kept side.
mesh_symmetrize :: proc(m: Mesh, axis: int, keep_positive: bool, pool: ^jobs.Pool, allocator := context.allocator) -> (out: Mesh, ok: bool) {
	assert(axis >= 0 && axis < 3)
	n := len(m.positions)
	side: f32 = 1 if keep_positive else -1

	// Vertices this close to the plane go onto it, so a cut never makes a sliver
	// between a vertex and the plane.
	lo, hi := Vec3{max(f32), max(f32), max(f32)}, Vec3{min(f32), min(f32), min(f32)}
	for p in m.positions {
		lo, hi = {min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)}, {max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)}
	}
	extent := max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
	snap := max(extent * 1e-5, 1e-30)

	positions := make([dynamic]Vec3, 0, n + n / 8, allocator)
	// The kept vertices first, in order; the snapped ones lie on the plane with +0 so
	// they hash like the cut points (mesh_clean welds by bits).
	where_ := make([]i8, n, context.temp_allocator) // -1 dropped side, 0 on the plane, 1 kept side
	for p, v in m.positions {
		q := p
		d := q[axis] * side
		switch {
		case abs(d) <= snap:
			q[axis] = 0
			where_[v] = 0
		case d > 0:
			where_[v] = 1
		case:
			where_[v] = -1
		}
		append(&positions, q)
	}

	indices := make([dynamic]u32, 0, len(m.indices) + len(m.indices) / 8, allocator)
	cut :: proc(positions: ^[dynamic]Vec3, a, b: u32, axis: int) -> u32 {
		// From the lower-numbered end, so both triangles of the edge get the same bits.
		pa, pb := positions[min(a, b)], positions[max(a, b)]
		t := pa[axis] / (pa[axis] - pb[axis])
		p := pa + (pb - pa) * t
		p[axis] = 0
		append(positions, p)
		return u32(len(positions) - 1)
	}
	for t := 0; t < len(m.indices); t += 3 {
		tri := [3]u32{m.indices[t], m.indices[t + 1], m.indices[t + 2]}
		kept, dropped := 0, 0
		for c in tri {
			if where_[c] > 0 do kept += 1
			if where_[c] < 0 do dropped += 1
		}
		if kept == 0 do continue // on the dropped side, or flat in the plane
		if dropped == 0 {
			append(&indices, tri[0], tri[1], tri[2])
			continue
		}
		// Clip the triangle to the kept side, corner by corner in order, then fan it.
		poly: [4]u32
		count := 0
		for c in 0 ..< 3 {
			a, b := tri[c], tri[(c + 1) % 3]
			if where_[a] >= 0 {
				poly[count] = a
				count += 1
			}
			if (where_[a] > 0 && where_[b] < 0) || (where_[a] < 0 && where_[b] > 0) {
				poly[count] = cut(&positions, a, b, axis)
				count += 1
			}
		}
		for k in 1 ..< count - 1 do append(&indices, poly[0], poly[k], poly[k + 1])
	}
	if len(indices) == 0 {
		delete(positions)
		delete(indices)
		return {}, false
	}

	// The mirror image: every vertex off the plane gets a mirrored twin, the plane's
	// own are shared, and the mirrored triangles turn the other way to face outward.
	half := len(positions)
	twin := make([]u32, half, context.temp_allocator)
	for v in 0 ..< half {
		p := positions[v]
		if p[axis] == 0 {
			twin[v] = u32(v)
			continue
		}
		p[axis] = -p[axis]
		twin[v] = u32(len(positions))
		append(&positions, p)
	}
	kept_indices := len(indices)
	for t := 0; t < kept_indices; t += 3 {
		append(&indices, twin[indices[t]], twin[indices[t + 2]], twin[indices[t + 1]])
	}

	out = Mesh{positions = positions, normals = make([dynamic]Vec3, len(positions), allocator), indices = indices}
	// Weld the cut points and drop what the dropped side used.
	if _, err := mesh_clean(&out, pool); err != .None {
		mesh_destroy(&out)
		return {}, false
	}
	return out, true
}
