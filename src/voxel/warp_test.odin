package voxel

import "core:math"
import "core:math/linalg"
import "core:testing"

import "../geom"
import "../jobs"

@(private = "file")
grab_sphere :: proc(across: f32, pool: ^jobs.Pool = nil) -> (c: Clay) {
	clay_init(&c, 2 / across, {}, pool)
	clay_fill_sphere(&c, {}, 1)
	return
}

IDENTITY :: matrix[3, 3]f32{1, 0, 0, 0, 1, 0, 0, 0, 1}

@(private = "file")
top_of :: proc(c: ^Clay, x: f32 = 0) -> f32 {
	hit, _, ok := clay_raycast(c, {x, 0, 5}, {0, 0, -1})
	return hit.z if ok else -1
}

@(test)
grab_drags_the_clay_under_the_brush_and_leaves_the_rest :: proc(t: ^testing.T) {
	c := grab_sphere(128)
	defer clay_destroy(&c)
	voxel := c.volume.voxel
	clay_stroke_begin(&c)
	clay_grab_begin(&c, 0.4, {{0, 0, 1}}, {IDENTITY})
	testing.expect(t, clay_grab_move(&c, {0, 0, 0.1}) > 0, "a frame's drag wrote nothing")
	testing.expect(t, clay_grab_move(&c, {0, 0, 0.2}) > 0, "the next frame's drag wrote nothing")
	testing.expect(t, clay_stroke_end(&c), "the grab changed nothing")
	// The middle goes all the way with the pointer; past the brush nothing moves.
	testing.expectf(t, math.abs(top_of(&c) - 1.2) < 1.5 * voxel, "the top is at %v, the drag took it to 1.2", top_of(&c))
	side, _, ok := clay_raycast(&c, {5, 0, 0}, {-1, 0, 0})
	testing.expectf(t, ok && math.abs(side.x - 1) < 0.5 * voxel, "the side moved to %v", side)
	m := clay_to_mesh(&c)
	defer geom.mesh_destroy(&m)
	check := geom.mesh_check(m)
	testing.expectf(t, check.closed && check.non_manifold_edges == 0 && !check.inverted, "%v", check)
}

@(test)
a_grab_dragged_back_leaves_the_field_as_it_was :: proc(t: ^testing.T) {
	// Every frame reads the field as it was at the press, so going there and back blurs
	// nothing: the field is the press's again, bit for bit.
	c := grab_sphere(96)
	defer clay_destroy(&c)
	before := clay_hash(&c)
	clay_stroke_begin(&c)
	clay_grab_begin(&c, 0.5, {{0, 0, 1}}, {IDENTITY})
	for i in 1 ..= 6 do _ = clay_grab_move(&c, {0.05 * f32(i), 0.03 * f32(i), 0.08 * f32(i)})
	testing.expect(t, clay_hash(&c) != before, "the drag changed nothing")
	_ = clay_grab_move(&c, {})
	// The bricks made where the clay went hold their tile's value again, but the hash reads
	// bricks, so compare what the field reads at points with a fresh sphere's.
	ref := grab_sphere(96)
	defer clay_destroy(&ref)
	same := true
	for z in -12 ..= 12 do for x in -12 ..= 12 {
		p := Vec3{f32(x) * 0.05, 0.1, 1 + f32(z) * 0.02}
		if volume_sample(&c.volume, p) != volume_sample(&ref.volume, p) do same = false
	}
	testing.expect(t, same, "dragged back, the field differs from the sphere's")
	_ = clay_stroke_end(&c)
}

