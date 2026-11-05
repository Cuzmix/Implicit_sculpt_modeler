package quadmesh

import "base:runtime"
import pq "core:container/priority_queue"
import "core:math"
import "core:slice"

// Freeze border (Params.frozen), as ZRemesher's FreezeBorder: a border whose vertices are
// marked comes back with the same vertices, where they were, one quad edge between each
// two, so the result welds back onto what it was cut from. ZBrush's own note on it says
// the border comes first and the count second, and so here. Each stage keeps it: the
// thinning leaves an open edge as it is anyway; the isotropic edge is graded from the
// border's edge length to the quad size (frozen_grade), and the remesh neither splits nor
// collapses a frozen edge nor moves its vertices (FROZEN); the quad size the field and the
// cover take is graded the same way on the isotropic mesh (frozen_band), and again for
// each of the landing's covers at its own scaling (frozen_regrade), so the quads beside
// the border are its edges' size whatever the landing does to the rest; the cover puts
// each frozen vertex on a point of the lattice and asks one step along the line from each
// to the next, firmly (cover_energy), its triangle's stretch along it held at one step
// through the curl correction; and the landing keeps the cover whose border edges are
// most often one step each (frozen_misses), stopping where the border holds the count.
// What the cover could not give (a border of an odd number of edges, a run whose steps
// came out two or none) is mended on the quads (frozen_mend): a missing vertex goes into
// the border edge where it belongs and a vertex the border does not have comes out of it,
// the polygon that grows cut back into quads, and a triangle where the sides are odd; a
// vertex that cannot come out is filled over. A border much finer or coarser than the
// quads asked sets the count near it: the field makes few of the pole pairs a fast change
// of size needs, so the rings beside the border keep its count.

// How fast the quad size may change away from a frozen border, per length: a quad of size
// s has a neighbour of at most 1.15 s. A faster change asks pole pairs the field makes few
// of, and the cover then squeezed the border into steps of none (0.35 gave a disc of 96
// border edges at 400 quads 30 triangles, 0.15 gives 8); a slower one asks many more
// quads than the count (0.05 gave the disc 572).
@(private = "file")
FROZEN_GRADE :: 0.15

// How far, as a share of the shorter of its border edges, an extracted vertex may lie
// from a frozen vertex and still be taken for it.
@(private = "file")
FROZEN_REACH :: 0.3

// The most border edges a run between two matched vertices may span, on either side,
// before it is taken for something other than a stretch of the frozen border (a
// symmetric half's cut, which runs from one end of a frozen border to the other).
@(private = "file")
FROZEN_RUN_MAX :: 16

// The frozen border of an island: its vertices, each with the next along the border as
// its triangles run (NONE at the end of a frozen run), the length wanted of the quads'
// edges there (the mean of its frozen edges') and how far an extracted vertex may lie
// from it and still be it.
Frozen_Border :: struct {
	points: [][3]f64,
	vertex: []u32, // the island's vertex each point is
	next:   []u32,
	length: []f64,
	reach:  []f64,
}

frozen_border_destroy :: proc(b: ^Frozen_Border) {
	heap := runtime.heap_allocator()
	delete(b.points, heap)
	delete(b.vertex, heap)
	delete(b.next, heap)
	delete(b.length, heap)
	delete(b.reach, heap)
	b^ = {}
}

