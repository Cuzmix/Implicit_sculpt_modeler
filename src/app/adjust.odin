package main

import "core:fmt"
import "core:math/linalg"
import sdl "vendor:sdl3"

// Changing the brush size or strength without the panels, where the brush is, as
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
// Where a new brush starts, and where a long press on the size slider puts it back.
DEFAULT_RADIUS_PX :: 60
MAX_RADIUS_PX :: 500
MIN_STRENGTH :: 0.01
// Pixels from the middle that count as full strength while adjusting it.
STRENGTH_PX :: 200

// Starts, follows and ends an adjustment with this frame's input.
adjust_update :: proc(app: ^App, input: ^Viewport_Input) {
	a := &app.ui.adjust
	d := &app.device
	if a.swallow {
		if .Left in d.down {
			viewport_mute(input)
		} else {
			a.swallow = false
		}
	}
	if a.kind == .None {
		if app.tool != .Brush || !input.hovered || app.stroke.active || app.ui.pie.open || typing(app) do return
		if d.ctrl || d.alt || d.shift || .Left in d.down do return
		switch {
		case key_pressed(d, sdl.K_S):
			// The pointer lands on the circle's edge, so the size starts where it was.
			a^ = {kind = .Size, before = app.brush.radius_px, center = input.mouse_pos - {app.brush.radius_px, 0}}
		case key_pressed(d, sdl.K_U):
			s := brush_strength(app)
			a^ = {kind = .Strength, before = s^, center = input.mouse_pos - {s^ * STRENGTH_PX, 0}}
		case:
			return
		}
		viewport_mute(input)
		return
	}

	reach := linalg.length(input.mouse_pos - a.center)
	value := adjust_value(app)
	switch a.kind {
	case .None:
	case .Size:
		value^ = clamp(reach, MIN_RADIUS_PX, MAX_RADIUS_PX)
	case .Strength:
		value^ = clamp(reach / STRENGTH_PX, MIN_STRENGTH, 1)
	}
	again := key_pressed(d, sdl.K_S if a.kind == .Size else sdl.K_U)
	if .Left in d.pressed || again {
		a.kind, a.swallow = .None, .Left in d.pressed
	} else if .Right in d.pressed || key_pressed(d, sdl.K_ESCAPE) {
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
draw_adjust :: proc(app: ^App, o: Overlay) -> bool {
	a := app.ui.adjust
	if a.kind == .None do return false
	label: string
	switch a.kind {
	case .None:
	case .Size:
		overlay_circle(o, a.center, app.brush.radius_px, overlay_color({1, 0.8, 0.4, 0.95}), 2)
		label = fmt.tprintf("Radius %.0f px", app.brush.radius_px)
	case .Strength:
		s := brush_strength(app)^
		overlay_circle(o, a.center, STRENGTH_PX, overlay_color({1, 1, 1, 0.35}), 1.5)
		overlay_disc(o, a.center, s * STRENGTH_PX, overlay_color({1, 0.8, 0.4, 0.25}))
		overlay_circle(o, a.center, s * STRENGTH_PX, overlay_color({1, 0.8, 0.4, 0.95}), 2)
		label = fmt.tprintf("%s strength %.2f", BRUSHES[app.brush.kind].name, s)
	}
	overlay_label(o, label, a.center)
	return true
}

// The strength of the brush in use. Each brush keeps its own, as in ZBrush and Blender,
// since a strength right for Draw is far too much for Smooth or Pinch.
brush_strength :: proc(app: ^App) -> ^f32 {return &app.brush.strengths[app.brush.kind]}

// The focal shift of the brush in use, which each brush keeps too (Falloff_Setting).
focal_shift :: proc(app: ^App) -> ^f32 {return &app.brush.falloffs[app.brush.kind].focal}

// Takes the pointer away from the tools and the camera for this frame.
viewport_mute :: proc(input: ^Viewport_Input) {
	input.primary, input.press, input.smooth, input.invert = false, false, false, false
	input.alt, input.mask, input.mask_shape = false, false, false
	input.orbit_drag, input.pan_drag, input.wheel = false, false, 0
}
