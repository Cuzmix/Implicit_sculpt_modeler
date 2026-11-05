package sparse

import "base:runtime"
import "core:math"
import "core:slice"

import "../jobs"

// A supernodal Cholesky factor of a symmetric positive definite matrix (A = P L Lᵀ Pᵀ),
// multifrontal: the columns of L that share a structure are grouped into supernodes,
// each a dense block, and each supernode's front (its rows by its rows, dense) is
// assembled from A's columns and its children's updates, its own columns factored in
// panels and the rest of the front updated by them as dense column operations, the
// update then handed to its parent. Most of a large factor's work lands in the top fronts
// of the tree as dense loops a compiler vectorizes, where the up-looking LDLᵀ (ldlt.odin)
// walks every entry through its indices; the fronts of disjoint subtrees are independent
// and run on the pool. Chains of supernodes are merged where the merge adds few explicit
// zeros (CHOLMOD's relaxed amalgamation), so the blocks are wide enough for the dense
// loops to pay. Every front is computed in one fixed order whatever the thread count, so
// a factor gives the same bits on one thread or many.

Supernodal_Symbolic :: struct {
	n:           int,
	order:       []i32, // the unknown eliminated k-th (AMD's order, postordered)
	inverse:     []i32,
	supers:      int,
	col_first:   []i32, // supernode s holds columns col_first[s] ..< col_first[s + 1]
	row_first:   []int, // its rows, rows[row_first[s]:row_first[s + 1]]: its own columns, then those below, ascending
	rows:        []i32,
	value_first: []int, // its block of L, column-major, rows by columns
	parent:      []i32, // the supernodes' tree, -1 at a root
	// The permuted lower triangle by columns (column j: rows at or below j), each entry
	// pointing back at its value in the matrix.
	a_first:     []int,
	a_rows:      []i32,
	a_from:      []i32,
	largest:     int, // the largest front's rows
	child_first: []i32, // supernode s's children are child[child_first[s]:child_first[s + 1]], ascending
	child:       []i32,
	// Pieces for the pool: piece i is supernodes subtree_first[2i] ..< subtree_first[2i + 1],
	// a whole subtree; the supernodes in no piece run after them all.
	subtree_first: []i32,
	split:       int,
}

Supernodal_Factor :: struct {
	symbolic: ^Supernodal_Symbolic,
	values:   []f64,
}

// The relaxed amalgamation's limits (CHOLMOD's defaults): a merged supernode of up to
// RELAX_COLUMNS[i] columns may hold up to RELAX_ZEROS[i] of explicit zeros, and any of at
// most 4 columns is merged whatever its zeros.
@(private = "file")
RELAX_COLUMNS := [3]int{4, 16, 48}
@(private = "file")
RELAX_ZEROS := [3]f64{0.8, 0.1, 0.05}

// The panel width of the dense factor's blocked loops.
@(private = "file")
PANEL :: 32

