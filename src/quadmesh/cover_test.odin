package quadmesh

import "base:runtime"
import "core:log"
import "core:math"
import "core:slice"
import "core:testing"
import "core:time"

import "../geom"
import "../jobs"

// The Odin cover on its own: against the C++'s on the same isotropic mesh and the same
// field (the same corner UVs, so the same integers rounded, the same singular vertices,
// as many cells and folds), with features, a density and guides, serial against parallel,
// and its time.

// An island's isotropic mesh and its Odin field, at about `quads` quads.
@(private = "file")
iso_and_field :: proc(island: Island, quads: int, sharp: f64, guides: [][3]f64 = nil, pool: ^jobs.Pool = nil) -> (iso: Isotropic, field: Field, scaling: f64, ok: bool) {
	run := Stage_Run{threads = 4, pool = pool}
	reason: Reason
	checks: Checks
	err: Stage_Error
	iso, err = odin_isotropic(island, edge_for(island, quads), 0, sharp, &run, &reason, &checks)
	if err != .None do return
	field, err = odin_field(iso, guides, 0.5, 1, sharp, &run, &reason, &checks)
	if err != .None do return
	area := f64(0)
	for t in island.triangles do area += triangle_area(island.positions[t[0]], island.positions[t[1]], island.positions[t[2]])
	scaling = math.sqrt(area / f64(quads)) / iso.mean_edge
	return iso, field, scaling, true
}

// The cover's area in cells, signed, and its triangles turned over.
@(private = "file")
cells_of :: proc(c: Cover) -> (cells: f64, flipped: int) {
	for t in c.uvs {
		a := 0.5 * ((t[1][0] - t[0][0]) * (t[2][1] - t[0][1]) - (t[2][0] - t[0][0]) * (t[1][1] - t[0][1]))
		cells += a
		if a < 0 do flipped += 1
	}
	return
}

// Both covers on the mesh: the Odin one's corner UVs within `tolerance` of the C++'s, the
// same singular vertices. Returns the Odin cover's time.
@(private = "file")
cover_against_cpp :: proc(t: ^testing.T, name: string, iso: Isotropic, field: Field, scaling: f64, guides: [][3]f64 = nil, sharp := 90.0, tolerance := 1e-6, pool: ^jobs.Pool = nil, loc := #caller_location) -> (odin_ms: f64) {
	run := Stage_Run{threads = 4, pool = pool}
	reason: Reason
	checks: Checks
	t0 := time.tick_now()
	ours, err := odin_cover(iso, field, guides, scaling, sharp, &run, &reason, &checks)
	odin_ms = time.duration_milliseconds(time.tick_since(t0))
	defer cover_destroy(&ours)
	if !testing.expectf(t, err == .None && len(ours.uvs) == len(iso.triangles), "%s: the Odin cover failed: %v %s", name, err, reason_string(&reason), loc = loc) do return
	our_cells, our_flipped := cells_of(ours)
	testing.expectf(t, checks.cover_unknowns > 0 && checks.cover_seam > 0, "%s: the checks name no unknowns or seam: %d, %d", name, checks.cover_unknowns, checks.cover_seam, loc = loc)
	when AVAILABLE {
		t1 := time.tick_now()
		theirs, cpp_err := cpp_cover(iso, guides, field, scaling, 0.5, 1, sharp, &run, &reason)
		cpp_ms := time.duration_milliseconds(time.tick_since(t1))
		defer cover_destroy(&theirs)
		if !testing.expectf(t, cpp_err == .None && len(theirs.uvs) == len(iso.triangles), "%s: the C++ cover failed: %v %s", name, cpp_err, reason_string(&reason), loc = loc) do return
		their_cells, their_flipped := cells_of(theirs)
		worst := f64(0)
		apart := 0
		for tri, f in ours.uvs do for k in 0 ..< 3 do for j in 0 ..< 2 {
			d := abs(tri[k][j] - theirs.uvs[f][k][j])
			worst = max(worst, d)
			if d > tolerance do apart += 1
		}
		log.infof("%s: %d triangles, %d seam edges, %d unknowns, %d integers; Odin %.1f cells, %d flipped, %d singular, %.1f ms; C++ %.1f cells, %d flipped, %d singular, %.1f ms; UVs apart %.2g at most, %d coordinates beyond %.0g",
			name, len(iso.triangles), checks.cover_seam, checks.cover_unknowns, checks.cover_integers, our_cells, our_flipped, len(ours.singular), odin_ms, their_cells, their_flipped, len(theirs.singular), cpp_ms, worst, apart, tolerance)
		testing.expectf(t, slice.equal(ours.singular, theirs.singular), "%s: singular vertices differ: %d against %d", name, len(ours.singular), len(theirs.singular), loc = loc)
		testing.expectf(t, apart == 0, "%s: %d UV coordinates differ by more than %g (%.3g at most)", name, apart, tolerance, worst, loc = loc)
	} else {
		log.infof("%s: %d triangles; Odin %.1f cells, %d flipped, %d singular, %.1f ms", name, len(iso.triangles), our_cells, our_flipped, len(ours.singular), odin_ms)
	}
	return
}

