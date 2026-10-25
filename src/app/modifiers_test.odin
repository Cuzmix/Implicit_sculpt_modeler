package main

import "core:os"
import "core:testing"

import "../camera"

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
	testing.expect(t, rail_finger_move(&r, 12, {100, 120}))
	testing.expect(t, rail_finger_move(&r, 12, {100, 101}))
	_ = rail_finger_up(&r, 12, 3.6, false, SLOP)
	testing.expect_value(t, r.latched, Modifiers{.Invert})

	// Cancelled by the system.
	_ = rail_finger_down(&r, 10, .Mask, {0, 0}, 4.0)
	_ = rail_finger_up(&r, 10, 4.05, true, SLOP)
	testing.expect_value(t, r.latched, Modifiers{.Invert})

	// A finger the rail never had is not its to move or release.
	testing.expect(t, !rail_finger_move(&r, 99, {0, 0}))
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

// Smooth, Mask and Hide are one at a time; Invert goes with any of them.
@(test)
rail_modes_take_turns :: proc(t: ^testing.T) {
	r: Modifier_Rail
	rail_toggle(&r, .Invert)
	rail_toggle(&r, .Smooth)
	rail_toggle(&r, .Mask)
	testing.expect_value(t, r.latched, Modifiers{.Invert, .Mask})
	rail_toggle(&r, .Hide)
	testing.expect_value(t, r.latched, Modifiers{.Invert, .Hide})
	testing.expect_value(t, rail_mode(r.latched), Maybe(Modifier)(.Hide))
	testing.expect_value(t, rail_mode({.Invert}), nil)
	testing.expect_value(t, rail_mode({.Smooth, .Mask}), Maybe(Modifier)(.Mask))
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
	append(&a.replay.take.samples, Input_Sample{{10, 20}, 1, .Press, {}})
	append(&a.replay.take.frames, Take_Frame{count = 1, camera = camera.orbit_default(), size = {800, 600}, primary = true, mask = true, invert = true})
	testing.expect(t, strokes_save(&a, path))

	b: App
	defer replay_destroy(&b.replay)
	defer results_destroy(&b)
	testing.expect(t, strokes_load(&b, path))
	testing.expect_value(t, len(b.replay.take.frames), 1)
	if len(b.replay.take.frames) == 1 {
		f := b.replay.take.frames[0]
		testing.expect(t, f.mask && f.invert && f.primary && !f.smooth)
	}

	data, err := os.read_entire_file(path, context.allocator)
	testing.expect(t, err == nil)
	defer delete(data)
	data[len(STROKES_MAGIC)] = 2
	testing.expect(t, os.write_entire_file(path, data) == nil)
	testing.expect(t, !strokes_load(&b, path))
	free_all(context.temp_allocator)
}
