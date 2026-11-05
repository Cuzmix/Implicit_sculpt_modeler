package main

import "core:math/linalg"

import "../geom"
import "../ui"

// The tube's two pads on the Curve tool's card, as Blender's custom bevel profile and taper
// curve are: the profile (its cross-section, a closed outline) and the width along (an open
// graph from the curve's start to its end), each drawn large enough to edit with a finger,
// with the same points, handles and handle types as a curve in space: drag a point or a
// handle, tap the line for a new point, double-tap a point to make it a corner (Vector) or
// smooth (Auto) again. On the profile with Mirror a point's partner across the dashed line
// follows it; on the width the ends stay at the start and end and the points in order.

// A pad's state between frames: the picked point (from 1; 0 for none), what the press
// holds, and the last tap on a point, for a double tap.
Profile_Pad :: struct {
	picked:    int,
	held:      Curve_Handle, // .Point, .In or .Out while a press holds one
	index:     int,
	tap_index: int,
	tap_at:    f64,
}

// What a pad edits.
Pad_Target :: union {
	^geom.Tube_Outline,
	^geom.Tube_Width,
}

// The part of the graph's plane a pad shows, and whether x and y share one scale (the
// profile, so a circle stays round) or each fills the pad (the width, start to end).
@(private = "file")
Pad_View :: struct {
	lo, hi:  [2]f32,
	uniform: bool,
}

@(private = "file")
PROFILE_VIEW :: Pad_View{{-1.45, -1.1}, {1.45, 1.1}, true}
@(private = "file")
WIDTH_VIEW :: Pad_View{{0, 0}, {1, geom.WIDTH_MAX}, false}

// How tall each pad is, in points.
PROFILE_PAD_H :: 176
WIDTH_PAD_H :: 104

@(private = "file")
pad_view :: proc(t: Pad_Target) -> Pad_View {
	switch _ in t {
	case ^geom.Tube_Outline:
		return PROFILE_VIEW
	case ^geom.Tube_Width:
		return WIDTH_VIEW
	}
	return PROFILE_VIEW
}

// The scale each way from the graph's plane to the pad `r`, a margin kept all round.
@(private = "file")
pad_scale :: proc(r: ui.Rect, v: Pad_View) -> [2]f32 {
	M :: 16
	s := [2]f32{(r.w - M) / (v.hi.x - v.lo.x), (r.h - M) / (v.hi.y - v.lo.y)}
	if v.uniform do s = min(s.x, s.y)
	return s
}

// Where graph point `p` is drawn in `r`, and back: the view's middle at the pad's, y up.
@(private = "file")
pad_to_screen :: proc(r: ui.Rect, v: Pad_View, p: [2]f32) -> [2]f32 {
	s := pad_scale(r, v)
	mid := 0.5 * (v.lo + v.hi)
	return {r.x + r.w * 0.5 + (p.x - mid.x) * s.x, r.y + r.h * 0.5 - (p.y - mid.y) * s.y}
}
@(private = "file")
pad_to_graph :: proc(r: ui.Rect, v: Pad_View, q: [2]f32) -> [2]f32 {
	s := pad_scale(r, v)
	mid := 0.5 * (v.lo + v.hi)
	p := [2]f32{mid.x + (q.x - r.x - r.w * 0.5) / s.x, mid.y - (q.y - r.y - r.h * 0.5) / s.y}
	return {clamp(p.x, v.lo.x, v.hi.x), clamp(p.y, v.lo.y, v.hi.y)}
}

// The target's points in use.
@(private = "file")
pad_points :: proc(t: Pad_Target) -> []geom.Profile_Point {
	switch g in t {
	case ^geom.Tube_Outline:
		return g.points[:g.count]
	case ^geom.Tube_Width:
		return g.points[:g.count]
	}
	return nil
}

// The target as curve points, and whether it is closed.
@(private = "file")
pad_bezier :: proc(t: Pad_Target) -> (pts: []geom.Bezier_Point, closed: bool) {
	switch g in t {
	case ^geom.Tube_Outline:
		return geom.profile_bezier(g^), true
	case ^geom.Tube_Width:
		return geom.width_bezier(g^), false
	}
	return
}
@(private = "file")
pad_set :: proc(t: Pad_Target, pts: []geom.Bezier_Point) {
	switch g in t {
	case ^geom.Tube_Outline:
		geom.profile_from_bezier(g, pts)
	case ^geom.Tube_Width:
		geom.width_from_bezier(g, pts)
	}
}

