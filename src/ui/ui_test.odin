package ui

import "core:math"
import "core:testing"

// A window of 800 by 600 points at one pixel per point with the pointer at `mouse`.
@(private = "file")
input_at :: proc(mouse: [2]f32, down: Buttons = {}, pressed: Buttons = {}, released: Buttons = {}, dt: f32 = 1.0 / 60) -> Input {
	return {mouse = mouse, mouse_valid = true, down = down, pressed = pressed, released = released, window = {800, 600}, pixel_density = 1, dt = dt}
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
anchored_column_stays_inside_the_safe_area :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)

	// A tablet's camera cutout takes 30 points off the top, its gesture bar 20 off the
	// bottom; the column keeps its 16 points from the safe area's edge instead.
	input := input_at({-1, -1})
	input.safe = {0, 30, 800, 550}
	two_buttons(&ctx, input)
	_, _, column := two_buttons(&ctx, input)
	testing.expect_value(t, column, Rect{800 - 16 - 56, 30 + 16, 56, 112})
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
	changed := vslider(ctx, "Strength", value, 0, 1, .Linear, "", track = 300)
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

@(test)
easings_run_from_zero_to_one :: proc(t: ^testing.T) {
	for e in Ease {
		testing.expectf(t, math.abs(ease(e, 0)) < 1e-6, "%v starts at 0", e)
		testing.expectf(t, math.abs(ease(e, 1) - 1) < 1e-6, "%v ends at 1", e)
		peak: f32
		for i in 0 ..= 100 do peak = max(peak, ease(e, f32(i) / 100))
		// Out_Back may pass the end a little, and nothing more than that.
		testing.expectf(t, peak <= (1.06 if e == .Out_Back else 1 + 1e-6), "%v peaks at %v", e, peak)
	}
	// Out_Quad is ahead of linear all the way: quick to start, settling gently.
	testing.expect(t, ease(.Out_Quad, 0.25) > 0.25 && ease(.Out_Quad, 0.75) > 0.75)
}

// Runs `frames` empty frames of `dt` seconds each, so tweens move on.
@(private = "file")
idle :: proc(ctx: ^Context, frames: int, dt: f32 = 1.0 / 60) {
	for _ in 0 ..< frames {
		frame_begin(ctx, input_at({-1, -1}, dt = dt))
		frame_end(ctx)
	}
}

@(test)
a_retargeted_tween_continues_from_where_it_is :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	frame_begin(&ctx, input_at({-1, -1}))
	// The first time it is seen, a tween is at its target.
	testing.expect_value(t, tween(&ctx, 1, 0, 0.2), 0)
	testing.expect_value(t, tween(&ctx, 1, 10, 0.2, .Linear), 0)
	frame_end(&ctx)
	idle(&ctx, 6) // a tenth of a second: half way
	frame_begin(&ctx, input_at({-1, -1}))
	mid := tween(&ctx, 1, 10, 0.2, .Linear)
	frame_end(&ctx)
	testing.expectf(t, mid > 4 && mid < 6, "half way along is %v", mid)
	// Turning back starts from where it is, not from either end.
	frame_begin(&ctx, input_at({-1, -1}, dt = 0))
	back := tween(&ctx, 1, 0, 0.2, .Linear)
	frame_end(&ctx)
	testing.expect_value(t, back, mid)
	idle(&ctx, 20)
	frame_begin(&ctx, input_at({-1, -1}))
	testing.expect_value(t, tween(&ctx, 1, 0, 0.2, .Linear), 0)
	frame_end(&ctx)
}

@(test)
reduced_motion_arrives_at_once :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	ctx.reduced_motion = true
	frame_begin(&ctx, input_at({-1, -1}))
	_ = tween(&ctx, 7, 0, 0.3)
	testing.expect_value(t, tween(&ctx, 7, 1, 0.3), 1)
	testing.expect_value(t, presence(&ctx, 8, true, 0.3), 1)
	frame_end(&ctx)
}

@(test)
presence_animates_in_and_unused_tweens_are_dropped :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	frame_begin(&ctx, input_at({-1, -1}))
	testing.expect_value(t, presence(&ctx, 3, true, 0.2), 0)
	frame_end(&ctx)
	frame_begin(&ctx, input_at({-1, -1}, dt = 0.1))
	p := presence(&ctx, 3, true, 0.2)
	frame_end(&ctx)
	testing.expectf(t, p > 0.5 && p < 1, "presence half way through is %v", p)
	testing.expect(t, 3 in ctx.tweens)
	// Nobody asks for it for three seconds: it goes.
	idle(&ctx, 40, 0.1)
	testing.expect(t, !(3 in ctx.tweens))
}

