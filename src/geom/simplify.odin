package geom

import "core:math"
import "core:math/linalg"
import "core:slice"

import "../jobs"

// Mesh simplification for levels of detail. Edges collapse into one of their existing
// vertices, cheapest first by quadric error (Garland and Heckbert), in passes of
// independent collapses as meshoptimizer does. A vertex on an edge that does not have
// exactly two triangles in the input never moves: a patch cut from a larger mesh keeps
// its border exactly, so the simplified patch still meets its neighbours without cracks.
// A Simplify_Guide (decimation) may instead let open edges slide along themselves, hold
// the lines between labelled regions (polygroups) as such feature lines, and make some
// vertices dearer to move.

// What steers a simplification besides the shape; the zero value steers nothing, and
// then open edges stay exactly where they are.
Simplify_Guide :: struct {
	// Per vertex of `positions`: how many times dearer moving it is (1 as usual), so the
	// detail that matters to the user (masked, or where the paint changes) goes last.
	weight:        []f32,
	// Per triangle of `indices`: a label (a polygroup). An edge between two labels is a
	// feature line: its vertices move only along it and its shape is held, as an open
	// edge's is with `slide_borders`; the labels follow the triangles into `out_labels`.
	labels:        []u16,
	// Vertices on an open edge slide along it rather than stay put, so an open mesh thins
	// out to its border too. Never for a patch cut from a larger mesh, whose border has to
	// meet its neighbours'.
	slide_borders: bool,
}

// How much a feature line's own planes (through the line, across its triangles) weigh
// against the triangles' planes, per squared length of the edge: enough that sliding a
// vertex off the line costs about what bending the surface by as much does.
@(private = "file")
FEATURE_WEIGHT :: 1.0
// A vertex whose two line edges meet at less than about 105 degrees is a corner of the
// line and stays.
@(private = "file")
LINE_CORNER_COS :: -0.25

// Area-weighted sum of plane equations, q(x) = xᵀAx + 2bᵀx + c, stored as A00 A01 A02
// A11 A12 A22, b, c, then the total area. Doubles, since near the surface the terms
// cancel almost exactly.
@(private = "file")
Quadric :: [11]f64

@(private = "file")
Vec3d :: [3]f64

@(private = "file")
plane_quadric :: proc(p0, p1, p2: Vec3d) -> Quadric {
	n := linalg.cross(p1 - p0, p2 - p0)
	length := linalg.length(n)
	if length <= 0 do return {}
	n /= length
	d := -linalg.dot(n, p0)
	w := length * 0.5
	return {w * n.x * n.x, w * n.x * n.y, w * n.x * n.z, w * n.y * n.y, w * n.y * n.z, w * n.z * n.z, w * n.x * d, w * n.y * d, w * n.z * d, w * d * d, w}
}

// The plane through edge a-b standing across the triangle with normal n (any length),
// weighted by the squared length of the edge: what keeps a feature line where it is.
@(private = "file")
edge_quadric :: proc(a, b, n: Vec3d) -> Quadric {
	e := b - a
	m := linalg.cross(e, n)
	length := linalg.length(m)
	if length <= 0 do return {}
	m /= length
	d := -linalg.dot(m, a)
	w := FEATURE_WEIGHT * linalg.length2(e)
	return {w * m.x * m.x, w * m.x * m.y, w * m.x * m.z, w * m.y * m.y, w * m.y * m.z, w * m.z * m.z, w * m.x * d, w * m.y * d, w * m.z * d, w * d * d, w}
}

// Mean squared distance, weighted by area, from p to the quadric's planes.
@(private = "file")
quadric_error :: #force_inline proc(q: Quadric, p: Vec3d) -> f64 {
	if q[10] <= 0 do return 0
	x, y, z := p.x, p.y, p.z
	r := q[0] * x * x + q[3] * y * y + q[5] * z * z + 2 * (q[1] * x * y + q[2] * x * z + q[4] * y * z + q[6] * x + q[7] * y + q[8] * z) + q[9]
	return max(r, 0) / q[10]
}

// Whether moving corner c of triangle (a, b, c) to d turns the triangle over, or nearly:
// more than about 75 degrees, so a run of collapses cannot flip it in small steps.
@(private = "file")
flips :: #force_inline proc(a, b, c, d: Vec3d) -> bool {
	eb := b - a
	before := linalg.cross(eb, c - a)
	after := linalg.cross(eb, d - a)
	return linalg.dot(before, after) <= 0.25 * math.sqrt(linalg.dot(before, before) * linalg.dot(after, after))
}

