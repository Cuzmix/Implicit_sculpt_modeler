package quadmesh

import "base:runtime"
import "core:log"
import "core:math"
import "core:slice"
import "core:testing"
import "core:time"

import "../geom"
import "../jobs"

// The frame field on its own, on smooth shapes, hard edges and features, a density and
// guides: held to what a field must be (the singular vertices the surface's topology needs
// and no more than the counts the tests were set from, at least as smooth, every size
// positive, a guide followed), serial against parallel, and its time.

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

// A field's singular vertices and smoothness as measured here, and its angles in the
// triangles' bases.
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

// What a field on a fixture must give: its singular vertices after the clean-up (a closed
// surface of genus 0 needs at least 8, a torus none) and as solved, and its smoothness at
// most (the mean 1 - cos 4(the frames' turn across an edge); a cube's frames turn only at
// its corners).
@(private = "file")
Field_Want :: struct {
	singular:   [2]int,
	solved:     int,
	smoothness: f64,
}

// The field on the mesh, held to `want`; with `guides`, the guided triangles' frames lie
// within GUIDE_DEGREES of their guide on average. Returns its time.
@(private = "file")
field_holds :: proc(t: ^testing.T, name: string, iso: Isotropic, want: Field_Want, guides: [][3]f64 = nil, adaptivity := 0.5, anisotropy := 1.0, sharp := 90.0, pool: ^jobs.Pool = nil, loc := #caller_location) -> (ms: f64) {
	heap := runtime.heap_allocator()
	run := Stage_Run{threads = 4, pool = pool}
	reason: Reason
	checks: Checks
	t0 := time.tick_now()
	field, err := odin_field(iso, guides, adaptivity, anisotropy, sharp, &run, &reason, &checks)
	ms = time.duration_milliseconds(time.tick_since(t0))
	defer field_destroy(&field)
	if !testing.expectf(t, err == .None && len(field.directions) == len(iso.triangles), "%s: the field failed: %v %s", name, err, reason_string(&reason), loc = loc) do return
	singular, smoothness, angles := measure(iso, field)
	defer delete(angles, heap)
	sizes_bad := 0
	for z in field.sizes do for k in 0 ..< 3 do if !(z[k] > 0) || !(z[k] < 1e6) do sizes_bad += 1
	// The guided triangles' frames against their guides, folded into a quarter turn.
	guided, apart := 0, f64(0)
	if guides != nil {
		s := surface_build(iso.positions, iso.triangles, nil)
		defer surface_destroy(&s)
		for g, f in guides {
			if g == {} do continue
			d := math.mod(angles[f] - tangent_angle(&s, g, f), math.PI / 2)
			if d > math.PI / 4 do d -= math.PI / 2
			if d < -math.PI / 4 do d += math.PI / 2
			apart += abs(d) * 180 / math.PI
			guided += 1
		}
		apart /= f64(max(guided, 1))
	}
	log.infof("%s: %d triangles; %d singular as solved, %d after, smoothness %.5f, %d guided %.2f degrees off on average, %.1f ms", name, len(iso.triangles), field.singular_solved, field.singular, smoothness, guided, apart, ms)
	testing.expectf(t, singular == field.singular, "%s: %d singular vertices measured, the field says %d", name, singular, field.singular, loc = loc)
	testing.expectf(t, field.singular >= want.singular[0] && field.singular <= want.singular[1], "%s: %d singular vertices, not %d to %d", name, field.singular, want.singular[0], want.singular[1], loc = loc)
	testing.expectf(t, field.singular_solved <= want.solved, "%s: %d singular vertices as solved, at most %d expected", name, field.singular_solved, want.solved, loc = loc)
	testing.expectf(t, smoothness <= want.smoothness, "%s: smoothness %.5f, at most %.5f expected", name, smoothness, want.smoothness, loc = loc)
	testing.expectf(t, sizes_bad == 0, "%s: %d sizes not positive and finite", name, sizes_bad, loc = loc)
	testing.expectf(t, guides == nil || (guided > 0 && apart <= GUIDE_DEGREES), "%s: the %d guided frames lie %.2f degrees off their guides on average", name, guided, apart, loc = loc)
	return
}

// How far, in degrees on average, a guided triangle's frame may lie off its guide: the
// guide pulls as hard as the curvature's strongest pull, and the smoothness pulls too.
@(private = "file")
GUIDE_DEGREES :: 2.0

@(test)
field_holds_on_smooth_shapes :: proc(t: ^testing.T) {
	source := geom.icosphere(4)
	defer geom.mesh_destroy(&source)
	sphere := island_of(source.positions[:], source.indices[:])
	defer island_destroy(&sphere)
	iso, ok := iso_of(sphere, 1500, 90)
	defer isotropic_destroy(&iso)
	if !testing.expect(t, ok) do return
	_ = field_holds(t, "sphere", iso, {{8, 12}, 14, 0.0215})
	_ = field_holds(t, "sphere, no adaptivity or anisotropy", iso, {{8, 12}, 14, 0.0215}, adaptivity = 0, anisotropy = 0)

	torus := torus_island(96, 48, 1, 0.4)
	defer island_destroy(&torus)
	iso_t, ok_t := iso_of(torus, 1500, 90)
	defer isotropic_destroy(&iso_t)
	if !testing.expect(t, ok_t) do return
	_ = field_holds(t, "torus", iso_t, {{0, 0}, 0, 0.0077})
}

// A hard-edged cube locks its frames to its edges, and a ring of features locks them too.
@(test)
field_holds_with_hard_edges_and_features :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	cube := cube_island(30)
	defer island_destroy(&cube)
	iso, ok := iso_of(cube, 600, 60)
	defer isotropic_destroy(&iso)
	if !testing.expect(t, ok) do return
	_ = field_holds(t, "cube", iso, {{8, 8}, 8, 1e-6}, sharp = 60)

	ring := make([dynamic][2]u32, heap)
	for tri in cube.triangles do for k in 0 ..< 3 {
		a, b := tri[k], tri[(k + 1) % 3]
		if a < b && abs(cube.positions[a].y) < 1e-12 && abs(cube.positions[b].y) < 1e-12 do append(&ring, [2]u32{a, b})
	}
	cube.features = ring[:]
	iso_r, ok_r := iso_of(cube, 600, 60)
	defer isotropic_destroy(&iso_r)
	if !testing.expect(t, ok_r && len(iso_r.corner_feature) > 0) do return
	_ = field_holds(t, "cube with a ring", iso_r, {{8, 8}, 8, 1e-6}, sharp = 60)
}

// A density scales the metric (and leaves the singular vertices as solved); guides pull.
@(test)
field_holds_with_density_and_guides :: proc(t: ^testing.T) {
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
	_ = field_holds(t, "density 4 above", iso, {{8, 56}, 56, 0.0236})
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
	_ = field_holds(t, "guide round the equator", iso_g, {{8, 8}, 8, 0.0136}, guides)
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

// A sphere of about 160,000 triangles at the bench's 20,000 quads, on four threads: the
// field's time, which the log carries.
@(test)
field_on_a_dense_sphere :: proc(t: ^testing.T) {
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
	_ = field_holds(t, "dense sphere", iso, {{8, 48}, 68, 0.0106}, pool = &pool)
}