// The order (AMD's, or `order` given), postordered, the supernodes and their structures.
supernodal_analyze :: proc(m: Symmetric, order: []i32 = nil, allocator := context.allocator) -> (s: Supernodal_Symbolic) {
	heap := runtime.heap_allocator()
	n := m.n
	s.n = n
	first_order, first_inverse: []i32
	if order != nil && len(order) == n {
		first_order = slice.clone(order, heap)
	} else {
		first_order, first_inverse = amd_order(m, heap)
		delete(first_inverse, heap)
	}
	defer delete(first_order, heap)

	// The elimination tree of the order, then its postorder, so each supernode's columns
	// and each subtree's are contiguous.
	{
		inverse := make([]i32, n, heap)
		defer delete(inverse, heap)
		for v, k in first_order do inverse[v] = i32(k)
		parent := elimination_tree(m, inverse, heap)
		defer delete(parent, heap)
		post := postorder(parent, heap)
		defer delete(post, heap)
		s.order = make([]i32, n, allocator)
		s.inverse = make([]i32, n, allocator)
		for k in 0 ..< n do s.order[k] = first_order[post[k]]
		for v, k in s.order do s.inverse[v] = i32(k)
	}

	// The permuted lower triangle by columns.
	s.a_first = make([]int, n + 1, allocator)
	for j in 0 ..< n do for p in m.first[j] ..< m.first[j + 1] {
		a, b := s.inverse[m.rows[p]], s.inverse[j]
		s.a_first[min(a, b) + 1] += 1
	}
	for k in 0 ..< n do s.a_first[k + 1] += s.a_first[k]
	s.a_rows = make([]i32, len(m.rows), allocator)
	s.a_from = make([]i32, len(m.rows), allocator)
	{
		at := make([]int, n, heap)
		defer delete(at, heap)
		copy(at, s.a_first[:n])
		for j in 0 ..< n do for p in m.first[j] ..< m.first[j + 1] {
			a, b := s.inverse[m.rows[p]], s.inverse[j]
			column := min(a, b)
			s.a_rows[at[column]] = max(a, b)
			s.a_from[at[column]] = i32(p)
			at[column] += 1
		}
		// Each column's rows ascending, so a front's assembly walks its rows in order.
		for k in 0 ..< n {
			lo, hi := s.a_first[k], s.a_first[k + 1]
			sort_pairs(s.a_rows[lo:hi], s.a_from[lo:hi])
		}
	}

	// The tree and each column's count in the final order (the count walks each row's
	// reach up the tree, as ldlt_analyze does).
	parent := make([]i32, n, heap)
	defer delete(parent, heap)
	count := make([]int, n, heap)
	defer delete(count, heap)
	{
		flag := make([]i32, n, heap)
		defer delete(flag, heap)
		for k in 0 ..< n {
			parent[k] = -1
			flag[k] = i32(k)
			count[k] += 1
		}
		// Row k's entries left of the diagonal are the lower triangle's entries in row k:
		// walk the lower columns instead, by the transpose.
		up_first := make([]int, n + 1, heap)
		defer delete(up_first, heap)
		for j in 0 ..< n do for p in s.a_first[j] ..< s.a_first[j + 1] do if int(s.a_rows[p]) != j do up_first[s.a_rows[p] + 1] += 1
		for k in 0 ..< n do up_first[k + 1] += up_first[k]
		up := make([]i32, up_first[n], heap)
		defer delete(up, heap)
		at := make([]int, n, heap)
		defer delete(at, heap)
		copy(at, up_first[:n])
		for j in 0 ..< n do for p in s.a_first[j] ..< s.a_first[j + 1] {
			i := s.a_rows[p]
			if int(i) == j do continue
			up[at[i]] = i32(j)
			at[i] += 1
		}
		for k in 0 ..< n {
			for p in up_first[k] ..< up_first[k + 1] {
				for i := up[p]; flag[i] != i32(k); i = parent[i] {
					if parent[i] == -1 do parent[i] = i32(k)
					count[i] += 1
					flag[i] = i32(k)
				}
			}
		}
	}

	// Fundamental supernodes: column j + 1 joins j's when it is j's parent, j its only
	// child, and its structure is j's less j.
	children := make([]i32, n, heap)
	defer delete(children, heap)
	for p in parent do if p >= 0 do children[p] += 1
	starts := make([dynamic]i32, heap)
	defer delete(starts)
	for j in 0 ..< n {
		if j == 0 || !(parent[j - 1] == i32(j) && count[j - 1] == count[j] + 1 && children[j] == 1) do append(&starts, i32(j))
	}
	fundamental := len(starts)
	append(&starts, i32(n))
	super_of := make([]i32, n, heap)
	defer delete(super_of, heap)
	for f in 0 ..< fundamental do for j in starts[f] ..< starts[f + 1] do super_of[j] = i32(f)
	f_parent := make([]i32, fundamental, heap)
	defer delete(f_parent, heap)
	for f in 0 ..< fundamental {
		last := starts[f + 1] - 1
		f_parent[f] = super_of[parent[last]] if parent[last] >= 0 else -1
	}

	// Relaxed amalgamation: a supernode merges with its parent when the parent follows it
	// and the merged block's explicit zeros are within the limits. Walked from the top so
	// each merge sees its parent's block already formed.
	columns := make([]int, fundamental, heap)
	defer delete(columns, heap)
	first_count := make([]int, fundamental, heap)
	defer delete(first_count, heap)
	zeros := make([]f64, fundamental, heap)
	defer delete(zeros, heap)
	merged := make([]bool, fundamental, heap)
	defer delete(merged, heap)
	for f in 0 ..< fundamental {
		columns[f] = int(starts[f + 1] - starts[f])
		first_count[f] = count[starts[f]]
	}
	for f := fundamental - 2; f >= 0; f -= 1 {
		p := f + 1
		if f_parent[f] != i32(p) do continue
		nc := columns[f] + columns[p]
		fc := columns[f] + first_count[p]
		dense := f64(nc) * f64(fc) - f64(nc) * f64(nc - 1) / 2
		own := f64(columns[f]) * f64(first_count[f]) - f64(columns[f]) * f64(columns[f] - 1) / 2
		theirs := f64(columns[p]) * f64(first_count[p]) - f64(columns[p]) * f64(columns[p] - 1) / 2
		z := dense - own - (theirs - zeros[p])
		fraction := z / dense if dense > 0 else 0
		join := nc <= RELAX_COLUMNS[0] || (nc <= RELAX_COLUMNS[1] && fraction < RELAX_ZEROS[0]) || (nc <= RELAX_COLUMNS[2] && fraction < RELAX_ZEROS[1]) || fraction < RELAX_ZEROS[2]
		if !join do continue
		columns[f], first_count[f], zeros[f] = nc, fc, z
		merged[p] = true
	}
	col_first := make([dynamic]i32, heap)
	defer delete(col_first)
	for f in 0 ..< fundamental do if !merged[f] do append(&col_first, starts[f])
	s.supers = len(col_first)
	append(&col_first, i32(n))
	s.col_first = slice.clone(col_first[:], allocator)
	for t in 0 ..< s.supers do for j in s.col_first[t] ..< s.col_first[t + 1] do super_of[j] = i32(t)
	s.parent = make([]i32, s.supers, allocator)
	for t in 0 ..< s.supers {
		last := s.col_first[t + 1] - 1
		s.parent[t] = super_of[parent[last]] if parent[last] >= 0 else -1
	}

	// Each supernode's rows: its columns, then the rows below them of its columns in A and
	// of its children's structures. Children come before their parent in the order.
	s.child_first = make([]i32, s.supers + 1, allocator)
	for p in s.parent do if p >= 0 do s.child_first[p + 1] += 1
	for t in 0 ..< s.supers do s.child_first[t + 1] += s.child_first[t]
	s.child = make([]i32, s.child_first[s.supers], allocator)
	{
		at := make([]i32, s.supers, heap)
		defer delete(at, heap)
		copy(at, s.child_first[:s.supers])
		for t in 0 ..< s.supers do if s.parent[t] >= 0 {
			s.child[at[s.parent[t]]] = i32(t)
			at[s.parent[t]] += 1
		}
	}
	mark := make([]i32, n, heap)
	defer delete(mark, heap)
	for &x in mark do x = -1
	rows := make([dynamic]i32, heap)
	defer delete(rows)
	s.row_first = make([]int, s.supers + 1, allocator)
	below := make([dynamic]i32, heap)
	defer delete(below)
	for t in 0 ..< s.supers {
		lo, hi := s.col_first[t], s.col_first[t + 1]
		clear(&below)
		for j in lo ..< hi do for p in s.a_first[j] ..< s.a_first[j + 1] {
			i := s.a_rows[p]
			if i >= hi && mark[i] != i32(t) {
				mark[i] = i32(t)
				append(&below, i)
			}
		}
		for q in s.child_first[t] ..< s.child_first[t + 1] {
			c := s.child[q]
			for i in rows[s.row_first[c]:s.row_first[c + 1]] do if i >= hi && mark[i] != i32(t) {
				mark[i] = i32(t)
				append(&below, i)
			}
		}
		slice.sort(below[:])
		for j in lo ..< hi do append(&rows, j)
		append(&rows, ..below[:])
		s.row_first[t + 1] = len(rows)
	}
	s.rows = slice.clone(rows[:], allocator)
	s.value_first = make([]int, s.supers + 1, allocator)
	for t in 0 ..< s.supers {
		r := s.row_first[t + 1] - s.row_first[t]
		c := int(s.col_first[t + 1] - s.col_first[t])
		s.value_first[t + 1] = s.value_first[t] + r * c
		s.largest = max(s.largest, r)
	}

	plan_subtrees(&s, allocator)
	return
}

