package geom

import "base:intrinsics"
import "core:math"
import "core:math/linalg"
import "core:slice"

import "../jobs"

// Slicing, as ZBrush's SliceCurve followed by Split Groups and Close Holes does in one
// go: a plane cuts the mesh in two, and each half becomes a mesh of its own. Triangles
// that cross the plane are clipped to it, each crossing edge getting one cut point that
// both halves share; with `close`, every loop the cut leaves on the plane is filled
// with a flat cap (cap_fill), so a closed mesh gives two closed meshes.

// A cap's edges are about as long as the cut's, but a cap never has more triangles than
// this (on a dense mesh it is then coarser than the surface around it): filling it takes
// time in proportion, and a cap is flat, so detail there is only for sculpting later.
SLICE_CAP_MAX_TRIANGLES :: 100_000

// Cuts `m` along the plane through `point` across `normal` (unit length). `front` is
// the part on the side `normal` points to, `back` the rest, each with zero normals for
// the sculptor to compute. With `close`, each loop the cut leaves on the plane is
// capped. Returns ok false when the plane misses the mesh or leaves all of it on one
// side.
mesh_slice :: proc(m: Mesh, point, normal: Vec3, close: bool, pool: ^jobs.Pool, allocator := context.allocator) -> (front, back: Mesh, ok: bool) {
	n := len(m.positions)
	tcount := len(m.indices) / 3
	if n == 0 || tcount == 0 do return
	// Vertices this close to the plane go onto it, so a cut never makes a sliver
	// between a vertex and the plane.
	lo, hi := m.positions[0], m.positions[0]
	for p in m.positions do lo, hi = linalg.min(lo, p), linalg.max(hi, p)
	snap := max(max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z) * 1e-5, 1e-30)

	// Sides, then the triangles wholly on one side, in parallel: only the few that
	// cross the plane are clipped one by one, in order, so the cut points' numbers do
	// not depend on threads.
	chunks := (tcount + RANGE_GRAIN - 1) / RANGE_GRAIN
	Side_Job :: struct {
		m:            Mesh,
		point:        Vec3,
		normal:       Vec3,
		snap:         f32,
		positions:    []Vec3,
		side:         []i8, // 1 front, -1 back, 0 on the plane
		has:          [][2]bool, // per chunk of vertices: some on the front, some on the back
		counts:       [][3]int, // per chunk of triangles: wholly front, wholly back, crossing
		offsets:      [][2]int, // ...where its whole ones go in each half
		halves:       [2][]u32,
	}
	job := Side_Job {
		m         = m,
		point     = point,
		normal    = normal,
		snap      = snap,
		positions = make([]Vec3, n, context.temp_allocator),
		side      = make([]i8, n, context.temp_allocator),
		has       = make([][2]bool, (n + RANGE_GRAIN - 1) / RANGE_GRAIN, context.temp_allocator),
		counts    = make([][3]int, chunks, context.temp_allocator),
		offsets   = make([][2]int, chunks, context.temp_allocator),
	}
	jobs.parallel_ranges(pool, n, &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Side_Job)data
		has: [2]bool
		for v in lo ..< hi {
			p := job.m.positions[v]
			d := linalg.dot(p - job.point, job.normal)
			switch {
			case abs(d) <= job.snap:
				p -= d * job.normal
				job.side[v] = 0
			case d > 0:
				job.side[v] = 1
				has[0] = true
			case:
				job.side[v] = -1
				has[1] = true
			}
			job.positions[v] = p
		}
		job.has[lo / RANGE_GRAIN] = has
	}, RANGE_GRAIN)
	any_front, any_back := false, false
	for h in job.has do any_front, any_back = any_front || h[0], any_back || h[1]
	if !any_front || !any_back do return

	// A triangle with a corner on each side crosses; one with corners on one side (and
	// on the plane) goes whole to that side; one flat in the plane goes nowhere.
	kind :: #force_inline proc(side: []i8, idx: []u32, t: int) -> int {
		f, k := false, false
		for c in 0 ..< 3 {
			s := side[idx[3 * t + c]]
			f ||= s > 0
			k ||= s < 0
		}
		switch {
		case f && k:
			return 2
		case f:
			return 0
		case k:
			return 1
		}
		return 3
	}
	jobs.parallel_ranges(pool, tcount, &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Side_Job)data
		c: [3]int
		for t in lo ..< hi do if k := kind(job.side, job.m.indices[:], t); k < 3 do c[k] += 1
		job.counts[lo / RANGE_GRAIN] = c
	}, RANGE_GRAIN)
	whole: [2]int
	crossing := 0
	for c, i in job.counts {
		job.offsets[i] = whole
		whole += {c[0], c[1]}
		crossing += c[2]
	}
	halves: [2][dynamic]u32 // front, back
	for &h, k in halves {
		h = make([dynamic]u32, 3 * whole[k], 3 * whole[k] + 6 * crossing + 64, context.temp_allocator)
		job.halves[k] = h[:]
	}
	jobs.parallel_ranges(pool, tcount, &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Side_Job)data
		at := job.offsets[lo / RANGE_GRAIN]
		idx := job.m.indices[:]
		for t in lo ..< hi {
			k := kind(job.side, idx, t)
			if k >= 2 do continue
			copy(job.halves[k][3 * at[k]:][:3], idx[3 * t:][:3])
			at[k] += 1
		}
	}, RANGE_GRAIN)

	// One cut point per crossing edge, made from its lower-numbered end so both of its
	// triangles agree.
	extra_cuts := make([dynamic]Vec3, 0, 2 * crossing + 16, context.temp_allocator)
	cuts := make(map[u64]u32, 2 * crossing + 16, context.temp_allocator)
	crossed: f64 // the lengths of the crossing edges, summed in the order they are met
	Cutter :: struct {
		positions: []Vec3,
		extra:     ^[dynamic]Vec3,
		cuts:      ^map[u64]u32,
		crossed:   ^f64,
		point:     Vec3,
		normal:    Vec3,
	}
	cutter := Cutter{job.positions, &extra_cuts, &cuts, &crossed, point, normal}
	cut :: proc(c: Cutter, a, b: u32) -> u32 {
		lo, hi := min(a, b), max(a, b)
		key := u64(lo) << 32 | u64(hi)
		if v, found := c.cuts[key]; found do return v
		pa, pb := c.positions[lo], c.positions[hi]
		c.crossed^ += f64(linalg.length(pb - pa))
		da, db := linalg.dot(pa - c.point, c.normal), linalg.dot(pb - c.point, c.normal)
		p := pa + (pb - pa) * (da / (da - db))
		p -= linalg.dot(p - c.point, c.normal) * c.normal
		append(c.extra, p)
		v := u32(len(c.positions) + len(c.extra) - 1)
		c.cuts[key] = v
		return v
	}
	side := job.side
	for t in 0 ..< tcount {
		if kind(side, m.indices[:], t) != 2 do continue
		tri := [3]u32{m.indices[3 * t], m.indices[3 * t + 1], m.indices[3 * t + 2]}
		for &out, k in halves {
			s: i8 = 1 if k == 0 else -1
			// Clip to this side corner by corner, in order, then fan.
			poly: [4]u32
			count := 0
			for c in 0 ..< 3 {
				a, b := tri[c], tri[(c + 1) % 3]
				if side[a] != -s {
					poly[count] = a
					count += 1
				}
				if (side[a] == s && side[b] == -s) || (side[a] == -s && side[b] == s) {
					poly[count] = cut(cutter, a, b)
					count += 1
				}
			}
			for k2 in 1 ..< count - 1 do append(&out, poly[0], poly[k2], poly[k2 + 1])
		}
	}
	if len(halves[0]) == 0 || len(halves[1]) == 0 do return
	positions := make([dynamic]Vec3, 0, n + len(extra_cuts), context.temp_allocator)
	append(&positions, ..job.positions)
	append(&positions, ..extra_cuts[:])
	// Caps take the length of the edges the plane crossed: the cut's own edges are
	// shorter, since it runs across triangles.
	edge := crossed / f64(max(len(extra_cuts), 1))

	// What may lie on a cap's border: vertices on the plane and the cut points.
	on_plane := make([]bool, len(positions), context.temp_allocator)
	for s, v in side do on_plane[v] = s == 0
	for v in n ..< len(positions) do on_plane[v] = true

	results: [2]Mesh
	for &out, k in halves {
		extra := make([dynamic]Vec3, 0, 0, context.temp_allocator) // cap vertices, numbered after `positions`
		if close {
			// Outward from the front half is against the normal, from the back with it.
			cap_normal := -normal if k == 0 else normal
			cap_fill(positions[:], &out, &extra, on_plane, point, cap_normal, edge)
		}
		results[k] = slice_compact(positions[:], extra[:], out[:], pool, allocator)
	}
	return results[0], results[1], true
}

