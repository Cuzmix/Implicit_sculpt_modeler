package main

import "core:math"
import "core:time"
import sdl "vendor:sdl3"

import "../ui"

// Fingers and the pen on a touch screen, the way ZBrush for iPad uses them. Every touch,
// from its first finger down to its last finger up, has one owner, decided by where the
// first finger landed, and keeps it to the end (as React Native's touch responder does):
// - on a panel, the panels have it: that finger is the pointer, and any other fingers of
//   the touch do nothing, so a finger resting on a slider never pinches the view;
// - on the viewport, one finger is the pointer, which navigate.odin gives to the tool or
//   to the camera; two or more navigate (pan, pinch to zoom, twist to roll), three drag
//   the brush's size and strength, and a quick tap of two fingers undoes, of three redoes.
//   A second finger ends what the first began, and lifting fingers never hands the touch
//   back to the one left down.
// SDL's own turning of the first finger into the mouse is off (platform_hints): it moves
// the pointer to wherever a finger lands with no notice, which turned the camera by the
// jump, and it gives the pointer to any finger, a palm's too. Here the pointer jumps
// without counting as a drag, and only the touch's first finger drives it.
// The pen is never a finger. While it is near the screen or on it, a finger touching on
// its own is taken for the hand holding it and does nothing (two fingers still navigate);
// the pen going down ends a touch in progress the same way, cancelled.
// A finger on a modifier rail button is no part of any touch: the rail keeps it
// (modifiers.odin), so it holds Smooth or Mask while another finger or the pen works.
Touch :: struct {
	fingers:   ui.Fingers,
	owner:     Touch_Owner,
	pointer:   u64, // the finger that is the pointer: the touch's first...
	pointing:  bool, // ...until it lifts, or the touch becomes a gesture or is cancelled
	gesture:   bool, // two or more fingers have been down in this touch
	palm:      bool, // the touch began with the pen near: one finger does nothing
	tap:       int, // fingers of a tap on the viewport made since last frame, 0 for none
	cancelled: bool, // the system or the pen cancelled the pointer this frame
	pen_down:  bool, // the pen's tip is on the screen
	pen_near:  bool, // the pen is near enough for the screen to see it
	// The gesture's running totals, from the touch's first finger down (touch_route).
	twist:     f32,
	rolling:   bool, // the twist passed TWIST_DEADZONE: the view rolls with it
	adjust:    [2]f32, // three fingers' travel...
	axis:      int, // ...and what it sets: 0 strength, 1 size, -1 not yet decided
}

// Who a touch belongs to.
Touch_Owner :: enum u8 {
	None, // no finger is down, or the interface has not yet said where the first landed
	Interface, // it began on a panel
	Viewport, // it began on the viewport
}

// Scripted fingers (--ui-events) come from this touch device, which counts as a screen.
TOUCH_SCRIPTED :: sdl.TouchID(0x5c1_f0e)