supernodal_symbolic_destroy :: proc(s: ^Supernodal_Symbolic, allocator := context.allocator) {
	delete(s.order, allocator)
	delete(s.inverse, allocator)
	delete(s.col_first, allocator)
	delete(s.row_first, allocator)
	delete(s.rows, allocator)
	delete(s.value_first, allocator)
	delete(s.parent, allocator)
	delete(s.a_first, allocator)
	delete(s.a_rows, allocator)
	delete(s.a_from, allocator)
	delete(s.child_first, allocator)
	delete(s.child, allocator)
	delete(s.subtree_first, allocator)
	s^ = {}
}

// L's entries, explicit zeros of the merged supernodes counted.
supernodal_fill :: proc(s: Supernodal_Symbolic) -> int {
	fill := 0
	for t in 0 ..< s.supers {
		r := s.row_first[t + 1] - s.row_first[t]
		c := int(s.col_first[t + 1] - s.col_first[t])
		fill += r * c - c * (c - 1) / 2
	}
	return fill
}

// The elimination tree of the matrix permuted by `inverse` (Liu's, with path compression).
@(private = "file")
elimination_tree :: proc(m: Symmetric, inverse: []i32, allocator: runtime.Allocator) -> []i32 {
	heap := runtime.heap_allocator()
	n := m.n
	// Row k of the permuted upper triangle: the permuted columns of A's entries with k.
	up_first := make([]int, n + 1, heap)
	defer delete(up_first, heap)
	for j in 0 ..< n do for p in m.first[j] ..< m.first[j + 1] {
		a, b := inverse[m.rows[p]], inverse[j]
		if a != b do up_first[max(a, b) + 1] += 1
	}
	for k in 0 ..< n do up_first[k + 1] += up_first[k]
	up := make([]i32, up_first[n], heap)
	defer delete(up, heap)
	at := make([]int, n, heap)
	defer delete(at, heap)
	copy(at, up_first[:n])
	for j in 0 ..< n do for p in m.first[j] ..< m.first[j + 1] {
		a, b := inverse[m.rows[p]], inverse[j]
		if a == b do continue
		hi := max(a, b)
		up[at[hi]] = min(a, b)
		at[hi] += 1
	}
	parent := make([]i32, n, allocator)
	ancestor := make([]i32, n, heap)
	defer delete(ancestor, heap)
	for k in 0 ..< n {
		parent[k] = -1
		ancestor[k] = -1
		for p in up_first[k] ..< up_first[k + 1] {
			i := up[p]
			for i != -1 && i < i32(k) {
				next := ancestor[i]
				ancestor[i] = i32(k)
				if next == -1 {
					parent[i] = i32(k)
					break
				}
				i = next
			}
		}
	}
	return parent
}

