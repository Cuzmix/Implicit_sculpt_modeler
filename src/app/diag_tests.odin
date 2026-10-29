package main

import "core:fmt"
import "core:math"

import "../ui"

// The Input diagnostics mode's guided tests (diagnostics.odin): what each asks the person to
// do, with which device, what should happen, and the verdict the run's own counts give where
// one is objective. The ids are what a report names a test by, so they never change; a new
// test goes at the end of its category.

Diag_Test_Id :: enum u8 {
	Finger_Tap,
	Finger_Drag,
	Finger_Cancel,
	Finger_After_Pencil,
	Finger_Pencil_Switch,
	Pencil_Tap,
	Pencil_Drag,
	Pencil_Hover,
	Pencil_Hover_Contact_Lift,
	Pressure_Ramp,
	Hover_Slider,
	Hover_Button,
	Hover_Menu,
	Slider_Ratio_Finger,
	Slider_Ratio_Pencil,
	Text_Focus_Finger,
	Text_Focus_Pencil,
	Text_Typing,
	Text_Dismiss_Reopen,
	Text_Scribble,
	Home_Swipe_Baseline,
	Home_Swipe_After_Pencil,
	Roll_Right,
	Roll_Left,
	Roll_Neutral,
	Roll_Wrap,
}

Diag_Test :: struct {
	key:      string, // the id a report and --diag-test use
	category: string,
	title:    string,
	device:   string, // finger, pencil, finger+pencil or keyboard
	needs:    string, // what only a device has: ipad, pencil, pencil_pro, comma separated
	probe:    Diag_Probe, // the control the steps point at, ringed on screen
	steps:    string, // one step a line
	expected: string,
}

// The text a field test types, and what is left of it after two Backspaces.
DIAG_TYPE_TEXT :: "sculpt"
DIAG_TYPE_LEFT :: "scul"

