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

// Halving averages each 2 x 2 block, its colour weighted by alpha so an edge over
// nothing keeps its colour, a clear block stays clear, and the same size is the same rows.
@(test)
image_resize_averages_by_alpha :: proc(t: ^testing.T) {
	// Two blocks side by side: one half red at full alpha and half clear, one clear.
	px := []u8{
		200, 0, 0, 255, 9, 9, 9, 0, 1, 2, 3, 0, 4, 5, 6, 0,
		200, 0, 0, 255, 9, 9, 9, 0, 7, 8, 9, 0, 1, 1, 1, 0,
	}
	half := image_resize(px, 4, 2, 2, 1)
	testing.expect(t, slice.equal(half, []u8{200, 0, 0, 128, 0, 0, 0, 0}), "halved wrong")
	same := image_resize(px, 4, 2, 4, 2)
	testing.expect(t, raw_data(same) == raw_data(px), "the same size copied")
	free_all(context.temp_allocator)
}
