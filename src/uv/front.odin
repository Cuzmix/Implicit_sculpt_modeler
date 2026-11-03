package uv

import "base:runtime"
import "core:slice"
import "core:sync"

import "../jobs"

// The flattening's fast direct solver: a multifrontal LDLᵀ factor (Duff and Reid 1983)
// over the tree a nested dissection gives. Each part of the tree gathers its pivots and
// the later unknowns they touch into a dense "front", takes its children's leftover
// updates, eliminates its pivots there with dense blocked loops and hands what is left to
// its parent. Parts of one depth are independent and run side by side, and the one big
// front at the top shares its rows out over the pool; each row's sums run in the same
// order on any pool, so the factor does not depend on it. The same answers as ldl_factor,
// many times faster on a big island, whose separators make dense blocks anyway.

// One part's share of the factor.
Front :: struct {
	index:  []u32, // its unknowns: the pivots, then the later ones they touch, ascending
	pivots: int,
	l:      []f64, // len(index) by pivots, by rows: l[i * pivots + k] for i > k
	d:      []f64, // per pivot
}

Fronts :: struct {
	n:     int,
	parts: []Front, // in the tree's order: each after its children
}

fronts_destroy :: proc(f: ^Fronts, allocator := context.allocator) {
	for &p in f.parts {
		delete(p.index, allocator)
		delete(p.l, allocator)
		delete(p.d, allocator)
	}
	delete(f.parts, allocator)
	f^ = {}
}

// Pivots eliminated together, whose updates of the rest of the front go as one pass.
@(private)
PANEL :: 32
// Fronts with at least this many rows share their updates out over the pool.
@(private)
WIDE_FRONT :: 384

// Factors `a` (whose order the tree `tree` gives: each part's unknowns are ranks
// [lo, hi) of it, its pivots [middle, hi)) with `pool` (nil for one thread). False, with
// nothing kept, when a pivot is not positive.
front_factor :: proc(a: Sparse, tree: []Dissection_Node, pool: ^jobs.Pool = nil, allocator := context.allocator) -> (f: Fronts, ok: bool) {
	n := a.n
	// Each unknown's entries below the diagonal, from the upper triangle by columns.
	below_first := make([]u32, n + 1, allocator)
	defer delete(below_first, allocator)
	for j in 0 ..< n do for p in a.first[j] ..< a.first[j + 1] do if int(a.row[p]) < j do below_first[a.row[p] + 1] += 1
	for i in 0 ..< n do below_first[i + 1] += below_first[i]
	below_row := make([]u32, below_first[n], allocator)
	defer delete(below_row, allocator)
	below_value := make([]f64, below_first[n], allocator)
	defer delete(below_value, allocator)
	diagonal := make([]f64, n, allocator)
	defer delete(diagonal, allocator)
	fill := make([]u32, n, allocator)
	defer delete(fill, allocator)
	copy(fill, below_first[:n])
	for j in 0 ..< n do for p in a.first[j] ..< a.first[j + 1] {
		i := a.row[p]
		if int(i) == j {
			diagonal[j] += a.value[p]
			continue
		}
		below_row[fill[i]], below_value[fill[i]] = u32(j), a.value[p]
		fill[i] += 1
	}

	parts := len(tree)
	f.n = n
	f.parts = make([]Front, parts, allocator)
	updates := make([][]f64, parts, allocator)
	defer {
		for u in updates do delete(u, allocator)
		delete(updates, allocator)
	}
	children := make([][dynamic]u32, parts, allocator)
	defer {
		for c in children do delete(c)
		delete(children, allocator)
	}
	for &c in children do c = make([dynamic]u32, allocator)
	depth := make([]u32, parts, allocator)
	defer delete(depth, allocator)
	deepest: u32
	for i := parts - 1; i >= 0; i -= 1 {
		if p := tree[i].parent; p >= 0 {
			depth[i] = depth[p] + 1
			append(&children[p], u32(i))
		}
		deepest = max(deepest, depth[i])
	}
	Job :: struct {
		below_first, below_row: []u32,
		below_value, diagonal:  []f64,
		tree:                   []Dissection_Node,
		f:                      ^Fronts,
		updates:                [][]f64,
		children:               [][dynamic]u32,
		level:                  []u32,
		failed:                 bool,
		allocator:              runtime.Allocator,
	}
	job := Job{below_first, below_row, below_value, diagonal, tree, &f, updates, children, nil, false, allocator}
	level := make([dynamic]u32, allocator)
	defer delete(level)
	for d := int(deepest); d >= 0; d -= 1 {
		clear(&level)
		for i in 0 ..< parts do if depth[i] == u32(d) do append(&level, u32(i))
		job.level = level[:]
		if len(level) == 1 {
			front_part(&job, int(level[0]), pool)
		} else {
			jobs.parallel_for(pool, len(level), &job, proc(data: rawptr, n: int) {
				job := cast(^Job)data
				front_part(job, int(job.level[n]), nil)
			})
		}
		if sync.atomic_load(&job.failed) {
			fronts_destroy(&f, allocator)
			return {}, false
		}
	}
	return f, true
}

