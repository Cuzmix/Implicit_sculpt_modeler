package main

import "core:fmt"
import "core:math/linalg"
import imgui "deps:odin-imgui"

// Changing the brush size or strength without the Tools panel, where the brush is, as
// ZBrush's S (draw size) and U (intensity) and Blender's F and Shift+F do. Pressing S
// or U over the viewport starts it: the brush circle stays put and its size, or the
// strength, follows how far the pointer is from the circle's middle. A click or the same
// key again keeps the new value; a right click or Escape puts the old one back.
// While it runs no tool or camera input reaches the viewport.

Adjust_Kind :: enum u8 {
	None,
	Size,
	Strength,
}

Brush_Adjust :: struct {
	kind:    Adjust_Kind,
	center:  [2]f32, // the circle's middle, in viewport coordinates
	before:  f32, // the value when it started, for a cancel
	// A click ended it: the left button does nothing else until it is let go.
	swallow: bool,
}

MIN_RADIUS_PX :: 5
MAX_RADIUS_PX :: 500
MIN_STRENGTH :: 0.01
// Pixels from the middle that count as full strength while adjusting it.
STRENGTH_PX :: 200

// Starts, follows and ends an adjustment with this frame's input.
adjust_update :: proc(app: ^App, input: ^Viewport_Input) {
	a := &app.ui.adjust
	io := imgui.GetIO()
	if a.swallow {
		if imgui.IsMouseDown(.Left) {
			viewport_mute(input)
		} else {
			a.swallow = false
		}
	}
	if a.kind == .None {
		if app.tool != .Brush || !input.hovered || app.stroke.active || app.ui.pie.open || io.WantTextInput do return
		if io.KeyCtrl || io.KeyAlt || io.KeyShift || imgui.IsMouseDown(.Left) do return
		switch {
		case imgui.IsKeyPressed(.S, false):
			// The pointer lands on the circle's edge, so the size starts where it was.
			a^ = {kind = .Size, before = app.brush.radius_px, center = input.mouse_pos - {app.brush.radius_px, 0}}
		case imgui.IsKeyPressed(.U, false):
			s := brush_strength(app)
			a^ = {kind = .Strength, before = s^, center = input.mouse_pos - {s^ * STRENGTH_PX, 0}}
		case:
			return
		}
		viewport_mute(input)
		return
	}

	d := linalg.length(input.mouse_pos - a.center)
	value := adjust_value(app)
	switch a.kind {
	case .None:
	case .Size:
		value^ = clamp(d, MIN_RADIUS_PX, MAX_RADIUS_PX)
	case .Strength:
		value^ = clamp(d / STRENGTH_PX, MIN_STRENGTH, 1)
	}
	again := imgui.IsKeyPressed(.S if a.kind == .Size else .U, false)
	if imgui.IsMouseClicked(.Left) || again {
		a.kind, a.swallow = .None, imgui.IsMouseClicked(.Left)
	} else if imgui.IsMouseClicked(.Right) || imgui.IsKeyPressed(.Escape, false) {
		value^ = a.before
		a.kind = .None
	}
	viewport_mute(input)
}

// The setting the running adjustment changes.
@(private = "file")
adjust_value :: proc(app: ^App) -> ^f32 {
	if app.ui.adjust.kind == .Strength do return brush_strength(app)
	return &app.brush.radius_px
}

// Draws the circle being sized, or the strength as a filled share of it, with the value.
// Returns false when no adjustment is running, so the usual brush outline is drawn.
draw_adjust :: proc(app: ^App, list: ^imgui.DrawList, o: imgui.Vec2) -> bool {
	a := app.ui.adjust
	if a.kind == .None do return false
	rgba :: proc(c: [4]f32) -> u32 {return imgui.ColorConvertFloat4ToU32(c)}
	c := o + a.center
	label: cstring
	switch a.kind {
	case .None:
	case .Size:
		imgui.DrawList_AddCircle(list, c, app.brush.radius_px, rgba({1, 0.8, 0.4, 0.95}), 64, 2)
		label = fmt.ctprintf("Radius %.0f px", app.brush.radius_px)
	case .Strength:
		s := brush_strength(app)^
		imgui.DrawList_AddCircle(list, c, STRENGTH_PX, rgba({1, 1, 1, 0.35}), 64, 1.5)
		imgui.DrawList_AddCircleFilled(list, c, s * STRENGTH_PX, rgba({1, 0.8, 0.4, 0.25}), 64)
		imgui.DrawList_AddCircle(list, c, s * STRENGTH_PX, rgba({1, 0.8, 0.4, 0.95}), 64, 2)
		label = fmt.ctprintf("%s strength %.2f", BRUSH_NAMES[app.brush.kind], s)
	}
	// On a dark plate, since the surface behind it is often light.
	size := imgui.CalcTextSize(label)
	imgui.DrawList_AddRectFilled(list, c - size * 0.5 - 4, c + size * 0.5 + 4, rgba({0.08, 0.08, 0.1, 0.8}), 4)
	imgui.DrawList_AddText(list, c - size * 0.5, rgba({1, 1, 1, 1}), label)
	return true
}

// The strength of the brush in use. Each brush keeps its own, as in ZBrush and Blender,
// since a strength right for Draw is far too much for Smooth or Pinch.
brush_strength :: proc(app: ^App) -> ^f32 {return &app.brush.strengths[app.brush.kind]}

// Takes the pointer away from the tools and the camera for this frame.
viewport_mute :: proc(input: ^Viewport_Input) {
	input.primary, input.press, input.smooth, input.invert = false, false, false, false
	input.orbit_drag, input.pan_drag, input.wheel = false, false, 0
}
