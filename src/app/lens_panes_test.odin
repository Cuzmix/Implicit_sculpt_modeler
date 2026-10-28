package main

import "core:testing"

import "../ui"

// Two taps on one handle within the double tap's time are a double tap; a tap on another
// handle, or one too late, starts over.
@(test)
handle_taps_make_a_double_tap :: proc(t: ^testing.T) {
	ctx: ui.Context
	d: Handle_Tap
	ctx.time = 1
	testing.expect(t, !handle_double_tap(&ctx, &d, 7))
	ctx.time = 1.2
	testing.expect(t, handle_double_tap(&ctx, &d, 7))
	testing.expect(t, !handle_double_tap(&ctx, &d, 7))
	ctx.time = 2
	testing.expect(t, !handle_double_tap(&ctx, &d, 8))
	ctx.time = 2.1
	testing.expect(t, !handle_double_tap(&ctx, &d, 7))
	ctx.time = 3
	testing.expect(t, !handle_double_tap(&ctx, &d, 7))
}