@(test)
cover_matches_the_cpp_on_smooth_shapes :: proc(t: ^testing.T) {
	source := geom.icosphere(4)
	defer geom.mesh_destroy(&source)
	sphere := island_of(source.positions[:], source.indices[:])
	defer island_destroy(&sphere)
	iso, field, scaling, ok := iso_and_field(sphere, 1500, 90)
	defer isotropic_destroy(&iso)
	defer field_destroy(&field)
	if !testing.expect(t, ok) do return
	_ = cover_against_cpp(t, "sphere", iso, field, scaling)
	_ = cover_against_cpp(t, "sphere, coarser", iso, field, 1.6 * scaling)

	torus := torus_island(96, 48, 1, 0.4)
	defer island_destroy(&torus)
	iso_t, field_t, scaling_t, ok_t := iso_and_field(torus, 1500, 90)
	defer isotropic_destroy(&iso_t)
	defer field_destroy(&field_t)
	if !testing.expect(t, ok_t) do return
	_ = cover_against_cpp(t, "torus", iso_t, field_t, scaling_t)
}

// A hard-edged cube holds its edges along the grid, and a ring of features too.
@(test)
cover_matches_the_cpp_with_hard_edges_and_features :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	cube := cube_island(30)
	defer island_destroy(&cube)
	iso, field, scaling, ok := iso_and_field(cube, 600, 60)
	defer isotropic_destroy(&iso)
	defer field_destroy(&field)
	if !testing.expect(t, ok) do return
	_ = cover_against_cpp(t, "cube", iso, field, scaling, sharp = 60)

	ring := make([dynamic][2]u32, heap)
	for tri in cube.triangles do for k in 0 ..< 3 {
		a, b := tri[k], tri[(k + 1) % 3]
		if a < b && abs(cube.positions[a].y) < 1e-12 && abs(cube.positions[b].y) < 1e-12 do append(&ring, [2]u32{a, b})
	}
	cube.features = ring[:]
	iso_r, field_r, scaling_r, ok_r := iso_and_field(cube, 600, 60)
	defer isotropic_destroy(&iso_r)
	defer field_destroy(&field_r)
	if !testing.expect(t, ok_r && len(iso_r.corner_feature) > 0) do return
	_ = cover_against_cpp(t, "cube with a ring", iso_r, field_r, scaling_r, sharp = 60)
}

