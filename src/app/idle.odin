package main

import "core:hash/xxhash"
import "core:mem"
import "core:time"
import sdl "vendor:sdl3"

import "../render"

// Resting when idle (Settings > System > Rest when idle). The frame loop otherwise
// draws at the screen's rate whether or not anything changes, which keeps the CPU and
// GPU awake and costs a tablet's battery. Once frames have changed nothing for
// IDLE_AFTER (no input, nothing held down, the same panels, nothing redrawn in the
// viewport, no stroke, replay, script, studio samples, thumbnails, Home's pictures or
// a thumbnail view waiting to be drawn), the loop waits for the next event before each
// frame, as an app with retained panels would, waking at least every IDLE_TICK so
// timers (autosave, the Blender link, work that finished on another thread) still come
// through. Any event ends the rest at once, and the frame it starts reads that input, so
// the first stroke after a rest is not late. A tick that ran out with no event starts a
// frame that takes no swapchain image and submits nothing (frame_step): the interface is
// laid out, so a change in it is seen and the next frame draws it, but the screen keeps
// the last frame and the GPU stays asleep. "Changed nothing" is judged from what was
// drawn, not from a list of what might animate: a panel fading or a progress bar moving
// changes the interface's triangles.
//
// In the background the loop holds instead (background_step): iOS ends an app that keeps
// the GPU busy there, and a frame nobody sees costs the battery. Android's SDL holds the
// whole loop inside its event pump from the pause to the resume, so there the app learns
// of the background and the foreground together on coming back, and the hold is a frame
// long; a desktop system sends neither event, but a scripted run's bg and fg do.
IDLE_AFTER :: 1 * time.Second
IDLE_TICK :: 100 // milliseconds
// How long a frame in the background waits between looks at the events: the life-cycle
// events wake it at once, and the autosave's hand-over needs no more than this.
BACKGROUND_TICK :: 250 // milliseconds

Idle :: struct {
	quiet_since: time.Tick, // the first frame of the run that changed nothing (zero: the last frame changed something)
	ui_hash:     u64, // the last frame's interface triangles and commands
	thumbs:      int, // thumbnails drawn so far (thumb_slots.drawn), to see a new one
	events:      int, // SDL events read this frame
	forced:      bool, // --idle-sleep: rest in a scripted run too, to test it
	background:  bool, // the app is in the background: the loop holds (background_step)
	// For the exit stats: how often the loop rested, for how long in all, how many of
	// those frames drew nothing (the tick ran out with no event), how many of those still
	// recorded GPU work (which the frame after shows), and how many frames were held.
	rests:       int,
	rest_ms:     f64,
	skipped:     int,
	recorded:    int,
	held:        int,
}

// Whether this run may rest at all: an interactive run with the setting on. A scripted
// run (tests, benchmarks, --frames) never does unless --idle-sleep asks, so its frames
// stay as many and as timed as before.
idle_allowed :: proc(app: ^App, interactive: bool) -> bool {
	return app.idle_sleep && (interactive || app.idle.forced)
}

// Waits for an event or `ms` milliseconds, leaving the event queued for the frame's own
// PollEvent loop; whether one waits. On the iPad SDL has no wait of its own and would
// poll every millisecond, so the wait there runs the main run loop, which sleeps until
// a touch, a notification or the time (ios_wait_events).
idle_wait :: proc(ms: i32) -> bool {
	when ODIN_PLATFORM_SUBTARGET_IOS do return ios_wait_events(ms)
	else do return sdl.WaitEventTimeout(nil, ms)
}

// At the top of a frame: rests until an event comes or IDLE_TICK passes, when the
// frames have changed nothing for IDLE_AFTER. `rested` is a tick that ran out with no
// event: the frame then draws nothing (frame_step).
idle_rest :: proc(app: ^App, interactive: bool) -> (rested: bool) {
	id := &app.idle
	id.events = 0
	if !idle_allowed(app, interactive) || id.quiet_since == {} || time.tick_since(id.quiet_since) < IDLE_AFTER do return false
	start := time.tick_now()
	woke := idle_wait(IDLE_TICK)
	id.rests += 1
	id.rest_ms += time.duration_milliseconds(time.tick_since(start))
	if !woke do id.skipped += 1
	return !woke
}

