package geom

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../jobs"

// An icosphere without the triangles whose middle `cut` says to cut, and with the
// vertices no triangle is left on taken out, as the app's meshes have none.
@(private = "file")
holed_sphere :: proc(level: int, cut: proc(c: Vec3) -> bool) -> Mesh {
	m := icosphere(level)
	defer mesh_destroy(&m)
	keep := make([]bool, len(m.indices) / 3, context.temp_allocator)
	for &k, t in keep {
		c := (m.positions[m.indices[3 * t]] + m.positions[m.indices[3 * t + 1]] + m.positions[m.indices[3 * t + 2]]) / 3
		k = !cut(c)
	}
	out, from := compact_mesh(m.positions[:], m.indices[:], keep)
	repair_map_destroy(&from)
	return out
}

@(private = "file")
two_holes :: proc(c: Vec3) -> bool {return c.y > 0.9 || c.x > 0.85}

// Two holes close into a sound sphere again, its caps facing out, the volume nearly the
// sphere's, every new vertex coloured from a border vertex and every cap triangle named;
// leaving the largest open closes only the other; one thread and three agree.
@(test)
close_holes_makes_a_sound_sphere :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	m := holed_sphere(4, two_holes)
	defer mesh_destroy(&m)
	before := mesh_integrity(m, nil)
	testing.expect_value(t, before.holes, 2)
	testing.expect(t, !before.check.closed)
	whole := icosphere(4)
	defer mesh_destroy(&whole)
	sphere := mesh_check(whole).volume

	out, from, report, ok := mesh_close_holes(m, false, nil)
	defer mesh_destroy(&out)
	defer repair_map_destroy(&from)
	testing.expect(t, ok)
	testing.expect_value(t, report, Close_Report{closed = 2})
	r := mesh_check(out)
	testing.expectf(t, mesh_report_ok(r), "%v", r)
	// Flat caps would take about 0.13 off: the caps bow out with the border.
	testing.expectf(t, r.volume < sphere && r.volume > sphere - 0.1, "volume %v, the sphere's %v", r.volume, sphere)
	testing.expect_value(t, len(from.vertex_from), len(out.positions))
	for f, v in from.vertex_from {
		testing.expect(t, int(f) < len(m.positions))
		if v < len(m.positions) do testing.expect_value(t, int(f), v)
	}
	caps := [2]int{}
	for f in from.tri_from[len(m.indices) / 3:] {
		testing.expect(t, f == REPAIR_NEW || f == REPAIR_NEW + 1)
		caps[f - REPAIR_NEW] += 1
	}
	testing.expect(t, caps[0] > 0 && caps[1] > 0)
	// The caps' new vertices lie between the plane of their border and the sphere.
	for p in out.positions[len(m.positions):] do testing.expectf(t, linalg.length(p) < 1.0001, "a cap vertex at %v", p)

	parallel, _, _, _ := mesh_close_holes(m, false, &pool, context.temp_allocator)
	testing.expect(t, slice.equal(parallel.positions[:], out.positions[:]) && slice.equal(parallel.indices[:], out.indices[:]))

	open, open_from, open_report, open_ok := mesh_close_holes(m, true, nil)
	defer mesh_destroy(&open)
	defer repair_map_destroy(&open_from)
	testing.expect(t, open_ok)
	testing.expect_value(t, open_report, Close_Report{closed = 1, left_open = 1})
	testing.expect_value(t, mesh_integrity(open, nil).holes, 1)

	// A sound sphere has nothing to close.
	_, _, _, none := mesh_close_holes(whole, false, nil)
	testing.expect(t, !none)
	free_all(context.temp_allocator)
}

// A hole whose border bends (a corner cut off the sphere across three planes) closes
// with a cap that follows it, and one that folds over itself seen from any side is
// fanned from its middle and still closes.
@(test)
close_holes_follows_a_bent_border :: proc(t: ^testing.T) {
	m := holed_sphere(4, proc(c: Vec3) -> bool {return c.x > 0.3 && c.y > 0.3 && c.z > 0.3})
	defer mesh_destroy(&m)
	out, from, report, ok := mesh_close_holes(m, false, nil)
	defer mesh_destroy(&out)
	defer repair_map_destroy(&from)
	testing.expect(t, ok && report.closed == 1)
	r := mesh_check(out)
	testing.expectf(t, mesh_report_ok(r), "%v", r)

	// A band round the middle of the sphere taken out leaves two holes facing apart.
	band := holed_sphere(3, proc(c: Vec3) -> bool {return abs(c.y) < 0.3})
	defer mesh_destroy(&band)
	shut, shut_from, shut_report, shut_ok := mesh_close_holes(band, false, nil)
	defer mesh_destroy(&shut)
	defer repair_map_destroy(&shut_from)
	testing.expect(t, shut_ok && shut_report.closed == 2)
	testing.expect_value(t, mesh_integrity(shut, nil).pieces, 2)
	testing.expect(t, mesh_report_ok(mesh_check(shut)))
	free_all(context.temp_allocator)
}

