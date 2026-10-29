package ui

import "core:testing"

// One frame of a row of three tabs that are drag sources, at the top left; the tab picked
// and the one dragged (-1 for none), and where the tabs are.
@(private = "file")
tabs_frame :: proc(ctx: ^Context, p: [2]f32, down, pressed, released: Buttons, pointer: Pointer_Kind) -> (picked, dragged: int, row: Rect) {
	frame_begin(ctx, {mouse = p, mouse_valid = true, down = down, pressed = pressed, released = released, window = {800, 600}, pixel_density = 1, dt = 1.0 / 60, pointer = pointer})
	begin_anchored(ctx, "column", .Start, .Start, {16, 16}, {direction = .Column, width = 300})
	dragged = -1
	picked = tabs(ctx, "tabs", {"One", "Two", "Three"}, 0, dragged = &dragged)
	row = last_ended(ctx)
	end(ctx)
	frame_end(ctx)
	return
}

// Pressed on the second tab, held for `hold` frames, then moved 60 points down over
// `frames` frames and let go: whether it was dragged and whether it was picked.
@(private = "file")
tabs_press :: proc(ctx: ^Context, at: [2]f32, hold, frames: int, pointer: Pointer_Kind) -> (dragged, picked: bool) {
	_, d, _ := tabs_frame(ctx, at, {.Left}, {.Left}, {}, pointer)
	for _ in 0 ..< hold do _, d, _ = tabs_frame(ctx, at, {.Left}, {}, {}, pointer)
	dragged ||= d == 1
	for i in 1 ..= frames {
		_, d, _ = tabs_frame(ctx, at + {0, 60 * f32(i) / f32(max(frames, 1))}, {.Left}, {}, {}, pointer)
		dragged ||= d == 1
	}
	p, _, _ := tabs_frame(ctx, at + {0, 60 if frames > 0 else 0}, {}, {}, {.Left}, pointer)
	return dragged, p == 1
}

// With `dragged`, a mouse drags a tab at once, a finger only after holding past the long
// press (a quick swipe is left to what scrolls), and a press that went past the slop is
// no tap; a still tap still picks the tab.
@(test)
tabs_drag_by_the_thumb_row_rule :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	_, _, row := tabs_frame(&ctx, {-1, -1}, {}, {}, {}, .Finger)
	_, _, row = tabs_frame(&ctx, {-1, -1}, {}, {}, {}, .Finger)
	at := [2]f32{row.x + row.w * 0.5, row.y + row.h * 0.5}
	dragged, picked := tabs_press(&ctx, at, 0, 6, .Mouse)
	testing.expect(t, dragged && !picked)
	dragged, picked = tabs_press(&ctx, at, 0, 6, .Finger)
	testing.expect(t, !dragged && !picked)
	dragged, picked = tabs_press(&ctx, at, 30, 6, .Finger)
	testing.expect(t, dragged && !picked)
	dragged, picked = tabs_press(&ctx, at, 2, 0, .Finger)
	testing.expect(t, !dragged && picked)
}
