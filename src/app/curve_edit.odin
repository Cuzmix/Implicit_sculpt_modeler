package main

import "core:log"
import "core:math"
import "core:math/linalg"

import "../camera"
import "../geom"
import "../gizmo"

// Editing a selected curve object with the pen, in the Curve tool: its points, their
// handles (coloured by type) and white radius dots are drawn over the model and can be dragged, and
// the line between points pulls like a rope, as ZBrush's curves do. A tap on a point picks
// it (Shift adds it to the picked points, and in the Edit tab a box dragged over empty space
// picks those inside, as Blender's edit mode does), and the picked points move together; a
// double tap makes them corners (diamonds) or smooth again (squares). Handles show on the
// picked points and their neighbours. A tap on the line adds a point there; a point dropped
// on its neighbour merges with it. Each edit, on release, is one undo step of the curve (a
// swap entry); picking alone is not.

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

// A box dragged over empty space in the Edit tab, in viewport pixels; `add` (Shift) adds
// to the picked points rather than replacing them.
Curve_Box :: struct {
	active:   bool,
	from, to: [2]f32,
	add:      bool,
}

// The last tap on a point: which object and point, and when, in seconds.
Curve_Tap :: struct {
	id, index: int,
	at:        f64,
}

// How soon, in seconds, a second tap on the same point makes a double tap.
CURVE_DOUBLE_TAP_S :: 0.35

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
		if !curve_handles_shown(app, cp, i) do continue
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
		if hit.handle == .Point {
			// Shift adds the point to the picked ones or takes it away; a press on a point not
			// picked picks it alone; a press on a picked one keeps them all, to move together.
			p := &obj.curve.points[hit.index]
			if input.smooth do p.selected = !p.selected
			else if !p.selected {
				curve_select_none(obj.curve)
				p.selected = true
			}
			c.picked = hit.index + 1
		}
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
		// Onto the surface under the pointer with Surface, else the Draw on plane through
		// where the point is (with Surface, the plane facing the view).
		if hit, _, ok := curve_land(app, input.mouse_pos, input.size, to_world(t, p.p)); ok {
			// The other picked points move by as much, so a picked group keeps its shape.
			delta := to_local(t, hit) - p.p
			for &q, j in cp.points do if j != d.index && q.selected && p.selected do q.p += delta
			p.p = to_local(t, hit)
		}
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

// Ends the press: a tap picks a point (a double tap turns the picked points between smooth
// and corner) or adds a point on the line; a point dropped on its neighbour merges into it.
// A change is one undo step.
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
			// A double tap turns the picked points into corners or back into smooth ones (as the
			// tapped one goes); a single tap on one of several picked points picks it alone.
			now := input_clock(app)
			if c.tap.id == obj.id && c.tap.index == d.index && now - c.tap.at < CURVE_DOUBLE_TAP_S {
				curve_corners_flip(cp, d.index)
				changed = true
				c.tap = {}
			} else {
				if !input.smooth {
					curve_select_none(cp)
					cp.points[d.index].selected = true
				}
				c.tap = {obj.id, d.index, now}
			}
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

// The points the context bar's commands work on: the picked points of `cp`, or with none
// picked, the one the Curve tool picked last (app.curve.picked, from 1), or none.
curve_targets :: proc(app: ^App, cp: ^Curve_Part) -> []int {
	out := make([dynamic]int, 0, len(cp.points), context.temp_allocator)
	for p, i in cp.points do if p.selected do append(&out, i)
	if len(out) == 0 && app.curve.picked >= 1 && app.curve.picked <= len(cp.points) do append(&out, app.curve.picked - 1)
	return out[:]
}

curve_select_none :: proc(cp: ^Curve_Part) {
	for &p in cp.points do p.selected = false
}

curve_selected_count :: proc(cp: ^Curve_Part) -> (n: int) {
	for p in cp.points do if p.selected do n += 1
	return
}

