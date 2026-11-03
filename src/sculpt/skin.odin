package sculpt

import "base:runtime"
import "core:math"
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
	// The vector skin: per sample, a sideways offset in its owner triangle's frame
	// (skin_frame), in the mesh's units, for what a height can't hold (a pinch, an
	// overhang, a VDM stamp). nil until a sideways stroke first writes one (skin_side_fit),
	// so a skin nothing moved sideways costs nothing more.
	side:       [][2]f16,
	// Each sample's normal, octahedral in two signed 16-bit halves, as the GPU reads it.
	normals:    [][2]i16,
	// Per node id, the nodes whose triangles share a vertex with its own (itself first):
	// a sample's normal reads the heights of every triangle at it, so a change in a node
	// reaches the normals of these. near[near_first[id]:near_first[id + 1]].
	near_first: []u32,
	near:       []u32,
	// Per node id, how much of it changed since the last sculptor_flush: nothing, heights
	// inside the dab boxes only (skin_mark_dab), or anything (skin_mark).
	stale:       []Skin_Stale,
	stale_nodes: [dynamic]u32,
	// The reach of every dab since the last flush, as boxes (lo, hi) around their spheres:
	// a sample changed only inside one, so only the normals near them go stale.
	boxes:       [dynamic][2]Vec3,
	// Per vertex, edge and triangle: the flush recomputed its samples' normals, so their
	// ranges go up to the GPU; cleared as the ranges are listed.
	redo_vert:   []bool,
	redo_edge:   []bool,
	redo_tri:    []bool,
	// Per triangle, a sphere holding its flat corners: centre and radius, kept with the
	// mesh (skin_spheres_update), so dabs and the flush skip far triangles with one test.
	spheres:     [][4]f32,
	// No triangle sphere's radius is larger (it only grows).
	sphere_max:  f32,
	// Per node id, its triangles' mean edge length, near enough (skin_node_edge), which a
	// split dab measures its radius against (skin_mesh_share).
	node_edge:   []f32,
	// Per node id: its vertices moved under a split dab since the last flush, so only its
	// samples near the dab boxes need new normals, not all of them (skin_split_moved).
	dab_moved:   []bool,
	// A dab's work, in runs of a hit node's triangles (skin_dab), so a dab that hits only
	// a few nodes still keeps every thread busy.
	items:       [dynamic]Skin_Item,
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
	// And with a vector page, its offsets' targets alike.
	smooth_side: [dynamic][2]f32,
	offsets:     [dynamic]u32,
}

// One run of a dab's work: hit leaf `hit`'s triangles [tri_lo, tri_hi) with the edges
// they number, and with `verts` its node's vertex samples too; `moved` and `top` are what
// it changed (Partial's moved and weight_sum), summed per hit leaf afterwards.
Skin_Item :: struct {
	hit:            u32,
	tri_lo, tri_hi: u32,
	verts:          bool,
	moved:          u32,
	top:            f32,
}

// Triangles a run of a dab's work takes (Skin_Item): at 16 segments about 17k samples.
@(private)
SKIN_ITEM_TRIS :: 16

// How much of a node's skin went stale (Skin.stale).
Skin_Stale :: enum u8 {
	Fresh,
	Near_Dabs, // only heights inside Skin.boxes changed
	Whole,
}

// Above this many dab boxes before a flush, each new one joins the last.
@(private)
SKIN_BOXES_MAX :: 32

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
	sk.stale = make([]Skin_Stale, len(s.nodes), allocator)
	sk.stale_nodes = make([dynamic]u32, 0, 64, allocator)
	sk.boxes = make([dynamic][2]Vec3, 0, SKIN_BOXES_MAX, allocator)
	sk.items = make([dynamic]Skin_Item, 0, 64, allocator)
	sk.redo_vert = make([]bool, sk.vert_count, allocator)
	sk.redo_edge = make([]bool, sk.edge_count, allocator)
	sk.redo_tri = make([]bool, sk.tri_count, allocator)
	sk.spheres = make([][4]f32, sk.tri_count, allocator)
	sk.node_edge = make([]f32, len(s.nodes), allocator)
	sk.dab_moved = make([]bool, len(s.nodes), allocator)
	skin_spheres_all(s, &sk)
	sk.ranges = make([dynamic]Skin_Range, 0, 64, allocator)
	sk.smooth_to = make([dynamic]f32, 0, 0, allocator)
	sk.smooth_side = make([dynamic][2]f32, 0, 0, allocator)
	sk.offsets = make([dynamic]u32, 0, 0, allocator)
	skin_near_build(s, &sk, allocator)
	skin_normals_all(s, &sk, flat = true)
	return sk, true
}