// The half's own mesh: the vertices its triangles use, in order. In parallel passes:
// mark what is used, number it chunk by chunk, then copy; most of the time is the first
// touch of the new arrays' memory.
@(private = "file")
slice_compact :: proc(positions, extra: []Vec3, indices: []u32, pool: ^jobs.Pool, allocator := context.allocator) -> Mesh {
	Compact :: struct {
		positions, extra: []Vec3,
		indices:          []u32,
		used:             []u8, // set from many threads, always to 1
		remap:            []u32,
		counts:           []u32, // per chunk of vertices: how many are used, then where they start
		out:              Mesh,
	}
	total := len(positions) + len(extra)
	c := Compact {
		positions = positions,
		extra     = extra,
		indices   = indices,
		used      = make([]u8, total, context.temp_allocator),
		remap     = make([]u32, total, context.temp_allocator),
		counts    = make([]u32, (total + RANGE_GRAIN - 1) / RANGE_GRAIN, context.temp_allocator),
	}
	jobs.parallel_ranges(pool, len(indices), &c, proc(data: rawptr, lo, hi: int) {
		c := cast(^Compact)data
		for i in c.indices[lo:hi] do intrinsics.atomic_store_explicit(&c.used[i], 1, .Relaxed)
	}, RANGE_GRAIN)
	jobs.parallel_ranges(pool, total, &c, proc(data: rawptr, lo, hi: int) {
		c := cast(^Compact)data
		count: u32
		for u in c.used[lo:hi] do count += u32(u)
		c.counts[lo / RANGE_GRAIN] = count
	}, RANGE_GRAIN)
	count: u32
	for &k in c.counts {
		k, count = count, count + k
	}
	c.out = Mesh {
		positions = make([dynamic]Vec3, count, allocator),
		normals   = make([dynamic]Vec3, count, allocator),
		indices   = make([dynamic]u32, len(indices), allocator),
	}
	jobs.parallel_ranges(pool, total, &c, proc(data: rawptr, lo, hi: int) {
		c := cast(^Compact)data
		at := c.counts[lo / RANGE_GRAIN]
		for v in lo ..< hi {
			if c.used[v] == 0 do continue
			c.remap[v] = at
			c.out.positions[at] = c.positions[v] if v < len(c.positions) else c.extra[v - len(c.positions)]
			at += 1
		}
	}, RANGE_GRAIN)
	jobs.parallel_ranges(pool, len(indices), &c, proc(data: rawptr, lo, hi: int) {
		c := cast(^Compact)data
		for k in lo ..< hi do c.out.indices[k] = c.remap[c.indices[k]]
	}, RANGE_GRAIN)
	return c.out
}