// Picks every point of the selected curve, or none when all are picked already.
curve_select_all :: proc(app: ^App) {
	obj := selected_curve(app)
	if obj == nil do return
	cp := obj.curve
	all := curve_selected_count(cp) == len(cp.points)
	for &p in cp.points do p.selected = !all
}

// Whether point `i`'s handles and radius dot show and take presses: those of the picked
// points and of their neighbours (whose handles shape the same segments), or every point's
// with Show every point's handles. Twenty orange dots over the model hide more than they offer.
curve_handles_shown :: proc(app: ^App, cp: ^Curve_Part, i: int) -> bool {
	if app.curve.all_handles || i == app.curve.picked - 1 do return true
	n := len(cp.points)
	if cp.points[i].selected do return true
	if (cp.closed || i > 0) && cp.points[(i + n - 1) % n].selected do return true
	return (cp.closed || i < n - 1) && cp.points[(i + 1) % n].selected
}

// Turns the picked points (and `at`) into corners, or all back into smooth ones when `at`
// is a corner already.
curve_corners_flip :: proc(cp: ^Curve_Part, at: int) {
	smooth := geom.bezier_is_corner(cp.points[at])
	for p, i in cp.points {
		if i != at && !p.selected do continue
		if smooth do geom.bezier_make_smooth(cp.points[:], cp.closed, i)
		else do geom.bezier_make_corner(cp.points[:], cp.closed, i)
	}
}

// Deletes the picked points of the selected curve (or the last picked), as one undo step,
// when it keeps at least CURVE_MIN_POINTS (three for a closed curve).
curve_delete_point :: proc(app: ^App) {
	obj := selected_curve(app)
	if obj == nil || !curve_point_deletable(app) do return
	before := history_snapshot(app, obj, "delete curve point")
	targets := curve_targets(app, obj.curve)
	#reverse for i in targets do ordered_remove(&obj.curve.points, i)
	app.curve.picked = min(targets[0] + 1, len(obj.curve.points))
	history_record_swap(app, obj.id, before, kind = .Curve)
	app.curve.edits += 1
	curve_changed(app, obj)
}

curve_point_deletable :: proc(app: ^App) -> bool {
	obj := selected_curve(app)
	if obj == nil do return false
	n, gone := len(obj.curve.points), len(curve_targets(app, obj.curve))
	return gone > 0 && n - gone >= (3 if obj.curve.closed else CURVE_MIN_POINTS)
}

// Turns the picked points into corners or back into smooth ones (as the last picked goes),
// as one undo step.
curve_toggle_corner :: proc(app: ^App) {
	obj := selected_curve(app)
	if obj == nil do return
	targets := curve_targets(app, obj.curve)
	if len(targets) == 0 do return
	before := history_snapshot(app, obj, "curve point corner")
	at := app.curve.picked - 1 if app.curve.picked >= 1 && app.curve.picked <= len(obj.curve.points) else targets[0]
	obj.curve.points[at].selected = true
	curve_corners_flip(obj.curve, at)
	history_record_swap(app, obj.id, before, kind = .Curve)
	app.curve.edits += 1
	curve_changed(app, obj)
}

