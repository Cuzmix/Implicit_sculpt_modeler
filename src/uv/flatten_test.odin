package uv

import "base:runtime"
import "core:math"
import "core:math/linalg"
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
	// The two sides of the cut at the first vertex lie the polygon's perimeter apart, in
	// the scale the packing gave the island (its UV area over its surface area).
	uv_area, surface: f64
	for c, tri in u.corner {
		e1, e2 := c[1] - c[0], c[2] - c[0]
		uv_area += abs(f64(e1.x * e2.y - e1.y * e2.x)) * 0.5
		p := positions[indices[3 * tri]]
		surface += f64(linalg.length(linalg.cross(positions[indices[3 * tri + 1]] - p, positions[indices[3 * tri + 2]] - p))) * 0.5
	}
	scale := f32(math.sqrt(uv_area / surface))
	ends := make([dynamic][2]f32, context.temp_allocator)
	for c, tri in u.corner do for k in 0 ..< 3 do if indices[3 * tri + k] == 0 && !slice.contains(ends[:], c[k]) do append(&ends, c[k])
	perimeter := f32(24 * 2 * math.sin(math.PI / 24)) * scale
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

// The packing puts every flattened island inside the unit square, no two boxes touching,
// and covers most of it with like islands.
@(test)
flatten_packs_islands_apart :: proc(t: ^testing.T) {
	positions, indices, faces, u := dome(12, 7)
	for i in 0 ..= 12 do for j in 0 ..< 12 do if i % 3 == 0 && i > 0 && i < 12 {
		cut(&u, indices, u32(j * 13 + i), u32((j + 1) * 13 + i))
		cut(&u, indices, u32(i * 13 + j), u32(i * 13 + j + 1))
	}
	islands_find(&u, indices, faces)
	r := flatten(&u, positions, indices, faces)
	testing.expect_value(t, r.flattened, u.islands)
	lo := make([][2]f32, u.islands, context.temp_allocator)
	hi := make([][2]f32, u.islands, context.temp_allocator)
	for &l in lo do l = {2, 2}
	for &h in hi do h = {-1, -1}
	for c, tri in u.corner do for p in c {
		i := u.island[tri]
		lo[i], hi[i] = {min(lo[i].x, p.x), min(lo[i].y, p.y)}, {max(hi[i].x, p.x), max(hi[i].y, p.y)}
	}
	for i in 0 ..< u.islands {
		testing.expectf(t, lo[i].x >= 0 && lo[i].y >= 0 && hi[i].x <= 1 && hi[i].y <= 1, "island %d inside: %v %v", i, lo[i], hi[i])
		for j in i + 1 ..< u.islands {
			apart := hi[i].x < lo[j].x || hi[j].x < lo[i].x || hi[i].y < lo[j].y || hi[j].y < lo[i].y
			testing.expectf(t, apart, "islands %d and %d apart", i, j)
		}
	}
	testing.expectf(t, u.filled > 0.7, "filled %v", u.filled)
}

// ABF++ reaches its angles on a dome (no fallback): every triangle's angles sum to π and
// round each inner vertex to 2π, and the island keeps the surface's angles better than
// LSCM alone does, with no flips.
@(test)
abf_keeps_angles_better_than_lscm :: proc(t: ^testing.T) {
	positions, indices, faces, base := dome(16, 9)
	abf := clone(base, context.temp_allocator)
	r := flatten(&abf, positions, indices, faces, .Abf)
	testing.expect_value(t, r.flattened, 1)
	testing.expect_value(t, r.fallbacks, 0)
	testing.expect_value(t, r.flips, 0)
	lscm := clone(base, context.temp_allocator)
	_ = flatten(&lscm, positions, indices, faces, .Lscm)
	sa, sl := stretch(abf, positions, indices), stretch(lscm, positions, indices)
	testing.expectf(t, sa.angle < sl.angle, "angle error ABF++ %v, LSCM %v", sa.angle, sl.angle)

	order, first := island_triangles(base, context.temp_allocator)
	island := island_mesh(base, indices, faces, order[first[0]:first[1]], context.temp_allocator)
	angles, ok := abf_angles(positions, &island, nil)
	defer delete(angles, runtime.heap_allocator())
	if !testing.expect(t, ok) do return
	worst := 0.0
	for k in 0 ..< len(angles) / 3 do worst = max(worst, abs(angles[3 * k] + angles[3 * k + 1] + angles[3 * k + 2] - math.PI))
	around := make([]f64, island.wedges, context.temp_allocator)
	for a, c in angles do around[island.wedge[c]] += a
	for w in 0 ..< island.wedges do if !island.on_edge[w] do worst = max(worst, abs(around[w] - 2 * math.PI))
	testing.expectf(t, worst < 1e-6, "angle sums off by %v", worst)
}