// The island's frozen border: its edges of one triangle whose two ends are frozen, as
// the triangles run. Empty when nothing is frozen.
frozen_border :: proc(island: Island) -> (b: Frozen_Border) {
	n := len(island.positions)
	if len(island.frozen) != n do return
	heap := runtime.heap_allocator()
	Directed :: struct {
		key:  u64,
		a, b: u32,
	}
	candidates := make([dynamic]Directed, heap)
	defer delete(candidates)
	for t in island.triangles do for k in 0 ..< 3 {
		a, c := t[k], t[(k + 1) % 3]
		if a == c || int(a) >= n || int(c) >= n || !island.frozen[a] || !island.frozen[c] do continue
		append(&candidates, Directed{edge_key(a, c), a, c})
	}
	slice.sort_by(candidates[:], proc(x, y: Directed) -> bool {return x.key < y.key || (x.key == y.key && x.a < y.a)})
	index := make([]u32, n, heap)
	defer delete(index, heap)
	for &i in index do i = NONE
	points := make([dynamic][3]f64, heap)
	vertex := make([dynamic]u32, heap)
	edges := make([dynamic][2]u32, heap)
	defer delete(edges)
	point :: proc(v: u32, island: Island, index: []u32, points: ^[dynamic][3]f64, vertex: ^[dynamic]u32) -> u32 {
		if index[v] == NONE {
			index[v] = u32(len(points))
			append(points, island.positions[v])
			append(vertex, v)
		}
		return index[v]
	}
	for i := 0; i < len(candidates); {
		j := i + 1
		for j < len(candidates) && candidates[j].key == candidates[i].key do j += 1
		if j - i == 1 {
			e := candidates[i]
			append(&edges, [2]u32{point(e.a, island, index, &points, &vertex), point(e.b, island, index, &points, &vertex)})
		}
		i = j
	}
	if len(edges) == 0 {
		delete(points)
		delete(vertex)
		return
	}
	b.points = points[:]
	b.vertex = vertex[:]
	b.next = make([]u32, len(points), heap)
	b.length = make([]f64, len(points), heap)
	b.reach = make([]f64, len(points), heap)
	count := make([]int, len(points), heap)
	defer delete(count, heap)
	for &x in b.next do x = NONE
	for &r in b.reach do r = math.F64_MAX
	for e in edges {
		b.next[e[0]] = e[1]
		l := length3(b.points[e[1]] - b.points[e[0]])
		for p in e {
			b.length[p] += l
			count[p] += 1
			b.reach[p] = min(b.reach[p], FROZEN_REACH * l)
		}
	}
	for &l, p in b.length do l /= f64(max(1, count[p]))
	return
}

// The quad size graded from a frozen border: `asked` where no border is near, and toward
// the border's edge length `length` as the border comes near, changing by at most
// FROZEN_GRADE per length along the surface (`distance` from the nearest border vertex).
@(private = "file")
frozen_graded :: #force_inline proc(asked, distance, length: f64) -> f64 {
	if distance == math.F64_MAX do return asked
	limit := FROZEN_GRADE * distance
	return length + clamp(asked - length, -limit, limit)
}

// A front over the triangles' edges from every vertex whose distance is 0 at once: each
// other vertex gets its distance along the edges from the nearest of them and that one's
// length (left at math.F64_MAX where no front reaches).
@(private = "file")
frozen_front :: proc(positions: [][3]f64, triangles: [][3]u32, distance, length: []f64) {
	n := len(positions)
	heap := runtime.heap_allocator()
	first := make([]u32, n + 1, heap)
	defer delete(first, heap)
	for t in triangles do for v in t do first[v + 1] += 2
	for v in 0 ..< n do first[v + 1] += first[v]
	ring := make([]u32, first[n], heap)
	defer delete(ring, heap)
	at := make([]u32, n, heap)
	defer delete(at, heap)
	copy(at, first[:n])
	for t in triangles do for k in 0 ..< 3 {
		v := t[k]
		ring[at[v]], ring[at[v] + 1] = t[(k + 1) % 3], t[(k + 2) % 3]
		at[v] += 2
	}
	Item :: struct {
		d: f64,
		v: u32,
	}
	queue: pq.Priority_Queue(Item)
	pq.init(&queue, proc(a, b: Item) -> bool {return a.d < b.d || (a.d == b.d && a.v < b.v)}, pq.default_swap_proc(Item), allocator = heap)
	defer pq.destroy(&queue)
	for d, v in distance do if d == 0 do pq.push(&queue, Item{0, u32(v)})
	for pq.len(queue) > 0 {
		item := pq.pop(&queue)
		v := item.v
		if item.d > distance[v] do continue
		for u in ring[first[v]:first[v + 1]] {
			d := item.d + length3(positions[u] - positions[v])
			if d >= distance[u] do continue
			distance[u], length[u] = d, length[v]
			pq.push(&queue, Item{d, u})
		}
	}
}

