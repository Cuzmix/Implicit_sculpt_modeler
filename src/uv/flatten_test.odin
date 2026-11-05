package uv

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
