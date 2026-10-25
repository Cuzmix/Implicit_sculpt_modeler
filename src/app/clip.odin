package main

import "core:math/linalg"
import imgui "deps:odin-imgui"


// Ctrl + Shift and a left drag with the Brush tool, as ZBrush's Ctrl+Shift brushes: what
// it does is the Tools panel's choice (Gesture_Tool). The hide tools draw a rectangle or
// a lasso; letting go keeps only what is inside it shown (Alt held at the end hides what
// is inside instead), through to the back. Clip and Slice draw a line across the view:
// Clip flattens everything of the selected object on the shaded side of it (the right of
// the drag; Alt takes the other side) onto the plane through the line and the view
// direction, mirroring with the brush's symmetry and leaving masked areas; Slice cuts
// the object in two along that plane, each part an object of its own with the cut
// closed. A click without a drag shows everything again, whichever tool is chosen.

Gesture_Tool :: enum u8 {
	Hide_Rectangle,
	Hide_Lasso,
	Clip,
	Slice,
}

GESTURE_NAMES := [Gesture_Tool]cstring {
	.Hide_Rectangle = "Hide rectangle",
	.Hide_Lasso     = "Hide lasso",
	.Clip           = "Clip",
	.Slice          = "Slice",
}

Clip_Gesture :: struct {
	active: bool,
	flip:   bool, // Alt was held: the other side goes, or the inside is hidden
	a, b:   [2]f32, // viewport pixels: where the drag started and where it is
	points: [dynamic][2]f32, // the lasso, in viewport pixels
}

// The drag must be at least this long, in pixels, to count as one; shorter is a click.
CLIP_MIN_PX :: 4

// Follows a Ctrl + Shift gesture with this frame's input. Returns true while one runs
// (or ended this frame), so the brush and mask shapes stay out of it.
clip_frame :: proc(app: ^App, input: Viewport_Input) -> bool {
	g := &app.clip
	if !g.active {
		if !input.press || !input.invert || !input.smooth || app.stroke.active do return false
		g.active, g.a, g.b, g.flip = true, input.mouse_pos, input.mouse_pos, input.alt
		clear(&g.points)
		append(&g.points, input.mouse_pos)
		return true
	}
	if input.primary {
		g.b = input.mouse_pos
		g.flip = input.alt
		if linalg.length(input.mouse_pos - g.points[len(g.points) - 1]) >= LASSO_STEP_PX do append(&g.points, input.mouse_pos)
		return true
	}
	g.active = false
	if linalg.length(g.b - g.a) < CLIP_MIN_PX {
		hide_command(app, .Show_All)
		return true
	}
	switch app.gesture {
	case .Hide_Rectangle, .Hide_Lasso:
		shape := shape_polygon(g.points[:], app.gesture == .Hide_Rectangle, input.size)
		if len(shape) >= 3 do hide_shape_command(app, shape, input.size, g.flip)
	case .Clip:
		clip_command(app, g.a, g.b, g.flip, input.size)
	case .Slice:
		slice_request(app, g.a, g.b, input.size)
	}
	return true
}

// Draws the gesture being dragged: the hide shape, or the line with (for Clip) a band
// of shading on the side that goes.
draw_clip :: proc(app: ^App, list: ^imgui.DrawList, o: imgui.Vec2, size: [2]f32) {
	g := &app.clip
	if !g.active do return
	rgba :: proc(c: [4]f32) -> u32 {return imgui.ColorConvertFloat4ToU32(c)}
	if app.gesture == .Hide_Rectangle || app.gesture == .Hide_Lasso {
		// Green keeps what is inside; red hides it.
		color := rgba({0.45, 0.9, 0.5, 1} if !g.flip else {1, 0.45, 0.4, 1})
		fill := rgba({0.45, 0.9, 0.5, 0.12} if !g.flip else {1, 0.45, 0.4, 0.12})
		draw_shape_outline(list, o, g.points[:], g.b, app.gesture == .Hide_Rectangle, color, fill)
		return
	}
	d := g.b - g.a
	if linalg.length(d) < 1 do return
	// The line runs across the whole viewport, as the plane does.
	dir := linalg.normalize(d)
	reach := linalg.length(size) + linalg.length(d)
	p0, p1 := g.a - dir * reach, g.a + dir * reach
	color := rgba({1, 0.85, 0.3, 0.9})
	if app.gesture == .Clip {
		side := [2]f32{-dir.y, dir.x} // the right of the drag, with y down
		if g.flip do side = -side
		band := side * reach
		shade := [4]imgui.Vec2{o + p0, o + p1, o + p1 + band, o + p0 + band}
		imgui.DrawList_AddConvexPolyFilled(list, &shade[0], 4, rgba({0, 0, 0, 0.25}))
	} else {
		color = rgba({0.4, 0.85, 1, 0.95})
	}
	imgui.DrawList_AddLine(list, o + p0, o + p1, color, 1.5)
	imgui.DrawList_AddCircleFilled(list, o + g.a, 3, color)
	imgui.DrawList_AddCircleFilled(list, o + g.b, 3, color)
}

clip_gesture_destroy :: proc(g: ^Clip_Gesture) {delete(g.points)}
