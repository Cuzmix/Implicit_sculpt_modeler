package quadmesh

import "base:runtime"
import "core:log"
import "core:math"
import "core:slice"
import "core:testing"
import "core:time"

import "../geom"
import "../jobs"

// The Odin frame field on its own: against the C++'s on the same isotropic mesh (as many
// singular vertices, about as smooth, the frames mostly the same way round, the same
// sizes), with features, a density and guides, serial against parallel, and its time.

// An island's isotropic mesh, by the Odin stage.
@(private = "file")
iso_of :: proc(island: Island, quads: int, sharp: f64, pool: ^jobs.Pool = nil) -> (iso: Isotropic, ok: bool) {
	run := Stage_Run{threads = 4, pool = pool}
	reason: Reason
	checks: Checks
	err: Stage_Error
	iso, err = odin_isotropic(island, edge_for(island, quads), 0, sharp, &run, &reason, &checks)
	return iso, err == .None
}

// A field's singular vertices and smoothness as measured here, whichever side solved it,
// and its angles in the Odin bases.
@(private = "file")
measure :: proc(iso: Isotropic, field: Field) -> (singular: int, smoothness: f64, angles: []f64) {
	s := surface_build(iso.positions, iso.triangles, nil)
	defer surface_destroy(&s)
	angles = make([]f64, len(iso.triangles), runtime.heap_allocator())
	for d, f in field.directions do angles[f] = tangent_angle(&s, d, f)
	singular, _ = singular_simplify(&s, angles, 90, nil, false)
	smoothness = field_smoothness(&s, angles)
	return
}

// Both fields on the mesh; the Odin one's singular vertices within `slack` of the C++'s
// (before and after the clean-up), its smoothness within 1 % of the C++'s or better, most
// frames the same way round, and the sizes the same. Returns the Odin field's times.
@(private = "file")
field_against_cpp :: proc(t: ^testing.T, name: string, iso: Isotropic, guides: [][3]f64 = nil, adaptivity := 0.5, anisotropy := 1.0, sharp := 90.0, slack := 0, pool: ^jobs.Pool = nil, loc := #caller_location) -> (odin_ms: f64) {
	heap := runtime.heap_allocator()
	run := Stage_Run{threads = 4, pool = pool}
	reason: Reason
	checks: Checks
	t0 := time.tick_now()
	ours, err := odin_field(iso, guides, adaptivity, anisotropy, sharp, &run, &reason, &checks)
	odin_ms = time.duration_milliseconds(time.tick_since(t0))
	defer field_destroy(&ours)
	if !testing.expectf(t, err == .None && len(ours.directions) == len(iso.triangles), "%s: the Odin field failed: %v %s", name, err, reason_string(&reason), loc = loc) do return
	our_singular, our_smooth, our_angles := measure(iso, ours)
	defer delete(our_angles, heap)
	testing.expectf(t, our_singular == ours.singular, "%s: %d singular vertices measured, the field says %d", name, our_singular, ours.singular, loc = loc)
	when AVAILABLE {
		t1 := time.tick_now()
		theirs, cpp_err := cpp_field(iso, guides, adaptivity, anisotropy, sharp, &run, &reason)
		cpp_ms := time.duration_milliseconds(time.tick_since(t1))
		defer field_destroy(&theirs)
		if !testing.expectf(t, cpp_err == .None && len(theirs.directions) == len(iso.triangles), "%s: the C++ field failed: %v %s", name, cpp_err, reason_string(&reason), loc = loc) do return
		their_singular, their_smooth, their_angles := measure(iso, theirs)
		defer delete(their_angles, heap)
		// The frames' difference, folded into a quarter turn either way.
		apart := make([]f64, len(our_angles), heap)
		defer delete(apart, heap)
		mean := f64(0)
		for &a, f in apart {
			d := math.mod(our_angles[f] - their_angles[f], math.PI / 2)
			if d > math.PI / 4 do d -= math.PI / 2
			if d < -math.PI / 4 do d += math.PI / 2
			a = abs(d) * 180 / math.PI
			mean += a
		}
		mean /= f64(max(len(apart), 1))
		slice.sort(apart)
		p95 := apart[len(apart) * 95 / 100] if len(apart) > 0 else 0
		worst_size := f64(0)
		for z, f in ours.sizes do for k in 0 ..< 3 do worst_size = max(worst_size, abs(z[k] - theirs.sizes[f][k]) / max(abs(theirs.sizes[f][k]), 1e-12))
		log.infof("%s: %d triangles; Odin %d singular as solved, %d after, smoothness %.5f, %.1f ms; C++ %d, %d (%d measured), %.5f, %.1f ms; frames apart %.2f degrees on average, %.2f at the 95th percentile; sizes apart %.2g at most",
			name, len(iso.triangles), ours.singular_solved, ours.singular, our_smooth, odin_ms, theirs.singular_solved, theirs.singular, their_singular, their_smooth, cpp_ms, mean, p95, worst_size)
		testing.expectf(t, abs(ours.singular_solved - theirs.singular_solved) <= slack, "%s: %d singular vertices as solved, the C++ %d", name, ours.singular_solved, theirs.singular_solved, loc = loc)
		testing.expectf(t, ours.singular <= theirs.singular + slack, "%s: %d singular vertices after the clean-up, the C++ %d", name, ours.singular, theirs.singular, loc = loc)
		testing.expectf(t, our_smooth <= their_smooth * 1.01 + 1e-9, "%s: smoothness %.5f, the C++'s %.5f", name, our_smooth, their_smooth, loc = loc)
		testing.expectf(t, worst_size < 1e-6, "%s: the sizes differ by %.2g", name, worst_size, loc = loc)
	} else {
		log.infof("%s: %d triangles; Odin %d singular, smoothness %.5f, %.1f ms", name, len(iso.triangles), ours.singular, our_smooth, odin_ms)
	}
	return
}

