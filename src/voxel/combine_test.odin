package voxel

import "core:math"
import "core:math/linalg"
import "core:testing"

import "../geom"
import "../jobs"

// A unit sphere at `centre` in a clay `across` voxels over the unit sphere's width.
@(private = "file")
sphere_clay :: proc(across: f32, centre: Vec3, pool: ^jobs.Pool = nil) -> (c: Clay) {
	clay_init(&c, 2 / across, {}, pool)
	clay_fill_sphere(&c, centre, 1)
	return
}

// The volume of the clay's surface, and that it is closed and manifold.
@(private = "file")
checked_volume :: proc(t: ^testing.T, c: ^Clay, what: string) -> f64 {
	m := clay_to_mesh(c)
	defer geom.mesh_destroy(&m)
	r := geom.mesh_check(m)
	testing.expectf(t, r.closed && !r.inverted && r.non_manifold_edges == 0 && r.boundary_edges == 0 && r.degenerate_triangles == 0 && r.nan_count == 0, "%s: %v", what, r)
	return r.volume
}

// A point of this clay's space into the other's, the other's sphere sitting at `offset`.
@(private = "file")
shift :: proc(offset: Vec3) -> matrix[4, 4]f32 {
	return matrix[4, 4]f32{
		1, 0, 0, -offset.x,
		0, 1, 0, -offset.y,
		0, 0, 1, -offset.z,
		0, 0, 0, 1,
	}
}

// A union of two unit spheres 1.2 apart holds more than one sphere and less than two; a
// subtract leaves less than the one; both stay closed and manifold.
@(test)
a_union_and_a_subtract_of_two_spheres_hold_the_right_volume :: proc(t: ^testing.T) {
	sphere := 4.0 / 3.0 * math.PI
	a := sphere_clay(96, {})
	defer clay_destroy(&a)
	other := sphere_clay(96, {})
	defer clay_destroy(&other)
	testing.expect(t, clay_combine(&a, &other.volume, shift({1.2, 0, 0}), 1, .Union))
	union_v := checked_volume(t, &a, "union")
	testing.expectf(t, union_v > 1.3 * sphere && union_v < 2 * sphere, "union volume %.3f of a sphere's %.3f", union_v, sphere)
	// The seam is where the two surfaces met: a vertex there is on one sphere or the other.
	m := clay_to_mesh(&a)
	defer geom.mesh_destroy(&m)
	worst: f32
	for p in m.positions do worst = max(worst, min(abs(linalg.length(p) - 1), abs(linalg.length(p - {1.2, 0, 0}) - 1)))
	testing.expectf(t, worst < 1.5 * a.volume.voxel, "a union vertex %.4f off both spheres, a voxel is %.4f", worst, a.volume.voxel)

	b := sphere_clay(96, {})
	defer clay_destroy(&b)
	testing.expect(t, clay_combine(&b, &other.volume, shift({1.2, 0, 0}), 1, .Subtract))
	cut_v := checked_volume(t, &b, "subtract")
	testing.expectf(t, cut_v > 0.4 * sphere && cut_v < 0.9 * sphere, "subtract volume %.3f of a sphere's %.3f", cut_v, sphere)
	// Nothing in the subtract lies inside the other sphere.
	n := clay_to_mesh(&b)
	defer geom.mesh_destroy(&n)
	deepest: f32
	for p in n.positions do deepest = max(deepest, 1 - linalg.length(p - {1.2, 0, 0}))
	testing.expectf(t, deepest < 1.5 * b.volume.voxel, "a subtract vertex %.4f inside the cutter", deepest)
}