// After point i moved: its mirror partner follows on the profile, it keeps its place on the
// width; then the Auto and Vector points take their handles again.
@(private = "file")
pad_settle :: proc(t: Pad_Target, i: int) {
	switch g in t {
	case ^geom.Tube_Outline:
		geom.profile_mirror_from(g, i)
		geom.profile_auto_handles(g)
	case ^geom.Tube_Width:
		geom.width_hold(g, i)
		geom.width_auto_handles(g)
		geom.width_hold(g, i)
	}
}
@(private = "file")
pad_insert :: proc(t: Pad_Target, u: f32) -> int {
	at := -1
	switch g in t {
	case ^geom.Tube_Outline:
		at = geom.profile_insert(g, u)
		if at >= 0 do geom.profile_auto_handles(g)
	case ^geom.Tube_Width:
		at = geom.width_insert(g, u)
		if at >= 0 do geom.width_auto_handles(g)
	}
	return at
}

// Whether point i's handle k (0 in, 1 out) shows and can be dragged: not a corner's, not
// one of no length, and not the one past either end of an open graph.
@(private = "file")
pad_handle_shown :: proc(pts: []geom.Profile_Point, closed: bool, i, k: int) -> bool {
	if pts[i].handles == .Vector do return false
	if !closed && ((i == 0 && k == 0) || (i == len(pts) - 1 && k == 1)) do return false
	return linalg.length(pts[i].h_in if k == 0 else pts[i].h_out) > 1e-6
}