skin_destroy :: proc(sk: ^Skin, allocator := context.allocator) {
	delete(sk.edge_first, allocator)
	delete(sk.tri_edges, allocator)
	delete(sk.edges, allocator)
	delete(sk.heights, allocator)
	delete(sk.side, allocator)
	delete(sk.normals, allocator)
	delete(sk.near_first, allocator)
	delete(sk.near, allocator)
	delete(sk.stale, allocator)
	delete(sk.stale_nodes)
	delete(sk.boxes)
	delete(sk.items)
	delete(sk.redo_vert, allocator)
	delete(sk.redo_edge, allocator)
	delete(sk.redo_tri, allocator)
	delete(sk.spheres, allocator)
	delete(sk.node_edge, allocator)
	delete(sk.dab_moved, allocator)
	delete(sk.ranges)
	delete(sk.layer, allocator)
	delete(sk.smooth_to)
	delete(sk.smooth_side)
	delete(sk.offsets)
	sk^ = {}
}

// Works out triangle t's sphere (Skin.spheres): the middle of its corners and the
// farthest corner's distance from it.
@(private)
skin_sphere :: #force_inline proc(s: ^Sculptor, sk: ^Skin, t: u32) {
	I := s.mesh.indices[:]
	P := s.mesh.positions[:]
	a, b, c := P[I[3 * t]], P[I[3 * t + 1]], P[I[3 * t + 2]]
	mid := (a + b + c) * (1.0 / 3)
	r := math.sqrt(max(linalg.length2(a - mid), linalg.length2(b - mid), linalg.length2(c - mid)))
	sk.spheres[t] = {mid.x, mid.y, mid.z, r}
}

// Works out every triangle's sphere, for a new skin or one undo brings back over a mesh
// that may have moved since.
@(private)
skin_spheres_all :: proc(s: ^Sculptor, sk: ^Skin) {
	Job :: struct {
		s:  ^Sculptor,
		sk: ^Skin,
	}
	job := Job{s, sk}
	jobs.parallel_ranges(s.pool, int(sk.tri_count), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		for t in u32(lo) ..< u32(hi) do skin_sphere(job.s, job.sk, t)
	}, geom.RANGE_GRAIN)
	for sp in sk.spheres do sk.sphere_max = max(sk.sphere_max, sp.w)
	for _, id in s.nodes do skin_node_edge(s, sk, u32(id))
}

// Node id's mean edge length from its triangles' spheres: a triangle's corners lie a
// radius from its middle at most, an edge of an even triangle √3 radii long.
@(private)
skin_node_edge :: proc(s: ^Sculptor, sk: ^Skin, id: u32) {
	n := s.nodes[id]
	sum: f32
	for t in n.tri_first ..< n.tri_first + n.tri_count do sum += sk.spheres[t].w
	sk.node_edge[id] = math.SQRT_THREE * sum / f32(max(n.tri_count, 1))
}

// Whether triangle t's sphere, widened by `widen`, comes within `reach` of `center`.
@(private)
skin_sphere_near :: #force_inline proc(sk: ^Skin, t: u32, center: Vec3, reach: f32) -> bool {
	sp := sk.spheres[t]
	r := reach + sp.w
	return linalg.length2(sp.xyz - center) <= r * r
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
	x := skin_sample(sk, s.mesh.indices[:], t, i, j)
	return p, p + skin_lift(s, sk, x, t, i, j, linalg.normalize0(n), f32(sk.heights[x]))
}

// How far sample x (at grid place (i, j) of triangle t, unit interpolated normal `nu`)
// lies from its flat point: its height along the normal, plus its sideways offset in its
// owner's frame when the skin has a vector page.
@(private)
skin_lift :: #force_inline proc(s: ^Sculptor, sk: ^Skin, x, t, i, j: u32, nu: Vec3, h: f32) -> Vec3 {
	off := nu * h
	if sk.side == nil do return off
	sd := sk.side[x]
	if sd == {} do return off
	tu, tv := skin_frame(s, sk, t, i, j, nu)
	return off + tu * f32(sd.x) + tv * f32(sd.y)
}