@(rodata)
DIAG_TESTS := [Diag_Test_Id]Diag_Test {
	.Finger_Tap = {
		"finger_tap", "finger", "Finger taps", "finger", "ipad", .Pad,
		"Press Start.\nTap the pad three times with one finger, lifting it fully each time.",
		"Every tap shows as a press and a release on the pad, and nothing stays pressed after the last one.",
	},
	.Finger_Drag = {
		"finger_drag", "finger", "Finger drag", "finger", "ipad", .Pad,
		"Press Start.\nPut one finger on the pad and drag it slowly across, at least a third of its width.\nLift it.",
		"The trail follows the finger the whole way, and it lets go when the finger lifts.",
	},
	.Finger_Cancel = {
		"finger_cancel", "finger", "Finger cancelled by the system", "finger", "ipad", .Pad,
		"Press Start.\nHold one finger on the pad.\nWith it still down, pull down Control Center from the top right corner with another finger (or switch apps), then come back.\nLift every finger.",
		"The system cancels the touch: the pad lets go without a click, and nothing stays pressed when you come back.",
	},
	.Finger_After_Pencil = {
		"finger_after_pencil", "finger", "Finger right after the Pencil", "finger+pencil", "ipad,pencil", .Pad,
		"Press Start.\nTap the pad twice with the Pencil.\nPut the Pencil down on the table, away from the screen.\nWithin two seconds, tap the pad three times with a finger.",
		"Every finger tap shows as a press on the pad: the app no longer takes the finger for the hand holding the Pencil.",
	},
	.Finger_Pencil_Switch = {
		"finger_pencil_switch", "finger", "Switching finger and Pencil", "finger+pencil", "ipad,pencil", .Pad,
		"Press Start.\nTap the pad with the Pencil, then put the Pencil away from the screen and tap with a finger.\nDo that five times.",
		"Every tap, finger or Pencil, shows as a press on the pad.",
	},
	.Pencil_Tap = {
		"pencil_tap", "pencil", "Pencil taps", "pencil", "ipad,pencil", .Pad,
		"Press Start.\nTap the pad three times with the Pencil's tip.",
		"Every tap shows as a press and a release by the pen.",
	},
	.Pencil_Drag = {
		"pencil_drag", "pencil", "Pencil drag", "pencil", "ipad,pencil", .Pad,
		"Press Start.\nDraw a line across the pad with the Pencil, at least a third of its width.\nLift it.",
		"The trail follows the tip the whole way and lets go when it lifts.",
	},
	.Pencil_Hover = {
		"pencil_hover", "pencil", "Pencil hover", "pencil", "ipad,pencil", .Pad,
		"Press Start.\nHold the Pencil's tip about a centimetre over the pad without touching, and move it around for two seconds.\nTake it well away from the screen and wait two seconds.",
		"The pad shows the hover ring and no press; once the Pencil is away, the app says it left (Pen near turns off).",
	},
	.Pencil_Hover_Contact_Lift = {
		"pencil_hover_contact_lift", "pencil", "Hover, touch, lift", "pencil", "ipad,pencil", .Pad,
		"Press Start.\nHover over the pad, then touch down and draw a short line, lift, hover a moment more.\nTake the Pencil away from the screen and wait two seconds.",
		"The events come in order: near, down, up, then the Pencil leaves; nothing stays pressed.",
	},
	.Pressure_Ramp = {
		"pressure_ramp", "pressure", "Pencil pressure", "pencil", "ipad,pencil", .Pad,
		"Press Start.\nDraw on the pad, starting as lightly as you can and pressing harder and harder.",
		"Pressure rises from near 0 to near 1. Without pressure reports the test says unavailable, never 0.",
	},
	.Hover_Slider = {
		"hover_slider", "hover", "Hover over a slider", "pencil", "ipad,pencil", .Slider,
		"Press Start.\nHold the Pencil over the slider's knob without touching and without turning it, for three seconds.\nMove it along the slider, still not touching.",
		"The slider's value stays where it was: hovering never changes it.",
	},
	.Hover_Button = {
		"hover_button", "hover", "Hover over a button", "pencil", "ipad,pencil", .Button,
		"Press Start.\nHold the Pencil over the diagnostic button without touching, for three seconds.\nMove it on and off the button a few times.",
		"The button lights while hovered but never clicks.",
	},
	.Hover_Menu = {
		"hover_menu", "hover", "Hover over a menu", "pencil", "ipad,pencil", .Menu,
		"Press Start.\nTap the diagnostic menu to open its list.\nHover the Pencil over the list's rows without touching, for three seconds.\nTap outside the list to close it.",
		"The rows light as the Pencil passes, but none is picked without a tap.",
	},
	.Slider_Ratio_Finger = {
		"slider_ratio_finger", "hover", "Size slider by finger", "finger", "ipad", .Vslider,
		"Press Start.\nDrag the size slider up and down with one finger, a few times, without reaching its ends.",
		"The value moves exactly as far as the finger along the track.",
	},
	.Slider_Ratio_Pencil = {
		"slider_ratio_pencil", "hover", "Size slider by Pencil", "pencil", "ipad,pencil", .Vslider,
		"Press Start.\nDrag the size slider up and down with the Pencil, a few times, without reaching its ends.",
		"The value moves exactly as far as the Pencil along the track: the same feel as a finger.",
	},
	.Text_Focus_Finger = {
		"text_focus_finger", "text", "Field focus by finger", "finger", "ipad", .Field,
		"Press Start.\nTap the diagnostic field with a finger.",
		"The field takes the keys (its outline lights) and the on-screen keyboard comes up.",
	},
	.Text_Focus_Pencil = {
		"text_focus_pencil", "text", "Field focus by Pencil", "pencil", "ipad,pencil", .Field,
		"Press Start.\nTap the diagnostic field with the Pencil.",
		"The field takes the keys and the keyboard (or the Pencil's shortcut bar) comes up.",
	},
	.Text_Typing = {
		"text_typing", "text", "Typing and Backspace", "keyboard", "ipad", .Field,
		"Press Start.\nTap the diagnostic field and clear it if it holds anything.\nType sculpt on the keyboard.\nPress Backspace twice.",
		"The field holds scul.",
	},
	.Text_Dismiss_Reopen = {
		"text_dismiss_reopen", "text", "Keyboard dismiss and reopen", "keyboard", "ipad", .Field,
		"Press Start.\nTap the diagnostic field: the keyboard comes up.\nHide the keyboard with its own hide key (bottom right).\nTap the field again.",
		"Hiding the keyboard lets the field go; the second tap takes the keys and brings the keyboard back.",
	},
	.Text_Scribble = {
		"text_scribble", "text", "Scribble into the field", "pencil", "ipad,pencil", .Field,
		"Press Start.\nWith the Pencil, handwrite the word ok inside the diagnostic field (Scribble).",
		"The handwriting turns into text in the field.",
	},
	.Home_Swipe_Baseline = {
		"home_swipe_baseline", "system", "Home swipe, before the Pencil", "finger", "ipad", .None,
		"Do this before using the Pencil in this session (restart the app if you have).\nPress Start.\nSwipe up from the very bottom edge of the screen once, as you would to go Home.\nCome back to Sculpt and say whether one swipe was enough.",
		"One swipe goes Home. You decide: the app only sees that it went to the background.",
	},
	.Home_Swipe_After_Pencil = {
		"home_swipe_after_pencil", "system", "Home swipe, after the Pencil", "finger+pencil", "ipad,pencil", .Pad,
		"Press Start.\nDraw on the pad with the Pencil for a few seconds, then put it away from the screen.\nSwipe up from the very bottom edge once, as you would to go Home.\nCome back to Sculpt and say whether one swipe was enough.",
		"One swipe goes Home, as before the Pencil. You decide: the app only sees that it went to the background.",
	},
	.Roll_Right = {
		"roll_right", "roll", "Barrel roll to the right", "pencil", "ipad,pencil_pro", .Slider,
		"Press Start.\nHold the Pencil Pro over the slider without touching.\nRoll it to the right: its top side turning to the right, clockwise as you look from its end toward the tip. About a quarter turn, slowly.",
		"The slider's value goes up.",
	},
	.Roll_Left = {
		"roll_left", "roll", "Barrel roll to the left", "pencil", "ipad,pencil_pro", .Slider,
		"Press Start.\nHold the Pencil Pro over the slider without touching.\nRoll it to the left (anticlockwise as you look from its end), about a quarter turn, slowly.",
		"The slider's value goes down.",
	},
	.Roll_Neutral = {
		"roll_neutral", "roll", "Barrel roll held still", "pencil", "ipad,pencil_pro", .Slider,
		"Press Start.\nHold the Pencil Pro over the slider without touching, as still as you can, for three seconds.",
		"The slider's value stays put: holding still is no roll.",
	},
	.Roll_Wrap = {
		"roll_wrap", "roll", "Barrel roll past half a turn", "pencil", "ipad,pencil_pro", .Slider,
		"Press Start.\nSet the slider near its middle with a tap.\nHold the Pencil Pro over it without touching and roll it one way a full turn or more, slowly, with your fingers walking round the barrel.",
		"The value keeps moving one way as the Pencil turns, with no jump where the reported angle wraps from 180 to -180.",
	},
}

