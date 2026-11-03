package retopo

import "core:math/linalg"

import "../geom"
import "../jobs"
import "../quadmesh"

// AutoRemesher's extractor leaves a few faces with an odd number of sides (a triangle or a
// pentagon its own cleanups found no partner for), and one is enough to keep a result from
// being all quads, and so from its UVs. On a closed mesh such faces come in pairs (every
// edge is two sides), so each is joined to the nearest other one, or to the open border (a
// mirrored half's seam, whose image across the plane carries the path on to the face's
// own image), by a path through the quads between: a vertex goes in the middle of every
// edge the path crosses, so each end gains a side, and each quad on the way is cut in two
// (straight through) or three (round a corner, about a new middle vertex). An end of six
// or more sides is then cut into quads. The vertices the cuts made and the corners round
// them are relaxed a few times, each to the middle of its neighbours and back onto the
// surface, so the former triangle comes out a fair quad.

// How far a path may run, in faces: a longer one would draw a seam of halved quads across
// the model, which is worse than the odd face it mends.
ODD_PATH_MAX :: 24
// The relaxing rounds over the mended patch.
ODD_RELAX_ROUNDS :: 6

@(private = "file")
Edge_Faces :: struct {
	face:  [2]i32,
	count: i32,
}

@(private = "file")
Odd_Edit :: struct {
	positions: [dynamic]geom.Vec3,
	first:     [dynamic]u32,
	corners:   [dynamic]u32,
	gone:      [dynamic]bool, // replaced by its cuts, or dropped by the caller
	kept_out:  [dynamic]bool, // the caller's dropped faces, which stay in the output as they were
	planes:    ^[dynamic]u8,
	edges:     map[[2]u32]Edge_Faces,
}

@(private = "file")
edge_key :: proc(a, b: u32) -> [2]u32 {
	return {min(a, b), max(a, b)}
}

@(private = "file")
face_corners :: proc(e: ^Odd_Edit, f: i32) -> []u32 {
	return e.corners[e.first[f]:e.first[f + 1]]
}

@(private = "file")
edges_add :: proc(e: ^Odd_Edit, f: i32) {
	corners := face_corners(e, f)
	for c, k in corners {
		key := edge_key(c, corners[(k + 1) % len(corners)])
		at := e.edges[key] if key in e.edges else Edge_Faces{face = {-1, -1}}
		if at.count < 2 do at.face[at.count] = f
		at.count += 1
		e.edges[key] = at
	}
}

@(private = "file")
edges_remove :: proc(e: ^Odd_Edit, f: i32) {
	corners := face_corners(e, f)
	for c, k in corners {
		key := edge_key(c, corners[(k + 1) % len(corners)])
		at, ok := e.edges[key]
		if !ok do continue
		if at.face[0] == f {
			at.face[0] = at.face[1]
			at.face[1] = -1
		} else if at.face[1] == f {
			at.face[1] = -1
		}
		at.count -= 1
		if at.count <= 0 do delete_key(&e.edges, key)
		else do e.edges[key] = at
	}
}

@(private = "file")
face_add :: proc(e: ^Odd_Edit, corners: []u32) -> i32 {
	f := i32(len(e.first) - 1)
	append(&e.corners, ..corners)
	append(&e.first, u32(len(e.corners)))
	append(&e.gone, false)
	append(&e.kept_out, false)
	edges_add(e, f)
	return f
}

// The point of `surface` nearest to p, or p where there is no surface.
@(private = "file")
onto :: proc(surface: geom.Mesh, bvh: ^geom.Bvh, p: geom.Vec3, hint: ^u32) -> geom.Vec3 {
	if bvh == nil || len(surface.indices) == 0 do return p
	tri, bary, _, ok := geom.bvh_closest(bvh^, surface, p, max(f32), hint^)
	if !ok do return p
	hint^ = tri
	i := surface.indices[3 * tri:3 * tri + 3]
	return bary[0] * surface.positions[i[0]] + bary[1] * surface.positions[i[1]] + bary[2] * surface.positions[i[2]]
}

