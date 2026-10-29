package main

import "core:math"
import "core:os"
import "core:testing"

import "../camera"
import "../ui"

// A quick tap that stayed put latches; a long hold, a hold a press was made with, a
// finger that wandered, or a cancelled one acts only while held; a tap on a latched
// button lets it go.
@(test)
rail_taps_latch_and_holds_do_not :: proc(t: ^testing.T) {
	SLOP :: 10
	r: Modifier_Rail
	testing.expect(t, rail_finger_down(&r, 7, .Invert, {0, 0}, 1.0))
	testing.expect_value(t, rail_mods(&r), Modifiers{.Invert})
	testing.expect(t, rail_finger_up(&r, 7, 1.1, false, SLOP))
	testing.expect_value(t, r.latched, Modifiers{.Invert})

	// Held past the tap's time: only while held.
	_ = rail_finger_down(&r, 8, .Smooth, {0, 0}, 2.0)
	testing.expect_value(t, rail_mods(&r), Modifiers{.Invert, .Smooth})
	_ = rail_finger_up(&r, 8, 2.5, false, SLOP)
	testing.expect_value(t, r.latched, Modifiers{.Invert})

	// Quick, but a press on the viewport went down while it was held.
	_ = rail_finger_down(&r, 9, .Smooth, {0, 0}, 3.0)
	r.fingers[0].used = true
	_ = rail_finger_up(&r, 9, 3.1, false, SLOP)
	testing.expect_value(t, r.latched, Modifiers{.Invert})

	// Quick, but it slid off further than the slop.
	_ = rail_finger_down(&r, 12, .Smooth, {100, 100}, 3.5)
	testing.expect(t, rail_finger_move(&r, 12, {100, 120}, 10))
	testing.expect(t, rail_finger_move(&r, 12, {100, 101}, 10))
	_ = rail_finger_up(&r, 12, 3.6, false, SLOP)
	testing.expect_value(t, r.latched, Modifiers{.Invert})

	// Cancelled by the system.
	_ = rail_finger_down(&r, 10, .Mask, {0, 0}, 4.0)
	_ = rail_finger_up(&r, 10, 4.05, true, SLOP)
	testing.expect_value(t, r.latched, Modifiers{.Invert})

	// A finger the rail never had is not its to move or release.
	testing.expect(t, !rail_finger_move(&r, 99, {0, 0}, 10))
	testing.expect(t, !rail_finger_up(&r, 99, 5, false, SLOP))

	// Tapped again: let go.
	_ = rail_finger_down(&r, 11, .Invert, {0, 0}, 6.0)
	_ = rail_finger_up(&r, 11, 6.1, false, SLOP)
	testing.expect_value(t, r.latched, Modifiers{})
	testing.expect_value(t, r.count, 0)
}

// A finger whose lift never came is dropped when its id comes down again, and a fifth
// finger on a full rail is refused.
@(test)
rail_fingers_stay_few_and_fresh :: proc(t: ^testing.T) {
	r: Modifier_Rail
	_ = rail_finger_down(&r, 1, .Smooth, {0, 0}, 1)
	_ = rail_finger_down(&r, 1, .Mask, {0, 0}, 2)
	testing.expect_value(t, r.count, 1)
	testing.expect_value(t, rail_mods(&r), Modifiers{.Mask})
	for id in u64(2) ..= 4 do testing.expect(t, rail_finger_down(&r, id, .Invert, {0, 0}, 3))
	testing.expect(t, !rail_finger_down(&r, 5, .Hide, {0, 0}, 3))
	testing.expect_value(t, rail_mods(&r), Modifiers{.Mask, .Invert})
	rail_forget(&r)
	testing.expect_value(t, rail_mods(&r), Modifiers{})
}

