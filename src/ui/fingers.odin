package ui

import "core:math"
import "core:math/linalg"

// Fingers on a touch screen and how they move together, apart from what that means to
// the app: which are down, where, how far their middle moved, their spread grew and
// they twisted since last asked, and whether they made a tap. The app feeds it its
// platform's touch events (ids and window positions) and decides what each gesture
// does; nothing here knows SDL.
FINGERS_MAX :: 10 // fingers beyond this many are ignored
FINGER_TAP :: 0.25 // seconds: a tap lifts every finger within this of the first going down...
FINGER_TAP_TRAVEL :: 24 // ...none of them having strayed further than this from where it went down

Finger :: struct {
	id:    u64,
	at:    [2]f32,
	start: [2]f32, // where it went down
}

Fingers :: struct {
	down:     [FINGERS_MAX]Finger,
	count:    int,
	most:     int, // the most down at once since none were
	began:    f64, // when the first of them went down (the caller's clock, seconds)
	travel:   f32, // the furthest any of them strayed from where it went down
	// What was measured last time (fingers_change), to take the next change from; not
	// measured once a finger came or went.
	middle:   [2]f32,
	spread:   f32,
	angle:    f32,
	measured: bool,
}

// How the fingers down moved since fingers_change was last called.
Finger_Change :: struct {
	pan:    [2]f32, // their middle moved this far
	zoom:   f32, // their spread grew this many times: 1 for none
	twist:  f32, // radians the first two turned, clockwise on screen (y down); 0 with one
	middle: [2]f32, // their middle now
}

// A finger went down at `at`. Returns true when it is the first since none were down,
// which starts a new touch sequence.
fingers_down :: proc(f: ^Fingers, id: u64, at: [2]f32, now: f64) -> (first: bool) {
	if fingers_index(f, id) >= 0 || f.count == FINGERS_MAX do return false
	first = f.count == 0
	if first do f.began, f.most, f.travel = now, 0, 0
	f.down[f.count] = {id, at, at}
	f.count += 1
	f.most = max(f.most, f.count)
	f.measured = false
	return
}

fingers_move :: proc(f: ^Fingers, id: u64, at: [2]f32) {
	i := fingers_index(f, id)
	if i < 0 do return
	f.down[i].at = at
	f.travel = max(f.travel, linalg.length(at - f.down[i].start))
}

// A finger came up, or the system cancelled it. Returns how many fingers made a tap
// when this was the last one up and they made one, else 0. A cancelled touch is never a
// tap. `known` is false for a finger that was not down (ignored, or past FINGERS_MAX).
fingers_up :: proc(f: ^Fingers, id: u64, now: f64, cancelled := false) -> (tap: int, known: bool) {
	i := fingers_index(f, id)
	if i < 0 do return 0, false
	f.count -= 1
	f.down[i] = f.down[f.count]
	f.measured = false
	if f.count > 0 do return 0, true
	if !cancelled && now - f.began < FINGER_TAP && f.travel < FINGER_TAP_TRAVEL do return f.most, true
	return 0, true
}

// Forgets every finger, as when the window loses the touch.
fingers_clear :: proc(f: ^Fingers) {
	f.count, f.measured = 0, false
}

// How the fingers down moved since the last call: nothing on the first call after a
// finger came or went, which only measures where they are.
fingers_change :: proc(f: ^Fingers) -> (change: Finger_Change) {
	change.zoom = 1
	if f.count == 0 {
		f.measured = false
		return
	}
	middle: [2]f32
	for d in f.down[:f.count] do middle += d.at / f32(f.count)
	spread: f32
	for d in f.down[:f.count] do spread += linalg.length(d.at - middle) / f32(f.count)
	angle: f32
	if f.count >= 2 {
		v := f.down[1].at - f.down[0].at
		angle = math.atan2(v.y, v.x)
	}
	change.middle = middle
	if f.measured {
		change.pan = middle - f.middle
		if f.spread > 0 && spread > 0 do change.zoom = spread / f.spread
		if f.count >= 2 {
			d := angle - f.angle
			// The shorter way round, so crossing the half turn is a small twist.
			if d > math.PI do d -= 2 * math.PI
			if d < -math.PI do d += 2 * math.PI
			change.twist = d
		}
	}
	f.middle, f.spread, f.angle, f.measured = middle, spread, angle, true
	return
}

@(private)
fingers_index :: proc(f: ^Fingers, id: u64) -> int {
	for d, i in f.down[:f.count] do if d.id == id do return i
	return -1
}