// A postorder of the forest `parent`: children in increasing order, each subtree contiguous.
@(private = "file")
postorder :: proc(parent: []i32, allocator: runtime.Allocator) -> []i32 {
	heap := runtime.heap_allocator()
	n := len(parent)
	head := make([]i32, n, heap)
	defer delete(head, heap)
	next := make([]i32, n, heap)
	defer delete(next, heap)
	for &h in head do h = -1
	for j := n - 1; j >= 0; j -= 1 {
		p := parent[j]
		if p == -1 do continue
		next[j] = head[p]
		head[p] = i32(j)
	}
	post := make([]i32, n, allocator)
	stack := make([]i32, n, heap)
	defer delete(stack, heap)
	k := 0
	for root in 0 ..< n {
		if parent[root] != -1 do continue
		top := 0
		stack[0] = i32(root)
		for top >= 0 {
			p := stack[top]
			c := head[p]
			if c == -1 {
				top -= 1
				post[k] = p
				k += 1
			} else {
				head[p] = next[c]
				top += 1
				stack[top] = c
			}
		}
	}
	return post
}

// Sorts `keys` ascending and `with` alongside.
@(private = "file")
sort_pairs :: proc(keys, with: []i32) {
	for i in 1 ..< len(keys) {
		k, w := keys[i], with[i]
		j := i
		for j > 0 && keys[j - 1] > k {
			keys[j] = keys[j - 1]
			with[j] = with[j - 1]
			j -= 1
		}
		keys[j], with[j] = k, w
	}
}