// Joins the faces of `m` with an odd number of sides in pairs, or to the open border, as
// the file's comment says. `dropped` (one per face, or empty) marks faces that count for
// nothing here (a mirrored half's caps, which the caller drops after): they stay as they
// are, out of every path, and their edges are border. `planes` (per vertex, or nil) is
// the seam's: a vertex put on a seam edge gets the planes both its ends share, and a seam
// vertex stays where it is. New vertices go onto `surface` through `bvh`, or through a
// tree built here when that is nil. Returns how many odd faces were mended and how many
// are left.
quad_fill_odd :: proc(m: ^quadmesh.Polygon_Mesh, dropped: ^[]bool, planes: ^[dynamic]u8, surface: geom.Mesh, bvh: ^geom.Bvh, pool: ^jobs.Pool) -> (mended, left: int) {
	faces := len(m.first) - 1
	odd_faces := make([dynamic]i32, context.temp_allocator)
	for f in 0 ..< faces {
		if dropped != nil && len(dropped^) == faces && dropped[f] do continue
		if (m.first[f + 1] - m.first[f]) % 2 == 1 do append(&odd_faces, i32(f))
	}
	if len(odd_faces) == 0 do return
	bvh := bvh
	own: geom.Bvh
	defer geom.bvh_destroy(&own)
	if bvh == nil && len(surface.indices) > 0 {
		own = geom.bvh_build_morton(surface, geom.BVH_LEAF_SIZE, pool)
		bvh = &own
	}

	e: Odd_Edit
	e.positions = make([dynamic]geom.Vec3, len(m.positions))
	copy(e.positions[:], m.positions)
	e.first = make([dynamic]u32, len(m.first))
	copy(e.first[:], m.first)
	e.corners = make([dynamic]u32, len(m.corners))
	copy(e.corners[:], m.corners)
	e.gone = make([dynamic]bool, faces)
	e.kept_out = make([dynamic]bool, faces)
	if dropped != nil && len(dropped^) == faces do copy(e.kept_out[:], dropped^)
	e.planes = planes
	e.edges = make(map[[2]u32]Edge_Faces, 2 * len(m.corners))
	defer delete(e.edges)
	for f in 0 ..< faces do if !e.kept_out[f] do edges_add(&e, i32(f))

	// The search's marks, kept over the whole run and cleared by the list of faces each
	// search reached.
	parent := make([dynamic]i32, faces, context.temp_allocator)
	via := make([dynamic][2]u32, faces, context.temp_allocator)
	hops := make([dynamic]i32, faces, context.temp_allocator)
	for &p in parent do p = -1
	reached := make([dynamic]i32, context.temp_allocator)
	queue := make([dynamic]i32, context.temp_allocator)
	path := make([dynamic]i32, context.temp_allocator)
	crossed := make([dynamic][2]u32, context.temp_allocator)
	touched := make([dynamic]u32, context.temp_allocator)
	hint := geom.BVH_NONE

	for s in odd_faces {
		if e.gone[s] || (e.first[s + 1] - e.first[s]) % 2 == 0 do continue
		// Breadth first over the quads from s, to the first odd face or border edge. The
		// marks grow with the faces the cuts added.
		for len(parent) < len(e.first) - 1 {
			append(&parent, -1)
			append(&via, [2]u32{})
			append(&hops, 0)
		}
		for f in reached do parent[f] = -1
		clear(&reached)
		clear(&queue)
		parent[s] = s
		hops[s] = 0
		append(&reached, s)
		append(&queue, s)
		end_face: i32 = -1
		end_edge: [2]u32
		end_border := false
		search: for head := 0; head < len(queue); head += 1 {
			f := queue[head]
			corners := face_corners(&e, f)
			for c, k in corners {
				key := edge_key(c, corners[(k + 1) % len(corners)])
				at := e.edges[key]
				if at.count == 1 {
					end_face, end_edge, end_border = f, key, true
					break search
				}
				if at.count != 2 do continue
				g := at.face[0] if at.face[0] != f else at.face[1]
				if g < 0 || parent[g] >= 0 do continue
				n := e.first[g + 1] - e.first[g]
				if n % 2 == 1 {
					parent[g] = f
					via[g] = key
					append(&reached, g)
					end_face, end_edge = g, key
					break search
				}
				if n != 4 || hops[f] + 1 > ODD_PATH_MAX do continue
				parent[g] = f
				via[g] = key
				hops[g] = hops[f] + 1
				append(&reached, g)
				append(&queue, g)
			}
		}
		if end_face < 0 do continue

		// The path from s to its end, and the edges it crosses in order.
		clear(&path)
		clear(&crossed)
		for f := end_face; ; f = parent[f] {
			append(&path, f)
			if f == s do break
			append(&crossed, via[f])
		}
		// Reverse both, so they run from s.
		for i, j := 0, len(path) - 1; i < j; i, j = i + 1, j - 1 do path[i], path[j] = path[j], path[i]
		for i, j := 0, len(crossed) - 1; i < j; i, j = i + 1, j - 1 do crossed[i], crossed[j] = crossed[j], crossed[i]
		if end_border do append(&crossed, end_edge)

		// A vertex in the middle of each crossed edge.
		middle := make(map[[2]u32]u32, len(crossed), context.temp_allocator)
		for key in crossed {
			v := u32(len(e.positions))
			a, b := e.positions[key[0]], e.positions[key[1]]
			on: u8
			if planes != nil do on = planes[key[0]] & planes[key[1]]
			p := (a + b) / 2
			if on == 0 do p = onto(surface, bvh, p, &hint)
			append(&e.positions, p)
			if planes != nil do append(planes, on)
			middle[key] = v
			append(&touched, v)
		}
		// Each face on the path with its new corners, cut into quads.
		for f in path {
			old := face_corners(&e, f)
			grown := make([dynamic]u32, 0, len(old) + 2, context.temp_allocator)
			inserted := make([dynamic]int, 0, 2, context.temp_allocator)
			for c, k in old {
				append(&grown, c)
				append(&touched, c)
				if v, ok := middle[edge_key(c, old[(k + 1) % len(old)])]; ok {
					append(&inserted, len(grown))
					append(&grown, v)
				}
			}
			edges_remove(&e, f)
			e.gone[f] = true
			cut_into_quads(&e, grown[:], inserted[:], surface, bvh, &hint, &touched)
		}
		mended += 2 if !end_border else 1
	}

	relax_patch(&e, touched[:], surface, bvh, &hint)

	// The faces that stand, in order: the caller's untouched ones first as they were, the
	// cuts after.
	first := make([dynamic]u32, 1, len(e.first))
	corners := make([dynamic]u32, 0, len(e.corners))
	out_dropped := make([dynamic]bool, 0, len(e.gone))
	for f in 0 ..< len(e.first) - 1 {
		if e.gone[f] do continue
		append(&corners, ..face_corners(&e, i32(f)))
		append(&first, u32(len(corners)))
		append(&out_dropped, e.kept_out[f])
	}
	for f in 0 ..< len(first) - 1 do if !out_dropped[f] && (first[f + 1] - first[f]) % 2 == 1 do left += 1
	delete(e.first)
	delete(e.corners)
	delete(e.gone)
	delete(e.kept_out)
	quadmesh.polygon_mesh_destroy(m)
	m^ = {e.positions[:], first[:], corners[:]}
	if dropped != nil {
		delete(dropped^)
		dropped^ = out_dropped[:]
	} else {
		delete(out_dropped)
	}
	return
}

