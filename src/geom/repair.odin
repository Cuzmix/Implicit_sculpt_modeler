package geom

import "core:math"
import "core:math/linalg"
import "core:slice"

import "../jobs"

// Mesh repair, the best of ZBrush's Close Holes, Weld Points and Check/Fix Mesh
// Integrity, Blender's Fill Holes, Merge by Distance and 3D print checks, and
// Meshmixer's Inspector: holes closed with caps as even as the surface around them that
// follow a border that is not flat, vertices closer than a distance welded, triangles
// with a repeated corner and duplicates dropped, triangles turned to agree with their
// neighbours and shells inside out turned the right way, and a report of what is wrong.
// Each makes a new mesh and says where each of its vertices and triangles came from
// (Repair_Map), so polypaint and polygroups can follow. All of it is serial or in
// fixed ranges, in the mesh's own order, so the result is the same on any thread count.

// A triangle a repair made rather than kept: its tri_from is REPAIR_NEW + k for the k-th
// patch (a hole's cap). A mesh never has 2^31 triangles.
REPAIR_NEW :: u32(1) << 31

// Where a repaired mesh's parts came from in the mesh it was made from.
Repair_Map :: struct {
	vertex_from: []u32, // per vertex: the old vertex it was or was welded into; a cap's new vertex, the border vertex nearest it by edges
	tri_from:    []u32, // per triangle: the old triangle it was, or REPAIR_NEW + the cap it is in
}

repair_map_destroy :: proc(r: ^Repair_Map, allocator := context.allocator) {
	delete(r.vertex_from, allocator)
	delete(r.tri_from, allocator)
	r^ = {}
}

// What a check found, beyond mesh_check's edges: the holes as loops, the pieces, and
// triangles and vertices that are there for nothing.
Mesh_Integrity :: struct {
	check:               Mesh_Report,
	holes:               int, // closed loops of border edges
	pieces:              int, // parts joined by edges
	duplicate_triangles: int, // triangles over the same three corners as an earlier one
	unused_vertices:     int, // vertices no triangle uses
}

// Whether the check found nothing to repair.
mesh_integrity_ok :: proc(r: Mesh_Integrity) -> bool {
	return mesh_report_ok(r.check) && r.duplicate_triangles == 0 && r.unused_vertices == 0
}

// Checks a mesh for what the repairs mend, with mesh_check's counts worked out in
// parallel from each vertex's triangles rather than by its sort (seconds at 5M
// vertices). It still takes a few passes over the mesh: a person's Check mesh, never
// per frame.
mesh_integrity :: proc(m: Mesh, pool: ^jobs.Pool) -> (r: Mesh_Integrity) {
	n := u32(len(m.positions))
	c := &r.check
	c.vertices = len(m.positions)
	c.triangles = len(m.indices) / 3
	c.bounds = AABB_EMPTY
	for p in m.positions {
		if math.is_nan(p.x) || math.is_nan(p.y) || math.is_nan(p.z) || math.is_inf(p.x) || math.is_inf(p.y) || math.is_inf(p.z) {
			c.nan_count += 1
		} else {
			aabb_grow(&c.bounds, p)
		}
	}
	// The sound triangles, as mesh_check counts edges over: corners in range and apart,
	// and some area (exactly none is what collapsed vertices give).
	sound := make([dynamic]u32, 0, len(m.indices), context.temp_allocator)
	used := make([]bool, n, context.temp_allocator)
	for t := 0; t + 2 < len(m.indices); t += 3 {
		a, b, k := m.indices[t], m.indices[t + 1], m.indices[t + 2]
		if a >= n || b >= n || k >= n {
			c.degenerate_triangles += 1
			continue
		}
		used[a], used[b], used[k] = true, true, true
		p0, p1, p2 := m.positions[a], m.positions[b], m.positions[k]
		if a == b || b == k || k == a || linalg.length2(linalg.cross(p1 - p0, p2 - p0)) == 0 {
			c.degenerate_triangles += 1
			continue
		}
		c.volume += f64(linalg.dot(p0, linalg.cross(p1, p2)))
		append(&sound, a, b, k)
	}
	c.volume /= 6
	for u in used do r.unused_vertices += int(!u)
	view := Mesh{positions = m.positions, indices = sound}
	faces := vertex_faces_build(view, pool, context.temp_allocator)
	edges := edge_counts(view, faces, pool)
	c.boundary_edges, c.inconsistent_edges, c.non_manifold_edges = edges[0], edges[1], edges[2]
	c.inverted = c.volume < 0
	c.closed = c.triangles > 0 && c.boundary_edges == 0 && c.inconsistent_edges == 0 && c.non_manifold_edges == 0

	keep := make([]bool, len(sound) / 3, context.temp_allocator)
	slice.fill(keep, true)
	r.duplicate_triangles = mark_duplicates(sound[:], keep, pool)
	_, loops := hole_loops(m.positions[:], border_edges(view, faces, pool))
	r.holes = len(loops)
	_, r.pieces = mesh_components(view, context.temp_allocator)
	return
}