// Cuts the supernodes' tree into subtrees for the pool: starting from the roots, the
// subtree of most work is replaced by its children until there are PIECES or none is
// worth splitting. Each piece is a run of the postorder (its root and the supernodes
// before it down to its lowest descendant); the rest, the tops, are its ancestors and run
// after every piece. The cut depends on the tree alone, never on the pool, so any thread
// count factors the same fronts in the same order.
@(private = "file")
plan_subtrees :: proc(s: ^Supernodal_Symbolic, allocator: runtime.Allocator) {
	heap := runtime.heap_allocator()
	if s.supers < 2 * PIECES {
		s.subtree_first = make([]i32, 1, allocator)
		s.split = 0
		return
	}
	work := make([]f64, s.supers, heap)
	defer delete(work, heap)
	low := make([]i32, s.supers, heap)
	defer delete(low, heap)
	for t in 0 ..< s.supers {
		r := f64(s.row_first[t + 1] - s.row_first[t])
		c := f64(s.col_first[t + 1] - s.col_first[t])
		work[t] += c * r * r
		low[t] = i32(t)
	}
	for t in 0 ..< s.supers {
		p := s.parent[t]
		if p >= 0 {
			work[p] += work[t]
			low[p] = min(low[p], low[t])
		}
	}
	total := f64(0)
	pieces := make([dynamic]i32, heap)
	defer delete(pieces)
	for t in 0 ..< s.supers do if s.parent[t] == -1 {
		append(&pieces, i32(t))
		total += work[t]
	}
	for len(pieces) < PIECES {
		best := -1
		for p, i in pieces do if s.child_first[p + 1] > s.child_first[p] && (best < 0 || work[p] > work[pieces[best]] || (work[p] == work[pieces[best]] && p < pieces[best])) do best = i
		if best < 0 || work[pieces[best]] < total / f64(4 * PIECES) do break
		p := pieces[best]
		ordered_remove(&pieces, best)
		for q in s.child_first[p] ..< s.child_first[p + 1] do append(&pieces, s.child[q])
	}
	slice.sort(pieces[:])
	s.subtree_first = make([]i32, 2 * len(pieces) + 1, allocator)
	for p, i in pieces {
		s.subtree_first[2 * i] = low[p]
		s.subtree_first[2 * i + 1] = p + 1
	}
	s.subtree_first[2 * len(pieces)] = i32(s.supers)
	s.split = len(pieces)
}

// The number of subtrees the tree is cut into, at most.
@(private = "file")
PIECES :: 64

// A front with at least this many columns to update spreads its update over the pool.
@(private = "file")
SPREAD_COLUMNS :: 192

