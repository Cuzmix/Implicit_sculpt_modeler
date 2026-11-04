package ui

import "core:testing"

@(private = "file")
still :: proc() -> Input {
	return {mouse = {-1, -1}, mouse_valid = true, window = {800, 600}, pixel_density = 1, dt = 1.0 / 60}
}

// What something drew can be copied from the frame after, triangles and clips, even when a
// layer laid under the panels moved the indices after it was drawn; slide_since moves it
// and its clip rectangles and cuts it where it goes behind something.
@(test)
a_panel_copied_from_last_frame_slides_whole :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	copy: Draw_Copy
	defer draw_copy_destroy(&copy)

	frame_begin(&ctx, still())
	fill_rect(&ctx, {0, 0, 10, 10}, 0, {255, 0, 0, 255})
	layer := layer_mark(&ctx)
	m := motion_mark(&ctx)
	fill_rect(&ctx, {100, 100, 50, 40}, 0, {0, 255, 0, 255})
	r := range_end(&ctx, m)
	drawn := r.vertex_end - r.vertex
	tris := r.index_end - r.index
	// Something drawn after, laid under the panel: indices move, vertices do not.
	from := layer_begin(&ctx)
	fill_rect(&ctx, {0, 0, 5, 5}, 0, {0, 0, 255, 255})
	layer_end(&ctx, layer, from)
	frame_end(&ctx)

	frame_begin(&ctx, still())
	testing.expect(t, drawn_last(&ctx, r))
	testing.expect(t, copy_prev(&ctx, r, &copy))
	testing.expect_value(t, len(copy.vertices), drawn)
	testing.expect_value(t, len(copy.indices), tris)
	for v in copy.vertices do testing.expect_value(t, v.color.rgb, [3]u8{0, 255, 0})
	m2 := draw_copy(&ctx, &copy)
	slide_since(&ctx, m2, 0.5, {20, 0}, {0, 0, 160, 600})
	xs := [2]f32{max(f32), min(f32)}
	for v in ctx.draw.vertices[m2.vertex:] do xs = {min(xs[0], v.pos.x), max(xs[1], v.pos.x)}
	testing.expect(t, xs[0] >= 119 && xs[0] <= 121 && xs[1] >= 169 && xs[1] <= 171, "the copy moved 20 points right")
	for v in ctx.draw.vertices[m2.vertex:] do testing.expect(t, v.color.a <= 128, "the copy faded")
	for c in ctx.draw.cmds[m2.cmd:] do testing.expect(t, c.clip.x + c.clip.w <= 160, "the copy is cut at 160 points")
	frame_end(&ctx)

	// Two frames on, it was not drawn the frame before, so there is nothing to copy.
	frame_begin(&ctx, still())
	testing.expect(t, !drawn_last(&ctx, r))
	testing.expect(t, !copy_prev(&ctx, r, &copy))
	frame_end(&ctx)
}

// With motion Reduced a slide only fades: nothing moves and nothing is cut.
@(test)
reduced_motion_slides_nothing :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	ctx.motion = .Reduced
	frame_begin(&ctx, still())
	m := motion_mark(&ctx)
	fill_rect(&ctx, {100, 100, 50, 40}, 0, {0, 255, 0, 255})
	before := ctx.draw.vertices[m.vertex].pos
	slide_since(&ctx, m, 0.5, {20, 0}, {0, 0, 10, 10})
	testing.expect_value(t, ctx.draw.vertices[m.vertex].pos, before)
	for c in ctx.draw.cmds[m.cmd:] do testing.expect(t, c.clip.w > 10, "nothing was cut")
	frame_end(&ctx)
}
