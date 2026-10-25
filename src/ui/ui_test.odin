package ui

import "core:math"
import "core:testing"

// A window of 800 by 600 points at one pixel per point with the pointer at `mouse`.
@(private = "file")
input_at :: proc(mouse: [2]f32, down: Buttons = {}, pressed: Buttons = {}, released: Buttons = {}) -> Input {
	return {mouse = mouse, mouse_valid = true, down = down, pressed = pressed, released = released, window = {800, 600}, pixel_density = 1}
}

// One frame with a column of two 48 point buttons anchored to the top right corner,
// 16 points in. Returns which were clicked and where the column ended up.
@(private = "file")
two_buttons :: proc(ctx: ^Context, input: Input) -> (a, b: bool, column: Rect) {
	frame_begin(ctx, input)
	begin_anchored(ctx, "column", .End, .Start, {16, 16}, {gap = 8, padding = 4, background = .Panel, radius = 16})
	a = icon_button(ctx, "a", ICON_UNDO)
	b = icon_button(ctx, "b", ICON_REDO)
	end(ctx)
	frame_end(ctx)
	column = ctx.placed[len(ctx.placed) - 1].rect
	return
}

@(test)
anchored_column_settles_in_one_frame :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)

	// The first frame does not know the column's size yet, so it sits against the edge
	// as if it were empty; from the second on it is placed by last frame's size.
	_, _, first := two_buttons(&ctx, input_at({-1, -1}))
	testing.expect_value(t, first.w, 56)
	testing.expect_value(t, first.h, 4 + 48 + 8 + 48 + 4)
	_, _, second := two_buttons(&ctx, input_at({-1, -1}))
	testing.expect_value(t, second, Rect{800 - 16 - 56, 16, 56, 112})
	_, _, third := two_buttons(&ctx, input_at({-1, -1}))
	testing.expect_value(t, third, second)
}

@(test)
press_and_release_on_a_button_clicks_it :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	_, _, column := two_buttons(&ctx, input_at({-1, -1}))
	_, _, column = two_buttons(&ctx, input_at({-1, -1}))

	// The second button's middle: 4 padding, 48, 8 gap, then half of 48.
	over_b := [2]f32{column.x + 28, column.y + 4 + 48 + 8 + 24}
	// Hovering gives the pointer to the column before anything is pressed.
	two_buttons(&ctx, input_at(over_b))
	testing.expect(t, wants_pointer(&ctx))
	a, b, _ := two_buttons(&ctx, input_at(over_b, down = {.Left}, pressed = {.Left}))
	testing.expect(t, !a && !b)
	a, b, _ = two_buttons(&ctx, input_at(over_b, released = {.Left}))
	testing.expect(t, !a && b)

	// Pressing on one button and letting go over the other clicks neither.
	over_a := [2]f32{column.x + 28, column.y + 4 + 24}
	two_buttons(&ctx, input_at(over_a, down = {.Left}, pressed = {.Left}))
	two_buttons(&ctx, input_at(over_b, down = {.Left}))
	a, b, _ = two_buttons(&ctx, input_at(over_b, released = {.Left}))
	testing.expect(t, !a && !b)
}

@(test)
a_drag_from_the_viewport_never_presses_a_button :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	_, _, column := two_buttons(&ctx, input_at({-1, -1}))
	_, _, column = two_buttons(&ctx, input_at({-1, -1}))
	over_a := [2]f32{column.x + 28, column.y + 28}

	two_buttons(&ctx, input_at({100, 300}, down = {.Left}, pressed = {.Left}))
	testing.expect(t, viewport_dragging(&ctx))
	testing.expect(t, !wants_pointer(&ctx))
	// The stroke passes over the button and ends there.
	two_buttons(&ctx, input_at(over_a, down = {.Left}))
	testing.expect(t, !wants_pointer(&ctx))
	a, b, _ := two_buttons(&ctx, input_at(over_a, released = {.Left}))
	testing.expect(t, !a && !b)
	testing.expect(t, !viewport_dragging(&ctx))
	// With the buttons up the column has the pointer again.
	two_buttons(&ctx, input_at(over_a))
	testing.expect(t, wants_pointer(&ctx))
}