// Smooth and Mask latched together are Hide; Hide latched lets them go and either lets
// Hide go; Invert goes with any of them.
@(test)
rail_modes_take_turns :: proc(t: ^testing.T) {
	r: Modifier_Rail
	rail_toggle(&r, .Invert)
	rail_toggle(&r, .Smooth)
	testing.expect_value(t, rail_mode(r.latched), Maybe(Modifier)(.Smooth))
	rail_toggle(&r, .Mask)
	testing.expect_value(t, r.latched, Modifiers{.Invert, .Smooth, .Mask})
	testing.expect_value(t, rail_mode(r.latched), Maybe(Modifier)(.Hide))
	rail_toggle(&r, .Smooth)
	testing.expect_value(t, rail_mode(r.latched), Maybe(Modifier)(.Mask))
	rail_toggle(&r, .Hide)
	testing.expect_value(t, r.latched, Modifiers{.Invert, .Hide})
	rail_toggle(&r, .Smooth)
	testing.expect_value(t, r.latched, Modifiers{.Invert, .Smooth})
	testing.expect_value(t, rail_mode({.Invert}), nil)
	testing.expect_value(t, rail_mode({.Smooth, .Mask}), Maybe(Modifier)(.Hide))
}

// Smooth and Mask held together by two fingers press as Hide; either alone presses as
// itself.
@(test)
rail_two_fingers_hide :: proc(t: ^testing.T) {
	r: Modifier_Rail
	_ = rail_finger_down(&r, 1, .Smooth, {0, 0}, 1)
	mods, held := rail_press_mods(&r)
	testing.expect_value(t, mods, Modifiers{.Smooth})
	testing.expect(t, held)
	_ = rail_finger_down(&r, 2, .Mask, {0, 0}, 1)
	mods, _ = rail_press_mods(&r)
	testing.expect_value(t, mods, Modifiers{.Hide})
	_ = rail_finger_up(&r, 1, 9, false, 10)
	mods, _ = rail_press_mods(&r)
	testing.expect_value(t, mods, Modifiers{.Mask})
}

// The wheel's sectors by angle round its middle, clockwise from the top; the grip and
// the corners outside the ring are none of them.
@(test)
wheel_sectors_by_angle :: proc(t: ^testing.T) {
	c := [2]f32{100, 100}
	testing.expect_value(t, ui.wheel_sector_at(c, {100, 50}, 132, 44), 0)
	testing.expect_value(t, ui.wheel_sector_at(c, {150, 100}, 132, 44), 1)
	testing.expect_value(t, ui.wheel_sector_at(c, {100, 150}, 132, 44), 2)
	testing.expect_value(t, ui.wheel_sector_at(c, {50, 100}, 132, 44), 3)
	testing.expect_value(t, ui.wheel_sector_at(c, {105, 100}, 132, 44), -1)
	testing.expect_value(t, ui.wheel_sector_at(c, {162, 162}, 132, 44), -1)
	r := Modifier_Rail{center = c, outer = 132, hole = 44}
	m, ok := rail_hit(&r, DIAL_DEFAULT, {100, 50})
	testing.expect(t, ok && m == .Smooth)
	m, ok = rail_hit(&r, DIAL_DEFAULT, {50, 100})
	testing.expect(t, ok && m == .Mask)
	_, ok = rail_hit(&r, DIAL_DEFAULT, {150, 100})
	testing.expect(t, !ok)
}

// A held button beats a latched one, the last held beats the others, and Invert goes
// with whichever mode is left.
@(test)
rail_press_prefers_the_newest_hold :: proc(t: ^testing.T) {
	r: Modifier_Rail
	rail_toggle(&r, .Mask)
	mods, held := rail_press_mods(&r)
	testing.expect_value(t, mods, Modifiers{.Mask})
	testing.expect(t, !held)
	_ = rail_finger_down(&r, 1, .Smooth, {0, 0}, 1)
	_ = rail_finger_down(&r, 2, .Hide, {0, 0}, 1)
	mods, held = rail_press_mods(&r)
	testing.expect_value(t, mods, Modifiers{.Hide})
	testing.expect(t, held)
	_ = rail_finger_up(&r, 2, 9, false, 10)
	_ = rail_finger_down(&r, 3, .Invert, {0, 0}, 1)
	mods, _ = rail_press_mods(&r)
	testing.expect_value(t, mods, Modifiers{.Smooth, .Invert})
}