// The island's isotropic edge graded from its frozen border (Island.refine): the quad size
// at a vertex runs from the border's edge length at the nearest border vertex toward the
// size the density asks (frozen_graded), so the isotropic mesh is as fine as the border
// beside it and as the quads grow away from it. The size away from the border, `away`, is
// found so the island still asks `cells` quads in all; where the border's quads alone come
// to more, it is the island's own and those are asked instead. Returns the quads asked and
// `away`, which the band takes on to the isotropic mesh (frozen_band).
frozen_grade :: proc(island: ^Island, border: Frozen_Border, quad_edge, cells: f64) -> (asked, away: f64) {
	n := len(island.positions)
	asked, away = cells, quad_edge
	if len(border.points) == 0 || !(quad_edge > 0) do return
	heap := runtime.heap_allocator()
	// Each vertex's share of the area: a third of each of its triangles'.
	area := make([]f64, n, heap)
	defer delete(area, heap)
	for t in island.triangles {
		a := triangle_area(island.positions[t[0]], island.positions[t[1]], island.positions[t[2]]) / 3
		for v in t do area[v] += a
	}
	distance := make([]f64, n, heap)
	defer delete(distance, heap)
	length := make([]f64, n, heap)
	defer delete(length, heap)
	for &d in distance do d = math.F64_MAX
	for v, p in border.vertex do distance[v], length[v] = 0, border.length[p]
	frozen_front(island.positions, island.triangles, distance, length)
	// The quad size the density asks at v against the island's own (1 without a density).
	base :: #force_inline proc(island: ^Island, v: int) -> f64 {
		return 1 / math.sqrt(max(island.density[v], 1e-6)) if len(island.density) == len(island.positions) else 1
	}
	count :: proc(island: ^Island, distance, length, area: []f64, away: f64) -> f64 {
		total := f64(0)
		for a, v in area {
			q := frozen_graded(away * base(island, v), distance[v], length[v])
			if q > 0 do total += a / (q * q)
		}
		return total
	}
	// The quads go down as the size away from the border goes up, so the size that asks
	// `cells` is found by halving, in the log, between a thousandth of the quad edge and
	// a thousand times it.
	lo, hi := math.ln(quad_edge * 1e-3), math.ln(quad_edge * 1e3)
	if most := count(island, distance, length, area, math.exp(hi)); !(cells > most) {
		lo = hi
		asked = most
	} else {
		for _ in 0 ..< 60 {
			mid := 0.5 * (lo + hi)
			if count(island, distance, length, area, math.exp(mid)) > cells do lo = mid
			else do hi = mid
		}
	}
	away = math.exp(lo)
	// The isotropic edge goes as the density's quad size already (its edge factor), so the
	// refinement asks the rest.
	if len(island.refine) != n {
		delete(island.refine, heap)
		island.refine = make([]f64, n, heap)
		for &r in island.refine do r = 1
	}
	for v in 0 ..< n {
		b := base(island, v)
		q := frozen_graded(away * b, distance[v], length[v])
		if q > 0 do island.refine[v] *= q / (quad_edge * b)
	}
	return
}

// A frozen border's band on the isotropic mesh: per vertex, how far along the surface the
// nearest frozen vertex is, the length of the border's edges there, and the quad size the
// density asks with no border (as at the quad edge `at`), so each cover's sizes can be
// graded again at its own scaling (frozen_regrade).
Frozen_Band :: struct {
	distance, length, base: []f64,
	at:                     f64,
}

frozen_band_destroy :: proc(b: ^Frozen_Band) {
	heap := runtime.heap_allocator()
	delete(b.distance, heap)
	delete(b.length, heap)
	delete(b.base, heap)
	b^ = {}
}

// The isotropic mesh's frozen band, from the ends of its frozen corners, with `away` the
// size away from the border frozen_grade found; the mesh's own quad size per vertex
// (Isotropic.vertex_scale, relative to the quad edge `at`) becomes the graded one, which
// the field turns by and the landing's first cover is sized by. Empty when no corner is
// frozen.
frozen_band :: proc(iso: ^Isotropic, away, at: f64) -> (b: Frozen_Band) {
	n := len(iso.positions)
	if n == 0 || len(iso.corner_frozen) != 3 * len(iso.triangles) || !(at > 0) do return
	heap := runtime.heap_allocator()
	b.distance = make([]f64, n, heap)
	b.length = make([]f64, n, heap)
	b.base = make([]f64, n, heap)
	b.at = at
	count := make([]int, n, heap)
	defer delete(count, heap)
	for &d in b.distance do d = math.F64_MAX
	for t, f in iso.triangles do for k in 0 ..< 3 {
		if !iso.corner_frozen[3 * f + k] do continue
		ends := [2]u32{t[k], t[(k + 1) % 3]}
		l := length3(iso.positions[ends[1]] - iso.positions[ends[0]])
		for v in ends {
			b.distance[v] = 0
			b.length[v] += l
			count[v] += 1
		}
	}
	for &l, v in b.length do if count[v] > 0 do l /= f64(count[v])
	frozen_front(iso.positions, iso.triangles, b.distance, b.length)
	scaled := len(iso.vertex_scale) == n
	for &x, v in b.base do x = away * (iso.vertex_scale[v] if scaled else 1)
	if !scaled {
		delete(iso.vertex_scale, heap)
		iso.vertex_scale = make([]f64, n, heap)
	}
	for v in 0 ..< n do iso.vertex_scale[v] = frozen_graded(b.base[v], b.distance[v], b.length[v]) / at
	return
}

