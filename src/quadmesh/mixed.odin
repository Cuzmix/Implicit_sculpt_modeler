package quadmesh

import "base:runtime"
import "core:math"
import "core:slice"

import "../jobs"
import "../sparse"

// The cover's mixed integer least squares (cover.odin), from AutoRemesher's
// MixedIntegerLeastSquares and ConstrainedLeastSquares (MIT, by Jeremy Hu), whose steps and
// choices this keeps, so the cover lands on AutoRemesher's integers. The unknowns are tied
// by homogeneous linear constraints, some are integers of a period (2 for a seam's
// translation, 1 for a feature's coordinate), and an energy of weighted rows is minimized
// over what the constraints leave free. The constraints are eliminated by substitution in
// three passes: those of one term set their unknown to zero and drop it (M0); those of two
// terms of unit size make one unknown plus or minus the other, joined in a union-find whose
// root keeps the larger period (M1); and the rest each express one group as a combination
// of others, the one whose period times coefficient is least going (M2), which keeps the
// integers as integers. Every unknown is then a combination of the remaining groups (its
// kernel line), and the energy is rewritten over those. The least squares is solved over
// the groups, every integer group rounded to its period at once, and solved again with
// those held, as AutoRemesher's greedy rounding does when its threshold takes them all in its
// first round. The solves go through src/sparse (AMD and the supernodal Cholesky) where
// AutoRemesher used Eigen, and keep their orderings and structures (Least_System), so the
// landing's later covers, whose rows have the same pattern and new numbers, only refill
// and refactor.

// A coefficient of an unknown in a row.
@(private)
Coeff :: struct {
	index: i32,
	a:     f64,
}

// Rows of a least squares problem: row r's coefficients are entries[first[r]:first[r + 1]],
// asking the weighted sum be rhs[r] with weight weight[r].
@(private)
Least_Rows :: struct {
	first:   [dynamic]i32,
	entries: [dynamic]Coeff,
	rhs:     [dynamic]f64,
	weight:  [dynamic]f64,
}

// A coefficient this close to zero is dropped from a row (dropTolerance).
@(private = "file")
DROP :: 1e-10

// A contribution this small is not added at all.
@(private = "file")
TINY :: 1e-14

// The ridge on a normal matrix, relative to its mean diagonal (ConstrainedLeastSquares's).
@(private = "file")
LEAST_RIDGE :: 1e-10

// An unknown M0 dropped.
@(private = "file")
GONE :: i32(-1)

@(private)
Mixed :: struct {
	size:        int,
	period:      [dynamic]i32, // per unknown, then per M0 index, then per group
	m0:          []i32, // per unknown: its index once the zeroed are dropped, or GONE
	m1:          []Coeff, // per M0 index: its parent in the union-find and the factor to it, then its group
	m2:          [][dynamic]Coeff, // per group: the combination of kernel groups it is
	m2t:         [][dynamic]Coeff, // per kernel group: the groups whose combination holds it
	c_data:      [dynamic]Coeff, // the constraints as recorded, normalized
	c_range:     [dynamic][2]i32,
	singles:     [dynamic]i32,
	multis:      [dynamic]i32,
	energy:      Least_Rows,
	kernel_size: int,
	k_first:     []i32, // unknown i's kernel line is k_data[k_first[i]:k_first[i + 1]]
	k_data:      [dynamic]Coeff,
	reduced:     Least_Rows,
	source:      [dynamic]i32, // per reduced row: the energy row it came from
	values:      []f64, // per kernel group
	// Scratch, kept between calls.
	scratch:     [dynamic]Coeff,
	r0, r1, r2:  [dynamic]Coeff,
	merged:      [dynamic]Coeff,
	difference:  [dynamic]Coeff,
	column:      [dynamic]Coeff,
	scatter:     []f64,
	touched:     [dynamic]i32,
}

