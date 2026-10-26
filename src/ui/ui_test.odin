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

// A toast dismissed by the app leaves as a clicked one does; the others stay.
@(test)
a_dismissed_toast_goes :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	busy := toast(&ctx, "Saving head.sculpt...", .Info)
	idle(&ctx, 5)
	done := toast(&ctx, "Saved head.sculpt", .Success)
	toast_dismiss(&ctx, busy)
	idle(&ctx, 30)
	testing.expect_value(t, ctx.toast_count, 1)
	testing.expect_value(t, ctx.toasts[0].serial, done)
}

// A toast's action is pressed by a click on its right end, which dismisses it too; a
// click on the message only dismisses it.
@(test)
a_toast_action_is_taken_once :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	serial := toast(&ctx, "Deleted Sphere 2", .Info, "Undo")
	plain := toast(&ctx, "Saved", .Success)
	testing.expect(t, serial != 0 && plain != serial)
	idle(&ctx, 30)
	where_is :: proc(ctx: ^Context, id: Id) -> Rect {
		for p in ctx.placed do if p.id == id do return p.rect
		return {}
	}
	undo := where_is(&ctx, ctx.toasts[0].id)
	saved := where_is(&ctx, ctx.toasts[1].id)
	testing.expectf(t, undo.w > 0 && saved.w > 0 && undo.w > saved.w, "toasts at %v and %v", undo, saved)
	// The message of the plain one: dismissed, nothing to act on.
	frame_begin(&ctx, input_at({saved.x + saved.w * 0.5, saved.y + saved.h * 0.5}, {.Left}, {.Left}))
	frame_end(&ctx)
	testing.expect_value(t, toast_take_action(&ctx), Id(0))
	// The action of the other, a few points below its edge: still within the target.
	frame_begin(&ctx, input_at({undo.x + undo.w - 12, undo.y + undo.h - 2}, {.Left}, {.Left}))
	frame_end(&ctx)
	testing.expect_value(t, toast_take_action(&ctx), serial)
	testing.expect_value(t, toast_take_action(&ctx), Id(0))
	idle(&ctx, 30)
	testing.expect_value(t, ctx.toast_count, 0)
}

// On a narrow window a long toast is cut short, its action whole and inside the window;
// a dropped action leaves the message.
@(test)
a_toast_keeps_its_action_on_screen :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	long := "Remeshed a very long object name that goes on and on: 1,002,113 vertices (312 ms) and more"
	serial := toast(&ctx, long, .Info, "Undo")
	for _ in 0 ..< 30 {
		in_ := input_at({-1, -1})
		in_.window = {360, 640}
		frame_begin(&ctx, in_)
		frame_end(&ctx)
	}
	r: Rect
	for p in ctx.placed do if p.id == ctx.toasts[0].id do r = p.rect
	testing.expectf(t, r.x >= 16 - 1 && r.x + r.w <= 360 - 16 + 1, "toast at %v in a 360 point window", r)
	toast_drop_action(&ctx, serial)
	testing.expect_value(t, ctx.toasts[0].action_len, 0)
	testing.expect_value(t, string(ctx.toasts[0].text[:ctx.toasts[0].len]), long)
	free_all(context.temp_allocator)
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

// A held field has the keys from the first frame it is drawn, keeps them through Enter,
// Escape and presses elsewhere, and lets them go once it is no longer drawn.
@(test)
a_held_text_field_keeps_the_keys :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	buf: [8]u8
	frame :: proc(ctx: ^Context, input: Input, buf: []u8, drawn := true) -> (typed: bool) {
		frame_begin(ctx, input)
		begin_anchored(ctx, "column", .Start, .Start, {0, 0}, {width = 200})
		if drawn do typed = text_field(ctx, "Search", buf, hold = true, hint = "Search")
		end(ctx)
		frame_end(ctx)
		return
	}
	elsewhere := [2]f32{600, 400}
	typed := frame(&ctx, input_at(elsewhere), buf[:])
	testing.expect(t, typing(&ctx))
	in_ := input_at(elsewhere)
	in_.text = "wi"
	typed = frame(&ctx, in_, buf[:])
	testing.expect(t, typed)
	testing.expect_value(t, string(buf[:2]), "wi")
	in_ = input_at(elsewhere, down = {.Left}, pressed = {.Left})
	in_.text_end = true
	frame(&ctx, in_, buf[:])
	testing.expect(t, typing(&ctx))
	frame(&ctx, input_at(elsewhere, released = {.Left}), buf[:])
	testing.expect(t, typing(&ctx))
	frame(&ctx, input_at(elsewhere), buf[:], drawn = false)
	testing.expect(t, !typing(&ctx))
}

