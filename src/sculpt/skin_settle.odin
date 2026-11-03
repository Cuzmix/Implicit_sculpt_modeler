package sculpt

import "core:math/linalg"
import "core:slice"

import "../geom"
import "../jobs"

// Settle (K2 of the detail skin): at the end of a stroke that wrote into the skin, the
// large, smooth part of what the skin holds at each mesh vertex moves into the vertex,
// and every sample around it is measured again from the moved surface, so the surface
// stays where the stroke left it while the heights shrink back toward zero. The outline
// then follows the detail, heights stay small enough not to stretch the small triangles,
// and f16 keeps its precision, which is finest near zero.
//
// It runs inside the stroke's undo step: the positions and heights it changes are saved
// as a dab saves them, so one undo takes back the stroke and its Settle together.

// How much of a grid step a vertex's smooth height must pass before Settle moves the
// vertex, by what passes it: half a step, below which the skin alone holds it well.
SKIN_SETTLE_STEP :: 0.5

// How far one vertex's lift may stand from the mean of its neighbours' lifts, over their
// mean edge: under two degrees of bend. Settle measures the samples again from the curved
// surface over the moved mesh, which kinks at the mesh's edges where the lift bends, so the
// heights take up each kink; the skin's normals, worked out from those heights, then show
// it as a flat patch the shape of a triangle on a coarse mesh. What bends faster stays in
// the skin, which holds it as well; a rise several edges wide still settles.
SKIN_SETTLE_BEND :: 0.03

// The most passes that pull lifts down to that bend; each reaches one ring further from
// the vertices that do not move.
SKIN_SETTLE_BEND_PASSES :: 8

// Settles the skin after a stroke, before sculptor_stroke_end: see above. Only the nodes
// whose heights this stroke saved are looked at. Returns how many vertices moved.
sculptor_skin_settle :: proc(s: ^Sculptor) -> int {
	sk := s.skin
	h := &s.history
	if sk == nil || s.dyn != nil || !h.recording do return 0
	m := s.mesh
	I := m.indices[:]
	S := sk.segments

	// The vertices to move and how far along their normals: each vertex owned by a node
	// whose heights the stroke changed, by the smooth height round it.
	moved: [dynamic]u32
	moved.allocator = context.temp_allocator
	lift: [dynamic]f32
	lift.allocator = context.temp_allocator
	for n, id in s.nodes {
		if h.skin_saved[id] != h.stamp do continue
		step := sk.node_edge[id] / f32(S)
		for v in n.vert_first ..< n.vert_first + n.vert_count {
			// Only what passes the threshold moves, so the lift grows from nothing at the
			// edge of what settles and the mesh gets no step there.
			d := skin_settle_height(s, sk, v)
			over := abs(d) - SKIN_SETTLE_STEP * step
			if over <= 0 do continue
			append(&moved, v)
			append(&lift, over if d > 0 else -over)
		}
	}
	if len(moved) == 0 do return 0
	settle_bend(s, moved[:], lift[:])
	// The vertices whose lift the bend took away do not move.
	kept := 0
	for v, k in moved do if lift[k] != 0 {
		moved[kept], lift[kept] = v, lift[k]
		kept += 1
	}
	resize(&moved, kept)
	resize(&lift, kept)
	if kept == 0 do return 0

	// Whose normals change: the moved vertices and every vertex of a triangle on one.
	// Whose samples are measured again: every triangle on one of those.
	reach := make(map[u32]struct{}, 4 * len(moved), context.temp_allocator)
	reach_list := make([dynamic]u32, 0, 4 * len(moved), context.temp_allocator)
	for v in moved {
		for f in faces_of(s, v) {
			for k in 0 ..< u32(3) {
				w := I[3 * f + k]
				if w in reach do continue
				reach[w] = {}
				append(&reach_list, w)
			}
		}
	}
	tri_seen := make(map[u32]struct{}, 2 * len(reach_list), context.temp_allocator)
	tris := make([dynamic]u32, 0, 2 * len(reach_list), context.temp_allocator)
	for v in reach_list {
		for f in faces_of(s, v) {
			if f in tri_seen do continue
			tri_seen[f] = {}
			append(&tris, f)
		}
	}
	slice.sort(tris[:])

	// Every sample of those triangles where it is now, height and all, a triangle at a
	// time on every thread. A sample on an edge or a vertex is worked out the same from
	// either triangle (skin_base), so the copies agree to the bit.
	per := int((S + 1) * (S + 2) / 2)
	job := Settle_Job{s = s, sk = sk, tris = tris[:], points = make([]Vec3, len(tris) * per, context.temp_allocator)}
	jobs.parallel_ranges(s.pool, len(tris), &job, settle_job_points, SETTLE_GRAIN)

	// Save what changes, as a dab would: the positions of the moved vertices' nodes and
	// the heights of every node owning one of those samples.
	node_of_vertex := node_of_vertex_build(s, context.temp_allocator)
	owners := make([]bool, len(s.nodes), context.temp_allocator)
	for v in moved do owners[node_of_vertex[v]] = true
	clear(&s.hit)
	for yes, id in owners do if yes && s.nodes[id].leaf != geom.BVH_NONE do append(&s.hit, s.nodes[id].leaf)
	record_hit(s, masks = false)
	moved_nodes := make([dynamic]u32, 0, len(s.hit), context.temp_allocator)
	for yes, id in owners do if yes do append(&moved_nodes, u32(id))

	holders := make([]bool, len(s.nodes), context.temp_allocator)
	for t in tris {
		holders[tri_node(s, t)] = true
		for k in 0 ..< 3 {
			holders[tri_node(s, sk.edges[sk.tri_edges[t][k] >> 1].tris[0])] = true
			holders[node_of_vertex[I[3 * t + u32(k)]]] = true
		}
	}
	clear(&s.hit)
	for yes, id in holders do if yes && s.nodes[id].leaf != geom.BVH_NONE do append(&s.hit, s.nodes[id].leaf)
	record_skin_hit(s)

	// Move the vertices along their normals, then bring the normals the move changed up
	// to date now, since the samples are measured from them.
	for v, k in moved do m.positions[v] += linalg.normalize0(m.normals[v]) * lift[k]
	for v in reach_list {
		sum: Vec3
		for f in faces_of(s, v) do sum += face_normal(m, f)
		m.normals[v] = linalg.normalize0(sum)
	}

	// Each sample's height again: how far its point lies from the moved surface along the
	// surface's normal there (and its sideways offset across it), written by the one
	// triangle that owns the sample.
	job.heights = make([]f32, len(tris), context.temp_allocator)
	jobs.parallel_ranges(s.pool, len(tris), &job, settle_job_heights, SETTLE_GRAIN)
	for x in job.heights do sk.height_max = max(sk.height_max, x)

	sculptor_nodes_moved(s, moved_nodes[:])
	record_changed(s)
	for yes, id in holders do if yes do skin_mark(s, u32(id))
	h.current.skinned = true
	return len(moved)
}