// Relax leaves a map that keeps lengths as it is (energy 4, the least), lowers a dome's
// LSCM energy without a flip, pulls a stretched grid back towards its lengths, holds
// pins, skips a folded island and gives the same bits on any pool.
@(test)
relax_lowers_stretch_and_keeps_pins :: proc(t: ^testing.T) {
	// The flat grid with its own coordinates.
	{
		positions, indices, faces, u := test_grid(6, same)
		r := relax(&u, positions, indices, faces)
		testing.expect_value(t, r.relaxed, 1)
		testing.expectf(t, abs(r.before - 4) < 1e-9 && abs(r.after - 4) < 1e-9, "energy %v to %v", r.before, r.after)
	}
	// A dome flattened by LSCM.
	{
		positions, indices, faces, u := dome(12, 7)
		_ = flatten(&u, positions, indices, faces, .Lscm)
		r := relax(&u, positions, indices, faces)
		testing.expect_value(t, r.relaxed, 1)
		testing.expectf(t, r.after < r.before && r.after >= 4, "energy %v to %v", r.before, r.after)
		testing.expect_value(t, stretch(u, positions, indices).flips, 0)
	}
	// A grid whose coordinates are stretched twice as wide: relax takes most of it out.
	{
		positions, indices, faces, u := test_grid(6, proc(p: geom.Vec3) -> [2]f32 {return {p.x * 2, p.y}})
		r := relax(&u, positions, indices, faces, 30)
		testing.expectf(t, r.before > 4.4 && r.after < 4.01, "energy %v to %v", r.before, r.after)
		testing.expectf(t, stretch(u, positions, indices).l2 < 1.01, "stretch %v", stretch(u, positions, indices))
	}
	// Two pins hold still and keep the island where it is.
	{
		positions, indices, faces, u := dome(8, 6)
		_ = flatten(&u, positions, indices, faces, .Lscm)
		u.pins = []u32{0, 8}
		held: [2][2]f32
		for c, tri in u.corner do for k in 0 ..< 3 {
			if indices[3 * tri + k] == 0 do held[0] = c[k]
			if indices[3 * tri + k] == 8 do held[1] = c[k]
		}
		r := relax(&u, positions, indices, faces)
		testing.expect_value(t, r.relaxed, 1)
		for c, tri in u.corner do for k in 0 ..< 3 {
			if indices[3 * tri + k] == 0 do testing.expect_value(t, c[k], held[0])
			if indices[3 * tri + k] == 8 do testing.expect_value(t, c[k], held[1])
		}
	}
	// A folded triangle: skipped and left as it was.
	{
		positions, indices, faces, u := test_grid(4, same)
		for &c, tri in u.corner do for k in 0 ..< 3 do if indices[3 * tri + k] == 6 do c[k] = {3, 3}
		before := slice.clone(u.corner, context.temp_allocator)
		r := relax(&u, positions, indices, faces)
		testing.expect_value(t, r.skipped, 1)
		testing.expect(t, slice.equal(before, u.corner), "left as it was")
	}
	// The same on any pool, over many islands.
	{
		positions, indices, faces, base := dome(12, 7)
		for i in 0 ..= 12 do for j in 0 ..< 12 do if i % 3 == 0 && i > 0 && i < 12 {
			cut(&base, indices, u32(j * 13 + i), u32((j + 1) * 13 + i))
			cut(&base, indices, u32(i * 13 + j), u32(i * 13 + j + 1))
		}
		islands_find(&base, indices, faces)
		_ = flatten(&base, positions, indices, faces, .Lscm)
		results: [3][][3][2]f32
		for workers, i in ([3]int{0, 1, 3}) {
			pool: jobs.Pool
			jobs.pool_init(&pool, workers)
			defer jobs.pool_destroy(&pool)
			u := clone(base, context.temp_allocator)
			r := relax(&u, positions, indices, faces, pool = &pool)
			testing.expect_value(t, r.relaxed, base.islands)
			results[i] = u.corner
		}
		testing.expect(t, slice.equal(results[0], results[1]) && slice.equal(results[0], results[2]), "the same on every pool")
	}
}