// The cover's sizes per triangle (`sizes`, the field's, graded at the band's quad edge)
// graded again for a cover whose quad is `scale` long where the size is 1: the size away
// from the border goes with the scaling while the border's stays its edges' length, so
// the landing's covers keep the border's quads one edge long whatever they scale.
frozen_regrade :: proc(band: ^Frozen_Band, triangles: [][3]u32, sizes: []f64, scale: f64, out: []f64) {
	for t, f in triangles {
		now, then := f64(0), f64(0)
		for v in t {
			now += frozen_graded(band.base[v] * scale / band.at, band.distance[v], band.length[v]) / scale
			then += frozen_graded(band.base[v], band.distance[v], band.length[v]) / band.at
		}
		out[f] = sizes[f] * now / then if then > 0 else sizes[f]
	}
}

// Mends the island's quads to its frozen border (the file's comment): every extracted
// vertex within reach of a frozen vertex is put on it exactly, and each run of the quads'
// border between two such vertices is matched to the frozen run between theirs, its
// vertices put on the frozen ones in order along the two runs, those left over taken out
// and those missing put in; a polygon that grew is cut back into quads. A run that does
// not lead along the frozen border (a symmetric half's cut) is left as it is.
frozen_mend :: proc(q: ^Quads, border: Frozen_Border, checks: ^Checks) {
	faces := len(q.first) - 1
	nv := len(q.positions)
	if len(border.points) == 0 || faces <= 0 do return
	heap := runtime.heap_allocator()
	checks.frozen_vertices += len(border.points)

	// The quads' border: each edge of one polygon, from a to b as the polygon runs.
	Directed :: struct {
		key:  u64,
		a, b: u32,
		face: u32,
	}
	all := make([]Directed, len(q.corners), heap)
	defer delete(all, heap)
	for f in 0 ..< faces {
		from, to := q.first[f], q.first[f + 1]
		for k in from ..< to {
			a, b := q.corners[k], q.corners[k + 1 if k + 1 < to else from]
			all[k] = {edge_key(a, b), a, b, u32(f)}
		}
	}
	slice.sort_by(all, proc(x, y: Directed) -> bool {return x.key < y.key || (x.key == y.key && x.face < y.face)})
	out_next := make([]u32, nv, heap)
	defer delete(out_next, heap)
	for &x in out_next do x = NONE
	// A vertex the quads' border passes through twice (where two of its polygons meet at
	// the vertex alone) has no one next along it, and a run through it is left as it is.
	pinched := make([]bool, nv, heap)
	defer delete(pinched, heap)
	for i := 0; i < len(all); {
		j := i + 1
		for j < len(all) && all[j].key == all[i].key do j += 1
		if j - i == 1 {
			if out_next[all[i].a] != NONE do pinched[all[i].a] = true
			out_next[all[i].a] = all[i].b
		}
		i = j
	}

	// Each border vertex of the quads matched to the nearest frozen vertex within its
	// reach, nearest pairs first, one to one.
	cell := f64(0)
	for r in border.reach do cell = max(cell, 2 * r)
	if !(cell > 0) || cell == math.F64_MAX do return
	Filed :: struct {
		at: [3]i64,
		p:  u32,
	}
	cell_of :: proc(x: [3]f64, cell: f64) -> [3]i64 {
		return {i64(math.floor(x.x / cell)), i64(math.floor(x.y / cell)), i64(math.floor(x.z / cell))}
	}
	before :: proc(a, b: [3]i64) -> bool {
		if a.x != b.x do return a.x < b.x
		if a.y != b.y do return a.y < b.y
		return a.z < b.z
	}
	filed := make([]Filed, len(border.points), heap)
	defer delete(filed, heap)
	for p, i in border.points do filed[i] = {cell_of(p, cell), u32(i)}
	slice.sort_by(filed, proc(x, y: Filed) -> bool {return before(x.at, y.at) || (x.at == y.at && x.p < y.p)})
	Pair :: struct {
		d:    f64,
		v, p: u32,
	}
	pairs := make([dynamic]Pair, heap)
	defer delete(pairs)
	for v in 0 ..< nv {
		if out_next[v] == NONE do continue
		x := q.positions[v]
		at := cell_of(x, cell)
		for dx in i64(-1) ..= 1 do for dy in i64(-1) ..= 1 do for dz in i64(-1) ..= 1 {
			key := at + {dx, dy, dz}
			lo, hi := 0, len(filed)
			for lo < hi {
				mid := (lo + hi) / 2
				if before(filed[mid].at, key) do lo = mid + 1
				else do hi = mid
			}
			for i := lo; i < len(filed) && filed[i].at == key; i += 1 {
				p := filed[i].p
				d := length3(border.points[p] - x)
				if d <= border.reach[p] do append(&pairs, Pair{d, u32(v), p})
			}
		}
	}
	slice.sort_by(pairs[:], proc(x, y: Pair) -> bool {return x.d < y.d || (x.d == y.d && (x.v < y.v || (x.v == y.v && x.p < y.p)))})
	match := make([]u32, nv, heap)
	defer delete(match, heap)
	for &m in match do m = NONE
	taken := make([]bool, len(border.points), heap)
	defer delete(taken, heap)
	for pair in pairs {
		if match[pair.v] != NONE || taken[pair.p] do continue
		match[pair.v], taken[pair.p] = pair.p, true
	}

	// The polygons as lists, copied out only where an edit touches them; a polygon merged
	// into another points at it.
	edit: Frozen_Edit
	edit.q = q
	edit.own = make([][dynamic]u32, faces, heap)
	edit.added = make([dynamic][dynamic]u32, heap)
	edit.into = make([]u32, faces, heap)
	for &x in edit.into do x = NONE
	edit.positions = make([dynamic][3]f64, nv, heap)
	copy(edit.positions[:], q.positions)
	defer {
		for &l in edit.own do delete(l)
		delete(edit.own, heap)
		delete(edit.into, heap)
		delete(edit.positions)
		delete(edit.faces_of, heap)
		delete(edit.faces_first, heap)
		for &l in edit.added do delete(l)
		delete(edit.added)
	}
	frozen_faces_of(&edit)
	for m, v in match do if m != NONE do edit.positions[v] = border.points[m]

	// The runs: from each matched vertex along the quads' border to the next matched one.
	run := make([dynamic]u32, heap)
	defer delete(run)
	chain := make([dynamic]u32, heap)
	defer delete(chain)
	// A run's vertices the mend matched start no run of their own: the run they were in
	// was mended whole.
	done := make([]bool, nv, heap)
	defer delete(done, heap)
	for a in 0 ..< u32(nv) {
		if match[a] == NONE || out_next[a] == NONE || done[a] do continue
		clear(&run)
		v := out_next[a]
		for v != NONE && v != a && match[v] == NONE && len(run) <= FROZEN_RUN_MAX {
			append(&run, v)
			v = out_next[v]
		}
		if v == NONE || v == a || match[v] == NONE || pinched[a] || pinched[v] do continue
		through := false
		for x in run do through ||= pinched[x]
		if through do continue
		c := v
		// The frozen run from a's point to c's, if there is one so short.
		clear(&chain)
		p := border.next[match[a]]
		for p != NONE && p != match[c] && p != match[a] && len(chain) <= FROZEN_RUN_MAX {
			append(&chain, p)
			p = border.next[p]
		}
		if p != match[c] do continue
		if len(run) == 0 && len(chain) == 0 do continue
		frozen_mend_run(&edit, a, c, run[:], chain[:], border, match, checks)
		for x in run do done[x] = true
	}

	// Every polygon that grew past four corners cut back into quads (and a triangle where
	// it has an odd number), and the vertices no polygon uses any more dropped.
	frozen_rebuild(&edit)
	checks.frozen_kept += edit.inserted
	for m in match do if m != NONE do checks.frozen_kept += 1
}