// Pulls each lift down so it stands from the mean of its neighbours' lifts (a vertex that
// does not move, or moves the other way, lifts by zero) by at most SKIN_SETTLE_BEND of
// their mean edge, in passes over the vertices in their order, so the result never depends
// on threads. Lifts only shrink, and a lift may be pulled to nothing.
@(private)
settle_bend :: proc(s: ^Sculptor, moved: []u32, lift: []f32) {
	m := s.mesh
	I := m.indices[:]
	at := make(map[u32]int, len(moved), context.temp_allocator)
	for v, k in moved do at[v] = k
	for _ in 0 ..< SKIN_SETTLE_BEND_PASSES {
		changed := false
		for v, k in moved {
			// Each neighbour once per face it shares, which weighs them as the faces do.
			sum, edges: f32
			count := 0
			for f in faces_of(s, v) {
				for c in 0 ..< u32(3) {
					w := I[3 * f + c]
					if w == v do continue
					if kw, ok := at[w]; ok && (lift[kw] > 0) == (lift[k] > 0) do sum += abs(lift[kw])
					edges += linalg.length(m.positions[w] - m.positions[v])
					count += 1
				}
			}
			if count == 0 do continue
			cap := (sum + SKIN_SETTLE_BEND * edges) / f32(count)
			if cap < abs(lift[k]) {
				lift[k] = cap if lift[k] > 0 else -cap
				changed = true
			}
		}
		if !changed do break
	}
}

// The smooth height round vertex v: the skin's heights along every edge at v, weighted
// down linearly to nothing at the far end, with the vertex's own, so a ridge or a pit
// narrower than an edge counts for little and a broad rise counts whole.
@(private)
skin_settle_height :: proc(s: ^Sculptor, sk: ^Skin, v: u32) -> f32 {
	S := sk.segments
	I := s.mesh.indices[:]
	sum := f32(sk.heights[v])
	weight: f32 = 1
	for f in faces_of(s, v) {
		c: u32
		for k in 0 ..< u32(3) do if I[3 * f + k] == v do c = k
		// The edge from corner c onward starts at v; the one from the corner before c
		// ends at v.
		out, into := sk.tri_edges[f][c], sk.tri_edges[f][(c + 2) % 3]
		for k in 1 ..< S {
			w := 1 - f32(k) / f32(S)
			sum += w * f32(sk.heights[skin_edge_sample(sk, out, k)])
			sum += w * f32(sk.heights[skin_edge_sample(sk, into, S - k)])
			weight += 2 * w
		}
	}
	return sum / weight
}

// Triangles a Settle job takes at a time: a triangle of 16 segments is 153 samples.
@(private = "file")
SETTLE_GRAIN :: 16