// A sphere as a soup of triangles, each with its own corners, welds back into the
// sphere at distance 0; with each copy nudged a little, it takes a distance to weld,
// and a smaller one welds nothing.
@(test)
weld_points_joins_a_triangle_soup :: proc(t: ^testing.T) {
	m := icosphere(3)
	defer mesh_destroy(&m)
	soup: Mesh
	defer mesh_destroy(&soup)
	for i, k in m.indices {
		append(&soup.positions, m.positions[i])
		append(&soup.indices, u32(k))
	}
	resize(&soup.normals, len(soup.positions))
	out, from, report, ok := mesh_weld_points(soup, 0, nil)
	defer mesh_destroy(&out)
	defer repair_map_destroy(&from)
	testing.expect(t, ok)
	testing.expect_value(t, len(out.positions), len(m.positions))
	testing.expect_value(t, report.welded, len(soup.positions) - len(m.positions))
	testing.expect(t, mesh_report_ok(mesh_check(out)))
	for f, v in from.vertex_from do testing.expect_value(t, out.positions[v], soup.positions[f])

	for &p, v in soup.positions do p += Vec3{1, -1, 1} * (f32(v % 5) * 2e-6)
	// Copies nudged alike still meet, but not the rest.
	tight, _, _, tight_ok := mesh_weld_points(soup, 1e-6, nil, context.temp_allocator)
	testing.expect(t, tight_ok && len(tight.positions) > len(m.positions) && !mesh_check(tight).closed)
	loose, _, loose_report, loose_ok := mesh_weld_points(soup, 1e-4, nil, context.temp_allocator)
	testing.expect(t, loose_ok)
	testing.expect_value(t, len(loose.positions), len(m.positions))
	testing.expect(t, loose_report.welded > 0)
	testing.expect(t, mesh_report_ok(mesh_check(loose)))

	// Welding past a triangle's size drops what collapses.
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	coarse, _, coarse_report, coarse_ok := mesh_weld_points(m, 0.2, &pool, context.temp_allocator)
	testing.expect(t, coarse_ok && coarse_report.dropped_triangles > 0 && len(coarse.positions) < len(m.positions))
	serial, _, _, _ := mesh_weld_points(m, 0.2, nil, context.temp_allocator)
	testing.expect(t, slice.equal(serial.indices[:], coarse.indices[:]))
	free_all(context.temp_allocator)
}

// Fix mesh drops a repeated corner, a duplicate, a fin and an unused vertex, turns
// triangles that disagree with their neighbours back, and turns a sphere inside out the
// right way round; a sound mesh needs nothing.
@(test)
fix_mesh_mends_what_it_can :: proc(t: ^testing.T) {
	m := icosphere(3)
	defer mesh_destroy(&m)
	sound := mesh_check(m)
	_, _, _, nothing := mesh_fix(m, nil)
	testing.expect(t, !nothing)

	broken: Mesh
	defer mesh_destroy(&broken)
	append(&broken.positions, ..m.positions[:])
	append(&broken.positions, Vec3{5, 5, 5}) // unused
	resize(&broken.normals, len(broken.positions))
	append(&broken.indices, ..m.indices[:])
	turned := 0
	for t := 0; t < len(m.indices) / 3; t += 7 {
		broken.indices[3 * t + 1], broken.indices[3 * t + 2] = broken.indices[3 * t + 2], broken.indices[3 * t + 1]
		turned += 1
	}
	append(&broken.indices, 0, 0, 1) // a repeated corner
	append(&broken.indices, broken.indices[3], broken.indices[4], broken.indices[5]) // a duplicate
	a, b, x := m.indices[9], m.indices[10], m.indices[300]
	append(&broken.indices, a, b, x, a, x, b) // a fin, facing both ways
	before := mesh_integrity(broken, nil)
	testing.expect(t, !mesh_integrity_ok(before))
	testing.expect_value(t, before.unused_vertices, 1)
	testing.expect_value(t, before.duplicate_triangles, 3)

	out, from, report, ok := mesh_fix(broken, nil)
	defer mesh_destroy(&out)
	defer repair_map_destroy(&from)
	testing.expect(t, ok)
	testing.expect_value(t, report.dropped_triangles, 1)
	testing.expect_value(t, report.dropped_vertices, 1)
	testing.expect_value(t, report.flipped_triangles, turned)
	r := mesh_check(out)
	testing.expectf(t, mesh_report_ok(r), "%v", r)
	testing.expect(t, abs(r.volume - sound.volume) < 1e-9)
	testing.expect(t, mesh_integrity_ok(mesh_integrity(out, nil)))

	inside_out := icosphere(2)
	defer mesh_destroy(&inside_out)
	mesh_flip(&inside_out, nil)
	right, right_from, right_report, right_ok := mesh_fix(inside_out, nil)
	defer mesh_destroy(&right)
	defer repair_map_destroy(&right_from)
	testing.expect(t, right_ok)
	testing.expect_value(t, right_report.turned_shells, 1)
	testing.expect(t, mesh_report_ok(mesh_check(right)))
	free_all(context.temp_allocator)
}

