package main

import "core:testing"
import sdl "vendor:sdl3"

// Without the event watch (lifecycle_watch, which answers them on a tablet), the queue's
// background event stops the preview's pictures and holds the frame loop, and coming back
// releases it; the system ending the app ends the run as a close does. Other events are
// not the app's life.
@(test)
lifecycle_events_hold_and_release_the_loop :: proc(t: ^testing.T) {
	app: App
	app.running = true
	e: sdl.Event
	e.type = .DID_ENTER_BACKGROUND
	testing.expect(t, lifecycle_event(&app, &e), "the background event was not taken")
	testing.expect(t, app.preview.background, "the preview still takes pictures")
	testing.expect(t, app.idle.background, "the loop does not hold")
	testing.expect(t, app.running, "the run ended on going to the background")
	e.type = .DID_ENTER_FOREGROUND
	testing.expect(t, lifecycle_event(&app, &e), "the foreground event was not taken")
	testing.expect(t, !app.idle.background, "the hold did not end")
	testing.expect(t, !app.preview.background, "the preview stayed stopped")
	e.type = .MOUSE_MOTION
	testing.expect(t, !lifecycle_event(&app, &e), "a pointer event was taken as the app's life")
	testing.expect(t, app.running, "a pointer event ended the run")
	e.type = .TERMINATING
	testing.expect(t, lifecycle_event(&app, &e), "the terminating event was not taken")
	testing.expect(t, !app.running, "the run goes on after the system ended the app")

	// With the watch on, it answers what SDL only sends to watchers (a timestamp of 0) and
	// queues it after, where lifecycle_event only takes it: the copy read after the resume
	// never sends the app back. One test, since the watch is one for the whole package.
	testing.expect(t, sdl.InitSubSystem({.EVENTS}), "SDL's events did not start")
	defer sdl.QuitSubSystem({.EVENTS})
	app.running = true
	lifecycle_watch_state = {&app, context}
	defer lifecycle_watch_state = {}
	e = {}
	e.type = .DID_ENTER_BACKGROUND
	_ = lifecycle_watch(&lifecycle_watch_state, &e)
	testing.expect(t, app.idle.background, "the watch did not hold the loop")
	e.type = .DID_ENTER_FOREGROUND
	_ = lifecycle_watch(&lifecycle_watch_state, &e)
	testing.expect(t, !app.idle.background, "the watch did not release the loop")
	queued: [4]sdl.Event
	n := sdl.PeepEvents(&queued[0], len(queued), .GETEVENT, .DID_ENTER_BACKGROUND, .DID_ENTER_FOREGROUND)
	testing.expect_value(t, n, 2)
	if n == 2 {
		testing.expect(t, queued[0].type == .DID_ENTER_BACKGROUND && queued[1].type == .DID_ENTER_FOREGROUND, "the queued copies are out of order")
		testing.expect(t, queued[0].common.timestamp != 0, "the queued copy has no time")
		testing.expect(t, lifecycle_event(&app, &queued[0]), "the queued background event was not taken")
		testing.expect(t, !app.idle.background, "the queued copy sent the app back to the background")
	}
	// An event pushed by the app (a scripted bg) is SDL's to queue, not the watch's.
	e.type = .DID_ENTER_BACKGROUND
	e.common.timestamp = 1
	_ = lifecycle_watch(&lifecycle_watch_state, &e)
	testing.expect(t, app.idle.background, "the watch did not answer a pushed event")
	testing.expect(t, !sdl.HasEvent(.DID_ENTER_BACKGROUND), "the watch queued a pushed event twice")
	// Any other event passes untouched.
	e.type = .MOUSE_MOTION
	testing.expect(t, lifecycle_watch(&lifecycle_watch_state, &e), "the watch dropped a pointer event")
	testing.expect(t, app.running && app.idle.background, "a pointer event changed the app's life")
}