// Each edge counted once, from its lower vertex's triangles in parallel ranges, as
// mesh_check sorts them: in one triangle (a border), in more than two, or in two that
// run it the same way.
@(private = "file")
edge_counts :: proc(m: Mesh, faces: Vertex_Faces, pool: ^jobs.Pool) -> (counts: [3]int) {
	Count :: struct {
		m:      Mesh,
		faces:  Vertex_Faces,
		counts: [][3]int, // per range
	}
	k := Count{m = m, faces = faces, counts = make([][3]int, (len(m.positions) + RANGE_GRAIN - 1) / RANGE_GRAIN, context.temp_allocator)}
	jobs.parallel_ranges(pool, len(m.positions), &k, proc(data: rawptr, lo, hi: int) {
		k := cast(^Count)data
		idx := k.m.indices[:]
		counts: [3]int
		for v in u32(lo) ..< u32(hi) {
			around := vertex_faces_of(k.faces, v)
			for f, i in around {
				for w in ([2]u32{corner_after(idx, f, v), corner_before(idx, f, v)}) {
					if w < v do continue
					// Only from the first triangle round v that has the edge.
					seen := false
					for g in around[:i] do seen ||= corner_after(idx, g, v) == w || corner_before(idx, g, v) == w
					if seen do continue
					forward, backward := 0, 0
					for g in around[i:] {
						forward += int(corner_after(idx, g, v) == w)
						backward += int(corner_before(idx, g, v) == w)
					}
					switch {
					case forward + backward == 1: counts[0] += 1
					case forward + backward > 2:  counts[2] += 1
					case forward != 1:            counts[1] += 1
					}
				}
			}
		}
		k.counts[lo / RANGE_GRAIN] = counts
	}, RANGE_GRAIN)
	for c in k.counts do counts += c
	return
}

// What Close holes did.
Close_Report :: struct {
	closed:    int, // holes capped
	left_open: int, // the largest, when it was asked to stay open
	fanned:    int, // caps made as a fan from the middle, since the hole folds over itself seen from any side
	spikes:    int, // border triangles the cap folded back over, taken out with their spike vertex
}

// Closes each hole of `m` (a loop of border edges) with a cap facing the way the surface
// around it does, all but the one with the longest border when `leave_largest` (a neck
// or a base kept open). The cap is ear clipped seen along the loop's own normal, then
// evened out to triangles about as long as the border's edges (slice.odin's cap_even),
// then raised off its plane as a membrane over the border's heights, so the cap of a
// hole in a curved part meets it without a step. Returns ok false, allocating nothing,
// when there is no hole to close.
mesh_close_holes :: proc(m: Mesh, leave_largest: bool, pool: ^jobs.Pool, allocator := context.allocator) -> (out: Mesh, from: Repair_Map, report: Close_Report, ok: bool) {
	n := len(m.positions)
	if n == 0 || len(m.indices) < 3 do return
	faces := vertex_faces_build(m, pool, context.temp_allocator)
	verts, loops := hole_loops(m.positions[:], border_edges(m, faces, pool))
	if len(loops) == 0 do return
	skip := -1
	if leave_largest {
		skip = 0
		for l, i in loops do if l.length > loops[skip].length do skip = i
		report.left_open = 1
	}
	extra := make([dynamic]Vec3, 0, 256, context.temp_allocator)
	extra_from := make([dynamic]u32, 0, 256, context.temp_allocator)
	caps := make([dynamic]u32, 0, 3 * len(verts), context.temp_allocator)
	cap_of := make([dynamic]u32, 0, len(verts), context.temp_allocator)
	tcount := len(m.indices) / 3
	keep := make([dynamic]bool, tcount, 2 * tcount, context.temp_allocator)
	slice.fill(keep[:], true)
	spiked := Spikes {
		idx   = m.indices[:],
		faces = faces,
		alive = keep[:],
		live  = make([]u32, n, context.temp_allocator),
	}
	for v in 0 ..< n do spiked.live[v] = u32(len(vertex_faces_of(faces, u32(v))))
	for l, i in loops {
		if i == skip do continue
		_, turn := loop_plane(m.positions[:], verts[l.first:][:l.count])
		loop := trim_spikes(m.positions[:], &spiked, verts[l.first:][:l.count], turn)
		report.spikes += l.count - len(loop)
		before := len(caps)
		if close_hole(m.positions[:], loop, l.length, &caps, &extra, &extra_from) do report.fanned += 1
		for _ in 0 ..< (len(caps) - before) / 3 do append(&cap_of, u32(report.closed))
		report.closed += 1
	}
	if report.closed == 0 do return

	positions := make([dynamic]Vec3, 0, n + len(extra), context.temp_allocator)
	append(&positions, ..m.positions[:])
	append(&positions, ..extra[:])
	indices := make([dynamic]u32, 0, len(m.indices) + len(caps), context.temp_allocator)
	append(&indices, ..m.indices[:])
	append(&indices, ..caps[:])
	// A cap can still lie over a triangle by the border with one over the same corners
	// facing the other way, a fin; both go.
	resize(&keep, len(indices) / 3)
	slice.fill(keep[tcount:], true)
	report.spikes += mark_duplicates(indices[:], keep[:], pool) / 2
	out, from = compact_mesh(positions[:], indices[:], keep[:], allocator)
	old := u32(len(m.indices) / 3)
	for &f in from.vertex_from do if int(f) >= n do f = extra_from[int(f) - n]
	for &f in from.tri_from do if f >= old do f = REPAIR_NEW + cap_of[f - old]
	return out, from, report, true
}

// What Weld points did.
Weld_Report :: struct {
	welded:              int, // vertices merged into an earlier one
	dropped_triangles:   int, // triangles left with a repeated corner
	duplicate_triangles: int, // triangles left over the same corners as another
}

