package main

import "core:math"
import "core:os"
import "core:testing"

import "../geom"
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

// The iPad's Only Draw with Apple Pencil leaves a finger only the view to turn, and a
// haptic is asked of the pen alone.
@(test)
pencil_only_and_haptics :: proc(t: ^testing.T) {
	app: App
	app.nav = NAV_DEFAULT
	testing.expect_value(t, finger_model_now(&app), Finger_Model.Sculpt)
	app.pencil.only = true
	testing.expect_value(t, finger_model_now(&app), Finger_Model.Orbit)
	testing.expect_value(t, app.nav.finger_model, Finger_Model.Sculpt)

	app.device.pointer = .Finger
	haptic(&app, .Alignment)
	app.device.pointer = .Mouse
	haptic(&app, .Path_Completed)
	testing.expect_value(t, app.pencil.haptics, 0)
	app.device.pointer = .Pen
	haptic(&app, .Alignment)
	testing.expect_value(t, app.pencil.haptics, 1)
}

// A Pen roll alpha turns with the pen, clockwise as the pen turns clockwise, from its own
// angle; the other modes take no notice of the roll.
@(test)
pen_roll_alpha_turns_with_the_pen :: proc(t: ^testing.T) {
	app: App
	app.brush.alpha_mode, app.brush.alpha_angle = .Pen_Roll, 10
	app.alpha_roll = 90
	testing.expect(t, abs(alpha_screen_angle(&app) - math.to_radians(f32(10 - 90))) < 1e-5)
	app.brush.alpha_mode = .Fixed
	testing.expect(t, abs(alpha_screen_angle(&app) - math.to_radians(f32(10))) < 1e-5)
}

// A pen laid toward the paper grows and softens the brush as far as the brush asks, full
// from LEAN_FULL degrees off upright; upright, or with both off, it changes nothing.
@(test)
pen_lean_grows_and_softens :: proc(t: ^testing.T) {
	testing.expect_value(t, lean_of({}), 0)
	testing.expect(t, abs(lean_of({30, 0}) - 0.5) < 1e-4)
	testing.expect_value(t, lean_of({0, -80}), 1)
	app: App
	app.brush.radius_px = 40
	testing.expect_value(t, brush_radius_px(&app, 1, {60, 0}), 40)
	app.brush.tilt_size = 1
	testing.expect(t, abs(brush_radius_px(&app, 1, {30, 0}) - 60) < 1e-3)
	testing.expect(t, abs(brush_radius_px(&app, 1, {0, 70}) - 80) < 1e-3)
}


// An Android pen's tilt and orientation come out as the lean the other platforms report:
// its top toward the screen's top leans up, toward its right leans right.
@(test)
pencil_tilt_from_android :: proc(t: ^testing.T) {
	near :: proc(a, b: [2]f32) -> bool {return abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01}
	testing.expect(t, near(pencil_tilt_android(0, 1), {0, 0}))
	thirty := math.to_radians(f32(30))
	testing.expect(t, near(pencil_tilt_android(thirty, 0), {0, -30}))
	testing.expect(t, near(pencil_tilt_android(thirty, math.PI / 2), {30, 0}))
	testing.expect(t, near(pencil_tilt_android(thirty, math.PI), {0, 30}))
	// Laid flat it stops short of 90 degrees rather than overflowing.
	flat := pencil_tilt_android(math.PI / 2, 0)
	testing.expect(t, flat.y < -88 && flat.y > -90)
}