// The keyboard's highlight fills a menu row as a hover does, without the pointer on it,
// and a row's hit area is the same whether it is highlighted or not.
@(test)
a_highlighted_menu_item_looks_hovered :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	ctx.reduced_motion = true
	frame :: proc(ctx: ^Context, highlight: bool) -> (vertices: int, cell: Rect) {
		frame_begin(ctx, input_at({600, 400}))
		begin_anchored(ctx, "column", .Start, .Start, {0, 0}, {width = 200})
		_ = menu_item(ctx, "Wireframe", highlight = highlight)
		cell = ctx.last_rect
		end(ctx)
		vertices = len(ctx.draw.vertices)
		frame_end(ctx)
		return
	}
	plain, plain_cell := frame(&ctx, false)
	frame(&ctx, true)
	lit, lit_cell := frame(&ctx, true)
	testing.expect(t, lit > plain)
	testing.expect_value(t, lit_cell, plain_cell)
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

// One frame of a bar 36 points tall holding one segmented control whose segments are 36
// points tall: their 48 point hit areas reach 6 points past the bar's top and bottom.
@(private = "file")
short_bar :: proc(ctx: ^Context, input: Input) -> (picked: int, bar: Rect) {
	frame_begin(ctx, input)
	begin_anchored(ctx, "bar", .Start, .Start, {100, 100}, {direction = .Row})
	names := [2]string{"One", "Two"}
	picked = tabs(ctx, "segments", names[:], 0, item_width = 80)
	end(ctx)
	frame_end(ctx)
	bar = ctx.placed[len(ctx.placed) - 1].rect
	return
}

@(test)
a_press_on_a_hit_area_past_the_panel_edge_is_the_widgets :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	_, bar := short_bar(&ctx, input_at({-1, -1}))
	_, bar = short_bar(&ctx, input_at({-1, -1}))
	testing.expect(t, bar.h < ctx.theme.target)
	// Just above the bar, inside the second segment's touch target: a finger landing
	// there presses the segment, and the viewport never sees it (a tap there used to
	// turn the camera by however much the finger wobbled).
	edge := [2]f32{bar.x + 120, bar.y - 3}
	short_bar(&ctx, input_at(edge, down = {.Left}, pressed = {.Left}))
	testing.expect(t, !viewport_dragging(&ctx))
	testing.expect(t, wants_pointer(&ctx))
	picked, _ := short_bar(&ctx, input_at(edge, released = {.Left}))
	testing.expect_value(t, picked, 1)
	// Well outside every target is still the viewport's.
	short_bar(&ctx, input_at({bar.x + 120, bar.y - 30}, down = {.Left}, pressed = {.Left}))
	testing.expect(t, viewport_dragging(&ctx))
	short_bar(&ctx, input_at({bar.x + 120, bar.y - 30}, released = {.Left}))
}

