package voxel

import "core:math"
import "core:math/linalg"
import "core:testing"

import "../jobs"

// A sphere of radius 1, 96 voxels across, masked above z = 0.
@(private = "file")
half_masked :: proc(pool: ^jobs.Pool = nil) -> (c: Clay) {
	clay_init(&c, 2.0 / 96, {}, pool)
	clay_fill_sphere(&c, {}, 1)
	upper :: proc(p: Vec3, _: rawptr) -> bool {return p.z > 0}
	_ = clay_mask_shape(&c, upper, nil, false)
	_ = clay_flush(&c)
	return
}

// The mask of the surface vertex nearest the sphere's point at height `z` on the x side.
@(private = "file")
mask_at_height :: proc(c: ^Clay, z: f32) -> u8 {
	_ = clay_flush(c)
	p := Vec3{math.sqrt(1 - z * z), 0, z}
	s := &c.surface
	best := f32(1e9)
	mask: u8
	for n in s.nodes {
		for k in n.vert_first ..< n.vert_first + n.vert_count {
			if d := linalg.length2(s.mesh.positions[k] - p); d < best do best, mask = d, s.mask[k]
		}
	}
	return mask
}

@(test)
grow_and_shrink_move_the_mask_s_edge_over_the_surface :: proc(t: ^testing.T) {
	voxel := f32(2.0 / 96)
	c := half_masked()
	defer clay_destroy(&c)
	testing.expect(t, mask_at_height(&c, -3 * voxel) == 0 && mask_at_height(&c, 3 * voxel) == 255, "the shape's edge is not at the equator")
	testing.expect(t, clay_mask_filter(&c, .Grow, 6), "Grow changed nothing")
	testing.expectf(t, mask_at_height(&c, -3 * voxel) == 255, "Grow did not reach 3 voxels down: %v", mask_at_height(&c, -3 * voxel))
	testing.expectf(t, mask_at_height(&c, -12 * voxel) == 0, "Grow went too far: %v", mask_at_height(&c, -12 * voxel))
	testing.expect(t, clay_undo(&c), "no step to undo")
	testing.expect(t, clay_mask_filter(&c, .Shrink, 6), "Shrink changed nothing")
	testing.expectf(t, mask_at_height(&c, 3 * voxel) == 0, "Shrink did not reach 3 voxels up: %v", mask_at_height(&c, 3 * voxel))
	// The band's edge (inside and out) does not eat the mask: far from the edge it holds.
	testing.expectf(t, mask_at_height(&c, 0.5) == 255 && mask_at_height(&c, 1) == 255, "Shrink ate the mask away from its edge: %v, %v", mask_at_height(&c, 0.5), mask_at_height(&c, 1))
}

@(test)
blur_softens_the_mask_s_edge_and_sharpen_hardens_it :: proc(t: ^testing.T) {
	voxel := f32(2.0 / 96)
	c := half_masked()
	defer clay_destroy(&c)
	testing.expect(t, clay_mask_filter(&c, .Blur, 4), "Blur changed nothing")
	soft := mask_at_height(&c, 2 * voxel)
	testing.expectf(t, soft > 128 && soft < 250, "Blur left the edge's mask at %v", soft)
	testing.expect(t, mask_at_height(&c, 0.5) == 255, "Blur moved the mask away from its edge")
	testing.expect(t, clay_mask_filter(&c, .Sharpen, 4), "Sharpen changed nothing")
	hard := mask_at_height(&c, 2 * voxel)
	testing.expectf(t, hard > soft, "Sharpen took the edge from %v to %v", soft, hard)
}

// The masks' hash (clay_hash reads the field only).
@(private = "file")
mask_hash :: proc(c: ^Clay) -> (h: u64) {
	v := &c.volume
	for coord, slot in v.coords {
		if coord == BRICK_FREE do continue
		m := mask_of(v, u32(slot))
		if m == nil do continue
		b: u64 = 0xcbf2_9ce4_8422_2325
		for x in coord do b = (b ~ u64(u32(x))) * 0x100_0000_01b3
		for x in m.m do b = (b ~ u64(x)) * 0x100_0000_01b3
		h += b
	}
	return
}

@(test)
a_mask_filter_is_the_same_on_any_thread_count_and_undoes_bit_for_bit :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	clays := [2]Clay{half_masked(), half_masked(&pool)}
	defer for &c in clays do clay_destroy(&c)
	before := mask_hash(&clays[0])
	for &c in clays do _ = clay_mask_filter(&c, .Blur, 3)
	testing.expect(t, mask_hash(&clays[0]) == mask_hash(&clays[1]), "Blur differs between one thread and three")
	testing.expect(t, mask_hash(&clays[0]) != before, "Blur changed nothing the hash sees")
	testing.expect(t, clay_undo(&clays[0]) && mask_hash(&clays[0]) == before, "undo left the mask changed")
	// No mask: nothing to filter.
	testing.expect(t, clay_mask_command(&clays[0], .Clear) && !clay_mask_filter(&clays[0], .Grow, 2), "a filter of no mask changed something")
}