@(private)
mixed_make :: proc(size: int) -> (m: Mixed) {
	heap := runtime.heap_allocator()
	m.size = size
	m.period = make([dynamic]i32, size, heap)
	m.m0 = make([]i32, size, heap)
	for &x, i in m.m0 do x = i32(i)
	m.c_data = make([dynamic]Coeff, heap)
	m.c_range = make([dynamic][2]i32, heap)
	m.singles = make([dynamic]i32, heap)
	m.multis = make([dynamic]i32, heap)
	m.energy = least_rows_make()
	m.reduced = least_rows_make()
	m.source = make([dynamic]i32, heap)
	m.k_data = make([dynamic]Coeff, heap)
	m.scratch = make([dynamic]Coeff, heap)
	m.r0 = make([dynamic]Coeff, heap)
	m.r1 = make([dynamic]Coeff, heap)
	m.r2 = make([dynamic]Coeff, heap)
	m.merged = make([dynamic]Coeff, heap)
	m.difference = make([dynamic]Coeff, heap)
	m.column = make([dynamic]Coeff, heap)
	m.touched = make([dynamic]i32, heap)
	return
}

@(private)
mixed_destroy :: proc(m: ^Mixed) {
	heap := runtime.heap_allocator()
	delete(m.period)
	delete(m.m0, heap)
	delete(m.m1, heap)
	for &r in m.m2 do delete(r)
	delete(m.m2, heap)
	for &r in m.m2t do delete(r)
	delete(m.m2t, heap)
	delete(m.c_data)
	delete(m.c_range)
	delete(m.singles)
	delete(m.multis)
	least_rows_destroy(&m.energy)
	delete(m.k_first, heap)
	delete(m.k_data)
	least_rows_destroy(&m.reduced)
	delete(m.source)
	delete(m.values, heap)
	delete(m.scratch)
	delete(m.r0)
	delete(m.r1)
	delete(m.r2)
	delete(m.merged)
	delete(m.difference)
	delete(m.column)
	delete(m.scatter, heap)
	delete(m.touched)
	m^ = {}
}

@(private)
least_rows_make :: proc() -> (r: Least_Rows) {
	heap := runtime.heap_allocator()
	r.first = make([dynamic]i32, 1, heap)
	r.entries = make([dynamic]Coeff, heap)
	r.rhs = make([dynamic]f64, heap)
	r.weight = make([dynamic]f64, heap)
	return
}

@(private)
least_rows_destroy :: proc(r: ^Least_Rows) {
	delete(r.first)
	delete(r.entries)
	delete(r.rhs)
	delete(r.weight)
	r^ = {}
}

@(private)
least_rows_add :: proc(r: ^Least_Rows, row: []Coeff, rhs, weight: f64) {
	append(&r.entries, ..row)
	append(&r.first, i32(len(r.entries)))
	append(&r.rhs, rhs)
	append(&r.weight, weight)
}

@(private)
mixed_set_period :: proc(m: ^Mixed, v: int, period: i32) {
	if v < len(m.period) do m.period[v] = max(0, period)
}

// Records a constraint that the coefficients' combination be zero.
@(private)
mixed_constraint :: proc(m: ^Mixed, coefficients: ..Coeff) {
	clear(&m.scratch)
	for c in coefficients do if int(c.index) < m.size && c.a != 0 do append(&m.scratch, c)
	normalize_row(&m.scratch)
	if len(m.scratch) == 0 do return
	if len(m.scratch) == 1 {
		append(&m.singles, i32(len(m.c_range)))
	} else {
		append(&m.multis, i32(len(m.c_range)))
	}
	append(&m.c_range, [2]i32{i32(len(m.c_data)), i32(len(m.scratch))})
	append(&m.c_data, ..m.scratch[:])
}

// Adds the energy row a·x_i + b·x_j = rhs with `weight`.
@(private)
mixed_energy :: proc(m: ^Mixed, i: int, a: f64, j: int, b: f64, rhs, weight: f64) {
	if weight <= 0 do return
	clear(&m.scratch)
	if i < m.size && a != 0 do append(&m.scratch, Coeff{i32(i), a})
	if j < m.size && b != 0 do append(&m.scratch, Coeff{i32(j), b})
	normalize_row(&m.scratch)
	if len(m.scratch) > 0 do least_rows_add(&m.energy, m.scratch[:], rhs, weight)
}