// Welds each vertex of `m` to the earliest vertex no further than `distance` away that is
// not itself welded to another (exactly the same place when it is 0), keeping that
// vertex's place, as Blender's Merge by Distance does; then drops triangles left with a
// repeated corner, duplicates (keeping one, or none of a pair facing both ways, which
// is a fin with no inside) and vertices no triangle uses. Returns ok false, allocating
// nothing, when no vertex is that close to another.
mesh_weld_points :: proc(m: Mesh, distance: f32, pool: ^jobs.Pool, allocator := context.allocator) -> (out: Mesh, from: Repair_Map, report: Weld_Report, ok: bool) {
	n := len(m.positions)
	if n == 0 do return
	positions := m.positions[:]
	d := max(distance, 0)
	exact := !(d > 0)
	// Cells twice the distance across: a vertex's partners lie in the two cells on each
	// axis nearest it, eight in all. At distance 0 a cell is one exact place.
	size := 2 * d
	cell_of :: proc(p: Vec3, size: f32) -> (cell: [3]i64, upper: [3]bool) {
		for k in 0 ..< 3 {
			x := p[k] / size
			if !(abs(x) < 1e15) do continue // not finite, or too far to tell cells apart: cell 0
			f := math.floor(x)
			cell[k] = i64(f)
			upper[k] = x - f >= 0.5
		}
		return
	}
	cell_key :: proc(c: [3]i64) -> u32 {
		mask :: (u64(1) << 21) - 1
		return mix64(u64(c.x) & mask << 42 | u64(c.y) & mask << 21 | u64(c.z) & mask)
	}
	place_key :: proc(p: Vec3) -> u32 {
		bits: [3]u32
		for k in 0 ..< 3 {
			bits[k] = transmute(u32)p[k]
			if bits[k] == 0x8000_0000 do bits[k] = 0 // -0 is +0
		}
		return mix64(u64(bits.x) << 32 | u64(bits.y)) ~ mix64(u64(bits.z) * 0x9e37_79b9_7f4a_7c15)
	}
	keys := make([]u32, n, context.temp_allocator)
	order := make([]u32, n, context.temp_allocator)
	for p, v in positions {
		if exact {
			keys[v] = place_key(p)
		} else {
			c, _ := cell_of(p, size)
			keys[v] = cell_key(c)
		}
		order[v] = u32(v)
	}
	// Stable, so each run of a key lists its vertices in order.
	radix_sort_pairs(keys, order, 32, pool)
	table := run_table_build(keys)

	rep := make([]u32, n, context.temp_allocator)
	limit := d * d
	for p, v in positions {
		best := u32(v)
		lookups: [8]u32
		count := 1
		if exact {
			lookups[0] = place_key(p)
		} else {
			c, upper := cell_of(p, size)
			count = 0
			for k in 0 ..< 8 {
				q := c
				for axis in 0 ..< 3 do if k >> uint(axis) & 1 == 1 do q[axis] += 1 if upper[axis] else -1
				lookups[count] = cell_key(q)
				count += 1
			}
		}
		for key in lookups[:count] {
			for i := run_table_find(table, key); i < n && keys[i] == key; i += 1 {
				r := order[i]
				if r >= best do break
				if rep[r] != r do continue
				q := positions[r]
				if exact ? q == p : linalg.length2(q - p) <= limit {
					best = r
					break
				}
			}
		}
		rep[v] = best
		report.welded += int(best != u32(v))
	}
	if report.welded == 0 do return

	indices := make([]u32, len(m.indices), context.temp_allocator)
	for i, k in m.indices do indices[k] = rep[i]
	keep := make([]bool, len(indices) / 3, context.temp_allocator)
	report.dropped_triangles = mark_degenerate(indices, keep)
	report.duplicate_triangles = mark_duplicates(indices, keep, pool)
	out, from = compact_mesh(positions, indices, keep, allocator)
	return out, from, report, true
}

// What Fix mesh did.
Fix_Report :: struct {
	dropped_triangles:   int, // a repeated corner, a corner past the vertices or one not finite
	duplicate_triangles: int, // over the same corners as another (one kept, or none of a fin)
	flipped_triangles:   int, // turned to agree with their neighbours
	turned_shells:       int, // closed pieces that faced inward, turned outward whole
	dropped_vertices:    int, // vertices no triangle used
}

