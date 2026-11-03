package uv

import "base:runtime"
import "core:slice"

// A sparse direct solver for the symmetric positive definite systems the flattening
// builds (LSCM's normal equations now, ABF++'s reduced system and the relax later): an
// LDLᵀ factorization computed row by row up the elimination tree (Davis's LDL, 2005)
// over an order found by nested dissection of the unknowns' places on the surface, which
// keeps the factor's fill near n·log n on a surface where an unordered factor fills
// quadratically. Exact where conjugate gradients on these systems need thousands of
// steps (their condition grows with the island). Everything with `allocator`, so a job
// passes its heap allocator; nothing depends on the thread it runs on.

// The upper triangle of a symmetric matrix by columns: column j's entries are rows
// row[first[j]:first[j + 1]], ascending, each at most j, with their values.
Sparse :: struct {
	n:     int,
	first: []u32,
	row:   []u32,
	value: []f64,
}

sparse_destroy :: proc(a: ^Sparse, allocator := context.allocator) {
	delete(a.first, allocator)
	delete(a.row, allocator)
	delete(a.value, allocator)
	a^ = {}
}

// A factor L·D·Lᵀ: L unit lower triangular by columns (column j's rows li[lp[j]:lp[j + 1]],
// below the diagonal), D its diagonal.
Ldl :: struct {
	n:  int,
	lp: []u32,
	li: []u32,
	lx: []f64,
	d:  []f64,
}

ldl_destroy :: proc(f: ^Ldl, allocator := context.allocator) {
	delete(f.lp, allocator)
	delete(f.li, allocator)
	delete(f.lx, allocator)
	delete(f.d, allocator)
	f^ = {}
}

// Factors `a`; false, with nothing kept, when a pivot is not positive (the matrix is not
// positive definite, as a solve with too few fixed points makes it).
ldl_factor :: proc(a: Sparse, allocator := context.allocator) -> (f: Ldl, ok: bool) {
	n := a.n
	parent := make([]i32, n, allocator)
	defer delete(parent, allocator)
	flag := make([]i32, n, allocator)
	defer delete(flag, allocator)
	count := make([]u32, n, allocator)
	defer delete(count, allocator)
	// The elimination tree and each column's count, from the pattern alone.
	for k in 0 ..< n {
		parent[k], flag[k] = -1, i32(k)
		for p in a.first[k] ..< a.first[k + 1] {
			i := i32(a.row[p])
			for i < i32(k) && flag[i] != i32(k) {
				if parent[i] == -1 do parent[i] = i32(k)
				count[i] += 1
				flag[i] = i32(k)
				i = parent[i]
			}
		}
	}
	f.n = n
	f.lp = make([]u32, n + 1, allocator)
	for k in 0 ..< n do f.lp[k + 1] = f.lp[k] + count[k]
	f.li = make([]u32, f.lp[n], allocator)
	f.lx = make([]f64, f.lp[n], allocator)
	f.d = make([]f64, n, allocator)
	y := make([]f64, n, allocator)
	defer delete(y, allocator)
	pattern := make([]i32, n, allocator)
	defer delete(pattern, allocator)
	filled := count
	for &c in filled do c = 0
	for k in 0 ..< n {
		// Row k of L, from column k of the matrix: the rows reached up the tree from its
		// entries, in topological order.
		top := n
		flag[k] = i32(k)
		y[k] = 0
		for p in a.first[k] ..< a.first[k + 1] {
			i := i32(a.row[p])
			y[i] += a.value[p]
			depth := 0
			for flag[i] != i32(k) {
				pattern[depth] = i
				depth += 1
				flag[i] = i32(k)
				i = parent[i]
			}
			for depth > 0 {
				top -= 1
				depth -= 1
				pattern[top] = pattern[depth]
			}
		}
		f.d[k] = y[k]
		y[k] = 0
		for ; top < n; top += 1 {
			i := pattern[top]
			yi := y[i]
			y[i] = 0
			end := f.lp[i] + filled[i]
			for p in f.lp[i] ..< end do y[f.li[p]] -= f.lx[p] * yi
			l := yi / f.d[i]
			f.d[k] -= l * yi
			f.li[end], f.lx[end] = u32(k), l
			filled[i] += 1
		}
		if !(f.d[k] > 0) {
			ldl_destroy(&f, allocator)
			return {}, false
		}
	}
	return f, true
}

// Solves L·D·Lᵀ·x = b in place in `x`.
ldl_solve :: proc(f: Ldl, x: []f64) {
	for j in 0 ..< f.n do for p in f.lp[j] ..< f.lp[j + 1] do x[f.li[p]] -= f.lx[p] * x[j]
	for j in 0 ..< f.n do x[j] /= f.d[j]
	for j := f.n - 1; j >= 0; j -= 1 do for p in f.lp[j] ..< f.lp[j + 1] do x[j] -= f.lx[p] * x[f.li[p]]
}