// Draws the pad named `name` for `t`, with `pad` its state, and follows the pointer over
// it. Returns whether `t` changed, and whether the change is a drag still going (one undo
// step when it lets go).
kit_curve_pad :: proc(app: ^App, pad: ^Profile_Pad, name: string, t: Pad_Target) -> (changed, dragging: bool) {
	ctx := &app.kit.ctx
	th := ctx.theme
	v := pad_view(t)
	_, is_width := t.(^geom.Tube_Width)
	a := ui.area(ctx, name, {0, WIDTH_PAD_H if is_width else PROFILE_PAD_H})
	r := a.rect
	pts := pad_points(t)
	closed := !is_width
	if pad.picked > len(pts) do pad.picked = 0
	reach := max(th.target * 0.4, 10)
	if a.pressed {
		pad.held = .None
		best := reach
		// Handles first where they show, then points over them.
		for q, i in pts {
			for k in 0 ..< 2 {
				if !pad_handle_shown(pts, closed, i, k) do continue
				end := q.p + (q.h_in if k == 0 else q.h_out)
				if d := linalg.length(a.mouse - pad_to_screen(r, v, end)); d < best do best, pad.held, pad.index = d, Curve_Handle.In if k == 0 else .Out, i
			}
		}
		for q, i in pts {
			if d := linalg.length(a.mouse - pad_to_screen(r, v, q.p)); d < best + 2 do best, pad.held, pad.index = d, .Point, i
		}
		switch pad.held {
		case .Point:
			now := input_clock(app)
			if pad.tap_index == pad.index + 1 && now - pad.tap_at < CURVE_DOUBLE_TAP_S {
				q := &pts[pad.index]
				q.handles = .Auto if q.handles == .Vector || q.handles == .Free else .Vector
				pad_settle(t, pad.index)
				pad.held, pad.tap_index = .None, 0
				return true, false
			}
			pad.tap_index, pad.tap_at = pad.index + 1, now
			pad.picked = pad.index + 1
		case .In, .Out:
		case .None, .Radius, .Line, .Nub:
			pad.held = .None
			// The line: a tap there adds a point (on the profile with Mirror, its partner too).
			if u, near := pad_line_hit(r, v, t, a.mouse, reach); near {
				if at := pad_insert(t, u); at >= 0 {
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
		at := pad_to_graph(r, v, a.mouse)
		bez, _ := pad_bezier(t)
		p := &bez[i]
		if pad.held == .Point {
			// A point on the mirror line stays on it.
			if o, ok := t.(^geom.Tube_Outline); ok && o.mirror && geom.profile_partner(o^, i) == i do at.x = 0
			p.p = {at.x, at.y, 0}
		} else {
			h := Vec3{at.x, at.y, 0} - p.p
			if pad.held == .In do p.h_in = h
			else do p.h_out = h
			geom.bezier_align_handles(p, pad.held == .Out)
		}
		pad_set(t, bez)
		pad_settle(t, i)
		changed, dragging = true, true
	} else if !a.held {
		pad.held = .None
	}
	pad_draw(app, pad^, r, v, t)
	return
}

// The place on the line nearest `m` on screen, within `reach`.
@(private = "file")
pad_line_hit :: proc(r: ui.Rect, v: Pad_View, t: Pad_Target, m: [2]f32, reach: f32) -> (u: f32, near: bool) {
	pts, closed := pad_bezier(t)
	if len(pts) < 2 do return
	STEPS :: 24
	best := reach
	prev := pad_to_screen(r, v, pts[0].p.xy)
	segs := len(pts) if closed else len(pts) - 1
	for k in 1 ..= segs * STEPS {
		uu := f32(k) / STEPS
		q := pad_to_screen(r, v, geom.bezier_at(pts, closed, uu).xy)
		if d := segment_distance(m, prev, q); d < best do best, u, near = d, uu - 0.5 / STEPS, true
		prev = q
	}
	return
}

// The distance from `p` to the segment from `a` to `b`.
@(private = "file")
segment_distance :: proc(p, a, b: [2]f32) -> f32 {
	ab := b - a
	l2 := linalg.dot(ab, ab)
	f := clamp(linalg.dot(p - a, ab) / l2, 0, 1) if l2 > 0 else 0
	return linalg.length(p - (a + ab * f))
}

// A dashed line from `a` to `b`, for a pad's guides.
@(private = "file")
pad_dashed :: proc(ctx: ^ui.Context, a, b: [2]f32, color: ui.Color) {
	DASHES :: 11
	for k in 0 ..< DASHES {
		f0 := f32(2 * k) / f32(2 * DASHES - 1)
		f1 := f32(2 * k + 1) / f32(2 * DASHES - 1)
		ui.line(ctx, linalg.lerp(a, b, f0), linalg.lerp(a, b, f1), color, 1)
	}
}

// The pad: a faint grid; on the profile the unit circle (a round tube's size) and the
// mirror line when Mirror is on, on the width its floor and the level of one (each point's
// own radius) dashed; the line, the handles in their type's colour and the points (corners
// as diamonds, the picked one white).
@(private = "file")
pad_draw :: proc(app: ^App, pad: Profile_Pad, r: ui.Rect, v: Pad_View, t: Pad_Target) {
	ctx := &app.kit.ctx
	th := ctx.theme
	ui.fill_rect(ctx, r, th.radius_medium, th.fill)
	grid := ui.color_fade(th.text, 0.06)
	guide := ui.color_fade(th.text, 0.14)
	closed := true
	switch g in t {
	case ^geom.Tube_Outline:
		for k in -2 ..= 2 {
			f := f32(k) * 0.5
			ui.line(ctx, pad_to_screen(r, v, {f, v.lo.y}), pad_to_screen(r, v, {f, v.hi.y}), grid, 1)
			ui.line(ctx, pad_to_screen(r, v, {v.lo.x, f}), pad_to_screen(r, v, {v.hi.x, f}), grid, 1)
		}
		ui.stroke_circle(ctx, pad_to_screen(r, v, {0, 0}), pad_scale(r, v).x, guide, 1)
		if g.mirror do pad_dashed(ctx, pad_to_screen(r, v, {0, v.lo.y}), pad_to_screen(r, v, {0, v.hi.y}), ui.color_fade(th.accent, 0.4))
	case ^geom.Tube_Width:
		closed = false
		for k in 1 ..= 3 {
			f := f32(k) * 0.25
			ui.line(ctx, pad_to_screen(r, v, {f, v.lo.y}), pad_to_screen(r, v, {f, v.hi.y}), grid, 1)
		}
		ui.line(ctx, pad_to_screen(r, v, {0, 0.5}), pad_to_screen(r, v, {1, 0.5}), grid, 1)
		ui.line(ctx, pad_to_screen(r, v, {0, 0}), pad_to_screen(r, v, {1, 0}), guide, 1)
		pad_dashed(ctx, pad_to_screen(r, v, {0, 1}), pad_to_screen(r, v, {1, 1}), guide)
	}
	bez, _ := pad_bezier(t)
	if len(bez) < 2 do return
	STEPS :: 24
	segs := len(bez) if closed else len(bez) - 1
	line := make([][2]f32, segs * STEPS + (0 if closed else 1), context.temp_allocator)
	for &q, k in line do q = pad_to_screen(r, v, geom.bezier_at(bez, closed, f32(k) / STEPS).xy)
	ui.polyline(ctx, line, th.accent, 2, closed = closed)
	pts := pad_points(t)
	for q, i in pts {
		color := overlay_color(CURVE_HANDLE_COLORS[q.handles])
		at := pad_to_screen(r, v, q.p)
		for k in 0 ..< 2 {
			if !pad_handle_shown(pts, closed, i, k) do continue
			end := pad_to_screen(r, v, q.p + (q.h_in if k == 0 else q.h_out))
			ui.line(ctx, at, end, color, 1.2)
			ui.fill_circle(ctx, end, 3.5, color)
		}
	}
	for q, i in pts {
		at := pad_to_screen(r, v, q.p)
		color := ui.Color{255, 255, 255, 255} if i == pad.picked - 1 else th.accent
		if geom.bezier_is_corner({handles = q.handles}) {
			S :: 6
			diamond := [4][2]f32{at + {0, -S}, at + {S, 0}, at + {0, S}, at + {-S, 0}}
			ui.fill_convex(ctx, diamond[:], color)
		} else {
			ui.fill_circle(ctx, at, 5, color)
		}
	}
}