// Mends what keeps a mesh from being sound without moving any vertex: drops triangles
// with a repeated corner, an index past the vertices or a corner that is not finite, and
// duplicates; turns triangles to run each edge they share with one other triangle the
// other way from it, piece by piece, changing the fewer; turns each closed piece that
// faces inward the right way round; and drops vertices no triangle uses. Edges with more
// than two triangles stay (Weld points or a remesh is for those). Returns ok false,
// allocating nothing, when there is nothing to mend.
mesh_fix :: proc(m: Mesh, pool: ^jobs.Pool, allocator := context.allocator) -> (out: Mesh, from: Repair_Map, report: Fix_Report, ok: bool) {
	n := u32(len(m.positions))
	tcount := len(m.indices) / 3
	if n == 0 || tcount == 0 do return
	finite := make([]bool, n, context.temp_allocator)
	for p, v in m.positions do finite[v] = !(math.is_nan(p.x) || math.is_nan(p.y) || math.is_nan(p.z) || math.is_inf(p.x) || math.is_inf(p.y) || math.is_inf(p.z))
	keep := make([]bool, tcount, context.temp_allocator)
	for t in 0 ..< tcount {
		a, b, c := m.indices[3 * t], m.indices[3 * t + 1], m.indices[3 * t + 2]
		keep[t] = a < n && b < n && c < n && a != b && b != c && c != a && finite[a] && finite[b] && finite[c]
		report.dropped_triangles += int(!keep[t])
	}
	if report.dropped_triangles > 0 && report.dropped_triangles == tcount do return
	// The duplicates over what is left (mark_duplicates reads only kept triangles).
	report.duplicate_triangles = mark_duplicates(m.indices[:3 * tcount], keep, pool)

	// The sound triangles as a mesh of their own, to find each edge's neighbours.
	sound := make([dynamic]u32, 0, 3 * tcount, context.temp_allocator)
	sound_from := make([dynamic]u32, 0, tcount, context.temp_allocator)
	for t in 0 ..< tcount {
		if !keep[t] do continue
		append(&sound, m.indices[3 * t], m.indices[3 * t + 1], m.indices[3 * t + 2])
		append(&sound_from, u32(t))
	}
	report.flipped_triangles, report.turned_shells = orient(Mesh{positions = m.positions, indices = sound}, pool)

	used := make([]bool, n, context.temp_allocator)
	for i in sound do used[i] = true
	for u in used do report.dropped_vertices += int(!u)
	if report == {} do return
	all := make([]bool, len(sound) / 3, context.temp_allocator)
	slice.fill(all, true)
	out, from = compact_mesh(m.positions[:], sound[:], all, allocator)
	for &f in from.tri_from do f = sound_from[f]
	return out, from, report, true
}

// Turns triangles of `m` in place so that each edge two triangles share is run once each
// way, piece by piece from its first triangle, then turns a piece whole when that changes
// fewer of its triangles, or when it is closed and faces inward. Returns how many
// triangles end up turned, and how many closed pieces were turned outward.
@(private = "file")
orient :: proc(m: Mesh, pool: ^jobs.Pool) -> (flipped, turned: int) {
	tcount := len(m.indices) / 3
	if tcount == 0 do return
	idx := m.indices[:]
	faces := vertex_faces_build(m, pool, context.temp_allocator)
	flip := make([]i8, tcount, context.temp_allocator)
	slice.fill(flip, -1)
	piece := make([dynamic]u32, 0, 1024, context.temp_allocator)
	for seed in 0 ..< tcount {
		if flip[seed] >= 0 do continue
		clear(&piece)
		flip[seed] = 0
		append(&piece, u32(seed))
		closed := true
		for head := 0; head < len(piece); head += 1 {
			t := piece[head]
			for k in 0 ..< u32(3) {
				a, b := idx[3 * t + k], idx[3 * t + (k + 1) % 3]
				other := max(u32)
				count := 0
				for g in vertex_faces_of(faces, a) {
					if g == t do continue
					if corner_after(idx, g, a) == b || corner_before(idx, g, a) == b {
						other = g
						count += 1
					}
				}
				if count != 1 {
					closed = false
					continue
				}
				if flip[other] >= 0 do continue
				// The neighbour agrees when it runs the edge b to a.
				agrees := corner_before(idx, other, a) == b
				flip[other] = flip[t] if agrees else 1 - flip[t]
				append(&piece, other)
			}
		}
		turns := 0
		for t in piece do turns += int(flip[t])
		invert := 2 * turns > len(piece)
		inward := false
		if closed {
			volume: f64
			for t in piece {
				p0, p1, p2 := m.positions[idx[3 * t]], m.positions[idx[3 * t + 1]], m.positions[idx[3 * t + 2]]
				det := f64(linalg.dot(p0, linalg.cross(p1, p2)))
				volume += -det if (flip[t] == 1) != invert else det
			}
			if volume < 0 {
				invert = !invert
				inward = true
			}
		}
		for t in piece {
			if (flip[t] == 1) == invert do continue
			idx[3 * t + 1], idx[3 * t + 2] = idx[3 * t + 2], idx[3 * t + 1]
			flipped += 1
		}
		turned += int(inward)
	}
	return
}

// The corners after and before `v` in triangle `f`, going round it.
@(private = "file")
corner_after :: #force_inline proc(idx: []u32, f, v: u32) -> u32 {
	t := idx[3 * f:][:3]
	if t[0] == v do return t[1]
	if t[1] == v do return t[2]
	return t[0]
}

@(private = "file")
corner_before :: #force_inline proc(idx: []u32, f, v: u32) -> u32 {
	t := idx[3 * f:][:3]
	if t[0] == v do return t[2]
	if t[1] == v do return t[0]
	return t[1]
}

// A directed edge.
@(private = "file")
Edge :: struct {
	a, b: u32,
}

// The edges run by a triangle with no triangle running them the other way, from each
// vertex's triangles in parallel ranges, in vertex order.
@(private = "file")
border_edges :: proc(m: Mesh, faces: Vertex_Faces, pool: ^jobs.Pool) -> []Edge {
	Border :: struct {
		m:      Mesh,
		faces:  Vertex_Faces,
		counts: []int, // per range: how many, then where its edges start
		out:    []Edge,
		fill:   bool,
	}
	b := Border {
		m      = m,
		faces  = faces,
		counts = make([]int, (len(m.positions) + RANGE_GRAIN - 1) / RANGE_GRAIN, context.temp_allocator),
	}
	walk :: proc(data: rawptr, lo, hi: int) {
		b := cast(^Border)data
		idx := b.m.indices[:]
		at := b.counts[lo / RANGE_GRAIN] if b.fill else 0
		for v in u32(lo) ..< u32(hi) {
			around := vertex_faces_of(b.faces, v)
			next: for f in around {
				w := corner_after(idx, f, v)
				for g in around do if corner_before(idx, g, v) == w do continue next
				if b.fill do b.out[at] = {v, w}
				at += 1
			}
		}
		if !b.fill do b.counts[lo / RANGE_GRAIN] = at
	}
	jobs.parallel_ranges(pool, len(m.positions), &b, walk, RANGE_GRAIN)
	total := 0
	for &c in b.counts do c, total = total, total + c
	b.out = make([]Edge, total, context.temp_allocator)
	b.fill = true
	jobs.parallel_ranges(pool, len(m.positions), &b, walk, RANGE_GRAIN)
	return b.out
}

