package uv

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

// The grid bent up into a dome: a cap of a sphere of radius `r` over its middle, which
// no map lays flat without some stretch.
@(private = "file")
dome :: proc(n: int, r: f32) -> (positions: []geom.Vec3, indices: []u32, faces: geom.Vertex_Faces, u: Uvs) {
	positions, indices, faces, u = test_grid(n, same)
	c := f32(n) * 0.5
	for &p in positions do p = linalg.normalize(geom.Vec3{p.x - c, p.y - c, r}) * r
	return
}

// A tube of `around` by `along` squares, welded round, cut open along the line at its
// first column of vertices, so one island with a border all round.
@(private = "file")
tube :: proc(around, along: int, radius: f32) -> (positions: []geom.Vec3, indices: []u32, faces: geom.Vertex_Faces, u: Uvs) {
	m: geom.Mesh
	m.positions = make([dynamic]geom.Vec3, context.temp_allocator)
	m.indices = make([dynamic]u32, context.temp_allocator)
	for y in 0 ..= along do for x in 0 ..< around {
		a := 2 * math.PI * f32(x) / f32(around)
		append(&m.positions, geom.Vec3{radius * math.cos(a), radius * math.sin(a), f32(y)})
	}
	at :: proc(around, x, y: int) -> u32 {return u32(y * around + x % around)}
	for y in 0 ..< along do for x in 0 ..< around {
		append(&m.indices, at(around, x, y), at(around, x + 1, y), at(around, x + 1, y + 1))
		append(&m.indices, at(around, x, y), at(around, x + 1, y + 1), at(around, x, y + 1))
	}
	positions, indices = m.positions[:], m.indices[:]
	faces = geom.vertex_faces_build(m, nil, context.temp_allocator)
	u = make_uvs(len(indices) / 3, context.temp_allocator)
	for y in 0 ..< along do cut(&u, indices, at(around, 0, y), at(around, 0, y + 1))
	islands_find(&u, indices, faces)
	return
}

// A flat grid comes back as it lies, up to its place and turn: no stretch, no flips.
@(test)
lscm_keeps_a_flat_grid :: proc(t: ^testing.T) {
	positions, indices, faces, u := test_grid(6, proc(p: geom.Vec3) -> [2]f32 {return {}})
	r := flatten(&u, positions, indices, faces)
	testing.expect_value(t, r.flattened, 1)
	testing.expect_value(t, r.flips, 0)
	s := stretch(u, positions, indices)
	testing.expectf(t, abs(s.l2 - 1) < 1e-5 && s.worst < 1 + 1e-4, "stretch %v", s)
	testing.expect_value(t, check(u, indices, faces, len(positions)), "")
}

// A tube cut along a line unrolls with no stretch (its triangles are developable) into
// a strip as long as its perimeter.
@(test)
lscm_unrolls_a_tube :: proc(t: ^testing.T) {
	positions, indices, faces, u := tube(24, 6, 1)
	testing.expect_value(t, u.islands, 1)
	r := flatten(&u, positions, indices, faces)
	testing.expect_value(t, r.flattened, 1)
	testing.expect_value(t, r.flips, 0)
	s := stretch(u, positions, indices)
	testing.expectf(t, abs(s.l2 - 1) < 1e-4 && s.worst < 1 + 1e-3, "stretch %v", s)
	// The two sides of the cut at the first vertex lie the polygon's perimeter apart.
	ends := make([dynamic][2]f32, context.temp_allocator)
	for c, tri in u.corner do for k in 0 ..< 3 do if indices[3 * tri + k] == 0 && !slice.contains(ends[:], c[k]) do append(&ends, c[k])
	perimeter := f32(24 * 2 * math.sin(math.PI / 24))
	if testing.expect_value(t, len(ends), 2) {
		d := linalg.length(ends[1] - ends[0])
		testing.expectf(t, abs(d - perimeter) < 1e-3 * perimeter, "the cut's sides %v apart, perimeter %v", d, perimeter)
	}
}

