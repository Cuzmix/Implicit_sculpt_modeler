package ui

import "core:testing"

// A finger at `mouse` on an 800 by 600 window, `dt` seconds after the last frame.
@(private = "file")
touch :: proc(mouse: [2]f32, down: Buttons = {}, pressed: Buttons = {}, released: Buttons = {}, pointer := Pointer_Kind.Finger) -> Input {
	return {mouse = mouse, mouse_valid = true, down = down, pressed = pressed, released = released, window = {800, 600}, pixel_density = 1, dt = 1.0 / 60, pointer = pointer}
}

Long_Frame :: struct {
	act, act_secondary:   bool, // "act" has a secondary action
	off_secondary:        bool, // secondary called after a disabled button
	tipped, plain:        bool, // "tipped" has a tooltip only, "plain" neither
	at:                   [4][2]f32, // the middles of act, off, tipped and plain
}

// One frame of a column at the top left: "act" (with a secondary action when `claim`),
// a disabled button, "tipped" (a tooltip, no secondary action) and "plain" (neither).
@(private = "file")
long_frame :: proc(ctx: ^Context, input: Input, claim := true) -> (f: Long_Frame) {
	frame_begin(ctx, input)
	begin_anchored(ctx, "column", .Start, .Start, {16, 16}, {direction = .Column})
	f.act = icon_button(ctx, "act", ICON_UNDO)
	f.at[0] = middle(ctx.last_rect)
	if claim do f.act_secondary = secondary(ctx)
	_ = icon_button(ctx, "off", ICON_REDO, enabled = false)
	f.at[1] = middle(ctx.last_rect)
	f.off_secondary = secondary(ctx)
	f.tipped = icon_button(ctx, "tipped", ICON_MENU)
	f.at[2] = middle(ctx.last_rect)
	f.plain = button(ctx, "plain")
	f.at[3] = middle(ctx.last_rect)
	end(ctx)
	frame_end(ctx)
	return
}

@(private = "file")
middle :: proc(r: Rect) -> [2]f32 {return {r.x + r.w * 0.5, r.y + r.h * 0.5}}

// Lays the column out and returns where its widgets are.
@(private = "file")
long_setup :: proc(ctx: ^Context) -> [4][2]f32 {
	_ = long_frame(ctx, touch({-1, -1}))
	return long_frame(ctx, touch({-1, -1})).at
}

// Presses at `p` and holds it still for `frames` frames, then lets go there. Returns how
// many frames the secondary action fired on and whether the release clicked.
@(private = "file")
hold :: proc(ctx: ^Context, p: [2]f32, frames: int, pointer := Pointer_Kind.Finger, claim := true) -> (fired: int, clicked, tipped, plain: bool) {
	f := long_frame(ctx, touch(p, {.Left}, {.Left}, pointer = pointer), claim)
	fired += int(f.act_secondary)
	for _ in 1 ..< frames {
		f = long_frame(ctx, touch(p, {.Left}, pointer = pointer), claim)
		fired += int(f.act_secondary)
		testing.expect(nil, !f.off_secondary)
	}
	f = long_frame(ctx, touch(p, released = {.Left}, pointer = pointer), claim)
	return fired, f.act, f.tipped, f.plain
}

// The theme's long press, 0.25 s, is 15 frames at 60 a second.
LONG_FRAMES :: 30

@(test)
a_long_press_runs_the_secondary_action_once_and_never_clicks :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	at := long_setup(&ctx)
	fired, clicked, _, _ := hold(&ctx, at[0], LONG_FRAMES)
	testing.expect_value(t, fired, 1)
	testing.expect(t, !clicked)
	// A press held 0.2 s is still a tap.
	fired, clicked, _, _ = hold(&ctx, at[0], 12)
	testing.expect_value(t, fired, 0)
	testing.expect(t, clicked)
	// So is a long press by the pen; the mouse's left button never long-presses.
	fired, _, _, _ = hold(&ctx, at[0], LONG_FRAMES, .Pen)
	testing.expect_value(t, fired, 1)
	fired, clicked, _, _ = hold(&ctx, at[0], LONG_FRAMES, .Mouse)
	testing.expect_value(t, fired, 0)
	testing.expect(t, clicked)
}