@(test)
a_long_grab_pulls_a_tendril_that_stays_closed :: proc(t: ^testing.T) {
	c := grab_sphere(128)
	defer clay_destroy(&c)
	voxel := c.volume.voxel
	clay_stroke_begin(&c)
	clay_grab_begin(&c, 0.3, {{0, 0, 1}}, {IDENTITY})
	for i in 1 ..= 10 do _ = clay_grab_move(&c, {0, 0, 0.08 * f32(i)})
	_ = clay_stroke_end(&c)
	testing.expectf(t, math.abs(top_of(&c) - 1.8) < 2 * voxel, "the tip is at %v, the drag took it to 1.8", top_of(&c))
	// Half way up the tendril there is clay, narrower than the brush.
	mid, _, ok := clay_raycast(&c, {5, 0, 1.4}, {-1, 0, 0})
	testing.expectf(t, ok && mid.x > 2 * voxel && mid.x < 0.3, "half way up the tendril's side is at %v", mid)
	m := clay_to_mesh(&c)
	defer geom.mesh_destroy(&m)
	check := geom.mesh_check(m)
	testing.expectf(t, check.closed && check.non_manifold_edges == 0 && !check.inverted, "%v", check)
}

@(test)
grab_with_mirror_images_moves_both_sides_alike_on_any_thread_count :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	clays := [2]Clay{grab_sphere(96), grab_sphere(96, &pool)}
	defer for &c in clays do clay_destroy(&c)
	mirror := matrix[3, 3]f32{-1, 0, 0, 0, 1, 0, 0, 0, 1}
	at := linalg.normalize(Vec3{0.5, 0, 0.8})
	for &c in clays {
		clay_stroke_begin(&c)
		clay_grab_begin(&c, 0.4, {at, mirror * at}, {IDENTITY, mirror})
		for i in 1 ..= 4 do _ = clay_grab_move(&c, {0.04 * f32(i), 0, 0.05 * f32(i)}, {0, 0, 1}, 0.2 * f32(i))
		_ = clay_stroke_end(&c)
	}
	testing.expect(t, clay_hash(&clays[0]) == clay_hash(&clays[1]), "the grab differs between one thread and three")
	// The mirror image moved the other side the mirrored way.
	right := top_of(&clays[0], 0.6)
	left := top_of(&clays[0], -0.6)
	testing.expectf(t, math.abs(right - left) < 0.5 * clays[0].volume.voxel, "the sides differ: %v and %v", right, left)
}

@(test)
undo_takes_a_grab_back_bit_for_bit :: proc(t: ^testing.T) {
	c := grab_sphere(96)
	defer clay_destroy(&c)
	before := clay_hash(&c)
	clay_stroke_begin(&c)
	clay_grab_begin(&c, 0.4, {{0, 0, 1}}, {IDENTITY})
	for i in 1 ..= 5 do _ = clay_grab_move(&c, {0.06 * f32(i), 0, 0.06 * f32(i)})
	testing.expect(t, clay_stroke_end(&c), "the grab changed nothing")
	after := clay_hash(&c)
	testing.expect(t, clay_undo(&c), "nothing to undo")
	testing.expect(t, clay_hash(&c) == before, "undo left the field changed")
	testing.expect(t, clay_redo(&c), "nothing to redo")
	testing.expect(t, clay_hash(&c) == after, "redo did not bring the grab back")
}

@(test)
masked_clay_holds_still_under_a_grab :: proc(t: ^testing.T) {
	c := grab_sphere(96)
	defer clay_destroy(&c)
	voxel := c.volume.voxel
	clay_mask_command(&c, .Fill)
	clay_stroke_begin(&c)
	clay_grab_begin(&c, 0.4, {{0, 0, 1}}, {IDENTITY})
	_ = clay_grab_move(&c, {0, 0, 0.2})
	_ = clay_stroke_end(&c)
	testing.expectf(t, math.abs(top_of(&c) - 1) < 0.5 * voxel, "the masked top moved to %v", top_of(&c))
}

@(test)
a_long_squeezing_pull_at_low_resolution_stays_closed :: proc(t: ^testing.T) {
	// A pull eight radii long across the sphere at 128 voxels squeezes the clay's sides
	// below a voxel, where values a hair from zero sit beside values far past it: the
	// surface still closes, with no triangle folded onto a point (mesh_node's inset).
	c := grab_sphere(128)
	defer clay_destroy(&c)
	_ = clay_flush(&c)
	clay_stroke_begin(&c)
	clay_grab_begin(&c, 0.129, {{0.0835, 0.303, 0.949}}, {IDENTITY})
	for i in 1 ..= 40 {
		_ = clay_grab_move(&c, Vec3{0.705, -0.059, -0.678} * (f32(i) / 40))
		_ = clay_flush(&c)
	}
	_ = clay_stroke_end(&c)
	m := clay_to_mesh(&c)
	defer geom.mesh_destroy(&m)
	check := geom.mesh_check(m)
	testing.expectf(t, check.closed && check.degenerate_triangles == 0, "%v", check)
}

