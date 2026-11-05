package main

import "core:fmt"
import "core:math"

import "../ui"

// The Point section of the Curve tool's Edit tab, as Blender's N panel for a curve: the
// picked points' middle X, Y and Z in the world, their radius and their tilt, each a value
// to drag. A drag moves every picked point by the change (so points apart stay apart), one
// undo step when it lets go, through a Curve_Points command.

// The picked points' values: the middle in the world, the mean radius in world units and
// the mean tilt in degrees.
Curve_Point_Values :: struct {
	middle: Vec3,
	radius: f32,
	tilt:   f32,
}

// The picked points' values on `obj`, and how many are picked.
curve_point_values :: proc(obj: ^Object) -> (v: Curve_Point_Values, n: int) {
	v.middle, n = curve_picked_middle(obj)
	if n == 0 do return
	for p in obj.curve.points do if p.selected {
		v.radius += p.radius
		v.tilt += p.twist
	}
	v.radius *= obj.transform.scale / f32(n)
	v.tilt = math.to_degrees(v.tilt / f32(n))
	return
}

// Moves `obj`'s picked points by the change from their values now to `wanted`, a radius
// no lower than zero, and makes its level again: one undo step, or with `drag` one from
// the first change to the release (as a look slider's, curve_look_drag_end). Returns false
// only on a GPU failure.
curve_set_point_values :: proc(app: ^App, obj: ^Object, wanted: Curve_Point_Values, drag := false) -> bool {
	cur, n := curve_point_values(obj)
	if n == 0 || cur == wanted do return true
	ld := &app.curve.look_drag
	if drag && ld.before != nil && ld.object != obj.id do curve_look_drag_end(app, force = true)
	before: ^Object_Snapshot
	if !drag {
		before = history_snapshot(app, obj, "point values")
		app.curve.edits += 1
	} else if ld.before == nil {
		ld^ = {object = obj.id, before = history_snapshot(app, obj, "point values")}
		app.curve.edits += 1
	}
	t := obj.transform
	move := to_local_dir(t, wanted.middle - cur.middle) / t.scale
	grow := (wanted.radius - cur.radius) / t.scale
	turn := math.to_radians(wanted.tilt - cur.tilt)
	for &p in obj.curve.points do if p.selected {
		p.p += move
		p.radius = max(p.radius + grow, 0)
		p.twist += turn
	}
	curve_changed(app, obj)
	if before != nil do history_record_swap(app, obj.id, before, kind = .Curve)
	return true
}

// The Point section: nothing until a point is picked.
kit_curve_point_section :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	v, n := curve_point_values(obj)
	if n == 0 do return
	ui.label(ctx, "Point" if n == 1 else fmt.tprintf("%d points", n), ctx.theme.small_size)
	wanted := v
	// A step a point dragged: about a thousandth of the curve's own size in the world.
	step := 0.002 * max(obj.transform.scale, 1e-3)
	// A value a rounding error from zero reads 0, not -0.
	shown :: proc(v: f32, format: string) -> string {return fmt.tprintf(format, 0 if abs(v) < 5e-4 else v)}
	axes := [3]string{"X", "Y", "Z"}
	changed := false
	for axis, i in axes {
		if ui.drag_value(ctx, fmt.tprintf("%s##curve point", axis), &wanted.middle[i], step, -1e4, 1e4, shown(wanted.middle[i], "%.3f")) do changed = true
	}
	if ui.drag_value(ctx, "Radius##curve point", &wanted.radius, 0.2 * step, 0, 1e3, fmt.tprintf("%.3f", wanted.radius)) do changed = true
	if ui.drag_value(ctx, "Tilt##curve point", &wanted.tilt, 0.5, -1e4, 1e4, shown(wanted.tilt, "%.0f°")) do changed = true
	if changed do app.ui.scene_command = {kind = .Curve_Points, points = wanted, look_drag = true}
}