// Sorts a row by unknown, sums repeats and drops what comes to nearly zero.
@(private = "file")
normalize_row :: proc(row: ^[dynamic]Coeff) {
	r := row[:]
	if len(r) <= 8 {
		for i in 1 ..< len(r) {
			x := r[i]
			j := i
			for j > 0 && r[j - 1].index > x.index {
				r[j] = r[j - 1]
				j -= 1
			}
			r[j] = x
		}
	} else {
		slice.sort_by(r, proc(a, b: Coeff) -> bool {return a.index < b.index})
	}
	out := 0
	i := 0
	for i < len(r) {
		j := i + 1
		a := r[i].a
		for j < len(r) && r[j].index == r[i].index {
			a += r[j].a
			j += 1
		}
		if abs(a) > DROP {
			r[out] = {r[i].index, a}
			out += 1
		}
		i = j
	}
	resize(row, out)
}

// Adds `a` at `index` into a sorted row.
@(private = "file")
row_add :: proc(row: ^[dynamic]Coeff, index: i32, a: f64) {
	if abs(a) < TINY do return
	lo, hi := 0, len(row)
	for lo < hi {
		mid := (lo + hi) / 2
		if row[mid].index < index {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(row) && row[lo].index == index {
		row[lo].a += a
		if abs(row[lo].a) < DROP do ordered_remove(row, lo)
	} else {
		inject_at(row, lo, Coeff{index, a})
	}
}

// row += factor · source, both sorted.
@(private = "file")
row_axpy :: proc(m: ^Mixed, row: ^[dynamic]Coeff, source: []Coeff, factor: f64) {
	if len(source) == 0 || factor == 0 do return
	clear(&m.merged)
	reserve(&m.merged, len(row) + len(source))
	i, j := 0, 0
	for i < len(row) && j < len(source) {
		if row[i].index < source[j].index {
			append(&m.merged, row[i])
			i += 1
		} else if source[j].index < row[i].index {
			a := factor * source[j].a
			if abs(a) >= TINY do append(&m.merged, Coeff{source[j].index, a})
			j += 1
		} else {
			contribution := factor * source[j].a
			a := row[i].a + contribution
			if abs(contribution) < TINY {
				append(&m.merged, row[i])
			} else if abs(a) >= DROP {
				append(&m.merged, Coeff{row[i].index, a})
			}
			i += 1
			j += 1
		}
	}
	for i < len(row) {
		append(&m.merged, row[i])
		i += 1
	}
	for j < len(source) {
		a := factor * source[j].a
		if abs(a) >= TINY do append(&m.merged, Coeff{source[j].index, a})
		j += 1
	}
	row^, m.merged = m.merged, row^
}

// out = row · m2, sorted, nearly zero dropped.
@(private = "file")
row_through_m2 :: proc(m: ^Mixed, row: []Coeff, out: ^[dynamic]Coeff) {
	clear(&m.touched)
	for c in row {
		if int(c.index) >= len(m.m2) do continue
		for b in m.m2[c.index] {
			if m.scatter[b.index] == 0 do append(&m.touched, b.index)
			m.scatter[b.index] += c.a * b.a
		}
	}
	slice.sort(m.touched[:])
	clear(out)
	for index in m.touched {
		a := m.scatter[index]
		m.scatter[index] = 0
		if abs(a) > DROP do append(out, Coeff{index, a})
	}
}

@(private = "file")
recorded :: #force_inline proc(m: ^Mixed, k: i32) -> []Coeff {
	r := m.c_range[k]
	return m.c_data[r[0]:r[0] + r[1]]
}

// r0 and r1: the row through M0 and through M1.
@(private = "file")
through_m0_m1 :: proc(m: ^Mixed, row: []Coeff) {
	clear(&m.r0)
	for c in row do if m.m0[c.index] != GONE do append(&m.r0, Coeff{m.m0[c.index], c.a})
	clear(&m.r1)
	for c in m.r0 do append(&m.r1, Coeff{m.m1[c.index].index, c.a * m.m1[c.index].a})
	normalize_row(&m.r1)
}

// Eliminates the constraints (finalizeConstraints); returns the kernel's size.
@(private)
mixed_finalize :: proc(m: ^Mixed) -> int {
	heap := runtime.heap_allocator()
	// Pass 0: a constraint of one term zeroes its unknown.
	for k in m.singles {
		row := recorded(m, k)
		if len(row) == 1 && row[0].a != 0 do m.m0[row[0].index] = GONE
	}
	n := 0
	for i in 0 ..< m.size do if m.m0[i] != GONE {
		m.period[n] = m.period[i]
		m.m0[i] = i32(n)
		n += 1
	}
	resize(&m.period, n)
	m.m1 = make([]Coeff, n, heap)
	for &x, i in m.m1 do x = {i32(i), 1}

	// Pass 1: two terms of unit size join their unknowns.
	for k in m.multis {
		through_m0_m1(m, recorded(m, k))
		r1 := m.r1[:]
		if len(r1) != 2 || abs(abs(r1[0].a) - 1) >= 1e-10 || abs(abs(r1[1].a) - 1) >= 1e-10 do continue
		roots := [2]Coeff{{r1[0].index, 1}, {r1[1].index, -r1[0].a / r1[1].a}}
		for &x in roots do for x.index != m.m1[x.index].index {
			x.a *= m.m1[x.index].a
			x.index = m.m1[x.index].index
		}
		if m.period[roots[0].index] < m.period[roots[1].index] {
			m.m1[roots[0].index] = {roots[1].index, roots[1].a * roots[0].a}
		} else {
			m.m1[roots[1].index] = {roots[0].index, roots[1].a * roots[0].a}
		}
	}
	for i in 0 ..< len(m.m1) do for m.m1[i].index != m.m1[m.m1[i].index].index {
		m.m1[i].a *= m.m1[m.m1[i].index].a
		m.m1[i].index = m.m1[m.m1[i].index].index
	}
	group := make([]i32, len(m.m1), heap)
	defer delete(group, heap)
	groups := 0
	for i in 0 ..< len(m.m1) {
		group[i] = GONE
		if int(m.m1[i].index) == i {
			group[i] = i32(groups)
			groups += 1
		}
	}
	period := make([dynamic]i32, groups, heap)
	for i in 0 ..< len(m.m1) {
		root := m.m1[i].index
		g := group[root]
		period[g] = max(period[g], m.period[root])
		m.m1[i].index = g
	}
	delete(m.period)
	m.period = period
	m.m2 = make([][dynamic]Coeff, groups, heap)
	m.m2t = make([][dynamic]Coeff, groups, heap)
	for i in 0 ..< groups {
		m.m2[i] = make([dynamic]Coeff, 1, heap)
		m.m2[i][0] = {i32(i), 1}
		m.m2t[i] = make([dynamic]Coeff, 1, heap)
		m.m2t[i][0] = {i32(i), 1}
	}
	m.scatter = make([]f64, groups, heap)

	// Pass 2: every constraint left takes a group out, the least period times coefficient.
	for k in 0 ..< len(m.c_range) {
		through_m0_m1(m, recorded(m, i32(k)))
		if len(m.r1) == 0 do continue
		row_through_m2(m, m.r1[:], &m.r2)
		r2 := m.r2[:]
		if len(r2) == 0 do continue
		remove := 0
		for i in 1 ..< len(r2) {
			if f64(m.period[r2[i].index]) * abs(r2[i].a) < f64(m.period[r2[remove].index]) * abs(r2[remove].a) do remove = i
		}
		remove_column(m, r2, remove)
	}
	m.kernel_size = groups

	// Each unknown's kernel line, and the energy over the kernel.
	m.k_first = make([]i32, m.size + 1, heap)
	for i in 0 ..< m.size {
		if m.m0[i] != GONE {
			g := m.m1[m.m0[i]]
			for b in m.m2[g.index] {
				a := g.a * b.a
				if abs(a) > DROP do append(&m.k_data, Coeff{b.index, a})
			}
		}
		m.k_first[i + 1] = i32(len(m.k_data))
	}
	row := make([dynamic]Coeff, heap)
	defer delete(row)
	for r in 0 ..< len(m.energy.rhs) {
		clear(&row)
		for c in m.energy.entries[m.energy.first[r]:m.energy.first[r + 1]] do row_axpy(m, &row, kernel_line(m, int(c.index)), c.a)
		if len(row) > 0 {
			least_rows_add(&m.reduced, row[:], m.energy.rhs[r], m.energy.weight[r])
			append(&m.source, i32(r))
		}
	}
	least_rows_destroy(&m.energy)
	// The elimination's arrays go: the solves need only the periods, the kernel lines and
	// the reduced rows, and the plan keeps the rest for all of the landing's covers.
	delete(m.m0, heap)
	delete(m.m1, heap)
	for &r in m.m2 do delete(r)
	delete(m.m2, heap)
	for &r in m.m2t do delete(r)
	delete(m.m2t, heap)
	delete(m.c_data)
	delete(m.c_range)
	delete(m.singles)
	delete(m.multis)
	delete(m.scratch)
	delete(m.r0)
	delete(m.r1)
	delete(m.r2)
	delete(m.merged)
	delete(m.difference)
	delete(m.column)
	delete(m.scatter, heap)
	delete(m.touched)
	m.m0, m.m1, m.m2, m.m2t, m.scatter = nil, nil, nil, nil, nil
	m.c_data, m.c_range, m.singles, m.multis, m.touched = {}, {}, {}, {}, {}
	m.scratch, m.r0, m.r1, m.r2, m.merged, m.difference, m.column = {}, {}, {}, {}, {}, {}, {}
	return m.kernel_size
}

@(private = "file")
kernel_line :: #force_inline proc(m: ^Mixed, i: int) -> []Coeff {
	return m.k_data[m.k_first[i]:m.k_first[i + 1]]
}