// The frame a sample's sideways offset is stored in: its owner triangle's first edge
// (corner 0 to corner 1) made perpendicular to the sample's unit interpolated normal `nu`,
// and the normal crossed with it. The owner is the triangle that writes the sample (a
// vertex's first triangle, an edge's lower one, or the triangle itself), so every
// triangle the sample lies on works out the same frame, to the bit, and the skin stays
// watertight; built from the owner's corners, it turns with the mesh, so what Grab or Pose
// bends carries its overhangs with it, as a tangent-space VDM does.
skin_frame :: proc(s: ^Sculptor, sk: ^Skin, t, i, j: u32, nu: Vec3) -> (tu, tv: Vec3) {
	I := s.mesh.indices[:]
	P := s.mesh.positions[:]
	o := skin_owner(s, sk, t, i, j)
	e := P[I[3 * o + 1]] - P[I[3 * o]]
	tu = linalg.normalize0(e - nu * linalg.dot(e, nu))
	return tu, linalg.cross(nu, tu)
}

// The triangle that owns the sample at grid place (i, j) of triangle t (skin_frame).
skin_owner :: #force_inline proc(s: ^Sculptor, sk: ^Skin, t, i, j: u32) -> u32 {
	I := s.mesh.indices[:]
	S := sk.segments
	switch {
	case i == 0 && j == 0: return faces_of(s, I[3 * t])[0]
	case i == S:           return faces_of(s, I[3 * t + 1])[0]
	case j == S:           return faces_of(s, I[3 * t + 2])[0]
	case j == 0:           return sk.edges[sk.tri_edges[t][0] >> 1].tris[0]
	case i + j == S:       return sk.edges[sk.tri_edges[t][1] >> 1].tris[0]
	case i == 0:           return sk.edges[sk.tri_edges[t][2] >> 1].tris[0]
	}
	return t
}

// Gives the skin its vector page (Skin.side), all zero, the first time a sideways stroke
// needs it.
skin_side_fit :: proc(sk: ^Skin, allocator: runtime.Allocator) {
	if len(sk.side) == len(sk.heights) do return
	delete(sk.side, allocator)
	sk.side = make([][2]f16, len(sk.heights), allocator)
}

// Recomputes every sample's normal, in parallel by triangle ranges: each sample is written
// by the one triangle that owns it (vertex samples by the vertex's first triangle).
// With `flat`, every height is zero, and each normal is the interpolated one: the same
// bits skin_normal gives then (each raised small triangle is its flat one, so the turn is
// zero), without the small triangles.
skin_normals_all :: proc(s: ^Sculptor, sk: ^Skin, flat := false) {
	Job :: struct {
		s:    ^Sculptor,
		sk:   ^Skin,
		flat: bool,
	}
	job := Job{s, sk, flat}
	jobs.parallel_ranges(s.pool, int(sk.tri_count), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		for t in u32(lo) ..< u32(hi) do skin_triangle_normals(job.s, job.sk, t, job.flat)
	}, 1 << 12)
}

// Writes the normals of the samples triangle t owns: its inside samples, the inside
// samples of the edges it owns, and its corners whose first triangle it is.
@(private)
skin_triangle_normals :: proc(s: ^Sculptor, sk: ^Skin, t: u32, flat := false) {
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
			// Inside samples go together below, unless flat.
			owned = flat
		}
		if !owned do continue
		n: Vec3
		if flat {
			_, n = skin_base(s, sk, t, i, j)
			n = linalg.normalize0(linalg.normalize0(n))
		} else {
			n = skin_normal(s, sk, t, i, j)
		}
		sk.normals[skin_sample(sk, I, t, i, j)] = geom.oct_encode(n)
	}
	if !flat do skin_grid_pass(s, sk, t, true, nil)
}

// The most grid places of a triangle (at SKIN_SEGMENTS_MAX), and of its small triangles.
@(private)
SKIN_PLACES_MAX :: (SKIN_SEGMENTS_MAX + 1) * (SKIN_SEGMENTS_MAX + 2) / 2
@(private)
SKIN_SMALL_MAX :: SKIN_SEGMENTS_MAX * SKIN_SEGMENTS_MAX

// One mesh triangle's part of a sample's normal: the turn and the area its small
// triangles at the sample add (skin_turn_at), summed from zero, so the same part comes
// from one look-up or from a grid pass.
@(private)
Skin_Partial :: struct {
	turn: Vec3,
	area: f32,
}

