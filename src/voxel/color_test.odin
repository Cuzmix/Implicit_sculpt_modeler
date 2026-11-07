package voxel

import "core:math"
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

// Paint carried by the clay: the top painted red, then each edit, on one thread and three.
@(private = "file")
painted_pair :: proc(pool: ^jobs.Pool) -> [2]Clay {
	clays := [2]Clay{color_sphere(), color_sphere(pool)}
	for &c in clays do paint_top(&c, {220, 30, 30}, 0.35)
	return clays
}

@(test)
grab_carries_the_paint :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	clays := painted_pair(&pool)
	defer for &c in clays do clay_destroy(&c)
	for &c in clays {
		clay_stroke_begin(&c)
		clay_grab_begin(&c, 0.5, {{0, 0, 1}}, {IDENTITY})
		for i in 1 ..= 4 do _ = clay_grab_move(&c, {0, 0, 0.1 * f32(i)})
		_ = clay_stroke_end(&c)
		_ = clay_flush(&c)
	}
	c := &clays[0]
	// The paint went up with the top, which is now at about 1.4.
	top := color_near(c, {0, 0, 1.4})
	testing.expectf(t, top.rgb == {220, 30, 30} && top[3] > 200, "the dragged top is %v", top)
	testing.expectf(t, color_near(c, {1, 0, 0})[3] == 0, "paint reached the side")
	testing.expect(t, color_hash(&clays[0]) == color_hash(&clays[1]), "the grabbed paint differs between one thread and three")
	testing.expect(t, clay_undo(c), "nothing to undo")
	testing.expectf(t, color_near_flushed(c, {0, 0, 1}).rgb == {220, 30, 30}, "undo lost the paint")
}

@(test)
snake_hook_carries_the_paint :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	clays := painted_pair(&pool)
	defer for &c in clays do clay_destroy(&c)
	for &c in clays {
		clay_stroke_begin(&c)
		at := Vec3{0, 0, 1}
		for _ in 0 ..< 6 {
			_ = clay_dab(&c, {kind = .Snake_Hook, radius = 0.35, strength = 1, normal = {0, 0, 1}, drag = {0, 0, 0.05}}, at)
			at.z += 0.05
		}
		_ = clay_stroke_end(&c)
		_ = clay_flush(&c)
	}
	top := color_near(&clays[0], {0, 0, 1.3})
	testing.expectf(t, top.rgb == {220, 30, 30} && top[3] > 200, "the hooked tip is %v", top)
	testing.expect(t, color_hash(&clays[0]) == color_hash(&clays[1]), "the hooked paint differs between one thread and three")
}

@(test)
mirror_and_resample_keep_the_paint :: proc(t: ^testing.T) {
	c := color_sphere()
	defer clay_destroy(&c)
	clay_stroke_begin(&c)
	_ = clay_dab(&c, {kind = .Paint, radius = 0.35, strength = 1, normal = {1, 0, 0}, color = {10, 200, 40}}, {1, 0, 0})
	_ = clay_stroke_end(&c)
	_ = clay_flush(&c)
	testing.expect(t, clay_mirror(&c, 0, true))
	_ = clay_flush(&c)
	other := color_near(&c, {-1, 0, 0})
	testing.expectf(t, other.rgb == {10, 200, 40} && other[3] > 200, "the mirrored side is %v", other)
	testing.expect(t, clay_resample(&c, RESAMPLE_UP))
	_ = clay_flush(&c)
	for x in ([2]f32{1, -1}) {
		col := color_near(&c, {x, 0, 0})
		testing.expectf(t, col.rgb == {10, 200, 40} && col[3] > 200, "after Res+ the side at %v is %v", x, col)
	}
	testing.expectf(t, color_near(&c, {0, 0, 1})[3] == 0, "Res+ spread paint to the top")
}

@(test)
union_takes_the_other_clays_paint :: proc(t: ^testing.T) {
	a := color_sphere()
	defer clay_destroy(&a)
	b := color_sphere()
	defer clay_destroy(&b)
	paint_top(&b, {0, 0, 250}, 2.5)
	want := color_near(&b, {1, 0, 0})
	// The other sphere sits 1.2 along x: its far side shows its paint, this one's none.
	to_other := matrix[4, 4]f32{1, 0, 0, -1.2, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}
	testing.expect(t, clay_combine(&a, &b.volume, to_other, 1, .Union))
	_ = clay_flush(&a)
	far := color_near(&a, {2.2, 0, 0})
	testing.expectf(t, far.rgb == {0, 0, 250} && math.abs(f32(far[3]) - f32(want[3])) < 8, "the other's side is %v, its own %v", far, want)
	testing.expectf(t, color_near(&a, {-1, 0, 0})[3] == 0, "this clay's side took paint")
}

