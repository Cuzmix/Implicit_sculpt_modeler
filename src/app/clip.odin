package main

import "core:math/linalg"
import imgui "deps:odin-imgui"


// Clipping, as ZBrush's Clip Curve does: with the Brush tool, Ctrl + Shift and a left
// drag draws a line across the view, and letting go flattens everything of the
// selected object on the shaded side of it (the right of the drag; Alt held at the end
// takes the other side) onto the plane through the line and the view direction, through
// to the back. It mirrors with the brush's symmetry and leaves masked areas.

Clip_Gesture :: struct {
	active: bool,
	flip:   bool, // Alt was held: the other side goes
	a, b:   [2]f32, // viewport pixels
}

// The drag must be at least this long, in pixels, to clip.
CLIP_MIN_PX :: 4

// Follows a clip gesture with this frame's input. Returns true while one runs (or ended
// this frame), so the brush and mask shapes stay out of it.
clip_frame :: proc(app: ^App, input: Viewport_Input) -> bool {
	g := &app.clip
	if !g.active {
		if !input.press || !input.invert || !input.smooth || app.stroke.active do return false
		g^ = {active = true, a = input.mouse_pos, b = input.mouse_pos, flip = input.alt}
		return true
	}
	if input.primary {
		g.b = input.mouse_pos
		g.flip = input.alt
		return true
	}
	g.active = false
	if linalg.length(g.b - g.a) >= CLIP_MIN_PX do clip_command(app, g.a, g.b, g.flip, input.size)
	return true
}

// Draws the line being dragged, with a band of shading on the side that goes.
draw_clip :: proc(app: ^App, list: ^imgui.DrawList, o: imgui.Vec2, size: [2]f32) {
	g := app.clip
	if !g.active do return
	rgba :: proc(c: [4]f32) -> u32 {return imgui.ColorConvertFloat4ToU32(c)}
	d := g.b - g.a
	if linalg.length(d) < 1 do return
	// The line runs across the whole viewport, as the plane does.
	dir := linalg.normalize(d)
	reach := linalg.length(size) + linalg.length(d)
	p0, p1 := g.a - dir * reach, g.a + dir * reach
	side := [2]f32{-dir.y, dir.x} // the right of the drag, with y down
	if g.flip do side = -side
	band := side * reach
	shade := [4]imgui.Vec2{o + p0, o + p1, o + p1 + band, o + p0 + band}
	imgui.DrawList_AddConvexPolyFilled(list, &shade[0], 4, rgba({0, 0, 0, 0.25}))
	imgui.DrawList_AddLine(list, o + p0, o + p1, rgba({1, 0.85, 0.3, 0.9}), 1.5)
	imgui.DrawList_AddCircleFilled(list, o + g.a, 3, rgba({1, 0.85, 0.3, 1}))
	imgui.DrawList_AddCircleFilled(list, o + g.b, 3, rgba({1, 0.85, 0.3, 1}))
}
