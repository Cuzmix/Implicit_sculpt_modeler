package main

import "core:log"
import "core:math/linalg"

import "../camera"
import "../geom"
import "../gizmo"

// Editing a selected curve object with the pen, in the Curve tool: its points, their
// orange handles and white radius dots are drawn over the model and can be dragged, and
// the line between points pulls like a rope, as ZBrush's curves do. A tap on a point
// makes it a corner (a diamond) or smooth again (a square) and picks it for the context
// bar; a tap on the line adds a point there; a point dropped on its neighbour merges with
// it. Each edit, on release, is one undo step of the curve (a swap entry).

Curve_Handle :: enum u8 {
	None,
	Point,
	In,
	Out,
	Radius,
	Line, // the line between points: a drag pulls it, a tap adds a point
}

// A press on the selected curve: what it holds, of which point (or at which place `u` of
// the line), where it began and whether it has moved past a tap; the curve as it was
// before, for its undo step.
Curve_Drag :: struct {
	handle: Curve_Handle,
	index:  int,
	u:      f32,
	from:   [2]f32,
	moved:  bool,
	id:     int,
	before: ^Object_Snapshot,
}

// How near, in pixels, a press must be to take a point, handle, dot or the line.
CURVE_GRAB_PX :: 14

// How far past a point's radius on screen its radius dot sits, in pixels.
CURVE_DOT_GAP_PX :: 12

// The selected object when it is a curve, or nil.
selected_curve :: proc(app: ^App) -> ^Object {
	obj := selected_object(app)
	return obj if object_is_curve(obj) else nil
}

// Where point `i` of `obj`'s curve and its handles are on screen; ok false when the point
// is behind the eye.
Curve_Point_Screen :: struct {
	point, h_in, h_out, radius: [2]f32,
	ok:                         bool,
}

curve_point_screen :: proc(app: ^App, obj: ^Object, view_proj: matrix[4, 4]f32, size: [2]f32, i: int) -> (sc: Curve_Point_Screen) {
	cp := obj.curve
	t := obj.transform
	p := cp.points[i]
	world := to_world(t, p.p)
	sc.point, sc.ok = gizmo.project(view_proj, world, size)
	if !sc.ok do return
	sc.h_in, _ = gizmo.project(view_proj, to_world(t, p.p + p.h_in), size)
	sc.h_out, _ = gizmo.project(view_proj, to_world(t, p.p + p.h_out), size)
	way := sc.h_out - sc.h_in
	if linalg.length(way) < 1e-3 {
		k := (i + 1) % len(cp.points)
		nb, _ := gizmo.project(view_proj, to_world(t, cp.points[k].p), size)
		way = nb - sc.point
	}
	across := linalg.normalize0([2]f32{-way.y, way.x})
	if across == {} do across = {0, -1}
	per_px := camera.orbit_world_per_px(app.camera, world, size.y)
	sc.radius = sc.point + across * (p.radius * t.scale / max(per_px, 1e-12) + CURVE_DOT_GAP_PX)
	return
}

// Whether point `i` has a handle on that side: an open curve's ends have none outward.
@(private = "file")
curve_has_handle :: proc(cp: ^Curve_Part, i: int, out: bool) -> bool {
	if cp.closed do return true
	return i < len(cp.points) - 1 if out else i > 0
}

