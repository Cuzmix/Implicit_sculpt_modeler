package main

import "core:testing"

import "../ui"

// A divider let go at the far edge closes the panes it squeezes there and keeps the others'
// views in order; at the near edge only One plus two's right divider closes anything, as
// every other near side holds the main pane, which never closes.
@(test)
grid_close_keeps_the_panes_left :: proc(t: ^testing.T) {
	to, keep, closes, ok := grid_close_target(.Four, 0, true)
	testing.expect(t, ok && to == .Stacked && keep[0] == 1 && closes == {1, 3})
	to, keep, closes, ok = grid_close_target(.One_Plus_Two, 1, true)
	testing.expect(t, ok && to == .Side_By_Side && keep[0] == 0 && closes == {2})
	to, _, closes, ok = grid_close_target(.Side_By_Side, 0, true)
	testing.expect(t, ok && to == .Single && closes == {1})
	for preset in Grid_Preset {
		_, _, _, ok = grid_close_target(preset, 0, false)
		testing.expect(t, !ok)
		// What a preset closes to always has fewer panes, and keeps only views it had.
		for div in 0 ..< 2 {
			if to, keep, closes, ok = grid_close_target(preset, div, true); !ok do continue
			testing.expect_value(t, grid_count(to), grid_count(preset) - card(closes))
			for j in 0 ..< grid_count(to) - 1 do testing.expect(t, keep[j] < grid_count(preset) - 1)
			testing.expect(t, 0 not_in closes)
		}
	}
	_, _, _, ok = grid_close_target(.Single, 0, true)
	testing.expect(t, !ok)
}

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
