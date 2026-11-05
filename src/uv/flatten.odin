package uv

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:time"

import "../geom"
import "../jobs"
import "../sparse"

// Flattening: each island that has a border is laid flat with as little distortion as
// the method gives, as Blender's Unwrap does, and scaled to its surface area so every
// island has the same texel density. Closed islands (no border) are left for seams to
// open (auto seams cut them).

Method :: enum u8 {
	Lscm, // least squares conformal maps (Lévy et al. 2002), straight from the surface
}

// Islands of at least this many triangles are solved one at a time with the pool working
// inside the solve; smaller ones side by side, one a thread.
@(private)
BIG_ISLAND :: 20_000

Flatten_Report :: struct {
	islands:   int, // islands the UVs have
	flattened: int, // laid flat
	closed:    int, // left as they were, having no border to open them along
	failed:    int, // left as they were: the solve broke down (a damaged surface)
	flips:     int, // flattened triangles facing the other way from their island
	ms:        f64,
}

// Flattens every island of `u` that has a border, in place, for the mesh `positions` and
// `indices` (with `faces`). An island with two or more pinned vertices (u.pins; a pinned
// vertex holds every corner of it in that island) keeps them where they are and is not
// scaled; with one, that pin and the border vertex farthest from it along the island's
// longest side are held for the solve; with none, the two border vertices farthest apart
// along that side. Big islands are solved one at a time with the pool working inside each
// solve, then the others side by side, each with memory of its own; nothing depends on
// the pool. The flattened islands that are not pinned are then placed side by side in
// the unit square (shelf_pack). Nothing happens without UVs.
flatten :: proc(u: ^Uvs, positions: []geom.Vec3, indices: []u32, faces: geom.Vertex_Faces, method: Method = .Lscm, pool: ^jobs.Pool = nil) -> (r: Flatten_Report) {
	start := time.tick_now()
	r.islands = u.islands
	if !has(u^) || u.islands == 0 do return
	order, first := island_triangles(u^, context.temp_allocator)
	Island_Result :: struct {
		state:  enum u8 {Untouched, Flat, Closed, Failed},
		pinned: bool, // held where its pins are, so neither scaled nor placed
		flips:  int,
	}
	Job :: struct {
		u:         ^Uvs,
		positions: []geom.Vec3,
		indices:   []u32,
		faces:     geom.Vertex_Faces,
		order:     []u32,
		first:     []u32,
		biggest:   []u32,
		results:   []Island_Result,
	}
	job := Job{u, positions, indices, faces, order, first, make([]u32, u.islands, context.temp_allocator), make([]Island_Result, u.islands, context.temp_allocator)}
	// Biggest first, so the big islands are a run at the start and the small ones are
	// claimed largest first.
	Size :: struct {
		triangles, island: u32,
	}
	sizes := make([]Size, u.islands, context.temp_allocator)
	for &s, i in sizes do s = {first[i + 1] - first[i], u32(i)}
	slice.sort_by(sizes, proc(a, b: Size) -> bool {return a.triangles > b.triangles || (a.triangles == b.triangles && a.island < b.island)})
	for s, i in sizes do job.biggest[i] = s.island
	// One island, solved on the calling thread with `pool` (nil inside a job).
	solve :: proc(job: ^Job, i: u32, pool: ^jobs.Pool) {
		heap := runtime.heap_allocator()
		context.allocator = heap
		res := &job.results[i]
		tris := job.order[job.first[i]:job.first[i + 1]]
		island := island_mesh(job.u^, job.indices, job.faces, tris, heap)
		defer island_mesh_free(&island, heap)
		if !island.border {
			res.state = .Closed
			return
		}
		flat, pinned, ok := lscm(job.u^, job.positions, &island, pool, heap)
		defer delete(flat, heap)
		if !ok {
			res.state = .Failed
			return
		}
		res.state, res.pinned = .Flat, pinned
		for t, li in tris do for k in 0 ..< 3 {
			p := flat[island.wedge[3 * li + k]]
			job.u.corner[t][k] = {f32(p.x), f32(p.y)}
		}
		for li in 0 ..< len(tris) do if signed_area(flat, island.wedge[3 * li:][:3]) < 0 do res.flips += 1
	}
	// The pool runs one job at a time, so the big islands go first, one by one, each with
	// the pool inside its solve, and then the small ones side by side, one a thread.
	big := 0
	for big < len(sizes) && sizes[big].triangles >= BIG_ISLAND do big += 1
	for i in job.biggest[:big] do solve(&job, i, pool)
	job.biggest = job.biggest[big:]
	jobs.parallel_for(pool, len(job.biggest), &job, proc(data: rawptr, n: int) {
		job := cast(^Job)data
		solve(job, job.biggest[n], nil)
	})
	place := make([]bool, u.islands, context.temp_allocator)
	for res, i in job.results {
		switch res.state {
		case .Untouched:
		case .Flat:
			place[i] = !res.pinned
			r.flattened += 1
			r.flips += res.flips
		case .Closed: r.closed += 1
		case .Failed: r.failed += 1
		}
	}
	shelf_pack(u, place)
	u.filled = boxes_filled(u^)
	r.ms = time.duration_milliseconds(time.tick_since(start))
	return
}