// Cuts a face that gained corners (`inserted`, their places in `poly`) into quads: a quad
// stays; a quad with two new corners on opposite sides splits between them, on sides that
// meet goes round a new middle vertex in three; any other even face (an odd end that
// gained one) splits along its shortest diagonal while six-sided, or as a fan of quads
// from its new corner.
@(private = "file")
cut_into_quads :: proc(e: ^Odd_Edit, poly: []u32, inserted: []int, surface: geom.Mesh, bvh: ^geom.Bvh, hint: ^u32, touched: ^[dynamic]u32) {
	n := len(poly)
	at :: proc(poly: []u32, i: int) -> u32 {return poly[i %% len(poly)]}
	if n == 4 {
		face_add(e, poly)
		return
	}
	if n == 6 && len(inserted) == 2 {
		i, j := inserted[0], inserted[1]
		d := (j - i) %% 6
		if d == 3 {
			face_add(e, {at(poly, i), at(poly, i + 1), at(poly, i + 2), at(poly, i + 3)})
			face_add(e, {at(poly, i + 3), at(poly, i + 4), at(poly, i + 5), at(poly, i)})
			return
		}
		start := i if d == 2 else j
		middle: geom.Vec3
		for v in poly do middle += e.positions[v]
		middle /= f32(n)
		c := u32(len(e.positions))
		append(&e.positions, onto(surface, bvh, middle, hint))
		if e.planes != nil do append(e.planes, 0)
		append(touched, c)
		face_add(e, {at(poly, start), at(poly, start + 1), at(poly, start + 2), c})
		face_add(e, {at(poly, start + 2), at(poly, start + 3), at(poly, start + 4), c})
		face_add(e, {at(poly, start + 4), at(poly, start + 5), at(poly, start), c})
		return
	}
	if n == 6 {
		best, best_length := 0, max(f32)
		for k in 0 ..< 3 {
			length := linalg.length(e.positions[poly[k]] - e.positions[poly[k + 3]])
			if length < best_length do best, best_length = k, length
		}
		face_add(e, {at(poly, best), at(poly, best + 1), at(poly, best + 2), at(poly, best + 3)})
		face_add(e, {at(poly, best + 3), at(poly, best + 4), at(poly, best + 5), at(poly, best)})
		return
	}
	if n % 2 == 1 || n < 4 {
		// Not expected (a face gains one corner per crossing); kept as it is.
		face_add(e, poly)
		return
	}
	from := inserted[0] if len(inserted) > 0 else 0
	for k := 1; k + 2 < n; k += 2 {
		face_add(e, {at(poly, from), at(poly, from + k), at(poly, from + k + 1), at(poly, from + k + 2)})
	}
}

