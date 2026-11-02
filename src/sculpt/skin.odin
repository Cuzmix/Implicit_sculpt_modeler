package sculpt

import "core:math/linalg"

import "../geom"
import "../jobs"

// Detail skin: heights on a fine grid of samples laid over every triangle of the mesh, so
// detail finer than the mesh holds costs a height a sample instead of polygons. A triangle
// with corners c0, c1, c2 carries the samples at the barycentric places (i, j) / S, where
// S is the skin's segments, i runs toward c1 and j toward c2. A sample's point is the
// triangle's flat point there plus its height along the mesh's interpolated normal.
//
// Samples on a mesh vertex are stored once per vertex, samples inside an edge once per
// edge and the rest once per triangle, so two triangles meeting at an edge read the same
// heights there and the skin has no seams. An edge is numbered by the lower numbered of
// its two triangles, as HD numbers them (hd_loop_step), so the edges of a node's
// contiguous triangles are contiguous too and a node owns its vertices' samples, its
// edges' samples and its triangles' samples alone.
//
// Where a sample sits on an edge or a vertex its point and normal are worked out from the
// edge's ends in the edge's own direction (or from the vertex), never from either
// triangle's corners, so both triangles get the same bits.
Skin :: struct {
	segments:   u32,
	vert_count: u32,
	edge_count: u32,
	tri_count:  u32,
	// Per triangle, the first edge it numbers; one more entry holds the edge count.
	edge_first: []u32,
	// Per triangle and corner c, the edge from corner c to the next: its id shifted left
	// by one, with the low bit set when the triangle runs it the other way from its owner.
	tri_edges:  [][3]u32,
	edges:      []Skin_Edge,
	// Heights along the normal in the mesh's units, by sample (skin_sample).
	heights:    []f16,
	// Each sample's normal, octahedral in two signed 16-bit halves, as the GPU reads it.
	normals:    [][2]i16,
	// Per node id, the nodes whose triangles share a vertex with its own (itself first):
	// a sample's normal reads the heights of every triangle at it, so a change in a node
	// reaches the normals of these. near[near_first[id]:near_first[id + 1]].
	near_first: []u32,
	near:       []u32,
	// Per node id: its samples' heights changed since the last sculptor_flush (skin_mark).
	stale:       []bool,
	stale_nodes: [dynamic]u32,
	// The sample ranges whose normals the last sculptor_flush recomputed, coalesced and
	// sorted, for uploading.
	ranges:      [dynamic]Skin_Range,
	// Per sample: Layer's height this stroke (and Draw's and Inflate's with Accumulate off),
	// as Sculptor.layer keeps them per vertex; nil until first used.
	layer:       []Layer_Height,
	// No height is further than this from zero: it only grows, and widens the reach a dab
	// tests a triangle against, since a raised sample can lie outside its triangle's box.
	height_max:  f32,
	// Smooth's targets, per sample of the hit nodes, each node's from offsets[hit index].
	smooth_to:   [dynamic]f32,
	offsets:     [dynamic]u32,
}

// A run of samples: [first, first + count), as a vertex range is, so the renderer takes
// both alike.
Skin_Range :: geom.Vertex_Range

// An edge's two triangles, its owner (the lower numbered) first, and the owner's corner
// the edge starts from, which sets the edge's direction.
Skin_Edge :: struct {
	tris:   [2]u32,
	corner: u32,
}

// The segments a skin may have: powers of two, so that Apply can build each as whole Loop
// levels, up to the most detail per triangle worth the memory (16 is 153 samples a
// triangle, before sharing).
SKIN_SEGMENTS_MIN :: 2
SKIN_SEGMENTS_MAX :: 16

