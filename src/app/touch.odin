package main

import "core:math"
import "core:math/linalg"
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
	lift:      Lift_Orbit,
	hold:      Hold_History,
}

// Two fingers down, then one lifted: the one left turns the view (Nomad's orbit for when
// the model fills the screen). Only after a pair that stayed still, so the finger left
// rolling off the end of a pinch never turns the view by itself.
Lift_Orbit :: struct {
	decided: bool, // whether this lift may orbit was decided...
	armed:   bool, // ...and it may
	moving:  bool, // the finger passed the slop from `from`: it turns the view
	from:    [2]f32, // where the finger was when the other lifted
	last:    [2]f32,
	pivot:   Vec3, // decided once, as it starts to turn
}

// Two or three fingers held still: undo or redo once at the long press, then again
// every HOLD_REPEAT until a finger moves or lifts (Nomad's and Procreate's hold).
Hold_History :: struct {
	since: f64, // input_clock when the last finger landed
	late:  bool, // a finger landed HOLD_LAND or more after the first, as a palm's do
	off:   bool, // moved, zoomed, twisted or the pen came: no more for this touch
	zoom:  f32, // how much the fingers' spread changed since they landed
	twist: f32,
	fired: int, // steps due so far (one a frame)...
	taken: int, // ...and taken in this touch (nothing left to undo takes none)
	done:  int, // ...and over the whole run, for the exit stats
	ring:  f32, // the ring's fill this frame, 0 to 1, or -1 for no ring
	at:    [2]f32, // the fingers' middle
	most:  int, // 2 undoes, 3 redoes
}

// Fingers of a hold land within this many seconds of the first, as a hand's do.
HOLD_LAND :: 0.15
// Seconds between repeated steps once the hold fired.
HOLD_REPEAT :: 0.12
// A spread change this large (as a log) or a twist this large (radians) is a pinch or a
// turn beginning, not a hold.
HOLD_ZOOM :: 0.03
HOLD_TWIST :: 3 * math.PI / 180

// How many steps a hold of `held` seconds is due: one at `long`, then one every `every`.
hold_due :: proc(held, long, every: f64) -> int {
	if held < long do return 0
	return 1 + int((held - long) / every)
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
				// A finger landing ends a lift's orbit; a late one is no hold.
				t.lift = {}
				t.hold.since = now
				if now - t.fingers.began >= HOLD_LAND do t.hold.late = true
				return
			}
			// The first finger of a touch: it becomes the pointer, unless the pen is about.
			t.owner, t.gesture, t.tap = .None, false, 0
			t.twist, t.rolling, t.adjust, t.axis = 0, false, {}, -1
			t.lift = {}
			t.hold = {since = now, zoom = 1, done = t.hold.done, ring = -1}
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
			// A tap whose finger left turned the view was an orbit.
			if tap >= 2 && t.gesture && t.owner == .Viewport && !t.lift.moving do t.tap = tap
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
	t.hold.ring = -1
	if t.owner != .Viewport || !t.gesture {
		_ = ui.fingers_change(&t.fingers) // keep the measure current for when it is
		return
	}
	change := ui.fingers_change(&t.fingers)
	f := &t.fingers
	if touch_lift_orbit(app, input) do return
	// Otherwise only while every finger of the gesture is still down: lifting one never
	// turns what is left into a different gesture.
	if f.count < 2 || f.count != f.most do return
	// A hold that undoes or redoes keeps the touch for itself.
	if touch_hold_history(app, change) do return
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

// The finger left down after one of two lifted turns the view, once it moves past the
// slop (Lift_Orbit). Returns whether the touch is in that state, so nothing else reads it.
@(private = "file")
touch_lift_orbit :: proc(app: ^App, input: ^Viewport_Input) -> bool {
	t := &app.touch
	f := &t.fingers
	l := &t.lift
	if f.count != 1 || f.most != 2 do return false
	slop := app.kit.ctx.theme.slop * app.kit.scale
	if !l.decided {
		l.decided = true
		still := f.travel <= slop && t.hold.fired == 0
		l.armed = app.nav.lift_one_orbit && still && !t.palm && !t.pen_near && !t.pen_down
		l.from, l.last = f.down[0].at, f.down[0].at
	}
	// The pen coming near is the hand going back to work: the finger stops turning.
	if t.pen_near || t.pen_down do l.armed = false
	if !l.armed do return false
	at := f.down[0].at
	if !l.moving {
		if linalg.length(at - l.from) <= slop do return true
		l.moving, l.last = true, at
		l.pivot, app.pivot.from = orbit_pivot(app, at, input.size)
		app.pivot.used = l.pivot
		return true
	}
	input.touch_orbit, input.touch_pivot = at - l.last, l.pivot
	l.last = at
	return true
}

// Two or three fingers held still undo or redo (Hold_History). Returns whether the hold
// has fired, after which it keeps the touch: no pan, zoom, roll or size and strength.
@(private = "file")
touch_hold_history :: proc(app: ^App, change: ui.Finger_Change) -> bool {
	t := &app.touch
	f := &t.fingers
	h := &t.hold
	h.zoom *= change.zoom
	h.twist += change.twist
	h.at, h.most = change.middle, f.most
	if h.off do return h.fired > 0
	slop := app.kit.ctx.theme.slop * app.kit.scale
	still := f.travel <= slop && abs(math.ln(h.zoom)) < HOLD_ZOOM && abs(h.twist) < HOLD_TWIST
	if !app.nav.hold_history || f.most > 3 || t.palm || t.pen_near || t.pen_down || h.late || !still {
		h.off = true
		return h.fired > 0
	}
	theme := app.kit.ctx.theme
	held := input_clock(app) - h.since
	h.ring = clamp(f32(held - f64(theme.long_ring)) / (theme.long_press - theme.long_ring), 0, 1) if held >= f64(theme.long_ring) else -1
	// One step a frame at most: an undo that swaps a mesh can take longer than the gap.
	if hold_due(held, f64(theme.long_press), HOLD_REPEAT) > h.fired {
		h.fired += 1
		stroke_finish(app)
		if f.most == 2 && history_can_undo(app) {
			history_undo(app)
			h.taken, h.done = h.taken + 1, h.done + 1
		} else if f.most == 3 && history_can_redo(app) {
			history_redo(app)
			h.taken, h.done = h.taken + 1, h.done + 1
		}
	}
	return h.fired > 0
}

// Radians two fingers turn before the twist rolls the view.
TWIST_DEADZONE :: 10 * math.PI / 180

// How long one finger on the model waits before it sculpts, unless it moves further
// than the slop first: long enough for a second finger landing with it to make the
// touch a gesture before any clay moves, short enough not to feel late (Nomad waits too).
FINGER_HOLD :: 90 * time.Millisecond
