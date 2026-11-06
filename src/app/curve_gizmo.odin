package main

import "core:math/linalg"

import "../camera"
import "../geom"
import "../gizmo"

// Moving, turning and scaling the picked points of a curve in the Curve tool's Edit tab,
// as Blender's edit mode does: the Move tool's gizmo (its mode, Move, Turn, Scale or All,
// and its orientation) stands at the middle of the picked points, and G, R and S start a
// move, turn or scale that follows the pointer with no button held, X, Y or Z keeping it to
// an axis, a press or Enter keeping it and Escape putting the points back. Snap (or Ctrl)
// steps it as it steps an object. Each is one undo step of the curve.

// A move, turn or scale of the picked points under way: the shared gizmo drag
// (point_xform.odin), the curve it is on, its undo snapshot and the points as they were.
Curve_Xform :: struct {
	using core: Point_Xform,
	id:         int,
	before:     ^Object_Snapshot,
	start:      [dynamic]geom.Bezier_Point,
	picked:     [dynamic]u32, // the picked points' numbers, which a snap passes over
}

// The picked points' middle in the world, with how many are picked.
curve_picked_middle :: proc(obj: ^Object) -> (mid: Vec3, n: int) {
	for p in obj.curve.points do if p.selected {
		mid += to_world(obj.transform, p.p)
		n += 1
	}
	if n > 0 do mid /= f32(n)
	return
}

// Whether the selected curve shows the gizmo on its picked points: the Edit tab with at
// least one point picked and nothing being drawn.
curve_gizmo_shown :: proc(app: ^App) -> bool {
	c := &app.curve
	if app.tool != .Curve || c.kind != .Curve || !c.editing || c.active || len(c.placing) > 0 do return false
	obj := selected_curve(app)
	return obj != nil && curve_selected_count(obj.curve) > 0
}

// The gizmo's arms in the Move tool's orientation: the world's, the curve object's, or the
// view's (Surface, which has no surface to stand on here, takes the object's).
curve_gizmo_axes :: proc(app: ^App, obj: ^Object) -> [3]Vec3 {
	switch app.move.orient {
	case .World:
	case .Object, .Surface:
		t := obj.transform
		return {linalg.normalize0(to_world_dir(t, {1, 0, 0})), linalg.normalize0(to_world_dir(t, {0, 1, 0})), linalg.normalize0(to_world_dir(t, {0, 0, 1}))}
	case .View:
		right, up, back := camera.orbit_basis(app.camera)
		return {right, up, back}
	}
	return gizmo.AXES
}

// The picked points' gizmo as it appears on screen; not ok when it is not shown. During a
// move it stands where the points have gone.
curve_gizmo_screen :: proc(app: ^App, size: [2]f32) -> (s: gizmo.Screen) {
	if !curve_gizmo_shown(app) || size.x <= 0 || size.y <= 0 do return
	obj := selected_curve(app)
	center, _ := curve_picked_middle(obj)
	arm_px := gizmo.ARM_PX * gizmo_scale(app)
	arm := arm_px * camera.orbit_world_per_px(app.camera, center, size.y)
	return gizmo.screen(edit_view_proj(app, size), center, arm, -camera.orbit_toward(app.camera, center), size, arm_px, app.move.mode, curve_gizmo_axes(app, obj))
}

// The gizmo's handle under `at`; none over a point, which its own press takes (a single
// picked point sits right under the gizmo's middle).
curve_gizmo_pick :: proc(app: ^App, at, size: [2]f32) -> gizmo.Handle {
	sc := curve_gizmo_screen(app, size)
	if !sc.ok do return .None
	if hit := curve_hit(app, selected_curve(app), size, at); hit.handle == .Point do return .None
	return gizmo.pick(sc, app.move.mode, at, gizmo_radius(app))
}

// Starts a move, turn or scale of the selected curve's picked points by `handle`, from the
// pointer at `at`; `keys` for one G, R or S started.
@(private = "file")
curve_xform_begin :: proc(app: ^App, handle: gizmo.Handle, at: [2]f32, keys: bool) {
	obj := selected_curve(app)
	x := &app.curve.xform
	curve_xform_drop(app)
	x.handle, x.keys, x.down, x.id = handle, keys, at, obj.id
	x.before = history_snapshot(app, obj, "move points")
	append(&x.start, ..obj.curve.points[:])
}

// Lets the move go without an undo step, the points as they are.
curve_xform_drop :: proc(app: ^App) {
	x := &app.curve.xform
	if x.before != nil do history_snapshot_drop(x.before)
	start, picked := x.start, x.picked
	clear(&start)
	clear(&picked)
	x^ = {start = start, picked = picked}
}

// Puts the points back where the move began and ends it with nothing recorded.
curve_xform_cancel :: proc(app: ^App) {
	x := &app.curve.xform
	if obj := object_by_id(app, x.id); obj != nil && obj.curve != nil && len(obj.curve.points) == len(x.start) {
		copy(obj.curve.points[:], x.start[:])
		curve_changed(app, obj)
	}
	curve_xform_drop(app)
}

// Ends the move: one undo step of the curve when a point moved.
curve_xform_end :: proc(app: ^App) {
	x := &app.curve.xform
	obj := object_by_id(app, x.id)
	if obj == nil || obj.curve == nil || x.before == nil {
		curve_xform_drop(app)
		return
	}
	changed := len(obj.curve.points) != len(x.start)
	if !changed do for p, i in obj.curve.points do if p != x.start[i] {
		changed = true
		break
	}
	if !changed {
		curve_xform_drop(app)
		return
	}
	history_record_swap(app, obj.id, x.before, kind = .Curve)
	x.before = nil
	app.curve.edits += 1
	curve_xform_drop(app)
}