@(private = "file")
Settle_Job :: struct {
	s:       ^Sculptor,
	sk:      ^Skin,
	tris:    []u32,
	// Per triangle in `tris`, each of its samples' points, in rows (j, then i).
	points:  []Vec3,
	// Per triangle in `tris`, the largest height it wrote, for Skin.height_max.
	heights: []f32,
}

@(private = "file")
settle_job_points :: proc(data: rawptr, lo, hi: int) {
	job := cast(^Settle_Job)data
	S := job.sk.segments
	per := int((S + 1) * (S + 2) / 2)
	for k in lo ..< hi {
		at := k * per
		t := job.tris[k]
		for j in 0 ..= S do for i in 0 ..= S - j {
			base, normal := skin_base(job.s, job.sk, t, i, j)
			n := linalg.normalize0(normal)
			x := skin_sample(job.sk, job.s.mesh.indices[:], t, i, j)
			lift := skin_lift(job.s, job.sk, x, t, i, j, n, f32(job.sk.heights[x]))
			job.points[at] = base + n * settle_rounding(job.s, t, i, j, S, base, n) + lift
			at += 1
		}
	}
}

@(private = "file")
settle_job_heights :: proc(data: rawptr, lo, hi: int) {
	job := cast(^Settle_Job)data
	s, sk := job.s, job.sk
	I := s.mesh.indices[:]
	S := sk.segments
	per := int((S + 1) * (S + 2) / 2)
	for k in lo ..< hi {
		t := job.tris[k]
		at := k * per
		most: f32
		for j in 0 ..= S do for i in 0 ..= S - j {
			point := job.points[at]
			at += 1
			if !settle_writes(s, sk, I, t, i, j) do continue
			base, normal := skin_base(s, sk, t, i, j)
			n := linalg.normalize0(normal)
			off := point - base - n * settle_rounding(s, t, i, j, S, base, n)
			height := linalg.dot(off, n)
			x := skin_sample(sk, I, t, i, j)
			sk.heights[x] = f16(height)
			most = max(most, abs(height))
			// A sideways offset is measured again in the moved owner's frame too, so a
			// pinch or an overhang stays where the stroke left it.
			if sk.side != nil && sk.side[x] != {} {
				tu, tv := skin_frame(s, sk, t, i, j, n)
				sk.side[x] = {f16(linalg.dot(off, tu)), f16(linalg.dot(off, tv))}
				most = max(most, abs(height) + abs(f32(sk.side[x].x)) + abs(f32(sk.side[x].y)))
			}
		}
		job.heights[k] = most
	}
}

// How far the surface the viewport shows lies above the flat triangle at sample (i, j),
// before any height: the skin's light follows the mesh's interpolated normals, so a mesh
// triangle looks rounded, as Phong tessellation (Boubekeur and Alexa, 2008) rounds it from
// its corners' normals. Settle keeps that rounded surface plus the heights where it was,
// rather than the flat one: kept flat, the heights would carry the rounding the light
// already adds, and each moved triangle would show as a facet. Zero at the corners; on an
// edge it reads that edge's two corners alone.
@(private)
settle_rounding :: proc(s: ^Sculptor, t, i, j, S: u32, base, n: Vec3) -> f32 {
	P := s.mesh.positions[:]
	N := s.mesh.normals[:]
	I := s.mesh.indices[:]
	b := [3]f32{1 - f32(i + j) / f32(S), f32(i) / f32(S), f32(j) / f32(S)}
	rounded: Vec3
	for k in 0 ..< 3 {
		if b[k] == 0 do continue
		v := I[3 * t + u32(k)]
		nv := linalg.normalize0(N[v])
		rounded += b[k] * (base - linalg.dot(base - P[v], nv) * nv)
	}
	return linalg.dot(rounded - base, n)
}

// Whether triangle t writes its sample at (i, j): inside samples always, an edge's by its
// owner (its lower triangle), a vertex's by its first triangle. Every sample whose base
// the move changed has its owner among the triangles Settle measures, since a changed
// base needs a corner whose normal changed, and every triangle on that corner is there.
@(private = "file")
settle_writes :: #force_inline proc(s: ^Sculptor, sk: ^Skin, I: []u32, t, i, j: u32) -> bool {
	S := sk.segments
	switch {
	case i == 0 && j == 0: return faces_of(s, I[3 * t])[0] == t
	case i == S:           return faces_of(s, I[3 * t + 1])[0] == t
	case j == S:           return faces_of(s, I[3 * t + 2])[0] == t
	case j == 0:           return sk.edges[sk.tri_edges[t][0] >> 1].tris[0] == t
	case i + j == S:       return sk.edges[sk.tri_edges[t][1] >> 1].tris[0] == t
	case i == 0:           return sk.edges[sk.tri_edges[t][2] >> 1].tris[0] == t
	}
	return true
}
