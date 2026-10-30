package main

import "core:fmt"
import "core:math/linalg"
import sdl "vendor:sdl3"

import "../camera"

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

// When the size or strength changes away from the view (the size and strength sliders, a
// chip's twist, [ and ], the pie, a script), the brush ring shows in the open view's middle at
// the size it now has, with its value, as Blender's radial control shows it, so a slider
// dragged on a tablet, with no pen hovering, still says how big the brush is on the model.
// It holds while the value keeps changing and fades soon after. A change made with the
// pointer on the view shows on the ring under it instead.
Size_Preview :: struct {
	kind:     Adjust_Kind, // what changed last; None before anything did
	radius:   f32, // the values seen last frame
	strength: f32,
	at:       f64, // the interface's clock at the last change
	seen:     bool,
	shown:    int, // previews started, for the exit stats
}

// Seconds the preview holds after the last change, then takes to fade.
SIZE_PREVIEW_HOLD :: 0.7
SIZE_PREVIEW_FADE :: 0.3

// Draws the preview while it shows, after noting this frame's change; `hovered` is the
// pointer on the view, whose own ring shows a change made there.
draw_size_preview :: proc(app: ^App, o: Overlay, size: [2]f32, hovered: bool) {
	p := &app.ui.size_preview
	now := app.kit.ctx.time
	radius, strength := app.brush.radius_px, brush_strength(app)^
	if p.seen && !hovered && app.ui.adjust.kind == .None && !app.stroke.active {
		kind: Adjust_Kind = .Size if radius != p.radius else .Strength if strength != p.strength else .None
		if kind != .None {
			if p.kind == .None || now - p.at > SIZE_PREVIEW_HOLD + SIZE_PREVIEW_FADE do p.shown += 1
			p.kind, p.at = kind, now
		}
	}
	p.radius, p.strength, p.seen = radius, strength, true
	if p.kind == .None do return
	t := f32(now - p.at)
	if t > SIZE_PREVIEW_HOLD + SIZE_PREVIEW_FADE || hovered || app.ui.adjust.kind != .None {
		p.kind = .None
		return
	}
	fade := clamp(1 - (t - SIZE_PREVIEW_HOLD) / SIZE_PREVIEW_FADE, 0, 1)
	// The middle of the view the panels leave open, where the camera centres the model,
	// in the overlay's viewport pixels.
	center := size * 0.5
	if grid_panes(&app.kit.grid) == 1 {
		free := lens_free_area(app)
		center = [2]f32{free.x + free.w * 0.5, free.y + free.h * 0.5} * o.scale - o.origin
	}
	label: string
	switch p.kind {
	case .None:
	case .Size:
		// At the size the brush has on the model at the view's middle, as the ring a
		// hovering pointer draws off the model.
		flat := radius * brush_size_scale(app, camera.orbit_world_per_px(app.camera, app.camera.target, size.y), size.y)
		overlay_circle(o, center, flat, overlay_color({1, 1, 1, 0.9 * fade}), 2)
		overlay_disc(o, center, 2, overlay_color({1, 1, 1, 0.6 * fade}))
		label = fmt.tprintf("Radius %.0f px", radius)
	case .Strength:
		overlay_circle(o, center, STRENGTH_PX, overlay_color({1, 1, 1, 0.35 * fade}), 1.5)
		overlay_disc(o, center, strength * STRENGTH_PX, overlay_color({1, 0.8, 0.4, 0.25 * fade}))
		overlay_circle(o, center, strength * STRENGTH_PX, overlay_color({1, 0.8, 0.4, 0.95 * fade}), 2)
		label = fmt.tprintf("%s strength %.2f", BRUSHES[app.brush.kind].name, strength)
	}
	if fade > 0.5 do overlay_label(o, label, center)
}

// Takes the pointer away from the tools and the camera for this frame.
viewport_mute :: proc(input: ^Viewport_Input) {
	input.primary, input.press, input.smooth, input.invert = false, false, false, false
	input.alt, input.mask, input.mask_shape = false, false, false
	input.orbit_drag, input.pan_drag, input.wheel = false, false, 0
}