@(private = "file")
Frozen_Edit :: struct {
	q:           ^Quads,
	own:         [][dynamic]u32, // per polygon: its corners once edited, else empty
	into:        []u32, // per polygon: the one it was merged into, or NONE
	positions:   [dynamic][3]f64,
	faces_first: []u32, // per vertex: its polygons are faces_of[faces_first[v]:faces_first[v + 1]]
	faces_of:    []u32,
	inserted:    int, // frozen vertices put in
	added:       [dynamic][dynamic]u32, // polygons the fills made, outside the quads' border
}

@(private = "file")
frozen_faces_of :: proc(e: ^Frozen_Edit) {
	heap := runtime.heap_allocator()
	q := e.q
	nv := len(q.positions)
	e.faces_first = make([]u32, nv + 1, heap)
	for c in q.corners do e.faces_first[c + 1] += 1
	for v in 0 ..< nv do e.faces_first[v + 1] += e.faces_first[v]
	e.faces_of = make([]u32, len(q.corners), heap)
	at := make([]u32, nv, heap)
	defer delete(at, heap)
	copy(at, e.faces_first[:nv])
	for f in 0 ..< len(q.first) - 1 do for k in q.first[f] ..< q.first[f + 1] {
		v := q.corners[k]
		e.faces_of[at[v]] = u32(f)
		at[v] += 1
	}
}

