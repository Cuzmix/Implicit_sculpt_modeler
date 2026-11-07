package voxel

import "core:math/linalg"
import "core:testing"

import "../geom"
import "../jobs"

@(private = "file")
color_sphere :: proc(pool: ^jobs.Pool = nil) -> (c: Clay) {
	clay_init(&c, 2.0 / 64, {}, pool)
	clay_fill_sphere(&c, {}, 1)
	_ = clay_flush(&c)
	return
}

// One Paint stroke of `color` at the sphere's top.
@(private = "file")
paint_top :: proc(c: ^Clay, color: [3]u8, radius: f32, invert := false) {
	clay_stroke_begin(c)
	_ = clay_dab(c, {kind = .Paint, radius = radius, strength = 1, invert = invert, normal = {0, 0, 1}, color = color}, {0, 0, 1})
	_ = clay_stroke_end(c)
	_ = clay_flush(c)
}

// The colour of the surface vertex nearest `p`.
@(private = "file")
color_near :: proc(c: ^Clay, p: Vec3) -> [4]u8 {
	s := &c.surface
	best := f32(1e9)
	col: [4]u8
	for n in s.nodes {
		for k in n.vert_first ..< n.vert_first + n.vert_count {
			if d := linalg.length2(s.mesh.positions[k] - p); d < best do best, col = d, s.color[k]
		}
	}
	return col
}

// The colours' hash (clay_hash reads the field only).
@(private = "file")
color_hash :: proc(c: ^Clay) -> (h: u64) {
	v := &c.volume
	for coord, slot in v.coords {
		if coord == BRICK_FREE do continue
		b := color_of(v, u32(slot))
		if b == nil do continue
		x: u64 = 0xcbf2_9ce4_8422_2325
		for k in coord do x = (x ~ u64(u32(k))) * 0x100_0000_01b3
		for p in b.c do x = (x ~ u64(transmute(u32)p)) * 0x100_0000_01b3
		h += x
	}
	return
}

@(test)
paint_colours_the_surface_and_leaves_the_field_alone :: proc(t: ^testing.T) {
	c := color_sphere()
	defer clay_destroy(&c)
	field := clay_hash(&c)
	testing.expect(t, !clay_has_color(&c))
	paint_top(&c, {200, 40, 30}, 0.4)
	testing.expect(t, clay_has_color(&c), "the stroke painted nothing")
	testing.expect_value(t, clay_hash(&c), field)
	top := color_near(&c, {0, 0, 1})
	testing.expectf(t, top.rgb == {200, 40, 30} && top[3] > 240, "the top is %v", top)
	side := color_near(&c, {1, 0, 0})
	testing.expectf(t, side[3] == 0, "the side got paint: %v", side)
	// Erasing takes the weight away.
	paint_top(&c, {}, 0.4, invert = true)
	testing.expectf(t, color_near(&c, {0, 0, 1})[3] == 0, "the erase left %v", color_near(&c, {0, 0, 1}))
	testing.expect(t, clay_undo(&c) && color_near_flushed(&c, {0, 0, 1})[3] > 240, "undo did not bring the paint back")
	testing.expect(t, clay_undo(&c) && !clay_has_color(&c), "undo left paint")
}

@(private = "file")
color_near_flushed :: proc(c: ^Clay, p: Vec3) -> [4]u8 {
	_ = clay_flush(c)
	return color_near(c, p)
}

@(test)
the_file_keeps_the_colours :: proc(t: ^testing.T) {
	c := color_sphere()
	defer clay_destroy(&c)
	paint_top(&c, {20, 120, 220}, 0.5)
	bytes := make([dynamic]u8)
	defer delete(bytes)
	testing.expect(t, clay_write(&c, &bytes))
	testing.expectf(t, len(bytes) <= clay_write_estimate(&c), "%d bytes, estimated %d", len(bytes), clay_write_estimate(&c))
	back: Clay
	r := geom.Byte_Reader{data = bytes[:], ok = true}
	testing.expect(t, clay_read(&back, &r, nil), "the clay did not read back")
	defer clay_destroy(&back)
	nb, na := 0, 0
	for coord, slot in back.volume.coords do if coord != BRICK_FREE && color_of(&back.volume, u32(slot)) != nil do nb += 1
	for coord, slot in c.volume.coords do if coord != BRICK_FREE && color_of(&c.volume, u32(slot)) != nil do na += 1
	testing.expectf(t, na == nb, "colour bricks %v and %v", na, nb)
	testing.expect_value(t, color_hash(&back), color_hash(&c))
	testing.expectf(t, color_near_flushed(&back, {0, 0, 1}) == color_near(&c, {0, 0, 1}), "the paint did not survive the file: %v, not %v", color_near(&back, {0, 0, 1}), color_near(&c, {0, 0, 1}))
}

@(test)
paint_is_the_same_on_any_thread_count :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	clays := [2]Clay{color_sphere(), color_sphere(&pool)}
	defer for &c in clays do clay_destroy(&c)
	for &c in clays {
		paint_top(&c, {255, 255, 0}, 0.6)
		paint_top(&c, {0, 0, 255}, 0.3)
	}
	testing.expect(t, color_hash(&clays[0]) == color_hash(&clays[1]), "paint differs between one thread and three")
}
