package quadmesh

import "base:runtime"
import "core:log"
import "core:math"
import "core:slice"
import "core:testing"
import "core:time"

import "../geom"
import "../jobs"

// The cover on its own: on smooth shapes, hard edges and features, a density and guides,
// held to what a cover must be (the cells the scaling asks, the singular vertices the
// surface's topology needs and no more than the field has, hardly a fold), serial against
// parallel, the landing's plan against fresh covers, and its time.

// An island's isotropic mesh and its field, at about `quads` quads.
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

// What a cover on a fixture must give: its singular vertices (a closed surface of genus 0
// needs at least 8 of a quarter turn each, a torus none, and the field's clean-up leaves no
// more than the counts the tests were set from), at most `flipped` triangles turned over,
// and its cells within `cells` of what the scaling asks (the integers rounded and the hard
// edges' lines move them a little either way).
@(private = "file")
Cover_Want :: struct {
	singular: [2]int,
	flipped:  int,
	cells:    [2]f64,
}

// The cover on the mesh, held to `want`. Returns its time.
@(private = "file")
cover_holds :: proc(t: ^testing.T, name: string, iso: Isotropic, field: Field, scaling: f64, want: Cover_Want, guides: [][3]f64 = nil, sharp := 90.0, pool: ^jobs.Pool = nil, loc := #caller_location) -> (ms: f64) {
	run := Stage_Run{threads = 4, pool = pool}
	reason: Reason
	checks: Checks
	t0 := time.tick_now()
	cover, err := odin_cover(iso, field, guides, scaling, sharp, &run, &reason, &checks)
	ms = time.duration_milliseconds(time.tick_since(t0))
	defer cover_destroy(&cover)
	if !testing.expectf(t, err == .None && len(cover.uvs) == len(iso.triangles), "%s: the cover failed: %v %s", name, err, reason_string(&reason), loc = loc) do return
	cells, flipped := cells_of(cover)
	// What the scaling asks, as the driver measures it: a face whose quads are s times the
	// size covers 1 / s² as many cells.
	quad_edge := scaling * iso.mean_edge
	asked := f64(0)
	scaled := len(iso.vertex_scale) == len(iso.positions)
	for tri in iso.triangles {
		s := (iso.vertex_scale[tri[0]] + iso.vertex_scale[tri[1]] + iso.vertex_scale[tri[2]]) / 3 if scaled else 1
		asked += triangle_area(iso.positions[tri[0]], iso.positions[tri[1]], iso.positions[tri[2]]) / (s * s)
	}
	asked /= quad_edge * quad_edge
	ratio := cells / asked
	log.infof("%s: %d triangles, %d seam edges, %d unknowns, %d integers; %.1f cells for %.1f asked (%.3f), %d flipped, %d singular, %.1f ms",
		name, len(iso.triangles), checks.cover_seam, checks.cover_unknowns, checks.cover_integers, cells, asked, ratio, flipped, len(cover.singular), ms)
	testing.expectf(t, checks.cover_unknowns > 0 && checks.cover_seam > 0, "%s: the checks name no unknowns or seam: %d, %d", name, checks.cover_unknowns, checks.cover_seam, loc = loc)
	testing.expectf(t, len(cover.singular) >= want.singular[0] && len(cover.singular) <= want.singular[1], "%s: %d singular vertices, not %d to %d", name, len(cover.singular), want.singular[0], want.singular[1], loc = loc)
	testing.expectf(t, flipped <= want.flipped, "%s: %d triangles turned over, at most %d expected", name, flipped, want.flipped, loc = loc)
	testing.expectf(t, ratio >= want.cells[0] && ratio <= want.cells[1], "%s: %.1f cells for %.1f asked, %.3f times, not %.2f to %.2f", name, cells, asked, ratio, want.cells[0], want.cells[1], loc = loc)
	return
}

@(test)
cover_holds_on_smooth_shapes :: proc(t: ^testing.T) {
	source := geom.icosphere(4)
	defer geom.mesh_destroy(&source)
	sphere := island_of(source.positions[:], source.indices[:])
	defer island_destroy(&sphere)
	iso, field, scaling, ok := iso_and_field(sphere, 1500, 90)
	defer isotropic_destroy(&iso)
	defer field_destroy(&field)
	if !testing.expect(t, ok) do return
	_ = cover_holds(t, "sphere", iso, field, scaling, {{8, 12}, 2, {0.85, 1.05}})
	_ = cover_holds(t, "sphere, coarser", iso, field, 1.6 * scaling, {{8, 12}, 4, {0.85, 1.05}})

	torus := torus_island(96, 48, 1, 0.4)
	defer island_destroy(&torus)
	iso_t, field_t, scaling_t, ok_t := iso_and_field(torus, 1500, 90)
	defer isotropic_destroy(&iso_t)
	defer field_destroy(&field_t)
	if !testing.expect(t, ok_t) do return
	_ = cover_holds(t, "torus", iso_t, field_t, scaling_t, {{0, 0}, 0, {0.85, 1.05}})
}

// A hard-edged cube holds its edges along the grid, and a ring of features too.
@(test)
cover_holds_with_hard_edges_and_features :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	cube := cube_island(30)
	defer island_destroy(&cube)
	iso, field, scaling, ok := iso_and_field(cube, 600, 60)
	defer isotropic_destroy(&iso)
	defer field_destroy(&field)
	if !testing.expect(t, ok) do return
	_ = cover_holds(t, "cube", iso, field, scaling, {{8, 8}, 0, {0.8, 1.05}}, sharp = 60)

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
	_ = cover_holds(t, "cube with a ring", iso_r, field_r, scaling_r, {{8, 8}, 0, {0.8, 1.05}}, sharp = 60)
}

// A density sizes the quads; a guide holds its faces' turn.
@(test)
cover_holds_with_density_and_guides :: proc(t: ^testing.T) {
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
	_ = cover_holds(t, "density 4 above", iso, field, scaling, {{8, 56}, 8, {0.85, 1.05}})
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
	_ = cover_holds(t, "guide round the equator", iso_g, field_g, scaling_g, {{8, 8}, 0, {0.85, 1.05}}, guides)
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

// A sphere of about 160,000 triangles at the bench's 20,000 quads, on four threads: the
// cover's time, which the log carries.
@(test)
cover_on_a_dense_sphere :: proc(t: ^testing.T) {
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
	_ = cover_holds(t, "dense sphere", iso, field, scaling, {{8, 48}, 6, {0.9, 1.05}}, pool = &pool)
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