// The polygon `f` now is (followed through merges), and its corners, copied out to edit.
@(private = "file")
frozen_face :: proc(e: ^Frozen_Edit, f: u32) -> (live: u32, corners: ^[dynamic]u32) {
	live = f
	for e.into[live] != NONE do live = e.into[live]
	if len(e.own[live]) == 0 {
		e.own[live] = make([dynamic]u32, 0, 8, runtime.heap_allocator())
		append(&e.own[live], ..e.q.corners[e.q.first[live]:e.q.first[live + 1]])
	}
	return live, &e.own[live]
}

// Where in `corners` the edge from a to b is, or -1.
@(private = "file")
edge_at :: proc(corners: []u32, a, b: u32) -> int {
	for c, k in corners do if c == a && corners[(k + 1) % len(corners)] == b do return k
	return -1
}

// One run of the quads' border, a, run..., c, against the frozen run a's point, chain...,
// c's point: the run's vertices put on the chain's in order along the two (each where its
// share of the way is nearest), and those left over taken out or those missing put in.
@(private = "file")
frozen_mend_run :: proc(e: ^Frozen_Edit, a, c: u32, run, chain: []u32, border: Frozen_Border, match: []u32, checks: ^Checks) {
	heap := runtime.heap_allocator()
	// Each vertex's share of the way along its run.
	along :: proc(points: [][3]f64, heap: runtime.Allocator) -> []f64 {
		t := make([]f64, len(points), heap)
		total := f64(0)
		for i in 1 ..< len(points) {
			total += length3(points[i] - points[i - 1])
			t[i] = total
		}
		if total > 0 do for &x in t do x /= total
		return t
	}
	out_points := make([][3]f64, len(run) + 2, heap)
	defer delete(out_points, heap)
	out_points[0] = e.positions[a]
	for v, i in run do out_points[i + 1] = e.positions[v]
	out_points[len(run) + 1] = e.positions[c]
	in_points := make([][3]f64, len(chain) + 2, heap)
	defer delete(in_points, heap)
	in_points[0] = border.points[match[a]]
	for p, i in chain do in_points[i + 1] = border.points[p]
	in_points[len(chain) + 1] = border.points[match[c]]
	t_out := along(out_points, heap)
	defer delete(t_out, heap)
	t_in := along(in_points, heap)
	defer delete(t_in, heap)

	// pick[i] of the shorter side: the index on the longer side it goes to, increasing,
	// each where its share is nearest while leaving room for the rest.
	short, long := t_out[1:len(t_out) - 1], t_in[1:len(t_in) - 1]
	if len(short) > len(long) do short, long = long, short
	pick := make([]int, len(short), heap)
	defer delete(pick, heap)
	next := 0
	for x, i in short {
		best := next
		for j in next ..= len(long) - (len(short) - i) {
			if abs(long[j] - x) < abs(long[best] - x) do best = j
		}
		pick[i] = best
		next = best + 1
	}
	if len(run) <= len(chain) {
		// Every vertex of the run is one of the chain's; the chain's others go in.
		landed := make([]u32, len(chain), heap)
		defer delete(landed, heap)
		for &x in landed do x = NONE
		for v, i in run {
			p := chain[pick[i]]
			e.positions[v] = border.points[p]
			match[v] = p
			landed[pick[i]] = v
		}
		// The missing ones go into the quads' border edge between the vertices placed on
		// either side of them, in order.
		prev := a
		for i := 0; i < len(chain); {
			if landed[i] != NONE {
				prev = landed[i]
				i += 1
				continue
			}
			j := i
			for j < len(chain) && landed[j] == NONE do j += 1
			to := c if j == len(chain) else landed[j]
			if !frozen_insert(e, prev, to, chain[i:j], border) do frozen_fill(e, prev, to, nil, chain[i:j], border)
			checks.frozen_mended += j - i
			i = j
		}
	} else {
		// Every vertex of the chain is one of the run's; the run's others come out.
		chosen := make([]bool, len(run), heap)
		defer delete(chosen, heap)
		for p, i in chain {
			v := run[pick[i]]
			e.positions[v] = border.points[p]
			match[v] = p
			chosen[pick[i]] = true
		}
		// Between each two vertices kept, those that cannot come out (a vertex of more
		// polygons than two) are filled over instead, by a polygon from the one before them
		// to the one after and back along them.
		stuck := make([dynamic]u32, heap)
		defer delete(stuck)
		prev := a
		for v, i in run {
			if chosen[i] {
				if len(stuck) > 0 do frozen_fill(e, prev, v, stuck[:], nil, border)
				clear(&stuck)
				prev = v
				continue
			}
			if !frozen_remove(e, v) do append(&stuck, v)
			checks.frozen_mended += 1
		}
		if len(stuck) > 0 do frozen_fill(e, prev, c, stuck[:], nil, border)
	}
}