// One frame with a button that toggles a popover opening under it, holding one item.
@(private = "file")
with_popover :: proc(ctx: ^Context, input: Input, open: ^bool) -> (item_clicked: bool, anchor: Rect) {
	frame_begin(ctx, input)
	begin_anchored(ctx, "bar", .Start, .Start, {10, 10}, {})
	if icon_button(ctx, "Open", ICON_MENU) do open^ = !open^
	anchor = ctx.last_rect
	end(ctx)
	if popover_begin(ctx, "pop", open, anchor, .Below, {direction = .Column, padding = 4, width = 200}) {
		item_clicked = menu_item(ctx, "Item")
		popover_end(ctx)
	}
	frame_end(ctx)
	return
}

@(test)
a_press_outside_a_popover_closes_it_and_never_reaches_the_viewport :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	open := false
	_, anchor := with_popover(&ctx, input_at({-1, -1}), &open)
	at := [2]f32{anchor.x + 24, anchor.y + 24}
	with_popover(&ctx, input_at(at, down = {.Left}, pressed = {.Left}), &open)
	with_popover(&ctx, input_at(at, released = {.Left}), &open)
	testing.expect(t, open)
	// Let it finish opening, then press on the viewport, far from it.
	for _ in 0 ..< 30 do with_popover(&ctx, input_at({600, 500}), &open)
	with_popover(&ctx, input_at({600, 500}, down = {.Left}, pressed = {.Left}), &open)
	testing.expect(t, !open)
	testing.expect(t, wants_pointer(&ctx))
	testing.expect(t, !viewport_dragging(&ctx))
	// Dragging on from there is still not the viewport's, until the button is up.
	with_popover(&ctx, input_at({620, 500}, down = {.Left}), &open)
	testing.expect(t, wants_pointer(&ctx))
	with_popover(&ctx, input_at({620, 500}, released = {.Left}), &open)
	with_popover(&ctx, input_at({620, 500}), &open)
	testing.expect(t, !wants_pointer(&ctx))
}

@(test)
a_closing_popover_takes_no_clicks :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	open := true
	for _ in 0 ..< 30 do with_popover(&ctx, input_at({-1, -1}), &open)
	size, _ := prev_layout(&ctx, "pop")
	testing.expect(t, size.x == 200 && size.y > 0)
	_, anchor := with_popover(&ctx, input_at({-1, -1}), &open)
	item := [2]f32{anchor.x + 40, anchor.y + anchor.h + 6 + 4 + 20}
	open = false
	// The item is still drawn while the popover leaves, but a click on it does nothing.
	with_popover(&ctx, input_at(item, down = {.Left}, pressed = {.Left}), &open)
	clicked, _ := with_popover(&ctx, input_at(item, released = {.Left}), &open)
	testing.expect(t, !clicked)
}

@(test)
tooltips_wait_and_hide_when_pressed :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	open := false
	_, anchor := with_popover(&ctx, input_at({-1, -1}), &open)
	at := [2]f32{anchor.x + 24, anchor.y + 24}
	// Before the delay: no tooltip drawn; after it, one is (more vertices).
	with_popover(&ctx, input_at(at), &open)
	before := len(ctx.draw.vertices)
	for _ in 0 ..< 40 do with_popover(&ctx, input_at(at), &open)
	after := len(ctx.draw.vertices)
	testing.expectf(t, after > before, "a tooltip shows after resting: %d then %d vertices", before, after)
	// A press hides it, and it stays hidden while the pointer stays.
	with_popover(&ctx, input_at(at, down = {.Left}, pressed = {.Left}), &open)
	with_popover(&ctx, input_at(at, released = {.Left}), &open)
	open = false
	for _ in 0 ..< 40 do with_popover(&ctx, input_at(at), &open)
	testing.expect_value(t, ctx.tip_pressed, id_of_in(&ctx, "bar", "Open"))
}

// The id `label` has inside the anchored container `parent`.
@(private = "file")
id_of_in :: proc(ctx: ^Context, parent, label: string) -> Id {
	frame_begin(ctx, input_at({-1, -1}, dt = 0))
	begin_anchored(ctx, parent, .Start, .Start, {10, 10}, {})
	id := id_of(ctx, label)
	end(ctx)
	frame_end(ctx)
	return id
}

