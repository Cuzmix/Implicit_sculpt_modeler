package main

import "../render"

// The viewport's background (Scene > Background): one colour, or a gradient from the top
// edge's colour to the bottom edge's, in the values a screen shows (sRGB, as the hex codes
// are). Only the viewport has it: thumbnails and the navigation head stay transparent, and
// screenshots and the studio render show it as the viewport does.
Background_Settings :: struct {
	gradient: bool,
	top:      [3]f32, // the whole background without the gradient
	bottom:   [3]f32,
}

// A soft grey that darkens toward the floor, as a photographer's backdrop does: light
// enough at the top that a dark model's outline reads, dark enough below that the floor
// grid's lines show.
BACKGROUND_DEFAULT :: Background_Settings{gradient = true, top = {0.27, 0.27, 0.28}, bottom = {0.09, 0.09, 0.1}}

// What the renderer paints this frame: both edges the top colour without the gradient.
background_frame :: proc(b: Background_Settings) -> render.Background {
	top := [4]f32{b.top.r, b.top.g, b.top.b, 1}
	if !b.gradient do return {top, top}
	return {top, {b.bottom.r, b.bottom.g, b.bottom.b, 1}}
}