@(test)
ids_depend_on_the_container_and_hidden_suffix :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	frame_begin(&ctx, input_at({-1, -1}))
	begin_anchored(&ctx, "left", .Start, .Start, {0, 0}, {})
	in_left := id_of(&ctx, "Size")
	in_left_hidden := id_of(&ctx, "Size##2")
	end(&ctx)
	begin_anchored(&ctx, "right", .End, .Start, {0, 0}, {})
	in_right := id_of(&ctx, "Size")
	end(&ctx)
	frame_end(&ctx)
	testing.expect(t, in_left != in_right)
	testing.expect(t, in_left != in_left_hidden)
	testing.expect_value(t, label_text("Size##2"), "Size")
	testing.expect_value(t, label_text("Size"), "Size")
	testing.expect_value(t, label_text(""), "")

	// The same label in the same container is the same widget next frame.
	frame_begin(&ctx, input_at({-1, -1}))
	begin_anchored(&ctx, "left", .Start, .Start, {0, 0}, {})
	testing.expect_value(t, id_of(&ctx, "Size"), in_left)
	end(&ctx)
	frame_end(&ctx)
}

@(test)
slider_maps_round_trip :: proc(t: ^testing.T) {
	for scale in Scale {
		for f in ([]f32{0, 0.25, 0.5, 0.9, 1}) {
			v := slider_value(f, 2, 500, scale)
			testing.expectf(t, math.abs(slider_fraction(v, 2, 500, scale) - f) < 1e-5, "%v at %v", scale, f)
		}
	}
	// A logarithmic slider's middle is the geometric mean, and the ends clamp.
	testing.expect(t, math.abs(slider_value(0.5, 1, 100, .Logarithmic) - 10) < 1e-4)
	testing.expect_value(t, slider_fraction(-5, 1, 100, .Logarithmic), 0)
	testing.expect_value(t, slider_fraction(1000, 1, 100, .Linear), 1)
	testing.expect_value(t, slider_value(2, 1, 100, .Linear), 100)
}

// One frame with a tall slider anchored at the left edge, 300 points of track.
@(private = "file")
one_slider :: proc(ctx: ^Context, input: Input, value: ^f32) -> bool {
	frame_begin(ctx, input)
	begin_anchored(ctx, "sliders", .Start, .Start, {16, 16}, {})
	changed := vslider(ctx, "Strength", value, 0, 1, .Linear, "")
	end(ctx)
	frame_end(ctx)
	return changed
}

@(test)
vslider_moves_by_the_drag_not_to_the_press :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	value: f32 = 0.5
	one_slider(&ctx, input_at({-1, -1}), &value)
	one_slider(&ctx, input_at({-1, -1}), &value)

	// Pressing near the bottom of the track does not jump the value there.
	testing.expect(t, !one_slider(&ctx, input_at({44, 330}, down = {.Left}, pressed = {.Left}), &value))
	testing.expect_value(t, value, 0.5)
	// Dragging up 60 points of a 300 point track adds a fifth.
	testing.expect(t, one_slider(&ctx, input_at({44, 270}, down = {.Left}), &value))
	testing.expect(t, math.abs(value - 0.7) < 1e-5)
	// Far past the top clamps to the end, even outside the slider.
	one_slider(&ctx, input_at({300, -400}, down = {.Left}), &value)
	testing.expect_value(t, value, 1)
	one_slider(&ctx, input_at({300, -400}, released = {.Left}), &value)
	testing.expect_value(t, ctx.active, 0)
}

@(test)
backgrounds_draw_under_their_content :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	for _ in 0 ..< 2 {
		frame_begin(&ctx, input_at({-1, -1}))
		begin_anchored(&ctx, "card", .Start, .Start, {0, 0}, {padding = 8, background = .Panel, radius = 16})
		fill_rect(&ctx, {8, 8, 10, 10}, 0, {1, 2, 3, 255})
		end(&ctx)
		frame_end(&ctx)
	}
	dl := &ctx.draw
	// The square is a quad (two triangles) with its fringe; the panel comes first, so
	// the last vertices referenced are the square's colour.
	last := dl.vertices[dl.indices[len(dl.indices) - 1]]
	testing.expect_value(t, last.color.rgb, [3]u8{1, 2, 3})
	first := dl.vertices[dl.indices[0]]
	testing.expect(t, first.color.rgb != [3]u8{1, 2, 3})
	total: u32
	for c in dl.cmds do total += c.index_count
	testing.expect_value(t, int(total), len(dl.indices))
}
