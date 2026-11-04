package sparse

import "base:runtime"
import "core:math"

// Conjugate gradients with a Jacobi preconditioner, for a symmetric positive definite
// system the LDLᵀ could not factor (a pivot that came out zero) or one too large to
// factor: it needs only the matrix and a few vectors. Starts from x as given (zero or a
// guess) and stops once the residual's norm is `tolerance` times b's, or after
// `iterations` steps. Returns the steps taken, the relative residual reached and whether
// it reached the tolerance.
cg_solve :: proc(m: Symmetric, b, x: []f64, tolerance := 1e-10, iterations := 0) -> (steps: int, residual: f64, ok: bool) {
	heap := runtime.heap_allocator()
	n := m.n
	if n == 0 do return 0, 0, true
	limit := iterations if iterations > 0 else max(100, 10 * n)
	inverse_diagonal := make([]f64, n, heap)
	defer delete(inverse_diagonal, heap)
	for j in 0 ..< n {
		inverse_diagonal[j] = 1
		for p in m.first[j] ..< m.first[j + 1] {
			if int(m.rows[p]) == j && m.values[p] > 0 do inverse_diagonal[j] = 1 / m.values[p]
		}
	}
	r := make([]f64, n, heap)
	defer delete(r, heap)
	z := make([]f64, n, heap)
	defer delete(z, heap)
	d := make([]f64, n, heap)
	defer delete(d, heap)
	q := make([]f64, n, heap)
	defer delete(q, heap)

	symmetric_multiply(m, x, q)
	b_norm := f64(0)
	for i in 0 ..< n {
		r[i] = b[i] - q[i]
		b_norm += b[i] * b[i]
	}
	b_norm = math.sqrt(b_norm)
	if b_norm == 0 do b_norm = 1
	rz := f64(0)
	for i in 0 ..< n {
		z[i] = inverse_diagonal[i] * r[i]
		d[i] = z[i]
		rz += r[i] * z[i]
	}
	for steps = 0; steps < limit; steps += 1 {
		rr := f64(0)
		for v in r do rr += v * v
		residual = math.sqrt(rr) / b_norm
		if residual <= tolerance do return steps, residual, true
		symmetric_multiply(m, d, q)
		dq := f64(0)
		for i in 0 ..< n do dq += d[i] * q[i]
		if !(dq > 0) do return steps, residual, false
		alpha := rz / dq
		for i in 0 ..< n {
			x[i] += alpha * d[i]
			r[i] -= alpha * q[i]
		}
		rz_next := f64(0)
		for i in 0 ..< n {
			z[i] = inverse_diagonal[i] * r[i]
			rz_next += r[i] * z[i]
		}
		beta := rz_next / rz
		rz = rz_next
		for i in 0 ..< n do d[i] = z[i] + beta * d[i]
	}
	rr := f64(0)
	for v in r do rr += v * v
	residual = math.sqrt(rr) / b_norm
	return steps, residual, residual <= tolerance
}