@(test)
field_matches_the_cpp_on_smooth_shapes :: proc(t: ^testing.T) {
	source := geom.icosphere(4)
	defer geom.mesh_destroy(&source)
	sphere := island_of(source.positions[:], source.indices[:])
	defer island_destroy(&sphere)
	iso, ok := iso_of(sphere, 1500, 90)
	defer isotropic_destroy(&iso)
	if !testing.expect(t, ok) do return
	_ = field_against_cpp(t, "sphere", iso)
	_ = field_against_cpp(t, "sphere, no adaptivity or anisotropy", iso, adaptivity = 0, anisotropy = 0)

	torus := torus_island(96, 48, 1, 0.4)
	defer island_destroy(&torus)
	iso_t, ok_t := iso_of(torus, 1500, 90)
	defer isotropic_destroy(&iso_t)
	if !testing.expect(t, ok_t) do return
	_ = field_against_cpp(t, "torus", iso_t)
}

// A hard-edged cube locks its frames to its edges, and a ring of features locks them too.
@(test)
field_matches_the_cpp_with_hard_edges_and_features :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	cube := cube_island(30)
	defer island_destroy(&cube)
	iso, ok := iso_of(cube, 600, 60)
	defer isotropic_destroy(&iso)
	if !testing.expect(t, ok) do return
	_ = field_against_cpp(t, "cube", iso, sharp = 60)

	ring := make([dynamic][2]u32, heap)
	for tri in cube.triangles do for k in 0 ..< 3 {
		a, b := tri[k], tri[(k + 1) % 3]
		if a < b && abs(cube.positions[a].y) < 1e-12 && abs(cube.positions[b].y) < 1e-12 do append(&ring, [2]u32{a, b})
	}
	cube.features = ring[:]
	iso_r, ok_r := iso_of(cube, 600, 60)
	defer isotropic_destroy(&iso_r)
	if !testing.expect(t, ok_r && len(iso_r.corner_feature) > 0) do return
	_ = field_against_cpp(t, "cube with a ring", iso_r, sharp = 60)
}

// A density scales the metric (and leaves the singular vertices as solved); guides pull.
@(test)
field_matches_the_cpp_with_density_and_guides :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	source := geom.icosphere(5)
	defer geom.mesh_destroy(&source)
	sphere := island_of(source.positions[:], source.indices[:])
	defer island_destroy(&sphere)
	sphere.density = make([]f64, len(sphere.positions), heap)
	for p, v in sphere.positions do sphere.density[v] = 4 if p.z > 0 else 1
	iso, ok := iso_of(sphere, 2000, 90)
	defer isotropic_destroy(&iso)
	if !testing.expect(t, ok && len(iso.vertex_scale) == len(iso.positions)) do return
	_ = field_against_cpp(t, "density 4 above", iso)
	delete(sphere.density, heap)
	sphere.density = nil

	// A guide round the equator: the triangles near it pulled along it.
	iso_g, ok_g := iso_of(sphere, 2000, 90)
	defer isotropic_destroy(&iso_g)
	if !testing.expect(t, ok_g) do return
	guides := make([][3]f64, len(iso_g.triangles), heap)
	defer delete(guides, heap)
	for tri, f in iso_g.triangles {
		c := (iso_g.positions[tri[0]] + iso_g.positions[tri[1]] + iso_g.positions[tri[2]]) / 3
		if abs(c.z) < 0.15 do guides[f] = {-c.y, c.x, 0}
	}
	_ = field_against_cpp(t, "guide round the equator", iso_g, guides)
}

// Any thread count gives the same field, bit for bit.
@(test)
field_is_the_same_on_any_thread_count :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	torus := torus_island(96, 48, 1, 0.4)
	defer island_destroy(&torus)
	iso, ok := iso_of(torus, 3000, 90)
	defer isotropic_destroy(&iso)
	if !testing.expect(t, ok) do return
	reason: Reason
	checks: Checks
	serial := Stage_Run{threads = 1}
	a, err_a := odin_field(iso, nil, 0.5, 1, 90, &serial, &reason, &checks)
	defer field_destroy(&a)
	parallel := Stage_Run{threads = 4, pool = &pool}
	b, err_b := odin_field(iso, nil, 0.5, 1, 90, &parallel, &reason, &checks)
	defer field_destroy(&b)
	if !testing.expect(t, err_a == .None && err_b == .None) do return
	testing.expect(t, slice.equal(a.directions, b.directions) && slice.equal(a.sizes, b.sizes), "the field differs between one thread and four")
}

// A sphere of about 160,000 triangles at the bench's 20,000 quads: the Odin field against
// the C++'s time, on four threads.
@(test)
field_speed_against_the_cpp :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	source := geom.geodesic_sphere(90, &pool)
	defer geom.mesh_destroy(&source)
	sphere := island_of(source.positions[:], source.indices[:])
	defer island_destroy(&sphere)
	iso, ok := iso_of(sphere, 20000, 90, &pool)
	defer isotropic_destroy(&iso)
	if !testing.expect(t, ok) do return
	_ = field_against_cpp(t, "dense sphere", iso, pool = &pool)
}