// A hole: `count` vertices from `first` in the loop list, in the order a cap runs them
// (against the border edges), and its border's length.
@(private = "file")
Hole :: struct {
	first, count: int,
	length:       f64,
}

// Joins border edges into loops, each run the other way (b to a), as a cap runs them; a
// vertex where two holes touch is passed through once by each. A run that does not
// close (where triangles disagree on the way round) is left out.
@(private = "file")
hole_loops :: proc(positions: []Vec3, border: []Edge) -> (verts: [dynamic]u32, holes: [dynamic]Hole) {
	verts = make([dynamic]u32, 0, len(border), context.temp_allocator)
	holes = make([dynamic]Hole, 0, 16, context.temp_allocator)
	if len(border) < 3 do return
	slice.sort_by(border, proc(x, y: Edge) -> bool {return x.b < y.b || (x.b == y.b && x.a < y.a)})
	used := make([]bool, len(border), context.temp_allocator)
	ending :: proc(border: []Edge, used: []bool, v: u32) -> int {
		i, _ := slice.binary_search_by(border, v, proc(e: Edge, v: u32) -> slice.Ordering {
			return .Less if e.b < v else .Greater
		})
		for ; i < len(border) && border[i].b == v; i += 1 do if !used[i] do return i
		return -1
	}
	for start in 0 ..< len(border) {
		if used[start] do continue
		first := len(verts)
		length: f64
		closed := false
		e := start
		for _ in 0 ..= len(border) {
			used[e] = true
			append(&verts, border[e].b)
			length += f64(linalg.length(positions[border[e].a] - positions[border[e].b]))
			next := border[e].a
			if next == border[start].b {
				closed = true
				break
			}
			e = ending(border, used, next)
			if e < 0 do break
		}
		count := len(verts) - first
		if !closed || count < 3 {
			resize(&verts, first)
			continue
		}
		append(&holes, Hole{first, count, length})
	}
	return
}

// Caps one hole, appending its triangles to `caps` and its new vertices to `extra` (with
// their colour's border vertex in `extra_from`), numbered after `positions`. Returns
// true when it had to fan the cap from the middle.
@(private = "file")
close_hole :: proc(positions: []Vec3, loop: []u32, length: f64, caps: ^[dynamic]u32, extra: ^[dynamic]Vec3, extra_from: ^[dynamic]u32) -> (fanned: bool) {
	count := len(loop)
	if count == 3 {
		append(caps, loop[0], loop[1], loop[2])
		return
	}
	origin, normal := loop_plane(positions, loop)
	fan :: proc(positions: []Vec3, loop: []u32, origin: Vec3, caps: ^[dynamic]u32, extra: ^[dynamic]Vec3, extra_from: ^[dynamic]u32) {
		centre := u32(len(positions) + len(extra))
		append(extra, origin)
		append(extra_from, loop[0])
		for i in 0 ..< len(loop) do append(caps, loop[i], loop[(i + 1) % len(loop)], centre)
	}
	if !(linalg.length2(normal) > 0) {
		fan(positions, loop, origin, caps, extra, extra_from)
		return true
	}
	normal = linalg.normalize(normal)
	// A plane basis in which the loop runs counter-clockwise: u × v = normal.
	u := linalg.normalize(linalg.cross(normal, Vec3{1, 0, 0} if abs(normal.x) < 0.9 else Vec3{0, 1, 0}))
	v := linalg.cross(normal, u)
	flat := make([][2]f64, count, context.temp_allocator)
	for id, i in loop {
		d := positions[id] - origin
		flat[i] = {f64(linalg.dot(d, u)), f64(linalg.dot(d, v))}
	}
	if !loop_simple(flat) {
		fan(positions, loop, origin, caps, extra, extra_from)
		return true
	}
	area: f64
	for i in 0 ..< count do area += flat[i].x * flat[(i + 1) % count].y - flat[(i + 1) % count].x * flat[i].y
	area /= 2
	cap := make([dynamic]u32, 0, 3 * count, context.temp_allocator)
	ear_clip(positions, loop, Hole{0, count, length}, []Hole{}, origin, u, v, &cap)
	target := max(length / f64(count), math.sqrt(max(area, 0) / (0.433 * SLICE_CAP_MAX_TRIANGLES)))
	first_new := len(positions) + len(extra)
	if target > 0 do cap_even(positions, &cap, extra, origin, u, v, target)
	resize(extra_from, len(extra))
	cap_settle(positions, cap[:], extra[:], extra_from[:], first_new, origin, normal)
	append(caps, ..cap[:])
	return
}