// Size and strength go through curves of their own, and a brush with Use global off keeps
// its own pressure, starting from the global one; the settings file keeps both, and one
// from before the size had a curve gives it the strength's.
@(test)
pressure_curves_apart_and_per_brush :: proc(t: ^testing.T) {
	path := "build/pressure_test.txt"
	defer os.remove(path)
	a: App
	defer results_destroy(&a)
	a.brush.kind, a.brush.radius_px = .Draw, 40
	a.brush.pressure_strength, a.brush.pressure_size = true, true
	a.brush.pressure_curve, a.brush.pressure_size_curve = geom.CURVE_LINEAR, PRESSURE_PRESETS[2].curve
	firm := geom.curve_at(PRESSURE_PRESETS[2].curve, 0.5)
	testing.expect(t, abs(brush_radius_px(&a, 0.5, {}) - 40 * firm) < 1e-3 && abs(pressure_curved(&a, 0.5) - 0.5) < 1e-3)
	// Clay keeps its own: it starts as the global one, then its size stops following the pen.
	brush_pressure_own(&a.brush, .Clay, true)
	testing.expect_value(t, a.brush.pressures[.Clay].pressure, brush_pressure(&a.brush, .Draw))
	a.brush.pressures[.Clay].size = false
	a.brush.kind = .Clay
	testing.expect_value(t, brush_radius_px(&a, 0.5, {}), 40)
	a.brush.kind = .Draw
	testing.expect(t, brush_radius_px(&a, 0.5, {}) < 40)

	testing.expect(t, settings_save(&a, path))
	b: App
	defer results_destroy(&b)
	settings_load(&b, path)
	testing.expect_value(t, b.brush.pressure_size_curve, PRESSURE_PRESETS[2].curve)
	testing.expect(t, b.brush.pressures[.Clay].own && !b.brush.pressures[.Clay].size && b.brush.pressures[.Clay].strength)
	testing.expect_value(t, b.brush.pressures[.Clay].size_curve, PRESSURE_PRESETS[2].curve)
	testing.expect(t, !b.brush.pressures[.Draw].own)

	// A file from before: no size curve line.
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string("version 4\npressure_curve 0.1 0.6 0.4 0.95\n")) == nil)
	c: App
	defer results_destroy(&c)
	settings_load(&c, path)
	testing.expect_value(t, c.brush.pressure_size_curve, c.brush.pressure_curve)
	testing.expect_value(t, c.brush.pressure_curve, PRESSURE_PRESETS[1].curve)
	free_all(context.temp_allocator)
}

// A response preset sets size and strength together; Clay's keeps the brush at least a
// fifth of its radius however light the touch, and the app starts Clay on it while the
// other brushes use the global pressure.
@(test)
pressure_responses_and_the_clay_floor :: proc(t: ^testing.T) {
	a: App
	defer results_destroy(&a)
	a.brush.kind, a.brush.radius_px = .Draw, 50
	at := pressure_edit(&a.brush)
	pressure_put(at, PRESSURE_RESPONSES[0].pressure)
	testing.expect_value(t, pressure_response(at), 0)
	testing.expect_value(t, brush_radius_px(&a, 0.1, {}), 50)
	pressure_put(at, PRESSURE_RESPONSES[1].pressure)
	testing.expect_value(t, pressure_response(at), 1)
	// The cube of 0.1 is a thousandth: the floor holds it at a fifth.
	testing.expect(t, abs(brush_radius_px(&a, 0.1, {}) - 10) < 1e-3)
	// The cube of 0.8 is 0.512, above the floor.
	testing.expect(t, abs(brush_radius_px(&a, 0.8, {}) - 50 * 0.512) < 0.05)
	// Firm strokes is at over nine tenths of its strength from half pressure on.
	pressure_put(at, PRESSURE_RESPONSES[2].pressure)
	testing.expect(t, pressure_curved(&a, 0.5) > 0.9 && pressure_curved(&a, 0.1) < 0.5)
	// A changed curve is no preset; a switched-off one does not count.
	at.size_curve^ = PRESSURE_PRESETS[3].curve
	testing.expect_value(t, pressure_response(at), 2)
	at.strength_curve^ = PRESSURE_PRESETS[3].curve
	testing.expect_value(t, pressure_response(at), -1)

	b := brush_defaults()
	testing.expect(t, b.pressures[.Clay].own && b.pressures[.Clay].pressure == PRESSURE_RESPONSES[1].pressure && !b.pressures[.Draw].own)
}