// A polygon outside the quads' border between a and b, over what they could not mend:
// the quads' border runs a, `over`..., b, and the polygon brings it back to a, `points`
// (frozen points, put in as new vertices)..., b, running against the border's edges so
// the quads stay one way round. Left out when it would have fewer than three corners.
@(private = "file")
frozen_fill :: proc(e: ^Frozen_Edit, a, b: u32, over, points: []u32, border: Frozen_Border) {
	if len(over) + len(points) == 0 do return
	poly := make([dynamic]u32, 0, len(over) + len(points) + 2, runtime.heap_allocator())
	append(&poly, a)
	for p in points {
		append(&poly, u32(len(e.positions)))
		append(&e.positions, border.points[p])
	}
	e.inserted += len(points)
	append(&poly, b)
	#reverse for v in over do append(&poly, v)
	append(&e.added, poly)
}

// Puts the frozen points into the quads' border edge from a to b, in order, as new
// vertices.
@(private = "file")
frozen_insert :: proc(e: ^Frozen_Edit, a, b: u32, points: []u32, border: Frozen_Border) -> bool {
	for f in e.faces_of[e.faces_first[a]:e.faces_first[a + 1]] {
		_, corners := frozen_face(e, f)
		k := edge_at(corners[:], a, b)
		if k < 0 do continue
		for p, i in points {
			inject_at(corners, k + 1 + i, u32(len(e.positions)))
			append(&e.positions, border.points[p])
		}
		e.inserted += len(points)
		return true
	}
	return false
}