// Builds a skin with flat heights over the sculptor's mesh. Refuses (false) a mesh with an
// open or non-manifold edge, since Apply could never subdivide it, or segments that are
// not a power of two in range.
@(require_results)
skin_make :: proc(s: ^Sculptor, segments: u32, allocator := context.allocator) -> (sk: Skin, ok: bool) {
	if segments < SKIN_SEGMENTS_MIN || segments > SKIN_SEGMENTS_MAX || segments & (segments - 1) != 0 do return {}, false
	if s.dyn != nil do return {}, false
	I := s.mesh.indices[:]
	tcount := len(I) / 3
	Build :: struct {
		s:          ^Sculptor,
		edge_first: []u32,
		tri_edges:  [][3]u32,
		edges:      []Skin_Edge,
		twins:      [][3]u32, // per corner: the triangle across its edge, or SKIN_NONE
		bad:        bool,
	}
	b := Build{s = s}
	b.twins = make([][3]u32, tcount, context.temp_allocator)
	b.edge_first = make([]u32, tcount + 1, allocator)
	jobs.parallel_ranges(s.pool, tcount, &b, proc(data: rawptr, lo, hi: int) {
		b := cast(^Build)data
		I := b.s.mesh.indices[:]
		for t in u32(lo) ..< u32(hi) {
			count: u32
			for c in u32(0) ..< 3 {
				twin, found := skin_twin(b.s, t, I[3 * t + c], I[3 * t + (c + 1) % 3])
				if found != 1 {
					// Written by several jobs, but only ever set to true.
					b.bad = true
					twin = SKIN_NONE
				}
				b.twins[t][c] = twin
				count += u32(t < twin)
			}
			b.edge_first[t + 1] = count
		}
	}, geom.RANGE_GRAIN)
	if b.bad {
		delete(b.edge_first, allocator)
		return {}, false
	}
	for t in 0 ..< tcount do b.edge_first[t + 1] += b.edge_first[t]
	ecount := b.edge_first[tcount]
	b.tri_edges = make([][3]u32, tcount, allocator)
	b.edges = make([]Skin_Edge, ecount, allocator)
	// Each triangle numbers its own edges and writes its twin's slot for them: a slot is
	// written by exactly one triangle, the edge's owner, so jobs never share one.
	jobs.parallel_ranges(s.pool, tcount, &b, proc(data: rawptr, lo, hi: int) {
		b := cast(^Build)data
		I := b.s.mesh.indices[:]
		for t in u32(lo) ..< u32(hi) {
			next := b.edge_first[t]
			for c in u32(0) ..< 3 {
				twin := b.twins[t][c]
				if twin < t do continue
				b.edges[next] = {tris = {t, twin}, corner = c}
				b.tri_edges[t][c] = next << 1
				b.tri_edges[twin][skin_corner_of(I, twin, I[3 * t + (c + 1) % 3])] = next << 1 | 1
				next += 1
			}
		}
	}, geom.RANGE_GRAIN)
	sk = Skin {
		segments   = segments,
		vert_count = u32(len(s.mesh.positions)),
		edge_count = ecount,
		tri_count  = u32(tcount),
		edge_first = b.edge_first,
		tri_edges  = b.tri_edges,
		edges      = b.edges,
	}
	n := skin_sample_count(&sk)
	sk.heights = make([]f16, n, allocator)
	sk.normals = make([][2]i16, n, allocator)
	sk.stale = make([]bool, len(s.nodes), allocator)
	sk.stale_nodes = make([dynamic]u32, 0, 64, allocator)
	sk.ranges = make([dynamic]Skin_Range, 0, 64, allocator)
	sk.smooth_to = make([dynamic]f32, 0, 0, allocator)
	sk.offsets = make([dynamic]u32, 0, 0, allocator)
	skin_near_build(s, &sk, allocator)
	skin_normals_all(s, &sk)
	return sk, true
}

skin_destroy :: proc(sk: ^Skin, allocator := context.allocator) {
	delete(sk.edge_first, allocator)
	delete(sk.tri_edges, allocator)
	delete(sk.edges, allocator)
	delete(sk.heights, allocator)
	delete(sk.normals, allocator)
	delete(sk.near_first, allocator)
	delete(sk.near, allocator)
	delete(sk.stale, allocator)
	delete(sk.stale_nodes)
	delete(sk.ranges)
	delete(sk.layer, allocator)
	delete(sk.smooth_to)
	delete(sk.offsets)
	sk^ = {}
}