// One frame of a drag-scrolled panel 200 points tall at (100, 100): eight 48 point
// buttons, then a slider. Returns the button clicked (-1 for none), whether the slider
// changed and whether a drag is scrolling the panel.
@(private = "file")
scroll_panel :: proc(ctx: ^Context, input: Input, scroll: ^f32, value: ^f32) -> (clicked: int, slid, dragging: bool) {
	frame_begin(ctx, input)
	id := id_of(ctx, "panel")
	_, natural := prev_layout(ctx, "panel")
	limit := max(natural.y - 200, 0)
	dragging = scroll_update(ctx, id, {100, 100, 240, 200}, scroll, limit)
	begin_anchored(ctx, "panel", .Start, .Start, {100, 100}, {direction = .Column, width = 240, height = 200, clip = true, scroll = scroll^, drag_scroll = true})
	clicked = -1
	names := [8]string{"b0", "b1", "b2", "b3", "b4", "b5", "b6", "b7"}
	for name, i in names do if button(ctx, name) do clicked = i
	slid = slider(ctx, "Size", value, 0, 1, .Linear, "")
	end(ctx)
	scroll_take(ctx, id, scroll^, limit)
	frame_end(ctx)
	return
}

@(private = "file")
finger_at :: proc(mouse: [2]f32, down: Buttons = {}, pressed: Buttons = {}, released: Buttons = {}) -> Input {
	in_ := input_at(mouse, down, pressed, released)
	in_.pointer = .Finger
	return in_
}

@(test)
the_first_finger_drag_on_a_control_scrolls_its_panel :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	scroll, value: f32 = 0, 0.5
	scroll_panel(&ctx, input_at({-1, -1}), &scroll, &value)
	scroll_panel(&ctx, input_at({-1, -1}), &scroll, &value)

	// The finger lands on the first button and goes straight up: within the slop
	// nothing moves; past it the panel takes the drag and follows from there.
	on_b0 := [2]f32{200, 124}
	scroll_panel(&ctx, finger_at(on_b0, down = {.Left}, pressed = {.Left}), &scroll, &value)
	testing.expect(t, wants_pointer(&ctx))
	scroll_panel(&ctx, finger_at(on_b0 - {0, 6}, down = {.Left}), &scroll, &value)
	testing.expect_value(t, scroll, 0)
	_, _, dragging := scroll_panel(&ctx, finger_at(on_b0 - {0, 20}, down = {.Left}), &scroll, &value)
	testing.expect(t, dragging)
	testing.expect_value(t, scroll, 0)
	scroll_panel(&ctx, finger_at(on_b0 - {0, 80}, down = {.Left}), &scroll, &value)
	testing.expect_value(t, scroll, 60)
	// Letting go over another button clicks nothing: the scroll took the press.
	clicked, _, _ := scroll_panel(&ctx, finger_at(on_b0 - {0, 80}, released = {.Left}), &scroll, &value)
	testing.expect_value(t, clicked, -1)
	testing.expect(t, !viewport_dragging(&ctx))

	// A tap that wobbles less than the slop is still a click, of the button now there.
	at := [2]f32{200, 140}
	scroll_panel(&ctx, finger_at(at, down = {.Left}, pressed = {.Left}), &scroll, &value)
	scroll_panel(&ctx, finger_at(at + {2, -4}, down = {.Left}), &scroll, &value)
	clicked, _, _ = scroll_panel(&ctx, finger_at(at + {2, -4}, released = {.Left}), &scroll, &value)
	testing.expect_value(t, clicked, 2) // 60 scrolled: the third button spans y 136 to 184
	testing.expect_value(t, scroll, 60)
}

@(test)
a_mouse_drag_on_a_control_never_scrolls :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	scroll, value: f32 = 0, 0.5
	scroll_panel(&ctx, input_at({-1, -1}), &scroll, &value)
	scroll_panel(&ctx, input_at({-1, -1}), &scroll, &value)
	on_b0 := [2]f32{200, 124}
	scroll_panel(&ctx, input_at(on_b0, down = {.Left}, pressed = {.Left}), &scroll, &value)
	_, _, dragging := scroll_panel(&ctx, input_at(on_b0 - {0, 80}, down = {.Left}), &scroll, &value)
	testing.expect(t, !dragging)
	testing.expect_value(t, scroll, 0)
	scroll_panel(&ctx, input_at(on_b0 - {0, 80}, released = {.Left}), &scroll, &value)
	// The wheel still scrolls it.
	in_ := input_at({200, 200})
	in_.wheel = -1
	scroll_panel(&ctx, in_, &scroll, &value)
	testing.expect_value(t, scroll, 64)
}

