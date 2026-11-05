package main

import "core:fmt"
import "core:math"
import "core:math/linalg"

import "../camera"
import "../gizmo"

// A move, turn or scale of a set of points by the Move tool's gizmo (its mode, Move, Turn,
// Scale or All, and its orientation) standing at their middle, as Blender's edit mode
// moves vertices: the picked points of a curve (curve_gizmo.odin) and the selection of a
// cage (model_gizmo.odin) share it, so both drag, step and read out alike. G, R and S start
// one that follows the pointer with no button held, X, Y or Z keeping it to an axis. Snap
// (or Ctrl) steps it as it steps an object. The owner keeps the points as they were and
// maps them through what point_xform_map returns each frame.
//
// The handle held (for a key's, the handle it stands for: G the middle, R the view ring, S
// the even scale, and with X, Y or Z the arm, ring or knob of that axis) and what the drag
// has done so far.
Point_Xform :: struct {
	handle:       gizmo.Handle,
	keys:         bool, // started by G, R or S: follows the pointer until a press, Enter or Escape
	live:         bool, // set up from the pointer's place (a gizmo drag goes live past the slop)
	down:         [2]f32, // where the press (or the key) was
	center:       [2]f32, // the pivot on screen
	arm_px:       f32,
	knob:         [2]f32, // a stretch's knob on screen, which way it stretches
	pivot:        Vec3, // the points' middle, in the world
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

// Sets the drag up from the pointer at `at` for points whose middle is `pivot`, with the
// gizmo `sc` standing there along `axes`. False when the handle cannot be dragged from this
// view (an arm seen end on, a plane edge on) or the gizmo is not shown.
point_xform_go_live :: proc(app: ^App, x: ^Point_Xform, screen: gizmo.Screen, pivot: Vec3, axes: [3]Vec3, at, size: [2]f32) -> bool {
	x.live = true
	sc := screen
	if !sc.ok do return false
	x.center, x.arm_px = sc.center, sc.arm_px
	x.pivot = pivot
	x.axes = axes
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

// What the drag does with the pointer at `at`, as a map of the world: about the pivot by
// `m`, then along `move`. Not ok when the pointer gives no place this frame (a ray along
// the plane), when the points stay as they last were.
point_xform_map :: proc(app: ^App, x: ^Point_Xform, at, size: [2]f32) -> (m: matrix[3, 3]f32, move: Vec3, ok: bool) {
	x.snapped = app.move.snap || app.device.ctrl
	was_amount, was_offset := x.amount, x.offset
	defer if x.snapped && (x.amount != was_amount || x.offset != was_offset) do haptic(app, .Alignment)
	origin, dir := mouse_ray(app.camera, at, size)
	m = matrix[3, 3]f32{1, 0, 0, 0, 1, 0, 0, 0, 1}
	#partial switch x.handle {
	case .X, .Y, .Z:
		axis := x.axes[int(x.handle) - int(gizmo.Handle.X)]
		s := gizmo.closest_on_axis(x.pivot, axis, origin, dir) or_return
		x.amount = s - x.axis_start
		if x.snapped do x.amount = gizmo.snap(x.amount, x.step)
		move = axis * x.amount
	case .View, .YZ, .XZ, .XY:
		hit := gizmo.ray_plane(origin, dir, x.grab, x.plane_normal) or_return
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
		} else if hit, hit_ok := gizmo.ray_plane(origin, dir, x.pivot, x.axis); hit_ok {
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
		m = point_xform_scale_matrix(x.axes[i] if i >= 0 else {}, f, i >= 0)
	case:
		return
	}
	return m, move, true
}

// A scale by `f`: along `axis` alone when `along` (I + (f - 1) a aᵀ, unchanged across it),
// else evenly.
point_xform_scale_matrix :: proc(axis: Vec3, f: f32, along: bool) -> matrix[3, 3]f32 {
	if !along do return matrix[3, 3]f32{f, 0, 0, 0, f, 0, 0, 0, f}
	a := axis
	k := f - 1
	return matrix[3, 3]f32{
		1 + k * a.x * a.x, k * a.x * a.y, k * a.x * a.z,
		k * a.y * a.x, 1 + k * a.y * a.y, k * a.y * a.z,
		k * a.z * a.x, k * a.z * a.y, 1 + k * a.z * a.z,
	}
}

// X, Y or Z during a key's drag: keeps it to that axis of the gizmo, or frees it again when
// it already is (as Blender's second X). The owner puts its points back first, so the axis
// applies to the whole drag.
point_xform_axis :: proc(x: ^Point_Xform, i: int) {
	mode := drag_mode(x.handle)
	base: gizmo.Handle = .X if mode == .Move else .Turn_X if mode == .Turn else .Scale_X
	free: gizmo.Handle = .View if mode == .Move else .Turn_View if mode == .Turn else .Scale
	want := gizmo.Handle(int(base) + i)
	if x.handle == want do want = free
	x.handle, x.live = want, false
	x.turned, x.amount, x.offset = 0, 0, {}
}

// What the drag under way has done, for the label by the pointer: "X +0.250",
// "Turn Z 45°", "Scale ×1.30".
point_xform_readout :: proc(x: ^Point_Xform) -> string {
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

// The gizmo `sc` over the points, the handle held or `hover` lit (none while a key's drag
// goes, which has no handle to show), and what the drag has done by the pointer.
draw_point_xform :: proc(app: ^App, o: Overlay, input: Viewport_Input, x: ^Point_Xform, sc: gizmo.Screen, hover: gizmo.Handle) {
	px := gizmo_scale(app)
	if !x.keys {
		if !sc.ok do return
		active := x.handle if x.handle != .None else hover
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
	if text := point_xform_readout(x); text != "" do overlay_label(o, text, input.mouse_pos + [2]f32{0, -40 * px})
}