// Folds one SDL event into the fingers, the pen, the Device's pointer and this frame's
// pointer samples.
touch_event :: proc(app: ^App, e: ^sdl.Event, window: ^sdl.Window) {
	t := &app.touch
	d := &app.device
	#partial switch e.type {
	case .PEN_PROXIMITY_IN:  t.pen_near = true
	case .PEN_PROXIMITY_OUT: t.pen_near, t.pen_down = false, false
	case .PEN_DOWN:
		t.pen_down, t.pen_near = true, true
		// A hand resting on the screen before the pen came down was not meant: cancel it.
		if app.nav.palm_rejection && t.fingers.count > 0 do touch_cancel(app, false)
	case .PEN_UP:
		t.pen_down = false
	case .FINGER_DOWN, .FINGER_MOTION, .FINGER_UP, .FINGER_CANCELED:
		f := e.tfinger
		// Only fingers on a screen: a laptop's touchpad also reports fingers, at positions on
		// the pad rather than in the window, which must never pan or pinch the view; and the
		// pen's and the mouse's stand-in fingers (off in platform_hints, should a platform
		// send them anyway) are not fingers.
		if f.touchID == sdl.PEN_TOUCHID || f.touchID == sdl.MOUSE_TOUCHID do return
		if f.touchID != TOUCH_SCRIPTED && sdl.GetTouchDeviceType(f.touchID) != .DIRECT do return
		w, h: i32
		_ = sdl.GetWindowSize(window, &w, &h)
		at := [2]f32{f.x * f32(w), f.y * f32(h)}
		id := u64(f.fingerID)
		now := input_clock(app)
		slop := app.kit.ctx.theme.slop * app.kit.scale
		// A finger on the modifier rail is the rail's alone (modifiers.odin): it is never the
		// pointer, never part of a gesture or a palm, and the pen landing leaves it be.
		#partial switch e.type {
		case .FINGER_DOWN:
			if which, ok := rail_claims(app, at); ok {
				_ = rail_finger_down(&app.rail, id, which, at, now)
				return
			}
			if !ui.fingers_down(&t.fingers, id, at, now) {
				if t.fingers.count >= 2 && !t.gesture do touch_gesture_begin(app)
				return
			}
			// The first finger of a touch: it becomes the pointer, unless the pen is about.
			t.owner, t.gesture, t.tap = .None, false, 0
			t.twist, t.rolling, t.adjust, t.axis = 0, false, {}, -1
			t.palm = app.nav.palm_rejection && (t.pen_near || t.pen_down)
			t.pointing = !t.palm
			t.pointer = id
			if t.palm do return
			d.pointer = .Finger
			device_move(d, at, jump = true)
			device_button(d, .Left, true, e.common.timestamp)
			d.input_at = e.common.timestamp
			append(&app.samples, Input_Sample{at, 1, .Press, {}})
		case .FINGER_MOTION:
			if rail_finger_move(&app.rail, id, at) do return
			ui.fingers_move(&t.fingers, id, at)
			if t.pointing && id == t.pointer {
				d.pointer = .Finger
				device_move(d, at)
				d.input_at = e.common.timestamp
				append(&app.samples, Input_Sample{at, 1, .Move, {}})
			}
		case:
			cancelled := e.type == .FINGER_CANCELED
			if rail_finger_up(&app.rail, id, now, cancelled, slop) do return
			tap, known := ui.fingers_up(&t.fingers, id, now, cancelled)
			if !known do return
			if t.pointing && id == t.pointer {
				t.pointing = false
				d.pointer = .Finger
				device_move(d, at)
				device_button(d, .Left, false, e.common.timestamp)
				append(&app.samples, Input_Sample{at, 1, .Release, {}})
				if cancelled do d.cancel, t.cancelled = true, true
			}
			// Only a gesture's tap is the touch's own: one finger's tap is the pointer's
			// click, which the panels or the tool take.
			if tap >= 2 && t.gesture && t.owner == .Viewport do t.tap = tap
		}
	case .WINDOW_FOCUS_LOST, .DID_ENTER_BACKGROUND:
		// Fingers lifted while the app is away never arrive: forget them, cancelled.
		if t.fingers.count > 0 do touch_cancel(app, true)
		rail_forget(&app.rail)
	}
}

// A second finger joined: the touch is now a gesture, and on the viewport the pointer
// the first finger drove lets go (navigate.odin drops a stroke it had not yet begun).
// While nobody owns the touch yet (both fingers came within one frame), touch_route lets
// go once the interface has said where the first one landed: on a panel it keeps it.
@(private = "file")
touch_gesture_begin :: proc(app: ^App) {
	t := &app.touch
	t.gesture = true
	if t.owner == .Viewport do touch_release_pointer(app, false)
}

// Lets go of the pointer a finger drove, where it is now.
touch_release_pointer :: proc(app: ^App, cancelled: bool) {
	t := &app.touch
	d := &app.device
	if !t.pointing do return
	t.pointing = false
	device_button(d, .Left, false, sdl.GetTicksNS())
	append(&app.samples, Input_Sample{d.mouse, 1, .Release, {}})
	if cancelled do d.cancel, t.cancelled = true, true
}

// Ends the touch in progress as cancelled: the pointer lets go without a click and the
// stroke it drove is taken back, and the fingers still down do nothing until all are up.
// A touch that drove no pointer (a palm, a gesture) has nothing to cancel in the drag, so
// a pen landing beside a resting hand sculpts at once.
@(private = "file")
touch_cancel :: proc(app: ^App, forget: bool) {
	t := &app.touch
	touch_release_pointer(app, true)
	t.gesture, t.tap = false, 0
	// The rest of the touch is nobody's: as a palm's.
	t.palm = true
	if forget do ui.fingers_clear(&t.fingers)
}