// What a press at `pos` takes of the selected curve: a point first, then a handle or a
// radius dot, then the line.
curve_hit :: proc(app: ^App, obj: ^Object, size, pos: [2]f32) -> (d: Curve_Drag) {
	cp := obj.curve
	view_proj := edit_view_proj(app, size)
	best := f32(CURVE_GRAB_PX)
	try :: proc(d: ^Curve_Drag, best: ^f32, at, pos: [2]f32, h: Curve_Handle, i: int) {
		if l := linalg.length(at - pos); l < best^ do best^, d.handle, d.index = l, h, i
	}
	for i in 0 ..< len(cp.points) {
		sc := curve_point_screen(app, obj, view_proj, size, i)
		if sc.ok do try(&d, &best, sc.point, pos, .Point, i)
	}
	if d.handle != .None do return
	for i in 0 ..< len(cp.points) {
		sc := curve_point_screen(app, obj, view_proj, size, i)
		if !sc.ok do continue
		if curve_has_handle(cp, i, false) do try(&d, &best, sc.h_in, pos, .In, i)
		if curve_has_handle(cp, i, true) do try(&d, &best, sc.h_out, pos, .Out, i)
		try(&d, &best, sc.radius, pos, .Radius, i)
	}
	if d.handle != .None do return
	segs := geom.bezier_segments(len(cp.points), cp.closed)
	STEPS :: 24
	prev: [2]f32
	for k in 0 ..= segs * STEPS {
		u := f32(k) / STEPS
		at, ok := gizmo.project(view_proj, to_world(obj.transform, geom.bezier_at(cp.points[:], cp.closed, u)), size)
		if !ok do return {}
		if k > 0 {
			if l := gizmo.segment_distance(pos, prev, at); l < best do best, d.handle, d.u = l, .Line, (f32(k) - 0.5) / STEPS
		}
		prev = at
	}
	return
}

// A press, drag or release of the Curve tool over the selected curve. Returns whether the
// press is the curve's, so the tool does not also start drawing a new one.
curve_edit_frame :: proc(app: ^App, input: Viewport_Input) -> bool {
	c := &app.curve
	d := &c.drag
	if input.press && input.primary && d.handle == .None {
		obj := selected_curve(app)
		if obj == nil || len(c.placing) > 0 do return false
		hit := curve_hit(app, obj, input.size, input.mouse_pos)
		if hit.handle == .None do return false
		hit.from, hit.id = input.mouse_pos, obj.id
		hit.before = history_snapshot(app, obj, "edit curve")
		d^ = hit
		if hit.handle == .Point do c.picked = hit.index + 1
		return true
	}
	if d.handle == .None do return false
	obj := object_by_id(app, d.id)
	if obj == nil || obj.curve == nil {
		curve_drag_drop(app)
		return true
	}
	if input.primary {
		if linalg.length(input.mouse_pos - d.from) > CURVE_TAP_PX do d.moved = true
		if d.moved do curve_drag_to(app, obj, input)
		return true
	}
	curve_release(app, obj, input)
	return true
}

// Forgets a press on a curve without an undo step (its curve went away, or an undo came).
curve_drag_drop :: proc(app: ^App) {
	d := &app.curve.drag
	if d.before != nil do history_snapshot_drop(d.before)
	d^ = {}
}

// Moves what the press holds to the pointer.
@(private = "file")
curve_drag_to :: proc(app: ^App, obj: ^Object, input: Viewport_Input) {
	cp := obj.curve
	d := &app.curve.drag
	t := obj.transform
	origin, dir := mouse_ray(app.camera, input.mouse_pos, input.size)
	lo, ld := to_local(t, origin), to_local_dir(t, dir)
	// On the plane through `at` facing the view, in the object's space.
	on_plane :: proc(app: ^App, t: Transform, lo, ld, at: Vec3) -> Vec3 {
		facing := linalg.normalize0(to_local_dir(t, camera.orbit_toward(app.camera, to_world(t, at))))
		den := linalg.dot(ld, facing)
		if abs(den) < 1e-8 do return at
		return lo + ld * (linalg.dot(at - lo, facing) / den)
	}
	switch d.handle {
	case .None:
	case .Point:
		p := &cp.points[d.index]
		// Onto the surface under the pointer when there is one, else the view plane.
		if _, hit, _, ok := scene_raycast_surface(app, origin, dir, skip_curves = true); ok do p.p = to_local(t, hit)
		else do p.p = on_plane(app, t, lo, ld, p.p)
	case .In, .Out:
		p := &cp.points[d.index]
		h := on_plane(app, t, lo, ld, p.p) - p.p
		if d.handle == .In do p.h_in = h
		else do p.h_out = h
		geom.bezier_align_handles(p, d.handle == .Out)
	case .Radius:
		p := &cp.points[d.index]
		view_proj := edit_view_proj(app, input.size)
		at, ok := gizmo.project(view_proj, to_world(t, p.p), input.size)
		if !ok do return
		per_px := camera.orbit_world_per_px(app.camera, to_world(t, p.p), input.size.y)
		p.radius = max(linalg.length(input.mouse_pos - at) - CURVE_DOT_GAP_PX, 1) * per_px / t.scale
	case .Line:
		// A rope pull: the two points either side move, handles and all, by shares that
		// put the curve's place `u` exactly under the pointer.
		curve_rope_pull(cp, d.u, on_plane(app, t, lo, ld, geom.bezier_at(cp.points[:], cp.closed, d.u)) - geom.bezier_at(cp.points[:], cp.closed, d.u))
	}
	// Once a frame, as this runs once a frame while the press lasts.
	curve_changed(app, obj)
}