// Takes group row[remove].index out of the kernel: every group whose combination holds it
// gets the rest of the constraint in its place (applyRemoveColumn).
@(private = "file")
remove_column :: proc(m: ^Mixed, row: []Coeff, remove: int) {
	pivot := row[remove]
	clear(&m.difference)
	for c, i in row do if i != remove do append(&m.difference, Coeff{c.index, -c.a / pivot.a})
	zero := pivot.index
	row_add(&m.difference, zero, -1)
	clear(&m.column)
	append(&m.column, ..m.m2t[zero][:])
	for d in m.difference do row_axpy(m, &m.m2t[d.index], m.column[:], d.a)
	for source in m.column do row_axpy(m, &m.m2[source.index], m.difference[:], source.a)
}

// The least squares over the kernel, every integer group then rounded to its period and
// the least squares solved again with them held (solveIteration twice), `free` and `held`
// the two solves' systems. False when a solve fails; `integers` is how many groups were
// rounded.
@(private)
mixed_solve :: proc(m: ^Mixed, free, held_system: ^Least_System, pool: ^jobs.Pool, report: proc(data: rawptr, fraction: f32) -> bool = nil, data: rawptr = nil) -> (ok: bool, integers: int, cancelled: bool) {
	heap := runtime.heap_allocator()
	if m.kernel_size == 0 do return
	fixed := make([]bool, m.kernel_size, heap)
	defer delete(fixed, heap)
	held := make([]f64, m.kernel_size, heap)
	defer delete(held, heap)
	delete(m.values, heap)
	m.values = make([]f64, m.kernel_size, heap)
	if !least_squares(free, &m.reduced, m.kernel_size, fixed, held, m.values, pool) do return
	for p in m.period do if p > 0 do integers += 1
	if integers == 0 do return true, 0, false
	if report != nil && !report(data, 0.5) do return false, integers, true
	for p, i in m.period do if p > 0 {
		fixed[i] = true
		held[i] = f64(p) * math.round(m.values[i] / f64(p))
	}
	if !least_squares(held_system, &m.reduced, m.kernel_size, fixed, held, m.values, pool) do return
	return true, integers, false
}

