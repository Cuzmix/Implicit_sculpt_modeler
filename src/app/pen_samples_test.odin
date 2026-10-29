package main

import "core:math/linalg"
import "core:testing"
import sdl "vendor:sdl3"

// A bridge's samples go in ahead of SDL's newest, at their offsets from it, each with its
// own pressure (or the newest's when it sent none); a sample that came with no motion
// after it is dropped at the end of the frame.
@(test)
pen_samples_go_in_before_the_newest :: proc(t: ^testing.T) {
	app: App
	defer delete(app.samples)
	app.pen_samples = {event_type = 0x9000, open = -1}
	app.pen_pressure = 0.8
	for s in ([]Pen_Sample{{offset = {-12, -6}, pressure = 0.3, lean = {10, -5}}, {offset = {-6, -3}, pressure = -1}}) {
		e := pen_sample_event(app.pen_samples.event_type, s)
		testing.expect(t, pen_samples_event(&app, &e))
	}
	pen_samples_motion(&app, {100, 50})
	testing.expect_value(t, len(app.samples), 3)
	testing.expect_value(t, app.samples[0], Input_Sample{{88, 44}, 0.3, .Move, {10, -5}})
	testing.expect_value(t, app.samples[1], Input_Sample{{94, 47}, 0.8, .Move, {}})
	testing.expect_value(t, app.samples[2].pos, [2]f32{100, 50})
	testing.expect_value(t, app.pen_samples.coalesced, 2)

	stray := pen_sample_event(app.pen_samples.event_type, {offset = {1, 1}, pressure = 1})
	_ = pen_samples_event(&app, &stray)
	pen_samples_frame_end(&app)
	pen_samples_motion(&app, {110, 50})
	testing.expect_value(t, len(app.samples), 4)
	testing.expect_value(t, app.pen_samples.coalesced, 2)

	// A damaged sample is taken out of the queue and never reaches a stroke.
	bad := pen_sample_event(app.pen_samples.event_type, {offset = {transmute(f32)u32(0x7fc00000), 0}})
	testing.expect(t, pen_samples_event(&app, &bad))
	testing.expect_value(t, app.pen_samples.waiting_count, 0)
}

// SDL reports a pen's place before its pressure and lean, so the newest sample takes the
// axes of its own update, and not those of the update after it.
@(test)
pen_samples_take_their_own_updates_axes :: proc(t: ^testing.T) {
	app: App
	defer delete(app.samples)
	app.pen_samples = {event_type = 0x9000, open = -1}
	app.pen_pressure = 0.2
	pen_samples_motion(&app, {10, 10})
	app.pen_pressure, app.pen_tilt = 0.6, {20, 0}
	pen_samples_axes(&app)
	testing.expect_value(t, app.samples[0].pressure, 0.6)
	testing.expect_value(t, app.samples[0].tilt, [2]f32{20, 0})

	e: sdl.Event
	e.pmotion = {type = .PEN_MOTION, which = 1, x = 12, y = 10}
	testing.expect(t, !pen_samples_event(&app, &e))
	app.pen_pressure = 0.9
	pen_samples_axes(&app)
	testing.expect_value(t, app.samples[0].pressure, 0.6)
	pen_samples_button(&app, {12, 10}, .Release)
	pen_samples_axes(&app)
	testing.expect_value(t, app.samples[1].pressure, 0.9)
}

// Each platform's raw lean comes out as the lean SDL reports elsewhere: an Apple Pencil
// held upright has none, and one leaning toward the screen's right leans right.
@(test)
pen_sample_leans_from_uikit_angles :: proc(t: ^testing.T) {
	upright := pencil_lean_uikit(0.3, 1.5707963)
	testing.expect(t, abs(upright.x) < 0.01 && abs(upright.y) < 0.01)
	right := pencil_lean_uikit(0, 0.7853982)
	testing.expect(t, abs(right.x - 45) < 0.01 && abs(right.y) < 0.01)
	down := pencil_lean_uikit(1.5707963, 0.7853982)
	testing.expect(t, abs(down.x) < 0.01 && abs(down.y - 45) < 0.01)
}

// While a stroke draws, the brush ring leads the pointer by a frame of its motion, or by
// the platform's predicted sample in the frame one came, never past PREDICT_MAX_PX; with
// the setting off, before the pointer has moved, or under a trailing brush it stays put.
@(test)
cursor_lead_runs_ahead_of_the_pointer :: proc(t: ^testing.T) {
	app: App
	defer delete(app.samples)
	app.pen_samples = {event_type = 0x9000, open = -1}
	app.nav.predict_cursor, app.stroke.active = true, true
	app.brush.smoothing = 1
	press := Viewport_Input{primary = true, mouse_pos = {100, 50}}
	cursor_predict_frame(&app, press)
	testing.expect_value(t, cursor_lead(&app), [2]f32{})
	press.mouse_pos = {110, 54}
	cursor_predict_frame(&app, press)
	testing.expect_value(t, cursor_lead(&app), [2]f32{10, 4})
	testing.expect_value(t, ring_center(&app, press), [2]f32{120, 58})

	ahead := pen_sample_event(app.pen_samples.event_type + 1, {offset = {6, 0}})
	testing.expect(t, pen_samples_event(&app, &ahead))
	cursor_predict_frame(&app, press)
	testing.expect_value(t, cursor_lead(&app), [2]f32{6, 0})
	// The next frame has none of its own, and goes back to the motion (none: it stood still).
	cursor_predict_frame(&app, press)
	testing.expect_value(t, cursor_lead(&app), [2]f32{})

	press.mouse_pos = {210, 54}
	cursor_predict_frame(&app, press)
	testing.expect(t, abs(linalg.length(cursor_lead(&app)) - PREDICT_MAX_PX) < 1e-3)
	app.brush.lazy_px = 30
	testing.expect_value(t, cursor_lead(&app), [2]f32{})
	app.brush.lazy_px, app.nav.predict_cursor = 0, false
	testing.expect_value(t, cursor_lead(&app), [2]f32{})
}