@(test)
convert_to_mesh_keeps_the_paint :: proc(t: ^testing.T) {
	c := color_sphere()
	defer clay_destroy(&c)
	paint_top(&c, {250, 200, 0}, 0.4)
	colors: [][4]u8
	m := clay_to_mesh(&c, colors = &colors)
	defer geom.mesh_destroy(&m)
	defer delete(colors)
	testing.expect_value(t, len(colors), len(m.positions))
	best := f32(1e9)
	top: [4]u8
	for p, k in m.positions do if d := linalg.length2(p - {0, 0, 1}); d < best do best, top = d, colors[k]
	testing.expectf(t, top.rgb == {250, 200, 0} && top[3] > 200, "the mesh's top is %v", top)
}

@(test)
fill_gradient_and_clear_paint_the_whole_clay :: proc(t: ^testing.T) {
	c := color_sphere()
	defer clay_destroy(&c)
	testing.expect(t, !clay_paint_command(&c, .Clear, {}, {}), "clearing unpainted clay changed it")
	testing.expect(t, clay_paint_command(&c, .Fill, {40, 80, 160}, {}))
	_ = clay_flush(&c)
	for p in ([3]Vec3{{1, 0, 0}, {0, -1, 0}, {0, 0, 1}}) {
		col := color_near(&c, p)
		testing.expectf(t, col == {40, 80, 160, 255}, "the fill left %v at %v", col, p)
	}
	testing.expect(t, !clay_paint_command(&c, .Fill, {40, 80, 160}, {}), "a second fill changed something")
	// Top white to bottom black: the axis points down.
	testing.expect(t, clay_paint_command(&c, .Gradient, {255, 255, 255}, {0, 0, 0}, {0, 0, -1}))
	_ = clay_flush(&c)
	top, middle, bottom := color_near(&c, {0, 0, 1}), color_near(&c, {1, 0, 0}), color_near(&c, {0, 0, -1})
	testing.expectf(t, top.r > 220 && bottom.r < 35 && middle.r > 100 && middle.r < 155, "the gradient is %v, %v, %v", top, middle, bottom)
	testing.expect(t, clay_paint_command(&c, .Clear, {}, {}))
	testing.expect(t, !clay_has_color(&c), "the clear left paint")
	testing.expect(t, clay_undo(&c) && color_near_flushed(&c, {0, 0, 1}).r > 220, "undo did not bring the gradient back")
}

@(test)
a_gradient_is_the_same_on_any_thread_count :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	clays := [2]Clay{color_sphere(), color_sphere(&pool)}
	defer for &c in clays do clay_destroy(&c)
	for &c in clays {
		paint_top(&c, {255, 0, 0}, 0.5)
		_ = clay_paint_command(&c, .Gradient, {0, 255, 0}, {0, 0, 255}, linalg.normalize(Vec3{1, 2, -1}))
	}
	testing.expect(t, color_hash(&clays[0]) == color_hash(&clays[1]), "the gradient differs between one thread and three")
}

@(test)
convert_to_voxels_keeps_the_meshs_paint :: proc(t: ^testing.T) {
	// A coarse sphere, so the paint has to be laid along its triangles, not from vertices.
	sphere := geom.icosphere(3)
	defer geom.mesh_destroy(&sphere)
	colors := make([][4]u8, len(sphere.positions))
	defer delete(colors)
	for p, k in sphere.positions do if p.z > 0.6 do colors[k] = {30, 200, 90, 255}
	c: Clay
	testing.expect(t, clay_from_mesh(&c, sphere, 2.0 / 64, nil))
	defer clay_destroy(&c)
	testing.expect(t, clay_paint_from_mesh(&c, sphere, colors))
	_ = clay_flush(&c)
	top := color_near(&c, {0, 0, 1})
	testing.expectf(t, top == {30, 200, 90, 255}, "the top is %v", top)
	testing.expectf(t, color_near(&c, {1, 0, 0})[3] == 0, "the side took paint: %v", color_near(&c, {1, 0, 0}))
	testing.expectf(t, color_near(&c, {0, 0, -1})[3] == 0, "the bottom took paint")
	unpainted := make([][4]u8, len(sphere.positions))
	defer delete(unpainted)
	testing.expect(t, !clay_paint_from_mesh(&c, sphere, unpainted), "an unpainted mesh painted the clay")
}

@(test)
the_colour_at_a_hit_is_the_paint_there :: proc(t: ^testing.T) {
	c := color_sphere()
	defer clay_destroy(&c)
	testing.expect_value(t, clay_color_at(&c, {0, 0, 1}), [4]u8{})
	paint_top(&c, {200, 40, 30}, 0.4)
	hit, _, ok := clay_raycast(&c, {0, 0, 5}, {0, 0, -1})
	testing.expect(t, ok)
	top := clay_color_at(&c, hit)
	testing.expectf(t, top.rgb == {200, 40, 30} && top[3] > 240, "the eyedropper sees %v", top)
	side, _, _ := clay_raycast(&c, {5, 0, 0}, {-1, 0, 0})
	testing.expect_value(t, clay_color_at(&c, side)[3], 0)
}
