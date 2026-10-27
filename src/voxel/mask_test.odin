package voxel

import "core:math/linalg"
import "core:testing"

import "../geom"
import "../jobs"

@(private = "file")
masked_sphere :: proc(across: f32, pool: ^jobs.Pool = nil) -> (c: Clay) {
	clay_init(&c, 2 / across, {}, pool)
	clay_fill_sphere(&c, {}, 1)
	_ = clay_flush(&c)
	return
}

// One stroke of `kind` at the sphere's top.
@(private = "file")
top_stroke :: proc(c: ^Clay, kind: Brush_Kind, radius: f32, invert := false) {
	clay_stroke_begin(c)
	_ = clay_dab(c, {kind = kind, radius = radius, strength = 1, invert = invert, normal = {0, 0, 1}}, {0, 0, 1})
	_ = clay_stroke_end(c)
	_ = clay_flush(c)
}

// The mask of the surface vertex nearest `p`.
@(private = "file")
vertex_mask_near :: proc(c: ^Clay, p: Vec3) -> (mask: u8, found: bool) {
	s := &c.surface
	best := f32(1e9)
	for n in s.nodes {
		for k in n.vert_first ..< n.vert_first + n.vert_count {
			d := linalg.length2(s.mesh.positions[k] - p)
			if d < best {
				best, mask, found = d, s.mask[k], true
			}
		}
	}
	return
}

// A Mask dab masks the clay under it, which an Add dab then cannot raise, while the same
// Add raises an unmasked sphere; the mask shows on the vertices there and nowhere else.
@(test)
a_masked_patch_holds_still_under_the_brush :: proc(t: ^testing.T) {
	c := masked_sphere(96)
	defer clay_destroy(&c)
	testing.expect(t, !clay_has_mask(&c))
	top_stroke(&c, .Mask, 0.5)
	testing.expect(t, clay_has_mask(&c), "the Mask dab left no mask")
	top, found := vertex_mask_near(&c, {0, 0, 1})
	testing.expectf(t, found && top > 240, "the top vertex's mask is %d", top)
	side, _ := vertex_mask_near(&c, {1, 0, 0})
	testing.expect_value(t, side, u8(0))
	before := volume_sample(&c.volume, {0, 0, 1.05})
	top_stroke(&c, .Add, 0.3)
	after := volume_sample(&c.volume, {0, 0, 1.05})
	testing.expectf(t, abs(after - before) < 0.05, "the masked top moved: %v to %v voxels", before, after)
	free := masked_sphere(96)
	defer clay_destroy(&free)
	top_stroke(&free, .Add, 0.3)
	moved := volume_sample(&free.volume, {0, 0, 1.05})
	testing.expectf(t, before - moved > 0.5, "the unmasked top did not rise: %v to %v voxels", before, moved)
	// Erasing the mask frees the clay again.
	top_stroke(&c, .Mask, 0.6, invert = true)
	testing.expect(t, !clay_has_mask(&c), "the inverted Mask dab left mask behind")
}

// Fill masks everything, Invert turns it over and Clear drops it; a shape masks what the
// test says and nothing else; each is one undo step the clay can take back.
@(test)
mask_commands_and_shapes_are_undo_steps :: proc(t: ^testing.T) {
	c := masked_sphere(96)
	defer clay_destroy(&c)
	testing.expect(t, clay_mask_command(&c, .Fill))
	_ = clay_flush(&c)
	m, _ := vertex_mask_near(&c, {0, 1, 0})
	testing.expect_value(t, m, u8(255))
	testing.expect(t, clay_mask_command(&c, .Invert))
	testing.expect(t, !clay_has_mask(&c), "inverting a full mask left some")
	testing.expect(t, clay_mask_command(&c, .Invert))
	testing.expect(t, clay_mask_command(&c, .Clear))
	testing.expect(t, len(c.volume.mask_bricks) == len(c.volume.mask_free), "Clear left mask bricks")
	testing.expect(t, !clay_mask_command(&c, .Clear), "clearing nothing counted as a change")
	upper :: proc(p: Vec3, _: rawptr) -> bool {return p.z > 0}
	testing.expect(t, clay_mask_shape(&c, upper, nil, false))
	_ = clay_flush(&c)
	hi, _ := vertex_mask_near(&c, {0, 0, 1})
	lo, _ := vertex_mask_near(&c, {0, 0, -1})
	testing.expectf(t, hi == 255 && lo == 0, "the shape masked %d above and %d below", hi, lo)
	testing.expect(t, clay_undo(&c), "no step to undo")
	testing.expect(t, !clay_has_mask(&c), "undo left the shape's mask")
	testing.expect(t, clay_redo(&c))
	testing.expect(t, clay_has_mask(&c), "redo did not bring the mask back")
	testing.expect(t, clay_mask_shape(&c, upper, nil, true), "unmasking the shape changed nothing")
	testing.expect(t, !clay_has_mask(&c))
}

