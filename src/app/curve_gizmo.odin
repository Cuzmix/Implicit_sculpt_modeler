package main

import "core:fmt"
import "core:math"
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

// A move, turn or scale of the picked points under way: the handle held (for a key's, the
// handle it stands for: G the middle, R the view ring, S the even scale, and with X, Y or
// Z the arm, ring or knob of that axis), the points as they were, and what the drag has
// done so far.
Curve_Xform :: struct {
	handle:       gizmo.Handle,
	keys:         bool, // started by G, R or S: follows the pointer until a press, Enter or Escape
	live:         bool, // set up from the pointer's place (a gizmo drag goes live past the slop)
	id:           int,
	before:       ^Object_Snapshot,
	start:        [dynamic]geom.Bezier_Point,
	down:         [2]f32, // where the press (or the key) was
	center:       [2]f32, // the pivot on screen
	arm_px:       f32,
	knob:         [2]f32, // a stretch's knob on screen, which way it stretches
	pivot:        Vec3, // the middle of the picked points, in the world
	axes:         [3]Vec3,
	step:         f32, // the snap grid's step at the pivot's zoom
	axis_start:   f32,
	grab:         Vec3,
	plane_normal: Vec3,
	axis:         Vec3,
	turn_from:    Vec3,
	turned:       f32, // radians
	edge:         bool, // a ring seen edge on turns by the drag along it on screen
	tangent:      [2]f32,
	amount:       f32, // the axis move, the degrees turned or the scale factor
	offset:       Vec3, // a plane or view move
	snapped:      bool,
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
	start := x.start
	clear(&start)
	x^ = {start = start}
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
	x := &app.curve.xform
	x.live = true
	sc := curve_gizmo_screen(app, size)
	if !sc.ok do return false
	x.center, x.arm_px = sc.center, sc.arm_px
	x.pivot, _ = curve_picked_middle(obj)
	x.axes = curve_gizmo_axes(app, obj)
	x.step = gizmo.grid_step(camera.orbit_world_per_px(app.camera, x.pivot, size.y) * gizmo_scale(app))
	x.amount = 1 if drag_mode(x.handle) == .Scale else 0
	origin, dir := mouse_ray(app.camera, at, size)
	toward := -camera.orbit_toward(app.camera, x.pivot)
	switch x.handle {
	case .None:
		return false
	case .X, .Y, .Z:
		x.axis_start = gizmo.closest_on_axis(x.pivot, x.axes[int(x.handle) - int(gizmo.Handle.X)], origin, dir) or_return
	case .View, .YZ, .XZ, .XY:
		x.plane_normal = -camera.orbit_toward(app.camera, app.camera.target) if x.handle == .View else x.axes[int(x.handle) - int(gizmo.Handle.YZ)]
		x.grab = gizmo.ray_plane(origin, dir, x.pivot, x.plane_normal) or_return
	case .Turn_X, .Turn_Y, .Turn_Z, .Turn_View:
		i := int(x.handle) - int(gizmo.Handle.Turn_X)
		x.axis = x.axes[i] if i < 3 else toward
		if x.keys {
			// A key's turn follows the pointer round the middle on screen, as Blender's R
			// does, about the axis turned to face the eye so the points turn the way the
			// pointer goes.
			if linalg.dot(x.axis, toward) < 0 do x.axis = -x.axis
			return true
		}
		hit, ok := gizmo.ray_plane(origin, dir, x.pivot, x.axis)
		x.edge = !ok || abs(linalg.dot(dir, x.axis)) < 0.2
		x.turn_from = hit
		if x.edge do x.tangent = gizmo.ring_tangent(sc.rings[i][:], at)
	case .Scale:
	case .Scale_X, .Scale_Y, .Scale_Z:
		x.knob = sc.knobs[gizmo.stretch_axis(x.handle)]
		if x.keys {
			// The knob's place, which a key's stretch has no gizmo of Scale mode for: along
			// the arm on screen.
			tip, _ := gizmo.project(edit_view_proj(app, size), x.pivot + x.axes[gizmo.stretch_axis(x.handle)] * (sc.arm_px * camera.orbit_world_per_px(app.camera, x.pivot, size.y)), size)
			x.knob = tip
		}
	}
	return true
}

