package main

import "core:testing"

import "../ui"

// Changing hands sends a window the user moved to the other side as far in as it was,
// once, and turns the wheel's drag from its place the other way; a window left where it
// opens is the layout's to place.
@(test)
changing_hands_moves_moved_windows_across :: proc(t: ^testing.T) {
	k: Kit_State
	k.windows[.Stats] = {moved = true, x = .Start, y = .Start, offset = {120, 80}}
	k.windows[.History] = {moved = true, x = .Center, y = .End, offset = {40, 10}}
	k.windows[.Help] = {x = .Start, offset = {5, 5}}
	k.wheel_offset = {30, -20}
	k.ctx.mirror = true
	kit_mirror(&k)
	testing.expect_value(t, k.windows[.Stats].x, ui.Anchor.End)
	testing.expect_value(t, k.windows[.Stats].offset, [2]f32{120, 80})
	testing.expect_value(t, k.windows[.History].offset, [2]f32{-40, 10})
	testing.expect_value(t, k.windows[.Help].x, ui.Anchor.Start)
	testing.expect_value(t, k.wheel_offset, [2]f32{-30, -20})
	// Nothing more happens until the hand changes again.
	kit_mirror(&k)
	testing.expect_value(t, k.windows[.Stats].x, ui.Anchor.End)
	k.ctx.mirror = false
	kit_mirror(&k)
	testing.expect_value(t, k.windows[.Stats].x, ui.Anchor.Start)
	testing.expect_value(t, k.wheel_offset, [2]f32{30, -20})
}
