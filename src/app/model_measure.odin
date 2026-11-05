package main

import "core:fmt"
import "core:math/linalg"

import "../gizmo"

// The Model tool's Measure action, as Blender's Measure tool, Shapr3D's and Plasticity's
// distance readouts: a drag from one place to another, or a tap on each, shows a line
// between them labelled with its length and how far apart its ends are along X, Y and Z.
// Each end lands where a snap to points would (a cage point, an edge or face middle, a
// curve point near the pen on screen), else on the surface under the pen, so a length
// between two corners is exact. It changes nothing, so it is no undo step; the line shows
// while Measure is the action, until the next measurement.
Model_Measure :: struct {
	a, b:  Vec3,
	ends:  int, // 0 for none, 1 with only `a` placed, 2 with both
	held:  bool, // the pen is down, carrying `b`
	first: bool, // ...from a press that placed `a`, so a tap leaves it waiting for `b`
	press: [2]f32,
	made:  int, // measurements finished, for the exit stats
}

// Where an end of a measurement with the pen at `at` lands: the nearest point on screen,
// else the surface under it.
measure_point :: proc(app: ^App, at, size: [2]f32) -> (p: Vec3, ok: bool) {
	if p, ok = snap_find(app, .Points, at, size, {}); ok do return
	return snap_find(app, .Surface, at, size, {})
}

// The Measure action, a frame: a press places an end, a drag carries the other, a lift
// ends it. Never fails.
model_measure_frame :: proc(app: ^App, input: Viewport_Input) -> bool {
	ms := &app.model.measure
	if ms.held {
		if p, ok := measure_point(app, input.mouse_pos, input.size); ok do ms.b = p
		if input.primary do return true
		ms.held = false
		// A lift away from the press ends the measurement; a tap on its first end leaves it
		// waiting for the second tap.
		if ms.first && linalg.length(input.mouse_pos - ms.press) <= app.kit.ctx.theme.slop do return true
		ms.ends = 2
		ms.made += 1
		return true
	}
	if !input.primary || !input.press do return true
	p, ok := measure_point(app, input.mouse_pos, input.size)
	if !ok {
		ms.ends = 0
		return true
	}
	ms.held, ms.press, ms.b = true, input.mouse_pos, p
	// A press with one end placed places the other; else it begins a new measurement.
	ms.first = ms.ends != 1
	if ms.first do ms.a, ms.ends = p, 1
	return true
}

// The measurement's text: its length, then how far apart its ends are along each axis.
measure_text :: proc(a, b: Vec3) -> string {
	d := b - a
	return fmt.tprintf("%.3f · X %.3f  Y %.3f  Z %.3f", linalg.length(d), abs(d.x), abs(d.y), abs(d.z))
}

// The measurement over the view: its ends ringed, the line between them and its label at
// the middle. With one end placed, the line runs to where the pen would place the other.
draw_measure_overlay :: proc(app: ^App, o: Overlay, input: Viewport_Input) {
	ms := &app.model.measure
	px := gizmo_scale(app)
	color := overlay_color(GIZMO_HIGHLIGHT)
	vp := view_proj_of(app, input.size)
	a, b := ms.a, ms.b
	shown := ms.ends == 2 || ms.held
	if ms.ends == 1 && !ms.held && input.hovered {
		b, shown = measure_point(app, input.mouse_pos, input.size)
	}
	// The place the pen is over, so the user sees where the next end would land.
	if !ms.held && input.hovered && ms.ends != 1 {
		if p, ok := measure_point(app, input.mouse_pos, input.size); ok do draw_snap_mark(app, o, input.size, p)
	}
	if ms.ends == 0 {
		overlay_label(o, MODEL_ACTION_NAMES[.Measure], input.mouse_pos + {0, -36})
		return
	}
	sa, seen_a := gizmo.project(vp, a, input.size)
	if seen_a do overlay_circle(o, sa, 5 * px, color, 2 * px)
	if !shown do return
	sb, seen_b := gizmo.project(vp, b, input.size)
	if seen_b do overlay_circle(o, sb, 5 * px, color, 2 * px)
	if !seen_a || !seen_b do return
	overlay_line(o, sa, sb, color, 2 * px)
	overlay_label(o, measure_text(a, b), (sa + sb) * 0.5 + {0, -20 * px})
}