// A loop's middle, and the normal it turns about (Newell's, as long as twice the area it
// encloses seen along it), summed from its first corner for precision.
@(private = "file")
loop_plane :: proc(positions: []Vec3, loop: []u32) -> (middle, turn: Vec3) {
	base := positions[loop[0]]
	sum, cross: [3]f64
	for i in 0 ..< len(loop) {
		p := positions[loop[i]] - base
		q := positions[loop[(i + 1) % len(loop)]] - base
		sum += {f64(p.x), f64(p.y), f64(p.z)}
		c := linalg.cross(p, q)
		cross += {f64(c.x), f64(c.y), f64(c.z)}
	}
	middle = base + Vec3{f32(sum.x), f32(sum.y), f32(sum.z)} / f32(len(loop))
	turn = Vec3{f32(cross.x), f32(cross.y), f32(cross.z)}
	return
}

// The mesh's triangles as Close holes takes spikes off it: which are still there, and how
// many each vertex is still in.
@(private = "file")
Spikes :: struct {
	idx:   []u32,
	faces: Vertex_Faces,
	alive: []bool,
	live:  []u32,
}

// Takes spikes off a hole's border: a border vertex in one triangle only, whose other two
// corners are its neighbours along the loop, where that triangle faces away from the
// way the hole is seen (`turn`). Seen along it, such a triangle is an ear the cap would
// cover with one over the same corners facing the other way (a fin with no inside);
// instead it goes, its vertex with it, and the loop runs straight past. Its neighbours
// can become spikes in turn. Returns the loop left (temp memory).
@(private = "file")
trim_spikes :: proc(positions: []Vec3, s: ^Spikes, loop: []u32, turn: Vec3) -> []u32 {
	count := len(loop)
	prev := make([]int, count, context.temp_allocator)
	next := make([]int, count, context.temp_allocator)
	gone := make([]bool, count, context.temp_allocator)
	for i in 0 ..< count do prev[i], next[i] = (i + count - 1) % count, (i + 1) % count
	stack := make([dynamic]int, 0, count, context.temp_allocator)
	for i := count - 1; i >= 0; i -= 1 do append(&stack, i)
	left := count
	for len(stack) > 0 && left > 3 {
		i := pop(&stack)
		b := loop[i]
		if gone[i] || s.live[b] != 1 do continue
		t := max(u32)
		for f in vertex_faces_of(s.faces, b) do if s.alive[f] do t = f
		a, c := loop[prev[i]], loop[next[i]]
		after, before := corner_after(s.idx, t, b), corner_before(s.idx, t, b)
		if !((after == a && before == c) || (after == c && before == a)) do continue
		p0, p1, p2 := positions[s.idx[3 * t]], positions[s.idx[3 * t + 1]], positions[s.idx[3 * t + 2]]
		if linalg.dot(linalg.cross(p1 - p0, p2 - p0), turn) >= 0 do continue
		s.alive[t] = false
		for k in 0 ..< u32(3) do s.live[s.idx[3 * t + k]] -= 1
		gone[i] = true
		next[prev[i]], prev[next[i]] = next[i], prev[i]
		left -= 1
		append(&stack, prev[i], next[i])
	}
	if left == count do return loop
	out := make([]u32, left, context.temp_allocator)
	k := 0
	for i in 0 ..< count {
		if gone[i] do continue
		out[k] = loop[i]
		k += 1
	}
	return out
}