// A press takes the rail's modifiers as it goes down and keeps them to its release,
// whatever fingers lift meanwhile; a key of the keyboard's own held at the press leaves
// the rail out of it.
@(test)
rail_press_keeps_what_it_took :: proc(t: ^testing.T) {
	a: App
	_ = rail_finger_down(&a.rail, 1, .Smooth, {0, 0}, 1)
	a.device.pressed, a.device.down = {.Left}, {.Left}
	input := Viewport_Input{primary = true}
	rail_press(&a, &input)
	testing.expect(t, input.smooth)
	testing.expect(t, a.rail.fingers[0].used)

	_ = rail_finger_up(&a.rail, 1, 1.05, false, 10)
	testing.expect_value(t, a.rail.latched, Modifiers{})
	a.device.pressed = {}
	input = {primary = true}
	rail_press(&a, &input)
	testing.expect(t, input.smooth)

	a.device.down = {}
	input = {}
	rail_press(&a, &input)
	testing.expect(t, !a.rail.press.active)

	rail_toggle(&a.rail, .Mask)
	a.device.pressed, a.device.down, a.device.ctrl = {.Left}, {.Left}, true
	input = {primary = true}
	rail_press(&a, &input)
	testing.expect(t, !input.mask && !input.mask_shape)
}

// The rail sets what the keyboard's modifiers would, as the design's table says.
@(test)
rail_presses_as_the_keyboard_would :: proc(t: ^testing.T) {
	Want :: struct {
		smooth, invert, alt, mask, mask_shape: bool,
	}
	cases := [?]struct {
		mods: Modifiers,
		want: Want,
	} {
		{{}, {}},
		{{.Smooth}, {smooth = true}},
		{{.Invert}, {invert = true}},
		{{.Smooth, .Invert}, {smooth = true, invert = true}},
		{{.Mask}, {mask = true, mask_shape = true}},
		{{.Mask, .Invert}, {mask = true, mask_shape = true, invert = true, alt = true}},
		{{.Hide}, {smooth = true, invert = true}},
		{{.Hide, .Invert}, {smooth = true, invert = true, alt = true}},
	}
	for c in cases {
		input := Viewport_Input{primary = true}
		rail_resolve(c.mods, &input)
		got := Want{input.smooth, input.invert, input.alt, input.mask, input.mask_shape}
		testing.expectf(t, got == c.want, "%v: %v, not %v", c.mods, got, c.want)
	}
	// Only a primary drag takes them.
	idle: Viewport_Input
	rail_resolve({.Hide, .Invert}, &idle)
	testing.expect(t, !idle.smooth && !idle.invert && !idle.alt && !idle.mask)
	testing.expect(t, rail_keeps_empty_space({.Mask}) && rail_keeps_empty_space({.Hide, .Invert}))
	testing.expect(t, !rail_keeps_empty_space({.Smooth, .Invert}))
	testing.expect_value(t, keyboard_mods(true, true), Modifiers{.Hide})
}

// A stroke made with the rail's Mask is saved as one, reads back as one, and a file of an
// older version that claims the flag is refused as damaged.
@(test)
strokes_keep_the_rail_mask :: proc(t: ^testing.T) {
	path := "build/rail_test.strokes"
	defer os.remove(path)
	a: App
	defer replay_destroy(&a.replay)
	defer results_destroy(&a)
	a.brush.radius_px = 40
	append(&a.replay.take.brushes, a.brush)
	append(&a.replay.take.seeds, 7)
	append(&a.replay.take.scales, 1)
	append(&a.replay.take.samples, Input_Sample{{10, 20}, 1, .Press, {}})
	append(&a.replay.take.frames, Take_Frame{count = 1, camera = camera.orbit_default(), size = {800, 600}, pen_roll = -30, primary = true, mask = true, invert = true})
	testing.expect(t, strokes_save(&a, path))

	b: App
	defer replay_destroy(&b.replay)
	defer results_destroy(&b)
	testing.expect(t, strokes_load(&b, path))
	testing.expect_value(t, len(b.replay.take.frames), 1)
	if len(b.replay.take.frames) == 1 {
		f := b.replay.take.frames[0]
		testing.expect(t, f.mask && f.invert && f.primary && !f.smooth)
		testing.expect_value(t, f.pen_roll, -30)
	}

	data, err := os.read_entire_file(path, context.allocator)
	testing.expect(t, err == nil)
	defer delete(data)
	data[len(STROKES_MAGIC)] = 2
	testing.expect(t, os.write_entire_file(path, data) == nil)
	testing.expect(t, !strokes_load(&b, path))
	free_all(context.temp_allocator)
}

