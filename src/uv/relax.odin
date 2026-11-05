package uv

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:time"

import "../geom"
import "../jobs"
import "../sparse"

// Stretch relax: SLIM (Rabinovich, Poranne, Panozzo and Sorkine-Hornung 2017) on the
// symmetric Dirichlet energy, Σ area·(|J|² + |J⁻¹|²) with J the map from a triangle's
// surface frame to its UVs. The energy is 4 a triangle for a map that keeps lengths and
// grows without bound as a triangle nears zero area, so steps that keep every triangle
// facing up (Smith and Schaefer 2015's largest step) keep the island unfolded. Each
// iteration takes each triangle's closest rotation and a weight from J's singular values
// (the local step) and solves one weighted system for every corner (the global step), on
// the pair system, whose pattern stays the same, so it is analysed once.

Relax_Report :: struct {
	islands: int, // islands the UVs have
	relaxed: int, // relaxed
	skipped: int, // with a border but left as they were: folded or degenerate, so of infinite energy
	before:  f64, // the relaxed islands' energy per unit of surface before (4 keeps lengths)
	after:   f64, // and after
	ms:      f64,
}

// Stops once an iteration lowers the energy by less than this share of it.
@(private = "file")
RELAX_ENOUGH :: 1e-3

// Relaxes every flattened island of `u` (a border, every triangle facing up) for up to
// `iterations` steps, in place, for the mesh `positions` and `indices` (with `faces`).
// An island's pinned vertices hold still, so it keeps its place and size; the other
// islands come out at the surface's size and are packed again (shelf_pack). Big islands
// one at a time with the pool in the factor, the others side by side, as flatten runs.
// With `symmetry` mirrored islands take their leaders' layouts reflected and islands
// that are their own mirrors are made symmetric again after, as flatten does.
relax :: proc(u: ^Uvs, positions: []geom.Vec3, indices: []u32, faces: geom.Vertex_Faces, iterations := 10, pool: ^jobs.Pool = nil, symmetry: ^Symmetry = nil) -> (r: Relax_Report) {
	start := time.tick_now()
	r.islands = u.islands
	if !has(u^) || u.islands == 0 do return
	order, first := island_triangles(u^, context.temp_allocator)
	Result :: struct {
		state:          enum u8 {Untouched, Relaxed, Skipped},
		pinned:         bool,
		surface:        f64,
		before, after:  f64,
	}
	Job :: struct {
		u:          ^Uvs,
		positions:  []geom.Vec3,
		indices:    []u32,
		faces:      geom.Vertex_Faces,
		order:      []u32,
		first:      []u32,
		results:    []Result,
		iterations: int,
		mirror:     Mirror,
		symmetric:  bool,
	}
	job := Job{u, positions, indices, faces, order, first, make([]Result, u.islands, context.temp_allocator), iterations, {}, symmetry != nil}
	if symmetry != nil do job.mirror = mirror_build(u^, positions, indices, faces, symmetry^, order, first)
	islands_run(first, &job, pool, proc(data: rawptr, i: u32, pool: ^jobs.Pool) {
		job := cast(^Job)data
		heap := runtime.heap_allocator()
		context.allocator = heap
		res := &job.results[i]
		if job.symmetric && job.mirror.leader[i] >= 0 do return
		tris := job.order[job.first[i]:job.first[i + 1]]
		island := island_mesh(job.u^, job.indices, job.faces, tris, heap)
		defer island_mesh_free(&island, heap)
		if !island.border do return
		ok: bool
		res.pinned, res.surface, res.before, res.after, ok = slim(job.u, job.positions, &island, job.iterations, pool)
		res.state = .Relaxed if ok else .Skipped
		if ok && !res.pinned && job.symmetric && job.mirror.self[i] {
			mirrors := mirror_wedges(&island, job.mirror, heap)
			defer delete(mirrors, heap)
			symmetrize_corners(job.u, &island, mirrors, job.positions, job.mirror.axis)
		}
	})
	leader: []i32
	if symmetry != nil {
		leader = job.mirror.leader
		for l, i in leader do if l >= 0 do job.results[i] = job.results[l]
		mirror_copy(u, job.mirror, proc(island: u32, data: rawptr) -> bool {
			results := cast(^[]Result)data
			return results[island].state == .Relaxed
		}, &job.results)
	}
	place := make([]bool, u.islands, context.temp_allocator)
	surface: f64
	for res, i in job.results {
		switch res.state {
		case .Untouched:
		case .Relaxed:
			r.relaxed += 1
			place[i] = !res.pinned
			surface += res.surface
			r.before += res.before
			r.after += res.after
		case .Skipped: r.skipped += 1
		}
	}
	if surface > 0 {
		r.before /= surface
		r.after /= surface
	}
	shelf_pack(u, place, leader)
	u.filled = boxes_filled(u^)
	r.ms = time.duration_milliseconds(time.tick_since(start))
	return
}