// Unknown i's value from the kernel's.
@(private)
mixed_value :: proc(m: ^Mixed, i: int) -> f64 {
	v := f64(0)
	for x in kernel_line(m, i) do if int(x.index) < len(m.values) do v += x.a * m.values[x.index]
	return v
}

// A least squares problem's normal equations kept between solves of rows of one pattern
// with the same unknowns held: the matrix's pattern, each of its triplets' slots in it,
// and the supernodal order and structure, so a later solve refills and refactors.
@(private)
Least_System :: struct {
	free:     []i32, // per unknown: its column, or GONE when held
	columns:  int,
	normal:   sparse.Symmetric,
	slots:    []i32,
	symbolic: sparse.Supernodal_Symbolic,
	factor:   sparse.Supernodal_Factor,
	ready:    bool,
}

@(private)
least_system_destroy :: proc(sys: ^Least_System) {
	heap := runtime.heap_allocator()
	delete(sys.free, heap)
	sparse.symmetric_destroy(&sys.normal, heap)
	delete(sys.slots, heap)
	sparse.supernodal_symbolic_destroy(&sys.symbolic, heap)
	sparse.supernodal_factor_destroy(&sys.factor, heap)
	sys^ = {}
}

// Minimizes Σ weight (row · x - rhs)² over the unknowns not `fixed`, the fixed ones held
// at `held`, by the normal equations with a ridge of LEAST_RIDGE times their mean
// diagonal (ConstrainedLeastSquares's solve), factored by the supernodal Cholesky on the
// pool. The first solve on `sys` orders and analyzes the pattern, by AMD over the unknowns
// or, with `group` above 1, over groups of that many consecutive unknowns (each
// triangle's three in the curl correction), whose members are eliminated together; a
// later one must have rows of the same pattern and the same unknowns fixed, and refills
// and refactors.
// Writes every unknown into x; false when the factor fails or the solution is not finite.
@(private)
least_squares :: proc(sys: ^Least_System, rows: ^Least_Rows, n: int, fixed: []bool, held: []f64, x: []f64, pool: ^jobs.Pool, group := 1) -> bool {
	heap := runtime.heap_allocator()
	if !sys.ready {
		sys.free = make([]i32, n, heap)
		sys.columns = 0
		for k in 0 ..< n {
			if fixed != nil && fixed[k] {
				sys.free[k] = GONE
			} else {
				sys.free[k] = i32(sys.columns)
				sys.columns += 1
			}
		}
	}
	free := sys.free
	count := sys.columns
	if count == 0 {
		for k in 0 ..< n do x[k] = held[k]
		return true
	}
	// The first solve gathers the normal matrix's triplets; a later one their numbers
	// alone, in the same order, for the slots the first one kept.
	t: sparse.Triplets
	defer sparse.triplets_destroy(&t)
	refill: []f64
	defer delete(refill, heap)
	if sys.ready {
		refill = make([]f64, len(sys.slots), heap)
	} else {
		pairs := 0
		for r in 0 ..< len(rows.rhs) {
			l := int(rows.first[r + 1] - rows.first[r])
			pairs += l * (l + 1) / 2
		}
		t = sparse.triplets_make(count, pairs + count, heap)
	}
	b := make([]f64, count, heap)
	defer delete(b, heap)
	diagonal := f64(0)
	k := 0
	for r in 0 ..< len(rows.rhs) {
		row := rows.entries[rows.first[r]:rows.first[r + 1]]
		w := math.sqrt(rows.weight[r])
		shift := f64(0)
		for c in row do if free[c.index] == GONE do shift += c.a * held[c.index]
		value := w * (rows.rhs[r] - shift)
		for c, p in row {
			i := free[c.index]
			if i == GONE do continue
			ai := w * c.a
			b[i] += ai * value
			for q in p ..< len(row) {
				j := free[row[q].index]
				if j == GONE do continue
				v := ai * (w * row[q].a)
				if sys.ready {
					refill[k] = v
				} else {
					sparse.triplets_add(&t, int(i), int(j), v)
				}
				k += 1
				if p == q do diagonal += v
			}
		}
	}
	if !least_matrix(sys, &t, refill, k, diagonal, n, group) do return false
	// The triplets and the refill are in the matrix now; neither is held while it factors.
	sparse.triplets_destroy(&t)
	delete(refill, heap)
	refill = nil
	if !sparse.supernodal_factor(&sys.factor, &sys.symbolic, sys.normal, pool, heap) do return false
	y := make([]f64, count, heap)
	defer delete(y, heap)
	sparse.supernodal_solve(&sys.factor, b, y)
	// The factor is made again by the next solve, so it is not held between solves (the
	// curl correction's is the largest thing a cover makes).
	sparse.supernodal_factor_destroy(&sys.factor, heap)
	for v in y do if math.is_nan(v) || math.is_inf(v) do return false
	for u in 0 ..< n do x[u] = held[u] if free[u] == GONE else y[free[u]]
	return true
}