// Moves each of `vertices` (repeats allowed) that is not on the seam or the border to the
// middle of its edge neighbours and back onto the surface, ODD_RELAX_ROUNDS times.
@(private = "file")
relax_patch :: proc(e: ^Odd_Edit, vertices: []u32, surface: geom.Mesh, bvh: ^geom.Bvh, hint: ^u32) {
	if len(vertices) == 0 do return
	index := make(map[u32]int, len(vertices), context.temp_allocator)
	order := make([dynamic]u32, context.temp_allocator)
	for v in vertices {
		if v in index do continue
		if e.planes != nil && int(v) < len(e.planes) && e.planes[v] != 0 do continue
		index[v] = len(order)
		append(&order, v)
	}
	if len(order) == 0 do return
	// Each patch vertex's neighbours along the edges of the faces that stand, and whether
	// it lies on the border (an edge with one face), which keeps it still.
	neighbours := make([][dynamic]u32, len(order), context.temp_allocator)
	for &list in neighbours do list = make([dynamic]u32, context.temp_allocator)
	still := make([]bool, len(order), context.temp_allocator)
	for f in 0 ..< len(e.first) - 1 {
		if e.gone[f] || e.kept_out[f] do continue
		corners := face_corners(e, i32(f))
		for c, k in corners {
			i, ok := index[c]
			if !ok do continue
			for d in ([2]u32{corners[(k + 1) % len(corners)], corners[(k + len(corners) - 1) % len(corners)]}) {
				seen := false
				for x in neighbours[i] do if x == d do seen = true
				if !seen do append(&neighbours[i], d)
				if e.edges[edge_key(c, d)].count != 2 do still[i] = true
			}
		}
	}
	moved := make([]geom.Vec3, len(order), context.temp_allocator)
	for _ in 0 ..< ODD_RELAX_ROUNDS {
		for v, i in order {
			moved[i] = e.positions[v]
			if still[i] || len(neighbours[i]) < 3 do continue
			sum: geom.Vec3
			for d in neighbours[i] do sum += e.positions[d]
			moved[i] = onto(surface, bvh, sum / f32(len(neighbours[i])), hint)
		}
		for v, i in order do e.positions[v] = moved[i]
	}
}

