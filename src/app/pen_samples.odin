package main

import "core:math"
import sdl "vendor:sdl3"

// Every sample a pen makes, not one a frame. Windows, Android and iOS gather a pen's
// samples between two frames into one (a WM_POINTERUPDATE with a history, a MotionEvent
// with historical samples, a UITouch with coalesced touches), and SDL 3.4 reads only the
// newest of each, so a fast stroke on a tablet arrived as one sample a frame: its path was
// laid as chords and its pressure and lean changed in steps. Each platform's bridge sends
// the older samples ahead of SDL's own event for the newest, as SDL user events of
// `Pen_Samples.event_type` (the Windows message hook in pen_samples_windows.odin, the
// activity's touch dispatch in android/.../SculptActivity.java with android_main.c, a
// gesture recogniser in ios/sculpt_ios.m), and the app slots them in before the newest
// when SDL's pen motion arrives. X11 and Wayland already deliver every sample.
//
// A sample's place is sent as an offset from the newest, since only SDL knows where its
// window's points are (Android's activity and SDL's surface may sit apart; a Windows
// tablet maps through its own rectangle): the offset needs only that both are measured
// alike. Its pressure and lean are its own.

Pen_Samples :: struct {
	// The user event type of a coalesced sample, 0 until registered; the type after it is
	// a predicted one (the brush ring's, never a dab's).
	event_type: u32,
	// Samples that arrived for the pen motion SDL has yet to report, oldest first.
	waiting:       [PEN_WAITING_MAX]Pen_Sample,
	waiting_count: int,
	// Where in App.samples the newest pen sample is while its update's axes may still
	// come: SDL reports a pen's place before its pressure and lean, so without this each
	// sample carried the update before's. -1 when none is open.
	open:          int,
	// For the exit stats and the Stats panel: frames with the primary button held over the
	// viewport and samples in them, the most in one frame, the frames' samples in all,
	// and how many of those the bridges gave on top of SDL's.
	frames:        int,
	most:          int,
	total:         int,
	coalesced:     int,
}

// One coalesced sample: where it was from the newest, how hard the pen pressed (below 0
// for as the newest) and its lean, in the platform's raw terms (pen_sample_lean).
Pen_Sample :: struct {
	offset:   [2]f32,
	pressure: f32,
	lean:     [2]f32,
}

// A WM_POINTERUPDATE holds at most a few dozen samples at a frame of 60 Hz; more than this
// waiting means SDL's newest never came, and the oldest are dropped.
PEN_WAITING_MAX :: 64

// Registers the two user event types the bridges send (the samples, then the predicted
// sample), and starts this platform's bridge. A failure leaves the type 0, and then the
// pen gives one sample a frame as before.
pen_samples_init :: proc(app: ^App, window: ^sdl.Window = nil) {
	p := &app.pen_samples
	p.open = -1
	t := sdl.RegisterEvents(2)
	if t == 0 do return
	p.event_type = t
	pen_samples_platform_start(p.event_type, window)
}

// Packs a sample as the bridges do: the offset's two floats in data1, the pressure and the
// first lean number in data2, the second lean number's bits in the code.
pen_sample_event :: proc(type: u32, s: Pen_Sample) -> sdl.Event {
	e: sdl.Event
	e.user.type = sdl.EventType(type)
	e.user.timestamp = sdl.GetTicksNS()
	e.user.data1 = rawptr(uintptr(u64(transmute(u32)s.offset.x) | u64(transmute(u32)s.offset.y) << 32))
	e.user.data2 = rawptr(uintptr(u64(transmute(u32)s.pressure) | u64(transmute(u32)s.lean.x) << 32))
	e.user.code = transmute(i32)s.lean.y
	return e
}