// Triangle t's part of the normal of the sample at its grid place (i, j).
@(private)
skin_partial :: proc(s: ^Sculptor, sk: ^Skin, t, i, j: u32) -> Skin_Partial {
	turn, area: Vec3
	skin_turn_at(s, sk, t, i, j, &turn, &area)
	return {turn, area.x}
}

// A sample's normal from its interpolated normal and the parts of every triangle it lies
// on, added in skin_normal's order.
@(private)
skin_normal_from :: #force_inline proc(base: Vec3, sum: Skin_Partial) -> Vec3 {
	n := linalg.normalize0(base)
	if sum.area > 0 do n += sum.turn / sum.area
	return linalg.normalize0(n)
}

// Where a place on a triangle's border lies in the parts skin_grid_pass writes: corner c's
// edge, k steps along it (skin_edge_place), so each corner is k = 0 of its own edge.
@(private)
skin_border_index :: #force_inline proc(S, c, k: u32) -> u32 {return c * S + k}

// One pass over triangle t's grid: each grid place's points and each small triangle's
// turn are worked out once instead of once for every sample they touch (about six times).
// With `inside`, writes the normals of its inside samples, as skin_normal gives them; with
// `border` (3 * segments long), writes its part of the normal at every place on its
// border (skin_border_index), as skin_partial gives it, for the vertex and edge samples
// it shares with its neighbours.
@(private)
skin_grid_pass :: proc(s: ^Sculptor, sk: ^Skin, t: u32, inside: bool, border: []Skin_Partial) {
	S := int(sk.segments)
	I := s.mesh.indices[:]
	// Grid place (i, j) at row j: j * (S + 1) - j * (j - 1) / 2 + i.
	place :: #force_inline proc(S, i, j: int) -> int {return j * (S + 1) - j * (j - 1) / 2 + i}
	flat, raised, base: [SKIN_PLACES_MAX]Vec3 = ---, ---, ---
	// The border's places through skin_base and skin_sample; the inside ones with their
	// sums written out here (the same sums, so the same bits), from the corners read once
	// and the triangle's own heights in order.
	P := s.mesh.positions[:]
	N := s.mesh.normals[:]
	ca, cb, cc := I[3 * t], I[3 * t + 1], I[3 * t + 2]
	pa, pb, pc := P[ca], P[cb], P[cc]
	na, nb, nc := N[ca], N[cb], N[cc]
	x := sk.vert_count + sk.edge_count * u32(S - 1) + t * skin_face_samples(sk)
	raised_any := false
	for j in 0 ..= S do for i in 0 ..= S - j {
		p, n: Vec3
		at: u32
		if i == 0 || j == 0 || i + j == S {
			p, n = skin_base(s, sk, t, u32(i), u32(j))
			at = skin_sample(sk, I, t, u32(i), u32(j))
		} else {
			b1, b2 := f32(i) / f32(S), f32(j) / f32(S)
			b0 := 1 - b1 - b2
			p, n = pa * b0 + pb * b1 + pc * b2, na * b0 + nb * b1 + nc * b2
			at = x
			x += 1
		}
		h := f32(sk.heights[at])
		k := place(S, i, j)
		lifted := sk.side != nil && sk.side[at] != {}
		raise := skin_lift(s, sk, at, t, u32(i), u32(j), linalg.normalize0(n), h) if lifted else linalg.normalize0(n) * h
		flat[k], raised[k], base[k] = p, p + raise, n
		raised_any ||= h != 0 || lifted
	}
	// The small triangle "up" at (i, j) has corners (i, j), (i+1, j), (i, j+1) and "down"
	// at (i, j) has (i+1, j), (i+1, j+1), (i, j+1), in the order skin_turn_at takes them.
	// Only the ones that exist are written, and only those are read.
	Small :: struct {
		turn: Vec3,
		half: f32,
		ok:   bool,
	}
	up, down: [SKIN_SMALL_MAX]Small = ---, ---
	small :: #force_inline proc(flat, raised: []Vec3, a, b, c: int) -> (out: Small) {
		out.turn, out.half, out.ok = skin_small_turn(flat[a], raised[a], flat[b], raised[b], flat[c], raised[c])
		return
	}
	// With no height in the triangle every raised small triangle is its flat one, and
	// skin_small_turn's turn is exactly zero (its two unit normals are the same division),
	// so only the areas are worked out: the same bits for less, as most of a skin under a
	// stroke that moves the mesh is often still flat.
	flat_small :: #force_inline proc(flat: []Vec3, a, b, c: int) -> (out: Small) {
		twice := linalg.length(linalg.cross(flat[b] - flat[a], flat[c] - flat[a]))
		if twice <= 0 do return
		return {half = twice * 0.5, ok = true}
	}
	if raised_any {
		for j in 0 ..< S do for i in 0 ..< S - j {
			up[j * S + i] = small(flat[:], raised[:], place(S, i, j), place(S, i + 1, j), place(S, i, j + 1))
			if i + j < S - 1 do down[j * S + i] = small(flat[:], raised[:], place(S, i + 1, j), place(S, i + 1, j + 1), place(S, i, j + 1))
		}
	} else {
		for j in 0 ..< S do for i in 0 ..< S - j {
			up[j * S + i] = flat_small(flat[:], place(S, i, j), place(S, i + 1, j), place(S, i, j + 1))
			if i + j < S - 1 do down[j * S + i] = flat_small(flat[:], place(S, i + 1, j), place(S, i + 1, j + 1), place(S, i, j + 1))
		}
	}
	// skin_turn_at's order and conditions: up at (i, j), (i-1, j), (i, j-1), then down at
	// (i-1, j), (i-1, j-1), (i, j-1), each where it exists.
	part :: #force_inline proc(up, down: []Small, S, i, j: int) -> (p: Skin_Partial) {
		add :: #force_inline proc(p: ^Skin_Partial, sm: Small) {
			if !sm.ok do return
			p.turn += sm.turn
			p.area += sm.half
		}
		if i + j < S do add(&p, up[j * S + i])
		if i >= 1 do add(&p, up[j * S + i - 1])
		if j >= 1 do add(&p, up[(j - 1) * S + i])
		if i >= 1 && i - 1 + j < S - 1 do add(&p, down[j * S + i - 1])
		if i >= 1 && j >= 1 do add(&p, down[(j - 1) * S + i - 1])
		if j >= 1 && i + j - 1 < S - 1 do add(&p, down[(j - 1) * S + i])
		return
	}
	if inside && S >= 3 {
		x = sk.vert_count + sk.edge_count * u32(S - 1) + t * skin_face_samples(sk)
		for j in 1 ..= S - 2 do for i in 1 ..= S - 1 - j {
			sk.normals[x] = geom.oct_encode(skin_normal_from(base[place(S, i, j)], part(up[:], down[:], S, i, j)))
			x += 1
		}
	}
	if border != nil {
		for c in u32(0) ..< 3 do for k in u32(0) ..< u32(S) {
			i, j := skin_edge_place(u32(S), c, k)
			border[skin_border_index(u32(S), c, k)] = part(up[:], down[:], S, int(i), int(j))
		}
	}
}

