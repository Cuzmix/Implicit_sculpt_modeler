package sparse

import "base:runtime"
import "core:log"
import "core:math"
import "core:math/rand"
import "core:testing"
import "core:time"

// A grid's five-point Laplacian, `shift` added to its diagonal: positive definite for any
// shift above zero, and the kind of pattern a mesh's systems have.
@(private = "file")
grid_laplacian :: proc(nx, ny: int, shift: f64) -> Symmetric {
	heap := runtime.heap_allocator()
	t := triplets_make(nx * ny, 5 * nx * ny, heap)
	defer triplets_destroy(&t)
	for y in 0 ..< ny do for x in 0 ..< nx {
		v := y * nx + x
		triplets_add(&t, v, v, shift)
		if x + 1 < nx do add_edge(&t, v, v + 1, 1)
		if y + 1 < ny do add_edge(&t, v, v + nx, 1)
	}
	m, _ := symmetric_from_triplets(t, allocator = heap)
	return m
}

// A weighted edge of a Laplacian: w on both ends' diagonals, -w between them.
@(private = "file")
add_edge :: proc(t: ^Triplets, a, b: int, w: f64) {
	triplets_add(t, a, a, w)
	triplets_add(t, b, b, w)
	triplets_add(t, a, b, -w)
}

// A connection Laplacian on the grid, two unknowns a node (a direction field's pair): each
// edge asks the far node's pair to be the near one's turned by an angle of its own, as
// the frame field's smoothness rows do; positive definite with the shift.
@(private = "file")
grid_connection :: proc(nx, ny: int, shift: f64, seed: u64) -> Symmetric {
	heap := runtime.heap_allocator()
	state := rand.create(seed)
	gen := runtime.default_random_generator(&state)
	t := triplets_make(2 * nx * ny, 20 * nx * ny, heap)
	defer triplets_destroy(&t)
	edge :: proc(t: ^Triplets, a, b: int, turn: f64) {
		c, s := math.cos(turn), math.sin(turn)
		// The rows (c x_a1 + s x_a2 - x_b1) and (-s x_a1 + c x_a2 - x_b2), squared.
		rows := [2][3]f64{{c, s, -1}, {-s, c, -1}}
		for r, k in rows {
			ids := [3]int{2 * a, 2 * a + 1, 2 * b + k}
			for i in 0 ..< 3 do for j in i ..< 3 do triplets_add(t, ids[i], ids[j], r[i] * r[j])
		}
	}
	for y in 0 ..< ny do for x in 0 ..< nx {
		v := y * nx + x
		triplets_add(&t, 2 * v, 2 * v, shift)
		triplets_add(&t, 2 * v + 1, 2 * v + 1, shift)
		if x + 1 < nx do edge(&t, v, v + 1, rand.float64_range(-0.3, 0.3, gen))
		if y + 1 < ny do edge(&t, v, v + nx, rand.float64_range(-0.3, 0.3, gen))
	}
	m, _ := symmetric_from_triplets(t, allocator = heap)
	return m
}

// A random sparse symmetric matrix made positive definite by its diagonal: each unknown
// joined to `per` others at random, and some unknowns to many (dense rows, which AMD
// orders last).
@(private = "file")
random_system :: proc(n, per, dense: int, seed: u64) -> Symmetric {
	heap := runtime.heap_allocator()
	state := rand.create(seed)
	gen := runtime.default_random_generator(&state)
	t := triplets_make(n, n * (per + 1), heap)
	defer triplets_destroy(&t)
	row_sum := make([]f64, n, heap)
	defer delete(row_sum, heap)
	link :: proc(t: ^Triplets, row_sum: []f64, a, b: int, v: f64) {
		if a == b do return
		triplets_add(t, a, b, v)
		row_sum[a] += abs(v)
		row_sum[b] += abs(v)
	}
	for i in 0 ..< n do for _ in 0 ..< per do link(&t, row_sum, i, rand.int_max(n, gen), rand.float64_range(-1, 1, gen))
	for d in 0 ..< dense do for j in 0 ..< n do if rand.int_max(3, gen) == 0 do link(&t, row_sum, d, j, rand.float64_range(-1, 1, gen))
	for i in 0 ..< n do triplets_add(&t, i, i, row_sum[i] + 0.5)
	m, _ := symmetric_from_triplets(t, allocator = heap)
	return m
}

@(private = "file")
right_side :: proc(n: int, seed: u64) -> []f64 {
	state := rand.create(seed)
	gen := runtime.default_random_generator(&state)
	b := make([]f64, n, runtime.heap_allocator())
	for &v in b do v = rand.float64_range(-1, 1, gen)
	return b
}