@(test)
sections_open_by_growing_and_lay_out_nothing_closed :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	open := false
	// The height read is the previous frame's, the layout the containers size themselves from.
	panel :: proc(ctx: ^Context, open: ^bool, dt: f32) -> (body_drawn: bool, height: f32) {
		frame_begin(ctx, input_at({-1, -1}, dt = dt))
		size, _ := prev_layout(ctx, "panel")
		begin_anchored(ctx, "panel", .Start, .Start, {0, 0}, {direction = .Column, width = 300})
		if section(ctx, "Group", open) {
			body_drawn = true
			for i in 0 ..< 4 do _ = button(ctx, i == 0 ? "A" : i == 1 ? "B" : i == 2 ? "C" : "D")
			section_end(ctx)
		}
		end(ctx)
		frame_end(ctx)
		return body_drawn, size.y
	}
	_, _ = panel(&ctx, &open, 0.016)
	drawn, closed_h := panel(&ctx, &open, 0.016)
	testing.expect(t, !drawn)
	open = true
	_, _ = panel(&ctx, &open, 0.016)
	_, _ = panel(&ctx, &open, 0.016)
	_, part := panel(&ctx, &open, 0.06)
	for _ in 0 ..< 30 do _, _ = panel(&ctx, &open, 0.016)
	_, full := panel(&ctx, &open, 0.016)
	testing.expectf(t, closed_h < part && part < full, "heights closed %v, opening %v, open %v", closed_h, part, full)
	testing.expectf(t, full >= closed_h + 4 * 48, "open, it holds its four buttons: %v", full)
}

@(test)
toasts_copy_their_text_and_go :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	buf := [5]u8{'S', 'a', 'v', 'e', 'd'}
	toast(&ctx, string(buf[:]), .Success)
	buf[0] = 'X'
	testing.expect_value(t, string(ctx.toasts[0].text[:ctx.toasts[0].len]), "Saved")
	for i in 0 ..< 6 do toast(&ctx, i % 2 == 0 ? "even" : "odd")
	testing.expect_value(t, ctx.toast_count, TOASTS)
	idle(&ctx, 1)
	testing.expect_value(t, ctx.toast_count, TOASTS)
	idle(&ctx, 40, 0.1)
	idle(&ctx, 1)
	testing.expect_value(t, ctx.toast_count, 0)
}

@(test)
hit_areas_reach_the_touch_target :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	r := hit_area(&ctx, {100, 100, 30, 20})
	testing.expect_value(t, r, Rect{91, 86, 48, 48})
	big := Rect{0, 0, 60, 60}
	testing.expect_value(t, hit_area(&ctx, big), big)
}

@(test)
transforms_scale_about_their_origin_and_fade :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	frame_begin(&ctx, input_at({-1, -1}))
	mark := vertex_mark(&ctx)
	draw_set_state(&ctx.draw, .Atlas, 0, ctx.clip)
	draw_quad(&ctx.draw, {10, 10, 10, 10}, WHITE_UV, WHITE_UV, {255, 255, 255, 200})
	transform_since(&ctx, mark, 0.5, 2, {10, 10}, {1, 0})
	v := ctx.draw.vertices[mark + 2]
	testing.expect_value(t, v.pos, [2]f32{31, 30})
	testing.expect_value(t, v.color.a, 100)
	frame_end(&ctx)
}

// One frame with a 200 point column at the top left holding a drag value and a text
// field, each a touch target tall. Returns whether each changed.
@(private = "file")
value_and_field :: proc(ctx: ^Context, input: Input, value: ^f32, buf: []u8, field := true) -> (dragged, typed: bool) {
	frame_begin(ctx, input)
	begin_anchored(ctx, "column", .Start, .Start, {0, 0}, {width = 200})
	dragged = drag_value(ctx, "Scale", value, 0.5, 0, 100, "")
	if field do typed = text_field(ctx, "Name", buf)
	end(ctx)
	frame_end(ctx)
	return
}

@(test)
a_drag_value_follows_the_pointer_from_where_it_was_pressed :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	value: f32 = 10
	buf: [8]u8
	value_and_field(&ctx, input_at({100, 24}), &value, buf[:])
	// The press alone changes nothing; 20 points right adds 10, and past the top it holds.
	dragged, _ := value_and_field(&ctx, input_at({100, 24}, down = {.Left}, pressed = {.Left}), &value, buf[:])
	testing.expect(t, !dragged)
	testing.expect_value(t, value, 10)
	dragged, _ = value_and_field(&ctx, input_at({120, 24}, down = {.Left}), &value, buf[:])
	testing.expect(t, dragged)
	testing.expect_value(t, value, 20)
	value_and_field(&ctx, input_at({500, 300}, down = {.Left}), &value, buf[:])
	testing.expect_value(t, value, 100)
	value_and_field(&ctx, input_at({500, 300}, released = {.Left}), &value, buf[:])
}

