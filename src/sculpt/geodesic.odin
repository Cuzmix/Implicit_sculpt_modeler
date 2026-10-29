package sculpt

import "base:runtime"
import "core:container/priority_queue"
import "core:math/linalg"
import "core:slice"

import "../geom"
import "../jobs"

// Distances along the surface for Grab's Topological falloff (ZBrush's Move Topological,
// Blender's geodesic falloff): Dijkstra over the edges of the shown triangles inside the
// brush's round reach, which holds everything a path shorter than the radius can reach.

@(private = "file")
Geodesic_Job :: struct {
	s:      ^Sculptor,
	center: Vec3,
	r2:     f32,
}

@(private = "file")
Geodesic_Item :: struct {
	d: f32,
	v: u32, // the vertex's place in the reach's list
}

// The vertices of the shown surface within `radius` of `center` along it, sorted, and
// each one's distance (the corners of the triangle the centre lies on start at their
// straight distance from it, as a path from the centre would). On the temp allocator.
// It leaves `s.hit` as the reach's leaves.
@(private)
geodesic_reach :: proc(s: ^Sculptor, center: Vec3, radius: f32) -> (verts: []u32, dist: []f32) {
	clear(&s.hit)
	geom.bvh_query_leaves(&s.bvh, center, radius, &s.hit)
	slice.sort(s.hit[:])
	resize(&s.hit, len(slice.unique(s.hit[:])))
	c := &s.connected
	n := len(s.mesh.positions)
	if len(c.mark) < n {
		resize(&c.mark, n)
		resize(&c.label, n)
	}
	c.stamp += 2
	if c.stamp < 2 {
		// Wrapped: marks from long ago would look current.
		slice.zero(c.mark[:])
		c.stamp = 2
	}
	for len(c.leaves) < len(s.hit) {
		append(&c.leaves, Connected_Leaf{links = make([dynamic][2]u32, runtime.heap_allocator())})
	}
	j := Geodesic_Job{s = s, center = center, r2 = radius * radius}
	count: u32
	for leaf in s.hit do count += s.nodes[s.node_of[leaf]].vert_count
	pool := s.pool if count >= PARALLEL_MIN_VERTS else nil
	jobs.parallel_for(pool, len(s.hit), &j, job_geodesic_marks)

	// Each vertex inside gets its place in a list in leaf order, so the graph and the
	// order its ties break in do not depend on the threads.
	inside := make([dynamic]u32, 0, int(count), context.temp_allocator)
	for leaf in s.hit {
		first, last := owned(s, leaf)
		for v in first ..< last {
			if c.mark[v] != c.stamp do continue
			c.label[v] = u32(len(inside))
			append(&inside, v)
		}
	}
	jobs.parallel_for(pool, len(s.hit), &j, job_geodesic_edges)

	// The edges as each vertex's neighbours (both ways; an edge two triangles share is
	// there twice, which changes nothing).
	m := len(inside)
	first := make([]u32, m + 1, context.temp_allocator)
	for l in c.leaves[:len(s.hit)] {
		for e in l.links {
			first[c.label[e[0]] + 1] += 1
			first[c.label[e[1]] + 1] += 1
		}
	}
	for i in 0 ..< m do first[i + 1] += first[i]
	next := make([]u32, m, context.temp_allocator)
	copy(next, first[:m])
	ends := make([]u32, first[m], context.temp_allocator)
	for l in c.leaves[:len(s.hit)] {
		for e in l.links {
			a, b := c.label[e[0]], c.label[e[1]]
			ends[next[a]], ends[next[b]] = b, a
			next[a] += 1
			next[b] += 1
		}
	}

	// Where it starts: the corners of the triangle the centre lies on, or with none found
	// (triangles large beside the brush), the vertex nearest it; ties to the lower number.
	tri, tri_d2 := max(u32), max(f32)
	nearest, nearest_d2 := max(u32), j.r2
	for l in c.leaves[:len(s.hit)] {
		if l.under != max(u32) && (l.under_d2 < tri_d2 || (l.under_d2 == tri_d2 && l.under < tri)) do tri, tri_d2 = l.under, l.under_d2
		if l.nearest != max(u32) && (l.nearest_d2 < nearest_d2 || (l.nearest_d2 == nearest_d2 && l.nearest < nearest)) do nearest, nearest_d2 = l.nearest, l.nearest_d2
	}
	d := make([]f32, m, context.temp_allocator)
	slice.fill(d, max(f32))
	queue: priority_queue.Priority_Queue(Geodesic_Item)
	priority_queue.init(&queue, proc(a, b: Geodesic_Item) -> bool {
		return a.d < b.d || (a.d == b.d && a.v < b.v)
	}, priority_queue.default_swap_proc(Geodesic_Item), max(m, 16), context.temp_allocator)
	seed :: proc(queue: ^priority_queue.Priority_Queue(Geodesic_Item), d: []f32, s: ^Sculptor, v: u32, center: Vec3) {
		at := s.connected.label[v]
		dv := linalg.length(s.mesh.positions[v] - center)
		if dv < d[at] {
			d[at] = dv
			priority_queue.push(queue, Geodesic_Item{dv, at})
		}
	}
	if tri != max(u32) {
		for corner in 0 ..< u32(3) do seed(&queue, d, s, s.mesh.indices[3 * tri + corner], center)
	} else if nearest != max(u32) {
		seed(&queue, d, s, nearest, center)
	}
	positions := s.mesh.positions
	for priority_queue.len(queue) > 0 {
		it := priority_queue.pop(&queue)
		if it.d > d[it.v] do continue
		p := positions[inside[it.v]]
		for w in ends[first[it.v]:first[it.v + 1]] {
			nd := it.d + linalg.length(positions[inside[w]] - p)
			if nd >= radius || nd >= d[w] do continue
			d[w] = nd
			priority_queue.push(&queue, Geodesic_Item{nd, w})
		}
	}

	Pair :: struct {
		v: u32,
		d: f32,
	}
	pairs := make([dynamic]Pair, 0, m, context.temp_allocator)
	for i in 0 ..< m do if d[i] < radius do append(&pairs, Pair{inside[i], d[i]})
	slice.sort_by(pairs[:], proc(a, b: Pair) -> bool {return a.v < b.v})
	verts = make([]u32, len(pairs), context.temp_allocator)
	dist = make([]f32, len(pairs), context.temp_allocator)
	for p, i in pairs do verts[i], dist[i] = p.v, p.d
	return
}