// Builds and eliminates part `i`'s front, after its children's.
@(private)
front_part :: proc(job: ^$J, i: int, pool: ^jobs.Pool) {
	a := job.allocator
	node := job.tree[i]
	pivots := int(node.hi - node.middle)
	// The later unknowns the pivots touch, directly or through the children's updates.
	later := make([dynamic]u32, a)
	defer delete(later)
	for p in node.middle ..< node.hi do for x in job.below_first[p] ..< job.below_first[p + 1] do if r := job.below_row[x]; r >= node.hi do append(&later, r)
	for c in job.children[i] {
		kid := &job.f.parts[c]
		for r in kid.index[kid.pivots:] do if r >= node.hi do append(&later, r)
	}
	slice.sort(later[:])
	kept := 0
	for r, x in later do if x == 0 || r != later[kept - 1] {
		later[kept] = r
		kept += 1
	}
	size := pivots + kept
	part := &job.f.parts[i]
	part.pivots = pivots
	part.index = make([]u32, size, a)
	for k in 0 ..< pivots do part.index[k] = node.middle + u32(k)
	copy(part.index[pivots:], later[:kept])
	at :: proc(part: ^Front, middle, hi, r: u32) -> int {
		if r < hi do return int(r - middle)
		x, found := slice.binary_search(part.index[part.pivots:], r)
		assert(found)
		return part.pivots + x
	}

	// The front, dense by rows; only its lower triangle is used.
	front := make([]f64, size * size, a)
	defer delete(front, a)
	for k in 0 ..< pivots {
		p := node.middle + u32(k)
		front[k * size + k] += job.diagonal[p]
		for x in job.below_first[p] ..< job.below_first[p + 1] {
			front[at(part, node.middle, node.hi, job.below_row[x]) * size + k] += job.below_value[x]
		}
	}
	for c in job.children[i] {
		kid := &job.f.parts[c]
		rest := kid.index[kid.pivots:]
		u := job.updates[c]
		place := make([]int, len(rest), a)
		defer delete(place, a)
		for r, x in rest do place[x] = at(part, node.middle, node.hi, r)
		for r in 0 ..< len(rest) do for s in 0 ..= r do front[place[r] * size + place[s]] += u[r * len(rest) + s]
		delete(job.updates[c], a)
		job.updates[c] = nil
	}

	// Eliminates the pivots a panel at a time: each panel's own columns first, then the
	// rest of the front by the panel in one pass.
	part.d = make([]f64, pivots, a)
	left := make([]f64, size * PANEL, a)
	defer delete(left, a)
	right := make([]f64, size * PANEL, a)
	defer delete(right, a)
	for k0 := 0; k0 < pivots; k0 += PANEL {
		k1 := min(k0 + PANEL, pivots)
		for k in k0 ..< k1 {
			d := front[k * size + k]
			if !(d > 0) {
				sync.atomic_store(&job.failed, true)
				return
			}
			part.d[k] = d
			for j in k + 1 ..< k1 {
				w := front[j * size + k] / d
				for r in j ..< size do front[r * size + j] -= front[r * size + k] * w
			}
		}
		width := k1 - k0
		// left[r] holds row r's panel entries as they were (L·D), right[r] as L.
		for r in k1 ..< size do for k in k0 ..< k1 {
			left[r * PANEL + k - k0] = front[r * size + k]
			right[r * PANEL + k - k0] = front[r * size + k] / part.d[k]
		}
		Update :: struct {
			front, left, right: []f64,
			size, k1, width:    int,
		}
		up := Update{front, left, right, size, k1, width}
		rows :: proc(data: rawptr, lo, hi: int) {
			up := cast(^Update)data
			for r in up.k1 + lo ..< up.k1 + hi {
				lr := up.left[r * PANEL:][:up.width]
				row := up.front[r * up.size:]
				for s in up.k1 ..= r {
					rs := up.right[s * PANEL:][:up.width]
					sum: f64
					for k in 0 ..< up.width do sum += lr[k] * rs[k]
					row[s] -= sum
				}
			}
		}
		if pool != nil && size >= WIDE_FRONT {
			jobs.parallel_ranges(pool, size - k1, &up, rows, 16)
		} else {
			rows(&up, 0, size - k1)
		}
		for k in k0 ..< k1 do for r in k + 1 ..< size do front[r * size + k] /= part.d[k]
	}
	part.l = make([]f64, size * pivots, a)
	for r in 0 ..< size do for k in 0 ..< min(r, pivots) do part.l[r * pivots + k] = front[r * size + k]
	rest := size - pivots
	if rest > 0 && node.parent >= 0 {
		u := make([]f64, rest * rest, a)
		for r in 0 ..< rest do for s in 0 ..= r do u[r * rest + s] = front[(pivots + r) * size + pivots + s]
		job.updates[i] = u
	}
}

// Solves L·D·Lᵀ·x = b in place in `x`, in the factor's order.
front_solve :: proc(f: Fronts, x: []f64) {
	for &part in f.parts {
		size := len(part.index)
		for k in 0 ..< part.pivots {
			xk := x[part.index[k]]
			for r in k + 1 ..< size do x[part.index[r]] -= part.l[r * part.pivots + k] * xk
		}
	}
	for &part in f.parts do for k in 0 ..< part.pivots do x[part.index[k]] /= part.d[k]
	for p := len(f.parts) - 1; p >= 0; p -= 1 {
		part := &f.parts[p]
		size := len(part.index)
		for k := part.pivots - 1; k >= 0; k -= 1 {
			s := x[part.index[k]]
			for r in k + 1 ..< size do s -= part.l[r * part.pivots + k] * x[part.index[r]]
			x[part.index[k]] = s
		}
	}
}