// One island's SLIM iterations, written back into u.corner. Returns whether it had pins,
// its surface area and its energy before and after; false (and nothing written) when a
// triangle is folded or degenerate at the start, or the surface is not finite.
@(private = "file")
slim :: proc(u: ^Uvs, positions: []geom.Vec3, m: ^Island_Mesh, iterations: int, pool: ^jobs.Pool) -> (pinned: bool, surface, before, after: f64, ok: bool) {
	heap := runtime.heap_allocator()
	corners := m.wedge
	n := len(corners) / 3

	// The start: each wedge where its first corner is.
	x := make([][2]f64, m.wedges, heap)
	defer delete(x, heap)
	seen := make([]bool, m.wedges, heap)
	defer delete(seen, heap)
	for t in 0 ..< n do for k in 0 ..< 3 {
		w := corners[3 * t + k]
		if seen[w] do continue
		seen[w] = true
		p := u.corner[m.tris[t]][k]
		x[w] = {f64(p.x), f64(p.y)}
	}

	// Per triangle its area on the surface and the gradients of its three corners'
	// barycentric weights in its surface frame (J = Σ x_k g_kᵀ).
	// The frames are measured at the island's own scale (its UV area over its surface
	// area), so a pinned island keeps its size and a packed one is not pulled back to the
	// surface's first; the packing scales the unpinned ones afterwards anyway.
	area := make([]f64, n, heap)
	defer delete(area, heap)
	grads := make([][3][2]f64, n, heap)
	defer delete(grads, heap)
	uv_area, surface_area: f64
	for t in 0 ..< n {
		_, a := triangle_frame(positions, m.vertex, corners[3 * t:][:3])
		surface_area += a
		w3 := corners[3 * t:][:3]
		p1, p2 := x[w3[1]] - x[w3[0]], x[w3[2]] - x[w3[0]]
		det := (p1.x * p2.y - p1.y * p2.x) * 0.5
		if !(det > 0) do return // folded or degenerate: infinite energy
		uv_area += det
	}
	if !(surface_area > 0) || !(surface_area < math.F64_MAX) do return
	scale := math.sqrt(uv_area / surface_area)
	for t in 0 ..< n {
		s, a := triangle_frame(positions, m.vertex, corners[3 * t:][:3])
		weight := 1.0
		if !(a > 1e-14 * max(linalg.length2(s[1]), linalg.length2(s[2]), 1e-30)) {
			// A sliver: the equilateral stand-in at a tenth of the weight, as lscm takes it.
			l := max(math.sqrt(linalg.length2(s[1])), math.sqrt(linalg.length2(s[2])), 1e-9)
			s = {{0, 0}, {l, 0}, {l * 0.5, l * math.sqrt(f64(3)) * 0.5}}
			a = l * l * math.sqrt(f64(3)) * 0.25
			weight = 0.1
		}
		for &c in s do c *= scale
		a *= scale * scale
		area[t] = a * weight
		surface += area[t]
		// The frame's edges E = [s1 - s0, s2 - s0]; g_1, g_2 are E⁻¹'s rows and g_0 = -g_1 - g_2.
		det := s[1].x * s[2].y - s[2].x * s[1].y
		g1 := [2]f64{s[2].y / det, -s[2].x / det}
		g2 := [2]f64{-s[1].y / det, s[1].x / det}
		grads[t] = {-g1 - g2, g1, g2}
	}

	energy :: proc(x: [][2]f64, corners: []u32, area: []f64, grads: [][3][2]f64) -> f64 {
		e: f64 = 0
		for t in 0 ..< len(area) {
			J := jacobian_at(x, corners[3 * t:][:3], grads[t])
			det := J[0][0] * J[1][1] - J[0][1] * J[1][0]
			if !(det > 0) do return math.INF_F64
			f := J[0][0] * J[0][0] + J[0][1] * J[0][1] + J[1][0] * J[1][0] + J[1][1] * J[1][1]
			e += area[t] * (f + f / (det * det))
		}
		return e
	}
	before = energy(x, corners, area, grads)
	if !(before < math.F64_MAX) do return

	// What is held: the pinned wedges, or else the lowest numbered wedge, which takes away
	// only the moves of the whole island (the rotations R fix its turn). An island with
	// two pins or more keeps its place and is not packed, as flatten treats it.
	fixed := make([]bool, m.wedges, heap)
	defer delete(fixed, heap)
	held := 0
	if u.pins != nil do for w in 0 ..< m.wedges {
		if _, on := binary_search_u32(u.pins, m.vertex[w]); on {
			fixed[w] = true
			held += 1
		}
	}
	pinned = held >= 2
	if held == 0 do fixed[0] = true
	column := make([]i32, m.wedges, heap)
	defer delete(column, heap)
	free := 0
	for w in 0 ..< m.wedges {
		column[w] = -1 if fixed[w] else i32(free)
		if !fixed[w] do free += 1
	}
	after = before
	// Nothing to gain where the lengths are kept already (4 per unit of surface).
	if free == 0 || before <= 4 * surface * (1 + 1e-6) do return pinned, surface, before, after, true

	rhs := make([]f64, 2 * free, heap)
	defer delete(rhs, heap)
	solved := make([]f64, 2 * free, heap)
	defer delete(solved, heap)
	values := make([dynamic]f64, 0, 21 * n, heap)
	defer delete(values)
	target := make([][2]f64, m.wedges, heap)
	defer delete(target, heap)
	trial := make([][2]f64, m.wedges, heap)
	defer delete(trial, heap)
	system: Pair_System
	made := false
	defer if made do pair_system_destroy(&system)

	for _ in 0 ..< iterations {
		// The local step and the global system: block(k, l) = A (g_k·g_l) M and the
		// right side A M R g_k, with M = W², per triangle.
		for &v in rhs do v = 0
		clear(&values)
		build: sparse.Triplets
		if !made do build = sparse.triplets_make(2 * free, 21 * n, heap)
		for t in 0 ..< n {
			w3 := corners[3 * t:][:3]
			g := grads[t]
			J := jacobian_at(x, w3, g)
			R, M := slim_local(J)
			for k in 0 ..< 3 {
				ck := column[w3[k]]
				if ck < 0 do continue
				rg := R * matrix[2, 1]f64{g[k].x, g[k].y}
				mr := M * rg
				rhs[2 * ck] += area[t] * mr[0, 0]
				rhs[2 * ck + 1] += area[t] * mr[1, 0]
				for l in 0 ..< 3 {
					cl := column[w3[l]]
					dot := area[t] * (g[k].x * g[l].x + g[k].y * g[l].y)
					if cl < 0 {
						xl := x[w3[l]]
						rhs[2 * ck] -= dot * (M[0, 0] * xl.x + M[0, 1] * xl.y)
						rhs[2 * ck + 1] -= dot * (M[1, 0] * xl.x + M[1, 1] * xl.y)
						continue
					}
					// Each pair once, from its lower column; the diagonal block's upper half.
					if cl < ck || (cl == ck && l != k) do continue
					for rr in 0 ..< 2 do for cc in 0 ..< 2 {
						if cl == ck && cc < rr do continue
						v := dot * M[rr, cc]
						append(&values, v)
						if !made do sparse.triplets_add(&build, 2 * int(ck) + rr, 2 * int(cl) + cc, v)
					}
				}
			}
		}
		if !made {
			built: bool
			system, built = pair_system_make(build, keep_slots = true)
			sparse.triplets_destroy(&build)
			if !built do break
			made = true
		} else {
			pair_system_refill(&system, values[:])
		}
		if !pair_system_solve(&system, pool, rhs, solved) do break
		for w in 0 ..< m.wedges do target[w] = x[w] if column[w] < 0 else {solved[2 * column[w]], solved[2 * column[w] + 1]}

		// The line search: at most 0.8 of the largest step that folds no triangle, then
		// halved until the energy falls.
		step := 1.0
		for t in 0 ..< n {
			w3 := corners[3 * t:][:3]
			step = min(step, 0.8 * fold_step(x, target, w3))
		}
		e := math.INF_F64
		for _ in 0 ..< 30 {
			for w in 0 ..< m.wedges do trial[w] = x[w] + (target[w] - x[w]) * step
			e = energy(trial, corners, area, grads)
			if e < after do break
			step *= 0.5
		}
		if !(e < after) do break
		copy(x, trial)
		done := after - e < RELAX_ENOUGH * after
		after = e
		if done do break
	}

	for t in 0 ..< n do for k in 0 ..< 3 {
		p := x[corners[3 * t + k]]
		u.corner[m.tris[t]][k] = {f32(p.x), f32(p.y)}
	}
	return pinned, surface, before, after, true
}