// How much a collapse's squared length adds to its cost in strict mode.
@(private = "file")
STRICT_LENGTH_COST :: 0.01

// Whether triangle (a, b, c) is a needle: its area against its squared sides is under
// a twentieth of an equilateral triangle's.
@(private = "file")
sliver :: #force_inline proc(a, b, c: Vec3d) -> bool {
	twice_area := linalg.length(linalg.cross(b - a, c - a))
	sides := linalg.length2(b - a) + linalg.length2(c - b) + linalg.length2(a - c)
	return 2 * math.SQRT_THREE * twice_area < 0.05 * sides
}

// Simplifies the triangles `indices` (into `positions`) towards `target` triangles,
// appending the result to `out` in the same vertex numbering. Stops early when no
// collapse is left that keeps the surface sound. Returns the largest error a collapse
// made: the area-weighted root mean square distance from where a vertex went to the
// planes of the triangles it had gathered, in the units of `positions`.
//
// Collapses in one pass share no vertex, but two may still move two corners of one
// triangle, which neither checked; for drawing that is harmless. With `strict`, no two
// vertices of a triangle move in one pass, so the checks hold and no triangle folds or
// goes flat, at the cost of more passes: for meshes that are sculpted or exported
// (mesh_decimate). `guide` steers it (Simplify_Guide); with its labels, `out_labels`
// (when not nil) receives the label of each triangle appended to `out`, in order.
simplify :: proc(positions: []Vec3, indices: []u32, target: int, out: ^[dynamic]u32, allocator := context.allocator, strict := false, progress: ^jobs.Progress = nil, share := [2]f32{0, 1}, guide := Simplify_Guide{}, out_labels: ^[dynamic]u16 = nil) -> (error: f32) {
	context.allocator = allocator
	EMPTY :: max(u32)

	// Local numbering, in order of first use, through an open-addressing table that
	// always has room: there are never more vertices than corners.
	size := 64
	for size <= len(indices) do size *= 2
	table := make([][2]u32, size) // {vertex, local vertex}
	defer delete(table)
	for &e in table do e[0] = EMPTY
	global := make([dynamic]u32, 0, len(indices) / 4 + 16) // local -> vertex
	defer delete(global)
	tris := make([dynamic][3]u32, 0, len(indices) / 3)
	defer delete(tris)
	labelled := guide.labels != nil
	assert(!labelled || len(guide.labels) == len(indices) / 3, "one label a triangle")
	// Each triangle's label, kept in step with `tris`.
	tri_label := make([dynamic]u16, 0, len(indices) / 3 if labelled else 0)
	defer delete(tri_label)
	for first := 0; first + 2 < len(indices); first += 3 {
		tri: [3]u32
		for k in 0 ..< 3 {
			g := indices[first + k]
			slot := int((g * 0x9E3779B1) >> 7) & (size - 1)
			for table[slot][0] != EMPTY && table[slot][0] != g do slot = (slot + 1) & (size - 1)
			if table[slot][0] == EMPTY {
				table[slot] = {g, u32(len(global))}
				append(&global, g)
			}
			tri[k] = table[slot][1]
		}
		if tri[0] != tri[1] && tri[1] != tri[2] && tri[2] != tri[0] {
			append(&tris, tri)
			if labelled do append(&tri_label, guide.labels[first / 3])
		}
	}
	defer {
		for tri in tris do append(out, global[tri[0]], global[tri[1]], global[tri[2]])
		if labelled && out_labels != nil do append(out_labels, ..tri_label[:])
	}
	if len(tris) <= target do return 0
	vcount := len(global)

	// Positions relative to the middle of the patch, so the quadric terms stay small.
	lo, hi := positions[global[0]], positions[global[0]]
	for g in global {
		lo = linalg.min(lo, positions[g])
		hi = linalg.max(hi, positions[g])
	}
	center := linalg.array_cast((lo + hi) * 0.5, f64)
	pos := make([]Vec3d, vcount)
	defer delete(pos)
	for g, i in global do pos[i] = linalg.array_cast(positions[g], f64) - center

	// Vertex -> triangles, rebuilt each pass.
	offsets := make([]u32, vcount + 1)
	defer delete(offsets)
	cursor := make([]u32, vcount)
	defer delete(cursor)
	adjacent := make([]u32, 3 * len(tris))
	defer delete(adjacent)
	adjacency :: proc(tris: [][3]u32, offsets, cursor, adjacent: []u32) {
		slice.zero(offsets)
		for tri in tris do for v in tri do offsets[v + 1] += 1
		for i in 1 ..< len(offsets) do offsets[i] += offsets[i - 1]
		copy(cursor, offsets[:len(cursor)])
		for tri, t in tris {
			for v in tri {
				adjacent[cursor[v]] = u32(t)
				cursor[v] += 1
			}
		}
	}
	adjacency(tris[:], offsets, cursor, adjacent)

	quadrics := make([]Quadric, vcount)
	defer delete(quadrics)
	for tri in tris {
		q := plane_quadric(pos[tri[0]], pos[tri[1]], pos[tri[2]])
		for v in tri do quadrics[v] += q
	}

	// Per local vertex: how dear moving it is (Simplify_Guide.weight).
	weight := make([]f32, vcount if guide.weight != nil else 0)
	defer delete(weight)
	for &w, i in weight do w = guide.weight[global[i]]

	// Fixed vertices: those on a non-manifold edge, those with too many neighbours to
	// check, and those on an open edge unless borders slide. With a guide, a vertex on
	// exactly two feature edges (open edges that slide, or edges between two labels) moves
	// only along them, into one of its two `rail` neighbours, and one on one feature edge
	// or on three or more (an end or a corner of the lines) stays.
	features := labelled || guide.slide_borders
	// The lines' bookkeeping counts on no neighbour of a collapse moving in its pass.
	assert(!features || strict, "feature lines need strict passes")
	locked := make([]bool, vcount)
	defer delete(locked)
	rail := make([][2]u32, vcount if features else 0)
	defer delete(rail)
	for &r in rail do r = {EMPTY, EMPTY}
	for v in 0 ..< vcount {
		neighbours: [32]u32
		counts: [32]u8
		sides: [32][2]u32 // the first two triangles on the edge to each neighbour
		n := 0
		scan: for t in adjacent[offsets[v]:offsets[v + 1]] {
			for w in tris[t] {
				if w == u32(v) do continue
				j := 0
				for j < n && neighbours[j] != w do j += 1
				if j == n {
					if n == len(neighbours) {
						locked[v] = true
						break scan
					}
					neighbours[n], counts[n] = w, 0
					n += 1
				}
				if counts[j] < 2 do sides[j][counts[j]] = t
				counts[j] += 1
			}
		}
		if locked[v] do continue
		lines := 0
		for j in 0 ..< n {
			line := false
			switch {
			case counts[j] > 2:
				locked[v] = true
			case counts[j] == 1:
				if guide.slide_borders do line = true
				else do locked[v] = true
			case labelled:
				line = tri_label[sides[j][0]] != tri_label[sides[j][1]]
			}
			if !line do continue
			if lines < 2 do rail[v][lines] = neighbours[j]
			lines += 1
			// The line's planes, each side's on its own vertex: the other end adds its own.
			for k in 0 ..< int(min(counts[j], 2)) {
				tri := tris[sides[j][k]]
				normal := linalg.cross(pos[tri[1]] - pos[tri[0]], pos[tri[2]] - pos[tri[0]])
				quadrics[v] += edge_quadric(pos[v], pos[neighbours[j]], normal)
			}
		}
		if lines == 1 || lines > 2 do locked[v] = true
		// A sharp corner of a line (a square patch's corner) stays: sliding it along one
		// edge would cut the corner off. The zigzag of a line along triangle edges turns
		// by at most 60 degrees, which stays free.
		if lines == 2 {
			a := linalg.normalize0(pos[rail[v][0]] - pos[v])
			b := linalg.normalize0(pos[rail[v][1]] - pos[v])
			if linalg.dot(a, b) > LINE_CORNER_COS do locked[v] = true
		}
		if features && lines != 2 do rail[v] = {EMPTY, EMPTY}
	}

	remap := make([]u32, vcount) // where each vertex went this pass
	defer delete(remap)
	for &r, i in remap do r = u32(i)
	busy := make([]bool, vcount) // takes part in a collapse this pass
	defer delete(busy)
	still := make([]bool, vcount if strict else 0) // strict: next to a collapse this pass, so it stays
	defer delete(still)
	alive := make([]bool, vcount)
	defer delete(alive)
	slice.fill(alive, true)
	stamp := make([]u32, vcount) // neighbours of the collapse's target
	defer delete(stamp)
	seen := make([]u32, vcount)
	defer delete(seen)
	stamp_id: u32

	Candidate :: struct {
		u, v: u32, // collapse u into v
		cost: f32,
	}
	candidates := make([dynamic]Candidate, 0, vcount)
	defer delete(candidates)
	keys := make([dynamic]u32, 0, vcount)
	defer delete(keys)
	order := make([dynamic]u32, 0, vcount)
	defer delete(order)
	temp := make([dynamic]u32, 0, vcount)
	defer delete(temp)
	done := make([dynamic][2]u32, 0, vcount) // collapses of this pass
	defer delete(done)

	// Whether collapsing u into v keeps the surface sound: no triangle around u turns
	// over, and the two share no neighbour beyond the triangles on their edge (else the
	// surface would pinch). Returns how many triangles the collapse removes.
	collapse_ok :: proc(u, v: u32, tris: [][3]u32, offsets, adjacent, remap, stamp, seen: []u32, stamp_id: u32, pos: []Vec3d, strict: bool) -> (removed: int, ok: bool) {
		for t in adjacent[offsets[v]:offsets[v + 1]] {
			tri := tris[t]
			a, b, c := remap[tri[0]], remap[tri[1]], remap[tri[2]]
			if a == b || b == c || c == a do continue
			stamp[a], stamp[b], stamp[c] = stamp_id, stamp_id, stamp_id
		}
		common := 0
		for t in adjacent[offsets[u]:offsets[u + 1]] {
			tri := tris[t]
			k := [3]u32{remap[tri[0]], remap[tri[1]], remap[tri[2]]}
			if k[0] == k[1] || k[1] == k[2] || k[2] == k[0] do continue
			for _ in 0 ..< 2 do if k[0] != u do k = {k[1], k[2], k[0]}
			if k[1] == v || k[2] == v {
				removed += 1
			} else if flips(pos[k[1]], pos[k[2]], pos[u], pos[v]) {
				return 0, false
			} else if strict && sliver(pos[k[1]], pos[k[2]], pos[v]) && !sliver(pos[k[1]], pos[k[2]], pos[u]) {
				// On a flat area every collapse costs nothing; this keeps them from
				// leaving needles that are all but flat.
				return 0, false
			}
			for w in k[1:] {
				if w != v && stamp[w] == stamp_id && seen[w] != stamp_id {
					seen[w] = stamp_id
					common += 1
				}
			}
		}
		return removed, removed > 0 && common == removed
	}

	worst: f64
	start := len(tris)
	for _ in 0 ..< (256 if strict else 32) {
		if len(tris) <= target do break
		// A job's progress, set only on the calling thread, and its cancel, which leaves
		// the passes so far for the caller to throw away.
		jobs.progress_set(progress, share[0], share[1], f32(start - len(tris)) / f32(max(start - target, 1)))
		if jobs.progress_cancelled(progress) do break
		// Each free vertex's cheapest collapse into a neighbour.
		clear(&candidates)
		for u in 0 ..< vcount {
			if locked[u] || !alive[u] do continue
			best, best_cost := EMPTY, max(f64)
			// A vertex on a feature line goes only along it.
			on_line := features && rail[u][0] != EMPTY
			for t in adjacent[offsets[u]:offsets[u + 1]] {
				for w in tris[t] {
					if w == u32(u) do continue
					if on_line && w != rail[u][0] && w != rail[u][1] do continue
					c := quadric_error(quadrics[u], pos[w])
					// Strict: shorter edges first where the error ties, as on flat
					// areas, which keeps the triangles from turning into needles.
					if strict do c += STRICT_LENGTH_COST * linalg.length2(pos[w] - pos[u])
					if weight != nil do c *= f64(weight[u])
					if c < best_cost {
						best, best_cost = w, c
					}
				}
			}
			if best != EMPTY do append(&candidates, Candidate{u32(u), best, f32(best_cost)})
		}
		// Cheapest first: non-negative floats sort like their bits.
		n := len(candidates)
		resize(&keys, n)
		resize(&order, n)
		resize(&temp, n)
		for c, i in candidates do keys[i] = transmute(u32)c.cost
		radix_order(keys[:], order[:], temp[:])

		goal := len(tris) - target
		removed := 0
		clear(&done)
		// With weights, near the target a pass takes only collapses up to half again as dear
		// as the one that would reach it if all were free to go (meshoptimizer's limit), so
		// the weighted detail waits for a later pass rather than going along with the cheap
		// collapses, as it would when a pass takes every independent one; the first collapse
		// that works always goes, so a pass is never empty.
		limit := max(f32)
		if weight != nil && goal / 2 < n do limit = 1.5 * candidates[order[goal / 2]].cost
		for i in order {
			if removed >= goal do break
			c := candidates[i]
			if c.cost > limit && len(done) > 0 do break
			if busy[c.u] || busy[c.v] do continue
			stamp_id += 1
			r, ok := collapse_ok(c.u, c.v, tris[:], offsets, adjacent, remap, stamp, seen, stamp_id, pos, strict)
			if !ok do continue
			if strict {
				// No vertex around u may move this pass, nor u if one around it did.
				if still[c.u] do continue
				clash := false
				for t in adjacent[offsets[c.u]:offsets[c.u + 1]] {
					for w in tris[t] do if w != c.u && remap[w] != w do clash = true
				}
				if clash do continue
				for t in adjacent[offsets[c.u]:offsets[c.u + 1]] {
					for w in tris[t] do if w != c.u do still[w] = true
				}
			}
			remap[c.u] = c.v
			busy[c.u], busy[c.v] = true, true
			removed += r
			worst = max(worst, quadric_error(quadrics[c.u], pos[c.v]) if strict else f64(c.cost))
			append(&done, [2]u32{c.u, c.v})
		}
		if len(done) == 0 do break

		for d in done {
			quadrics[d[1]] += quadrics[d[0]]
			alive[d[0]] = false
			if features && rail[d[0]][0] != EMPTY do rail_collapse(rail, locked, d[0], d[1])
		}
		kept := 0
		for tri, t in tris {
			a, b, c := remap[tri[0]], remap[tri[1]], remap[tri[2]]
			if a == b || b == c || c == a do continue
			tris[kept] = {a, b, c}
			if labelled do tri_label[kept] = tri_label[t]
			kept += 1
		}
		resize(&tris, kept)
		if labelled do resize(&tri_label, kept)
		for d in done {
			remap[d[0]] = d[0]
			busy[d[0]], busy[d[1]] = false, false
		}
		if strict do slice.zero(still)
		adjacency(tris[:], offsets, cursor, adjacent)
	}
	return f32(math.sqrt(worst))
}

