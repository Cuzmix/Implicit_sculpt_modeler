package geom

import "core:math/linalg"
import "core:slice"

import "../jobs"

// The polygons a mesh's triangles were cut from, for mesh_symmetrize to keep: polygon f's
// corners are corners[first[f]:first[f + 1]], in order round it, and tri_poly[t] is
// triangle t's polygon (sculpt.Polys, which need not keep a polygon's triangles
// together). All nil for a mesh of triangles only.
Polygons :: struct {
	first:    []u32,
	corners:  []u32,
	tri_poly: []u32,
}

// A polygon mesh's creased edges and corners, as sculpt.Sharp keeps them: edges[i] (the
// key lo << 32 | hi of its ends) has sharpness edge[i], verts[i] has corner sharpness
// vert[i], both sorted by key.
Creases :: struct {
	edges: []u64,
	edge:  []f32,
	verts: []u32,
	vert:  []f32,
}

creases_destroy :: proc(c: ^Creases, allocator := context.allocator) {
	delete(c.edges, allocator)
	delete(c.edge, allocator)
	delete(c.verts, allocator)
	delete(c.vert, allocator)
	c^ = {}
}

// What mesh_symmetrize made of the polygons it was given: one number a triangle of the
// result, a run of equal numbers one polygon's triangles (as Mesh_Part.polys keeps them,
// for mesh_polygons), and the creases on the result's vertices.
Symmetrized_Polygons :: struct {
	polys:   [dynamic]u32,
	creases: Creases,
}

symmetrized_polygons_destroy :: proc(s: ^Symmetrized_Polygons, allocator := context.allocator) {
	delete(s.polys)
	creases_destroy(&s.creases, allocator)
	s^ = {}
}

