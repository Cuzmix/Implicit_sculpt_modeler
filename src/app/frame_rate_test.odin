package main

import "core:testing"

// Low latency keeps one frame in flight only where it was asked for: always, or during
// strokes where the backend changes it for no more than a wait; otherwise two.
@(test)
low_latency_picks_the_frames_in_flight :: proc(t: ^testing.T) {
	testing.expect_value(t, frames_wanted(.Always, false, false), 1)
	testing.expect_value(t, frames_wanted(.Always, true, true), 1)
	testing.expect_value(t, frames_wanted(.During_Strokes, true, true), 1)
	testing.expect_value(t, frames_wanted(.During_Strokes, false, true), 2)
	testing.expect_value(t, frames_wanted(.During_Strokes, true, false), 2)
	testing.expect_value(t, frames_wanted(.Off, true, true), 2)
}