// A stroke that carves a masked brick down to a tile loses its mask with the brick; undo
// brings the brick and its mask back, bit for bit.
@(test)
undo_brings_a_collapsed_brick_s_mask_back :: proc(t: ^testing.T) {
	c := masked_sphere(64)
	defer clay_destroy(&c)
	testing.expect(t, clay_mask_command(&c, .Fill))
	before := clay_hash(&c)
	masked_before := len(c.volume.mask_bricks) - len(c.volume.mask_free)
	// Subtract with an empty mask? The mask holds the clay still, so first unmask a patch
	// and carve there, which collapses bricks beside it that keep their full mask.
	clay_stroke_begin(&c)
	_ = clay_dab(&c, {kind = .Mask, radius = 0.6, strength = 1, invert = true, normal = {0, 0, 1}}, {0, 0, 1})
	_ = clay_stroke_end(&c)
	clay_stroke_begin(&c)
	for _ in 0 ..< 6 do _ = clay_dab(&c, {kind = .Subtract, radius = 0.45, strength = 1, normal = {0, 0, 1}}, {0, 0, 1})
	_ = clay_stroke_end(&c)
	testing.expect(t, clay_undo(&c) && clay_undo(&c), "two steps to undo")
	testing.expect_value(t, clay_hash(&c), before)
	testing.expect_value(t, len(c.volume.mask_bricks) - len(c.volume.mask_free), masked_before)
	for coord, slot in c.volume.coords {
		if coord == BRICK_FREE do continue
		m := mask_of(&c.volume, u32(slot))
		if m == nil || m.m[0] != 255 {
			testing.fail_now(t, "a brick came back without its full mask")
		}
	}
}

// The file keeps the masks (the old raw versions are read in pack_test.odin).
@(test)
the_file_keeps_the_masks :: proc(t: ^testing.T) {
	c := masked_sphere(64)
	defer clay_destroy(&c)
	top_stroke(&c, .Mask, 0.5)
	bytes := make([dynamic]u8)
	defer delete(bytes)
	testing.expect(t, clay_write(&c, &bytes))
	testing.expectf(t, len(bytes) <= clay_write_estimate(&c), "%d bytes, estimated %d", len(bytes), clay_write_estimate(&c))
	back: Clay
	r := geom.Byte_Reader{data = bytes[:], ok = true}
	testing.expect(t, clay_read(&back, &r, nil), "the clay did not read back")
	defer clay_destroy(&back)
	testing.expect_value(t, clay_hash(&back), clay_hash(&c))
	for g in ([3][3]i32{{2048, 2048, 2048 + 31}, {2048 + 5, 2048 - 3, 2048 + 30}, {2048, 2048 + 31, 2048}}) {
		testing.expect_value(t, mask_value(&back.volume, g), mask_value(&c.volume, g))
	}
	testing.expect(t, mask_value(&back.volume, {2048, 2048, 2048 + 31}) > 200, "the top voxel's mask did not survive the file")
}

// Masked dabs and mask dabs agree on one thread and three.
@(test)
masked_strokes_agree_on_one_thread_and_three :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	serial := masked_sphere(96)
	defer clay_destroy(&serial)
	parallel := masked_sphere(96, &pool)
	defer clay_destroy(&parallel)
	for c in ([2]^Clay{&serial, &parallel}) {
		clay_stroke_begin(c)
		for i in 0 ..< 5 do _ = clay_dab(c, {kind = .Mask, radius = 0.4, strength = 0.5, normal = {0, 0, 1}}, {0.1 * f32(i), 0, 1})
		_ = clay_stroke_end(c)
		clay_stroke_begin(c)
		for i in 0 ..< 5 do _ = clay_dab(c, {kind = .Add, radius = 0.3, strength = 1, normal = {0, 0, 1}}, {0.1 * f32(i), 0, 1})
		_ = clay_stroke_end(c)
		_ = clay_flush(c)
	}
	testing.expect_value(t, clay_hash(&parallel), clay_hash(&serial))
	sum :: proc(c: ^Clay) -> (s: int) {
		for coord, slot in c.volume.coords {
			if coord == BRICK_FREE do continue
			if m := mask_of(&c.volume, u32(slot)); m != nil do for x in m.m do s += int(x)
		}
		return
	}
	testing.expect_value(t, sum(&parallel), sum(&serial))
}