// An intersect keeps the lens the spheres share, with every brick outside it gone; two
// spheres apart intersect to nothing, which empties the clay and says so.
@(test)
an_intersect_keeps_the_lens_and_empties_on_disjoint_shapes :: proc(t: ^testing.T) {
	sphere := 4.0 / 3.0 * math.PI
	a := sphere_clay(96, {})
	defer clay_destroy(&a)
	other := sphere_clay(96, {})
	defer clay_destroy(&other)
	testing.expect(t, clay_combine(&a, &other.volume, shift({1.2, 0, 0}), 1, .Intersect))
	lens := checked_volume(t, &a, "intersect")
	// Two unit spheres d apart share a lens of π (4 − 3d + d³ / 4) / 3 ... written out: π (2 − d)² (4 + d) / 12.
	d := 1.2
	expected := math.PI * (2 - d) * (2 - d) * (4 + d) / 12
	testing.expectf(t, abs(lens - expected) < 0.05 * sphere, "lens volume %.3f, expected %.3f", lens, expected)
	bounds := volume_bounds(&a.volume)
	// The box is of the bricks, a band and a brick past the lens itself.
	testing.expectf(t, bounds.lo.x > -0.2 && bounds.hi.x < 1.4 && bounds.hi.y < 1.2, "the lens's bricks reach %v", bounds)

	far := sphere_clay(96, {})
	defer clay_destroy(&far)
	testing.expect(t, !clay_combine(&far, &other.volume, shift({5, 0, 0}), 1, .Intersect), "disjoint spheres intersected to something")
	testing.expect_value(t, volume_brick_count(&far.volume), 0)
	testing.expect(t, !volume_has_clay(&far.volume))
}

// A blend rounds the seam: the blended union holds more than the sharp one and stays
// closed; the other's scale and turn come through its placing.
@(test)
a_blend_adds_a_fillet_and_the_other_is_placed_by_its_transform :: proc(t: ^testing.T) {
	a := sphere_clay(96, {})
	defer clay_destroy(&a)
	other := sphere_clay(96, {})
	defer clay_destroy(&other)
	testing.expect(t, clay_combine(&a, &other.volume, shift({1.2, 0, 0}), 1, .Union))
	sharp := checked_volume(t, &a, "sharp")
	b := sphere_clay(96, {})
	defer clay_destroy(&b)
	testing.expect(t, clay_combine(&b, &other.volume, shift({1.2, 0, 0}), 1, .Union, blend = 6))
	blended := checked_volume(t, &b, "blended")
	testing.expectf(t, blended > sharp * 1.003, "blended %.3f, sharp %.3f", blended, sharp)

	// The other at half size on top: a point p of this space is 2 (p − top) in the other's,
	// and one of the other's units is half of ours.
	top := Vec3{0, 0, 1.2}
	to_other := matrix[4, 4]f32{
		2, 0, 0, -2 * top.x,
		0, 2, 0, -2 * top.y,
		0, 0, 2, -2 * top.z,
		0, 0, 0, 1,
	}
	c := sphere_clay(96, {})
	defer clay_destroy(&c)
	testing.expect(t, clay_combine(&c, &other.volume, to_other, 0.5, .Union))
	_ = checked_volume(t, &c, "scaled")
	bounds := volume_bounds(&c.volume)
	// The box is of the bricks, so it reaches a band and a brick further than the surface.
	testing.expectf(t, bounds.hi.z > 1.7 && bounds.hi.z < 2 && bounds.hi.x < 1.3, "the small sphere reaches %v", bounds)
}

// The combine is the same bit for bit on one thread and three, and a copy of a clay is
// the clay.
@(test)
a_combine_is_the_same_on_one_thread_and_three :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	other := sphere_clay(96, {})
	defer clay_destroy(&other)
	serial := sphere_clay(96, {})
	defer clay_destroy(&serial)
	parallel: Clay
	clay_copy(&parallel, &serial)
	defer clay_destroy(&parallel)
	parallel.pool = &pool
	testing.expect_value(t, clay_hash(&parallel), clay_hash(&serial))
	testing.expect(t, clay_combine(&serial, &other.volume, shift({0.7, 0.3, 0}), 1, .Subtract, blend = 2))
	testing.expect(t, clay_combine(&parallel, &other.volume, shift({0.7, 0.3, 0}), 1, .Subtract, blend = 2))
	testing.expect_value(t, clay_hash(&parallel), clay_hash(&serial))
	_ = clay_flush(&serial)
	_ = clay_flush(&parallel)
	sv, st := surface_counts(&serial.surface)
	pv, pt := surface_counts(&parallel.surface)
	testing.expect(t, sv == pv && st == pt, "the surfaces differ")
}