// Values the verdicts need: how many taps make a test, how far a drag goes, how long a hover
// lasts (frames at 60 a second), and how close two ratios must be.
DIAG_TAPS :: 3
DIAG_DRAG_PT :: 100
DIAG_HOVER_FRAMES :: 60
DIAG_RATIO_OFF :: 0.15
// A one-frame change bigger than this share of the slider's range is a jump, not a turn.
DIAG_ROLL_JUMP :: 0.25
// Value units (of 100) a still pencil may drift by before it counts as moving the slider.
DIAG_STILL :: 0.5
// Degrees of roll a "still" hold may report before it is a turn after all.
DIAG_STILL_ROLL :: 5
// Points the size slider's track is long, and so the value it moves per point.
DIAG_VTRACK :: f32(160)
DIAG_RANGE :: f32(100)

// The run's verdict from its own counts, and why, or .None for a test only the person can
// judge. Temp memory for the reason.
diag_judge :: proc(r: ^Diag_Run) -> (Diag_Verdict, string) {
	m := &r.m
	rec := r.received
	pressed := r.responded[.Press]
	switch r.test {
	case .Finger_Tap, .Pencil_Tap:
		pen := r.test == .Pencil_Tap
		downs := r.on_probe[.Pen_Down] if pen else r.on_probe[.Finger_Down]
		by := r.by[.Pen] if pen else r.by[.Finger]
		what := "pen" if pen else "finger"
		if downs == 0 do return .Inconclusive, fmt.tprintf("no %s touched the pad%s", what, diag_other_pointer(r, pen))
		if by < downs do return .Fail, fmt.tprintf("%d %s downs on the pad, %d answered (%d taken as a palm)", downs, what, by, r.palms)
		if r.anomalies[.Stuck_Pressed] > 0 do return .Fail, "something stayed pressed after the last tap"
		if downs < DIAG_TAPS do return .Inconclusive, fmt.tprintf("%d of %d taps, all answered", downs, DIAG_TAPS)
		return .Pass, fmt.tprintf("%d %s taps, every one answered", downs, what)
	case .Finger_Drag, .Pencil_Drag:
		pen := r.test == .Pencil_Drag
		downs := r.on_probe[.Pen_Down] if pen else r.on_probe[.Finger_Down]
		by := r.by[.Pen] if pen else r.by[.Finger]
		if downs == 0 do return .Inconclusive, fmt.tprintf("no %s touched the pad%s", "pen" if pen else "finger", diag_other_pointer(r, pen))
		if by == 0 do return .Fail, fmt.tprintf("%d downs on the pad, none answered (%d palms)", downs, r.palms)
		if m.travel < DIAG_DRAG_PT do return .Inconclusive, fmt.tprintf("dragged %.0f of %d points", m.travel, DIAG_DRAG_PT)
		if r.anomalies[.Stuck_Pressed] > 0 do return .Fail, "the pad stayed pressed after the lift"
		return .Pass, fmt.tprintf("followed %.0f points and let go", m.travel)
	case .Finger_Cancel:
		if rec[.Finger_Cancel] == 0 do return .Inconclusive, "no cancel arrived from the system"
		if r.anomalies[.Stuck_Pressed] > 0 do return .Fail, "cancelled, but something stayed pressed"
		if r.responded[.Click] > 0 do return .Fail, "the cancelled touch still clicked"
		return .Pass, fmt.tprintf("%d cancels; nothing stayed pressed", rec[.Finger_Cancel])
	case .Finger_After_Pencil, .Finger_Pencil_Switch:
		if m.after_pen_downs == 0 {
			if rec[.Pen_Down] + rec[.Pen_Move] == 0 do return .Inconclusive, "the Pencil was not used first"
			return .Inconclusive, "no finger touched the pad after the Pencil"
		}
		if m.after_pen_answered < m.after_pen_downs {
			return .Fail, fmt.tprintf("%d of %d finger downs after the Pencil answered (%d palms, pen near %v)", m.after_pen_answered, m.after_pen_downs, r.palms, m.palm_pen_near)
		}
		if r.test == .Finger_Pencil_Switch && m.switches < 2 * DIAG_TAPS do return .Inconclusive, fmt.tprintf("%d switches, all answered", m.switches)
		return .Pass, fmt.tprintf("%d finger downs after the Pencil, all answered", m.after_pen_downs)
	case .Pencil_Hover:
		if m.hover_frames == 0 do return .Inconclusive, "the pen never hovered on the pad"
		if pressed > 0 && rec[.Pen_Down] == 0 do return .Fail, "the pad was pressed with no pen down"
		if m.pen_stuck do return .Fail, fmt.tprintf("the pen still counted as near %.1f s after its last report", m.stuck_for)
		if rec[.Pen_Far] == 0 && m.pen_near_end do return .Inconclusive, "hovered; the pen has not left yet"
		return .Pass, fmt.tprintf("hovered %d frames, no press, and it left", m.hover_frames)
	case .Pencil_Hover_Contact_Lift:
		if m.order < 3 do return .Inconclusive, fmt.tprintf("saw %s so far", DIAG_ORDER_NAMES[clamp(m.order, 0, 4)])
		if m.order_broken do return .Fail, "the events came out of order (an up before its down, or a down with no near)"
		if m.pen_stuck do return .Fail, fmt.tprintf("the pen still counted as near %.1f s after its last report", m.stuck_for)
		if m.order < 4 do return .Inconclusive, "near, down and up seen; the pen has not left yet"
		return .Pass, "near, down, up, then it left"
	case .Pressure_Ramp:
		if m.pressure_samples == 0 {
			if rec[.Pen_Down] == 0 do return .Inconclusive, "the pen did not touch the pad"
			return .Unavailable, "the pen touched but no pressure was reported"
		}
		span := m.pressure_max - m.pressure_min
		if span >= 0.5 do return .Pass, fmt.tprintf("pressure %.2f to %.2f over %d reports", m.pressure_min, m.pressure_max, m.pressure_samples)
		return .Inconclusive, fmt.tprintf("pressure only %.2f to %.2f", m.pressure_min, m.pressure_max)
	case .Hover_Slider:
		if m.hover_frames < DIAG_HOVER_FRAMES / 2 do return .Inconclusive, fmt.tprintf("hovered %d frames", m.hover_frames)
		if abs(m.hover_changed) > 0 do return .Fail, fmt.tprintf("the value moved %.2f while hovering (roll reported %.1f degrees then)", m.hover_changed, m.hover_roll)
		return .Pass, fmt.tprintf("hovered %d frames; the value never moved", m.hover_frames)
	case .Hover_Button:
		if m.hover_clicks > 0 do return .Fail, fmt.tprintf("%d clicks with nothing touching", m.hover_clicks)
		if m.hover_frames < DIAG_HOVER_FRAMES / 2 do return .Inconclusive, fmt.tprintf("hovered %d frames", m.hover_frames)
		return .Pass, fmt.tprintf("hovered %d frames, no click", m.hover_frames)
	case .Hover_Menu:
		if m.hover_picks > 0 do return .Fail, fmt.tprintf("%d rows picked with nothing touching", m.hover_picks)
		if m.menu_open_frames == 0 do return .Inconclusive, "the menu's list was not opened"
		if m.hover_frames < DIAG_HOVER_FRAMES / 2 do return .Inconclusive, fmt.tprintf("hovered the open list %d frames", m.hover_frames)
		return .Pass, fmt.tprintf("hovered the open list %d frames, nothing picked", m.hover_frames)
	case .Slider_Ratio_Finger, .Slider_Ratio_Pencil:
		want: ui.Pointer_Kind = .Pen if r.test == .Slider_Ratio_Pencil else .Finger
		if m.drag_travel < 40 do return .Inconclusive, fmt.tprintf("dragged %.0f points", m.drag_travel)
		if m.drag_by != want do return .Inconclusive, fmt.tprintf("dragged by %v, not %v", m.drag_by, want)
		ratio, expected := diag_ratio(m)
		off := abs(ratio / expected - 1)
		if off > DIAG_RATIO_OFF do return .Fail, fmt.tprintf("%.3f a point against %.3f (%.0f%% off)", ratio, expected, 100 * off)
		return .Pass, fmt.tprintf("%.3f a point against %.3f", ratio, expected)
	case .Text_Focus_Finger, .Text_Focus_Pencil:
		want: ui.Pointer_Kind = .Pen if r.test == .Text_Focus_Pencil else .Finger
		if m.field_presses[want] == 0 do return .Inconclusive, fmt.tprintf("the field was not pressed by %v", want)
		if m.focused_by[want] == 0 do return .Fail, "pressed, but the field did not take the keys"
		if m.text_input_on == 0 do return .Fail, "the field took the keys, but text input never turned on"
		if m.keyboard_known && m.keyboard_shown == 0 do return .Fail, "text input is on, but the keyboard never showed"
		return .Pass, "the field took the keys and text input came on"
	case .Text_Typing:
		if rec[.Text] == 0 && rec[.Key_Down] == 0 do return .Inconclusive, "nothing was typed"
		field := diag_text(m.field[:])
		if field == DIAG_TYPE_LEFT do return .Pass, "the field holds scul"
		return .Fail, fmt.tprintf("the field holds %q, not %q", field, DIAG_TYPE_LEFT)
	case .Text_Dismiss_Reopen:
		if r.anomalies[.Keyboard_Desync] > 0 do return .Fail, "the field kept the keys with no keyboard or text input"
		if m.text_input_on >= 2 && m.text_input_off >= 1 do return .Pass, "text input went off with the keyboard and came back with the second tap"
		return .Inconclusive, fmt.tprintf("text input came on %d times and went off %d", m.text_input_on, m.text_input_off)
	case .Text_Scribble:
		if m.pen_text > 0 do return .Pass, fmt.tprintf("%d text arrivals while the Pencil wrote", m.pen_text)
		if m.field_pen_downs >= DIAG_TAPS do return .Fail, fmt.tprintf("%d Pencil strokes on the field, no text", m.field_pen_downs)
		return .Inconclusive, "no handwriting on the field yet"
	case .Home_Swipe_Baseline, .Home_Swipe_After_Pencil:
		if r.test == .Home_Swipe_After_Pencil && rec[.Pen_Down] == 0 do return .Inconclusive, "the Pencil was not used first; you decide"
		if rec[.Background] == 0 do return .Inconclusive, fmt.tprintf("the app did not go to the background (%d downs near the bottom edge); you decide", m.edge_downs)
		return .Inconclusive, fmt.tprintf("went to the background %.1f s after Start (%d downs near the bottom edge); you decide", m.first_background, m.edge_downs)
	case .Roll_Right, .Roll_Left:
		if m.rotation_reports == 0 do return .Unavailable, "no roll was reported: a Pencil Pro is needed"
		delta := m.roll_value
		if abs(delta) < DIAG_STILL do return .Inconclusive, fmt.tprintf("the value moved %.2f (roll %.1f degrees while hovering)", delta, m.roll_deg)
		up := r.test == .Roll_Right
		if (delta > 0) == up do return .Pass, fmt.tprintf("the value went %s by %.1f", "up" if up else "down", abs(delta))
		return .Fail, fmt.tprintf("the value went %s by %.1f (the app read %.1f degrees of roll)", "down" if up else "up", abs(delta), m.roll_deg)
	case .Roll_Neutral:
		if m.hover_frames < DIAG_HOVER_FRAMES do return .Inconclusive, fmt.tprintf("hovered %d frames", m.hover_frames)
		if abs(m.roll_deg) > DIAG_STILL_ROLL && abs(m.roll_value) > DIAG_STILL do return .Inconclusive, fmt.tprintf("the pencil turned %.1f degrees; hold it still", m.roll_deg)
		if abs(m.roll_value) > DIAG_STILL do return .Fail, fmt.tprintf("the value drifted %.2f with the pencil still", m.roll_value)
		return .Pass, fmt.tprintf("the value stayed within %.2f", abs(m.roll_value))
	case .Roll_Wrap:
		if m.rotation_reports == 0 do return .Unavailable, "no roll was reported: a Pencil Pro is needed"
		if m.max_step > DIAG_ROLL_JUMP do return .Fail, fmt.tprintf("the value jumped %.0f%% of its range in one frame", 100 * m.max_step)
		if !m.wrapped do return .Inconclusive, fmt.tprintf("the reported angle stayed within %.0f to %.0f: roll further", m.raw_min, m.raw_max)
		return .Pass, fmt.tprintf("wrapped past 180 degrees; the largest step was %.1f%%", 100 * m.max_step)
	}
	return .None, ""
}

// A note for a pointer test that got the other kind of pointer instead.
@(private = "file")
diag_other_pointer :: proc(r: ^Diag_Run, pen: bool) -> string {
	if r.received[.Mouse_Down] > 0 do return " (the mouse did: run this on a touch screen)"
	if !pen && r.received[.Pen_Down] > 0 do return " (the pen did)"
	if pen && r.received[.Finger_Down] > 0 do return " (a finger did)"
	return ""
}

// What a hover, contact and lift run has seen so far, by how far its order got.
@(rodata)
DIAG_ORDER_NAMES := [5]string{"nothing", "the pen near", "the pen down", "the pen up", "the pen leave"}

// The value a drag of the size slider moved per point, and what it should move: the track's
// whole length is its whole range.
diag_ratio :: proc(m: ^Diag_Measures) -> (ratio, expected: f32) {
	expected = DIAG_RANGE / DIAG_VTRACK
	if m.drag_travel <= 0 do return 0, expected
	return m.drag_value / m.drag_travel, expected
}

// Whether a value moved, allowing for float noise in a slider's fraction round trip.
diag_moved :: proc(before, after: f32) -> bool {
	return abs(after - before) > 1e-4 * DIAG_RANGE && !math.is_nan(after)
}
