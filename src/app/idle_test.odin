package main

import "core:testing"
import sdl "vendor:sdl3"

// Going to the background asks for an autosave, stops the preview's pictures and holds
// the frame loop; coming back releases it; the system ending the app ends the run as a
// close does. Other events are not the app's life.
@(test)
lifecycle_events_hold_and_release_the_loop :: proc(t: ^testing.T) {
	app: App
	app.running = true
	e: sdl.Event
	e.type = .DID_ENTER_BACKGROUND
	testing.expect(t, lifecycle_event(&app, &e), "the background event was not taken")
	testing.expect(t, app.autosave.background, "no autosave was asked for")
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
}
