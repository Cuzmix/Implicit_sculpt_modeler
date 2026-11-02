package voxel

import "core:math/rand"
import "core:testing"

import "../geom"

// A brick of a plane field: the distance to z = 3.5 in voxels, clamped as the band is, so
// each row along x is one value.
@(private = "file")
plane_brick :: proc() -> (b: Brick) {
	for k in 0 ..< BRICK_VOXELS do b.d[k] = clamp(i16((f32(k / (BRICK * BRICK)) - 3.5) * SCALE), -CLAMP, CLAMP)
	return
}

// Packing a brick and its mask and unpacking them gives the same bytes, whether the brick
// is a plane (rows of one value: run tokens), all runs, random (raw, since packing would
// not shrink it), at the ends of the range or a straight ramp (every residual 0: a byte a
// voxel); a packed stream never exceeds the raw brick.
@(test)
packed_bricks_and_masks_come_back_bit_for_bit :: proc(t: ^testing.T) {
	bricks: [5]Brick
	bricks[0] = plane_brick()
	for k in 0 ..< BRICK_VOXELS do bricks[1].d[k] = CLAMP if k < 300 else -CLAMP
	r := rand.create(7)
	context.random_generator = rand.default_random_generator(&r)
	for k in 0 ..< BRICK_VOXELS do bricks[2].d[k] = i16(rand.int31_max(65536) - 32768)
	for k in 0 ..< BRICK_VOXELS do bricks[3].d[k] = max(i16) if k % 2 == 0 else min(i16)
	for k in 0 ..< BRICK_VOXELS do bricks[4].d[k] = i16(k) - 256 // a straight ramp: residuals all 0
	for &b, i in bricks {
		out := make([dynamic]u8)
		defer delete(out)
		pack_brick(&out, &b)
		size := int(out[0]) | int(out[1]) << 8
		testing.expectf(t, len(out) <= 2 + size_of(Brick), "brick %d packed to %d bytes", i, len(out))
		testing.expectf(t, (size == 0) == (len(out) == 2 + size_of(Brick)), "brick %d: count %d for %d bytes", i, size, len(out))
		rd := geom.byte_reader(out[:])
		back: Brick
		testing.expectf(t, unpack_brick(&rd, &back) && rd.at == len(out), "brick %d did not unpack", i)
		testing.expectf(t, back == b, "brick %d changed through packing", i)
	}
	plane_out := make([dynamic]u8)
	defer delete(plane_out)
	pack_brick(&plane_out, &bricks[0])
	testing.expectf(t, len(plane_out) < 128, "a plane brick packed to %d bytes", len(plane_out))
	ramp_out := make([dynamic]u8)
	defer delete(ramp_out)
	pack_brick(&ramp_out, &bricks[4])
	testing.expectf(t, len(ramp_out) <= BRICK_VOXELS + 4, "a ramp brick packed to %d bytes", len(ramp_out))

	masks: [3]Mask_Brick
	for k in 0 ..< BRICK_VOXELS do masks[1].m[k] = 255 if k > 100 && k < 400 else 0
	for k in 0 ..< BRICK_VOXELS do masks[2].m[k] = u8(rand.int31_max(256))
	for &m, i in masks {
		out := make([dynamic]u8)
		defer delete(out)
		pack_mask(&out, &m)
		testing.expectf(t, len(out) <= 2 + size_of(Mask_Brick), "mask %d packed to %d bytes", i, len(out))
		if i < 2 do testing.expectf(t, len(out) < 16, "mask %d of runs packed to %d bytes", i, len(out))
		rd := geom.byte_reader(out[:])
		back: Mask_Brick
		testing.expectf(t, unpack_mask(&rd, &back) && rd.at == len(out), "mask %d did not unpack", i)
		testing.expectf(t, back == m, "mask %d changed through packing", i)
	}
}

// A damaged packed brick or mask is refused: a stream that ends early, one whose run goes
// past the brick, one with a count past the bytes, one that leaves bytes over.
@(test)
damaged_packed_bricks_are_refused :: proc(t: ^testing.T) {
	b := plane_brick()
	good := make([dynamic]u8)
	defer delete(good)
	pack_brick(&good, &b)
	bad := [?][]u8 {
		good[:len(good) - 3], // ends early
		{5, 0, 0, 0, 0, 255, 0, 255}, // two runs of 255 after the first value: 511 values, then 255 more
		{40, 0, 0, 0}, // a count past the bytes
		{0, 0}, // raw with nothing after it
	}
	for bytes, i in bad {
		rd := geom.byte_reader(bytes)
		back: Brick
		testing.expectf(t, !unpack_brick(&rd, &back), "damaged brick %d accepted", i)
	}
	over := make([dynamic]u8)
	defer delete(over)
	append(&over, ..good[:])
	append(&over, 7) // a byte past the stream, inside the count
	over[0] += 1
	rd := geom.byte_reader(over[:])
	back: Brick
	testing.expect(t, !unpack_brick(&rd, &back), "a stream with a byte left over accepted")

	bad_masks := [?][]u8{{4, 0, 255, 0, 255, 0}, {3, 0, 1, 2, 3}, {2, 0, 0, 7}}
	for bytes, i in bad_masks {
		mr := geom.byte_reader(bytes)
		m: Mask_Brick
		testing.expectf(t, !unpack_mask(&mr, &m), "damaged mask %d accepted", i)
	}
}

// A sculpted clay's file is well under its raw size: the smooth band packs to about a byte
// a voxel and the clamp either side to runs.
@(test)
a_sculpted_clay_s_file_is_about_half_its_raw_size :: proc(t: ^testing.T) {
	c: Clay
	clay_init(&c, 2.0 / 128, {}, nil)
	defer clay_destroy(&c)
	clay_fill_sphere(&c, {}, 1)
	clay_stroke_begin(&c)
	for i in 0 ..< 8 {
		p := Vec3{0.2 * f32(i) - 0.7, 0, 1}
		_ = clay_dab(&c, {kind = .Add, radius = 0.25, strength = 1, normal = {0, 0, 1}}, p)
	}
	_ = clay_stroke_end(&c)
	out := make([dynamic]u8)
	defer delete(out)
	testing.expect(t, clay_write(&c, &out))
	raw := volume_brick_count(&c.volume) * size_of(Brick)
	testing.expectf(t, len(out) < raw * 65 / 100, "%d bytes for %d raw (%d %%)", len(out), raw, len(out) * 100 / raw)
	testing.expectf(t, len(out) <= clay_write_estimate(&c), "%d bytes, estimated %d", len(out), clay_write_estimate(&c))
	rd := geom.byte_reader(out[:])
	back: Clay
	testing.expect(t, clay_read(&back, &rd, nil), "the clay did not read back")
	defer clay_destroy(&back)
	testing.expect_value(t, clay_hash(&back), clay_hash(&c))
}