// Raises a cap's new vertices (numbered from `first_new`, on the plane through `origin`
// across `normal`) off the plane to a membrane over the border's heights, each the mean
// of its neighbours' (over-relaxed Gauss-Seidel, in a fixed order), and gives each the
// border vertex nearest it by edges as where its colour comes from.
@(private = "file")
cap_settle :: proc(positions: []Vec3, cap: []u32, extra: []Vec3, extra_from: []u32, first_new: int, origin, normal: Vec3) {
	n := len(positions)
	place :: #force_inline proc(positions, extra: []Vec3, g: u32) -> Vec3 {
		return positions[g] if int(g) < len(positions) else extra[int(g) - len(positions)]
	}
	// The cap's own numbering, and each vertex's neighbours (an inner edge twice, once
	// from each triangle beside it, which weighs every inner edge alike).
	local := make(map[u32]u32, len(cap) / 2 + 16, context.temp_allocator)
	ids := make([dynamic]u32, 0, len(cap) / 2 + 16, context.temp_allocator)
	for g in cap {
		if g in local do continue
		local[g] = u32(len(ids))
		append(&ids, g)
	}
	count := len(ids)
	starts := make([]u32, count + 1, context.temp_allocator)
	for t := 0; t < len(cap); t += 3 {
		for k in 0 ..< 3 {
			starts[local[cap[t + k]] + 1] += 1
			starts[local[cap[t + (k + 1) % 3]] + 1] += 1
		}
	}
	for i in 0 ..< count do starts[i + 1] += starts[i]
	near := make([]u32, starts[count], context.temp_allocator)
	cursor := slice.clone(starts[:count], context.temp_allocator)
	for t := 0; t < len(cap); t += 3 {
		for k in 0 ..< 3 {
			a, b := local[cap[t + k]], local[cap[t + (k + 1) % 3]]
			near[cursor[a]] = b
			cursor[a] += 1
			near[cursor[b]] = a
			cursor[b] += 1
		}
	}
	fixed :: #force_inline proc(ids: []u32, first_new: int, i: int) -> bool {return int(ids[i]) < first_new}

	// Heights over the plane: the border's are where it is, the new ones start at their
	// mean and settle.
	height := make([]f64, count, context.temp_allocator)
	mean, spread, reach: f64
	borders, inner := 0, 0
	for i in 0 ..< count {
		if !fixed(ids[:], first_new, i) {
			inner += 1
			continue
		}
		d := place(positions, extra, ids[i]) - origin
		height[i] = f64(linalg.dot(d, normal))
		mean += height[i]
		spread = max(spread, abs(height[i]))
		reach = max(reach, f64(linalg.length(d)))
		borders += 1
	}
	if inner == 0 do return
	mean /= f64(max(borders, 1))
	for i in 0 ..< count do if !fixed(ids[:], first_new, i) do height[i] = mean
	if spread > 1e-6 * reach {
		side := math.sqrt(f64(inner))
		omega := 2 / (1 + math.sin(math.PI / (side + 1)))
		// A ten-thousandth of the border's own rise is far below what can be seen.
		tolerance := 1e-4 * spread
		for _ in 0 ..< 10 * int(side) + 100 {
			most: f64
			for i in 0 ..< count {
				if fixed(ids[:], first_new, i) do continue
				sum: f64
				for j in near[starts[i]:starts[i + 1]] do sum += height[j]
				step := omega * (sum / f64(starts[i + 1] - starts[i]) - height[i])
				height[i] += step
				most = max(most, abs(step))
			}
			if most < tolerance do break
		}
		for i in 0 ..< count do if !fixed(ids[:], first_new, i) do extra[int(ids[i]) - n] += normal * f32(height[i])
	}

	// Colours: breadth first from the border, in its order.
	source := make([]u32, count, context.temp_allocator)
	slice.fill(source, max(u32))
	queue := make([dynamic]u32, 0, count, context.temp_allocator)
	for i in 0 ..< count {
		if !fixed(ids[:], first_new, i) do continue
		source[i] = ids[i]
		append(&queue, u32(i))
	}
	for head := 0; head < len(queue); head += 1 {
		i := queue[head]
		for j in near[starts[i]:starts[i + 1]] {
			if source[j] != max(u32) do continue
			source[j] = source[i]
			append(&queue, j)
		}
	}
	for i in 0 ..< count {
		if fixed(ids[:], first_new, i) do continue
		extra_from[int(ids[i]) - n] = source[i] if source[i] != max(u32) else ids[0]
	}
}

// Whether a loop seen flat crosses itself nowhere. Its edges go into a grid of about as
// many cells as it has corners, and only edges sharing a cell are compared.
@(private = "file")
loop_simple :: proc(pts: [][2]f64) -> bool {
	count := len(pts)
	lo, hi := pts[0], pts[0]
	for p in pts do lo, hi = linalg.min(lo, p), linalg.max(hi, p)
	extent := hi - lo
	if !(extent.x > 0) || !(extent.y > 0) do return false
	side := max(1, int(math.sqrt(f64(count))))
	cell := extent / f64(side)
	span :: proc(a, b, lo, cell: f64, side: int) -> (int, int) {
		i := clamp(int((min(a, b) - lo) / cell), 0, side - 1)
		j := clamp(int((max(a, b) - lo) / cell), 0, side - 1)
		return i, j
	}
	starts := make([]int, side * side + 1, context.temp_allocator)
	for pass in 0 ..< 2 {
		if pass == 1 {
			for c in 0 ..< side * side do starts[c + 1] += starts[c]
		}
		cursor := slice.clone(starts[:side * side], context.temp_allocator) if pass == 1 else nil
		list := make([]u32, starts[side * side], context.temp_allocator) if pass == 1 else nil
		for i in 0 ..< count {
			a, b := pts[i], pts[(i + 1) % count]
			x0, x1 := span(a.x, b.x, lo.x, cell.x, side)
			y0, y1 := span(a.y, b.y, lo.y, cell.y, side)
			for y in y0 ..= y1 do for x in x0 ..= x1 {
				c := y * side + x
				if pass == 0 {
					starts[c + 1] += 1
				} else {
					list[cursor[c]] = u32(i)
					cursor[c] += 1
				}
			}
		}
		if pass == 0 do continue
		for c in 0 ..< side * side {
			in_cell := list[starts[c]:starts[c + 1]]
			for i, k in in_cell do for j in in_cell[k + 1:] {
				lo_i, hi_i := min(i, j), max(i, j)
				if hi_i == lo_i + 1 || (lo_i == 0 && int(hi_i) == count - 1) do continue
				a, b := pts[lo_i], pts[(int(lo_i) + 1) % count]
				p, q := pts[hi_i], pts[(int(hi_i) + 1) % count]
				o1, o2 := cross2(a, b, p), cross2(a, b, q)
				o3, o4 := cross2(p, q, a), cross2(p, q, b)
				if o1 * o2 < 0 && o3 * o4 < 0 do return false
			}
		}
	}
	return true
}

// Marks triangles with a repeated corner as not kept; returns how many.
@(private = "file")
mark_degenerate :: proc(indices: []u32, keep: []bool) -> (dropped: int) {
	for t in 0 ..< len(indices) / 3 {
		a, b, c := indices[3 * t], indices[3 * t + 1], indices[3 * t + 2]
		keep[t] = a != b && b != c && c != a
		dropped += int(!keep[t])
	}
	return
}