// Mirror and weld, as ZBrush's Mirror And Weld and Blender's Symmetrize do: the mesh is
// cut by the plane through the origin across `axis` (0 x, 1 y, 2 z), the half on the
// `keep_positive` side (or the other) is kept, and a mirror image of it replaces the
// other half, joined along the cut. A mesh with `polygons` keeps them whole where it can,
// as ZBrush does: it is welded along a seam of its own edges moved onto the plane
// (symmetrize_seam), so a quad mesh stays the same quads. Otherwise the cut goes polygon
// by polygon (each triangle its own polygon when there are none): a polygon wholly on
// the kept side keeps its own triangles, one the plane crosses is clipped to it and cut
// into a fan (a quad crossed through two opposite sides stays a quad), and one whose
// kept part falls in pieces is clipped triangle by triangle, each a polygon of its own.
// The points where edges meet the plane are worked out from each edge's ends in a fixed
// order, so the two polygons of an edge make the same point and it welds. The result is
// a closed mesh when the input is, with normals zero for the sculptor to compute. With
// `out_polygons` given, the result's polygons and the creases of `creases` that lie on
// the kept side and their mirror images go there (made with `allocator`). Returns ok
// false when nothing of the mesh is on the kept side.
mesh_symmetrize :: proc(m: Mesh, axis: int, keep_positive: bool, pool: ^jobs.Pool, allocator := context.allocator, polygons: Polygons = {}, creases: Creases = {}, out_polygons: ^Symmetrized_Polygons = nil) -> (out: Mesh, ok: bool) {
	assert(axis >= 0 && axis < 3)
	n := len(m.positions)
	side: f32 = 1 if keep_positive else -1
	triangles := len(m.indices) / 3
	has_polygons := polygons.first != nil
	assert(!has_polygons || len(polygons.tri_poly) == triangles, "one polygon a triangle")

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

	// Each polygon's triangles, in triangle order: tris[tri_first[f]:tri_first[f + 1]].
	polygon_count := len(polygons.first) - 1 if has_polygons else triangles
	tri_first, tris: []u32
	if has_polygons {
		tri_first = make([]u32, polygon_count + 1, context.temp_allocator)
		tris = make([]u32, triangles, context.temp_allocator)
		for f in polygons.tri_poly do tri_first[f + 1] += 1
		for f in 0 ..< polygon_count do tri_first[f + 1] += tri_first[f]
		at := slice.clone(tri_first[:polygon_count], context.temp_allocator)
		for f, t in polygons.tri_poly {
			tris[at[f]] = u32(t)
			at[f] += 1
		}
	}

	indices := make([dynamic]u32, 0, len(m.indices) + len(m.indices) / 8, allocator)
	// One number a kept triangle, a polygon's triangles one run.
	polys := make([dynamic]u32, 0, len(m.indices) / 3 if out_polygons != nil else 0, context.temp_allocator)
	next: u32
	// Where each cut edge met the plane, by the edge's key, for creases to follow onto
	// the part of a creased edge the cut keeps; nil without creases.
	cuts: map[u64]u32
	if out_polygons != nil && len(creases.edges) > 0 do cuts = make(map[u64]u32, 64, context.temp_allocator)
	cut :: proc(positions: ^[dynamic]Vec3, a, b: u32, axis: int, cuts: ^map[u64]u32) -> u32 {
		// From the lower-numbered end, so both polygons of the edge get the same bits.
		pa, pb := positions[min(a, b)], positions[max(a, b)]
		t := pa[axis] / (pa[axis] - pb[axis])
		p := pa + (pb - pa) * t
		p[axis] = 0
		append(positions, p)
		at := u32(len(positions) - 1)
		if cuts^ != nil do cuts[u64(min(a, b)) << 32 | u64(max(a, b))] = at
		return at
	}
	// Clips the loop of `corners` to the kept side, corner by corner in order, into
	// `loop`; false when what is kept is not one piece.
	clip :: proc(positions: ^[dynamic]Vec3, where_: []i8, corners: []u32, axis: int, loop: ^[dynamic]u32, cuts: ^map[u64]u32) -> bool {
		clear(loop)
		runs := 0
		count := len(corners)
		for c in 0 ..< count {
			a, b := corners[c], corners[(c + 1) % count]
			if where_[b] < 0 && where_[a] >= 0 do runs += 1
		}
		if runs != 1 do return false
		for c in 0 ..< count {
			a, b := corners[c], corners[(c + 1) % count]
			if where_[a] >= 0 do append(loop, a)
			if (where_[a] > 0 && where_[b] < 0) || (where_[a] < 0 && where_[b] > 0) do append(loop, cut(positions, a, b, axis, cuts))
		}
		return true
	}
	// Mirrors the kept half in place: every vertex off the plane gets a mirrored twin, the
	// plane's own are shared, and the mirrored triangles turn the other way to face
	// outward, each mirrored polygon numbered `next` on from its own.
	mirror :: proc(positions: ^[dynamic]Vec3, indices, polys: ^[dynamic]u32, next: u32, axis: int) -> (twin: []u32) {
		half := len(positions)
		twin = make([]u32, half, context.temp_allocator)
		for v in 0 ..< half {
			p := positions[v]
			if p[axis] == 0 {
				twin[v] = u32(v)
				continue
			}
			p[axis] = -p[axis]
			twin[v] = u32(len(positions))
			append(positions, p)
		}
		kept_indices := len(indices)
		for t := 0; t < kept_indices; t += 3 {
			append(indices, twin[indices[t]], twin[indices[t + 2]], twin[indices[t + 1]])
		}
		kept_polys := len(polys)
		for i in 0 ..< kept_polys do append(polys, polys[i] + next)
		return
	}

	// A polygon mesh is first tried along a seam of its own edges (symmetrize_seam), which
	// keeps every polygon whole; when that cannot be done cleanly, or leaves the mirror
	// open where the mesh was closed, the cut below is made instead.
	twin: []u32
	if has_polygons && symmetrize_seam(m, polygons, tris, tri_first, positions[:], where_, axis, side, &indices, &polys, &next, out_polygons != nil) {
		seam_twin := mirror(&positions, &indices, &polys, next, axis)
		if !mesh_edges_paired({indices = indices}, pool) && mesh_edges_paired(m, pool) {
			// Back to the plain cut: the half's own positions and sides again.
			resize(&positions, n)
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
				positions[v] = q
			}
			clear(&indices)
			clear(&polys)
			next = 0
		} else {
			twin = seam_twin
		}
	}
	if twin == nil {
		loop := make([dynamic]u32, 0, 8, context.temp_allocator)
		for f in 0 ..< polygon_count {
			corners := polygons.corners[polygons.first[f]:polygons.first[f + 1]] if has_polygons else m.indices[3 * f:][:3]
			kept, dropped := 0, 0
			for c in corners {
				if where_[c] > 0 do kept += 1
				if where_[c] < 0 do dropped += 1
			}
			if kept == 0 do continue // on the dropped side, or flat in the plane
			own := tris[tri_first[f]:tri_first[f + 1]] if has_polygons else []u32{u32(f)}
			if dropped == 0 {
				for t in own {
					append(&indices, ..m.indices[3 * t:][:3])
					if out_polygons != nil do append(&polys, next)
				}
				next += 1
				continue
			}
			if clip(&positions, where_, corners, axis, &loop, &cuts) {
				for k in 1 ..< len(loop) - 1 {
					append(&indices, loop[0], loop[k], loop[k + 1])
					if out_polygons != nil do append(&polys, next)
				}
				next += 1
				continue
			}
			// In pieces: each triangle clipped on its own, as a polygon of its own.
			for t in own {
				if !clip(&positions, where_, m.indices[3 * t:][:3], axis, &loop, &cuts) do continue
				for k in 1 ..< len(loop) - 1 {
					append(&indices, loop[0], loop[k], loop[k + 1])
					if out_polygons != nil do append(&polys, next)
				}
				next += 1
			}
		}
		if len(indices) == 0 {
			delete(positions)
			delete(indices)
			return {}, false
		}
		twin = mirror(&positions, &indices, &polys, next, axis)
	}

	out = Mesh{positions = positions, normals = make([dynamic]Vec3, len(positions), allocator), indices = indices}
	// Weld the cut points and drop what the dropped side used.
	remap: []u32
	if out_polygons != nil {
		out_polygons.polys = make([dynamic]u32, len(polys), allocator)
		copy(out_polygons.polys[:], polys[:])
		if creases.edges != nil || creases.verts != nil do remap = make([]u32, len(positions), context.temp_allocator)
	}
	if _, err := mesh_clean(&out, pool, polys = &out_polygons.polys if out_polygons != nil else nil, remap = remap); err != .None {
		mesh_destroy(&out)
		if out_polygons != nil do symmetrized_polygons_destroy(out_polygons, allocator)
		return {}, false
	}
	if remap != nil do out_polygons.creases = creases_mirrored(creases, where_, cuts, twin, remap, allocator)
	return out, true
}

