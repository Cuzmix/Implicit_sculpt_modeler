package uv

import "base:runtime"
import "core:math"

import "../geom"
import "../jobs"
import "../sparse"

// ABF++ (Sheffer, Lévy, Mogilnitsky and Bogomyakov 2005): the angles of a flat island
// closest to the surface's, found by Newton's method on the Lagrangian of
//   E = ½ Σ w_i (α_i - β_i)²,  w_i = 1 / β_i²,
// under the conditions that make the angles a flat mesh: each triangle's sum is π, each
// interior wedge's sum is 2π, and round each interior wedge the products of the sines
// of the angles after it and before it agree (the wheel condition, which closes the
// lengths round the fan). The angle block of the Newton system is diagonal and the
// triangle conditions touch disjoint angles, so both are eliminated by hand and only a
// system of two unknowns an interior wedge is left, solved on the pair system. LSCM
// then lays the triangles out in the shapes the angles give (flatten.odin).

// Newton steps at most, and the root mean square of the gradient at which they stop and
// below which the angles are still taken after the last step.
@(private = "file")
ABF_STEPS :: 10
@(private = "file")
ABF_DONE :: 1e-6
@(private = "file")
ABF_GOOD_ENOUGH :: 1e-4

// The surface's angles are kept within these, so that no weight or cotangent blows up.
@(private = "file")
ABF_MIN :: 3 * math.PI / 180
@(private = "file")
ABF_MAX :: 175 * math.PI / 180