// Takes vertex v, which the frozen border does not have, out of the quads' border: from
// its one polygon, or the two it is in merged into one without it. A vertex of more
// polygons, or a merge that would repeat a corner, stays.
@(private = "file")
frozen_remove :: proc(e: ^Frozen_Edit, v: u32) -> bool {
	live: [4]u32
	count := 0
	for f in e.faces_of[e.faces_first[v]:e.faces_first[v + 1]] {
		g, _ := frozen_face(e, f)
		seen := false
		for x in live[:count] do if x == g do seen = true
		if seen do continue
		if count == len(live) do return false
		live[count] = g
		count += 1
	}
	switch count {
	case 1:
		corners := &e.own[live[0]]
		if len(corners) <= 3 do return false
		for c, k in corners do if c == v {
			ordered_remove(corners, k)
			return true
		}
	case 2:
		// The first polygon has the border edge into v, the second the one out of it, and
		// they share the edge from v inward.
		first, second := &e.own[live[0]], &e.own[live[1]]
		i := index_of(first[:], v)
		j := index_of(second[:], v)
		if i < 0 || j < 0 do return false
		inward := first[(i + 1) % len(first)]
		if second[(j - 1 + len(second)) % len(second)] != inward {
			first, second = second, first
			live[0], live[1] = live[1], live[0]
			i, j = j, i
			inward = first[(i + 1) % len(first)]
			if second[(j - 1 + len(second)) % len(second)] != inward do return false
		}
		// first: ..., v, inward, ... ; second: ..., inward, v, ... . Merged: first from
		// after inward round to before v, then second from after v round to inward.
		merged := make([dynamic]u32, 0, len(first) + len(second), runtime.heap_allocator())
		for k in 1 ..< len(first) - 1 do append(&merged, first[(i + 1 + k) % len(first)])
		for k in 1 ..< len(second) do append(&merged, second[(j + k) % len(second)])
		for x, k in merged do for y in merged[k + 1:] do if x == y {
			delete(merged)
			return false
		}
		delete(first^)
		first^ = merged
		delete(second^)
		second^ = {}
		e.into[live[1]] = live[0]
		return true
	}
	return false
}

@(private = "file")
index_of :: proc(list: []u32, v: u32) -> int {
	for x, k in list do if x == v do return k
	return -1
}

// The quads again from the edits: each polygon of more than four corners cut into quads,
// a triangle first where it has an odd number, always along the shortest cut; then the
// vertices no polygon uses dropped.
@(private = "file")
frozen_rebuild :: proc(e: ^Frozen_Edit) {
	heap := runtime.heap_allocator()
	q := e.q
	faces := len(q.first) - 1
	first := make([dynamic]u32, 1, faces + 8, heap)
	corners := make([dynamic]u32, 0, len(q.corners) + 16, heap)
	poly := make([dynamic]u32, heap)
	defer delete(poly)
	rest := make([dynamic]u32, heap)
	defer delete(rest)
	for f in 0 ..< faces + len(e.added) {
		clear(&poly)
		if f >= faces {
			append(&poly, ..e.added[f - faces][:])
		} else {
			if e.into[f] != NONE do continue
			if len(e.own[f]) > 0 do append(&poly, ..e.own[f][:])
			else do append(&poly, ..q.corners[q.first[f]:q.first[f + 1]])
		}
		for len(poly) > 4 {
			// The cut off a quad (or, from an odd polygon, a triangle) whose diagonal is
			// shortest; what is left keeps the cut's two ends.
			side := 2 if len(poly) % 2 == 1 else 3
			best, shortest := 0, math.F64_MAX
			for k in 0 ..< len(poly) {
				d := length3(e.positions[poly[(k + side) % len(poly)]] - e.positions[poly[k]])
				if d < shortest do best, shortest = k, d
			}
			for s in 0 ..= side do append(&corners, poly[(best + s) % len(poly)])
			append(&first, u32(len(corners)))
			clear(&rest)
			for s in side ..= len(poly) do append(&rest, poly[(best + s) % len(poly)])
			poly, rest = rest, poly
		}
		append(&corners, ..poly[:])
		append(&first, u32(len(corners)))
	}
	// The vertices still used, in order.
	renumber := make([]u32, len(e.positions), heap)
	defer delete(renumber, heap)
	for &r in renumber do r = NONE
	for c in corners do renumber[c] = 0
	kept := u32(0)
	for &r in renumber do if r != NONE {
		r = kept
		kept += 1
	}
	positions := make([][3]f64, kept, heap)
	for p, v in e.positions do if renumber[v] != NONE do positions[renumber[v]] = p
	for &c in corners do c = renumber[c]
	quads_destroy(q)
	q.positions = positions
	q.first = first[:]
	q.corners = corners[:]
}

// How many of the isotropic mesh's frozen border edges the cover gives other than one
// step of the grid (none or two, which the extraction makes a bay of and the mend a
// triangle), by which the landing picks among its covers.
frozen_misses :: proc(cover: Cover, corner_frozen: []bool) -> int {
	if len(corner_frozen) != 3 * len(cover.uvs) do return 0
	misses := 0
	for t, f in cover.uvs do for k in 0 ..< 3 {
		if !corner_frozen[3 * f + k] do continue
		d := t[(k + 1) % 3] - t[k]
		if abs(abs(d.x) + abs(d.y) - 1) > 0.25 do misses += 1
	}
	return misses
}
