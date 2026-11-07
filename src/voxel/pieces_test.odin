package voxel

import "core:math"
import "core:testing"

import "../geom"
import "../jobs"

// A sphere of 0.5 with two balls of 0.1 off it: one well clear above, one three voxels
// off its side, so close that their bands meet.
@(private = "file")
floater_clay :: proc(pool: ^jobs.Pool = nil) -> (c: Clay) {
	clay_init(&c, 2.0 / 128, {}, pool)
	clay_fill_sphere(&c, {}, 0.5)
	clay_stroke_begin(&c)
	for p in ([?]Vec3{{0, 0, 0.8}, {0.65, 0, 0}}) do _ = clay_dab(&c, {kind = .Tube, radius = 0.1, strength = 1, normal = {0, 0, 1}, from = p}, p)
	_ = clay_stroke_end(&c)
	return
}

@(private = "file")
floater_hit :: proc(c: ^Clay, origin, dir: Vec3) -> f32 {
	hit, _, ok := clay_raycast(c, origin, dir)
	return hit.x * -dir.x + hit.y * -dir.y + hit.z * -dir.z if ok else -100
}

@(test)
removing_floaters_keeps_only_the_largest_piece :: proc(t: ^testing.T) {
	c := floater_clay()
	defer clay_destroy(&c)
	voxel := c.volume.voxel
	top := floater_hit(&c, {0, 0, 5}, {0, 0, -1})
	side := floater_hit(&c, {5, 0, 0}, {-1, 0, 0})
	testing.expectf(t, math.abs(top - 0.9) < voxel && math.abs(side - 0.75) < voxel, "the balls are not there: the top at %v, the side at %v", top, side)
	bricks := volume_brick_count(&c.volume)
	removed := clay_keep_largest(&c)
	testing.expectf(t, removed == 2, "%v pieces went, not 2", removed)
	top = floater_hit(&c, {0, 0, 5}, {0, 0, -1})
	side = floater_hit(&c, {5, 0, 0}, {-1, 0, 0})
	testing.expectf(t, math.abs(top - 0.5) < voxel && math.abs(side - 0.5) < voxel, "the sphere is not what is left: the top at %v, the side at %v", top, side)
	testing.expectf(t, volume_brick_count(&c.volume) < bricks, "the balls' bricks stayed: %v of %v", volume_brick_count(&c.volume), bricks)
	m := clay_to_mesh(&c)
	defer geom.mesh_destroy(&m)
	check := geom.mesh_check(m)
	testing.expectf(t, check.closed && check.non_manifold_edges == 0 && !check.inverted && check.bounds.hi.x < 0.5 + voxel && check.bounds.hi.z < 0.5 + voxel, "%v", check)
	// One piece: nothing to remove.
	testing.expect(t, clay_keep_largest(&c) == 0, "a single piece lost something")
}

@(test)
removing_floaters_is_the_same_on_any_thread_count_and_undoes_bit_for_bit :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	clays := [2]Clay{floater_clay(), floater_clay(&pool)}
	defer for &c in clays do clay_destroy(&c)
	before := clay_hash(&clays[0])
	for &c in clays do _ = clay_keep_largest(&c)
	testing.expect(t, clay_hash(&clays[0]) == clay_hash(&clays[1]), "removing floaters differs between one thread and three")
	testing.expect(t, clay_hash(&clays[0]) != before, "removing floaters changed nothing")
	testing.expect(t, clay_undo(&clays[0]) && clay_hash(&clays[0]) == before, "undo left the field changed")
}

@(test)
keeping_one_piece_leaves_that_piece_alone :: proc(t: ^testing.T) {
	c := floater_clay()
	defer clay_destroy(&c)
	testing.expect_value(t, clay_piece_count(&c), 3)
	// The two balls are the same size: the first in brick order ranks first, the same each run.
	testing.expect(t, clay_keep_piece(&c, 1), "the second piece was not kept")
	testing.expect_value(t, clay_piece_count(&c), 1)
	m := clay_to_mesh(&c)
	defer geom.mesh_destroy(&m)
	check := geom.mesh_check(m)
	size := check.bounds.hi - check.bounds.lo
	testing.expectf(t, check.closed && size.x < 0.25 && size.y < 0.25 && size.z < 0.25, "what is left is not one ball: %v", check)
	testing.expect(t, !clay_keep_piece(&c, 0), "a single piece changed")
	testing.expect(t, clay_undo(&c) && clay_piece_count(&c) == 3, "undo did not bring the pieces back")
}