@(test)
a_press_that_strays_past_the_slop_is_no_long_press :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	at := long_setup(&ctx)
	p := at[0]
	f := long_frame(&ctx, touch(p, {.Left}, {.Left}))
	f = long_frame(&ctx, touch(p + {0, 15}, {.Left}))
	fired := 0
	for _ in 0 ..< LONG_FRAMES {
		f = long_frame(&ctx, touch(p, {.Left}))
		fired += int(f.act_secondary)
	}
	testing.expect_value(t, fired, 0)
	f = long_frame(&ctx, touch(p, released = {.Left}))
	testing.expect(t, f.act)
}

// The right button (a mouse's, or a pen's side button) pressed and let go on a widget
// runs its secondary action; pressed on one and let go on another, nothing.
@(test)
a_right_click_runs_the_secondary_action_on_the_widget_it_began_on :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	at := long_setup(&ctx)
	_ = long_frame(&ctx, touch(at[0], {.Right}, {.Right}, pointer = .Mouse))
	f := long_frame(&ctx, touch(at[0], released = {.Right}, pointer = .Mouse))
	testing.expect(t, f.act_secondary && !f.act)
	_ = long_frame(&ctx, touch(at[2], {.Right}, {.Right}, pointer = .Mouse))
	_ = long_frame(&ctx, touch(at[0], {.Right}, pointer = .Mouse))
	f = long_frame(&ctx, touch(at[0], released = {.Right}, pointer = .Mouse))
	testing.expect(t, !f.act_secondary)
}

// A long press on a widget with a tooltip and no secondary action shows the tooltip
// while held, and does not click; one with neither does nothing, and clicks. The
// disabled widget laid out after "act" is never what secondary acts on.
@(test)
a_long_press_without_a_secondary_action_shows_the_tooltip :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	at := long_setup(&ctx)
	_, _, tipped, _ := hold(&ctx, at[2], LONG_FRAMES)
	testing.expect(t, !tipped)
	shown, _ := long_tip_shown(&ctx)
	testing.expect_value(t, shown, "tipped")
	_, _, _, plain := hold(&ctx, at[3], LONG_FRAMES)
	testing.expect(t, plain)
	// "act" without its secondary call: the disabled button's call after it must not
	// take its long press, which shows act's tooltip instead.
	fired, clicked, _, _ := hold(&ctx, at[0], LONG_FRAMES, claim = false)
	testing.expect_value(t, fired, 0)
	testing.expect(t, !clicked)
	acted, _ := long_tip_shown(&ctx)
	testing.expect_value(t, acted, "act")
}

@(private = "file")
reset_slider :: proc(ctx: ^Context, input: Input, value: ^f32) -> bool {
	frame_begin(ctx, input)
	begin_anchored(ctx, "sliders", .Start, .Start, {16, 16}, {})
	changed := vslider(ctx, "Strength", value, 0, 1, .Linear, "", track = 300, reset = 0.5)
	end(ctx)
	frame_end(ctx)
	return changed
}

// A long press on a slider with a reset value puts it back; a slow drag (a pen's fine
// adjustment, under the slop) moves it and never resets it.
@(test)
a_slider_resets_on_a_long_press_but_not_in_a_slow_drag :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	value: f32 = 0.9
	reset_slider(&ctx, touch({-1, -1}), &value)
	reset_slider(&ctx, touch({-1, -1}), &value)
	p := [2]f32{38, 180}
	reset_slider(&ctx, touch(p, {.Left}, {.Left}), &value)
	for _ in 0 ..< LONG_FRAMES do reset_slider(&ctx, touch(p, {.Left}), &value)
	testing.expect_value(t, value, 0.5)
	// Held on and dragged up 30 points of 300: from the reset value.
	reset_slider(&ctx, touch(p - {0, 30}, {.Left}), &value)
	testing.expect(t, abs(value - 0.6) < 1e-5)
	reset_slider(&ctx, touch(p - {0, 30}, released = {.Left}), &value)

	value = 0.9
	reset_slider(&ctx, touch(p, {.Left}, {.Left}), &value)
	for i in 0 ..< LONG_FRAMES {
		q := p - {0, f32(i) * 0.2}
		reset_slider(&ctx, touch(q, {.Left}), &value)
	}
	testing.expect(t, value > 0.9)
	reset_slider(&ctx, touch(p, released = {.Left}), &value)
}