@(test)
a_slider_in_a_scrolled_panel_takes_sideways_drags_only :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	scroll, value: f32 = 0, 0.5
	scroll_panel(&ctx, input_at({-1, -1}), &scroll, &value)
	scroll_panel(&ctx, input_at({-1, -1}), &scroll, &value)
	// Scroll to the bottom so the slider shows: 8 * 48 + 52, less 200.
	in_ := input_at({200, 200})
	in_.wheel = -10
	scroll_panel(&ctx, in_, &scroll, &value)
	limit := scroll
	testing.expect(t, limit > 0)
	// The slider's track is 34 points under its top, which sits at 8 * 48 less the scroll.
	on_track := [2]f32{220, 100 + 8 * 48 - limit + 36}

	// Up and down from the slider scrolls the panel and leaves the value alone.
	scroll_panel(&ctx, finger_at(on_track, down = {.Left}, pressed = {.Left}), &scroll, &value)
	scroll_panel(&ctx, finger_at(on_track + {3, 30}, down = {.Left}), &scroll, &value)
	_, slid, dragging := scroll_panel(&ctx, finger_at(on_track + {3, 60}, down = {.Left}), &scroll, &value)
	testing.expect(t, dragging && !slid)
	testing.expect_value(t, value, 0.5)
	testing.expect_value(t, scroll, limit - 30)
	scroll_panel(&ctx, finger_at(on_track + {3, 60}, released = {.Left}), &scroll, &value)
	testing.expect_value(t, value, 0.5)
	scroll = limit
	scroll_panel(&ctx, input_at({-1, -1}), &scroll, &value)

	// Sideways it moves the value and the panel stays put.
	scroll_panel(&ctx, finger_at(on_track, down = {.Left}, pressed = {.Left}), &scroll, &value)
	_, slid, _ = scroll_panel(&ctx, finger_at(on_track + {4, 0}, down = {.Left}), &scroll, &value)
	testing.expect(t, !slid)
	_, slid, dragging = scroll_panel(&ctx, finger_at(on_track + {40, 12}, down = {.Left}), &scroll, &value)
	testing.expect(t, slid && !dragging)
	testing.expect(t, value > 0.5)
	testing.expect_value(t, scroll, limit)
	scroll_panel(&ctx, finger_at(on_track + {40, 12}, released = {.Left}), &scroll, &value)

	// A tap puts the value where it landed.
	left := [2]f32{101, on_track.y}
	scroll_panel(&ctx, finger_at(left, down = {.Left}, pressed = {.Left}), &scroll, &value)
	scroll_panel(&ctx, finger_at(left, released = {.Left}), &scroll, &value)
	testing.expect_value(t, value, 0)
}

@(test)
a_cancelled_press_lets_go_without_a_click :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	_, _, column := two_buttons(&ctx, input_at({-1, -1}))
	_, _, column = two_buttons(&ctx, input_at({-1, -1}))
	over_a := [2]f32{column.x + 28, column.y + 28}
	two_buttons(&ctx, finger_at(over_a, down = {.Left}, pressed = {.Left}))
	cancelled := finger_at(over_a, released = {.Left})
	cancelled.cancel = true
	a, b, _ := two_buttons(&ctx, cancelled)
	testing.expect(t, !a && !b)
	testing.expect_value(t, ctx.active, 0)
}

@(test)
a_scrolled_out_control_reaches_no_further_than_its_panel :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	scroll, value: f32 = 0, 0.5
	scroll_panel(&ctx, input_at({-1, -1}), &scroll, &value)
	scroll_panel(&ctx, input_at({-1, -1}), &scroll, &value)
	// The buttons below the panel's 200 points are clipped out: a press under the panel
	// is the viewport's.
	scroll_panel(&ctx, input_at({200, 320}, down = {.Left}, pressed = {.Left}), &scroll, &value)
	testing.expect(t, viewport_dragging(&ctx))
	scroll_panel(&ctx, input_at({200, 320}, released = {.Left}), &scroll, &value)
}