@(test)
elastic_pulls_the_point_pressed_all_the_way_and_its_surround_part_way :: proc(t: ^testing.T) {
	c := grab_sphere(128)
	defer clay_destroy(&c)
	voxel := c.volume.voxel
	clay_stroke_begin(&c)
	clay_grab_begin(&c, 0.25, {{0, 0, 1}}, {IDENTITY}, elastic = true, volume = 0.8)
	for i in 1 ..= 4 do _ = clay_grab_move(&c, {0, 0, 0.05 * f32(i)})
	testing.expect(t, clay_stroke_end(&c), "the pull changed nothing")
	testing.expectf(t, math.abs(top_of(&c) - 1.2) < 1.5 * voxel, "the top is at %v, the pull took it to 1.2", top_of(&c))
	// Past where Grab's falloff ends the clay still rose, by about a tenth of the pull,
	// and past the Kelvinlet's reach it did not move.
	near := top_of(&c, 0.28)
	rest := math.sqrt(f32(1 - 0.28 * 0.28))
	testing.expectf(t, near > rest + voxel && near < rest + 0.1, "past the radius the top is at %v, it was %v", near, rest)
	side, _, ok := clay_raycast(&c, {5, 0, 0}, {-1, 0, 0})
	testing.expectf(t, ok && math.abs(side.x - 1) < 0.5 * voxel, "the side moved to %v", side)
	m := clay_to_mesh(&c)
	defer geom.mesh_destroy(&m)
	check := geom.mesh_check(m)
	testing.expectf(t, check.closed && check.non_manifold_edges == 0 && !check.inverted, "%v", check)
}

@(test)
elastic_with_more_volume_keeps_more_of_it :: proc(t: ^testing.T) {
	gained: [2]f64
	for volume, i in ([2]f32{0, 1}) {
		c := grab_sphere(96)
		defer clay_destroy(&c)
		before := clay_to_mesh(&c)
		defer geom.mesh_destroy(&before)
		clay_stroke_begin(&c)
		clay_grab_begin(&c, 0.3, {{0, 0, 1}}, {IDENTITY}, elastic = true, volume = volume)
		for s in 1 ..= 4 do _ = clay_grab_move(&c, {0, 0, 0.06 * f32(s)})
		_ = clay_stroke_end(&c)
		after := clay_to_mesh(&c)
		defer geom.mesh_destroy(&after)
		gained[i] = geom.mesh_signed_volume(after) - geom.mesh_signed_volume(before)
	}
	testing.expectf(t, gained[0] > 0 && gained[1] < gained[0], "a soft pull gained %v, a firm one %v", gained[0], gained[1])
}

@(test)
elastic_is_the_same_on_any_thread_count_and_undoes_bit_for_bit :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	clays := [2]Clay{grab_sphere(96), grab_sphere(96, &pool)}
	defer for &c in clays do clay_destroy(&c)
	before := clay_hash(&clays[0])
	mirror := matrix[3, 3]f32{-1, 0, 0, 0, 1, 0, 0, 0, 1}
	at := linalg.normalize(Vec3{0.4, 0, 0.9})
	for &c in clays {
		clay_stroke_begin(&c)
		clay_grab_begin(&c, 0.2, {at, mirror * at}, {IDENTITY, mirror}, elastic = true, volume = 0.5)
		for i in 1 ..= 4 do _ = clay_grab_move(&c, {0.03 * f32(i), 0.02 * f32(i), 0.05 * f32(i)}, {0, 0, 1}, 0.15 * f32(i))
		_ = clay_stroke_end(&c)
	}
	testing.expect(t, clay_hash(&clays[0]) == clay_hash(&clays[1]), "the pull differs between one thread and three")
	testing.expect(t, clay_undo(&clays[0]) && clay_hash(&clays[0]) == before, "undo left the field changed")
}