// Sets the move up from the pointer at `at`. False when the handle cannot be dragged from
// this view (an arm seen end on, a plane edge on).
@(private = "file")
curve_xform_go_live :: proc(app: ^App, obj: ^Object, at, size: [2]f32) -> bool {
	sc := curve_gizmo_screen(app, size)
	pivot, _ := curve_picked_middle(obj)
	x := &app.curve.xform
	// A snap lands on anything but the picked points.
	clear(&x.picked)
	for p, i in obj.curve.points do if p.selected do append(&x.picked, u32(i))
	x.skip = {id = obj.id, points = x.picked[:]}
	return point_xform_go_live(app, &x.core, sc, pivot, curve_gizmo_axes(app, obj), at, size)
}

// Moves the picked points to follow the pointer at `at`, from where they began.
@(private = "file")
curve_xform_to :: proc(app: ^App, obj: ^Object, at, size: [2]f32) {
	x := &app.curve.xform
	m, move, ok := point_xform_map(app, &x.core, at, size)
	if !ok do return
	curve_points_map(obj, x.start[:], x.pivot, m, move)
	curve_changed(app, obj)
}

// Sets each picked point of `obj` (and its handles) to where `start`'s was, mapped through
// the world: about `pivot` by `m`, then along `move`. Handles are mapped as the places they
// reach, so they turn and scale with their points; a point's radius stays.
curve_points_map :: proc(obj: ^Object, start: []geom.Bezier_Point, pivot: Vec3, m: matrix[3, 3]f32, move: Vec3) {
	t := obj.transform
	f :: proc(t: Transform, local, pivot: Vec3, m: matrix[3, 3]f32, move: Vec3) -> Vec3 {
		return to_local(t, pivot + m * (to_world(t, local) - pivot) + move)
	}
	for &p, i in obj.curve.points {
		if i >= len(start) do break
		s := start[i]
		if !s.selected do continue
		p.p = f(t, s.p, pivot, m, move)
		p.h_in = f(t, s.p + s.h_in, pivot, m, move) - p.p
		p.h_out = f(t, s.p + s.h_out, pivot, m, move) - p.p
	}
}

// A press, drag or release on the picked points' gizmo, or a key's move under way, in the
// Curve tool. True while it is theirs, so nothing else takes the press.
curve_xform_frame :: proc(app: ^App, input: Viewport_Input) -> bool {
	x := &app.curve.xform
	if x.handle == .None {
		if !input.press || !input.primary do return false
		h := curve_gizmo_pick(app, input.mouse_pos, input.size)
		if h == .None do return false
		curve_xform_begin(app, h, input.mouse_pos, false)
		return true
	}
	obj := object_by_id(app, x.id)
	if obj == nil || obj.curve == nil || len(obj.curve.points) != len(x.start) {
		curve_xform_drop(app)
		return false
	}
	// Escape puts the points back mid-drag, as it puts an object back.
	if !x.keys && key_pressed(&app.device, KEY_ESCAPE) {
		curve_xform_cancel(app)
		return true
	}
	if x.keys {
		// A press keeps the move; the press is the move's alone, not a new pick or curve.
		if input.press && input.primary {
			curve_xform_end(app)
			return true
		}
		if !x.live && !curve_xform_go_live(app, obj, x.down, input.size) {
			curve_xform_cancel(app)
			return true
		}
		curve_xform_to(app, obj, input.mouse_pos, input.size)
		return input.primary
	}
	if !input.primary {
		curve_xform_end(app)
		return true
	}
	slop := app.kit.ctx.theme.slop * gizmo_scale(app)
	if !x.live {
		if linalg.length(input.mouse_pos - x.down) <= slop do return true
		if !curve_xform_go_live(app, obj, input.mouse_pos, input.size) {
			curve_xform_drop(app)
			return true
		}
		// From the pointer's place now, so nothing jumps by the slop.
		x.down = input.mouse_pos
		return true
	}
	curve_xform_to(app, obj, input.mouse_pos, input.size)
	return true
}

// Starts G (move in the view, `.View`), R (turn about the view, `.Turn_View`) or S (scale,
// `.Scale`) on the picked points from the pointer's place, as Blender's keys do.
curve_xform_key :: proc(app: ^App, handle: gizmo.Handle) {
	if !curve_gizmo_shown(app) do return
	if app.curve.xform.handle != .None && !app.curve.xform.keys do return
	if app.curve.xform.keys do curve_xform_cancel(app)
	curve_xform_begin(app, handle, app.curve.pointer, true)
}

// X, Y or Z during a key's move: keeps it to that axis of the gizmo, or frees it again when
// it already is (as Blender's second X).
curve_xform_axis :: proc(app: ^App, i: int) {
	x := &app.curve.xform
	if !x.keys do return
	// Begins again from the points as they were, so the axis applies to the whole move.
	obj := object_by_id(app, x.id)
	if obj != nil && obj.curve != nil && len(obj.curve.points) == len(x.start) do copy(obj.curve.points[:], x.start[:])
	point_xform_axis(&x.core, i)
}

// The picked points' gizmo over the curve, the handle held or under the pointer lit (none
// while a key's move goes, which has no handle to show), and what the move has done by the
// pointer.
draw_curve_gizmo :: proc(app: ^App, o: Overlay, input: Viewport_Input) {
	x := &app.curve.xform
	sc := curve_gizmo_screen(app, input.size)
	hover := gizmo.Handle.None
	if x.handle == .None && input.hovered do hover = curve_gizmo_pick(app, input.mouse_pos, input.size)
	draw_point_xform(app, o, input, &x.core, sc, hover)
}