// The creases of `c` on the kept side or the plane, an edge the cut crossed creased from
// its kept end to where it met the plane (`cuts`), and their mirror images, in the
// numbers of the welded result (each kept vertex v is remap[v], its twin remap[twin[v]]),
// sorted by key with each edge and corner once.
@(private = "file")
creases_mirrored :: proc(c: Creases, where_: []i8, cuts: map[u64]u32, twin, remap: []u32, allocator := context.allocator) -> (out: Creases) {
	Edge :: struct {
		key:   u64,
		sharp: f32,
	}
	Vert :: struct {
		v:     u32,
		sharp: f32,
	}
	edges := make([dynamic]Edge, 0, 2 * len(c.edges), context.temp_allocator)
	for key, i in c.edges {
		a, b := u32(key >> 32), u32(key & 0xffff_ffff)
		if int(a) >= len(where_) || int(b) >= len(where_) || where_[a] < 0 && where_[b] < 0 do continue
		if where_[a] < 0 || where_[b] < 0 {
			// Crossed by the plane: creased from the kept end to the cut, if it was cut.
			at, was_cut := cuts[key]
			if !was_cut do continue
			if where_[a] < 0 do a = at
			else do b = at
		}
		for pair in ([2][2]u32{{a, b}, {twin[a], twin[b]}}) {
			x, y := remap[pair[0]], remap[pair[1]]
			if x == max(u32) || y == max(u32) || x == y do continue
			append(&edges, Edge{u64(min(x, y)) << 32 | u64(max(x, y)), c.edge[i]})
		}
	}
	verts := make([dynamic]Vert, 0, 2 * len(c.verts), context.temp_allocator)
	for v, i in c.verts {
		if int(v) >= len(where_) || where_[v] < 0 do continue
		for w in ([2]u32{v, twin[v]}) {
			if x := remap[w]; x != max(u32) do append(&verts, Vert{x, c.vert[i]})
		}
	}
	slice.sort_by(edges[:], proc(x, y: Edge) -> bool {return x.key < y.key})
	slice.sort_by(verts[:], proc(x, y: Vert) -> bool {return x.v < y.v})
	ek := make([dynamic]u64, 0, len(edges), allocator)
	es := make([dynamic]f32, 0, len(edges), allocator)
	for e in edges {
		if len(ek) > 0 && ek[len(ek) - 1] == e.key do continue
		append(&ek, e.key)
		append(&es, e.sharp)
	}
	vk := make([dynamic]u32, 0, len(verts), allocator)
	vs := make([dynamic]f32, 0, len(verts), allocator)
	for v in verts {
		if len(vk) > 0 && vk[len(vk) - 1] == v.v do continue
		append(&vk, v.v)
		append(&vs, v.sharp)
	}
	out = {ek[:], es[:], vk[:], vs[:]}
	return
}

// How many rounds symmetrize_seam takes notches off its seam before it gives up: each
// round moves the seam a polygon at most, and a seam needing more is far from an edge loop.
@(private = "file")
SEAM_ROUNDS :: 8