// Feature line vertex u went into v, one of its two neighbours along the line: v and
// u's other neighbour now meet along it. A line closed into a loop of two edges ends
// with both its vertices fixed, as the line is then as short as it can be.
@(private = "file")
rail_collapse :: proc(rail: [][2]u32, locked: []bool, u, v: u32) {
	EMPTY :: max(u32)
	other := rail[u][1] if rail[u][0] == v else rail[u][0]
	rail[u] = {EMPTY, EMPTY}
	for w in ([2]u32{v, other}) {
		if rail[w][0] == EMPTY do continue
		with := other if w == v else v
		for &r in rail[w] do if r == u do r = with
		if rail[w][0] == rail[w][1] {
			rail[w] = {EMPTY, EMPTY}
			locked[w] = true
		}
	}
}

// Indices of `keys` in ascending key order, sorted stably by bytes (LSD radix).
@(private = "file")
radix_order :: proc(keys: []u32, order, temp: []u32) {
	for &o, i in order do o = u32(i)
	src, dst := order, temp
	for shift: u32 = 0; shift < 32; shift += 8 {
		counts: [257]u32
		for i in src do counts[((keys[i] >> shift) & 0xff) + 1] += 1
		for b in 1 ..< len(counts) do counts[b] += counts[b - 1]
		for i in src {
			b := (keys[i] >> shift) & 0xff
			dst[counts[b]] = i
			counts[b] += 1
		}
		src, dst = dst, src
	}
}