@(test)
fingers_make_a_tap_only_quick_still_and_not_cancelled :: proc(t: ^testing.T) {
	f: Fingers
	testing.expect(t, fingers_down(&f, 1, {100, 100}, 0))
	testing.expect(t, !fingers_down(&f, 2, {200, 100}, 0.01))
	testing.expect(t, !fingers_down(&f, 2, {200, 100}, 0.01)) // already down
	tap, known := fingers_up(&f, 1, 0.1)
	testing.expect(t, known && tap == 0) // one is still down
	tap, known = fingers_up(&f, 2, 0.12)
	testing.expect_value(t, tap, 2)
	_, known = fingers_up(&f, 7, 0.13)
	testing.expect(t, !known)

	// Too slow, too far, or cancelled: no tap.
	_ = fingers_down(&f, 1, {100, 100}, 1)
	tap, _ = fingers_up(&f, 1, 1 + FINGER_TAP + 0.01)
	testing.expect_value(t, tap, 0)
	_ = fingers_down(&f, 1, {100, 100}, 2)
	fingers_move(&f, 1, {100 + FINGER_TAP_TRAVEL + 1, 100})
	fingers_move(&f, 1, {100, 100}) // coming back does not undo the travel
	tap, _ = fingers_up(&f, 1, 2.05)
	testing.expect_value(t, tap, 0)
	_ = fingers_down(&f, 1, {100, 100}, 3)
	tap, _ = fingers_up(&f, 1, 3.05, cancelled = true)
	testing.expect_value(t, tap, 0)
}

@(test)
fingers_measure_pan_spread_and_twist :: proc(t: ^testing.T) {
	f: Fingers
	_ = fingers_down(&f, 1, {100, 100}, 0)
	_ = fingers_down(&f, 2, {200, 100}, 0)
	first := fingers_change(&f)
	// The first measure after a finger came only says where they are.
	testing.expect_value(t, first.pan, [2]f32{0, 0})
	testing.expect_value(t, first.zoom, 1)
	testing.expect_value(t, first.middle, [2]f32{150, 100})

	// Both move right 30: a pan, no zoom, no twist.
	fingers_move(&f, 1, {130, 100})
	fingers_move(&f, 2, {230, 100})
	c := fingers_change(&f)
	testing.expect_value(t, c.pan, [2]f32{30, 0})
	testing.expect(t, abs(c.zoom - 1) < 1e-5 && abs(c.twist) < 1e-5)

	// Spreading to twice as far apart about the same middle zooms 2 times.
	fingers_move(&f, 1, {80, 100})
	fingers_move(&f, 2, {280, 100})
	c = fingers_change(&f)
	testing.expect(t, abs(c.zoom - 2) < 1e-4)
	testing.expect(t, abs(c.pan.x) < 1e-4)

	// The second finger going round below the first is a clockwise twist (y is down).
	fingers_move(&f, 2, {180, 200})
	c = fingers_change(&f)
	testing.expect(t, abs(c.twist - math.PI / 4) < 1e-4)

	// Crossing the half turn is the short way round, not a whole turn back.
	fingers_move(&f, 2, {80 - 100, 100 + 1})
	_ = fingers_change(&f)
	fingers_move(&f, 2, {80 - 100, 100 - 1})
	c = fingers_change(&f)
	testing.expect(t, abs(c.twist) < 0.1)

	// A finger lifting starts the measure afresh: no jump from the one left.
	_, _ = fingers_up(&f, 2, 0.5)
	c = fingers_change(&f)
	testing.expect_value(t, c.pan, [2]f32{0, 0})
}