// Moves the line's place `u` by `delta`, moving the points either side with their handles.
// A cubic's point at t weighs its first end, handle with it, (1-t)²(1+2t) and its second
// t²(3-2t); the ends move by (1-t) and t of one share that makes the weighed sum `delta`.
curve_rope_pull :: proc(cp: ^Curve_Part, u: f32, delta: Vec3) {
	segs := geom.bezier_segments(len(cp.points), cp.closed)
	if segs == 0 do return
	seg := clamp(int(u), 0, segs - 1)
	tt := clamp(u - f32(seg), 0, 1)
	w0 := (1 - tt) * (1 - tt) * (1 + 2 * tt)
	w1 := tt * tt * (3 - 2 * tt)
	share := 1 / max(w0 * (1 - tt) + w1 * tt, 1e-4)
	a, b := seg, (seg + 1) % len(cp.points)
	cp.points[a].p += delta * ((1 - tt) * share)
	cp.points[b].p += delta * (tt * share)
}

// Ends the press: a tap toggles a point between smooth and corner or adds a point on the
// line; a point dropped on its neighbour merges into it. A change is one undo step.
@(private = "file")
curve_release :: proc(app: ^App, obj: ^Object, input: Viewport_Input) {
	c := &app.curve
	d := c.drag
	c.drag = {}
	cp := obj.curve
	changed := d.moved
	if !d.moved {
		#partial switch d.handle {
		case .Point:
			if cp.points[d.index].corner do geom.bezier_make_smooth(cp.points[:], cp.closed, d.index)
			else do geom.bezier_make_corner(cp.points[:], cp.closed, d.index)
			changed = true
		case .Line:
			if at := geom.bezier_insert(&cp.points, cp.closed, d.u); at >= 0 {
				c.picked = at + 1
				changed = true
			}
		}
	} else if d.handle == .Point && len(cp.points) > CURVE_MIN_POINTS {
		view_proj := edit_view_proj(app, input.size)
		here := curve_point_screen(app, obj, view_proj, input.size, d.index)
		n := len(cp.points)
		sides := [2]int{d.index - 1, d.index + 1}
		for k in sides {
			if !cp.closed && (k < 0 || k >= n) do continue
			j := (k + n) % n
			if j == d.index do continue
			there := curve_point_screen(app, obj, view_proj, input.size, j)
			if here.ok && there.ok && linalg.length(here.point - there.point) < CURVE_GRAB_PX {
				ordered_remove(&cp.points, d.index)
				c.picked = (j if j < d.index else d.index) + 1
				break
			}
		}
	}
	if !changed {
		history_snapshot_drop(d.before)
		return
	}
	history_record_swap(app, obj.id, d.before, kind = .Curve)
	c.edits += 1
	curve_changed(app, obj)
}