// Factors and solves; returns the relative residual and the fill.
@(private = "file")
solve_once :: proc(t: ^testing.T, m: Symmetric, b: []f64, order: []i32 = nil) -> (residual: f64, fill: int) {
	heap := runtime.heap_allocator()
	s := ldlt_analyze(m, order, heap)
	defer symbolic_destroy(&s, heap)
	f: Factor
	defer factor_destroy(&f, heap)
	if !testing.expect(t, ldlt_factor(&f, &s, m, heap), "the factor failed") do return 1, 0
	x := make([]f64, m.n, heap)
	defer delete(x, heap)
	ldlt_solve(&f, b, x)
	return relative_residual(m, x, b), symbolic_fill(s)
}

@(private = "file")
is_permutation :: proc(order, inverse: []i32) -> bool {
	heap := runtime.heap_allocator()
	seen := make([]bool, len(order), heap)
	defer delete(seen, heap)
	for v, k in order {
		if v < 0 || int(v) >= len(order) || seen[v] || int(inverse[v]) != k do return false
		seen[v] = true
	}
	return true
}

@(test)
triplets_sum_and_refill :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	tr := triplets_make(3, 0, heap)
	defer triplets_destroy(&tr)
	triplets_add(&tr, 2, 0, 1) // (0, 2), given from the lower side
	triplets_add(&tr, 1, 1, 2)
	triplets_add(&tr, 0, 2, 3) // the same entry again
	triplets_add(&tr, 0, 0, 4)
	slots: []i32
	m, ok := symmetric_from_triplets(tr, &slots, heap)
	defer symmetric_destroy(&m, heap)
	defer delete(slots, heap)
	testing.expect(t, ok)
	testing.expect_value(t, len(m.values), 3)
	testing.expect_value(t, m.first[3] - m.first[2], 1)
	testing.expect_value(t, m.values[m.first[2]], 4.0) // 1 + 3
	symmetric_refill(&m, slots, []f64{10, 20, 30, 40})
	testing.expect_value(t, m.values[m.first[2]], 40.0)
	testing.expect_value(t, m.values[m.first[0]], 40.0)
	y := make([]f64, 3, heap)
	defer delete(y, heap)
	symmetric_multiply(m, []f64{1, 1, 1}, y)
	testing.expect(t, y[0] == 80 && y[1] == 20 && y[2] == 40, "A·1 is the row sums")

	bad := triplets_make(2, 0, heap)
	defer triplets_destroy(&bad)
	triplets_add(&bad, 0, 2, 1)
	_, fine := symmetric_from_triplets(bad, allocator = heap)
	testing.expect(t, !fine, "an index out of range is refused")
}

@(test)
ldlt_solves_grids_and_random_systems :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	Case :: struct {
		name: string,
		m:    Symmetric,
	}
	cases := [?]Case {
		{"grid 40 by 30", grid_laplacian(40, 30, 1e-3)},
		{"grid 1 by 1", grid_laplacian(1, 1, 2)},
		{"connection 30 by 30", grid_connection(30, 30, 1e-4, 7)},
		{"random 2000", random_system(2000, 4, 0, 11)},
		{"random 1500 with dense rows", random_system(1500, 3, 5, 13)},
		{"random 300, two apart", random_system(300, 0, 0, 17)},
	}
	for &c in cases {
		defer symmetric_destroy(&c.m, heap)
		b := right_side(c.m.n, 3)
		defer delete(b, heap)
		order, inverse := amd_order(c.m, heap)
		testing.expectf(t, is_permutation(order, inverse), "%s: AMD's order is not a permutation", c.name)
		delete(order, heap)
		delete(inverse, heap)
		residual, fill := solve_once(t, c.m, b)
		testing.expectf(t, residual < 1e-10, "%s: residual %g", c.name, residual)
		log.infof("%s: %d unknowns, %d entries, fill %d, residual %.2g", c.name, c.m.n, len(c.m.values), fill, residual)
	}
}

@(test)
amd_keeps_the_fill_down :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	m := grid_laplacian(60, 60, 1e-3)
	defer symmetric_destroy(&m, heap)
	b := right_side(m.n, 5)
	defer delete(b, heap)
	natural := make([]i32, m.n, heap)
	defer delete(natural, heap)
	for &v, i in natural do v = i32(i)
	_, natural_fill := solve_once(t, m, b, natural)
	residual, amd_fill := solve_once(t, m, b)
	log.infof("grid 60 by 60: fill %d in the natural order, %d in AMD's", natural_fill, amd_fill)
	testing.expectf(t, 2 * amd_fill < natural_fill, "AMD's fill %d is not under half the natural order's %d", amd_fill, natural_fill)
	testing.expect(t, residual < 1e-10)
}