// A tube welded round, mirror symmetric across y = 0 (each square's diagonal turned to
// match its mirror's), cut along x's line at angle 0 and, with `both`, at angle π too.
@(private)
mirror_tube :: proc(around, along: int, both: bool) -> (positions: []geom.Vec3, indices: []u32, faces: geom.Vertex_Faces, u: Uvs) {
	m: geom.Mesh
	m.positions = make([dynamic]geom.Vec3, context.temp_allocator)
	m.indices = make([dynamic]u32, context.temp_allocator)
	for y in 0 ..= along do for x in 0 ..< around {
		a := 2 * math.PI * f64(x) / f64(around)
		append(&m.positions, geom.Vec3{f32(math.cos(a)) * 3, f32(math.sin(a)) * 3, f32(y)})
	}
	for &p in m.positions do if abs(p.y) < 1e-6 do p.y = 0
	at :: proc(around, x, y: int) -> u32 {return u32(y * around + x % around)}
	for y in 0 ..< along do for x in 0 ..< around {
		if x < around / 2 {
			append(&m.indices, at(around, x, y), at(around, x + 1, y), at(around, x + 1, y + 1))
			append(&m.indices, at(around, x, y), at(around, x + 1, y + 1), at(around, x, y + 1))
		} else {
			append(&m.indices, at(around, x, y), at(around, x + 1, y), at(around, x, y + 1))
			append(&m.indices, at(around, x + 1, y), at(around, x + 1, y + 1), at(around, x, y + 1))
		}
	}
	positions, indices = m.positions[:], m.indices[:]
	faces = geom.vertex_faces_build(m, nil, context.temp_allocator)
	u = make_uvs(len(indices) / 3, context.temp_allocator)
	for y in 0 ..< along {
		cut(&u, indices, at(around, 0, y), at(around, 0, y + 1))
		if both do cut(&u, indices, at(around, around / 2, y), at(around, around / 2, y + 1))
	}
	islands_find(&u, indices, faces)
	return
}

// The worst difference between a UV edge and its mirror edge's length, over the mean
// edge, for the triangles that have mirrors.
@(private)
mirror_mismatch :: proc(u: Uvs, r: Mirror) -> (worst: f32, mirrored: int) {
	mean: f32 = 0
	for c in u.corner do mean += linalg.length(c[1] - c[0])
	mean /= f32(len(u.corner))
	for c, t in u.corner {
		o := r.tri[t]
		if o < 0 do continue
		mirrored += 1
		for k in 0 ..< 3 {
			a := linalg.length(c[(k + 1) % 3] - c[k])
			mc := u.corner[o]
			b := linalg.length(mc[r.at[t][(k + 1) % 3]] - mc[r.at[t][k]])
			worst = max(worst, abs(a - b) / mean)
		}
	}
	return
}

// Two mirrored halves: the second takes the first's layout reflected (same shapes, no
// flips); one island across the plane comes out symmetric; and a vertex moved off its
// mirror leaves its island to be laid out alone.
@(test)
symmetry_mirrors_islands :: proc(t: ^testing.T) {
	sym := DEFAULT_SYMMETRY
	sym.axis = 1
	{
		positions, indices, faces, u := mirror_tube(16, 4, true)
		testing.expect_value(t, u.islands, 2)
		order, first := island_triangles(u, context.temp_allocator)
		m := mirror_build(u, positions, indices, faces, sym, order, first)
		testing.expect(t, m.leader[1] == 0 && m.leader[0] == -1, "island 1 follows island 0")
		r := flatten(&u, positions, indices, faces, .Abf, symmetry = &sym)
		testing.expect_value(t, r.flattened, 2)
		testing.expect_value(t, r.flips, 0)
		testing.expect_value(t, stretch(u, positions, indices).flips, 0)
		worst, mirrored := mirror_mismatch(u, m)
		testing.expect_value(t, mirrored, len(indices) / 3)
		testing.expectf(t, worst < 1e-5, "mirror edges differ by %v", worst)
		_ = relax(&u, positions, indices, faces, symmetry = &sym)
		worst, _ = mirror_mismatch(u, m)
		testing.expectf(t, worst < 1e-5, "after relax, mirror edges differ by %v", worst)
	}
	{
		positions, indices, faces, u := mirror_tube(16, 4, false)
		testing.expect_value(t, u.islands, 1)
		order, first := island_triangles(u, context.temp_allocator)
		m := mirror_build(u, positions, indices, faces, sym, order, first)
		testing.expect(t, m.self[0], "the island is its own mirror")
		r := flatten(&u, positions, indices, faces, .Lscm, symmetry = &sym)
		testing.expect_value(t, r.flips, 0)
		worst, _ := mirror_mismatch(u, m)
		testing.expectf(t, worst < 1e-5, "mirror edges differ by %v", worst)
	}
	{
		positions, indices, faces, u := mirror_tube(16, 4, true)
		positions[3].z += 0.3
		order, first := island_triangles(u, context.temp_allocator)
		m := mirror_build(u, positions, indices, faces, sym, order, first)
		testing.expect(t, m.leader[1] == -1 && m.leader[0] == -1, "no island follows another")
	}
}