// Folds one SDL event in, and says whether it was a coalesced sample, which nothing else
// may then see.
pen_samples_event :: proc(app: ^App, e: ^sdl.Event) -> bool {
	p := &app.pen_samples
	if p.event_type == 0 do return false
	if u32(e.type) == p.event_type {
		a := u64(uintptr(e.user.data1))
		b := u64(uintptr(e.user.data2))
		s := Pen_Sample {
			offset   = {transmute(f32)u32(a), transmute(f32)u32(a >> 32)},
			pressure = transmute(f32)u32(b),
			lean     = {transmute(f32)u32(b >> 32), transmute(f32)e.user.code},
		}
		finite :: proc(x: f32) -> bool {return !math.is_nan(x) && !math.is_inf(x)}
		if !finite(s.offset.x) || !finite(s.offset.y) || !finite(s.pressure) || !finite(s.lean.x) || !finite(s.lean.y) do return true
		if p.waiting_count == PEN_WAITING_MAX {
			copy(p.waiting[:], p.waiting[1:])
			p.waiting_count -= 1
		}
		p.waiting[p.waiting_count] = s
		p.waiting_count += 1
		return true
	}
	// The second type: a platform's predicted sample (the iPad's predicted touches), its
	// offset from the newest in data1, for the brush ring only (cursor_lead).
	if u32(e.type) == p.event_type + 1 {
		a := u64(uintptr(e.user.data1))
		offset := [2]f32{transmute(f32)u32(a), transmute(f32)u32(a >> 32)}
		if !math.is_nan(offset.x + offset.y) && !math.is_inf(offset.x + offset.y) do app.predict.platform, app.predict.platform_age = offset, 0
		return true
	}
	#partial switch e.type {
	case .PEN_MOTION:
		// A new update of the pen: the last one's axes are all in.
		p.open = -1
	case .PEN_PROXIMITY_OUT, .PEN_UP, .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		// Samples waiting belong to a motion that will not come.
		p.waiting_count = 0
	}
	return false
}

// Adds the pen's motion to `pos` (window points) to the frame's samples: first the samples
// that came before it, then its own, which stays open for its update's axes.
pen_samples_motion :: proc(app: ^App, pos: [2]f32) {
	p := &app.pen_samples
	for s in p.waiting[:p.waiting_count] {
		pressure := s.pressure if s.pressure >= 0 else app.pen_pressure
		append(&app.samples, Input_Sample{pos + s.offset, clamp(pressure, 0, 1), .Move, pen_sample_lean(s.lean)})
	}
	p.coalesced += p.waiting_count
	p.waiting_count = 0
	append(&app.samples, Input_Sample{pos, app.pen_pressure, .Move, app.pen_tilt})
	p.open = len(app.samples) - 1
}

// The pen's button sample (its tip down or up) at `pos`, open for its update's axes too.
pen_samples_button :: proc(app: ^App, pos: [2]f32, kind: Sample_Kind) {
	append(&app.samples, Input_Sample{pos, app.pen_pressure, kind, app.pen_tilt})
	app.pen_samples.open = len(app.samples) - 1
}

// The pen's pressure or lean changed: the newest pen sample, if its update is still
// coming in, takes it.
pen_samples_axes :: proc(app: ^App) {
	p := &app.pen_samples
	if p.open < 0 || p.open >= len(app.samples) do return
	s := &app.samples[p.open]
	s.pressure, s.tilt = app.pen_pressure, app.pen_tilt
}

// The frame's events are all read: nothing waits or stays open into the next frame, whose
// samples start afresh.
pen_samples_frame_end :: proc(app: ^App) {
	p := &app.pen_samples
	p.waiting_count = 0
	p.open = -1
}

// Counts a frame whose stroke had `count` samples, for the stats.
pen_samples_count :: proc(app: ^App, count: int) {
	p := &app.pen_samples
	if count <= 0 do return
	p.frames += 1
	p.total += count
	p.most = max(p.most, count)
}

// A coalesced sample's lean as every platform reports it (degrees toward the right and
// toward the bottom of the screen of the pen's top), from what this platform's bridge
// sends: an Android pen's AXIS_TILT and AXIS_ORIENTATION, an Apple Pencil's azimuth in
// the view and altitude (radians both), or elsewhere the lean in degrees already.
pen_sample_lean :: proc(raw: [2]f32) -> [2]f32 {
	when ODIN_PLATFORM_SUBTARGET == .Android {
		return pencil_tilt_android(raw.x, raw.y)
	} else when ODIN_PLATFORM_SUBTARGET_IOS {
		return pencil_lean_uikit(raw.x, raw.y)
	} else {
		return raw
	}
}

when ODIN_OS != .Windows {
	// Starts the bridge that sends the pen's coalesced samples as `event_type`: the iPad's
	// recogniser on SDL's view of `window`, or Android's activity; nothing elsewhere.
	pen_samples_platform_start :: proc(event_type: u32, window: ^sdl.Window) {
		when ODIN_PLATFORM_SUBTARGET_IOS {
			if window != nil do sculpt_ios_samples_start(window, event_type)
		} else when ODIN_PLATFORM_SUBTARGET == .Android {
			sculpt_android_samples_start(event_type)
		}
	}
}