// A density sizes the quads; a guide holds its faces' turn.
@(test)
cover_matches_the_cpp_with_density_and_guides :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	source := geom.icosphere(5)
	defer geom.mesh_destroy(&source)
	sphere := island_of(source.positions[:], source.indices[:])
	defer island_destroy(&sphere)
	sphere.density = make([]f64, len(sphere.positions), heap)
	for p, v in sphere.positions do sphere.density[v] = 4 if p.z > 0 else 1
	iso, field, scaling, ok := iso_and_field(sphere, 2000, 90)
	defer isotropic_destroy(&iso)
	defer field_destroy(&field)
	if !testing.expect(t, ok) do return
	_ = cover_against_cpp(t, "density 4 above", iso, field, scaling)
	delete(sphere.density, heap)
	sphere.density = nil

	iso_g, field_plain, scaling_g, ok_g := iso_and_field(sphere, 2000, 90)
	defer isotropic_destroy(&iso_g)
	defer field_destroy(&field_plain)
	if !testing.expect(t, ok_g) do return
	guides := make([][3]f64, len(iso_g.triangles), heap)
	defer delete(guides, heap)
	for tri, f in iso_g.triangles {
		c := (iso_g.positions[tri[0]] + iso_g.positions[tri[1]] + iso_g.positions[tri[2]]) / 3
		if abs(c.z) < 0.15 do guides[f] = {-c.y, c.x, 0}
	}
	run := Stage_Run{threads = 4}
	reason: Reason
	checks: Checks
	field_g, err := odin_field(iso_g, guides, 0.5, 1, 90, &run, &reason, &checks)
	defer field_destroy(&field_g)
	if !testing.expect(t, err == .None) do return
	_ = cover_against_cpp(t, "guide round the equator", iso_g, field_g, scaling_g, guides)
}

// Any thread count gives the same cover, bit for bit.
@(test)
cover_is_the_same_on_any_thread_count :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	torus := torus_island(96, 48, 1, 0.4)
	defer island_destroy(&torus)
	iso, field, scaling, ok := iso_and_field(torus, 3000, 90)
	defer isotropic_destroy(&iso)
	defer field_destroy(&field)
	if !testing.expect(t, ok) do return
	reason: Reason
	checks: Checks
	serial := Stage_Run{threads = 1}
	a, err_a := odin_cover(iso, field, nil, scaling, 90, &serial, &reason, &checks)
	defer cover_destroy(&a)
	parallel := Stage_Run{threads = 4, pool = &pool}
	b, err_b := odin_cover(iso, field, nil, scaling, 90, &parallel, &reason, &checks)
	defer cover_destroy(&b)
	if !testing.expect(t, err_a == .None && err_b == .None) do return
	testing.expect(t, slice.equal(a.uvs, b.uvs) && slice.equal(a.singular, b.singular), "the cover differs between one thread and four")
}

// A sphere of about 160,000 triangles at the bench's 20,000 quads: the Odin cover against
// the C++'s time, on four threads.
@(test)
cover_speed_against_the_cpp :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	source := geom.geodesic_sphere(90, &pool)
	defer geom.mesh_destroy(&source)
	sphere := island_of(source.positions[:], source.indices[:])
	defer island_destroy(&sphere)
	iso, field, scaling, ok := iso_and_field(sphere, 20000, 90, nil, &pool)
	defer isotropic_destroy(&iso)
	defer field_destroy(&field)
	if !testing.expect(t, ok) do return
	_ = cover_against_cpp(t, "dense sphere", iso, field, scaling, pool = &pool)
}

// The landing's covers on one plan are each the cover made from scratch at its scaling,
// bit for bit, whatever the order they come in: a later one refills and refactors the
// solves the first one ordered and analyzed.
@(test)
cover_plan_serves_every_scaling :: proc(t: ^testing.T) {
	source := geom.icosphere(4)
	defer geom.mesh_destroy(&source)
	sphere := island_of(source.positions[:], source.indices[:])
	defer island_destroy(&sphere)
	iso, field, scaling, ok := iso_and_field(sphere, 1500, 90)
	defer isotropic_destroy(&iso)
	defer field_destroy(&field)
	if !testing.expect(t, ok) do return
	run := Stage_Run{threads = 1}
	reason: Reason
	checks: Checks
	plan, err := odin_cover_plan(iso, field, nil, 90, &run, &reason)
	defer cover_plan_destroy(&plan)
	if !testing.expect(t, err == .None) do return
	for k in ([?]f64{1, 1.4, 0.8, 1}) {
		a, err_a := odin_cover_at(&plan, k * scaling, &run, &reason, &checks)
		defer cover_destroy(&a)
		b, err_b := odin_cover(iso, field, nil, k * scaling, 90, &run, &reason, &checks)
		defer cover_destroy(&b)
		if !testing.expect(t, err_a == .None && err_b == .None) do return
		testing.expectf(t, slice.equal(a.uvs, b.uvs) && slice.equal(a.singular, b.singular), "at %.1f times the scaling the plan's cover differs from a fresh one", k)
	}
}
