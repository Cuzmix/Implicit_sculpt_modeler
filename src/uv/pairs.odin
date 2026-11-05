package uv

import "base:runtime"
import "core:math"

import "../jobs"
import "../sparse"

// A symmetric system whose unknowns come in pairs (2k and 2k + 1: a wedge's u and v in
// LSCM, a vertex's two constraints in ABF++), solved on src/sparse's supernodal Cholesky
// in an AMD order over the pairs that keeps each pair's two together, so the supernodes
// come in whole blocks. The pattern is analysed once; a refill puts new numbers on it.
// Everything is made and freed with the heap, as the solves run inside jobs.

@(private)
Pair_System :: struct {
	m:        sparse.Symmetric,
	slots:    []i32,
	symbolic: sparse.Supernodal_Symbolic,
	factor:   sparse.Supernodal_Factor,
	factored: bool,
}

// The system the triplets `t` make (2 * pairs unknowns), analysed. False when an index is
// out of range.
@(private)
pair_system_make :: proc(t: sparse.Triplets, keep_slots := false) -> (s: Pair_System, ok: bool) {
	heap := runtime.heap_allocator()
	s.m = sparse.symmetric_from_triplets(t, &s.slots if keep_slots else nil, heap) or_return
	pairs := (s.m.n + 1) / 2
	g := sparse.triplets_make(pairs, len(s.m.rows) / 2 + pairs, heap)
	defer sparse.triplets_destroy(&g)
	for i in 0 ..< pairs do sparse.triplets_add(&g, i, i, 1)
	for j in 0 ..< s.m.n do for p in s.m.first[j] ..< s.m.first[j + 1] {
		if r := int(s.m.rows[p]) / 2; r != j / 2 do sparse.triplets_add(&g, r, j / 2, 1)
	}
	graph, _ := sparse.symmetric_from_triplets(g, nil, heap)
	defer sparse.symmetric_destroy(&graph, heap)
	by_pair, inverse := sparse.amd_order(graph, heap)
	defer delete(by_pair, heap)
	delete(inverse, heap)
	order := make([]i32, s.m.n, heap)
	defer delete(order, heap)
	at := 0
	for p in by_pair do for k in 2 * p ..< min(2 * p + 2, i32(s.m.n)) {
		order[at] = k
		at += 1
	}
	s.symbolic = sparse.supernodal_analyze(s.m, order, heap)
	return s, true
}

// New numbers on the same pattern, one per triplet in the order first given.
@(private)
pair_system_refill :: proc(s: ^Pair_System, values: []f64) {
	sparse.symmetric_refill(&s.m, s.slots, values)
}

// Factors the system as it now stands and solves it for `rhs` into `x`.
@(private)
pair_system_solve :: proc(s: ^Pair_System, pool: ^jobs.Pool, rhs, x: []f64) -> bool {
	heap := runtime.heap_allocator()
	if s.factored do sparse.supernodal_factor_destroy(&s.factor, heap)
	s.factored = sparse.supernodal_factor(&s.factor, &s.symbolic, s.m, pool, heap)
	if !s.factored do return false
	sparse.supernodal_solve(&s.factor, rhs, x)
	for v in x do if math.is_nan(v) || math.is_inf(v) do return false
	return true
}

@(private)
pair_system_destroy :: proc(s: ^Pair_System) {
	heap := runtime.heap_allocator()
	if s.factored do sparse.supernodal_factor_destroy(&s.factor, heap)
	sparse.supernodal_symbolic_destroy(&s.symbolic, heap)
	sparse.symmetric_destroy(&s.m, heap)
	delete(s.slots, heap)
	s^ = {}
}