// Seconds on a steady clock, for every timed gesture: taps, holds, the pie's tap. With
// --ui-dt it is the interface's fixed clock, which moves the same amount each frame, so a
// scripted finger held N frames is the same gesture however slowly the frames come.
input_clock :: proc(app: ^App) -> f64 {
	if app.kit.fixed_dt > 0 do return app.kit.ctx.time
	return f64(sdl.GetTicksNS()) / 1e9
}

// Decides who has the touch once the interface said where its first finger landed,
// and turns two or more fingers on the viewport into this frame's navigation. Runs in
// kit_viewport_input after the interface laid out, before the pointer drag is routed.
touch_route :: proc(app: ^App, input: ^Viewport_Input) {
	t := &app.touch
	if t.fingers.count == 0 && t.owner != .None && !t.pointing {
		// The touch ended; the next one is decided afresh.
		t.owner = .None
	}
	if t.fingers.count > 0 && t.owner == .None {
		// A palm (or a cancelled touch) never pressed the pointer; it lies on the
		// viewport as far as two-finger gestures go.
		t.owner = .Viewport if t.palm || ui.viewport_dragging(&app.kit.ctx) else .Interface
		if t.owner == .Viewport && t.gesture do touch_release_pointer(app, false)
	}
	if t.tap > 0 {
		if app.nav.tap_history {
			stroke_finish(app)
			if t.tap == 2 && history_can_undo(app) do history_undo(app)
			if t.tap >= 3 && history_can_redo(app) do history_redo(app)
		}
		t.tap = 0
	}
	if t.owner != .Viewport || !t.gesture {
		_ = ui.fingers_change(&t.fingers) // keep the measure current for when it is
		return
	}
	change := ui.fingers_change(&t.fingers)
	f := &t.fingers
	// Only while every finger of the gesture is still down: lifting one never turns what
	// is left into a different gesture.
	if f.count < 2 || f.count != f.most do return
	nav := app.nav
	if f.most == 2 {
		if nav.two_finger_pan do input.touch_pan = change.pan * nav.pan_speed
		if nav.pinch_zoom && change.zoom != 1 {
			input.touch_zoom = math.pow(change.zoom, nav.zoom_speed)
			if nav.zoom_toward do input.touch_zoom_at = change.middle - input.size * 0.5
		}
		// Twisting rolls the view (ZBrush's Allow Roll Gesture), once the fingers turned
		// further than a pinch's wobble, and only where the view may roll.
		if nav.twist_roll && nav.orbit_style == .Free {
			t.twist += change.twist
			if abs(t.twist) > TWIST_DEADZONE do t.rolling = true
			if t.rolling do input.touch_roll = change.twist
		}
	} else if nav.three_finger {
		// Three fingers: up and down sizes the brush, sideways sets its strength, whichever
		// way they went first past the slop (as Nomad's and ZBrush's three-finger drags).
		t.adjust += change.pan
		if t.axis < 0 && max(abs(t.adjust.x), abs(t.adjust.y)) > app.kit.ctx.theme.slop * app.kit.scale {
			t.axis = 1 if abs(t.adjust.y) >= abs(t.adjust.x) else 0
		}
		switch t.axis {
		case 1:
			app.brush.radius_px = clamp(app.brush.radius_px * math.pow(2, -change.pan.y / (200 * app.kit.scale)), MIN_RADIUS_PX, MAX_RADIUS_PX)
		case 0:
			s := brush_strength(app)
			s^ = clamp(s^ + change.pan.x / (400 * app.kit.scale), MIN_STRENGTH, 1)
		}
	}
}

// Radians two fingers turn before the twist rolls the view.
TWIST_DEADZONE :: 10 * math.PI / 180

// How long one finger on the model waits before it sculpts, unless it moves further
// than the slop first: long enough for a second finger landing with it to make the
// touch a gesture before any clay moves, short enough not to feel late (Nomad waits too).
FINGER_HOLD :: 90 * time.Millisecond