// Marks an edge with no triangle across it.
SKIN_NONE :: max(u32)

// The other triangle on the edge v→w of triangle t, and how many there are (1 on a sound
// closed mesh).
@(private)
skin_twin :: proc(s: ^Sculptor, t, v, w: u32) -> (twin: u32, found: int) {
	twin = SKIN_NONE
	I := s.mesh.indices[:]
	for f in faces_of(s, v) {
		if f == t do continue
		a, b, c := I[3 * f], I[3 * f + 1], I[3 * f + 2]
		if a == w || b == w || c == w {
			twin = f
			found += 1
		}
	}
	return
}

@(private)
skin_corner_of :: #force_inline proc(I: []u32, t, v: u32) -> u32 {
	if I[3 * t] == v do return 0
	if I[3 * t + 1] == v do return 1
	return 2
}

// Samples inside a triangle, off its edges.
skin_face_samples :: #force_inline proc(sk: ^Skin) -> u32 {
	S := sk.segments
	return (S - 1) * (S - 2) / 2
}

skin_sample_count :: proc(sk: ^Skin) -> int {
	return int(sk.vert_count) + int(sk.edge_count) * int(sk.segments - 1) + int(sk.tri_count) * int(skin_face_samples(sk))
}

// Where in the sample arrays the sample at grid place (i, j) of triangle t lives, for
// 0 <= i, j and i + j <= segments.
skin_sample :: proc(sk: ^Skin, I: []u32, t, i, j: u32) -> u32 {
	S := sk.segments
	switch {
	case i == 0 && j == 0:
		return I[3 * t]
	case i == S:
		return I[3 * t + 1]
	case j == S:
		return I[3 * t + 2]
	case j == 0:
		return skin_edge_sample(sk, sk.tri_edges[t][0], i)
	case i + j == S:
		return skin_edge_sample(sk, sk.tri_edges[t][1], j)
	case i == 0:
		return skin_edge_sample(sk, sk.tri_edges[t][2], S - j)
	}
	// Inside: rows j = 1 .. S-2, each with i = 1 .. S-1-j.
	row := (j - 1) * (S - 2) - (j - 1) * (j - 2) / 2
	return sk.vert_count + sk.edge_count * (S - 1) + t * skin_face_samples(sk) + row + (i - 1)
}

// The sample k steps (1 .. segments-1) along an edge from the corner the triangle runs it
// from, by the edge reference tri_edges holds.
@(private)
skin_edge_sample :: #force_inline proc(sk: ^Skin, ref, k: u32) -> u32 {
	S := sk.segments
	along := k if ref & 1 == 0 else S - k
	return sk.vert_count + (ref >> 1) * (S - 1) + (along - 1)
}

// Where a sample is on the surface before its height: its flat point and the mesh's
// interpolated normal there (not unit length).
@(private)
skin_base :: proc(s: ^Sculptor, sk: ^Skin, t, i, j: u32) -> (p, n: Vec3) {
	I := s.mesh.indices[:]
	P := s.mesh.positions[:]
	N := s.mesh.normals[:]
	S := sk.segments
	edge_at :: #force_inline proc(s: ^Sculptor, sk: ^Skin, ref, k: u32) -> (p, n: Vec3) {
		e := sk.edges[ref >> 1]
		I := s.mesh.indices[:]
		a := I[3 * e.tris[0] + e.corner]
		b := I[3 * e.tris[0] + (e.corner + 1) % 3]
		along := k if ref & 1 == 0 else sk.segments - k
		f := f32(along) / f32(sk.segments)
		P := s.mesh.positions[:]
		N := s.mesh.normals[:]
		return P[a] + (P[b] - P[a]) * f, N[a] + (N[b] - N[a]) * f
	}
	switch {
	case i == 0 && j == 0:
		return P[I[3 * t]], N[I[3 * t]]
	case i == S:
		return P[I[3 * t + 1]], N[I[3 * t + 1]]
	case j == S:
		return P[I[3 * t + 2]], N[I[3 * t + 2]]
	case j == 0:
		return edge_at(s, sk, sk.tri_edges[t][0], i)
	case i + j == S:
		return edge_at(s, sk, sk.tri_edges[t][1], j)
	case i == 0:
		return edge_at(s, sk, sk.tri_edges[t][2], S - j)
	}
	b1, b2 := f32(i) / f32(S), f32(j) / f32(S)
	b0 := 1 - b1 - b2
	a, b, c := I[3 * t], I[3 * t + 1], I[3 * t + 2]
	return P[a] * b0 + P[b] * b1 + P[c] * b2, N[a] * b0 + N[b] * b1 + N[c] * b2
}

