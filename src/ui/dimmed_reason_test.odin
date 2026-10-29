package ui

import "core:testing"

// A dimmed button or menu row with a reason never runs, but a finger held on it shows the
// reason in its tooltip; one with none stays as it was, taking no press at all.
@(test)
a_dimmed_control_says_why :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	frame :: proc(ctx: ^Context, p: [2]f32, down, pressed, released: Buttons) -> (clicked, picked: bool, b, m: Rect) {
		frame_begin(ctx, {mouse = p, mouse_valid = true, down = down, pressed = pressed, released = released, window = {800, 600}, pixel_density = 1, dt = 1.0 / 60, pointer = .Finger})
		begin_anchored(ctx, "panel", .Start, .Start, {16, 16}, {direction = .Column, width = 260})
		clicked = button(ctx, "Remesh", enabled = false, reason = "Clay is voxel clay")
		b = ctx.last_rect
		picked = menu_item(ctx, "Subdivide", enabled = false, reason = "Cube is a cage")
		m = ctx.last_rect
		end(ctx)
		frame_end(ctx)
		return
	}
	_, _, b, m := frame(&ctx, {-1, -1}, {}, {}, {})
	_, _, b, m = frame(&ctx, {-1, -1}, {}, {}, {})
	for r, i in ([2]Rect{b, m}) {
		at := [2]f32{r.x + 30, r.y + r.h * 0.5}
		_, _, _, _ = frame(&ctx, at, {.Left}, {.Left}, {})
		for _ in 0 ..< 40 do _, _, _, _ = frame(&ctx, at, {.Left}, {}, {})
		_, keys := long_tip_shown(&ctx)
		testing.expect_value(t, keys, "Clay is voxel clay" if i == 0 else "Cube is a cage")
		clicked, picked, _, _ := frame(&ctx, at, {}, {}, {.Left})
		testing.expect(t, !clicked && !picked)
		for _ in 0 ..< 3 do _, _, _, _ = frame(&ctx, {-1, -1}, {}, {}, {})
	}
}