// Moves the picked points to follow the pointer at `at`, from where they began.
@(private = "file")
curve_xform_to :: proc(app: ^App, obj: ^Object, at, size: [2]f32) {
	x := &app.curve.xform
	x.snapped = app.move.snap || app.device.ctrl
	was_amount, was_offset := x.amount, x.offset
	defer if x.snapped && (x.amount != was_amount || x.offset != was_offset) do haptic(app, .Alignment)
	origin, dir := mouse_ray(app.camera, at, size)
	// The change as a map of the world: about the pivot by `m`, then along `move`.
	m := matrix[3, 3]f32{1, 0, 0, 0, 1, 0, 0, 0, 1}
	move: Vec3
	#partial switch x.handle {
	case .X, .Y, .Z:
		axis := x.axes[int(x.handle) - int(gizmo.Handle.X)]
		s, ok := gizmo.closest_on_axis(x.pivot, axis, origin, dir)
		if !ok do return
		x.amount = s - x.axis_start
		if x.snapped do x.amount = gizmo.snap(x.amount, x.step)
		move = axis * x.amount
	case .View, .YZ, .XZ, .XY:
		hit, ok := gizmo.ray_plane(origin, dir, x.grab, x.plane_normal)
		if !ok do return
		delta := hit - x.grab
		if x.handle != .View {
			// Along the plane's two arms, exactly in the plane whatever the rounding.
			c: Vec3
			for k in 0 ..< 3 do c[k] = linalg.dot(delta, x.axes[k])
			c[int(x.handle) - int(gizmo.Handle.YZ)] = 0
			if x.snapped do for &d in c do d = gizmo.snap(d, x.step)
			delta = x.axes[0] * c.x + x.axes[1] * c.y + x.axes[2] * c.z
		} else if x.snapped {
			for &d in delta do d = gizmo.snap(d, x.step)
		}
		x.offset = delta
		move = delta
	case .Turn_X, .Turn_Y, .Turn_Z, .Turn_View:
		if x.keys {
			a, b := x.down - x.center, at - x.center
			if linalg.length(a) < 1 || linalg.length(b) < 1 do return
			// Screen y runs down, so the angle on screen turns the other way to the axis.
			x.turned = -(math.atan2(b.y, b.x) - math.atan2(a.y, a.x))
		} else if x.edge {
			x.turned = gizmo.tangent_turn(at - x.down, x.tangent)
		} else if hit, ok := gizmo.ray_plane(origin, dir, x.pivot, x.axis); ok {
			x.turned += gizmo.plane_turn(x.pivot, x.axis, x.turn_from, hit)
			x.turn_from = hit
		}
		degrees := gizmo.wrap_degrees(linalg.to_degrees(x.turned)) if x.keys else linalg.to_degrees(x.turned)
		if x.snapped do degrees = gizmo.snap(degrees, gizmo.TURN_SNAP_DEGREES)
		x.amount = degrees
		m = linalg.matrix3_rotate_f32(linalg.to_radians(degrees), linalg.normalize(x.axis))
	case .Scale, .Scale_X, .Scale_Y, .Scale_Z:
		f: f32
		i := gizmo.stretch_axis(x.handle)
		if x.keys {
			// As Blender's S: the pointer's distance from the middle over the key's.
			from := max(linalg.length(x.down - x.center), 1)
			f = linalg.length(at - x.center) / from
		} else if i >= 0 {
			f = gizmo.stretch_factor(x.center, x.knob, x.down, at, x.arm_px)
		} else {
			f = gizmo.scale_factor(x.center, x.down, at, x.arm_px)
		}
		if x.snapped do f = gizmo.snap(f, gizmo.SCALE_SNAP)
		x.amount = f
		if i >= 0 {
			a := x.axes[i]
			// I + (f - 1) a aᵀ: stretched along the arm, unchanged across it.
			k := f - 1
			m = matrix[3, 3]f32{
				1 + k * a.x * a.x, k * a.x * a.y, k * a.x * a.z,
				k * a.y * a.x, 1 + k * a.y * a.y, k * a.y * a.z,
				k * a.z * a.x, k * a.z * a.y, 1 + k * a.z * a.z,
			}
		} else {
			m = matrix[3, 3]f32{f, 0, 0, 0, f, 0, 0, 0, f}
		}
	case:
		return
	}
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
	mode := drag_mode(x.handle)
	base: gizmo.Handle = .X if mode == .Move else .Turn_X if mode == .Turn else .Scale_X
	free: gizmo.Handle = .View if mode == .Move else .Turn_View if mode == .Turn else .Scale
	want := gizmo.Handle(int(base) + i)
	if x.handle == want do want = free
	// Begins again from the points as they were, so the axis applies to the whole move.
	obj := object_by_id(app, x.id)
	if obj != nil && obj.curve != nil && len(obj.curve.points) == len(x.start) do copy(obj.curve.points[:], x.start[:])
	x.handle, x.live = want, false
	x.turned, x.amount, x.offset = 0, 0, {}
}