// Factors the matrix, whose pattern must be the one `s` was made from, on the pool's
// threads: the subtrees side by side, then the tops, whose larger fronts spread their
// updates. The factor's values are made on its first use and reused after. Returns false
// on a pivot that is not positive or not finite.
supernodal_factor :: proc(f: ^Supernodal_Factor, s: ^Supernodal_Symbolic, m: Symmetric, pool: ^jobs.Pool = nil, allocator := context.allocator) -> bool {
	heap := runtime.heap_allocator()
	total := s.value_first[s.supers] if s.supers > 0 else 0
	if f.symbolic != s || len(f.values) != total {
		supernodal_factor_destroy(f, allocator)
		f.symbolic = s
		f.values = make([]f64, total, allocator)
	}
	Run :: struct {
		f:      ^Supernodal_Factor,
		s:      ^Supernodal_Symbolic,
		m:      Symmetric,
		roots:  [][]f64, // per piece: its root's update, for the tops
		failed: bool,
	}
	run := Run{f, s, m, make([][]f64, s.split, heap), false}
	defer {
		for r in run.roots do delete(r, heap)
		delete(run.roots, heap)
	}
	jobs.parallel_for(pool if s.split > 1 else nil, s.split, &run, proc(data: rawptr, i: int) {
		run := cast(^Run)data
		s := run.s
		w := front_work_make(s)
		defer front_work_destroy(&w)
		lo, hi := int(s.subtree_first[2 * i]), int(s.subtree_first[2 * i + 1])
		for t in lo ..< hi {
			if !factor_front(run.f, s, run.m, &w, t, nil, nil) {
				run.failed = true
				return
			}
		}
		// The root's update is all that is left on the stack.
		if len(w.updates) == 1 do run.roots[i] = slice.clone(w.stack[:], runtime.heap_allocator())
	})
	if run.failed do return false
	// The tops, with the pieces' roots' updates in their slots.
	slot := make([]i32, s.supers, heap)
	defer delete(slot, heap)
	for &x in slot do x = -1
	in_piece := make([]bool, s.supers, heap)
	defer delete(in_piece, heap)
	for i in 0 ..< s.split {
		lo, hi := s.subtree_first[2 * i], s.subtree_first[2 * i + 1]
		for t in lo ..< hi do in_piece[t] = true
		slot[hi - 1] = i32(i)
	}
	w := front_work_make(s)
	defer front_work_destroy(&w)
	Slots :: struct {
		slot:  []i32,
		roots: [][]f64,
	}
	slots := Slots{slot, run.roots}
	for t in 0 ..< s.supers do if !in_piece[t] {
		if !factor_front(f, s, m, &w, t, &slots, pool) do return false
	}
	return true
}

@(private = "file")
Front_Work :: struct {
	front:   [dynamic]f64, // grown to the largest front met, never cleared whole
	local:   []i32, // a global row's place in the front being assembled
	stack:   [dynamic]f64, // the pending updates, each its rows' count squared
	updates: [dynamic][2]int, // per pending update: its supernode and where it starts in the stack
}

@(private = "file")
front_work_make :: proc(s: ^Supernodal_Symbolic) -> (w: Front_Work) {
	heap := runtime.heap_allocator()
	w.front = make([dynamic]f64, heap)
	w.local = make([]i32, s.n, heap)
	w.stack = make([dynamic]f64, heap)
	w.updates = make([dynamic][2]int, heap)
	return
}

@(private = "file")
front_work_destroy :: proc(w: ^Front_Work) {
	heap := runtime.heap_allocator()
	delete(w.front)
	delete(w.local, heap)
	delete(w.stack)
	delete(w.updates)
	w^ = {}
}