@(test)
amd_is_the_same_with_less_room :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	for seed in u64(1) ..= 4 {
		m := random_system(800, 5, 3, seed)
		defer symmetric_destroy(&m, heap)
		roomy, roomy_inverse := amd_order(m, heap)
		tight, tight_inverse := amd_order(m, heap, room = 0)
		defer delete(roomy, heap)
		defer delete(roomy_inverse, heap)
		defer delete(tight, heap)
		defer delete(tight_inverse, heap)
		same := true
		for v, k in roomy do if tight[k] != v do same = false
		testing.expectf(t, same, "seed %d: the order changed when the workspace had to be compressed", seed)
	}
}

@(test)
refactor_reuses_the_symbolic_pass :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	m := grid_connection(25, 20, 1e-3, 3)
	defer symmetric_destroy(&m, heap)
	b := right_side(m.n, 9)
	defer delete(b, heap)
	s := ldlt_analyze(m, allocator = heap)
	defer symbolic_destroy(&s, heap)
	f: Factor
	defer factor_destroy(&f, heap)
	testing.expect(t, ldlt_factor(&f, &s, m, heap))
	// New numbers on the same pattern: the refactor gives what a fresh analysis does, bit
	// for bit.
	for j in 0 ..< m.n {
		for p in m.first[j] ..< m.first[j + 1] {
			m.values[p] *= 1.5
			if int(m.rows[p]) == j do m.values[p] += 0.1
		}
	}
	testing.expect(t, ldlt_factor(&f, &s, m, heap))
	x := make([]f64, m.n, heap)
	defer delete(x, heap)
	ldlt_solve(&f, b, x)
	fresh := ldlt_analyze(m, allocator = heap)
	defer symbolic_destroy(&fresh, heap)
	g: Factor
	defer factor_destroy(&g, heap)
	testing.expect(t, ldlt_factor(&g, &fresh, m, heap))
	y := make([]f64, m.n, heap)
	defer delete(y, heap)
	ldlt_solve(&g, b, y)
	same := true
	for v, i in x do if v != y[i] do same = false
	testing.expect(t, same, "a refactor differs from a fresh factor")
	testing.expect(t, relative_residual(m, x, b) < 1e-10)
	// Solving in place.
	ldlt_solve(&f, b, b)
	for v, i in b do if v != x[i] do same = false
	testing.expect(t, same, "solving in place differs")
}

@(test)
singular_systems_fail_and_cg_takes_over :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	// A Laplacian with no shift is singular (constants are its null space).
	m := grid_laplacian(10, 10, 0)
	defer symmetric_destroy(&m, heap)
	s := ldlt_analyze(m, allocator = heap)
	defer symbolic_destroy(&s, heap)
	f: Factor
	defer factor_destroy(&f, heap)
	// Its last pivot is zero to rounding, so the factor either fails or leaves a tiny
	// pivot; with no right side outside the range, conjugate gradients still solve it.
	_ = ldlt_factor(&f, &s, m, heap)
	zero := triplets_make(4, 0, heap)
	defer triplets_destroy(&zero)
	for i in 0 ..< 4 do triplets_add(&zero, i, i, 0)
	z, _ := symmetric_from_triplets(zero, allocator = heap)
	defer symmetric_destroy(&z, heap)
	zs := ldlt_analyze(z, allocator = heap)
	defer symbolic_destroy(&zs, heap)
	zf: Factor
	defer factor_destroy(&zf, heap)
	testing.expect(t, !ldlt_factor(&zf, &zs, z, heap), "a zero matrix factored")

	g := grid_laplacian(50, 40, 1e-2)
	defer symmetric_destroy(&g, heap)
	b := right_side(g.n, 21)
	defer delete(b, heap)
	x := make([]f64, g.n, heap)
	defer delete(x, heap)
	steps, residual, ok := cg_solve(g, b, x)
	testing.expectf(t, ok && residual <= 1e-10, "CG stopped at %g after %d steps", residual, steps)
	testing.expect(t, relative_residual(g, x, b) < 1e-8)
}