// The check counts holes, pieces and duplicates.
@(test)
integrity_counts_holes_and_pieces :: proc(t: ^testing.T) {
	a := holed_sphere(3, two_holes)
	defer mesh_destroy(&a)
	b := icosphere(2)
	defer mesh_destroy(&b)
	for &p in b.positions do p.x += 3
	parts := [2]Mesh{a, b}
	both := mesh_join(parts[:])
	defer mesh_destroy(&both)
	r := mesh_integrity(both, nil)
	testing.expect_value(t, r.holes, 2)
	testing.expect_value(t, r.pieces, 2)
	testing.expect_value(t, r.duplicate_triangles, 0)
	testing.expect_value(t, r.unused_vertices, 0)
	testing.expect(t, r.check.boundary_edges > 0 && !mesh_integrity_ok(r))
	free_all(context.temp_allocator)
}

// A sphere open above its lower part, whose border has spikes (a triangle of its own past
// the border, with two border edges) closes into a sound sphere. Below the middle the
// spikes face down, away from the cap, so seen along the cap they are ears it would
// cover with a triangle over the same corners facing the other way; both go, with the
// spike's vertex.
@(test)
close_holes_takes_out_spikes :: proc(t: ^testing.T) {
	m := icosphere(5)
	defer mesh_destroy(&m)
	tcount := len(m.indices) / 3
	kept := make([]bool, tcount, context.temp_allocator)
	used := make([]bool, len(m.positions), context.temp_allocator)
	for &k, t in kept {
		c := (m.positions[m.indices[3 * t]] + m.positions[m.indices[3 * t + 1]] + m.positions[m.indices[3 * t + 2]]) / 3
		k = c.y <= -0.3
		if k do for c in 0 ..< 3 do used[m.indices[3 * t + c]] = true
	}
	// Each edge's triangles, to find a cut triangle that shares an edge with a kept one.
	across := make(map[u64]int, 3 * tcount, context.temp_allocator)
	for t in 0 ..< tcount do for c in 0 ..< 3 do across[u64(m.indices[3 * t + c]) << 32 | u64(m.indices[3 * t + (c + 1) % 3])] = t
	spikes := 0
	for t in 0 ..< tcount {
		if kept[t] do continue
		for c in 0 ..< 3 {
			a, b, apex := m.indices[3 * t + c], m.indices[3 * t + (c + 1) % 3], m.indices[3 * t + (c + 2) % 3]
			other, found := across[u64(b) << 32 | u64(a)]
			if !found || !kept[other] || used[apex] do continue
			kept[t], used[apex] = true, true
			spikes += 1
			break
		}
	}
	testing.expectf(t, spikes > 20, "%d spikes", spikes)
	holed, holed_from := compact_mesh(m.positions[:], m.indices[:], kept)
	defer mesh_destroy(&holed)
	defer repair_map_destroy(&holed_from)
	out, from, report, ok := mesh_close_holes(holed, false, nil)
	defer mesh_destroy(&out)
	defer repair_map_destroy(&from)
	testing.expect(t, ok && report.closed == 1)
	testing.expectf(t, report.spikes > 0, "%v", report)
	r := mesh_integrity(out, nil)
	testing.expectf(t, mesh_integrity_ok(r), "%v %v", report, r)
	testing.expect_value(t, len(from.tri_from), len(out.indices) / 3)
	free_all(context.temp_allocator)
}

// The check's counts are mesh_check's, on a sound sphere, one with holes, one with a
// turned triangle, a duplicate and a triangle of no area, and two spheres sharing nothing.
@(test)
integrity_counts_as_mesh_check :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	sphere := icosphere(3)
	defer mesh_destroy(&sphere)
	holed := holed_sphere(3, two_holes)
	defer mesh_destroy(&holed)
	broken: Mesh
	defer mesh_destroy(&broken)
	append(&broken.positions, ..sphere.positions[:])
	resize(&broken.normals, len(broken.positions))
	append(&broken.indices, ..sphere.indices[:])
	broken.indices[4], broken.indices[5] = broken.indices[5], broken.indices[4]
	append(&broken.indices, sphere.indices[30], sphere.indices[31], sphere.indices[32])
	append(&broken.indices, 0, 0, 1)
	for m in ([?]Mesh{sphere, holed, broken}) {
		want := mesh_check(m)
		got := mesh_integrity(m, &pool).check
		testing.expectf(t, abs(got.volume - want.volume) < 1e-9, "volume %v, want %v", got.volume, want.volume)
		got.volume = want.volume
		testing.expect_value(t, got, want)
	}
	free_all(context.temp_allocator)
}