// A dome flattens with no flips and a little stretch; held pins stay where they were,
// and the island is not scaled.
@(test)
lscm_dome_and_pins :: proc(t: ^testing.T) {
	positions, indices, faces, u := dome(8, 6)
	r := flatten(&u, positions, indices, faces)
	testing.expect_value(t, r.flips, 0)
	s := stretch(u, positions, indices)
	testing.expectf(t, s.l2 < 1.05 && s.worst < 1.2, "stretch %v", s)

	// Pin two corners of the grid at new places.
	u.pins = []u32{0, 8}
	for &c, tri in u.corner do for k in 0 ..< 3 {
		switch indices[3 * tri + k] {
		case 0: c[k] = {0.1, 0.2}
		case 8: c[k] = {0.9, 0.2}
		}
	}
	r = flatten(&u, positions, indices, faces)
	testing.expect_value(t, r.flattened, 1)
	for c, tri in u.corner do for k in 0 ..< 3 {
		switch indices[3 * tri + k] {
		case 0: testing.expect_value(t, c[k], [2]f32{0.1, 0.2})
		case 8: testing.expect_value(t, c[k], [2]f32{0.9, 0.2})
		}
	}
	// One pin holds the solve too, with the island scaled to its area after.
	u.pins = []u32{4}
	r = flatten(&u, positions, indices, faces)
	testing.expect_value(t, r.flattened, 1)
	testing.expect_value(t, r.flips, 0)
	testing.expect_value(t, check(u, indices, faces, len(positions)), "")
}

// A closed island and a damaged one are left as they were and counted.
@(test)
flatten_leaves_closed_and_broken_islands :: proc(t: ^testing.T) {
	m := geom.icosphere(1, allocator = context.temp_allocator)
	faces := geom.vertex_faces_build(m, nil, context.temp_allocator)
	u := make_uvs(len(m.indices) / 3, context.temp_allocator)
	for &c in u.corner do c = {{0.5, 0.5}, {0.5, 0.5}, {0.5, 0.5}}
	r := flatten(&u, m.positions[:], m.indices[:], faces)
	testing.expect_value(t, r.closed, 1)
	for c in u.corner do testing.expect(t, c == {{0.5, 0.5}, {0.5, 0.5}, {0.5, 0.5}})

	positions, indices, gfaces, g := test_grid(3, same)
	positions[5] = {math.nan_f32(), 0, 0}
	before := slice.clone(g.corner, context.temp_allocator)
	r = flatten(&g, positions, indices, gfaces)
	testing.expect_value(t, r.failed, 1)
	testing.expect(t, slice.equal(before, g.corner), "a failed island keeps its UVs")
}

// Many islands solved on pools of one, two and four threads come out bit for bit the same.
@(test)
flatten_does_not_depend_on_the_pool :: proc(t: ^testing.T) {
	positions, indices, faces, base := dome(12, 7)
	// Seams along every third line of the grid cut it into islands.
	for i in 0 ..= 12 do for j in 0 ..< 12 do if i % 3 == 0 && i > 0 && i < 12 {
		cut(&base, indices, u32(j * 13 + i), u32((j + 1) * 13 + i))
		cut(&base, indices, u32(i * 13 + j), u32(i * 13 + j + 1))
	}
	islands_find(&base, indices, faces)
	testing.expect(t, base.islands > 4)
	results: [3][][3][2]f32
	for workers, i in ([3]int{0, 1, 3}) {
		pool: jobs.Pool
		jobs.pool_init(&pool, workers)
		defer jobs.pool_destroy(&pool)
		u := clone(base, context.temp_allocator)
		r := flatten(&u, positions, indices, faces, pool = &pool)
		testing.expect_value(t, r.flattened, base.islands)
		results[i] = u.corner
	}
	testing.expect(t, slice.equal(results[0], results[1]) && slice.equal(results[0], results[2]), "the same on every pool")
}

