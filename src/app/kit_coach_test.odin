package main

import "core:testing"

import "../ui"

// Each tip's words follow the input in use and the settings that change what it does.
@(test)
coach_text_follows_the_input_and_settings :: proc(t: ^testing.T) {
	app: App
	app.nav = NAV_DEFAULT
	for step in Coach_Step {
		seen: [ui.Pointer_Kind]string
		for p in ui.Pointer_Kind {
			app.device.pointer = p
			_, seen[p] = coach_text(&app, step)
			testing.expectf(t, seen[p] != "", "%v %v has no words", step, p)
		}
		testing.expectf(t, seen[.Mouse] != seen[.Finger], "%v reads the same for a mouse and a finger", step)
	}
	app.device.pointer = .Finger
	_, sculpts := coach_text(&app, .Draw)
	app.nav.finger_model = .Orbit
	_, orbits := coach_text(&app, .Draw)
	testing.expect(t, sculpts != orbits)
	app.device.pointer = .Mouse
	_, turns := coach_text(&app, .Turn)
	app.nav.empty_drag[.Mouse] = .Tool
	_, tool := coach_text(&app, .Turn)
	testing.expect(t, turns != tool)
}

// What was done counts once the gesture ends, the card shows the first step not done,
// and restarting starts from the first again.
@(test)
coach_counts_what_was_done :: proc(t: ^testing.T) {
	app: App
	app.nav = NAV_DEFAULT
	app.coach_run = true
	app.tool = .Brush
	step, ok := coach_step(&app)
	testing.expect(t, ok && step == .Draw)
	// A turn while a drag is still held counts only once it is let go.
	app.coach_seen = {.Turn}
	app.drag.owner = .Orbit
	coach_update(&app)
	testing.expect_value(t, app.kit.coach, 0)
	app.drag.owner = .None
	coach_update(&app)
	testing.expect_value(t, app.kit.coach, 1 << u8(Coach_Step.Turn))
	step, ok = coach_step(&app)
	testing.expect(t, ok && step == .Draw)
	app.stroke.active = true
	coach_update(&app)
	app.stroke.active = false
	app.coach_seen += {.Move}
	coach_update(&app)
	testing.expect_value(t, app.kit.coach, COACH_DONE)
	_, ok = coach_step(&app)
	testing.expect(t, !ok)
	testing.expect(t, !coach_shown(&app))
	coach_restart(&app)
	step, ok = coach_step(&app)
	testing.expect(t, ok && step == .Draw && coach_shown(&app))
}
