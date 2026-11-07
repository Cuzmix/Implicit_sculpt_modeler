package voxel

import "core:math"
import "core:math/linalg"
import "core:testing"

import "../geom"
import "../jobs"

@(private = "file")
mirror_clay :: proc(centre: Vec3, pool: ^jobs.Pool = nil) -> (c: Clay) {
	clay_init(&c, 2.0 / 128, {}, pool)
	clay_fill_sphere(&c, centre, 0.5)
	return
}

@(private = "file")
mirror_hit :: proc(c: ^Clay, origin, dir: Vec3) -> f32 {
	hit, _, ok := clay_raycast(c, origin, dir)
	return linalg.dot(hit, dir) if ok else -100
}

@(test)
mirroring_makes_the_replaced_side_the_kept_sides_image :: proc(t: ^testing.T) {
	c := mirror_clay({0.3, 0, 0})
	defer clay_destroy(&c)
	voxel := c.volume.voxel
	testing.expect(t, clay_mirror(&c, 0, true), "the mirror changed nothing")
	// Two spheres now, at 0.3 and -0.3: the left one's far side is at -0.8.
	left := -mirror_hit(&c, {-5, 0, 0}, {1, 0, 0})
	testing.expectf(t, math.abs(left - 0.8) < voxel, "the left side is at -%v, it should be at -0.8", left)
	for x in ([?]f32{0.1, 0.25, 0.4, 0.55, 0.7}) {
		pos := mirror_hit(&c, {x, 0.05, 5}, {0, 0, -1})
		neg := mirror_hit(&c, {-x, 0.05, 5}, {0, 0, -1})
		testing.expectf(t, math.abs(pos - neg) < 0.5 * voxel, "at ±%v the tops are %v and %v", x, pos, neg)
	}
	m := clay_to_mesh(&c)
	defer geom.mesh_destroy(&m)
	check := geom.mesh_check(m)
	testing.expectf(t, check.closed && check.non_manifold_edges == 0 && !check.inverted, "%v", check)
	// Mirroring what is already symmetric moves nothing (the repair along the seam may
	// round a value differently, so the field need not be identical).
	_ = clay_mirror(&c, 0, false)
	for x in ([?]f32{-0.55, -0.25, 0.25, 0.55}) {
		again := mirror_hit(&c, {x, 0.05, 5}, {0, 0, -1})
		want := -math.sqrt(0.25 - (math.abs(x) - 0.3) * (math.abs(x) - 0.3) - 0.0025)
		testing.expectf(t, math.abs(again - want) < voxel, "at %v mirroring again moved the top to %v", x, -again)
	}
}

@(test)
mirroring_keeps_the_negative_side_on_any_axis :: proc(t: ^testing.T) {
	c := mirror_clay({0, 0, -0.3})
	defer clay_destroy(&c)
	testing.expect(t, clay_mirror(&c, 2, false), "the mirror changed nothing")
	top := -mirror_hit(&c, {0.1, 0, 5}, {0, 0, -1})
	bottom := -mirror_hit(&c, {0.1, 0, -5}, {0, 0, 1})
	testing.expectf(t, math.abs(top - bottom) < 0.5 * c.volume.voxel, "the top is at %v, the bottom at %v", top, bottom)
	// Nothing on the kept side: nothing to mirror.
	d := mirror_clay({0, 0, 0.6})
	defer clay_destroy(&d)
	testing.expect(t, !clay_mirror(&d, 2, false), "a clay with nothing kept changed")
}

@(test)
a_mirror_is_the_same_on_any_thread_count_and_undoes_bit_for_bit :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	clays := [2]Clay{mirror_clay({0.27, 0.1, 0}), mirror_clay({0.27, 0.1, 0}, &pool)}
	defer for &c in clays do clay_destroy(&c)
	before := clay_hash(&clays[0])
	for &c in clays do clay_mirror(&c, 0, true)
	testing.expect(t, clay_hash(&clays[0]) == clay_hash(&clays[1]), "the mirror differs between one thread and three")
	testing.expect(t, clay_hash(&clays[0]) != before, "the mirror changed nothing")
	testing.expect(t, clay_undo(&clays[0]) && clay_hash(&clays[0]) == before, "undo left the field changed")
}