@(test)
a_text_field_takes_typing_once_tapped :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	value: f32
	buf: [6]u8
	copy(buf[:], "ab")
	over := [2]f32{100, 48 + 24}
	typed_in :: proc(mouse: [2]f32, text: string, backspace := 0, end := false) -> Input {
		input := input_at(mouse)
		input.text, input.backspace, input.text_end = text, backspace, end
		return input
	}
	// Typing before the tap goes nowhere.
	_, typed := value_and_field(&ctx, typed_in(over, "x"), &value, buf[:])
	testing.expect(t, !typed && !typing(&ctx))
	value_and_field(&ctx, input_at(over, down = {.Left}, pressed = {.Left}), &value, buf[:])
	value_and_field(&ctx, input_at(over, released = {.Left}), &value, buf[:])
	testing.expect(t, typing(&ctx))
	// Two bytes of é count as one letter; what does not fit (keeping the zero) is dropped.
	_, typed = value_and_field(&ctx, typed_in(over, "cé"), &value, buf[:])
	testing.expect(t, typed)
	testing.expect_value(t, string(buf[:5]), "abcé")
	value_and_field(&ctx, typed_in(over, "zz"), &value, buf[:])
	testing.expect_value(t, string(buf[:5]), "abcé")
	value_and_field(&ctx, typed_in(over, "", backspace = 2), &value, buf[:])
	testing.expect_value(t, string(buf[:3]), "ab\x00")
	value_and_field(&ctx, typed_in(over, "", end = true), &value, buf[:])
	testing.expect(t, !typing(&ctx))
	// A field that is no longer drawn lets the keys go.
	value_and_field(&ctx, input_at(over, down = {.Left}, pressed = {.Left}), &value, buf[:])
	value_and_field(&ctx, input_at(over, released = {.Left}), &value, buf[:])
	testing.expect(t, typing(&ctx))
	value_and_field(&ctx, input_at(over), &value, buf[:], field = false)
	testing.expect(t, !typing(&ctx))
}

@(test)
an_open_select_keeps_its_options_when_their_memory_is_reused :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	// The options live in memory the app frees before frame_end draws the list (temp
	// memory, after a remesh's free_all); the list must not read it then.
	backing := [8]u8{'S', 'm', 'a', 'l', 'l', 'B', 'i', 'g'}
	options := [2]string{string(backing[:5]), string(backing[5:])}
	frame := proc(ctx: ^Context, input: Input, options: []string) {
		frame_begin(ctx, input)
		begin_anchored(ctx, "column", .Start, .Start, {0, 0}, {width = 200})
		_ = select(ctx, "size", options, 0)
		end(ctx)
	}
	frame(&ctx, input_at({100, 24}), options[:])
	frame_end(&ctx)
	frame(&ctx, input_at({100, 24}, down = {.Left}, pressed = {.Left}), options[:])
	frame_end(&ctx)
	frame(&ctx, input_at({100, 24}, released = {.Left}), options[:])
	backing = {}
	frame_end(&ctx)
	testing.expect_value(t, string(ctx.select_text[:]), "SmallBig")
	testing.expect_value(t, len(ctx.select_ends), 2)
}

@(test)
a_layer_draws_under_what_came_after_its_mark :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	frame_begin(&ctx, input_at({-1, -1}))
	image(&ctx, {0, 0, 800, 600}, 1)
	layer := layer_mark(&ctx)
	begin_anchored(&ctx, "panel", .Start, .Start, {16, 16}, {padding = 8, width = 100, height = 100, radius = 12, background = .Panel})
	end(&ctx)
	panel := len(ctx.draw.indices) - layer.index
	// The overlay comes after the panel, as the app's does once its tools have run.
	overlay_vertex := u32(vertex_mark(&ctx))
	from := layer_begin(&ctx)
	fill_circle(&ctx, {50, 50}, 30, {255, 0, 0, 255})
	stroke_circle(&ctx, {50, 50}, 40, {255, 255, 255, 255}, 1.5)
	layer_end(&ctx, layer, from)
	dl := frame_end(&ctx)
	overlay := len(dl.indices) - layer.index - panel
	testing.expect(t, panel > 0 && overlay > 0)
	// Right after the image come the overlay's triangles, then the panel's.
	under, over := true, true
	for i in dl.indices[layer.index:][:overlay] do under &&= i >= overlay_vertex
	for i in dl.indices[layer.index + overlay:] do over &&= i < overlay_vertex
	testing.expect(t, under && over)
	// The commands still cover every index once, in order.
	next: u32
	for c in dl.cmds {
		testing.expect_value(t, c.first_index, next)
		next += c.index_count
	}
	testing.expect_value(t, int(next), len(dl.indices))
}