// Fills the holes the cut left in a half (`indices`, over `positions`) with flat caps
// facing along `cap_normal`: the half's border edges with both ends on the plane are
// joined into loops, outer loops and the holes inside them are triangulated together
// (ear clipping, holes joined to their outer loop by a bridge), then the cap's long
// inner edges are split, its triangles made Delaunay by flips and its inner vertices
// smoothed, so its edges come out about `edge` long. New vertices go into
// `extra`, numbered after `positions`. A loop that does not close is left open.
@(private = "file")
cap_fill :: proc(positions: []Vec3, indices: ^[dynamic]u32, extra: ^[dynamic]Vec3, on_plane: []bool, origin, cap_normal: Vec3, edge: f64) {
	// Directed edges with both ends on the plane, and which of them have no reverse.
	Edge :: struct {
		a, b: u32,
	}
	edges := make([dynamic]Edge, 0, 1024, context.temp_allocator)
	seen := make(map[u64]bool, 1024, context.temp_allocator)
	for t := 0; t < len(indices); t += 3 {
		for c in 0 ..< 3 {
			a, b := indices[t + c], indices[t + (c + 1) % 3]
			if !on_plane[a] || !on_plane[b] do continue
			append(&edges, Edge{a, b})
			seen[u64(a) << 32 | u64(b)] = true
		}
	}
	border := make([dynamic]Edge, 0, len(edges), context.temp_allocator)
	for e in edges do if !(u64(e.b) << 32 | u64(e.a) in seen) do append(&border, e)
	if len(border) < 3 do return
	// The cap runs each border edge the other way: as loops, b to a.
	slice.sort_by(border[:], proc(x, y: Edge) -> bool {return x.b < y.b || (x.b == y.b && x.a < y.a)})
	used := make([]bool, len(border), context.temp_allocator)
	starting :: proc(border: []Edge, used: []bool, v: u32) -> int {
		i, _ := slice.binary_search_by(border, v, proc(e: Edge, v: u32) -> slice.Ordering {
			return .Less if e.b < v else .Greater
		})
		for ; i < len(border) && border[i].b == v; i += 1 do if !used[i] do return i
		return -1
	}

	// A plane basis in which the cap faces the viewer: u × v = cap_normal.
	u := linalg.normalize(linalg.cross(cap_normal, Vec3{1, 0, 0} if abs(cap_normal.x) < 0.9 else Vec3{0, 1, 0}))
	v := linalg.cross(cap_normal, u)
	flat :: proc(p, origin, u, v: Vec3) -> [2]f64 {
		d := p - origin
		return {f64(linalg.dot(d, u)), f64(linalg.dot(d, v))}
	}

	Loop :: struct {
		first, count: int, // into loop_verts
		area:         f64, // signed: outer loops positive, holes negative
	}
	loop_verts := make([dynamic]u32, 0, len(border), context.temp_allocator)
	loops := make([dynamic]Loop, 0, 8, context.temp_allocator)
	for start in 0 ..< len(border) {
		if used[start] do continue
		first := len(loop_verts)
		e := start
		closed := false
		for steps := 0; steps <= len(border); steps += 1 {
			used[e] = true
			append(&loop_verts, border[e].b)
			next_vertex := border[e].a
			if next_vertex == border[start].b {
				closed = true
				break
			}
			e = starting(border[:], used, next_vertex)
			if e < 0 do break
		}
		count := len(loop_verts) - first
		if !closed || count < 3 {
			resize(&loop_verts, first)
			continue
		}
		area: f64
		for i in 0 ..< count {
			p := flat(positions[loop_verts[first + i]], origin, u, v)
			q := flat(positions[loop_verts[first + (i + 1) % count]], origin, u, v)
			area += p.x * q.y - q.x * p.y
		}
		append(&loops, Loop{first, count, area / 2})
	}
	if len(loops) == 0 do return

	// Each hole goes with the smallest outer loop around it.
	owner := make([]int, len(loops), context.temp_allocator)
	for &o, i in owner {
		o = -1
		if loops[i].area >= 0 do continue
		p := flat(positions[loop_verts[loops[i].first]], origin, u, v)
		best := max(f64)
		for l, j in loops {
			if l.area <= 0 || l.area >= best do continue
			if point_in_loop(positions, loop_verts[l.first:][:l.count], p, origin, u, v) {
				o, best = j, l.area
			}
		}
	}

	cap := make([dynamic]u32, 0, 3 * len(border), context.temp_allocator)
	for l, i in loops {
		if l.area <= 0 do continue
		holes := make([dynamic]Loop, 0, 4, context.temp_allocator)
		for h, j in loops do if owner[j] == i do append(&holes, h)
		ear_clip(positions, loop_verts[:], l, holes[:], origin, u, v, &cap)
	}
	if len(cap) == 0 do return

	// Evening out happens on the cap alone, in the plane.
	area: f64
	for l in loops do area += l.area
	target := max(edge, math.sqrt(area / (0.433 * SLICE_CAP_MAX_TRIANGLES)))
	if !(target > 0) {
		append(indices, ..cap[:])
		return
	}
	cap_even(positions, &cap, extra, origin, u, v, target)
	append(indices, ..cap[:])
}