// The conformal map of island `m`: a coordinate per wedge, made with `allocator`. False
// when the solve breaks down, as a surface with non-finite positions
// makes it.
@(private)
lscm :: proc(u: Uvs, positions: []geom.Vec3, m: ^Island_Mesh, pool: ^jobs.Pool, allocator: runtime.Allocator) -> (flat: [][2]f64, pinned, ok: bool) {
	a := allocator
	corners := m.wedge
	n := len(corners) / 3
	// The caller frees `flat` whether or not the solve works.
	flat = make([][2]f64, m.wedges, a)

	for v in m.vertex do for x in positions[v] do if math.is_nan(x) || math.is_inf(x) do return

	// What is held: two or more pinned wedges where they are, otherwise a pair set apart
	// by their distance on the surface.
	fixed := make([]bool, m.wedges, a)
	defer delete(fixed, a)
	held := 0
	one := -1
	if u.pins != nil do for w in 0 ..< m.wedges {
		if _, on := slice.binary_search(u.pins, m.vertex[w]); on {
			fixed[w] = true
			held += 1
			if one < 0 do one = w
		}
	}
	pinned = held >= 2
	if pinned {
		for c in 0 ..< len(corners) do if fixed[corners[c]] {
			p := u.corner[m.tris[c / 3]][c % 3]
			flat[corners[c]] = {f64(p.x), f64(p.y)}
		}
	} else {
		for &f in fixed do f = false
		p, q := far_pair(positions, m, one)
		if p == q do return
		fixed[p], fixed[q] = true, true
		flat[p] = {0, 0}
		flat[q] = {f64(linalg.length(positions[m.vertex[q]] - positions[m.vertex[p]])), 0}
	}

	// The unknowns: two a free wedge, u then v.
	column := make([]i32, m.wedges, a)
	defer delete(column, a)
	free := 0
	for w in 0 ..< m.wedges {
		column[w] = -1 if fixed[w] else i32(free)
		if !fixed[w] do free += 1
	}

	// Each triangle's two rows of LSCM's least squares system (Lévy et al. 2002): for its
	// corners in a frame of their own, W_j = (z_{j+2} - z_{j+1}) / sqrt(2·area), and the
	// residual Σ W_j·(u_j + i·v_j). Its real part is Σ a_j·u_j - b_j·v_j and its imaginary
	// part Σ b_j·u_j + a_j·v_j.
	coef := make([][3][2]f64, n, a)
	defer delete(coef, a)
	area_sum: f64
	for t in 0 ..< n {
		s, area := triangle_frame(positions, m.vertex, corners[3 * t:][:3])
		area_sum += area
		weight := 1.0
		if !(area > 1e-14 * max(linalg.length2(s[1]), linalg.length2(s[2]), 1e-30)) {
			// A sliver: an equilateral stand-in at a tenth of the weight, as Blender treats
			// them, so it neither breaks the solve nor pulls on its neighbours.
			l := max(math.sqrt(linalg.length2(s[1])), math.sqrt(linalg.length2(s[2])), 1e-9)
			s = {{0, 0}, {l, 0}, {l * 0.5, l * math.sqrt(f64(3)) * 0.5}}
			area = l * l * math.sqrt(f64(3)) * 0.25
			weight = 0.1
		}
		scale := weight / math.sqrt(2 * area)
		for j in 0 ..< 3 do coef[t][j] = (s[(j + 2) % 3] - s[(j + 1) % 3]) * scale
	}
	for c in coef do for j in c do if !finite(j) do return

	// The free wedges' neighbours through the triangles, each row sorted and once.
	next := make([]u32, free + 1, a)
	defer delete(next, a)
	for t in 0 ..< n do for j in 0 ..< 3 {
		cj := column[corners[3 * t + j]]
		if cj < 0 do continue
		for k in 0 ..< 3 do if k != j && column[corners[3 * t + k]] >= 0 do next[cj + 1] += 1
	}
	for i in 0 ..< free do next[i + 1] += next[i]
	neighbour := make([]u32, next[free], a)
	defer delete(neighbour, a)
	fill := make([]u32, free, a)
	defer delete(fill, a)
	copy(fill, next[:free])
	for t in 0 ..< n do for j in 0 ..< 3 {
		cj := column[corners[3 * t + j]]
		if cj < 0 do continue
		for k in 0 ..< 3 do if ck := column[corners[3 * t + k]]; k != j && ck >= 0 {
			neighbour[fill[cj]] = u32(ck)
			fill[cj] += 1
		}
	}
	// Sorted and made unique in place; `ends[i]` is where row i's distinct entries end.
	ends := make([]u32, free, a)
	defer delete(ends, a)
	for i in 0 ..< free {
		row := neighbour[next[i]:next[i + 1]]
		slice.sort(row)
		kept := 0
		for v, x in row do if x == 0 || v != row[kept - 1] {
			row[kept] = v
			kept += 1
		}
		ends[i] = next[i] + u32(kept)
	}

	// The normal equations' 2 by 2 blocks: block(i, j)[r][c] couples unknown r of wedge i
	// with unknown c of wedge j; the diagonal ones apart, the others beside `neighbour`.
	Block :: [2][2]f64
	block :: #force_inline proc(ci, cj: [2]f64) -> Block {
		return {{ci.x * cj.x + ci.y * cj.y, -ci.x * cj.y + ci.y * cj.x}, {-ci.y * cj.x + ci.x * cj.y, ci.y * cj.y + ci.x * cj.x}}
	}
	diagonal := make([]Block, free, a)
	defer delete(diagonal, a)
	off := make([]Block, next[free], a)
	defer delete(off, a)
	rhs := make([]f64, 2 * free, a)
	defer delete(rhs, a)
	for t in 0 ..< n do for j in 0 ..< 3 {
		cj := column[corners[3 * t + j]]
		if cj < 0 do continue
		for k in 0 ..< 3 {
			b := block(coef[t][j], coef[t][k])
			wk := corners[3 * t + k]
			ck := column[wk]
			switch {
			case k == j:
				for r in 0 ..< 2 do for c in 0 ..< 2 do diagonal[cj][r][c] += b[r][c]
			case ck < 0:
				x := flat[wk]
				rhs[2 * cj] -= b[0][0] * x.x + b[0][1] * x.y
				rhs[2 * cj + 1] -= b[1][0] * x.x + b[1][1] * x.y
			case:
				row := neighbour[next[cj]:ends[cj]]
				at, _ := slice.binary_search(row, u32(ck))
				e := &off[next[cj] + u32(at)]
				for r in 0 ..< 2 do for c in 0 ..< 2 do e[r][c] += b[r][c]
			}
		}
	}

	// The system on the shared sparse solver: the upper triangle once (each diagonal
	// block's upper half and each neighbour pair from its lower numbered wedge), unknown c
	// of wedge i being 2i + c.
	heap := runtime.heap_allocator()
	t := sparse.triplets_make(2 * free, 3 * free + 4 * int(next[free]), heap)
	defer sparse.triplets_destroy(&t)
	for i in 0 ..< free {
		for r in 0 ..< 2 do for c in r ..< 2 do sparse.triplets_add(&t, 2 * i + r, 2 * i + c, diagonal[i][r][c])
		for x in next[i] ..< ends[i] do if j := int(neighbour[x]); j > i {
			for r in 0 ..< 2 do for c in 0 ..< 2 do sparse.triplets_add(&t, 2 * i + r, 2 * j + c, off[x][r][c])
		}
	}
	system, built := sparse.symmetric_from_triplets(t, nil, heap)
	if !built do return
	defer sparse.symmetric_destroy(&system, heap)

	// AMD over the wedges' graph, each wedge's two unknowns kept together, so the
	// supernodes come in whole blocks.
	g := sparse.triplets_make(free, free + int(next[free]), heap)
	defer sparse.triplets_destroy(&g)
	for i in 0 ..< free {
		sparse.triplets_add(&g, i, i, 1)
		for x in next[i] ..< ends[i] do if j := int(neighbour[x]); j > i do sparse.triplets_add(&g, i, j, 1)
	}
	graph, _ := sparse.symmetric_from_triplets(g, nil, heap)
	defer sparse.symmetric_destroy(&graph, heap)
	by_wedge, inverse := sparse.amd_order(graph, heap)
	delete(inverse, heap)
	order := make([]i32, 2 * free, heap)
	for w, k in by_wedge do order[2 * k], order[2 * k + 1] = 2 * w, 2 * w + 1
	delete(by_wedge, heap)
	symbolic := sparse.supernodal_analyze(system, order, heap)
	delete(order, heap)
	defer sparse.supernodal_symbolic_destroy(&symbolic, heap)
	factor: sparse.Supernodal_Factor
	if !sparse.supernodal_factor(&factor, &symbolic, system, pool, heap) do return
	defer sparse.supernodal_factor_destroy(&factor, heap)
	x := make([]f64, 2 * free, heap)
	defer delete(x, heap)
	sparse.supernodal_solve(&factor, rhs, x)
	for w in 0 ..< m.wedges do if c := column[w]; c >= 0 do flat[w] = {x[2 * c], x[2 * c + 1]}
	for p in flat do if !finite(p) do return

	if !pinned {
		// The surface's area, facing up. The conformal energy keeps the triangles'
		// winding, so a negative total would only come from a solve gone wrong, which the
		// flip count then shows anyway.
		uv_area: f64
		for t in 0 ..< n do uv_area += signed_area(flat, corners[3 * t:][:3])
		if uv_area < 0 do for &p in flat do p.y = -p.y
		if uv_area == 0 do return
		s := math.sqrt(area_sum / abs(uv_area))
		for &p in flat do p *= s
	}
	ok = true
	return
}