// Assembles, factors and updates supernode t's front. Its children's updates are added
// last child first: from the top of `w`'s stack, or for a child that is a piece's root
// from its slot (`slots`, the tops only). Pushes its own update for its parent.
@(private = "file")
factor_front :: proc(f: ^Supernodal_Factor, s: ^Supernodal_Symbolic, m: Symmetric, w: ^Front_Work, t: int, slots: rawptr, pool: ^jobs.Pool) -> bool {
	Slots :: struct {
		slot:  []i32,
		roots: [][]f64,
	}
	rows := s.rows[s.row_first[t]:s.row_first[t + 1]]
	r := len(rows)
	lo := int(s.col_first[t])
	c := int(s.col_first[t + 1]) - lo
	if len(w.front) < r * r do non_zero_resize(&w.front, r * r)
	F := w.front[:r * r]
	// Only the lower triangle is read: each column zeroed from its diagonal down.
	for j in 0 ..< r do slice.zero(F[j * r + j:(j + 1) * r])
	for i, k in rows do w.local[i] = i32(k)
	for j in 0 ..< c {
		col := lo + j
		base := j * r
		for p in s.a_first[col] ..< s.a_first[col + 1] do F[base + int(w.local[s.a_rows[p]])] += m.values[s.a_from[p]]
	}
	for q := s.child_first[t + 1] - 1; q >= s.child_first[t]; q -= 1 {
		child := s.child[q]
		crows := s.rows[s.row_first[child] + int(s.col_first[child + 1] - s.col_first[child]):s.row_first[child + 1]]
		u := len(crows)
		if u == 0 do continue
		U: []f64
		from_stack := true
		if slots != nil {
			sl := cast(^Slots)slots
			if sl.slot[child] >= 0 {
				U = sl.roots[sl.slot[child]]
				from_stack = false
			}
		}
		if from_stack {
			top := w.updates[len(w.updates) - 1]
			assert(top[0] == int(child), "supernodal_factor: a child's update is not on top of the stack")
			U = w.stack[top[1]:top[1] + u * u]
		}
		for b in 0 ..< u {
			cb := int(w.local[crows[b]]) * r
			for a in b ..< u do F[cb + int(w.local[crows[a]])] += U[a + b * u]
		}
		if from_stack {
			top := pop(&w.updates)
			resize(&w.stack, top[1])
		}
	}
	// The front's own columns, in panels; each panel then updates every column right of it.
	fr := raw_data(F)
	for j0 := 0; j0 < c; j0 += PANEL {
		j1 := min(j0 + PANEL, c)
		for j in j0 ..< j1 {
			d := fr[j + j * r]
			if !(d > 0) || d > math.F64_MAX do return false
			d = math.sqrt(d)
			fr[j + j * r] = d
			inv := 1 / d
			pj := fr[j * r:]
			for i in j + 1 ..< r do pj[i] *= inv
			for jj in j + 1 ..< j1 {
				l := pj[jj]
				if l == 0 do continue
				q := fr[jj * r:]
				for i in jj ..< r do q[i] -= pj[i] * l
			}
		}
		if pool != nil && r - j1 >= SPREAD_COLUMNS {
			spread_trailing(pool, fr, r, j0, j1)
		} else {
			update_trailing(fr, r, j0, j1, j1, r)
		}
	}
	block := f.values[s.value_first[t]:s.value_first[t + 1]]
	// The block keeps the lower triangle; above the diagonal the front holds what an
	// earlier front left there, so the block has zeros there, the same on any run.
	for j in 0 ..< c {
		slice.zero(block[j * r:j * r + j])
		copy(block[j * r + j:(j + 1) * r], F[j * r + j:(j + 1) * r])
	}
	u := r - c
	if u > 0 && s.parent[t] >= 0 {
		start := len(w.stack)
		non_zero_resize(&w.stack, start + u * u)
		U := w.stack[start:]
		for b in 0 ..< u do copy(U[b * u + b:(b + 1) * u], F[(c + b) * r + c + b:(c + b) * r + r])
		append(&w.updates, [2]int{t, start})
	}
	return true
}