// The events of the app's life, which the frame and the background hold both answer:
// the end of the run, and a tablet's app going to the background and coming back.
// Whether `e` was one of them.
lifecycle_event :: proc(app: ^App, e: ^sdl.Event) -> bool {
	#partial switch e.type {
	case .QUIT, .WINDOW_CLOSE_REQUESTED, .TERMINATING:
		// The system ending the app (a tablet) ends the run as a close does, its settings
		// and session written; the scene was already handed to the background's autosave.
		app.running = false
	case .DID_ENTER_FOREGROUND:
		// The window comes back with a new surface, which has to ask for its frame rate again.
		app.pacer.voted_window = nil
		app.preview.background = false
		app.idle.background = false
		// The new surface gets a drawn frame whatever the frames before showed.
		app.idle.quiet_since = {}
		pencil_only_read(app)
	case .DID_ENTER_BACKGROUND:
		// The system may end the app from the background without another word.
		if app.settings_file != "" do _ = settings_save(app, app.settings_file)
		app.autosave.background = true
		app.preview.background = true
		app.idle.background = true
	case:
		return false
	}
	return true
}

// The hold's wait: a plain sleep, since every event but the app's own stays queued through
// the hold and a wait for any event would return at once. On the iPad the main run loop
// sleeps instead, so the system's notifications come through; on Android the pump after
// it holds until the app is resumed.
background_wait :: proc(ms: i32) {
	when ODIN_PLATFORM_SUBTARGET_IOS do ios_run_loop_wait(ms)
	else do sdl.DelayNS(u64(ms) * 1_000_000)
}

// A frame in the background (Idle.background): no image is acquired and nothing is drawn
// or submitted. The loop sleeps BACKGROUND_TICK, takes the app's own events alone from the
// queue (SDL's QUIT to DID_ENTER_FOREGROUND range; the foreground event ends the hold)
// and leaves every other queued, in order, for the first frame back, which reads them as
// every frame does: a file handed over meanwhile (the iPad's Open in Sculpt arrives as a
// drop before the foreground event) imports then. The background's autosave is the frame
// loop's to hand over, so that still runs. A scripted run's events still go in by frame
// (its bg and fg among them), so the frames count on while the loop holds.
background_step :: proc(app: ^App, window: ^sdl.Window) {
	id := &app.idle
	background_wait(BACKGROUND_TICK)
	id.held += 1
	app.kit.frame += 1
	kit_events_push(app, window)
	sdl.PumpEvents()
	e: sdl.Event
	for id.background && sdl.PeepEvents(&e, 1, .GETEVENT, .QUIT, .DID_ENTER_FOREGROUND) > 0 {
		diag_event(app, &e)
		_ = lifecycle_event(app, &e)
	}
	autosave_frame(app)
	free_all(context.temp_allocator)
}

// At the end of a frame: whether it changed anything, which ends a quiet run, or
// starts or continues one. `gpu_work` is whether the viewport's recording held anything
// (a picture drawn late changes a texture and no triangle), and `rested` whether the
// frame drew nothing: such a change then waits for the frame after, which draws.
idle_note :: proc(app: ^App, drawn: render.Viewport_Stats, dabs: int, gpu_work, rested: bool) {
	id := &app.idle
	dl := &app.kit.ctx.draw
	h := xxhash.XXH3_64_default(mem.slice_to_bytes(dl.vertices[:]))
	h ~= xxhash.XXH3_64_with_seed(mem.slice_to_bytes(dl.indices[:]), 1)
	h ~= xxhash.XXH3_64_with_seed(mem.slice_to_bytes(dl.cmds[:]), 2)
	// A view window's interface counts as the main one's (view_window.odin keeps its hash).
	// Seeded by its number, so two windows changing alike never cancel out.
	for w in app.view_windows.open do if w != nil do h ~= w.hash ~ u64(w.number) * 0x9e3779b97f4a7c15
	ui_changed := h != id.ui_hash
	id.ui_hash = h
	thumbs_changed := app.thumb_slots.drawn != id.thumbs
	id.thumbs = app.thumb_slots.drawn
	held := app.device.down != {} || app.touch.fingers.count > 0 || app.ui.pie.space_down
	busy := app.stroke.active || replay_busy(app) || timelapse_capturing(app) || app.script.running ||
		(studio_running(app) && !render_running(app) && app.studio.samples < int(app.studio_samples)) || render_busy(app) || home_busy(app) || app.thumbnail.due || grid_due(app) || view_windows_due(app) || app.capture.path != "" || turntable_recording(app) || lod_waiting(app)
	viewport := !drawn.partial || drawn.redrawn_px > 0 || drawn.cache_redrawn
	// The view settles into full detail LOD_SETTLE after it stops: that redraw is
	// timed, not driven by input, so the quiet run waits for it.
	settling := time.tick_since(app.view_moved) < 2 * LOD_SETTLE
	if rested && gpu_work do id.recorded += 1
	if id.events > 0 || ui_changed || thumbs_changed || held || busy || viewport || settling || dabs > 0 || gpu_work {
		id.quiet_since = {}
	} else if id.quiet_since == {} {
		id.quiet_since = time.tick_now()
	}
}
