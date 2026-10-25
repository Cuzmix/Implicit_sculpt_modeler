package main

import "core:math/linalg"
import "core:time"
import sdl "vendor:sdl3"

// Fingers on a touch screen, the way tablet sculpting apps use them. SDL turns the first
// finger into the left mouse button (marked TOUCH_MOUSEID), which the interface's
// buttons and sliders take as they are; in the viewport touch_apply then reads fingers as:
// - one finger turns the view, or sculpts as the mouse does with Finger sculpts on;
// - two or more pan by their middle and zoom by their spread;
// - a quick tap of two fingers undoes, of three redoes.
// The pen is never a finger: it sculpts as the mouse does.
Touch :: struct {
	ids:     [TOUCH_MAX_FINGERS]sdl.FingerID,
	pos:     [TOUCH_MAX_FINGERS][2]f32, // window coordinates
	count:   int,
	gesture: bool, // two or more fingers have been down since none were
	most:    int, // the most fingers down at once since none were
	down_at: time.Tick, // when the first of them went down
	travel:  f32, // how far their middle and spread moved since then (window coordinates)
	// Last frame's middle and spread of the fingers down, to take this frame's change
	// from; not measured once a finger came or went.
	middle:   [2]f32,
	spread:   f32,
	measured: bool,
	tap:      int, // fingers of a tap made since last frame, 0 for none
	finger_mouse:  bool, // the left button down now is a finger's
	finger_sculpt: bool, // one finger sculpts instead of turning the view (Menu > Finger sculpts)
}

TOUCH_MAX_FINGERS :: 10 // fingers beyond this many are ignored
TOUCH_TAP :: 250 * time.Millisecond // a tap lifts every finger within this...
TOUCH_TAP_PX :: 24 // ...having moved their middle and spread less than this, in window coordinates

// Folds one SDL event into the fingers held.
touch_event :: proc(t: ^Touch, e: ^sdl.Event, window: ^sdl.Window) {
	#partial switch e.type {
	case .MOUSE_BUTTON_DOWN:
		if e.button.button == sdl.BUTTON_LEFT do t.finger_mouse = e.button.which == sdl.TOUCH_MOUSEID
	case .FINGER_DOWN, .FINGER_MOTION, .FINGER_UP, .FINGER_CANCELED:
		f := e.tfinger
		// A pen's and a mouse's stand-in touches are not fingers.
		if f.touchID == sdl.PEN_TOUCHID || f.touchID == sdl.MOUSE_TOUCHID do return
		w, h: i32
		_ = sdl.GetWindowSize(window, &w, &h)
		at := [2]f32{f.x * f32(w), f.y * f32(h)}
		i := -1
		for id, k in t.ids[:t.count] {
			if id == f.fingerID do i = k
		}
		#partial switch e.type {
		case .FINGER_DOWN:
			if i >= 0 || t.count == TOUCH_MAX_FINGERS do return
			if t.count == 0 {
				t.down_at, t.most, t.travel = time.tick_now(), 0, 0
			}
			t.ids[t.count], t.pos[t.count] = f.fingerID, at
			t.count += 1
			t.most = max(t.most, t.count)
			if t.count >= 2 do t.gesture = true
			t.measured = false
		case .FINGER_MOTION:
			if i >= 0 do t.pos[i] = at
		case:
			if i < 0 do return
			t.count -= 1
			t.ids[i], t.pos[i] = t.ids[t.count], t.pos[t.count]
			t.measured = false
			if t.count > 0 do return
			quick := time.tick_since(t.down_at) < TOUCH_TAP && e.type == .FINGER_UP
			if t.gesture && quick && t.travel < TOUCH_TAP_PX do t.tap = t.most
			t.gesture = false
		}
	}
}

// Turns this frame's viewport input into what the fingers mean (see Touch). Runs once
// the interface has said what the viewport saw, before the camera and the tools read it.
touch_apply :: proc(app: ^App, input: ^Viewport_Input) {
	t := &app.touch
	if t.tap > 0 {
		stroke_finish(app)
		if t.tap == 2 && history_can_undo(app) do history_undo(app)
		if t.tap >= 3 && history_can_redo(app) do history_redo(app)
		t.tap = 0
	}
	if t.gesture {
		input.primary, input.press, input.smooth, input.invert, input.alt = false, false, false, false, false
		input.orbit_drag, input.pan_drag = false, false
		if t.count < 2 do return
		middle: [2]f32
		spread: f32
		for p in t.pos[:t.count] do middle += p / f32(t.count)
		for p in t.pos[:t.count] do spread += linalg.length(p - middle) / f32(t.count)
		if t.measured {
			input.touch_pan = middle - t.middle
			if t.spread > 0 && spread > 0 do input.touch_zoom = spread / t.spread
			t.travel += linalg.length(middle - t.middle) + abs(spread - t.spread)
		}
		t.middle, t.spread, t.measured = middle, spread, true
		return
	}
	if t.finger_mouse && !t.finger_sculpt && input.primary {
		input.orbit_drag = true
		input.primary, input.press, input.smooth, input.invert, input.alt = false, false, false, false, false
	}
}