// Mirror and weld along a seam of the mesh's own edges, as ZBrush's Mirror And Weld keeps
// a quad mesh's topology: the polygons whose middle is on the kept side are kept whole,
// and the vertices where they meet the dropped ones (the seam) move onto the plane, so
// the mirror image joins them edge for edge and no polygon is cut. A kept polygon with
// three or more corners on the seam (where the seam steps across a mesh's rows) is cut
// into a fan from a corner off it, so none of its triangles lies flat on the plane
// against its own mirror image. Then `positions` holds the moved seam, `where_` says
// which vertices the kept polygons use (0 those on the plane), and the kept polygons'
// triangles are in `indices`, numbered by polygon from `next` in `polys` when
// `numbered`. Refused, changing nothing, when that would spoil the mesh: a kept polygon
// with a corner on the dropped side off the seam (the plane runs far from an edge loop
// there), or a triangle turned over or flattened by the move.
@(private = "file")
symmetrize_seam :: proc(m: Mesh, polygons: Polygons, tris, tri_first: []u32, positions: []Vec3, where_: []i8, axis: int, side: f32, indices, polys: ^[dynamic]u32, next: ^u32, numbered: bool) -> bool {
	n := len(m.positions)
	count := len(polygons.first) - 1
	kept := make([]bool, count, context.temp_allocator)
	touch := make([]u8, n, context.temp_allocator) // 1 a kept polygon's corner, 2 a dropped one's
	for f in 0 ..< count {
		middle: f32
		for c in polygons.corners[polygons.first[f]:polygons.first[f + 1]] do middle += m.positions[c][axis]
		kept[f] = middle * side > 0
	}
	// A kept polygon with every corner on the seam (in a notch of it) would lie flat on
	// the plane, so it goes with the dropped side, which may notch another: a few rounds
	// settle it.
	for round in 0 ..= SEAM_ROUNDS {
		slice.zero(touch)
		any_kept := false
		for f in 0 ..< count {
			any_kept ||= kept[f]
			for c in polygons.corners[polygons.first[f]:polygons.first[f + 1]] do touch[c] |= 1 if kept[f] else 2
		}
		if !any_kept do return false
		notched := false
		for f in 0 ..< count {
			if !kept[f] do continue
			on_seam := 0
			corners := polygons.corners[polygons.first[f]:polygons.first[f + 1]]
			for c in corners do if touch[c] == 3 do on_seam += 1
			if on_seam == len(corners) {
				kept[f] = false
				notched = true
			}
		}
		if !notched do break
		if round == SEAM_ROUNDS do return false
	}
	place :: proc(positions: []Vec3, touch: []u8, v: u32, axis: int) -> Vec3 {
		p := positions[v]
		if touch[v] == 3 do p[axis] = 0
		return p
	}
	// The kept polygons' triangles after the move, a polygon's together; checked before
	// anything changes.
	out := make([dynamic]u32, 0, len(m.indices), context.temp_allocator)
	runs := make([dynamic]u32, 0, count, context.temp_allocator) // triangles a kept polygon
	for f in 0 ..< count {
		if !kept[f] do continue
		corners := polygons.corners[polygons.first[f]:polygons.first[f + 1]]
		on_seam, off := 0, -1
		for c, k in corners {
			if touch[c] == 3 {
				on_seam += 1
			} else {
				if where_[c] < 0 do return false
				if off < 0 do off = k
			}
		}
		// Which way the polygon faced before the move, from its own triangles.
		facing: Vec3
		own := tris[tri_first[f]:tri_first[f + 1]]
		for t in own {
			tri := m.indices[3 * t:][:3]
			facing += linalg.cross(positions[tri[1]] - positions[tri[0]], positions[tri[2]] - positions[tri[0]])
		}
		start := len(out)
		if on_seam >= 3 {
			// A fan from the corner off the seam: every triangle keeps that corner.
			for i in 1 ..< len(corners) - 1 {
				append(&out, corners[off], corners[(off + i) % len(corners)], corners[(off + i + 1) % len(corners)])
			}
		} else {
			for t in own do append(&out, ..m.indices[3 * t:][:3])
		}
		for k := start; k < len(out); k += 3 {
			a, b, c := place(positions, touch, out[k], axis), place(positions, touch, out[k + 1], axis), place(positions, touch, out[k + 2], axis)
			if linalg.dot(facing, linalg.cross(b - a, c - a)) <= 0 do return false
		}
		append(&runs, u32((len(out) - start) / 3))
	}
	for v in 0 ..< n {
		if touch[v] == 3 do positions[v][axis] = 0
		where_[v] = -1 if touch[v] & 1 == 0 else (0 if positions[v][axis] == 0 else 1)
	}
	append(indices, ..out[:])
	for run in runs {
		if numbered do for _ in 0 ..< run do append(polys, next^)
		next^ += 1
	}
	return true
}