// One hit leaf: marks the vertices it owns inside the round reach and finds the one
// nearest the centre.
@(private = "file")
job_geodesic_marks :: proc(data: rawptr, i: int) {
	j := cast(^Geodesic_Job)data
	s := j.s
	c := &s.connected
	l := &c.leaves[i]
	l.nearest, l.nearest_d2 = max(u32), j.r2
	first, last := owned(s, s.hit[i])
	for v in first ..< last {
		delta := s.mesh.positions[v] - j.center
		d2 := linalg.dot(delta, delta)
		if d2 >= j.r2 do continue
		c.mark[v] = c.stamp
		if d2 < l.nearest_d2 do l.nearest, l.nearest_d2 = v, d2
	}
}

// One hit leaf: the edges of its shown triangles with both ends inside, and its triangle
// nearest the centre with all three inside, near enough to be the one it lies on.
@(private = "file")
job_geodesic_edges :: proc(data: rawptr, i: int) {
	j := cast(^Geodesic_Job)data
	s := j.s
	c := &s.connected
	m := s.mesh
	l := &c.leaves[i]
	clear(&l.links)
	l.under, l.under_d2 = max(u32), max(f32)
	// Only triangles with a corner this near the centre may be the one it lies on: a
	// quarter of the radius, as Connected's flood takes.
	near2 := j.r2 / 16
	hidden := sculptor_hidden_tris(s)
	nd := s.nodes[s.node_of[s.hit[i]]]
	for f in nd.tri_first ..< nd.tri_first + nd.tri_count {
		if hidden != nil && hidden[f] do continue
		a, b, e := m.indices[3 * f], m.indices[3 * f + 1], m.indices[3 * f + 2]
		ia, ib, ie := c.mark[a] == c.stamp, c.mark[b] == c.stamp, c.mark[e] == c.stamp
		if ia && ib do append(&l.links, [2]u32{a, b})
		if ib && ie do append(&l.links, [2]u32{b, e})
		if ia && ie do append(&l.links, [2]u32{a, e})
		if !(ia && ib && ie) do continue
		pa, pb, pe := m.positions[a], m.positions[b], m.positions[e]
		da, db, de := pa - j.center, pb - j.center, pe - j.center
		if min(linalg.dot(da, da), linalg.dot(db, db), linalg.dot(de, de)) >= near2 do continue
		q := triangle_closest(j.center, pa, pb, pe) - j.center
		if d2 := linalg.dot(q, q); d2 < l.under_d2 do l.under, l.under_d2 = f, d2
	}
}
