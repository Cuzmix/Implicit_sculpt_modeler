package sparse

import "base:runtime"
import "core:math"

// A sparse LDLᵀ of a symmetric matrix (A = P L D Lᵀ Pᵀ, L unit lower triangular, D
// diagonal), simplicial and up-looking as Eigen's SimplicialLDLT is: row k of L is solved
// from row k of A over the elimination tree's reach, so the factor costs about the flops
// its fill asks and no more. The symbolic pass (the order, the tree, each column's count)
// depends only on the pattern and is kept, so new numbers on the same pattern refactor
// without it. No pivoting: the matrix must be positive definite or close to it (a least
// squares system's normal matrix with a small ridge), and a pivot that comes out zero or
// not finite fails the factor rather than giving a wrong answer.

Symbolic :: struct {
	n:       int,
	order:   []i32, // the unknown eliminated k-th
	inverse: []i32, // where each unknown is eliminated
	parent:  []i32, // the elimination tree, -1 at a root
	first:   []int, // L's column k is first[k] ..< first[k + 1]
	// The permuted matrix's upper triangle (column k: the rows of P A Pᵀ above or on its
	// diagonal), its entries as indices into the matrix's values, so a refactor gathers
	// them.
	c_first: []int,
	c_rows:  []i32,
	c_from:  []i32,
}

Factor :: struct {
	symbolic: ^Symbolic,
	rows:     []i32, // L's row of each entry below the diagonal, by columns
	values:   []f64,
	diagonal: []f64, // D
}

// The order (AMD) and the structure of L for the matrix's pattern; `order` given (one
// unknown per entry) is used instead of AMD's. From `allocator`.
ldlt_analyze :: proc(m: Symmetric, order: []i32 = nil, allocator := context.allocator) -> (s: Symbolic) {
	heap := runtime.heap_allocator()
	n := m.n
	s.n = n
	if order != nil && len(order) == n {
		s.order = make([]i32, n, allocator)
		s.inverse = make([]i32, n, allocator)
		copy(s.order, order)
		for v, k in order do s.inverse[v] = i32(k)
	} else {
		s.order, s.inverse = amd_order(m, allocator)
	}

	// The permuted upper triangle by columns, each entry pointing back at its value.
	s.c_first = make([]int, n + 1, allocator)
	entries := len(m.rows)
	for j in 0 ..< n {
		for p in m.first[j] ..< m.first[j + 1] {
			a, b := s.inverse[m.rows[p]], s.inverse[j]
			s.c_first[max(a, b) + 1] += 1
		}
	}
	for k in 0 ..< n do s.c_first[k + 1] += s.c_first[k]
	s.c_rows = make([]i32, entries, allocator)
	s.c_from = make([]i32, entries, allocator)
	at := make([]int, n, heap)
	defer delete(at, heap)
	copy(at, s.c_first[:n])
	for j in 0 ..< n {
		for p in m.first[j] ..< m.first[j + 1] {
			a, b := s.inverse[m.rows[p]], s.inverse[j]
			column := max(a, b)
			s.c_rows[at[column]] = min(a, b)
			s.c_from[at[column]] = i32(p)
			at[column] += 1
		}
	}

	// The elimination tree and L's column counts: row k of L is the set of nodes met
	// walking up the tree from each row of column k until a node already marked for k.
	s.parent = make([]i32, n, allocator)
	s.first = make([]int, n + 1, allocator)
	flag := make([]i32, n, heap)
	defer delete(flag, heap)
	for k in 0 ..< n {
		s.parent[k] = -1
		flag[k] = i32(k)
		for p in s.c_first[k] ..< s.c_first[k + 1] {
			i := s.c_rows[p]
			for ; flag[i] != i32(k); i = s.parent[i] {
				if s.parent[i] == -1 do s.parent[i] = i32(k)
				s.first[i + 1] += 1
				flag[i] = i32(k)
			}
		}
	}
	for k in 0 ..< n do s.first[k + 1] += s.first[k]
	return
}