// J = Σ x_k g_kᵀ for the triangle's wedges `w`.
@(private = "file")
jacobian_at :: #force_inline proc(x: [][2]f64, w: []u32, g: [3][2]f64) -> (J: [2][2]f64) {
	for k in 0 ..< 3 {
		p := x[w[k]]
		J[0][0] += p.x * g[k].x
		J[0][1] += p.x * g[k].y
		J[1][0] += p.y * g[k].x
		J[1][1] += p.y * g[k].y
	}
	return
}

// SLIM's local step for the symmetric Dirichlet energy: J = U Σ Vᵀ in closed form (2 by 2,
// signed: U and V rotations, the sign in σ2, so R is never a reflection), the closest
// rotation R = U Vᵀ and M = W² with W = U diag(w) Uᵀ, w_i the square root of
// (σ_i - σ_i⁻³) / (σ_i - 1) = (σ_i + 1)(σ_i² + 1) / σ_i³, which is 2 at σ_i = 1.
@(private = "file")
slim_local :: proc(J: [2][2]f64) -> (R, M: matrix[2, 2]f64) {
	e := (J[0][0] + J[1][1]) * 0.5
	f := (J[0][0] - J[1][1]) * 0.5
	g := (J[1][0] + J[0][1]) * 0.5
	h := (J[1][0] - J[0][1]) * 0.5
	q := math.sqrt(e * e + h * h)
	r := math.sqrt(f * f + g * g)
	s1, s2 := q + r, q - r
	a1 := math.atan2(g, f)
	a2 := math.atan2(h, e)
	// J = rot(φ) diag(σ1, σ2) rot(θ): U = rot(φ), the rotation R = rot(φ + θ) = rot(a2).
	phi := (a2 + a1) * 0.5
	c, s := math.cos(a2), math.sin(a2)
	R = {c, -s, s, c}
	weight :: proc(sigma: f64) -> f64 {
		s := max(sigma, 1e-12)
		return math.sqrt((s + 1) * (s * s + 1) / (s * s * s))
	}
	w1, w2 := weight(s1), weight(s2)
	cu, su := math.cos(phi), math.sin(phi)
	// M = U diag(w1², w2²) Uᵀ.
	a, b := w1 * w1, w2 * w2
	M = {cu * cu * a + su * su * b, cu * su * (a - b), cu * su * (a - b), su * su * a + cu * cu * b}
	return
}