// Smooth put down while a brush stroke is under way smooths the rest of the press, which
// makes the stroke a straight line, and lifting it then does not latch it; while no
// stroke is under way (an orbit, a Move drag) it latches as a tap as before.
@(test)
rail_smooth_mid_stroke_is_a_line_not_a_latch :: proc(t: ^testing.T) {
	SLOP :: 10
	app: App
	app.tool = .Brush
	app.device.pressed, app.device.down = {.Left}, {.Left}
	input := Viewport_Input{primary = true}
	rail_press(&app, &input)
	testing.expect(t, !input.smooth)
	app.device.pressed = {}
	app.stroke.active = true
	_ = rail_finger_down(&app.rail, 3, .Smooth, {0, 0}, 1.0)
	input = {primary = true}
	rail_press(&app, &input)
	testing.expect(t, input.smooth)
	_ = rail_finger_up(&app.rail, 3, 1.05, false, SLOP)
	testing.expect_value(t, app.rail.latched, Modifiers{})

	// No stroke under way: the tap latches.
	app.stroke.active = false
	_ = rail_finger_down(&app.rail, 4, .Smooth, {0, 0}, 2.0)
	input = {primary = true}
	rail_press(&app, &input)
	testing.expect(t, !input.smooth)
	_ = rail_finger_up(&app.rail, 4, 2.05, false, SLOP)
	testing.expect_value(t, app.rail.latched, Modifiers{.Smooth})
}

// Turned, the wheel's sectors turn with it: a quarter turn clockwise puts the first (Smooth)
// on the right.
@(test)
wheel_sectors_turn_with_the_wheel :: proc(t: ^testing.T) {
	c := [2]f32{100, 100}
	testing.expect_value(t, ui.wheel_sector_at(c, {150, 100}, 132, 44, math.PI / 2), 0)
	testing.expect_value(t, ui.wheel_sector_at(c, {100, 150}, 132, 44, math.PI / 2), 1)
	testing.expect_value(t, ui.wheel_sector_at(c, {100, 50}, 132, 44, -math.PI / 2), 1)
	r := Modifier_Rail{center = c, outer = 132, hole = 44, turn = math.PI / 2}
	m, ok := rail_hit(&r, DIAL_DEFAULT, {150, 100})
	testing.expect(t, ok && m == .Smooth)
}

