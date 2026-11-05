package sparse

import "base:runtime"
import "core:slice"

// Sparse symmetric systems and their solvers: the matrix kept as its upper triangle by
// columns, assembled from triplets (an entry added twice is summed); a fill-reducing order
// (amd.odin, SuiteSparse's AMD); a sparse LDLᵀ whose symbolic pass is kept for refactoring
// the same pattern with new numbers (ldlt.odin); its complex twin for Hermitian systems
// (hermitian.odin); and conjugate gradients with a Jacobi preconditioner for a system the
// LDLᵀ cannot take (cg.odin). It knows nothing of meshes: Quad Remesh's frame field and
// cover are its first users, and UV unwrapping and deformers can use it as well. Everything runs serially in a fixed order, so a solve
// gives the same bits every time and on any machine that rounds the same way.

// A symmetric n by n matrix as its upper triangle by columns (compressed sparse column):
// column j holds rows[first[j]:first[j + 1]], ascending and none above j, with their
// values. The diagonal is stored like any entry, and missing means zero.
Symmetric :: struct {
	n:      int,
	first:  []int,
	rows:   []i32,
	values: []f64,
}

// Entries waiting to become a Symmetric: (row, column, value), either triangle, an entry
// given more than once summed.
Triplets :: struct {
	n:       int,
	rows:    [dynamic]i32,
	columns: [dynamic]i32,
	values:  [dynamic]f64,
}

triplets_make :: proc(n: int, capacity := 0, allocator := context.allocator) -> Triplets {
	return {
		n = n,
		rows = make([dynamic]i32, 0, capacity, allocator),
		columns = make([dynamic]i32, 0, capacity, allocator),
		values = make([dynamic]f64, 0, capacity, allocator),
	}
}

triplets_destroy :: proc(t: ^Triplets) {
	delete(t.rows)
	delete(t.columns)
	delete(t.values)
	t^ = {}
}

// Adds `value` at (i, j) and, the matrix being symmetric, at (j, i).
triplets_add :: #force_inline proc(t: ^Triplets, i, j: int, value: f64) {
	append(&t.rows, i32(min(i, j)))
	append(&t.columns, i32(max(i, j)))
	append(&t.values, value)
}

// The symmetric matrix the triplets make, and with `slots` each triplet's place in its
// values, so new numbers on the same pattern go in by symmetric_refill without sorting
// again. Duplicates are summed in the triplets' order, so the sums are the same every
// time. Returns false when an index is out of range.
symmetric_from_triplets :: proc(t: Triplets, slots: ^[]i32 = nil, allocator := context.allocator) -> (m: Symmetric, ok: bool) {
	heap := runtime.heap_allocator()
	n := t.n
	if !in_range(t.rows[:], t.columns[:], n) do return {}, false
	m.n = n
	m.first = make([]int, n + 1, allocator)
	place, entries := compress(t.rows[:], t.columns[:], m.first)
	defer delete(place, heap)
	m.rows = make([]i32, entries, allocator)
	m.values = make([]f64, entries, allocator)
	for k in 0 ..< len(t.values) {
		m.rows[place[k]] = t.rows[k]
		m.values[place[k]] += t.values[k]
	}
	if slots != nil do slots^ = slice.clone(place[:], allocator)
	return m, true
}

// Whether every (row, column) is inside an n by n matrix's upper triangle's range.
@(private)
in_range :: proc(rows, columns: []i32, n: int) -> bool {
	for k in 0 ..< len(rows) do if rows[k] < 0 || int(columns[k]) >= n do return false
	return true
}

// The compressed columns of the triplets' pattern (rows at or above their columns): fills
// `first` (n + 1 entries, zero) and gives each triplet's place among the entries, the
// duplicates of an entry sharing it, and how many entries there are. A counting sort by
// row and then a stable one by column leaves the triplets in column order with ascending
// rows, ties in their own order, so a sum over each entry's triplets in the triplets'
// order is the same every time.
@(private)
compress :: proc(rows, columns: []i32, first: []int) -> (place: []i32, entries: int) {
	heap := runtime.heap_allocator()
	n := len(first) - 1
	by_row := counting_order(rows, nil, n, heap)
	defer delete(by_row, heap)
	order := counting_order(columns, by_row, n, heap)
	defer delete(order, heap)
	place = make([]i32, len(rows), heap)
	last_row, last_column := i32(-1), i32(-1)
	for k in order {
		r, c := rows[k], columns[k]
		if r != last_row || c != last_column {
			entries += 1
			first[c + 1] += 1
			last_row, last_column = r, c
		}
		place[k] = i32(entries - 1)
	}
	for j in 0 ..< n do first[j + 1] += first[j]
	return
}

// Puts new numbers on a matrix made by symmetric_from_triplets: `values` holds one per
// triplet, in the triplets' order, and `slots` is what that call gave.
symmetric_refill :: proc(m: ^Symmetric, slots: []i32, values: []f64) {
	for &v in m.values do v = 0
	for s, k in slots do m.values[s] += values[k]
}

symmetric_destroy :: proc(m: ^Symmetric, allocator := context.allocator) {
	delete(m.first, allocator)
	delete(m.rows, allocator)
	delete(m.values, allocator)
	m^ = {}
}

// y = A x.
symmetric_multiply :: proc(m: Symmetric, x, y: []f64) {
	for &v in y do v = 0
	for j in 0 ..< m.n {
		xj, sum := x[j], f64(0)
		for p in m.first[j] ..< m.first[j + 1] {
			i, v := int(m.rows[p]), m.values[p]
			y[i] += v * xj
			if i != j do sum += v * x[i]
		}
		y[j] += sum
	}
}

// The largest |A x - b| over the largest |b| (or over 1 when b is zero).
relative_residual :: proc(m: Symmetric, x, b: []f64) -> f64 {
	heap := runtime.heap_allocator()
	y := make([]f64, m.n, heap)
	defer delete(y, heap)
	symmetric_multiply(m, x, y)
	worst, scale := f64(0), f64(0)
	for i in 0 ..< m.n {
		worst = max(worst, abs(y[i] - b[i]))
		scale = max(scale, abs(b[i]))
	}
	return worst / (scale if scale > 0 else 1)
}

// The positions of `keys` (each below n) sorted by key, ties kept in the order of `within`
// (all positions in order when nil): one counting pass.
@(private = "file")
counting_order :: proc(keys: []i32, within: []i32, n: int, allocator: runtime.Allocator) -> []i32 {
	start := make([]int, n + 1, allocator)
	defer delete(start, allocator)
	for k in keys do start[k + 1] += 1
	for j in 0 ..< n do start[j + 1] += start[j]
	out := make([]i32, len(keys), allocator)
	if within == nil {
		for k, i in keys {
			out[start[k]] = i32(i)
			start[k] += 1
		}
	} else {
		for i in within {
			k := keys[i]
			out[start[k]] = i
			start[k] += 1
		}
	}
	return out
}