// Sets the picked points' handle type (or the last picked one's), as one undo step.
curve_set_handles :: proc(app: ^App, kind: geom.Handle_Type) {
	obj := selected_curve(app)
	if obj == nil do return
	if len(curve_targets(app, obj.curve)) == 0 do return
	// The snapshot first: it may use the frame's scratch memory the targets live in.
	before := history_snapshot(app, obj, "curve handles")
	for i in curve_targets(app, obj.curve) do geom.bezier_set_handles(obj.curve.points[:], obj.curve.closed, i, kind)
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

// Each handle type's colour, so a point's kind reads at a glance as in Blender: Aligned
// orange (as every handle was), Auto yellow, Vector green, Free red.
@(rodata)
CURVE_HANDLE_COLORS := [geom.Handle_Type][4]f32 {
	.Aligned = {0.95, 0.66, 0.23, 1},
	.Auto    = {0.98, 0.9, 0.3, 1},
	.Vector  = {0.45, 0.85, 0.4, 1},
	.Free    = {0.95, 0.4, 0.4, 1},
}

// Draws the selected curve's editing handles: handles in their type's colour on lines to their point, a
// white radius dot per point, the picked point ringed.
draw_curve_edit :: proc(app: ^App, o: Overlay, size: [2]f32) {
	obj := selected_curve(app)
	if obj == nil do return
	cp := obj.curve
	view_proj := edit_view_proj(app, size)
	white := overlay_color({1, 1, 1, 1})
	dark := overlay_color({0.04, 0.06, 0.08, 0.8})
	blue := overlay_color({0.4, 0.85, 1, 1})
	if cp.use == .Lathe do draw_lathe_axis(app, o, obj, view_proj, size)
	for i in 0 ..< len(cp.points) {
		sc := curve_point_screen(app, obj, view_proj, size, i)
		if !sc.ok do continue
		if cp.points[i].selected do overlay_disc(o, sc.point, 6 * o.scale, white)
		if i == app.curve.picked - 1 do overlay_circle(o, sc.point, 9 * o.scale, blue, 2 * o.scale)
		if !curve_handles_shown(app, cp, i) do continue
		ways := [2]bool{false, true}
		for out in ways {
			if !curve_has_handle(cp, i, out) do continue
			h := sc.h_out if out else sc.h_in
			color := overlay_color(CURVE_HANDLE_COLORS[cp.points[i].handles])
			overlay_line(o, sc.point, h, color, 1 * o.scale)
			overlay_disc(o, h, 5 * o.scale, dark)
			overlay_disc(o, h, 3.5 * o.scale, color)
		}
		overlay_line(o, sc.point, sc.radius, overlay_color({1, 1, 1, 0.35}), 1 * o.scale)
		overlay_disc(o, sc.radius, 5.5 * o.scale, dark)
		overlay_disc(o, sc.radius, 4 * o.scale, white)
	}
	if b := app.curve.box; b.active do overlay_box(o, b.from, b.to, blue, overlay_color({0.4, 0.85, 1, 0.12}), 1 * o.scale)
}

// A lathe's axis as a dashed line over the view, a little longer than the curve reaches
// along it either way.
@(private = "file")
draw_lathe_axis :: proc(app: ^App, o: Overlay, obj: ^Object, view_proj: matrix[4, 4]f32, size: [2]f32) {
	cp := obj.curve
	axis := linalg.normalize0(cp.lathe.axis)
	if axis == {} do return
	origin := geom.lathe_origin(cp.points[:], cp.lathe)
	lo, hi := max(f32), -max(f32)
	for p in cp.points {
		h := linalg.dot(p.p - origin, axis)
		lo, hi = min(lo, h), max(hi, h)
	}
	reach := max(hi - lo, 1e-3)
	lo, hi = lo - 0.15 * reach, hi + 0.15 * reach
	DASHES :: 24
	color := overlay_color({1, 1, 1, 0.7})
	for k in 0 ..< DASHES {
		a := to_world(obj.transform, origin + axis * math.lerp(lo, hi, f32(2 * k) / f32(2 * DASHES)))
		b := to_world(obj.transform, origin + axis * math.lerp(lo, hi, f32(2 * k + 1) / f32(2 * DASHES)))
		sa, ok_a := gizmo.project(view_proj, a, size)
		sb, ok_b := gizmo.project(view_proj, b, size)
		if ok_a && ok_b do overlay_line(o, sa, sb, color, 1.5 * o.scale)
	}
}

// Makes the selected curve's tube or lathe again after an edit, when it makes one. A GPU failure
// leaves the curve with an empty level, drawn as its line, and says so in the log.
curve_changed :: proc(app: ^App, obj: ^Object) {
	if obj.curve == nil do return
	// Auto and Vector points follow the points round them.
	geom.bezier_auto_handles(obj.curve.points[:], obj.curve.closed)
	if obj.curve.use == .None || obj.curve.use == .Guide do return
	if !curve_rebuild(app, obj) do log.errorf("curve: could not make the tube of %s on the GPU", object_label(obj))
}

// The Edit tab's box over empty space: a press starts it, the drag stretches it, and the
// release picks the points inside (Shift: adds them); a tap without a drag picks none.
curve_box_frame :: proc(app: ^App, obj: ^Object, input: Viewport_Input) {
	b := &app.curve.box
	if input.primary {
		if input.press do b^ = {active = true, from = input.mouse_pos, add = input.smooth}
		if b.active do b.to = input.mouse_pos
		return
	}
	if !b.active do return
	defer b^ = {}
	cp := obj.curve
	if !b.add do curve_select_none(cp)
	lo := [2]f32{min(b.from.x, b.to.x), min(b.from.y, b.to.y)}
	hi := [2]f32{max(b.from.x, b.to.x), max(b.from.y, b.to.y)}
	if hi.x - lo.x < CURVE_TAP_PX && hi.y - lo.y < CURVE_TAP_PX do return
	view_proj := edit_view_proj(app, input.size)
	for &p, i in cp.points {
		sc := curve_point_screen(app, obj, view_proj, input.size, i)
		if sc.ok && sc.point.x >= lo.x && sc.point.x <= hi.x && sc.point.y >= lo.y && sc.point.y <= hi.y {
			p.selected = true
			app.curve.picked = i + 1
		}
	}
}

// The Curve tool's own keys while it edits a selected curve, before the bindings: Tab
// switches Draw and Edit (as Blender's Tab into edit mode), and in the Edit tab A picks
// every point or none and Delete or Backspace deletes the picked points. True for a chord
// they take, which the bindings then pass over.
curve_key_taken :: proc(app: ^App, chord: Chord) -> bool {
	if app.tool != .Curve || app.curve.kind != .Curve || selected_curve(app) == nil || chord.mods != {} do return false
	switch chord.key {
	case KEY_TAB:
		return true
	case KEY_A, KEY_DELETE, KEY_BACKSPACE:
		return app.curve.editing
	case KEY_G, KEY_R, KEY_S:
		return curve_gizmo_shown(app)
	case KEY_X, KEY_Y, KEY_Z, KEY_RETURN, KEY_KP_ENTER, KEY_ESCAPE:
		return app.curve.xform.keys
	}
	return false
}

curve_keys :: proc(app: ^App) {
	d := &app.device
	if !curve_key_taken(app, {key = KEY_TAB}) do return
	if chord_down(d, {key = KEY_TAB}) do app.curve.editing = !app.curve.editing
	if !app.curve.editing do return
	// G, R and S move, turn and scale the picked points with the pointer; X, Y and Z keep
	// it to an axis; Enter keeps it and Escape puts the points back.
	if chord_down(d, {key = KEY_G}) do curve_xform_key(app, .View)
	if chord_down(d, {key = KEY_R}) do curve_xform_key(app, .Turn_View)
	if chord_down(d, {key = KEY_S}) do curve_xform_key(app, .Scale)
	if app.curve.xform.keys {
		for k, i in ([3]Key{KEY_X, KEY_Y, KEY_Z}) do if chord_down(d, {key = k}) do curve_xform_axis(app, i)
		if chord_down(d, {key = KEY_RETURN}) || chord_down(d, {key = KEY_KP_ENTER}) do curve_xform_end(app)
		if chord_down(d, {key = KEY_ESCAPE}) do curve_xform_cancel(app)
		return
	}
	if chord_down(d, {key = KEY_A}) do curve_select_all(app)
	if chord_down(d, {key = KEY_DELETE}) || chord_down(d, {key = KEY_BACKSPACE}) do curve_delete_point(app)
}