// Two fingers on the wheel that spread or twist stop holding their sectors, latch nothing
// as they lift, and the gesture lasts until every finger is off; two held still still hold
// Smooth and Mask, which hide. A plain finger (on the pie's sector) holds nothing.
@(test)
wheel_two_fingers_resize_rather_than_hold :: proc(t: ^testing.T) {
	SLOP :: 10
	r: Modifier_Rail
	_ = rail_finger_down(&r, 1, .Smooth, {100, 50}, 1.0)
	_ = rail_finger_down(&r, 2, .Mask, {50, 100}, 1.0)
	testing.expect_value(t, rail_mods(&r), Modifiers{.Smooth, .Mask})
	mods, _ := rail_press_mods(&r)
	testing.expect_value(t, mods, Modifiers{.Hide})
	// Under twice the slop apart and a small turn: still holding.
	_ = rail_finger_move(&r, 1, {100, 45}, SLOP)
	testing.expect(t, !r.gesture)
	// Spread: the gesture, from the line between where they came down.
	_ = rail_finger_move(&r, 1, {100, 20}, SLOP)
	testing.expect(t, r.gesture && r.began)
	testing.expect_value(t, r.from, [2]f32{-50, 50})
	testing.expect_value(t, rail_mods(&r), Modifiers{})
	mods, _ = rail_press_mods(&r)
	testing.expect_value(t, mods, Modifiers{})
	_ = rail_finger_up(&r, 1, 1.1, false, SLOP)
	testing.expect(t, r.gesture)
	_ = rail_finger_up(&r, 2, 1.1, false, SLOP)
	testing.expect(t, !r.gesture)
	testing.expect_value(t, r.latched, Modifiers{})

	// A plain finger beside a modifier one: the modifier alone holds, and a quick lift of
	// the plain one latches nothing.
	_ = rail_finger_down(&r, 3, .Invert, {100, 150}, 2.0)
	_ = rail_finger_down(&r, 4, .Smooth, {150, 100}, 2.0, plain = true)
	testing.expect_value(t, rail_mods(&r), Modifiers{.Invert})
	_ = rail_finger_up(&r, 4, 2.05, false, SLOP)
	testing.expect_value(t, r.latched, Modifiers{})
	rail_forget(&r)
}

// The wheel's size snaps to the nearest by ratio, and its turn to whole steps within a
// half turn either way.
@(test)
wheel_size_and_turn_snap :: proc(t: ^testing.T) {
	testing.expect_value(t, wheel_size_nearest(132), Wheel_Size.Medium)
	testing.expect_value(t, wheel_size_nearest(60), Wheel_Size.Small)
	testing.expect_value(t, wheel_size_nearest(190), Wheel_Size.XL2)
	testing.expect_value(t, wheel_size_nearest(400), Wheel_Size.XL3)
	testing.expect_value(t, wheel_turn_snapped(44), 45)
	testing.expect_value(t, wheel_turn_snapped(-8), -15)
	testing.expect_value(t, wheel_turn_snapped(190), -165)
	testing.expect_value(t, wheel_turn_snapped(-185), -180)
}

// The pen's roll counts the short way round where its numbers wrap, and starts afresh
// with no jump from the first report.
@(test)
pen_roll_wraps_the_short_way :: proc(t: ^testing.T) {
	app: App
	pen_roll_take(&app, 170)
	testing.expect_value(t, app.pen_roll, 0)
	pen_roll_take(&app, -170)
	testing.expect_value(t, app.pen_roll, 20)
	pen_roll_take(&app, 170)
	testing.expect_value(t, app.pen_roll, 0)
	pen_roll_take(&app, 150)
	testing.expect_value(t, app.pen_roll, -20)
}

// The brush ring takes the reference app's cursor colours by what a press will do: red to
// sculpt, blue to smooth, yellow to mask, white to hide, pink inverted.
@(test)
brush_ring_colours_by_modifier :: proc(t: ^testing.T) {
	app: App
	app.kit.rail_side = .Left
	red := brush_ring_color(&app, false)
	testing.expect(t, red.r > 0.9 && red.g < 0.5 && red.b < 0.5)
	app.rail.latched = {.Smooth}
	blue := brush_ring_color(&app, false)
	testing.expect(t, blue.b > 0.9 && blue.r < 0.5)
	app.rail.latched = {.Mask}
	yellow := brush_ring_color(&app, true)
	testing.expect(t, yellow.r > 0.9 && yellow.g > 0.8 && yellow.b < 0.5 && yellow.a > red.a)
	app.rail.latched = {.Hide}
	testing.expect_value(t, brush_ring_color(&app, false).rgb, [3]f32{1, 1, 1})
	app.rail.latched = {.Invert}
	pink := brush_ring_color(&app, false)
	testing.expect(t, pink.r > 0.9 && pink.b > 0.8)
}
