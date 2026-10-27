package main

import "core:slice"
import "core:testing"

// A covered pixel keeps the viewport's colour, an empty one goes clear, and an edge
// takes the transparent drawing's colour with its coverage divided back out.
@(test)
capture_compose_keeps_cover_and_clears_the_ground :: proc(t: ^testing.T) {
	shown := []u8{10, 20, 30, 255, 40, 50, 60, 255, 70, 80, 90, 255}
	cut := []u8{1, 2, 3, 255, 9, 9, 9, 0, 32, 64, 128, 128}
	capture_compose(shown, cut)
	testing.expect(t, slice.equal(shown, []u8{10, 20, 30, 255, 0, 0, 0, 0, 64, 128, 255, 128}), "composed wrong")
}
