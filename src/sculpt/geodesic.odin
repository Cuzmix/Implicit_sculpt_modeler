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

// The edges of the shown surface inside the round reach of `radius` about `center`: the
// vertices inside, listed in leaf order so nothing depends on the threads, and each one's
// neighbours (ends[first[i]:first[i + 1]], places in that list; an edge two triangles share
// is there twice, an open edge once). Also the triangle the centre lies on and the vertex
// nearest it, max(u32) where none is found. On the temp allocator; it leaves `s.hit` as
// the reach's leaves.
@(private = "file")
Geodesic_Graph :: struct {
	inside:  []u32,
	first:   []u32,
	ends:    []u32,
	tri:     u32,
	nearest: u32,
}

@(private = "file")
geodesic_graph :: proc(s: ^Sculptor, center: Vec3, radius: f32) -> (g: Geodesic_Graph) {
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

	// Where a walk from the centre starts: the corners of the triangle it lies on, or with
	// none found (triangles large beside the brush), the vertex nearest it; ties to the
	// lower number.
	tri, tri_d2 := max(u32), max(f32)
	nearest, nearest_d2 := max(u32), j.r2
	for l in c.leaves[:len(s.hit)] {
		if l.under != max(u32) && (l.under_d2 < tri_d2 || (l.under_d2 == tri_d2 && l.under < tri)) do tri, tri_d2 = l.under, l.under_d2
		if l.nearest != max(u32) && (l.nearest_d2 < nearest_d2 || (l.nearest_d2 == nearest_d2 && l.nearest < nearest)) do nearest, nearest_d2 = l.nearest, l.nearest_d2
	}
	return {inside[:], first, ends, tri, nearest}
}

// Dijkstra over `g` from the distances `d` already seeded (and pushed on `queue`), out to
// `radius`.
@(private = "file")
geodesic_walk :: proc(s: ^Sculptor, g: Geodesic_Graph, d: []f32, queue: ^priority_queue.Priority_Queue(Geodesic_Item), radius: f32) {
	positions := s.mesh.positions
	for priority_queue.len(queue^) > 0 {
		it := priority_queue.pop(queue)
		if it.d > d[it.v] do continue
		p := positions[g.inside[it.v]]
		for w in g.ends[g.first[it.v]:g.first[it.v + 1]] {
			nd := it.d + linalg.length(positions[g.inside[w]] - p)
			if nd >= radius || nd >= d[w] do continue
			d[w] = nd
			priority_queue.push(queue, Geodesic_Item{nd, w})
		}
	}
}

@(private = "file")
geodesic_queue :: proc(m: int) -> (queue: priority_queue.Priority_Queue(Geodesic_Item)) {
	priority_queue.init(&queue, proc(a, b: Geodesic_Item) -> bool {
		return a.d < b.d || (a.d == b.d && a.v < b.v)
	}, priority_queue.default_swap_proc(Geodesic_Item), max(m, 16), context.temp_allocator)
	return
}

// The vertices of `g` whose distance in `d` is under `radius`, sorted, with those
// distances. On the temp allocator.
@(private = "file")
geodesic_within :: proc(g: Geodesic_Graph, d: []f32, radius: f32) -> (verts: []u32, dist: []f32) {
	Pair :: struct {
		v: u32,
		d: f32,
	}
	pairs := make([dynamic]Pair, 0, len(d), context.temp_allocator)
	for i in 0 ..< len(d) do if d[i] < radius do append(&pairs, Pair{g.inside[i], d[i]})
	slice.sort_by(pairs[:], proc(a, b: Pair) -> bool {return a.v < b.v})
	verts = make([]u32, len(pairs), context.temp_allocator)
	dist = make([]f32, len(pairs), context.temp_allocator)
	for p, i in pairs do verts[i], dist[i] = p.v, p.d
	return
}