@(private = "file")
point_in_loop :: proc(positions: []Vec3, loop: []u32, p: [2]f64, origin, u, v: Vec3) -> bool {
	inside := false
	for i in 0 ..< len(loop) {
		da := positions[loop[i]] - origin
		db := positions[loop[(i + 1) % len(loop)]] - origin
		a := [2]f64{f64(linalg.dot(da, u)), f64(linalg.dot(da, v))}
		b := [2]f64{f64(linalg.dot(db, u)), f64(linalg.dot(db, v))}
		if (a.y > p.y) != (b.y > p.y) && p.x < a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x) do inside = !inside
	}
	return inside
}

// One corner of the polygon being clipped: a circular doubly linked list.
@(private = "file")
Ear_Node :: struct {
	p:          [2]f64,
	id:         u32, // the vertex
	prev, next: int,
	gone:       bool,
}

@(private = "file")
cross2 :: #force_inline proc(a, b, c: [2]f64) -> f64 {
	return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
}

// Triangulates the outer loop `outer` (counter-clockwise in the u, v plane) with the
// `holes` inside it (clockwise), appending the triangles to `out`.
@(private = "file")
ear_clip :: proc(positions: []Vec3, loop_verts: []u32, outer: $L, holes: []L, origin, u, v: Vec3, out: ^[dynamic]u32) {
	nodes := make([dynamic]Ear_Node, 0, outer.count + 16, context.temp_allocator)
	add_ring :: proc(nodes: ^[dynamic]Ear_Node, positions: []Vec3, ids: []u32, origin, u, v: Vec3) -> int {
		first := len(nodes)
		for id, i in ids {
			d := positions[id] - origin
			append(nodes, Ear_Node{p = {f64(linalg.dot(d, u)), f64(linalg.dot(d, v))}, id = id, prev = first + (i + len(ids) - 1) % len(ids), next = first + (i + 1) % len(ids)})
		}
		return first
	}
	start := add_ring(&nodes, positions, loop_verts[outer.first:][:outer.count], origin, u, v)

	// Holes join the outer ring rightmost first, each by a bridge from its rightmost
	// corner to a corner of the ring it can see along +u: holes further left lie wholly
	// left of it, so no bridge crosses one not joined yet.
	Hole_Start :: struct {
		node: int,
		x:    f64,
	}
	order := make([dynamic]Hole_Start, 0, len(holes), context.temp_allocator)
	for h in holes {
		first := add_ring(&nodes, positions, loop_verts[h.first:][:h.count], origin, u, v)
		best := first
		for k in first ..< first + h.count do if nodes[k].p.x > nodes[best].p.x do best = k
		append(&order, Hole_Start{best, nodes[best].p.x})
	}
	slice.sort_by(order[:], proc(a, b: Hole_Start) -> bool {return a.x > b.x})
	for h in order do bridge_hole(&nodes, start, h.node)

	// Clipping: walk the ring, cutting off ears (convex corners with no corner of the
	// ring inside them) until three are left.
	remaining := 1
	for k := nodes[start].next; k != start; k = nodes[k].next do remaining += 1
	// Only a reflex corner can lie inside an ear, and clipping never makes a corner
	// reflex, so the test looks at the corners that were reflex at the start.
	reflex := make([dynamic]int, 0, 64, context.temp_allocator)
	for j := start; true; /**/ {
		if cross2(nodes[nodes[j].prev].p, nodes[j].p, nodes[nodes[j].next].p) <= 0 do append(&reflex, j)
		j = nodes[j].next
		if j == start do break
	}
	k := start
	misses := 0
	for remaining > 3 {
		a, c := nodes[k].prev, nodes[k].next
		if is_ear(nodes[:], reflex[:], k) || misses > remaining {
			// A ring with no ear left (a degenerate one) still ends: the corner is cut
			// anyway, unless it is flat.
			if cross2(nodes[a].p, nodes[k].p, nodes[c].p) > 0 || misses > 2 * remaining {
				append(out, nodes[a].id, nodes[k].id, nodes[c].id)
			}
			nodes[a].next, nodes[c].prev = c, a
			nodes[k].gone = true
			remaining -= 1
			misses = 0
			k = c
			continue
		}
		misses += 1
		k = c
	}
	a, c := nodes[k].prev, nodes[k].next
	if cross2(nodes[a].p, nodes[k].p, nodes[c].p) > 0 do append(out, nodes[a].id, nodes[k].id, nodes[c].id)
}

