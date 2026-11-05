package main

import "core:math/linalg"

import "../geom"
import "../ui"

// The tube's profile pad on the Curve tool's card: its cross-section drawn large enough to
// edit with a finger, with the same points, handles and handle types as a curve in space,
// as Blender's custom bevel profile is: drag a point or a handle, tap the outline for a new
// point, double-tap a point to make it a corner (Vector) or smooth (Auto) again. With Mirror
// a point's partner across the dashed line follows it.

// The pad's state between frames: the picked point (from 1; 0 for none), what the press
// holds, and the last tap on a point, for a double tap.
Profile_Pad :: struct {
	picked:    int,
	held:      Curve_Handle, // .Point, .In or .Out while a press holds one
	index:     int,
	tap_index: int,
	tap_at:    f64,
}

// The part of the profile's plane the pad shows: x from -PAD_X to PAD_X, y from -PAD_Y up
// to PAD_Y, so the unit circle and a little round it fit.
@(private = "file")
PAD_X :: 1.45
@(private = "file")
PAD_Y :: 1.1

// How tall the pad is, in points.
PROFILE_PAD_H :: 176

// Where profile point `p` is drawn in `r`, and back: one scale both ways, y up.
@(private = "file")
pad_scale :: proc(r: ui.Rect) -> f32 {return min((r.w - 16) / (2 * PAD_X), (r.h - 16) / (2 * PAD_Y))}
@(private = "file")
pad_to_screen :: proc(r: ui.Rect, p: [2]f32) -> [2]f32 {
	s := pad_scale(r)
	return {r.x + r.w * 0.5 + p.x * s, r.y + r.h * 0.5 - p.y * s}
}
@(private = "file")
pad_to_profile :: proc(r: ui.Rect, q: [2]f32) -> [2]f32 {
	s := pad_scale(r)
	return {clamp((q.x - r.x - r.w * 0.5) / s, -PAD_X, PAD_X), clamp(-(q.y - r.y - r.h * 0.5) / s, -PAD_Y, PAD_Y)}
}

// Draws the pad for `o` and follows the pointer over it. Returns whether `o` changed, and
// whether the change is a drag still going (one undo step when it lets go).
kit_profile_pad :: proc(app: ^App, o: ^geom.Tube_Outline) -> (changed, dragging: bool) {
	ctx := &app.kit.ctx
	t := ctx.theme
	pad := &app.curve.pad
	a := ui.area(ctx, "profile pad", {0, PROFILE_PAD_H})
	r := a.rect
	if pad.picked > o.count do pad.picked = 0
	reach := max(t.target * 0.4, 10)
	if a.pressed {
		pad.held = .None
		best := reach
		// Handles first where they show, then points over them.
		for q, i in o.points[:o.count] {
			if q.handles == .Vector do continue
			for h, k in ([2][2]f32{q.h_in, q.h_out}) {
				if d := linalg.length(a.mouse - pad_to_screen(r, q.p + h)); d < best do best, pad.held, pad.index = d, Curve_Handle.In if k == 0 else .Out, i
			}
		}
		for q, i in o.points[:o.count] {
			if d := linalg.length(a.mouse - pad_to_screen(r, q.p)); d < best + 2 do best, pad.held, pad.index = d, .Point, i
		}
		switch pad.held {
		case .Point:
			now := input_clock(app)
			if pad.tap_index == pad.index + 1 && now - pad.tap_at < CURVE_DOUBLE_TAP_S {
				q := &o.points[pad.index]
				q.handles = .Auto if q.handles == .Vector || q.handles == .Free else .Vector
				geom.profile_mirror_from(o, pad.index)
				geom.profile_auto_handles(o)
				pad.held, pad.tap_index = .None, 0
				return true, false
			}
			pad.tap_index, pad.tap_at = pad.index + 1, now
			pad.picked = pad.index + 1
		case .In, .Out:
		case .None, .Radius, .Line, .Nub:
			pad.held = .None
			// The outline: a tap there adds a point (with Mirror, its partner too).
			if u, near := pad_line_hit(r, o^, a.mouse, reach); near {
				if at := geom.profile_insert(o, u); at >= 0 {
					geom.profile_auto_handles(o)
					pad.picked = at + 1
					changed = true
				}
			} else {
				pad.picked = 0
			}
		}
	}
	if a.held && pad.held != .None && !a.pressed {
		i := pad.index
		at := pad_to_profile(r, a.mouse)
		pts := geom.profile_bezier(o^)
		p := &pts[i]
		if pad.held == .Point {
			// A point on the mirror line stays on it.
			if o.mirror && geom.profile_partner(o^, i) == i do at.x = 0
			p.p = {at.x, at.y, 0}
		} else {
			h := Vec3{at.x, at.y, 0} - p.p
			if pad.held == .In do p.h_in = h
			else do p.h_out = h
			geom.bezier_align_handles(p, pad.held == .Out)
		}
		geom.profile_from_bezier(o, pts)
		geom.profile_mirror_from(o, i)
		geom.profile_auto_handles(o)
		changed, dragging = true, true
	} else if !a.held {
		pad.held = .None
	}
	pad_draw(app, r, o)
	return
}

