package sparse

import "base:runtime"
import "core:math"

// Hermitian systems: complex unknowns, a matrix equal to its conjugate transpose and
// positive definite, factored as P H Pᵀ = L D Lᴴ (L unit lower triangular and complex, D
// real) by the same up-looking pass as the LDLᵀ, over the same symbolic pass. A real
// system whose unknowns come in pairs that every entry turns and scales alike (each 2 by
// 2 block [a -b; b a], as a frame field's (cos 4θ, sin 4θ) pairs are coupled) is this
// system at half the size: a pair is one complex unknown, a block one complex entry
// a + ib. Its factor holds a quarter of the real factor's entries in half the memory and
// takes about half its flops, and its order (AMD over the pairs) keeps each pair
// together, which the real system's order need not.

// A Hermitian n by n matrix as its upper triangle by columns: column j holds
// rows[first[j]:first[j + 1]], ascending and none above j, the entry at row i being
// H[i][j]; the entry below is its conjugate, and the diagonal is real.
Hermitian :: struct {
	n:      int,
	first:  []int,
	rows:   []i32,
	values: []complex128,
}

// Entries waiting to become a Hermitian: (row, column, value), an entry given more than
// once summed.
Hermitian_Triplets :: struct {
	n:       int,
	rows:    [dynamic]i32,
	columns: [dynamic]i32,
	values:  [dynamic]complex128,
}

hermitian_triplets_make :: proc(n: int, capacity := 0, allocator := context.allocator) -> Hermitian_Triplets {
	return {
		n = n,
		rows = make([dynamic]i32, 0, capacity, allocator),
		columns = make([dynamic]i32, 0, capacity, allocator),
		values = make([dynamic]complex128, 0, capacity, allocator),
	}
}

hermitian_triplets_destroy :: proc(t: ^Hermitian_Triplets) {
	delete(t.rows)
	delete(t.columns)
	delete(t.values)
	t^ = {}
}

// Adds `value` at (i, j) and its conjugate at (j, i): on the diagonal only its real part
// counts.
hermitian_triplets_add :: #force_inline proc(t: ^Hermitian_Triplets, i, j: int, value: complex128) {
	append(&t.rows, i32(min(i, j)))
	append(&t.columns, i32(max(i, j)))
	switch {
	case i < j: append(&t.values, value)
	case i > j: append(&t.values, conj(value))
	case: append(&t.values, complex(real(value), 0))
	}
}

// The Hermitian matrix the triplets make, duplicates summed in the triplets' order.
// Returns false when an index is out of range.
hermitian_from_triplets :: proc(t: Hermitian_Triplets, allocator := context.allocator) -> (m: Hermitian, ok: bool) {
	heap := runtime.heap_allocator()
	if !in_range(t.rows[:], t.columns[:], t.n) do return {}, false
	m.n = t.n
	m.first = make([]int, t.n + 1, allocator)
	place, entries := compress(t.rows[:], t.columns[:], m.first)
	defer delete(place, heap)
	m.rows = make([]i32, entries, allocator)
	m.values = make([]complex128, entries, allocator)
	for k in 0 ..< len(t.values) {
		m.rows[place[k]] = t.rows[k]
		m.values[place[k]] += t.values[k]
	}
	return m, true
}

hermitian_destroy :: proc(m: ^Hermitian, allocator := context.allocator) {
	delete(m.first, allocator)
	delete(m.rows, allocator)
	delete(m.values, allocator)
	m^ = {}
}

// The matrix's pattern, for ldlt_analyze and amd_order (which read no values).
hermitian_pattern :: proc(m: Hermitian) -> Symmetric {
	return {n = m.n, first = m.first, rows = m.rows}
}

// y = H x.
hermitian_multiply :: proc(m: Hermitian, x, y: []complex128) {
	for &v in y do v = 0
	for j in 0 ..< m.n {
		xj, sum := x[j], complex128(0)
		for p in m.first[j] ..< m.first[j + 1] {
			i, v := int(m.rows[p]), m.values[p]
			y[i] += v * xj
			if i != j do sum += conj(v) * x[i]
		}
		y[j] += sum
	}
}

// The largest |H x - b| over the largest |b| (or over 1 when b is zero).
hermitian_residual :: proc(m: Hermitian, x, b: []complex128) -> f64 {
	heap := runtime.heap_allocator()
	y := make([]complex128, m.n, heap)
	defer delete(y, heap)
	hermitian_multiply(m, x, y)
	worst, scale := f64(0), f64(0)
	for i in 0 ..< m.n {
		worst = max(worst, abs(y[i] - b[i]))
		scale = max(scale, abs(b[i]))
	}
	return worst / (scale if scale > 0 else 1)
}