// What the move under way has done, for the label by the pointer: "X +0.250",
// "Turn Z 45°", "Scale ×1.30".
curve_xform_readout :: proc(app: ^App) -> string {
	x := app.curve.xform
	if x.handle == .None || !x.live do return ""
	switch drag_mode(x.handle) {
	case .Move:
		if x.handle >= .X && x.handle <= .Z do return fmt.tprintf("%v %+.3f", x.handle, x.amount)
		return fmt.tprintf("Move %+.3f, %+.3f, %+.3f", x.offset.x, x.offset.y, x.offset.z)
	case .Turn:
		names := [4]string{"X", "Y", "Z", "view"}
		return fmt.tprintf("Turn %s %+.1f°", names[int(x.handle) - int(gizmo.Handle.Turn_X)], x.amount)
	case .Scale, .All:
		names := [3]string{"X", "Y", "Z"}
		if i := gizmo.stretch_axis(x.handle); i >= 0 do return fmt.tprintf("Scale %s ×%.2f", names[i], x.amount)
		return fmt.tprintf("Scale ×%.2f", x.amount)
	}
	return ""
}

// The picked points' gizmo over the curve, the handle held or under the pointer lit (none
// while a key's move goes, which has no handle to show), and what the move has done by the
// pointer.
draw_curve_gizmo :: proc(app: ^App, o: Overlay, input: Viewport_Input) {
	x := app.curve.xform
	px := gizmo_scale(app)
	if !x.keys {
		sc := curve_gizmo_screen(app, input.size)
		if !sc.ok do return
		active := x.handle
		if active == .None && input.hovered do active = curve_gizmo_pick(app, input.mouse_pos, input.size)
		turning := x.live && drag_mode(x.handle) == .Turn
		scaling := x.live && x.handle == .Scale
		draw_gizmo_shape(o, sc, app.move.mode, active, px, true, turning, scaling, x.center, input.mouse_pos)
	} else if x.live {
		// A key's turn or scale draws the line or circle it follows from the middle.
		#partial switch drag_mode(x.handle) {
		case .Turn:
			overlay_line(o, x.center, input.mouse_pos, overlay_color(GIZMO_HIGHLIGHT), 1.5 * px)
		case .Scale:
			overlay_circle(o, x.center, linalg.length(input.mouse_pos - x.center), overlay_color({1, 0.85, 0.3, 0.6}), 1.5 * px)
		}
	}
	if text := curve_xform_readout(app); text != "" do overlay_label(o, text, input.mouse_pos + [2]f32{0, -40 * px})
}