// One small triangle's part of a normal (skin_turn_at): the raised triangle's unit normal
// minus the flat one's, times the flat one's area, and that area; not ok for a flat
// triangle of no area.
@(private)
skin_small_turn :: #force_inline proc(pa, qa, pb, qb, pc, qc: Vec3) -> (turn: Vec3, half: f32, ok: bool) {
	flat := linalg.cross(pb - pa, pc - pa)
	twice := linalg.length(flat)
	if twice <= 0 do return
	raised := linalg.normalize0(linalg.cross(qb - qa, qc - qa))
	return (raised - flat / twice) * (twice * 0.5), twice * 0.5, true
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
	sum: Skin_Partial
	S := sk.segments
	I := s.mesh.indices[:]
	// Each triangle's part is summed from zero and the parts added in this order, so a grid
	// pass's parts (skin_grid_pass) give the same bits.
	add :: #force_inline proc(sum: ^Skin_Partial, p: Skin_Partial) {
		sum.turn += p.turn
		sum.area += p.area
	}
	switch {
	case (i == 0 && j == 0) || i == S || j == S:
		v := I[3 * t] if i == 0 && j == 0 else (I[3 * t + 1] if i == S else I[3 * t + 2])
		for f in faces_of(s, v) {
			c := skin_corner_of(I, f, v)
			fi, fj: u32 = 0, 0
			if c == 1 do fi = S
			if c == 2 do fj = S
			add(&sum, skin_partial(s, sk, f, fi, fj))
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
			add(&sum, skin_partial(s, sk, f, fi, fj))
		}
	case:
		sum = skin_partial(s, sk, t, i, j)
	}
	return skin_normal_from(n, sum)
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
		dt, half, ok := skin_small_turn(pa, qa, pb, qb, pc, qc)
		if !ok do return
		turn^ += dt
		area.x += half
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
