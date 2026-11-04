package main

import "core:testing"

import "../ui"

// Changing hands sends a floating card the user moved to the other side as far in as it
// was, once, and turns the wheel's drag from its place the other way; a card left where it
// opens is the layout's to place.
@(test)
changing_hands_moves_moved_windows_across :: proc(t: ^testing.T) {
	k: Kit_State
	k.cards.windows[.Look] = {moved = true, x = .Start, y = .Start, offset = {120, 80}}
	k.wheel_offset = {30, -20}
	k.ctx.mirror = true
	kit_mirror(&k)
	testing.expect_value(t, k.cards.windows[.Look].x, ui.Anchor.End)
	testing.expect_value(t, k.cards.windows[.Look].offset, [2]f32{120, 80})
	testing.expect_value(t, k.wheel_offset, [2]f32{-30, -20})
	// Nothing more happens until the hand changes again.
	kit_mirror(&k)
	testing.expect_value(t, k.cards.windows[.Look].x, ui.Anchor.End)
	k.ctx.mirror = false
	kit_mirror(&k)
	testing.expect_value(t, k.cards.windows[.Look].x, ui.Anchor.Start)
	testing.expect_value(t, k.wheel_offset, [2]f32{30, -20})
	// A centred window's offset turns over.
	k.cards.windows[.Look] = {moved = true, x = .Center, y = .End, offset = {40, 10}}
	k.ctx.mirror = true
	kit_mirror(&k)
	testing.expect_value(t, k.cards.windows[.Look].offset, [2]f32{-40, 10})
	// A window left where it opens stays the layout's to place.
	k.cards.windows[.Look] = {x = .Start, offset = {5, 5}}
	k.ctx.mirror = false
	kit_mirror(&k)
	testing.expect_value(t, k.cards.windows[.Look].x, ui.Anchor.Start)
}