// The sample's point on the skin: its flat point raised by its height along the
// interpolated normal.
skin_point :: proc(s: ^Sculptor, sk: ^Skin, t, i, j: u32) -> Vec3 {
	_, q := skin_base_and_point(s, sk, t, i, j)
	return q
}

// The sample's flat point and its point on the skin, from one look-up of its base.
@(private)
skin_base_and_point :: #force_inline proc(s: ^Sculptor, sk: ^Skin, t, i, j: u32) -> (flat, point: Vec3) {
	p, n := skin_base(s, sk, t, i, j)
	h := f32(sk.heights[skin_sample(sk, s.mesh.indices[:], t, i, j)])
	return p, p + linalg.normalize0(n) * h
}

// Recomputes every sample's normal, in parallel by triangle ranges: each sample is written
// by the one triangle that owns it (vertex samples by the vertex's first triangle).
skin_normals_all :: proc(s: ^Sculptor, sk: ^Skin) {
	Job :: struct {
		s:  ^Sculptor,
		sk: ^Skin,
	}
	job := Job{s, sk}
	jobs.parallel_ranges(s.pool, int(sk.tri_count), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		for t in u32(lo) ..< u32(hi) do skin_triangle_normals(job.s, job.sk, t)
	}, 1 << 12)
}

// Writes the normals of the samples triangle t owns: its inside samples, the inside
// samples of the edges it owns, and its corners whose first triangle it is.
@(private)
skin_triangle_normals :: proc(s: ^Sculptor, sk: ^Skin, t: u32) {
	I := s.mesh.indices[:]
	S := sk.segments
	for j in u32(0) ..= S do for i in u32(0) ..= S - j {
		owned := false
		switch {
		case (i == 0 && j == 0) || i == S || j == S:
			v := I[3 * t] if i == 0 && j == 0 else (I[3 * t + 1] if i == S else I[3 * t + 2])
			owned = faces_of(s, v)[0] == t
		case j == 0:
			owned = sk.tri_edges[t][0] & 1 == 0 && sk.edges[sk.tri_edges[t][0] >> 1].tris[0] == t
		case i + j == S:
			owned = sk.tri_edges[t][1] & 1 == 0 && sk.edges[sk.tri_edges[t][1] >> 1].tris[0] == t
		case i == 0:
			owned = sk.tri_edges[t][2] & 1 == 0 && sk.edges[sk.tri_edges[t][2] >> 1].tris[0] == t
		case:
			owned = true
		}
		if !owned do continue
		sk.normals[skin_sample(sk, I, t, i, j)] = geom.oct_encode(skin_normal(s, sk, t, i, j))
	}
}