// The share of the way from `x` to `y` at which triangle `w` first reaches zero area, or
// a share past 1 when it never does on the way.
@(private = "file")
fold_step :: proc(x, y: [][2]f64, w: []u32) -> f64 {
	p1, p2 := x[w[1]] - x[w[0]], x[w[2]] - x[w[0]]
	d1, d2 := (y[w[1]] - y[w[0]]) - p1, (y[w[2]] - y[w[0]]) - p2
	// det(p + t d) = c + b t + a t².
	a := d1.x * d2.y - d1.y * d2.x
	b := p1.x * d2.y + d1.x * p2.y - p1.y * d2.x - d1.y * p2.x
	c := p1.x * p2.y - p1.y * p2.x
	best := math.INF_F64
	if abs(a) < 1e-300 {
		if b < 0 do best = -c / b
	} else {
		disc := b * b - 4 * a * c
		if disc >= 0 {
			root := math.sqrt(disc)
			// The two roots, each the stable way.
			q := -0.5 * (b + math.copy_sign(root, b))
			for t in ([2]f64{q / a, c / q if q != 0 else math.INF_F64}) do if t > 0 do best = min(best, t)
		}
	}
	return best
}

@(private = "file")
binary_search_u32 :: proc(s: []u32, v: u32) -> (int, bool) {
	lo, hi := 0, len(s)
	for lo < hi {
		mid := (lo + hi) / 2
		if s[mid] < v do lo = mid + 1
		else do hi = mid
	}
	return lo, lo < len(s) && s[lo] == v
}