@(test)
ldlt_speed :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	// About the cover's size at 20,000 quads (80,000 unknowns, two a node) and a plain
	// Laplacian of 90,000.
	Case :: struct {
		name: string,
		m:    Symmetric,
	}
	cases := [?]Case{{"connection 200 by 200", grid_connection(200, 200, 1e-6, 5)}, {"grid 300 by 300", grid_laplacian(300, 300, 1e-3)}}
	for &c in cases {
		defer symmetric_destroy(&c.m, heap)
		b := right_side(c.m.n, 1)
		defer delete(b, heap)
		t0 := time.tick_now()
		s := ldlt_analyze(c.m, allocator = heap)
		defer symbolic_destroy(&s, heap)
		t1 := time.tick_now()
		f: Factor
		defer factor_destroy(&f, heap)
		testing.expect(t, ldlt_factor(&f, &s, c.m, heap))
		t2 := time.tick_now()
		x := make([]f64, c.m.n, heap)
		defer delete(x, heap)
		ldlt_solve(&f, b, x)
		t3 := time.tick_now()
		residual := relative_residual(c.m, x, b)
		testing.expectf(t, residual < 1e-10, "%s: residual %g", c.name, residual)
		log.infof("%s: %d unknowns, fill %d, analyze %.1f ms, factor %.1f ms, solve %.1f ms, residual %.2g", c.name, c.m.n, symbolic_fill(s), time.duration_milliseconds(time.tick_diff(t0, t1)), time.duration_milliseconds(time.tick_diff(t1, t2)), time.duration_milliseconds(time.tick_diff(t2, t3)), residual)
	}
}

// A connection Laplacian over an nx by ny grid as a Hermitian matrix (each node one complex
// unknown, each grid edge the energy |e^{i turn} z_a - z_b|²) and as the real system of
// twice the size it stands for (each complex entry a + ib the block [a -b; b a]).
@(private = "file")
complex_connection :: proc(nx, ny: int, shift: f64, seed: u64) -> (h: Hermitian, m: Symmetric) {
	heap := runtime.heap_allocator()
	state := rand.create(seed)
	gen := runtime.default_random_generator(&state)
	ht := hermitian_triplets_make(nx * ny, 4 * nx * ny, heap)
	defer hermitian_triplets_destroy(&ht)
	rt := triplets_make(2 * nx * ny, 12 * nx * ny, heap)
	defer triplets_destroy(&rt)
	put :: proc(ht: ^Hermitian_Triplets, rt: ^Triplets, a, b: int, v: complex128) {
		hermitian_triplets_add(ht, a, b, v)
		if a == b {
			triplets_add(rt, 2 * a, 2 * a, real(v))
			triplets_add(rt, 2 * a + 1, 2 * a + 1, real(v))
			return
		}
		// Row a's block at column b, [re -im; im re]; the transpose is row b's at a.
		triplets_add(rt, 2 * a, 2 * b, real(v))
		triplets_add(rt, 2 * a, 2 * b + 1, -imag(v))
		triplets_add(rt, 2 * a + 1, 2 * b, imag(v))
		triplets_add(rt, 2 * a + 1, 2 * b + 1, real(v))
	}
	for y in 0 ..< ny do for x in 0 ..< nx {
		v := y * nx + x
		put(&ht, &rt, v, v, complex(shift, 0))
		for w in ([2]int{v + 1 if x + 1 < nx else -1, v + nx if y + 1 < ny else -1}) {
			if w < 0 do continue
			turn := rand.float64_range(-1.2, 1.2, gen)
			c := complex(math.cos(turn), math.sin(turn))
			put(&ht, &rt, v, v, 1)
			put(&ht, &rt, w, w, 1)
			put(&ht, &rt, v, w, -conj(c))
		}
	}
	h, _ = hermitian_from_triplets(ht, heap)
	m, _ = symmetric_from_triplets(rt, allocator = heap)
	return
}