// One frame of a drag-scrolled panel at (100, 100), 200 points tall, of ten icon
// buttons: the first with a secondary action, the second with only its tooltip.
@(private = "file")
long_panel :: proc(ctx: ^Context, input: Input, scroll: ^f32) -> (fired: bool, dragging: bool) {
	frame_begin(ctx, input)
	id := id_of(ctx, "panel")
	_, natural := prev_layout(ctx, "panel")
	dragging = scroll_update(ctx, id, {100, 100, 240, 200}, scroll, max(natural.y - 200, 0))
	begin_anchored(ctx, "panel", .Start, .Start, {100, 100}, {direction = .Column, width = 240, height = 200, clip = true, scroll = scroll^, drag_scroll = true})
	names := [10]string{"p0", "p1", "p2", "p3", "p4", "p5", "p6", "p7", "p8", "p9"}
	for name, i in names {
		_ = icon_button(ctx, name, ICON_MENU)
		if i == 0 do fired = secondary(ctx)
	}
	end(ctx)
	frame_end(ctx)
	return
}

// Once a long press ran an action, dragging on does not scroll the panel under what it
// opened; after a long press that only showed a tooltip, it does.
@(test)
a_long_press_action_keeps_the_press_from_the_scroll :: proc(t: ^testing.T) {
	for which in 0 ..< 2 {
		ctx: Context
		init(&ctx)
		defer destroy(&ctx)
		scroll: f32
		long_panel(&ctx, touch({-1, -1}), &scroll)
		long_panel(&ctx, touch({-1, -1}), &scroll)
		p := [2]f32{124, 124 + f32(which) * 48}
		long_panel(&ctx, touch(p, {.Left}, {.Left}), &scroll)
		fired := false
		for _ in 0 ..< LONG_FRAMES {
			f, _ := long_panel(&ctx, touch(p, {.Left}), &scroll)
			fired ||= f
		}
		testing.expect_value(t, fired, which == 0)
		dragging := false
		for i in 1 ..= 10 {
			_, d := long_panel(&ctx, touch(p - {0, f32(i) * 5}, {.Left}), &scroll)
			dragging ||= d
		}
		testing.expectf(t, dragging == (which == 1), "button %d: scrolled %v", which, dragging)
		long_panel(&ctx, touch(p, released = {.Left}), &scroll)
	}
}

// A press its widget used for a drag of its own (press_used) runs no secondary action
// however long it is then held, and letting go on the widget is no click.
@(test)
a_used_press_neither_long_presses_nor_clicks :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	at := long_setup(&ctx)
	p := at[0]
	used_frame :: proc(ctx: ^Context, input: Input, use: bool) -> (clicked, fired: bool) {
		frame_begin(ctx, input)
		begin_anchored(ctx, "column", .Start, .Start, {16, 16}, {direction = .Column})
		clicked = icon_button(ctx, "act", ICON_UNDO)
		if use do press_used(ctx)
		fired = secondary(ctx)
		end(ctx)
		frame_end(ctx)
		return
	}
	_, _ = used_frame(&ctx, touch(p, {.Left}, {.Left}), false)
	_, _ = used_frame(&ctx, touch(p, {.Left}), true)
	fired := 0
	for _ in 0 ..< LONG_FRAMES {
		_, f := used_frame(&ctx, touch(p, {.Left}), false)
		fired += int(f)
	}
	clicked, _ := used_frame(&ctx, touch(p, released = {.Left}), false)
	testing.expect_value(t, fired, 0)
	testing.expect(t, !clicked)
}