@(private = "file")
is_ear :: proc(nodes: []Ear_Node, reflex: []int, k: int) -> bool {
	a, b, c := nodes[nodes[k].prev].p, nodes[k].p, nodes[nodes[k].next].p
	if cross2(a, b, c) <= 0 do return false
	lo := linalg.min(linalg.min(a, b), c)
	hi := linalg.max(linalg.max(a, b), c)
	for j in reflex {
		if nodes[j].gone || j == k || j == nodes[k].prev || j == nodes[k].next do continue
		p := nodes[j].p
		if p.x < lo.x || p.y < lo.y || p.x > hi.x || p.y > hi.y do continue
		// A corner at the same place as one of the ear's (a bridge's twin) is not in it.
		if p == a || p == b || p == c do continue
		if cross2(a, b, p) >= 0 && cross2(b, c, p) >= 0 && cross2(c, a, p) >= 0 do return false
	}
	return true
}

// Joins the hole ring through node `h` (its rightmost corner) to the ring through
// `start`: a ray from h along +x meets the nearest edge of the ring; the bridge goes to
// that edge's right end, or to the corner inside the triangle so made that is closest
// in angle to the ray, so nothing crosses it. Both ends are doubled so the ring runs out
// along the bridge, round the hole and back.
@(private = "file")
bridge_hole :: proc(nodes: ^[dynamic]Ear_Node, start, h: int) {
	hp := nodes[h].p
	best_x := max(f64)
	m := -1
	for k := start; true; /**/ {
		a, b := nodes[k].p, nodes[nodes[k].next].p
		if (a.y > hp.y) != (b.y > hp.y) || a.y == hp.y {
			if a.y != b.y {
				x := a.x + (hp.y - a.y) / (b.y - a.y) * (b.x - a.x)
				if x >= hp.x && x < best_x {
					best_x = x
					m = k if a.x > b.x else nodes[k].next
				}
			} else if a.y == hp.y && a.x >= hp.x && a.x < best_x {
				best_x, m = a.x, k
			}
		}
		k = nodes[k].next
		if k == start do break
	}
	if m < 0 do return // not inside after all: the hole is left out
	// Corners inside the triangle (hole corner, ray hit, m) would hide m: take the one
	// nearest the ray's direction instead.
	mp := nodes[m].p
	hit := [2]f64{best_x, hp.y}
	best_tan := max(f64)
	for k := start; true; /**/ {
		p := nodes[k].p
		if k != m && p.x >= hp.x && p != hp {
			t0, t1, t2 := hp, hit, mp
			if cross2(t0, t1, t2) < 0 do t1, t2 = t2, t1
			if cross2(t0, t1, p) >= 0 && cross2(t1, t2, p) >= 0 && cross2(t2, t0, p) >= 0 {
				tan := abs(p.y - hp.y) / max(p.x - hp.x, 1e-300)
				if tan < best_tan || (tan == best_tan && p.x > nodes[m].p.x) do best_tan, m = tan, k
			}
		}
		k = nodes[k].next
		if k == start do break
	}
	// m -> h ... (round the hole) ... h2 -> m2 -> m's old next.
	h2 := len(nodes)
	append(nodes, nodes[h])
	m2 := len(nodes)
	append(nodes, nodes[m])
	h_prev, m_next := nodes[h].prev, nodes[m].next
	nodes[m].next, nodes[h].prev = h, m
	nodes[h_prev].next, nodes[h2].prev = h2, h_prev
	nodes[h2].next, nodes[m2].prev = m2, h2
	nodes[m2].next, nodes[m_next].prev = m_next, m2
}