// The Hermitian factor solves what the real system of twice the size solves, to the
// rounding, through any order, and refactors on its symbolic pass.
@(test)
hermitian_matches_the_real_system :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	h, m := complex_connection(40, 30, 1e-3, 9)
	defer hermitian_destroy(&h, heap)
	defer symmetric_destroy(&m, heap)
	n := h.n
	b := make([]complex128, n, heap)
	defer delete(b, heap)
	rb := make([]f64, 2 * n, heap)
	defer delete(rb, heap)
	state := rand.create(4)
	gen := runtime.default_random_generator(&state)
	for &v, i in b {
		v = complex(rand.float64_range(-1, 1, gen), rand.float64_range(-1, 1, gen))
		rb[2 * i], rb[2 * i + 1] = real(v), imag(v)
	}
	natural := make([]i32, n, heap)
	defer delete(natural, heap)
	for &v, i in natural do v = i32(n - 1 - i)
	for order in ([2][]i32{nil, natural}) {
		s := ldlt_analyze(hermitian_pattern(h), order, heap)
		defer symbolic_destroy(&s, heap)
		f: Hermitian_Factor
		defer hermitian_factor_destroy(&f, heap)
		if !testing.expect(t, hermitian_factor(&f, &s, h, heap), "the Hermitian factor failed") do return
		x := make([]complex128, n, heap)
		defer delete(x, heap)
		hermitian_solve(&f, b, x)
		residual := hermitian_residual(h, x, b)
		rx := make([]f64, 2 * n, heap)
		defer delete(rx, heap)
		rs := ldlt_analyze(m, allocator = heap)
		defer symbolic_destroy(&rs, heap)
		rf: Factor
		defer factor_destroy(&rf, heap)
		testing.expect(t, ldlt_factor(&rf, &rs, m, heap))
		ldlt_solve(&rf, rb, rx)
		apart := f64(0)
		for v, i in x do apart = max(apart, abs(real(v) - rx[2 * i]), abs(imag(v) - rx[2 * i + 1]))
		log.infof("Hermitian %d unknowns (%s order): fill %d against the real system's %d, residual %.2g, apart from the real solution %.2g", n, "AMD" if order == nil else "reversed", symbolic_fill(s), symbolic_fill(rs), residual, apart)
		testing.expectf(t, residual < 1e-10, "residual %g", residual)
		testing.expectf(t, apart < 1e-8, "%g apart from the real system's solution", apart)
		// New numbers on the same pattern: twice the diagonal's shift.
		for p in 0 ..< len(h.values) do if int(h.rows[p]) == column_of(h, p) do h.values[p] += 1e-3
		testing.expect(t, hermitian_factor(&f, &s, h, heap))
		hermitian_solve(&f, b, x)
		testing.expectf(t, hermitian_residual(h, x, b) < 1e-10, "refactored residual %g", hermitian_residual(h, x, b))
		for p in 0 ..< len(h.values) do if int(h.rows[p]) == column_of(h, p) do h.values[p] -= 1e-3
	}
}

// The column entry p of the matrix is in.
@(private = "file")
column_of :: proc(h: Hermitian, p: int) -> int {
	for j in 0 ..< h.n do if p < h.first[j + 1] do return j
	return h.n
}

// The Hermitian factor against the real one on the same connection Laplacian, 40,000
// complex unknowns (80,000 real).
@(test)
hermitian_speed :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	h, m := complex_connection(200, 200, 1e-6, 5)
	defer hermitian_destroy(&h, heap)
	defer symmetric_destroy(&m, heap)
	b := make([]complex128, h.n, heap)
	defer delete(b, heap)
	for &v, i in b do v = complex(math.sin(f64(i)), math.cos(f64(i)))
	t0 := time.tick_now()
	s := ldlt_analyze(hermitian_pattern(h), allocator = heap)
	defer symbolic_destroy(&s, heap)
	t1 := time.tick_now()
	f: Hermitian_Factor
	defer hermitian_factor_destroy(&f, heap)
	testing.expect(t, hermitian_factor(&f, &s, h, heap))
	t2 := time.tick_now()
	x := make([]complex128, h.n, heap)
	defer delete(x, heap)
	hermitian_solve(&f, b, x)
	t3 := time.tick_now()
	residual := hermitian_residual(h, x, b)
	testing.expectf(t, residual < 1e-10, "residual %g", residual)
	rs := ldlt_analyze(m, allocator = heap)
	defer symbolic_destroy(&rs, heap)
	t4 := time.tick_now()
	rf: Factor
	defer factor_destroy(&rf, heap)
	testing.expect(t, ldlt_factor(&rf, &rs, m, heap))
	t5 := time.tick_now()
	ms :: proc(a, b: time.Tick) -> f64 {return time.duration_milliseconds(time.tick_diff(a, b))}
	log.infof("Hermitian %d unknowns: fill %d, analyze %.1f ms, factor %.1f ms, solve %.1f ms, residual %.2g; the real system's %d: fill %d, analyze %.1f ms, factor %.1f ms", h.n, symbolic_fill(s), ms(t0, t1), ms(t1, t2), ms(t2, t3), residual, m.n, symbolic_fill(rs), ms(t3, t4), ms(t4, t5))
}