@(test)
fingers_past_the_most_are_ignored :: proc(t: ^testing.T) {
	f: Fingers
	for i in 0 ..< FINGERS_MAX do _ = fingers_down(&f, u64(i), {f32(i) * 10, 0}, 0)
	testing.expect(t, !fingers_down(&f, 99, {500, 0}, 0))
	testing.expect_value(t, f.count, FINGERS_MAX)
	_, known := fingers_up(&f, 99, 0.1)
	testing.expect(t, !known)
	fingers_clear(&f)
	testing.expect_value(t, f.count, 0)
	testing.expect(t, fingers_down(&f, 5, {0, 0}, 1))
}

// One frame of a window 300 points wide, 20 points in from the top right of an 800 by
// 600 window (`size` for another), with a button in its body. Returns what was done and
// where the window ended up.
@(private = "file")
one_window :: proc(ctx: ^Context, input: Input, w: ^Window, size := [2]f32{800, 600}) -> (closed, raised, inside: bool, rect: Rect) {
	input := input
	input.window = size
	frame_begin(ctx, input)
	body: bool
	body, closed, raised = window_begin(ctx, "win", "Window", w, .End, .Start, {20, 20}, {direction = .Column, padding = 10, width = 300, background = .Panel})
	if body do inside = icon_button(ctx, "inside", ICON_UNDO)
	window_end(ctx)
	frame_end(ctx)
	rect = ctx.placed[len(ctx.placed) - 1].rect
	return
}

// Where to hold a window's title bar: over its title, clear of its buttons.
@(private = "file")
title_of :: proc(r: Rect) -> [2]f32 {
	return {r.x + 60, r.y + 10 + 24}
}

@(test)
a_window_dragged_by_its_title_keeps_to_the_nearer_edges :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	w: Window
	_, _, _, r := one_window(&ctx, input_at({-1, -1}), &w)
	_, _, _, r = one_window(&ctx, input_at({-1, -1}), &w)
	testing.expect_value(t, r.x, 800 - 20 - 300)
	testing.expect_value(t, r.y, 20)

	// Down and to the left, past the slop, then on: the window follows the pointer exactly.
	at := title_of(r)
	one_window(&ctx, input_at(at, down = {.Left}, pressed = {.Left}), &w)
	one_window(&ctx, input_at(at + {-20, 20}, down = {.Left}), &w)
	_, _, _, moved := one_window(&ctx, input_at(at + {-400, 300}, down = {.Left}), &w)
	testing.expect_value(t, moved.x, r.x - 400)
	testing.expect_value(t, moved.y, r.y + 300)
	_, _, inside, _ := one_window(&ctx, input_at(at + {-400, 300}, released = {.Left}), &w)
	testing.expect(t, !inside, "letting go of the title bar pressed a button")
	testing.expect(t, w.moved && !w.dragging && !w.minimized, "a drag left the window in the wrong state")
	// Its middle is on the left and its title bar in the bottom half.
	testing.expect_value(t, w.x, Anchor.Start)
	testing.expect_value(t, w.y, Anchor.End)
	_, _, _, still := one_window(&ctx, input_at({-1, -1}), &w)
	testing.expect_value(t, still, moved)

	// A larger window keeps it as far from the left and the bottom as it was.
	_, _, _, grown := one_window(&ctx, input_at({-1, -1}), &w, {1000, 700})
	testing.expect_value(t, grown.x, moved.x)
	testing.expect_value(t, 700 - (grown.y + grown.h), 600 - (moved.y + moved.h))
}

@(test)
a_window_dragged_off_the_screen_keeps_its_title_bar_inside :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	w: Window
	_, _, _, r := one_window(&ctx, input_at({-1, -1}), &w)
	_, _, _, r = one_window(&ctx, input_at({-1, -1}), &w)
	at := title_of(r)
	one_window(&ctx, input_at(at, down = {.Left}, pressed = {.Left}), &w)
	one_window(&ctx, input_at(at + {30, 30}, down = {.Left}), &w)
	_, _, _, gone := one_window(&ctx, input_at({2000, 2000}, down = {.Left}), &w)
	one_window(&ctx, input_at({2000, 2000}, released = {.Left}), &w)
	testing.expect_value(t, gone.x + gone.w, 800)
	testing.expect_value(t, gone.y, 600 - (2 * 10 + 48))
	// Then a smaller window: still there to take hold of.
	_, _, _, small := one_window(&ctx, input_at({-1, -1}), &w, {500, 400})
	testing.expect(t, small.x >= 0 && small.x + small.w <= 500 && small.y + 10 + 48 <= 400, "the title bar left a smaller window")
}