// Evens out a cap in place: splits inner edges longer than about `target`, flips to
// Delaunay triangles and smooths the inner vertices, new ones going into `extra` (cap
// triangle corners at or past len(positions) are in it). The cap's border is kept.
@(private = "file")
cap_even :: proc(positions: []Vec3, cap: ^[dynamic]u32, extra: ^[dynamic]Vec3, origin, u, v: Vec3, target: f64) {
	// The cap's own numbering: its corners, then the vertices splitting adds.
	local := make(map[u32]u32, len(cap) / 2 + 16, context.temp_allocator)
	ids := make([dynamic]u32, 0, len(cap) / 2 + 16, context.temp_allocator)
	pts := make([dynamic][2]f64, 0, len(cap) / 2 + 16, context.temp_allocator)
	tris := make([dynamic][3]u32, 0, len(cap) / 3, context.temp_allocator)
	for t := 0; t < len(cap); t += 3 {
		tri: [3]u32
		for c in 0 ..< 3 {
			g := cap[t + c]
			l, found := local[g]
			if !found {
				l = u32(len(ids))
				local[g] = l
				append(&ids, g)
				d := positions[g] - origin
				append(&pts, [2]f64{f64(linalg.dot(d, u)), f64(linalg.dot(d, v))})
			}
			tri[c] = l
		}
		append(&tris, tri)
	}
	corners := len(ids) // the cap's border and bridge corners, which never move
	// twin[3t + k]: the half-edge running the other way along tris[t]'s edge k (from
	// corner k to k + 1), or -1 on the border.
	twin := make([dynamic]i32, 3 * len(tris), context.temp_allocator)
	halves := make(map[u64]i32, 3 * len(tris), context.temp_allocator)
	for tri, t in tris do for k in 0 ..< 3 do halves[u64(tri[k]) << 32 | u64(tri[(k + 1) % 3])] = i32(3 * t + k)
	for tri, t in tris {
		for k in 0 ..< 3 {
			g, found := halves[u64(tri[(k + 1) % 3]) << 32 | u64(tri[k])]
			twin[3 * t + k] = g if found else -1
		}
	}
	corner :: #force_inline proc(tris: [][3]u32, h: i32) -> u32 {return tris[h / 3][h % 3]}
	len2 :: #force_inline proc(pts: [][2]f64, a, b: u32) -> f64 {d := pts[a] - pts[b]; return d.x * d.x + d.y * d.y}
	link :: #force_inline proc(twin: ^[dynamic]i32, a, b: i32) {
		if a >= 0 do twin[a] = b
		if b >= 0 do twin[b] = a
	}

	// Splits, by longest-edge bisection (Rivara): while a triangle has an inner edge
	// longer than it should be, follow its longest inner edge across to the neighbour,
	// and on while the neighbour's is longer still, then split the last edge, which is
	// the longest of both triangles beside it. Splitting an edge that is not its
	// neighbour's longest would thin that neighbour, and splits could then run on
	// without end. An edge should be no longer than the limit, or than 3/4 of the longest
	// border edge at either end: the border is never split, and a triangle on a border
	// edge always keeps another edge at least half as long.
	reach := make([dynamic]f64, len(pts), context.temp_allocator) // per corner: its longest border edge, squared
	for tri, t in tris {
		for k in 0 ..< 3 {
			if twin[3 * t + k] >= 0 do continue
			a, b := tri[k], tri[(k + 1) % 3]
			l := len2(pts[:], a, b)
			reach[a], reach[b] = max(reach[a], l), max(reach[b], l)
		}
	}
	limit2 := (1.4 * target) * (1.4 * target)
	longest_inner :: proc(pts: [][2]f64, tris: [][3]u32, twin: []i32, t: i32) -> (best: i32, best_len: f64) {
		best = -1
		for k in 0 ..< i32(3) {
			h := 3 * t + k
			if twin[h] < 0 do continue
			if l := len2(pts, tris[t][k], tris[t][(k + 1) % 3]); l > best_len do best, best_len = h, l
		}
		return
	}
	too_long :: proc(pts: [][2]f64, tris: [][3]u32, twin: []i32, reach: []f64, limit2: f64, t: int) -> bool {
		for k in 0 ..< 3 {
			if twin[3 * t + k] < 0 do continue
			a, b := tris[t][k], tris[t][(k + 1) % 3]
			if len2(pts, a, b) > max(limit2, 0.5625 * max(reach[a], reach[b])) do return true
		}
		return false
	}
	flip_all :: proc(pts: [][2]f64, tris: [][3]u32, twin: []i32) {
		stack := make([dynamic]i32, 0, len(twin), context.temp_allocator)
		for g, h in twin do if i32(h) < g do append(&stack, i32(h))
		flip_from(pts, tris, twin, &stack)
	}
	// Lawson's flips from the half-edges on `stack`: each is checked, and the four
	// around each flip go on it in turn. A flip only ever makes the triangulation more
	// Delaunay, so this ends; the count limit guards against ties going back and forth.
	flip_from :: proc(pts: [][2]f64, tris: [][3]u32, twin: []i32, stack: ^[dynamic]i32) {
		for budget := 16 * len(twin); len(stack) > 0 && budget > 0; budget -= 1 {
			h := pop(stack)
			g := twin[h]
			if g < 0 do continue
			t, w := h / 3, g / 3
			a, b, c := tris[t][h % 3], tris[t][(h + 1) % 3], tris[t][(h + 2) % 3]
			d := tris[w][(g + 2) % 3]
			// Delaunay: d outside the circle through a, b, c.
			pa, pb, pc := pts[a] - pts[d], pts[b] - pts[d], pts[c] - pts[d]
			det := (pa.x * pa.x + pa.y * pa.y) * (pb.x * pc.y - pc.x * pb.y) -
				(pb.x * pb.x + pb.y * pb.y) * (pa.x * pc.y - pc.x * pa.y) +
				(pc.x * pc.x + pc.y * pc.y) * (pa.x * pb.y - pb.x * pa.y)
			scale := linalg.length2(pts[a] - pts[b])
			if det <= 1e-12 * scale * scale do continue
			// Only a convex quad flips.
			if cross2(pts[c], pts[d], pts[a]) >= 0 || cross2(pts[c], pts[d], pts[b]) <= 0 do continue
			x_bc, x_ca := twin[3 * t + (h + 1) % 3], twin[3 * t + (h + 2) % 3]
			x_ad, x_db := twin[3 * w + (g + 1) % 3], twin[3 * w + (g + 2) % 3]
			// (a, b, c) and (b, a, d) become (a, d, c) and (d, b, c).
			tris[t] = {a, d, c}
			tris[w] = {d, b, c}
			set :: #force_inline proc(twin: []i32, x, y: i32) {
				if x >= 0 do twin[x] = y
				if y >= 0 do twin[y] = x
			}
			set(twin, 3 * t + 0, x_ad)
			set(twin, 3 * t + 1, 3 * w + 2)
			set(twin, 3 * t + 2, x_ca)
			set(twin, 3 * w + 0, x_db)
			set(twin, 3 * w + 1, x_bc)
			append(stack, 3 * t + 0, 3 * t + 2, 3 * w + 0, 3 * w + 1)
		}
	}
	// In rounds: one split per triangle that wants one, then flips back to Delaunay
	// around the splits, which keeps the triangles from thinning as the ear clipping's
	// fans are cut up.
	flip_all(pts[:], tris[:], twin[:])
	around := make([dynamic]i32, 0, 1024, context.temp_allocator)
	for _ in 0 ..< 64 {
		split := 0
		round := len(tris)
		for t in 0 ..< round {
			if len(tris) >= 2 * SLICE_CAP_MAX_TRIANGLES do break
			if !too_long(pts[:], tris[:], twin[:], reach[:], limit2, t) do continue
			split += 1
			best, best_len := longest_inner(pts[:], tris[:], twin[:], i32(t))
			for _ in 0 ..< 64 {
				next, next_len := longest_inner(pts[:], tris[:], twin[:], twin[best] / 3)
				if next == twin[best] || next_len <= best_len do break
				best, best_len = next, next_len
			}
			// Triangle (a, b, c) and its neighbour (b, a, d) across a-b become four around
			// the middle m: (a, m, c), (m, b, c), (b, m, d), (m, a, d).
			h, g := best, twin[best]
			tu, uu := h / 3, g / 3
			a, b, c := corner(tris[:], h), corner(tris[:], 3 * tu + (h + 1) % 3), corner(tris[:], 3 * tu + (h + 2) % 3)
			d := corner(tris[:], 3 * uu + (g + 2) % 3)
			x_bc, x_ca := twin[3 * tu + (h + 1) % 3], twin[3 * tu + (h + 2) % 3]
			x_ad, x_db := twin[3 * uu + (g + 1) % 3], twin[3 * uu + (g + 2) % 3]
			m := u32(len(pts))
			append(&pts, (pts[a] + pts[b]) / 2)
			append(&ids, max(u32))
			append(&reach, 0)
			t2, u2 := i32(len(tris)), i32(len(tris) + 1)
			tris[tu] = {a, m, c}
			tris[uu] = {b, m, d}
			append(&tris, [3]u32{m, b, c}, [3]u32{m, a, d})
			append(&twin, -1, -1, -1, -1, -1, -1)
			link(&twin, 3 * tu + 0, 3 * u2 + 0) // a-m
			link(&twin, 3 * t2 + 0, 3 * uu + 0) // m-b
			link(&twin, 3 * tu + 1, 3 * t2 + 2) // m-c
			link(&twin, 3 * uu + 1, 3 * u2 + 2) // m-d
			link(&twin, 3 * tu + 2, x_ca)
			link(&twin, 3 * t2 + 1, x_bc)
			link(&twin, 3 * uu + 2, x_db)
			link(&twin, 3 * u2 + 1, x_ad)
			append(&around, 3 * tu + 2, 3 * t2 + 1, 3 * uu + 2, 3 * u2 + 1)
		}
		flip_from(pts[:], tris[:], twin[:], &around)
		if split == 0 do break
	}

	// Smoothing: each inner vertex toward the middle of its neighbours, undone where a
	// triangle would turn over.
	sum := make([][2]f64, len(pts), context.temp_allocator)
	count := make([]u32, len(pts), context.temp_allocator)
	old := make([][2]f64, len(pts), context.temp_allocator)
	for _ in 0 ..< 2 {
		slice.zero(sum)
		slice.zero(count)
		for tri in tris {
			for k in 0 ..< 3 {
				x, y := tri[k], tri[(k + 1) % 3]
				sum[x] += pts[y]
				count[x] += 1
			}
		}
		copy(old, pts[:])
		for k in corners ..< len(pts) do if count[k] > 0 do pts[k] = sum[k] / f64(count[k])
		// Each pass puts back at least one vertex, and with all put back every triangle
		// faces the right way again, so this ends.
		for {
			bad := false
			for tri in tris {
				if cross2(pts[tri[0]], pts[tri[1]], pts[tri[2]]) > 0 do continue
				for c in tri do if int(c) >= corners && pts[c] != old[c] {pts[c] = old[c]; bad = true}
			}
			if !bad do break
		}
		flip_all(pts[:], tris[:], twin[:])
	}

	// Back to the mesh's numbering, new vertices on the plane.
	first := u32(len(positions) + len(extra))
	for k in corners ..< len(pts) {
		ids[k] = first + u32(k - corners)
		p := pts[k]
		append(extra, origin + u * f32(p.x) + v * f32(p.y))
	}
	clear(cap)
	for tri in tris do append(cap, ids[tri[0]], ids[tri[1]], ids[tri[2]])
}
