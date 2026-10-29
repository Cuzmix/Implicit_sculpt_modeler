package main

import "core:math"
import "core:os"
import "core:testing"

import "../sculpt"

// What SDL 3.4's UIKit driver makes of an azimuth and an altitude (degrees), as
// SDL_uikitpen.m computes it.
@(private = "file")
uikit_sdl_tilt :: proc(azimuth, altitude: f32) -> [2]f32 {
	x := (180 - abs(azimuth)) - 90
	y := -(90 - altitude) if azimuth < 0 else 90 - altitude
	return {x, y}
}

// The lean a pen of that azimuth and altitude has, as Windows and X11 report it.
@(private = "file")
lean :: proc(azimuth, altitude: f32) -> [2]f32 {
	a, h := math.to_radians(azimuth), math.to_radians(altitude)
	return {math.to_degrees(math.atan(math.cos(h) * math.cos(a) / math.sin(h))), math.to_degrees(math.atan(math.cos(h) * math.sin(a) / math.sin(h)))}
}

// An iPad pencil's lean comes out as every other platform's: upright is no lean at all,
// though SDL says 90 degrees across, and each way round the screen leans its own way.
@(test)
pencil_tilt_undoes_sdls_uikit_tilt :: proc(t: ^testing.T) {
	upright := pencil_tilt_uikit(uikit_sdl_tilt(0, 90))
	testing.expectf(t, abs(upright.x) < 0.01 && abs(upright.y) < 0.01, "upright leans %v", upright)
	CASES :: [?][2]f32{{0, 45}, {90, 30}, {-135, 60}, {170, 20}, {-30, 75}, {45, 89}}
	for c in CASES {
		got, want := pencil_tilt_uikit(uikit_sdl_tilt(c.x, c.y)), lean(c.x, c.y)
		testing.expectf(t, abs(got.x - want.x) < 0.01 && abs(got.y - want.y) < 0.01, "azimuth %v altitude %v: %v, want %v", c.x, c.y, got, want)
	}
}

// A double-tap waits for the frame; Ignore in the iPad's Settings turns it off whatever
// the slot holds; a squeeze begun mid-stroke is the grip, not a gesture.
@(test)
pencil_gestures_wait_and_obey_ignore :: proc(t: ^testing.T) {
	app: App
	app.nav = NAV_DEFAULT
	pencil_gesture(&app, .Double_Tap, .Switch_Previous)
	testing.expect_value(t, app.pencil.pending, Maybe(Gesture_Slot)(.Pen_Double_Tap))
	testing.expect_value(t, app.pencil.preferred[0], Pencil_Action.Switch_Previous)
	app.pencil.pending = nil
	pencil_gesture(&app, .Double_Tap, .Ignore)
	testing.expect_value(t, app.pencil.pending, nil)

	pencil_gesture(&app, .Squeeze_Began, .Contextual_Palette)
	pencil_gesture(&app, .Squeeze_Ended, .Contextual_Palette)
	testing.expect_value(t, app.pencil.pending, Maybe(Gesture_Slot)(.Pen_Squeeze))
	app.pencil.pending = nil
	app.stroke.active = true
	pencil_gesture(&app, .Squeeze_Began, .Contextual_Palette)
	app.stroke.active = false
	pencil_gesture(&app, .Squeeze_Ended, .Contextual_Palette)
	testing.expect_value(t, app.pencil.pending, nil)
	// The next squeeze is a gesture again.
	pencil_gesture(&app, .Squeeze_Began, .Contextual_Palette)
	pencil_gesture(&app, .Squeeze_Ended, .Contextual_Palette)
	testing.expect_value(t, app.pencil.pending, Maybe(Gesture_Slot)(.Pen_Squeeze))
}

// Follow the Pencil setting: the eraser is Smooth, on and off; the last used brush comes
// back, and the one before it the next time.
@(test)
pencil_preferred_actions_sculpt :: proc(t: ^testing.T) {
	app: App
	app.nav = NAV_DEFAULT
	app.brush.kind = .Draw
	pencil_init(&app)
	app.pencil.preferred[0] = .Switch_Eraser
	pencil_preferred_run(&app)
	testing.expect_value(t, app.rail.latched, Modifiers{.Smooth})
	pencil_preferred_run(&app)
	testing.expect_value(t, app.rail.latched, Modifiers{})

	app.brush.kind = .Clay
	pencil_frame(&app)
	app.pencil.preferred[0] = .Switch_Previous
	pencil_preferred_run(&app)
	testing.expect_value(t, app.brush.kind, sculpt.Brush_Kind.Draw)
	pencil_frame(&app)
	pencil_preferred_run(&app)
	testing.expect_value(t, app.brush.kind, sculpt.Brush_Kind.Clay)
	free_all(context.temp_allocator)
}

// A number the bridge sends that this version does not know does nothing; scripts name
// actions in lower case.
@(test)
pencil_actions_by_number_and_name :: proc(t: ^testing.T) {
	testing.expect_value(t, pencil_action_from(int(Pencil_Action.Run_Shortcut)), Pencil_Action.Run_Shortcut)
	testing.expect_value(t, pencil_action_from(99), Pencil_Action.Ignore)
	testing.expect_value(t, pencil_action_from(-1), Pencil_Action.Ignore)
	a, ok := pencil_action_named("switch_previous")
	testing.expect(t, ok)
	testing.expect_value(t, a, Pencil_Action.Switch_Previous)
	_, ok = pencil_action_named("erase")
	testing.expect(t, !ok)
	testing.expect_value(t, eraser_mods(.Tip), Modifiers{})
	testing.expect_value(t, eraser_mods(.Mask), Modifiers{.Mask})
}

// The pencil's slots and the eraser end are remembered, and resetting the gesture map
// leaves them as they were.
@(test)
pencil_settings_are_remembered :: proc(t: ^testing.T) {
	path := "build/pencil_test.txt"
	defer os.remove(path)
	a: App
	defer results_destroy(&a)
	a.nav = NAV_DEFAULT
	a.nav.gestures[.Pen_Double_Tap] = {.Undo, 0}
	a.nav.gestures[.Pen_Squeeze] = {}
	a.nav.gestures[.Pen_Button_2] = {.Brush_Pie, 0}
	a.nav.eraser = .Mask
	testing.expect(t, settings_save(&a, path))
	b: App
	defer results_destroy(&b)
	b.nav = NAV_DEFAULT
	settings_load(&b, path)
	testing.expect_value(t, b.nav.gestures, a.nav.gestures)
	testing.expect_value(t, b.nav.eraser, Eraser_Use.Mask)
	b.nav.gestures[.Two_Tap] = {.Wireframe, 0}
	gesture_map_reset(&b.nav)
	testing.expect_value(t, b.nav.gestures[.Two_Tap], Pie_Slot{.Undo, 0})
	testing.expect_value(t, b.nav.gestures[.Pen_Double_Tap], Pie_Slot{.Undo, 0})
	free_all(context.temp_allocator)
}