symbolic_destroy :: proc(s: ^Symbolic, allocator := context.allocator) {
	delete(s.order, allocator)
	delete(s.inverse, allocator)
	delete(s.parent, allocator)
	delete(s.first, allocator)
	delete(s.c_first, allocator)
	delete(s.c_rows, allocator)
	delete(s.c_from, allocator)
	s^ = {}
}

// The entries of L, the fill the order leaves.
symbolic_fill :: proc(s: Symbolic) -> int {
	return s.first[s.n] if s.n > 0 else 0
}

// Factors the matrix, whose pattern must be the one `s` was made from. The factor's
// arrays are made on its first use and reused after. Returns false on a pivot that is zero
// or not finite (the matrix is singular or far from positive definite).
ldlt_factor :: proc(f: ^Factor, s: ^Symbolic, m: Symmetric, allocator := context.allocator) -> bool {
	heap := runtime.heap_allocator()
	n := s.n
	fill := symbolic_fill(s^)
	if f.symbolic != s || len(f.rows) != fill || len(f.diagonal) != n {
		factor_destroy(f, allocator)
		f.symbolic = s
		f.rows = make([]i32, fill, allocator)
		f.values = make([]f64, fill, allocator)
		f.diagonal = make([]f64, n, allocator)
	}
	y := make([]f64, n, heap)
	defer delete(y, heap)
	pattern := make([]i32, n, heap)
	defer delete(pattern, heap)
	flag := make([]i32, n, heap)
	defer delete(flag, heap)
	filled := make([]int, n, heap)
	defer delete(filled, heap)

	for k in 0 ..< n {
		// Row k's reach in the tree, in an order where each node comes before its parent,
		// and column k of P A Pᵀ scattered into y.
		top := n
		flag[k] = i32(k)
		for p in s.c_first[k] ..< s.c_first[k + 1] {
			i := s.c_rows[p]
			y[i] += m.values[s.c_from[p]]
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
		d := y[k]
		y[k] = 0
		// The column updates are most of the factor's time: walked through raw pointers, as
		// the column's length is known.
		ys := raw_data(y)
		for ; top < n; top += 1 {
			i := pattern[top]
			yi := ys[i]
			ys[i] = 0
			start := s.first[i]
			count := filled[i]
			rows, values := raw_data(f.rows[start:]), raw_data(f.values[start:])
			for q in 0 ..< count do ys[rows[q]] -= values[q] * yi
			l := yi / f.diagonal[i]
			d -= l * yi
			rows[count] = i32(k)
			values[count] = l
			filled[i] += 1
		}
		if d == 0 || d != d || abs(d) > math.F64_MAX do return false
		f.diagonal[k] = d
	}
	return true
}

factor_destroy :: proc(f: ^Factor, allocator := context.allocator) {
	delete(f.rows, allocator)
	delete(f.values, allocator)
	delete(f.diagonal, allocator)
	f^ = {}
}

// Solves A x = b with the factor; x and b may be the same slice.
ldlt_solve :: proc(f: ^Factor, b, x: []f64) {
	heap := runtime.heap_allocator()
	s := f.symbolic
	n := s.n
	y := make([]f64, n, heap)
	defer delete(y, heap)
	for k in 0 ..< n do y[k] = b[s.order[k]]
	for j in 0 ..< n {
		yj := y[j]
		if yj == 0 do continue
		for p in s.first[j] ..< s.first[j + 1] do y[f.rows[p]] -= f.values[p] * yj
	}
	for j in 0 ..< n do y[j] /= f.diagonal[j]
	for j := n - 1; j >= 0; j -= 1 {
		sum := y[j]
		for p in s.first[j] ..< s.first[j + 1] do sum -= f.values[p] * y[f.rows[p]]
		y[j] = sum
	}
	for k in 0 ..< n do x[s.order[k]] = y[k]
}
