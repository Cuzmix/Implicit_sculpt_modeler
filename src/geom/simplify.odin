package geom

import "core:math"
import "core:math/linalg"
import "core:slice"

// Mesh simplification for levels of detail. Edges collapse into one of their existing
// vertices, cheapest first by quadric error (Garland and Heckbert), in passes of
// independent collapses as meshoptimizer does. A vertex on an edge that does not have
// exactly two triangles in the input never moves: a patch cut from a larger mesh keeps
// its border exactly, so the simplified patch still meets its neighbours without cracks.

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

// Simplifies the triangles `indices` (into `positions`) towards `target` triangles,
// appending the result to `out` in the same vertex numbering. Stops early when no
// collapse is left that keeps the surface sound. Returns the largest error a collapse
// made: the area-weighted root mean square distance from where a vertex went to the
// planes of the triangles it had gathered, in the units of `positions`.
simplify :: proc(positions: []Vec3, indices: []u32, target: int, out: ^[dynamic]u32, allocator := context.allocator) -> (error: f32) {
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
		if tri[0] != tri[1] && tri[1] != tri[2] && tri[2] != tri[0] do append(&tris, tri)
	}
	defer {
		for tri in tris do append(out, global[tri[0]], global[tri[1]], global[tri[2]])
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

	// Fixed vertices: those on an edge without exactly two triangles (a border or a
	// non-manifold edge), and those with too many neighbours to check.
	locked := make([]bool, vcount)
	defer delete(locked)
	for v in 0 ..< vcount {
		neighbours: [32]u32
		counts: [32]u8
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
				counts[j] += 1
			}
		}
		for j in 0 ..< n do if counts[j] != 2 do locked[v] = true
	}

	quadrics := make([]Quadric, vcount)
	defer delete(quadrics)
	for tri in tris {
		q := plane_quadric(pos[tri[0]], pos[tri[1]], pos[tri[2]])
		for v in tri do quadrics[v] += q
	}

	remap := make([]u32, vcount) // where each vertex went this pass
	defer delete(remap)
	for &r, i in remap do r = u32(i)
	busy := make([]bool, vcount) // takes part in a collapse this pass
	defer delete(busy)
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
	collapse_ok :: proc(u, v: u32, tris: [][3]u32, offsets, adjacent, remap, stamp, seen: []u32, stamp_id: u32, pos: []Vec3d) -> (removed: int, ok: bool) {
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
	for _ in 0 ..< 32 {
		if len(tris) <= target do break
		// Each free vertex's cheapest collapse into a neighbour.
		clear(&candidates)
		for u in 0 ..< vcount {
			if locked[u] || !alive[u] do continue
			best, best_cost := EMPTY, max(f64)
			for t in adjacent[offsets[u]:offsets[u + 1]] {
				for w in tris[t] {
					if w == u32(u) do continue
					if c := quadric_error(quadrics[u], pos[w]); c < best_cost {
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
		for i in order {
			if removed >= goal do break
			c := candidates[i]
			if busy[c.u] || busy[c.v] do continue
			stamp_id += 1
			r, ok := collapse_ok(c.u, c.v, tris[:], offsets, adjacent, remap, stamp, seen, stamp_id, pos)
			if !ok do continue
			remap[c.u] = c.v
			busy[c.u], busy[c.v] = true, true
			removed += r
			worst = max(worst, f64(c.cost))
			append(&done, [2]u32{c.u, c.v})
		}
		if len(done) == 0 do break

		for d in done {
			quadrics[d[1]] += quadrics[d[0]]
			alive[d[0]] = false
		}
		kept := 0
		for tri in tris {
			a, b, c := remap[tri[0]], remap[tri[1]], remap[tri[2]]
			if a == b || b == c || c == a do continue
			tris[kept] = {a, b, c}
			kept += 1
		}
		resize(&tris, kept)
		for d in done {
			remap[d[0]] = d[0]
			busy[d[0]], busy[d[1]] = false, false
		}
		adjacency(tris[:], offsets, cursor, adjacent)
	}
	return f32(math.sqrt(worst))
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