// Triangle `w`'s corners (wedges at `vertex`) laid into a frame of its own: corner 0 at
// the origin, corner 1 along x, corner 2 above; and its area.
@(private)
triangle_frame :: proc(positions: []geom.Vec3, vertex: []u32, w: []u32) -> (s: [3][2]f64, area: f64) {
	p0 := linalg.array_cast(positions[vertex[w[0]]], f64)
	e1 := linalg.array_cast(positions[vertex[w[1]]], f64) - p0
	e2 := linalg.array_cast(positions[vertex[w[2]]], f64) - p0
	x1 := linalg.length(e1)
	if !(x1 > 0) do return {{0, 0}, {x1, 0}, {0, 0}}, 0
	y2 := linalg.length(linalg.cross(e1, e2)) / x1
	s = {{0, 0}, {x1, 0}, {linalg.dot(e2, e1) / x1, y2}}
	return s, x1 * y2 * 0.5
}

@(private)
signed_area :: proc(flat: [][2]f64, w: []u32) -> f64 {
	a, b, c := flat[w[0]], flat[w[1]], flat[w[2]]
	return ((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) * 0.5
}

// The two border wedges to hold: the extremes along the longest side of the island's box,
// the lowest numbered on a tie; with a pinned wedge `one` (or -1), that one and the
// extreme farther from it.
@(private)
far_pair :: proc(positions: []geom.Vec3, m: ^Island_Mesh, one: int) -> (p, q: int) {
	lo, hi := [3]f32{math.F32_MAX, math.F32_MAX, math.F32_MAX}, [3]f32{-math.F32_MAX, -math.F32_MAX, -math.F32_MAX}
	for v in m.vertex do lo, hi = linalg.min(lo, positions[v]), linalg.max(hi, positions[v])
	size := hi - lo
	axis := 0
	if size.y > size[axis] do axis = 1
	if size.z > size[axis] do axis = 2
	p, q = -1, -1
	for w in 0 ..< m.wedges {
		if !m.on_edge[w] do continue
		at := positions[m.vertex[w]][axis]
		if p < 0 || at < positions[m.vertex[p]][axis] do p = w
		if q < 0 || at > positions[m.vertex[q]][axis] do q = w
	}
	if p < 0 do return 0, 0
	if one >= 0 {
		at := positions[m.vertex[one]][axis]
		far := q if abs(positions[m.vertex[q]][axis] - at) >= abs(positions[m.vertex[p]][axis] - at) else p
		return one, far
	}
	return
}

@(private)
finite :: proc(p: [2]f64) -> bool {
	return !math.is_nan(p.x) && !math.is_nan(p.y) && !math.is_inf(p.x) && !math.is_inf(p.y)
}