// Among the kept triangles, marks each over the same three corners as an earlier one
// facing the same way as not kept, and all of them when they face both ways (a fin with
// no inside); returns how many were marked.
@(private = "file")
mark_duplicates :: proc(indices: []u32, keep: []bool, pool: ^jobs.Pool) -> (dropped: int) {
	sorted :: #force_inline proc(indices: []u32, t: u32) -> [3]u32 {
		a, b, c := indices[3 * t], indices[3 * t + 1], indices[3 * t + 2]
		if a > b do a, b = b, a
		if b > c do b, c = c, b
		if a > b do a, b = b, a
		return {a, b, c}
	}
	// Whether the triangle runs its corners in the order of the sorted three.
	even :: #force_inline proc(indices: []u32, t: u32, s: [3]u32) -> bool {
		a, b := indices[3 * t], indices[3 * t + 1]
		return (a == s[0] && b == s[1]) || (a == s[1] && b == s[2]) || (a == s[2] && b == s[0])
	}
	keys := make([dynamic]u32, 0, len(keep), context.temp_allocator)
	tris := make([dynamic]u32, 0, len(keep), context.temp_allocator)
	for k, t in keep {
		if !k do continue
		s := sorted(indices, u32(t))
		append(&keys, mix64(u64(s[0]) << 32 | u64(s[1])) ~ mix64(u64(s[2]) * 0x9e37_79b9_7f4a_7c15))
		append(&tris, u32(t))
	}
	// Stable, so a run lists its triangles in order.
	radix_sort_pairs(keys[:], tris[:], 32, pool)
	handled := make([]bool, len(keys), context.temp_allocator)
	group := make([dynamic]u32, 0, 8, context.temp_allocator)
	for lo := 0; lo < len(keys); {
		hi := lo + 1
		for hi < len(keys) && keys[hi] == keys[lo] do hi += 1
		for i in lo ..< hi {
			if hi - lo == 1 || handled[i] do continue
			s := sorted(indices, tris[i])
			clear(&group)
			append(&group, tris[i])
			for j in i + 1 ..< hi {
				if handled[j] || sorted(indices, tris[j]) != s do continue
				handled[j] = true
				append(&group, tris[j])
			}
			if len(group) == 1 do continue
			both := false
			for t in group[1:] do both ||= even(indices, t, s) != even(indices, group[0], s)
			for t, k in group {
				if k == 0 && !both do continue
				keep[t] = false
				dropped += 1
			}
		}
		lo = hi
	}
	return
}

// The kept triangles of `indices` over `positions` as a mesh of their own with the
// vertices they use, in order, and where each came from.
@(private)
compact_mesh :: proc(positions: []Vec3, indices: []u32, keep: []bool, allocator := context.allocator) -> (out: Mesh, from: Repair_Map) {
	new_of := make([]u32, len(positions), context.temp_allocator)
	slice.fill(new_of, max(u32))
	kept := 0
	for k, t in keep {
		if !k do continue
		kept += 1
		for c in 0 ..< 3 do new_of[indices[3 * t + c]] = 0
	}
	used: u32
	for &k in new_of {
		if k == max(u32) do continue
		k = used
		used += 1
	}
	out = Mesh {
		positions = make([dynamic]Vec3, used, allocator),
		normals   = make([dynamic]Vec3, used, allocator),
		indices   = make([dynamic]u32, 0, 3 * kept, allocator),
	}
	from.vertex_from = make([]u32, used, allocator)
	from.tri_from = make([]u32, kept, allocator)
	for k, v in new_of {
		if k == max(u32) do continue
		out.positions[k] = positions[v]
		from.vertex_from[k] = u32(v)
	}
	for k, t in keep {
		if !k do continue
		from.tri_from[len(out.indices) / 3] = u32(t)
		append(&out.indices, new_of[indices[3 * t]], new_of[indices[3 * t + 1]], new_of[indices[3 * t + 2]])
	}
	return
}

// 64 bits mixed into 32 (the finaliser of MurmurHash3), so the radix sort's low bits
// spread.
@(private = "file")
mix64 :: #force_inline proc(x: u64) -> u32 {
	x := x
	x ~= x >> 33
	x *= 0xff51_afd7_ed55_8ccd
	x ~= x >> 33
	x *= 0xc4ce_b9fe_1a85_ec53
	x ~= x >> 33
	return u32(x)
}

// Where each run of equal keys in a sorted key list starts, by key: open addressing,
// the keys being mixed already.
@(private = "file")
Run_Table :: struct {
	keys:   []u32,
	starts: []u32, // max(u32) for an empty slot
	mask:   u32,
}

@(private = "file")
run_table_build :: proc(sorted: []u32) -> (t: Run_Table) {
	runs := 0
	for k, i in sorted do runs += int(i == 0 || k != sorted[i - 1])
	size := 16
	for size < 2 * runs do size *= 2
	t.keys = make([]u32, size, context.temp_allocator)
	t.starts = make([]u32, size, context.temp_allocator)
	t.mask = u32(size - 1)
	slice.fill(t.starts, max(u32))
	for k, i in sorted {
		if i > 0 && k == sorted[i - 1] do continue
		slot := k & t.mask
		for t.starts[slot] != max(u32) do slot = (slot + 1) & t.mask
		t.keys[slot], t.starts[slot] = k, u32(i)
	}
	return
}

// The first place of `key` in the sorted list, or max(int) when it is not there.
@(private = "file")
run_table_find :: proc(t: Run_Table, key: u32) -> int {
	for slot := key & t.mask; t.starts[slot] != max(u32); slot = (slot + 1) & t.mask {
		if t.keys[slot] == key do return int(t.starts[slot])
	}
	return max(int)
}