// Deletes the picked point of the selected curve, as one undo step, when it keeps at least
// CURVE_MIN_POINTS (three for a closed curve).
curve_delete_point :: proc(app: ^App) {
	obj := selected_curve(app)
	if obj == nil || !curve_point_deletable(app) do return
	before := history_snapshot(app, obj, "delete curve point")
	ordered_remove(&obj.curve.points, app.curve.picked - 1)
	app.curve.picked = min(app.curve.picked, len(obj.curve.points))
	history_record_swap(app, obj.id, before, kind = .Curve)
	app.curve.edits += 1
	curve_changed(app, obj)
}

curve_point_deletable :: proc(app: ^App) -> bool {
	obj := selected_curve(app)
	if obj == nil do return false
	n := len(obj.curve.points)
	return app.curve.picked >= 1 && app.curve.picked <= n && n > (3 if obj.curve.closed else CURVE_MIN_POINTS)
}

// Turns the picked point into a corner or back into a smooth one, as one undo step.
curve_toggle_corner :: proc(app: ^App) {
	obj := selected_curve(app)
	if obj == nil do return
	i := app.curve.picked - 1
	if i < 0 || i >= len(obj.curve.points) do return
	before := history_snapshot(app, obj, "curve point corner")
	cp := obj.curve
	if cp.points[i].corner do geom.bezier_make_smooth(cp.points[:], cp.closed, i)
	else do geom.bezier_make_corner(cp.points[:], cp.closed, i)
	history_record_swap(app, obj.id, before, kind = .Curve)
	app.curve.edits += 1
	curve_changed(app, obj)
}

// Closes the selected curve into a loop, or opens it, as one undo step; a loop needs three
// points.
curve_toggle_closed :: proc(app: ^App) {
	obj := selected_curve(app)
	if obj == nil || (!obj.curve.closed && len(obj.curve.points) < 3) do return
	before := history_snapshot(app, obj, "close curve")
	obj.curve.closed = !obj.curve.closed
	history_record_swap(app, obj.id, before, kind = .Curve)
	app.curve.edits += 1
	curve_changed(app, obj)
}

// Draws the selected curve's editing handles: orange handles on lines to their point, a
// white radius dot per point, the picked point ringed.
draw_curve_edit :: proc(app: ^App, o: Overlay, size: [2]f32) {
	obj := selected_curve(app)
	if obj == nil do return
	cp := obj.curve
	view_proj := edit_view_proj(app, size)
	orange := overlay_color({0.95, 0.66, 0.23, 1})
	white := overlay_color({1, 1, 1, 1})
	dark := overlay_color({0.04, 0.06, 0.08, 0.8})
	blue := overlay_color({0.4, 0.85, 1, 1})
	for i in 0 ..< len(cp.points) {
		sc := curve_point_screen(app, obj, view_proj, size, i)
		if !sc.ok do continue
		ways := [2]bool{false, true}
		for out in ways {
			if !curve_has_handle(cp, i, out) do continue
			h := sc.h_out if out else sc.h_in
			overlay_line(o, sc.point, h, orange, 1 * o.scale)
			overlay_disc(o, h, 5 * o.scale, dark)
			overlay_disc(o, h, 3.5 * o.scale, orange)
		}
		overlay_line(o, sc.point, sc.radius, overlay_color({1, 1, 1, 0.35}), 1 * o.scale)
		overlay_disc(o, sc.radius, 5.5 * o.scale, dark)
		overlay_disc(o, sc.radius, 4 * o.scale, white)
		if i == app.curve.picked - 1 do overlay_circle(o, sc.point, 9 * o.scale, blue, 2 * o.scale)
	}
}

// Makes the selected curve's tube again after an edit, when it makes one. A GPU failure
// leaves the curve with an empty level, drawn as its line, and says so in the log.
curve_changed :: proc(app: ^App, obj: ^Object) {
	if obj.curve == nil || obj.curve.use == .None do return
	if !curve_rebuild(app, obj) do log.errorf("curve: could not make the tube of %s on the GPU", object_label(obj))
}
