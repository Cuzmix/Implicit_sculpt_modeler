package main

import "core:math/linalg"

import "../ui"


// Ctrl + Shift and a left drag with the Brush tool, as ZBrush's Ctrl+Shift brushes: what
// it does is the Object palette's choice (Gesture_Tool). The hide tools draw a rectangle or
// a lasso; letting go keeps only what is inside it shown (Alt held at the end hides what
// is inside instead), through to the back. Clip and Slice draw a line across the view:
// Clip flattens everything of the selected object on the shaded side of it (the right of
// the drag; Alt takes the other side) onto the plane through the line and the view
// direction, mirroring with the brush's symmetry and leaving masked areas; Slice cuts
// the object in two along that plane, each part an object of its own with the cut
// closed; Knife cuts it there too but throws the shaded side away, closing the cut on
// what stays. A click without a drag shows everything again, whichever tool is chosen.

Gesture_Tool :: enum u8 {
	Hide_Rectangle,
	Hide_Lasso,
	Clip,
	Slice,
	Knife,
}

GESTURE_NAMES := [Gesture_Tool]cstring {
	.Hide_Rectangle = "Hide rectangle",
	.Hide_Lasso     = "Hide lasso",
	.Clip           = "Clip",
	.Slice          = "Slice",
	.Knife          = "Knife",
}

Clip_Gesture :: struct {
	active: bool,
	flip:   bool, // Alt was held: the other side goes, or the inside is hidden
	a, b:   [2]f32, // viewport pixels: where the drag started and where it is
	points: [dynamic][2]f32, // the lasso, in viewport pixels
	pointer: ui.Pointer_Kind, // what pressed it, which decides whether it waits for Apply
}

// A mouse's drag must be at least this long, in pixels, to count as one; shorter is a
// click. A finger's or a pen's must pass the slop, since their taps wander further.
CLIP_MIN_PX :: 4

// How long a gesture's drag must be to count as one, in pixels, for the pointer in use.
gesture_min_px :: proc(app: ^App) -> f32 {
	if app.device.pointer == .Mouse do return CLIP_MIN_PX
	return app.kit.ctx.theme.slop * app.kit.scale
}

// Where a gesture pressed this frame begins: its first sample, where a finger landed
// before its stroke waited out FINGER_HOLD, or else the pointer.
gesture_start :: proc(input: Viewport_Input) -> [2]f32 {
	return input.samples[0].pos if len(input.samples) > 0 else input.mouse_pos
}

// Follows a Ctrl + Shift gesture with this frame's input. Returns true while one runs
// (or ended this frame), so the brush and mask shapes stay out of it.
clip_frame :: proc(app: ^App, input: Viewport_Input) -> bool {
	g := &app.clip
	if !g.active {
		if !input.press || !input.invert || !input.smooth || app.stroke.active do return false
		start := gesture_start(input)
		g.active, g.a, g.b, g.flip, g.pointer = true, start, input.mouse_pos, input.alt, app.device.pointer
		clear(&g.points)
		append(&g.points, start)
		if input.mouse_pos != start do append(&g.points, input.mouse_pos)
		return true
	}
	if input.primary {
		g.b = input.mouse_pos
		g.flip = input.alt
		if linalg.length(input.mouse_pos - g.points[len(g.points) - 1]) >= LASSO_STEP_PX do append(&g.points, input.mouse_pos)
		return true
	}
	g.active = false
	if linalg.length(g.b - g.a) < gesture_min_px(app) {
		// A click on a polygroup isolates it (with Alt: masks it), as in ZBrush.
		if !group_click(app, g.a, input.size, g.flip) do hide_command(app, .Show_All)
		return true
	}
	switch app.gesture {
	case .Hide_Rectangle, .Hide_Lasso:
		shape_finish(app, .Hide, g.points[:], app.gesture == .Hide_Rectangle, g.flip, input.size, g.pointer)
	case .Clip, .Slice, .Knife:
		line := [2][2]f32{g.a, g.b}
		kinds := [Gesture_Tool]Shape_Kind{.Hide_Rectangle = .Hide, .Hide_Lasso = .Hide, .Clip = .Clip, .Slice = .Slice, .Knife = .Knife}
		shape_finish(app, kinds[app.gesture], line[:], false, g.flip, input.size, g.pointer)
	}
	return true
}

// Draws the gesture being dragged: the hide shape, or the line with (for Clip and Knife)
// a band of shading on the side that goes.
draw_clip :: proc(app: ^App, o: Overlay, size: [2]f32) {
	g := &app.clip
	if !g.active do return
	if app.gesture == .Hide_Rectangle || app.gesture == .Hide_Lasso {
		// Green keeps what is inside; red hides it.
		color := overlay_color({0.45, 0.9, 0.5, 1} if !g.flip else {1, 0.45, 0.4, 1})
		fill := overlay_color({0.45, 0.9, 0.5, 0.12} if !g.flip else {1, 0.45, 0.4, 0.12})
		draw_shape_outline(o, g.points[:], g.b, app.gesture == .Hide_Rectangle, color, fill)
		return
	}
	draw_clip_line(o, g.a, g.b, g.flip, app.gesture != .Slice, size)
}

// A Clip, Slice or Knife line from `a` to `b`, across the whole viewport as the plane is,
// with (when `clip`) a band of shading on the side that goes.
draw_clip_line :: proc(o: Overlay, a, b: [2]f32, flip, clip: bool, size: [2]f32) {
	d := b - a
	if linalg.length(d) < 1 do return
	dir := linalg.normalize(d)
	reach := linalg.length(size) + linalg.length(d)
	p0, p1 := a - dir * reach, a + dir * reach
	color := overlay_color({1, 0.85, 0.3, 0.9})
	if clip {
		side := [2]f32{-dir.y, dir.x} // the right of the drag, with y down
		if flip do side = -side
		band := side * reach
		shade := [4][2]f32{p0, p1, p1 + band, p0 + band}
		overlay_fill(o, shade[:], overlay_color({0, 0, 0, 0.25}))
	} else {
		color = overlay_color({0.4, 0.85, 1, 0.95})
	}
	overlay_line(o, p0, p1, color, 1.5)
	overlay_disc(o, a, 3, color)
	overlay_disc(o, b, 3, color)
}

clip_gesture_destroy :: proc(g: ^Clip_Gesture) {delete(g.points)}