@(test)
minimise_folds_a_window_to_its_bar_and_a_tap_on_it_opens_it :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	w: Window
	_, _, _, r := one_window(&ctx, input_at({-1, -1}), &w)
	_, _, _, r = one_window(&ctx, input_at({-1, -1}), &w)
	// Minimise and Close sit at the bar's right end: 10 padding, then 48 each.
	minimise := [2]f32{r.x + r.w - 10 - 48 - 24, r.y + 10 + 24}
	body := [2]f32{r.x + 10 + 24, r.y + 10 + 48 + 24}
	one_window(&ctx, input_at(minimise, down = {.Left}, pressed = {.Left}), &w)
	one_window(&ctx, input_at(minimise, released = {.Left}), &w)
	testing.expect(t, w.minimized, "Minimise did not fold the window")
	_, _, _, folded := one_window(&ctx, input_at({-1, -1}), &w)
	testing.expect_value(t, folded.h, 2 * 10 + 48)
	testing.expect_value(t, folded.y, r.y)
	// Its body is gone: a press where its button was is the viewport's.
	_, _, inside, _ := one_window(&ctx, input_at(body, down = {.Left}, pressed = {.Left}), &w)
	one_window(&ctx, input_at(body, released = {.Left}), &w)
	testing.expect(t, !inside && !w.moved, "a folded window's body answered")
	// A tap on its title opens it again.
	one_window(&ctx, input_at(title_of(folded), down = {.Left}, pressed = {.Left}), &w)
	one_window(&ctx, input_at(title_of(folded), released = {.Left}), &w)
	testing.expect(t, !w.minimized && !w.moved, "a tap on the folded title did not open it")
}

@(test)
close_and_a_press_anywhere_on_a_window_are_reported :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	w: Window
	_, _, _, r := one_window(&ctx, input_at({-1, -1}), &w)
	_, _, _, r = one_window(&ctx, input_at({-1, -1}), &w)
	body := [2]f32{r.x + 10 + 24, r.y + 10 + 48 + 24}
	one_window(&ctx, input_at(body), &w)
	_, raised, _, _ := one_window(&ctx, input_at(body, down = {.Left}, pressed = {.Left}), &w)
	testing.expect(t, raised, "a press on the body did not raise the window")
	_, raised2, inside, _ := one_window(&ctx, input_at(body, released = {.Left}), &w)
	testing.expect(t, inside && !raised2, "the body's button did not click, or a release raised the window")
	close := [2]f32{r.x + r.w - 10 - 24, r.y + 10 + 24}
	one_window(&ctx, input_at(close, down = {.Left}, pressed = {.Left}), &w)
	closed, _, _, _ := one_window(&ctx, input_at(close, released = {.Left}), &w)
	testing.expect(t, closed, "Close was not reported")
}

@(test)
a_finger_on_a_title_bar_moves_its_window_after_the_slop :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	w: Window
	_, _, _, r := one_window(&ctx, finger_at({-1, -1}), &w)
	_, _, _, r = one_window(&ctx, finger_at({-1, -1}), &w)
	at := title_of(r)
	one_window(&ctx, finger_at(at, down = {.Left}, pressed = {.Left}), &w)
	// Within the slop it stays: a tap is not a drag.
	_, _, _, still := one_window(&ctx, finger_at(at + {6, 0}, down = {.Left}), &w)
	testing.expect_value(t, still, r)
	_, _, _, moved := one_window(&ctx, finger_at(at + {-200, 100}, down = {.Left}), &w)
	one_window(&ctx, finger_at(at + {-200, 100}, released = {.Left}), &w)
	testing.expect_value(t, moved.x, r.x - 200)
	testing.expect_value(t, moved.y, r.y + 100)
	testing.expect(t, !ctx.viewport_drag, "the drag reached the viewport")
}