// The vertices of the shown surface within `radius` of `center` along it, sorted, and
// each one's distance (the corners of the triangle the centre lies on start at their
// straight distance from it, as a path from the centre would). On the temp allocator.
// It leaves `s.hit` as the reach's leaves.
@(private)
geodesic_reach :: proc(s: ^Sculptor, center: Vec3, radius: f32) -> (verts: []u32, dist: []f32) {
	g := geodesic_graph(s, center, radius)
	d := make([]f32, len(g.inside), context.temp_allocator)
	slice.fill(d, max(f32))
	queue := geodesic_queue(len(g.inside))
	seed :: proc(queue: ^priority_queue.Priority_Queue(Geodesic_Item), d: []f32, s: ^Sculptor, v: u32, center: Vec3) {
		at := s.connected.label[v]
		dv := linalg.length(s.mesh.positions[v] - center)
		if dv < d[at] {
			d[at] = dv
			priority_queue.push(queue, Geodesic_Item{dv, at})
		}
	}
	if g.tri != max(u32) {
		for corner in 0 ..< u32(3) do seed(&queue, d, s, s.mesh.indices[3 * g.tri + corner], center)
	} else if g.nearest != max(u32) {
		seed(&queue, d, s, g.nearest, center)
	}
	geodesic_walk(s, g, d, &queue, radius)
	return geodesic_within(g, d, radius)
}

// Boundary's reach (Blender's Boundary brush): the open edge of the shown surface nearest
// `center` within `radius`, held whole for a radius along the edge either way from the
// vertex of it nearest the press and fading over the next radius, and the surface within a
// radius of it, each vertex given its distance from the edge along the surface plus how far
// past that first radius along the edge its nearest part of the edge lies. So the rim is
// picked up as a band rather than a point, as a hem is taken in the fingers, with no tear
// where the hold ends along it. Sorted; on the temp allocator. False when no open edge
// lies within the radius. It leaves `s.hit` as the reach's leaves.
@(private)
boundary_reach :: proc(s: ^Sculptor, center: Vec3, radius: f32) -> (verts: []u32, dist: []f32, ok: bool) {
	// The open edge nearest the press: an edge in one shown triangle alone.
	near := geodesic_graph(s, center, radius)
	start, start_d2 := max(u32), radius * radius
	for i in 0 ..< len(near.inside) {
		p := s.mesh.positions[near.inside[i]]
		d2 := linalg.length2(p - center)
		if d2 >= start_d2 || !geodesic_open(near, u32(i)) do continue
		start, start_d2 = near.inside[i], d2
	}
	if start == max(u32) do return
	// Along the edge from there, then into the surface from every part of it.
	g := geodesic_graph(s, s.mesh.positions[start], 2 * radius)
	m := len(g.inside)
	along := make([]f32, m, context.temp_allocator)
	slice.fill(along, max(f32))
	queue := geodesic_queue(m)
	from := s.connected.label[start]
	along[from] = 0
	priority_queue.push(&queue, Geodesic_Item{0, from})
	positions := s.mesh.positions
	for priority_queue.len(queue) > 0 {
		it := priority_queue.pop(&queue)
		if it.d > along[it.v] do continue
		p := positions[g.inside[it.v]]
		for w in g.ends[g.first[it.v]:g.first[it.v + 1]] {
			if !geodesic_open_edge(g, it.v, w) do continue
			nd := it.d + linalg.length(positions[g.inside[w]] - p)
			if nd >= 2 * radius || nd >= along[w] do continue
			along[w] = nd
			priority_queue.push(&queue, Geodesic_Item{nd, w})
		}
	}
	d := make([]f32, m, context.temp_allocator)
	slice.fill(d, max(f32))
	for a, i in along {
		if a >= 2 * radius do continue
		d[i] = max(a - radius, 0)
		priority_queue.push(&queue, Geodesic_Item{d[i], u32(i)})
	}
	geodesic_walk(s, g, d, &queue, radius)
	verts, dist = geodesic_within(g, d, radius)
	return verts, dist, true
}

// Whether vertex `i` of `g` lies on an open edge.
@(private = "file")
geodesic_open :: proc(g: Geodesic_Graph, i: u32) -> bool {
	for w in g.ends[g.first[i]:g.first[i + 1]] do if geodesic_open_edge(g, i, w) do return true
	return false
}

// Whether the edge from `i` to `w` in `g` is open: one shown triangle has it, so `w` is
// among `i`'s neighbours once.
@(private = "file")
geodesic_open_edge :: proc(g: Geodesic_Graph, i, w: u32) -> bool {
	count := 0
	for x in g.ends[g.first[i]:g.first[i + 1]] do if x == w do count += 1
	return count == 1
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
