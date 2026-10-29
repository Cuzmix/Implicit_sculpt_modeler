package main

import "core:math"
import "core:os"
import "core:testing"
import sdl "vendor:sdl3"

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

// Where the platform never says that the pen left (an iPad's SDL), the pen counts as gone
// PEN_GONE after its last report with its tip up: never while it touches, never twice, and
// never where the platform says so itself.
@(test)
the_pen_leaves_where_the_platform_never_says_so :: proc(t: ^testing.T) {
	app: App
	app.kit.fixed_dt = 1.0 / 60
	app.kit.ctx.time = 100
	app.pencil.no_leave = true
	e: sdl.Event
	e.pmotion = {type = .PEN_MOTION, windowID = 7, which = 3}
	pencil_heard(&app, &e)
	testing.expect(t, app.pencil.about)
	testing.expect_value(t, app.pencil.heard_window, sdl.WindowID(7))
	testing.expect_value(t, app.pencil.heard_pen, sdl.PenID(3))
	testing.expect(t, !pencil_gone(app.pencil, 100 + PEN_GONE * 0.5))
	testing.expect(t, pencil_gone(app.pencil, 100 + PEN_GONE))
	desktop := app.pencil
	desktop.no_leave = false
	testing.expect(t, !pencil_gone(desktop, 100 + 60))

	app.kit.ctx.time = 101
	e.ptouch = {type = .PEN_DOWN, windowID = 7, which = 3, down = true}
	pencil_heard(&app, &e)
	testing.expect(t, !pencil_gone(app.pencil, 101 + 60))
	e.ptouch = {type = .PEN_UP, windowID = 7, which = 3}
	pencil_heard(&app, &e)
	testing.expect(t, !pencil_gone(app.pencil, 101 + PEN_GONE * 0.5))
	testing.expect(t, pencil_gone(app.pencil, 101 + PEN_GONE))

	// The leave said, the pen is gone until it reports again.
	e.pproximity = {type = .PEN_PROXIMITY_OUT, windowID = 7, which = 3}
	pencil_heard(&app, &e)
	testing.expect(t, !pencil_gone(app.pencil, 101 + 60))
	app.kit.ctx.time = 200
	e.paxis = {type = .PEN_AXIS, windowID = 7, which = 3, axis = .DISTANCE, value = 0.5}
	pencil_heard(&app, &e)
	testing.expect(t, app.pencil.about)
	testing.expect(t, pencil_gone(app.pencil, 200 + PEN_GONE))
}

// The pen turned to the right turns the frame's roll clockwise, the way that raises a slider
// and grows the brush, and to the left the other way, across zero and across the half turn
// where the numbers wrap alike. An iPad's SDL reports the turn to the right as a falling
// angle (pencil_roll_uikit). A report further than ROLL_JUMP from the last starts afresh.
@(test)
the_pens_roll_turns_both_ways_and_wraps :: proc(t: ^testing.T) {
	app: App
	turned :: proc(app: ^App, reports: []f32, uikit := false) -> f32 {
		app.pen_roll = 0
		for r in reports do pen_roll_take(app, pencil_roll_uikit(r) if uikit else r)
		return app.pen_roll
	}
	near :: proc(t: ^testing.T, got, want: f32, loc := #caller_location) {
		testing.expectf(t, math.abs(got - want) < 1e-4, "turned %v, want %v", got, want, loc = loc)
	}
	near(t, turned(&app, {-10, 0, 10}), 20)
	near(t, turned(&app, {0, -10}), -20)
	// Past the half turn, from the 170 the pen came back at.
	near(t, turned(&app, {170, -170, -150}), 40)
	near(t, turned(&app, {-170, 170, 150}), -60)
	// Further than a hand turns between two reports: no turn, the new start kept.
	near(t, turned(&app, {60, 80}), 20)
	app.pen_roll_last = nil
	near(t, turned(&app, {20, 10, 0, -10}, uikit = true), 30)
	app.pen_roll_last = nil
	near(t, turned(&app, {-160, -170, 170, 160}, uikit = true), 40)
	near(t, turned(&app, {170, -170}, uikit = true), -30)
}