// The flat angles for island `m`, three per island triangle in its order, made with the
// heap, which the caller frees. False when Newton's method does not reach them, so the caller falls back to LSCM.
@(private)
abf_angles :: proc(positions: []geom.Vec3, m: ^Island_Mesh, pool: ^jobs.Pool) -> (alpha: []f64, ok: bool) {
	heap := runtime.heap_allocator()
	corners := m.wedge
	n := len(corners) / 3
	// The caller frees `alpha` whether or not the angles are reached.
	alpha = make([]f64, 3 * n, heap)

	// The interior wedges, numbered: unknown 2k is wedge k's angle sum, 2k + 1 its wheel.
	inner := make([]i32, m.wedges, heap)
	defer delete(inner, heap)
	interior := 0
	for w in 0 ..< m.wedges {
		inner[w] = -1 if m.on_edge[w] else i32(interior)
		if !m.on_edge[w] do interior += 1
	}

	// The targets: the surface's angles, those round an interior wedge scaled to sum to
	// 2π (as Blender does, so the start is closer to flat), then clamped.
	beta := make([]f64, 3 * n, heap)
	defer delete(beta, heap)
	for t in 0 ..< n {
		s, _ := triangle_frame(positions, m.vertex, corners[3 * t:][:3])
		for j in 0 ..< 3 {
			b := corner_angle(s, j)
			beta[3 * t + j] = b if !math.is_nan(b) else math.PI / 3
		}
	}
	around := make([]f64, interior, heap)
	defer delete(around, heap)
	for c in 0 ..< 3 * n do if k := inner[corners[c]]; k >= 0 do around[k] += beta[c]
	for c in 0 ..< 3 * n {
		if k := inner[corners[c]]; k >= 0 && around[k] > 0 do beta[c] *= 2 * math.PI / around[k]
		beta[c] = clamp(beta[c], ABF_MIN, ABF_MAX)
	}
	copy(alpha, beta)
	weight := make([]f64, 3 * n, heap)
	defer delete(weight, heap)
	for b, c in beta do weight[c] = 1 / (b * b)

	// The multipliers: one a triangle, two an interior wedge.
	tri := make([]f64, n, heap)
	defer delete(tri, heap)
	wheel := make([]f64, 2 * interior, heap)
	defer delete(wheel, heap)

	// Per step: each angle's cotangent, each interior wedge's two sine products, the
	// gradient and the conditions.
	cot := make([]f64, 3 * n, heap)
	defer delete(cot, heap)
	after := make([]f64, interior, heap)
	defer delete(after, heap)
	before := make([]f64, interior, heap)
	defer delete(before, heap)
	grad := make([]f64, 3 * n, heap)
	defer delete(grad, heap)
	c_tri := make([]f64, n, heap)
	defer delete(c_tri, heap)
	c_wheel := make([]f64, 2 * interior, heap)
	defer delete(c_wheel, heap)
	q := make([]f64, 3 * n, heap)
	defer delete(q, heap)
	rhs := make([]f64, 2 * interior, heap)
	defer delete(rhs, heap)
	step := make([]f64, 2 * interior, heap)
	defer delete(step, heap)
	g := make([]f64, 3 * n, heap)
	defer delete(g, heap)
	values := make([dynamic]f64, 0, 21 * n, heap)
	defer delete(values)

	// Corner j of a triangle: the angle sum of its own wedge, the wheel of the wedge
	// before it (whose "after" angle it is: j is corner k + 1 of k = j + 2) and of the
	// wedge after it (whose "before" angle it is). Its row of the conditions' Jacobian
	// in the six of the triangle's wedges (sum and wheel of each corner's wedge).
	jacobian :: #force_inline proc(t: int, corners: []u32, inner: []i32, cot, after, before: []f64) -> (J: [6][3]f64) {
		for k in 0 ..< 3 {
			kw := inner[corners[3 * t + k]]
			if kw < 0 do continue
			J[2 * k][k] = 1
			J[2 * k + 1][(k + 1) % 3] = after[kw] * cot[3 * t + (k + 1) % 3]
			J[2 * k + 1][(k + 2) % 3] = -before[kw] * cot[3 * t + (k + 2) % 3]
		}
		return
	}

	system: Pair_System
	made := false
	defer if made do pair_system_destroy(&system)
	for iteration in 0 ..= ABF_STEPS {
		for a, c in alpha do cot[c] = math.cos(a) / math.sin(a)
		for &v in after do v = 1
		for &v in before do v = 1
		for k in 0 ..< interior do c_wheel[2 * k] = -2 * math.PI
		for t in 0 ..< n do for k in 0 ..< 3 {
			kw := inner[corners[3 * t + k]]
			if kw < 0 do continue
			after[kw] *= math.sin(alpha[3 * t + (k + 1) % 3])
			before[kw] *= math.sin(alpha[3 * t + (k + 2) % 3])
			c_wheel[2 * kw] += alpha[3 * t + k]
		}
		for k in 0 ..< interior do c_wheel[2 * k + 1] = after[k] - before[k]
		// The gradient of the Lagrangian in the angles and the conditions themselves.
		norm: f64 = 0
		for t in 0 ..< n {
			J := jacobian(t, corners, inner, cot, after, before)
			c_tri[t] = alpha[3 * t] + alpha[3 * t + 1] + alpha[3 * t + 2] - math.PI
			norm += c_tri[t] * c_tri[t]
			for j in 0 ..< 3 {
				c := 3 * t + j
				d := weight[c] * (alpha[c] - beta[c]) + tri[t]
				for k in 0 ..< 3 do if kw := inner[corners[3 * t + k]]; kw >= 0 {
					d += J[2 * k][j] * wheel[2 * kw] + J[2 * k + 1][j] * wheel[2 * kw + 1]
				}
				grad[c] = d
				norm += d * d
			}
		}
		for v in c_wheel do norm += v * v
		rms := math.sqrt(norm / f64(4 * n + 2 * interior))
		if !(rms < math.F64_MAX) do return
		if rms < ABF_DONE do break
		if iteration == ABF_STEPS {
			if rms < ABF_GOOD_ENOUGH do break
			return
		}

		// The reduced system S·dλ = c - J q (see the derivation in the header): per
		// triangle, Λ* = Λ⁻¹ - Λ⁻¹ 1 1ᵀ Λ⁻¹ / D with D the sum of Λ⁻¹ over its angles,
		// and S takes J Λ* Jᵀ over the triangle's rows.
		for &v in rhs do v = 0
		clear(&values)
		t_build: sparse.Triplets
		if !made do t_build = sparse.triplets_make(2 * interior, 21 * n, heap)
		for t in 0 ..< n {
			J := jacobian(t, corners, inner, cot, after, before)
			inv: [3]f64
			d_sum: f64 = 0
			y_sum: f64 = 0
			for j in 0 ..< 3 {
				inv[j] = 1 / weight[3 * t + j]
				d_sum += inv[j]
				y_sum += grad[3 * t + j] * inv[j]
			}
			z := (c_tri[t] - y_sum) / d_sum
			star: [3][3]f64
			for i in 0 ..< 3 {
				q[3 * t + i] = grad[3 * t + i] * inv[i] + inv[i] * z
				for j in 0 ..< 3 do star[i][j] = (inv[i] if i == j else 0) - inv[i] * inv[j] / d_sum
			}
			row: [6]int
			for k in 0 ..< 3 {
				kw := inner[corners[3 * t + k]]
				row[2 * k], row[2 * k + 1] = -1, -1
				if kw >= 0 do row[2 * k], row[2 * k + 1] = 2 * int(kw), 2 * int(kw) + 1
			}
			for r in 0 ..< 6 do if row[r] >= 0 {
				for j in 0 ..< 3 do rhs[row[r]] -= J[r][j] * q[3 * t + j]
				for s in 0 ..< 6 do if row[s] >= row[r] {
					v: f64 = 0
					for i in 0 ..< 3 do for j in 0 ..< 3 do v += J[r][i] * star[i][j] * J[s][j]
					append(&values, v)
					if !made do sparse.triplets_add(&t_build, row[r], row[s], v)
				}
			}
		}
		for v, k in c_wheel do rhs[k] += v
		if interior == 0 {
			// No interior wedge: only the triangles' sums, which the step below meets.
		} else if !made {
			ok_make: bool
			system, ok_make = pair_system_make(t_build, keep_slots = true)
			sparse.triplets_destroy(&t_build)
			if !ok_make do return
			made = true
		} else {
			pair_system_refill(&system, values[:])
		}
		if interior > 0 && !pair_system_solve(&system, pool, rhs, step) do return

		// Back to the triangles' multipliers and the angles: g = Jᵀ dλ per angle,
		// dλ_t = (c_t - Σ y - Σ g/Λ) / D, dα = Λ⁻¹ (-∇ - dλ_t - g).
		for t in 0 ..< n {
			J := jacobian(t, corners, inner, cot, after, before)
			for j in 0 ..< 3 {
				v: f64 = 0
				for k in 0 ..< 3 do if kw := inner[corners[3 * t + k]]; kw >= 0 {
					v += J[2 * k][j] * step[2 * kw] + J[2 * k + 1][j] * step[2 * kw + 1]
				}
				g[3 * t + j] = v
			}
		}
		for k in 0 ..< 2 * interior do wheel[k] += step[k]
		for t in 0 ..< n {
			inv: [3]f64
			d_sum, y_sum: f64
			for j in 0 ..< 3 {
				inv[j] = 1 / weight[3 * t + j]
				d_sum += inv[j]
				y_sum += (grad[3 * t + j] + g[3 * t + j]) * inv[j]
			}
			d_tri := (c_tri[t] - y_sum) / d_sum
			tri[t] += d_tri
			for j in 0 ..< 3 {
				c := 3 * t + j
				alpha[c] += inv[j] * (-grad[c] - d_tri - g[c])
				// An angle pushed out of a triangle is no flat mesh; a step that far is a
				// solve gone wrong, which LSCM then takes over from.
				if !(alpha[c] > 0 && alpha[c] < math.PI) do return
			}
		}
	}
	return alpha, true
}