// The trailing update over the pool: the columns cut into runs of about equal work, the
// work of column jj going as its length r - jj. Each column is updated as
// update_trailing updates it, so the bits do not depend on the cut.
@(private = "file")
spread_trailing :: proc(pool: ^jobs.Pool, fr: [^]f64, r, j0, j1: int) {
	Spread :: struct {
		fr:         [^]f64,
		r, j0, j1:  int,
		cuts:       [65]int,
	}
	pieces := min(4 * jobs.pool_size(pool), 64)
	sp := Spread{fr = fr, r = r, j0 = j0, j1 = j1}
	// Columns j1 ..< r; the work left of column jj is the triangle above it.
	total := f64(r - j1) * f64(r - j1 + 1) / 2
	sp.cuts[0] = j1
	jj := j1
	for k in 1 ..< pieces {
		goal := total * f64(k) / f64(pieces)
		// The work of columns j1 ..< x is total - (r - x)(r - x + 1) / 2.
		for jj < r && total - f64(r - jj) * f64(r - jj + 1) / 2 < goal do jj += 1
		sp.cuts[k] = jj
	}
	sp.cuts[pieces] = r
	jobs.parallel_for(pool, pieces, &sp, proc(data: rawptr, i: int) {
		sp := cast(^Spread)data
		update_trailing(sp.fr, sp.r, sp.j0, sp.j1, sp.cuts[i], sp.cuts[i + 1])
	})
}

// Columns jj in lo ..< hi of the r-row front, each from row jj down, less the panel
// columns j0 ..< j1 times their entries in row jj: four panel columns at a time.
@(private = "file")
update_trailing :: proc(fr: [^]f64, r, j0, j1, lo, hi: int) {
	for jj in lo ..< hi {
		q := fr[jj * r:]
		j := j0
		for ; j + 4 <= j1; j += 4 {
			p0, p1, p2, p3 := fr[j * r:], fr[(j + 1) * r:], fr[(j + 2) * r:], fr[(j + 3) * r:]
			l0, l1, l2, l3 := p0[jj], p1[jj], p2[jj], p3[jj]
			if l0 == 0 && l1 == 0 && l2 == 0 && l3 == 0 do continue
			for i in jj ..< r do q[i] -= p0[i] * l0 + p1[i] * l1 + p2[i] * l2 + p3[i] * l3
		}
		for ; j < j1; j += 1 {
			p := fr[j * r:]
			l := p[jj]
			if l == 0 do continue
			for i in jj ..< r do q[i] -= p[i] * l
		}
	}
}

supernodal_factor_destroy :: proc(f: ^Supernodal_Factor, allocator := context.allocator) {
	delete(f.values, allocator)
	f^ = {}
}

// Solves A x = b with the factor; x and b may be the same slice.
supernodal_solve :: proc(f: ^Supernodal_Factor, b, x: []f64) {
	heap := runtime.heap_allocator()
	s := f.symbolic
	n := s.n
	y := make([]f64, n, heap)
	defer delete(y, heap)
	for k in 0 ..< n do y[k] = b[s.order[k]]
	for t in 0 ..< s.supers {
		rows := s.rows[s.row_first[t]:s.row_first[t + 1]]
		r := len(rows)
		lo := int(s.col_first[t])
		c := int(s.col_first[t + 1]) - lo
		L := f.values[s.value_first[t]:]
		for j in 0 ..< c {
			col := L[j * r:]
			yj := y[lo + j] / col[j]
			y[lo + j] = yj
			if yj == 0 do continue
			for i in j + 1 ..< r do y[rows[i]] -= col[i] * yj
		}
	}
	for t := s.supers - 1; t >= 0; t -= 1 {
		rows := s.rows[s.row_first[t]:s.row_first[t + 1]]
		r := len(rows)
		lo := int(s.col_first[t])
		c := int(s.col_first[t + 1]) - lo
		L := f.values[s.value_first[t]:]
		for j := c - 1; j >= 0; j -= 1 {
			col := L[j * r:]
			sum := y[lo + j]
			for i in j + 1 ..< r do sum -= col[i] * y[rows[i]]
			y[lo + j] = sum / col[j]
		}
	}
	for k in 0 ..< n do x[s.order[k]] = y[k]
}