// A folded More returns false; opened, it grows in and fills a body; with `always` the
// body shows at once. The row itself is not counted as a control.
@(test)
more_folds_and_always_shows :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	frame :: proc(ctx: ^Context, open: ^bool, always: bool) -> (body: bool, controls: int) {
		frame_begin(ctx, input_at({-1, -1}))
		begin_anchored(ctx, "column", .Start, .Start, {0, 0}, {direction = .Column, width = 300})
		before := ctx.controls
		if more(ctx, "more", open, always) {
			body = true
			_ = button(ctx, "inside")
			more_end(ctx)
		}
		controls = ctx.controls - before
		end(ctx)
		frame_end(ctx)
		return
	}
	open := false
	body, controls := frame(&ctx, &open, false)
	testing.expect(t, !body)
	testing.expect_value(t, controls, 0)
	// Opened, it grows in over the panel motion's time.
	open = true
	for _ in 0 ..< 30 do body, controls = frame(&ctx, &open, false)
	testing.expect(t, body)
	testing.expect_value(t, controls, 1)
	closed := false
	body, controls = frame(&ctx, &closed, true)
	testing.expect(t, body && !closed)
	testing.expect_value(t, controls, 1)
}

// A list taller than the window is cut to fit it, opens with its chosen option in view,
// and a drag scrolls it without picking.
@(test)
a_long_select_list_fits_the_window_and_scrolls :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	options: [30]string
	for &o, i in options do o = "Option ab" if i % 2 == 0 else "Option cd"
	picked := -1
	frame := proc(ctx: ^Context, input: Input, options: []string, picked: ^int) {
		frame_begin(ctx, input)
		begin_anchored(ctx, "column", .Start, .Start, {0, 100}, {width = 200})
		if p := select(ctx, "many", options, 20); p >= 0 do picked^ = p
		end(ctx)
		frame_end(ctx)
	}
	field := [2]f32{100, 124}
	frame(&ctx, input_at(field), options[:], &picked)
	frame(&ctx, input_at(field, down = {.Left}, pressed = {.Left}), options[:], &picked)
	frame(&ctx, input_at(field, released = {.Left}), options[:], &picked)
	for _ in 0 ..< 30 do frame(&ctx, input_at({-1, -1}), options[:], &picked)
	list: Rect
	ctx.id_seed = ctx.select_id
	list_id := id_of(&ctx, "select list")
	ctx.id_seed = 0
	for p in ctx.placed do if p.id == list_id do list = p.rect
	testing.expect(t, list.h > 0 && list.y >= 4 && list.y + list.h <= 600 - 4)
	row := ctx.theme.target - 4
	// Option 20 is in view: its row is inside the list.
	at := 20 * row - ctx.select_scroll
	testing.expect(t, at >= 0 && at + row <= list.h)
	before := ctx.select_scroll
	// A drag up the list scrolls it down, and picks nothing.
	start := [2]f32{list.x + 60, list.y + list.h * 0.5}
	finger :: proc(at: [2]f32, down: Buttons = {}, pressed: Buttons = {}, released: Buttons = {}) -> Input {
		in_ := input_at(at, down, pressed, released)
		in_.pointer = .Finger
		return in_
	}
	frame(&ctx, finger(start, down = {.Left}, pressed = {.Left}), options[:], &picked)
	for i in 1 ..= 10 do frame(&ctx, finger(start - {0, f32(i) * 8}, down = {.Left}), options[:], &picked)
	frame(&ctx, finger(start - {0, 80}, released = {.Left}), options[:], &picked)
	testing.expect(t, ctx.select_scroll > before)
	testing.expect_value(t, picked, -1)
	testing.expect(t, ctx.select_open != 0)
}