// The direct solvers solve a grid's Laplacian plus the identity to rounding, in the
// order nested dissection gives, which is a permutation, and agree with each other.
@(test)
ldl_solves_a_laplacian :: proc(t: ^testing.T) {
	positions, indices, _, _ := test_grid(20, same)
	n := len(positions)
	// The grid's edges as a graph.
	edges := make([dynamic][2]u32, context.temp_allocator)
	for tri in 0 ..< len(indices) / 3 do for k in 0 ..< 3 {
		a, b := indices[3 * tri + k], indices[3 * tri + (k + 1) % 3]
		append(&edges, [2]u32{a, b}, [2]u32{b, a})
	}
	slice.sort_by(edges[:], proc(p, q: [2]u32) -> bool {return p[0] < q[0] || (p[0] == q[0] && p[1] < q[1])})
	uniq := make([dynamic][2]u32, context.temp_allocator)
	for e in edges do if len(uniq) == 0 || e != uniq[len(uniq) - 1] do append(&uniq, e)
	next := make([]u32, n + 1, context.temp_allocator)
	neighbour := make([]u32, len(uniq), context.temp_allocator)
	for e, i in uniq {
		next[e[0] + 1] += 1
		neighbour[i] = e[1]
	}
	for i in 0 ..< n do next[i + 1] += next[i]
	order, tree := dissection_order(positions, next, neighbour, context.temp_allocator)
	sorted := slice.clone(order, context.temp_allocator)
	slice.sort(sorted)
	for v, i in sorted do testing.expect_value(t, v, u32(i))
	rank := make([]u32, n, context.temp_allocator)
	for v, i in order do rank[v] = u32(i)
	// L + I in the dissection order, upper triangle by columns.
	a: Sparse
	a.n = n
	a.first = make([]u32, n + 1, context.temp_allocator)
	rows := make([dynamic]u32, context.temp_allocator)
	values := make([dynamic]f64, context.temp_allocator)
	for k in 0 ..< n {
		v := order[k]
		col := make([dynamic]u32, context.temp_allocator)
		for w in neighbour[next[v]:next[v + 1]] do if rank[w] < u32(k) do append(&col, rank[w])
		slice.sort(col[:])
		for r in col {
			append(&rows, r)
			append(&values, -1)
		}
		append(&rows, u32(k))
		append(&values, f64(next[v + 1] - next[v]) + 1)
		a.first[k + 1] = u32(len(rows))
	}
	a.row, a.value = rows[:], values[:]
	f, ok := ldl_factor(a, context.temp_allocator)
	if !testing.expect(t, ok) do return
	b := make([]f64, n, context.temp_allocator)
	for &x in b do x = rand.float64()
	x := slice.clone(b, context.temp_allocator)
	ldl_solve(f, x)
	// The residual, from the full symmetric matrix.
	worst: f64
	for k in 0 ..< n {
		v := order[k]
		ax := (f64(next[v + 1] - next[v]) + 1) * x[k]
		for w in neighbour[next[v]:next[v + 1]] do ax -= x[rank[w]]
		worst = max(worst, abs(ax - b[k]))
	}
	testing.expectf(t, worst < 1e-12, "residual %v", worst)

	// The frontal factor gives the same answer, on one thread and on a pool.
	for workers in ([]int{-1, 3}) {
		pool: jobs.Pool
		if workers >= 0 do jobs.pool_init(&pool, workers)
		defer if workers >= 0 do jobs.pool_destroy(&pool)
		// Parts factored side by side allocate from their threads, so not from temp.
		fronts, factored := front_factor(a, tree, &pool if workers >= 0 else nil, runtime.heap_allocator())
		if !testing.expect(t, factored) do continue
		defer fronts_destroy(&fronts, runtime.heap_allocator())
		y := slice.clone(b, context.temp_allocator)
		front_solve(fronts, y)
		gap: f64
		for v, i in y do gap = max(gap, abs(v - x[i]))
		testing.expectf(t, gap < 1e-10, "frontal and LDL differ by %v", gap)
	}
}
