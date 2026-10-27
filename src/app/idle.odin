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
// the first stroke after a rest is not late. "Changed nothing" is judged from what was
// drawn, not from a list of what might animate: a panel fading or a progress bar moving
// changes the interface's triangles.
IDLE_AFTER :: 1 * time.Second
IDLE_TICK :: 100 // milliseconds

Idle :: struct {
	quiet_since: time.Tick, // the first frame of the run that changed nothing (zero: the last frame changed something)
	ui_hash:     u64, // the last frame's interface triangles and commands
	thumbs:      int, // thumbnails drawn so far (thumb_slots.drawn), to see a new one
	events:      int, // SDL events read this frame
	forced:      bool, // --idle-sleep: rest in a scripted run too, to test it
	// For the exit stats: how often the loop rested, and for how long in all.
	rests:       int,
	rest_ms:     f64,
}

// Whether this run may rest at all: an interactive run with the setting on. A scripted
// run (tests, benchmarks, --frames) never does unless --idle-sleep asks, so its frames
// stay as many and as timed as before.
idle_allowed :: proc(app: ^App, interactive: bool) -> bool {
	return app.idle_sleep && (interactive || app.idle.forced)
}

// At the top of a frame: rests until an event comes or IDLE_TICK passes, when the
// frames have changed nothing for IDLE_AFTER.
idle_rest :: proc(app: ^App, interactive: bool) {
	id := &app.idle
	id.events = 0
	if !idle_allowed(app, interactive) || id.quiet_since == {} || time.tick_since(id.quiet_since) < IDLE_AFTER do return
	start := time.tick_now()
	// The event stays queued for the frame's own PollEvent loop.
	_ = sdl.WaitEventTimeout(nil, IDLE_TICK)
	id.rests += 1
	id.rest_ms += time.duration_milliseconds(time.tick_since(start))
}

// At the end of a frame: whether it changed anything, which ends a quiet run, or
// starts or continues one.
idle_note :: proc(app: ^App, drawn: render.Viewport_Stats, dabs: int) {
	id := &app.idle
	dl := &app.kit.ctx.draw
	h := xxhash.XXH3_64_default(mem.slice_to_bytes(dl.vertices[:]))
	h ~= xxhash.XXH3_64_with_seed(mem.slice_to_bytes(dl.indices[:]), 1)
	h ~= xxhash.XXH3_64_with_seed(mem.slice_to_bytes(dl.cmds[:]), 2)
	ui_changed := h != id.ui_hash
	id.ui_hash = h
	thumbs_changed := app.thumb_slots.drawn != id.thumbs
	id.thumbs = app.thumb_slots.drawn
	held := app.device.down != {} || app.touch.fingers.count > 0 || app.ui.pie.space_down
	busy := app.stroke.active || replay_busy(app) || timelapse_capturing(app) || app.script.running ||
		(studio_running(app) && !render_running(app) && app.studio.samples < int(app.studio_samples)) || render_busy(app) || home_busy(app) || app.thumbnail.due || app.capture.path != "" || turntable_recording(app)
	viewport := !drawn.partial || drawn.redrawn_px > 0 || drawn.cache_redrawn
	// The view settles into full detail LOD_SETTLE after it stops: that redraw is
	// timed, not driven by input, so the quiet run waits for it.
	settling := time.tick_since(app.view_moved) < 2 * LOD_SETTLE
	if id.events > 0 || ui_changed || thumbs_changed || held || busy || viewport || settling || dabs > 0 {
		id.quiet_since = {}
	} else if id.quiet_since == {} {
		id.quiet_since = time.tick_now()
	}
}
