package main

import "core:testing"

// Low latency keeps one frame in flight only where it was asked for: always, or during
// strokes where the backend changes it for no more than a wait; otherwise two.
@(test)
low_latency_picks_the_frames_in_flight :: proc(t: ^testing.T) {
	testing.expect_value(t, frames_wanted(.Always, false), 1)
	testing.expect_value(t, frames_wanted(.Always, true), 1)
	testing.expect_value(t, frames_wanted(.During_Strokes, true), 1)
	testing.expect_value(t, frames_wanted(.During_Strokes, false), 2)
	testing.expect_value(t, frames_wanted(.Off, true), 2)
}

// During strokes gives up one frame in flight when most frames of a verdict miss the
// screen, rests, then tries again; fast frames and the frame after a change keep it.
@(test)
low_latency_steps_back_when_frames_are_slow :: proc(t: ^testing.T) {
	testing.expect_value(t, frames_wanted(.During_Strokes, true, true), 2)
	testing.expect_value(t, frames_wanted(.Always, true, true), 1)
	period := 1000.0 / 60
	g: Latency_Guard
	// Fast frames never step back.
	for i in 0 ..< 40 do testing.expect(t, !latency_guard_step(&g, true, true, period, period, u64(i)), "a frame that keeps up stepped back")
	// Slow frames do, once a verdict's worth of them are counted; the first is skipped.
	g = {}
	stepped := -1
	for i in 0 ..< 20 {
		if latency_guard_step(&g, true, true, period * 3, period, u64(i)) {
			stepped = i
			break
		}
	}
	testing.expect_value(t, stepped, LATENCY_SAMPLES)
	testing.expect(t, latency_guard_step(&g, true, false, 0, period, u64(stepped + 1)), "the rest ended at once")
	testing.expect(t, !latency_guard_step(&g, true, false, 0, period, u64(stepped) + LATENCY_REST + 1), "the rest never ended")
}