// The place on the outline nearest `m` on screen, within `reach`.
@(private = "file")
pad_line_hit :: proc(r: ui.Rect, o: geom.Tube_Outline, m: [2]f32, reach: f32) -> (u: f32, near: bool) {
	pts := geom.profile_bezier(o)
	STEPS :: 24
	best := reach
	prev := pad_to_screen(r, pts[0].p.xy)
	for k in 1 ..= o.count * STEPS {
		uu := f32(k) / STEPS
		q := pad_to_screen(r, geom.bezier_at(pts, true, uu).xy)
		if d := ui_segment_distance(m, prev, q); d < best do best, u, near = d, uu - 0.5 / STEPS, true
		prev = q
	}
	return
}

// The distance from `p` to the segment from `a` to `b`.
@(private = "file")
ui_segment_distance :: proc(p, a, b: [2]f32) -> f32 {
	ab := b - a
	l2 := linalg.dot(ab, ab)
	f := clamp(linalg.dot(p - a, ab) / l2, 0, 1) if l2 > 0 else 0
	return linalg.length(p - (a + ab * f))
}

// The pad: a faint grid, the unit circle (a round tube's size), the mirror line when
// Mirror is on, the outline, the handles in their type's colour and the points (corners as
// diamonds, the picked one white).
@(private = "file")
pad_draw :: proc(app: ^App, r: ui.Rect, o: ^geom.Tube_Outline) {
	ctx := &app.kit.ctx
	t := ctx.theme
	pad := app.curve.pad
	ui.fill_rect(ctx, r, t.radius_medium, t.fill)
	grid := ui.color_fade(t.text, 0.06)
	for k in -2 ..= 2 {
		v := f32(k) * 0.5
		ui.line(ctx, pad_to_screen(r, {v, -PAD_Y}), pad_to_screen(r, {v, PAD_Y}), grid, 1)
		ui.line(ctx, pad_to_screen(r, {-PAD_X, v}), pad_to_screen(r, {PAD_X, v}), grid, 1)
	}
	ui.stroke_circle(ctx, pad_to_screen(r, {0, 0}), pad_scale(r), ui.color_fade(t.text, 0.14), 1)
	if o.mirror {
		DASHES :: 11
		for k in 0 ..< DASHES {
			y0 := -PAD_Y + 2 * PAD_Y * f32(2 * k) / f32(2 * DASHES - 1)
			y1 := -PAD_Y + 2 * PAD_Y * f32(2 * k + 1) / f32(2 * DASHES - 1)
			ui.line(ctx, pad_to_screen(r, {0, y0}), pad_to_screen(r, {0, y1}), ui.color_fade(t.accent, 0.4), 1)
		}
	}
	pts := geom.profile_bezier(o^)
	STEPS :: 24
	line := make([][2]f32, o.count * STEPS, context.temp_allocator)
	for &q, k in line do q = pad_to_screen(r, geom.bezier_at(pts, true, f32(k) / STEPS).xy)
	ui.polyline(ctx, line, t.accent, 2, closed = true)
	for q in o.points[:o.count] {
		if q.handles == .Vector do continue
		color := overlay_color(CURVE_HANDLE_COLORS[q.handles])
		at := pad_to_screen(r, q.p)
		for h in ([2][2]f32{q.h_in, q.h_out}) {
			if linalg.length(h) < 1e-6 do continue
			end := pad_to_screen(r, q.p + h)
			ui.line(ctx, at, end, color, 1.2)
			ui.fill_circle(ctx, end, 3.5, color)
		}
	}
	for q, i in o.points[:o.count] {
		at := pad_to_screen(r, q.p)
		picked := i == pad.picked - 1
		color := ui.Color{255, 255, 255, 255} if picked else t.accent
		if geom.bezier_is_corner({handles = q.handles}) {
			S :: 6
			diamond := [4][2]f32{at + {0, -S}, at + {S, 0}, at + {0, S}, at + {-S, 0}}
			ui.fill_convex(ctx, diamond[:], color)
		} else {
			ui.fill_circle(ctx, at, 5, color)
		}
	}
}