// Parts of at most this many unknowns are not cut again.
@(private)
DISSECTION_LEAF :: 4

// An elimination order for the graph `next` (node v's neighbours are
// neighbour[next[v]:next[v + 1]]) whose nodes lie at `place`: nested dissection by
// coordinate bisection. Each part is halved at the median along its box's longest side,
// the nodes of the lower half touching the upper half are the separator, and the order
// is the lower half's, then the upper half's, then the separator. Ties go to the lower
// node, so the order follows from the graph and places alone. order[i] is the node
// eliminated i-th; `tree` holds the parts, each after the two it was cut into (the
// frontal factor's tree).
dissection_order :: proc(place: [][3]f32, next, neighbour: []u32, allocator := context.allocator) -> (order: []u32, tree: []Dissection_Node) {
	n := len(place)
	order = make([]u32, n, allocator)
	nodes := make([]u32, n, allocator)
	defer delete(nodes, allocator)
	for &v, i in nodes do v = u32(i)
	// side[v]: which half v fell in at the cut being made; part[v]: which part v is in.
	side := make([]u8, n, allocator)
	defer delete(side, allocator)
	part := make([]u32, n, allocator)
	defer delete(part, allocator)
	keys := make([]Dissection_Key, n, allocator)
	defer delete(keys, allocator)
	State :: struct {
		place:            [][3]f32,
		next, neighbour:  []u32,
		order:            []u32,
		at:               int,
		side:             []u8,
		part:             []u32,
		parts:            u32,
		keys:             []Dissection_Key,
		tree:             [dynamic]Dissection_Node,
		allocator:        runtime.Allocator,
	}
	s := State{place, next, neighbour, order, 0, side, part, 0, keys, make([dynamic]Dissection_Node, allocator), allocator}
	// Returns the part's node in the tree, or -1 for an empty part.
	cut :: proc(s: ^State, nodes: []u32) -> i32 {
		if len(nodes) == 0 do return -1
		start := u32(s.at)
		if len(nodes) <= DISSECTION_LEAF {
			for v in nodes {
				s.order[s.at] = v
				s.at += 1
			}
			append(&s.tree, Dissection_Node{start, start, u32(s.at), -1})
			return i32(len(s.tree) - 1)
		}
		lo, hi := s.place[nodes[0]], s.place[nodes[0]]
		for v in nodes do lo, hi = {min(lo.x, s.place[v].x), min(lo.y, s.place[v].y), min(lo.z, s.place[v].z)}, {max(hi.x, s.place[v].x), max(hi.y, s.place[v].y), max(hi.z, s.place[v].z)}
		size := hi - lo
		axis := 0
		if size.y > size[axis] do axis = 1
		if size.z > size[axis] do axis = 2
		keys := s.keys[:len(nodes)]
		for v, i in nodes do keys[i] = {s.place[v][axis], v}
		slice.sort_by(keys, proc(a, b: Dissection_Key) -> bool {return a.at < b.at || (a.at == b.at && a.node < b.node)})
		for k, i in keys do nodes[i] = k.node
		half := len(nodes) / 2
		s.parts += 1
		here := s.parts
		for v, i in nodes {
			s.part[v] = here
			s.side[v] = 0 if i < half else 1
		}
		// The separator: lower nodes with an upper neighbour in this part, moved to the end
		// of the lower half, keeping the rest in their order.
		lower := nodes[:half]
		kept := 0
		separator := make([dynamic]u32, 0, 16, s.allocator)
		defer delete(separator)
		for v in lower {
			touches := false
			for w in s.neighbour[s.next[v]:s.next[v + 1]] do if s.part[w] == here && s.side[w] == 1 {
				touches = true
				break
			}
			if touches do append(&separator, v)
			else {
				lower[kept] = v
				kept += 1
			}
		}
		copy(lower[kept:], separator[:])
		a := cut(s, lower[:kept])
		b := cut(s, nodes[half:])
		middle := u32(s.at)
		for v in separator {
			s.order[s.at] = v
			s.at += 1
		}
		append(&s.tree, Dissection_Node{start, middle, u32(s.at), -1})
		here_node := i32(len(s.tree) - 1)
		if a >= 0 do s.tree[a].parent = here_node
		if b >= 0 do s.tree[b].parent = here_node
		return here_node
	}
	_ = cut(&s, nodes)
	assert(s.at == n)
	return order, s.tree[:]
}

// A part of a nested dissection: its nodes are ranks [lo, hi) of the order, the last of
// them, [middle, hi), its separator (a whole leaf part when middle is lo); `parent` is
// the part it was cut from, -1 for the whole.
Dissection_Node :: struct {
	lo, middle, hi: u32,
	parent:         i32,
}

@(private)
Dissection_Key :: struct {
	at:   f32,
	node: u32,
}