// A sample's normal: the mesh's interpolated normal turned as much as the skin turns the
// small triangles that meet at the sample, in every mesh triangle it lies on: the
// area-weighted mean, over those small triangles, of the unit normal of the raised small
// triangle minus the unit normal of the flat one, gathered in a fixed order so the result
// never depends on which triangle asks. Flat heights give the interpolated normal itself
// to the bit, a skin raised evenly over a curve keeps it, and any offset, along the normal
// or sideways, turns it by what the raised small triangles really do, so the same pass
// serves a skin that moves samples sideways.
skin_normal :: proc(s: ^Sculptor, sk: ^Skin, t, i, j: u32) -> Vec3 {
	_, n := skin_base(s, sk, t, i, j)
	n = linalg.normalize0(n)
	turn, area: Vec3 = {}, {}
	S := sk.segments
	I := s.mesh.indices[:]
	switch {
	case (i == 0 && j == 0) || i == S || j == S:
		v := I[3 * t] if i == 0 && j == 0 else (I[3 * t + 1] if i == S else I[3 * t + 2])
		for f in faces_of(s, v) {
			c := skin_corner_of(I, f, v)
			fi, fj: u32 = 0, 0
			if c == 1 do fi = S
			if c == 2 do fj = S
			skin_turn_at(s, sk, f, fi, fj, &turn, &area)
		}
	case j == 0 || i + j == S || i == 0:
		c: u32 = 0 if j == 0 else (1 if i + j == S else 2)
		k := i if c == 0 else (j if c == 1 else S - j)
		ref := sk.tri_edges[t][c]
		e := sk.edges[ref >> 1]
		along := k if ref & 1 == 0 else S - k
		for f in e.tris {
			// The same place on the edge, as triangle f numbers its grid.
			fc := e.corner if f == e.tris[0] else skin_corner_of(I, f, I[3 * e.tris[0] + (e.corner + 1) % 3])
			fk := along if f == e.tris[0] else S - along
			fi, fj := skin_edge_place(S, fc, fk)
			skin_turn_at(s, sk, f, fi, fj, &turn, &area)
		}
	case:
		skin_turn_at(s, sk, t, i, j, &turn, &area)
	}
	if area.x > 0 do n += turn / area.x
	return linalg.normalize0(n)
}

// The grid place k steps along the edge that starts at corner c of a triangle.
@(private)
skin_edge_place :: #force_inline proc(S, c, k: u32) -> (i, j: u32) {
	switch c {
	case 0:
		return k, 0
	case 1:
		return S - k, k
	}
	return 0, S - k
}

// Adds, for every small triangle of mesh triangle t that has a corner at grid place
// (i, j), the raised small triangle's unit normal minus the flat one's, weighted by the
// flat one's area, to `turn`, and the area to `area.x`.
@(private)
skin_turn_at :: proc(s: ^Sculptor, sk: ^Skin, t, i, j: u32, turn, area: ^Vec3) {
	S := int(sk.segments)
	ii, jj := int(i), int(j)
	small :: proc(s: ^Sculptor, sk: ^Skin, t: u32, a, b, c: [2]int, turn, area: ^Vec3) {
		pa, qa := skin_base_and_point(s, sk, t, u32(a.x), u32(a.y))
		pb, qb := skin_base_and_point(s, sk, t, u32(b.x), u32(b.y))
		pc, qc := skin_base_and_point(s, sk, t, u32(c.x), u32(c.y))
		flat := linalg.cross(pb - pa, pc - pa)
		twice := linalg.length(flat)
		if twice <= 0 do return
		raised := linalg.normalize0(linalg.cross(qb - qa, qc - qa))
		turn^ += (raised - flat / twice) * (twice * 0.5)
		area.x += twice * 0.5
	}
	up :: proc(S, i, j: int) -> bool {return i >= 0 && j >= 0 && i + j < S}
	down :: proc(S, i, j: int) -> bool {return i >= 0 && j >= 0 && i + j < S - 1}
	// The small triangles touching (i, j), always in this order.
	if up(S, ii, jj) do small(s, sk, t, {ii, jj}, {ii + 1, jj}, {ii, jj + 1}, turn, area)
	if up(S, ii - 1, jj) do small(s, sk, t, {ii - 1, jj}, {ii, jj}, {ii - 1, jj + 1}, turn, area)
	if up(S, ii, jj - 1) do small(s, sk, t, {ii, jj - 1}, {ii + 1, jj - 1}, {ii, jj}, turn, area)
	if down(S, ii - 1, jj) do small(s, sk, t, {ii, jj}, {ii, jj + 1}, {ii - 1, jj + 1}, turn, area)
	if down(S, ii - 1, jj - 1) do small(s, sk, t, {ii, jj - 1}, {ii, jj}, {ii - 1, jj}, turn, area)
	if down(S, ii, jj - 1) do small(s, sk, t, {ii + 1, jj - 1}, {ii + 1, jj}, {ii, jj}, turn, area)
}