// The ridge on the triplets made so far (`made` of them, in `t` on the first solve and
// `refill` on a later one), then the normal matrix made, ordered and analyzed, or its
// numbers refilled.
@(private = "file")
least_matrix :: proc(sys: ^Least_System, t: ^sparse.Triplets, refill: []f64, made: int, diagonal: f64, n, group: int) -> bool {
	heap := runtime.heap_allocator()
	count := sys.columns
	k := made
	ridge := LEAST_RIDGE * diagonal / f64(count) if diagonal > 0 else LEAST_RIDGE
	for i in 0 ..< count {
		if sys.ready {
			refill[k] = ridge
		} else {
			sparse.triplets_add(t, i, i, ridge)
		}
		k += 1
	}
	if sys.ready {
		sparse.symmetric_refill(&sys.normal, sys.slots, refill)
	} else {
		ok: bool
		sys.normal, ok = sparse.symmetric_from_triplets(t^, &sys.slots, heap)
		sparse.triplets_destroy(t)
		if !ok do return false
		order: []i32
		defer delete(order, heap)
		if group > 1 do order = group_order(sys, n, group)
		sys.symbolic = sparse.supernodal_analyze(sys.normal, order, heap)
		sys.ready = true
	}
	return true
}

// An order of the system's columns that keeps each group of `group` consecutive unknowns
// together: AMD over the groups' graph, each group's free unknowns in turn.
@(private = "file")
group_order :: proc(sys: ^Least_System, n, group: int) -> []i32 {
	heap := runtime.heap_allocator()
	groups := (n + group - 1) / group
	unknown := make([]i32, sys.columns, heap)
	defer delete(unknown, heap)
	for f, k in sys.free do if f != GONE do unknown[f] = i32(k)
	m := sys.normal
	t := sparse.triplets_make(groups, len(m.rows), heap)
	defer sparse.triplets_destroy(&t)
	for j in 0 ..< m.n do for p in m.first[j] ..< m.first[j + 1] do sparse.triplets_add(&t, int(unknown[m.rows[p]]) / group, int(unknown[j]) / group, 1)
	g, _ := sparse.symmetric_from_triplets(t, nil, heap)
	defer sparse.symmetric_destroy(&g, heap)
	by_group, inverse := sparse.amd_order(g, heap)
	defer delete(by_group, heap)
	defer delete(inverse, heap)
	order := make([]i32, sys.columns, heap)
	at := 0
	for gi in by_group do for k in int(gi) * group ..< min((int(gi) + 1) * group, n) do if sys.free[k] != GONE {
		order[at] = sys.free[k]
		at += 1
	}
	return order
}
