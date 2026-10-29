package ui

import "core:testing"

// A menu row with a tag is still one row that a tap picks.
@(test)
a_tagged_menu_item_still_picks :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	frame :: proc(ctx: ^Context, p: [2]f32, down, pressed, released: Buttons) -> (picked: bool, r: Rect) {
		frame_begin(ctx, {mouse = p, mouse_valid = true, down = down, pressed = pressed, released = released, window = {800, 600}, pixel_density = 1, dt = 1.0 / 60, pointer = .Mouse})
		begin_anchored(ctx, "menu", .Start, .Start, {16, 16}, {direction = .Column, width = 260})
		picked = menu_item(ctx, "Make editable", tag = "Model", tag_color = {0xff, 0x9f, 0x5a, 0xff})
		r = ctx.last_rect
		end(ctx)
		frame_end(ctx)
		return
	}
	_, r := frame(&ctx, {-1, -1}, {}, {}, {})
	_, r = frame(&ctx, {-1, -1}, {}, {}, {})
	at := [2]f32{r.x + 40, r.y + r.h * 0.5}
	_, _ = frame(&ctx, at, {.Left}, {.Left}, {})
	picked, _ := frame(&ctx, at, {}, {}, {.Left})
	testing.expect(t, picked)
}