// Doublets: a vertex only two polygons meet at, which then share both of its edges. The
// extractor leaves a few where its cells fold (the two quads lie over each other there,
// and their triangles meet back to back, which the check counts as edges of four faces),
// and a mirrored half leaves one wherever a quad has two edges along the seam (the quad
// and its image then share both). Each is dissolved: the vertex goes and the two polygons
// become one, the first's corners from the vertex's next round to its previous and the
// second's between, which for two quads is a quad (across the seam, a quad lying over
// it). A merge that would repeat a corner or leave fewer than three is not made. Rounds
// repeat while a merge leaves another doublet, at most DOUBLET_ROUNDS. `planes` (one per
// vertex, or nil) loses the dissolved vertices' entries as the positions do. Returns how
// many were dissolved.
DOUBLET_ROUNDS :: 4

dissolve_doublets :: proc(m: ^quadmesh.Polygon_Mesh, planes: ^[dynamic]u8) -> (dissolved: int) {
	for _ in 0 ..< DOUBLET_ROUNDS {
		n := len(m.positions)
		faces := len(m.first) - 1
		count := make([]u32, n, context.temp_allocator)
		for c in m.corners do count[c] += 1
		at := make([][2]i32, n, context.temp_allocator)
		for &a in at do a = {-1, -1}
		for f in 0 ..< faces {
			for c in m.corners[m.first[f]:m.first[f + 1]] do if count[c] == 2 {
				if at[c][0] < 0 do at[c][0] = i32(f)
				else do at[c][1] = i32(f)
			}
		}
		// The faces' corners as they become; a merged-away face is gone.
		polys := make([][dynamic]u32, faces, context.temp_allocator)
		for f in 0 ..< faces {
			polys[f] = make([dynamic]u32, 0, int(m.first[f + 1] - m.first[f]), context.temp_allocator)
			append(&polys[f], ..m.corners[m.first[f]:m.first[f + 1]])
		}
		gone := make([]bool, faces, context.temp_allocator)
		removed := make([]bool, n, context.temp_allocator)
		round := 0
		for v in 0 ..< n {
			f, g := at[v][0], at[v][1]
			if f < 0 || g < 0 || f == g || gone[f] || gone[g] do continue
			pf, pg := polys[f][:], polys[g][:]
			i, j := index_of(pf, u32(v)), index_of(pg, u32(v))
			if i < 0 || j < 0 do continue
			next_f, prev_f := pf[(i + 1) % len(pf)], pf[(i + len(pf) - 1) % len(pf)]
			next_g, prev_g := pg[(j + 1) % len(pg)], pg[(j + len(pg) - 1) % len(pg)]
			// Both edges shared, the second polygon running them the other way.
			if next_g != prev_f || prev_g != next_f do continue
			merged := make([dynamic]u32, 0, len(pf) + len(pg), context.temp_allocator)
			for k in 1 ..< len(pf) do append(&merged, pf[(i + k) % len(pf)])
			for k in 2 ..< len(pg) - 1 do append(&merged, pg[(j + k) % len(pg)])
			if len(merged) < 3 || repeats(merged[:]) do continue
			polys[f] = merged
			gone[g] = true
			removed[v] = true
			round += 1
		}
		if round == 0 do break
		dissolved += round
		// Compacted: the dissolved vertices go, the gone faces with them.
		remap := make([]u32, n, context.temp_allocator)
		positions := make([dynamic]geom.Vec3, 0, n)
		kept_planes: [dynamic]u8
		if planes != nil do kept_planes = make([dynamic]u8, 0, n)
		for v in 0 ..< n {
			if removed[v] do continue
			remap[v] = u32(len(positions))
			append(&positions, m.positions[v])
			if planes != nil && v < len(planes) do append(&kept_planes, planes[v])
		}
		first := make([dynamic]u32, 0, faces + 1)
		corners := make([dynamic]u32, 0, len(m.corners))
		append(&first, 0)
		for f in 0 ..< faces {
			if gone[f] do continue
			for c in polys[f] do append(&corners, remap[c])
			append(&first, u32(len(corners)))
		}
		quadmesh.polygon_mesh_destroy(m)
		m.positions, m.first, m.corners = positions[:], first[:], corners[:]
		if planes != nil {
			delete(planes^)
			planes^ = kept_planes
		}
	}
	return
}

@(private = "file")
index_of :: proc(s: []u32, x: u32) -> int {
	for y, i in s do if y == x do return i
	return -1
}

@(private = "file")
repeats :: proc(s: []u32) -> bool {
	for x, i in s do for y in s[i + 1:] do if x == y do return true
	return false
}