Hermitian_Factor :: struct {
	symbolic: ^Symbolic,
	rows:     []i32, // L's row of each entry below the diagonal, by columns
	values:   []complex128,
	diagonal: []f64, // D
}

// Factors the matrix, whose pattern must be the one `s` was made from (ldlt_analyze of
// hermitian_pattern). The factor's arrays are made on its first use and reused after.
// Returns false on a pivot that is zero or not finite.
hermitian_factor :: proc(f: ^Hermitian_Factor, s: ^Symbolic, m: Hermitian, allocator := context.allocator) -> bool {
	heap := runtime.heap_allocator()
	n := s.n
	fill := symbolic_fill(s^)
	if f.symbolic != s || len(f.rows) != fill || len(f.diagonal) != n {
		hermitian_factor_destroy(f, allocator)
		f.symbolic = s
		f.rows = make([]i32, fill, allocator)
		f.values = make([]complex128, fill, allocator)
		f.diagonal = make([]f64, n, allocator)
	}
	y := make([]complex128, n, heap)
	defer delete(y, heap)
	pattern := make([]i32, n, heap)
	defer delete(pattern, heap)
	flag := make([]i32, n, heap)
	defer delete(flag, heap)
	filled := make([]int, n, heap)
	defer delete(filled, heap)

	for k in 0 ..< n {
		// Column k of P H Pᵀ's upper triangle scattered into y, and row k's reach in the
		// tree, each node before its parent. An entry the order turned to the other side of
		// the diagonal is the conjugate of the one stored.
		top := n
		flag[k] = i32(k)
		for p in s.c_first[k] ..< s.c_first[k + 1] {
			i := s.c_rows[p]
			from := s.c_from[p]
			v := m.values[from]
			if int(i) != k && int(s.inverse[m.rows[from]]) == k do v = conj(v)
			y[i] += v
			length := 0
			for ; flag[i] != i32(k); i = s.parent[i] {
				pattern[length] = i
				length += 1
				flag[i] = i32(k)
			}
			for length > 0 {
				top -= 1
				length -= 1
				pattern[top] = pattern[length]
			}
		}
		d := real(y[k])
		y[k] = 0
		// Row k of L from the forward solve L w = column k, as the LDLᵀ's: L[k][i] is
		// conj(w_i) / D_i, and D_k loses |w_i|² / D_i.
		ys := raw_data(y)
		for ; top < n; top += 1 {
			i := pattern[top]
			yi := ys[i]
			ys[i] = 0
			start := s.first[i]
			count := filled[i]
			rows, values := raw_data(f.rows[start:]), raw_data(f.values[start:])
			for q in 0 ..< count do ys[rows[q]] -= values[q] * yi
			di := f.diagonal[i]
			l := complex(real(yi) / di, -imag(yi) / di)
			d -= real(l) * real(yi) - imag(l) * imag(yi)
			rows[count] = i32(k)
			values[count] = l
			filled[i] += 1
		}
		if d == 0 || d != d || abs(d) > math.F64_MAX do return false
		f.diagonal[k] = d
	}
	return true
}

hermitian_factor_destroy :: proc(f: ^Hermitian_Factor, allocator := context.allocator) {
	delete(f.rows, allocator)
	delete(f.values, allocator)
	delete(f.diagonal, allocator)
	f^ = {}
}

// Solves H x = b with the factor; x and b may be the same slice.
hermitian_solve :: proc(f: ^Hermitian_Factor, b, x: []complex128) {
	heap := runtime.heap_allocator()
	s := f.symbolic
	n := s.n
	y := make([]complex128, n, heap)
	defer delete(y, heap)
	for k in 0 ..< n do y[k] = b[s.order[k]]
	for j in 0 ..< n {
		yj := y[j]
		if yj == 0 do continue
		for p in s.first[j] ..< s.first[j + 1] do y[f.rows[p]] -= f.values[p] * yj
	}
	for j in 0 ..< n do y[j] = complex(real(y[j]) / f.diagonal[j], imag(y[j]) / f.diagonal[j])
	for j := n - 1; j >= 0; j -= 1 {
		sum := y[j]
		for p in s.first[j] ..< s.first[j + 1] do sum -= conj(f.values[p]) * y[f.rows[p]]
		y[j] = sum
	}
	for k in 0 ..< n do x[s.order[k]] = y[k]
}
