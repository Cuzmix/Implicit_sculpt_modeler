package main

import "core:fmt"
import "core:math/linalg"
import sdl "vendor:sdl3"

import "../camera"
import "../gizmo"

// The tool the left mouse button drives in the viewport.
Tool :: enum u8 {
	Move, // select objects by clicking them; move them with the gizmo or by dragging
	Brush, // sculpt the object under the cursor
	Curve, // draw a tube, stitches or a zipper over the surface (curve_tool.odin)
	Insert, // put a shape on the surface (curve_tool.odin)
}

Move_Tool :: struct {
	hover: gizmo.Handle, // handle under the cursor while no drag is active
	drag:  Move_Drag,
	mode:  gizmo.Mode, // what the handles do: move, turn or scale (remembered)
	snap:  bool, // the Snap latch: every drag snaps, as Ctrl makes one drag (remembered)
	// The drags that changed an object, and the handle of the last, for the exit stats.
	drags: int,
	last:  gizmo.Handle,
	drawn: [2]f32, // where the gizmo's centre was drawn last, for the scripted scenarios
}

// A drag in progress, of the gizmo or of an object's body. handle is None when there is
// none. It is set up when it goes live: at once for the mouse, and for a finger or a pen
// once it moves past the slop, so a tap never nudges the object.
Move_Drag :: struct {
	handle:       gizmo.Handle,
	id:           int, // the object dragged
	start:        Transform, // the object as it was when the drag began
	live:         bool,
	press:        [2]f32, // the pointer when it went live
	center:       [2]f32, // the gizmo's centre on screen then
	arm_px:       f32, // ...and its arms' length
	pivot:        Vec3, // what turns and scales go about
	step:         f32, // the move grid's step, fixed for the drag
	axis_start:   f32, // .X/.Y/.Z: where along the axis the drag began
	grab:         Vec3, // a move across a plane: the point on it under the pointer when live
	plane_normal: Vec3, // ...and the plane's normal
	axis:         Vec3, // a turn: the axis
	turn_from:    Vec3, // ...where the pointer met the ring's plane last frame
	edge:         bool, // ...seen edge on, the drag along the ring on screen turns it
	tangent:      [2]f32, // ...in pixels a radian
	turned:       f32, // ...the turn so far in radians, unwrapped
	amount:       f32, // what the readout shows: the move along an axis, degrees or the factor
	snapped:      bool, // this frame's change snapped
}

// What the drag does, for the undo button and the History panel.
@(rodata)
MOVE_WHAT := [gizmo.Mode]string {
	.Move  = "Move",
	.Turn  = "Turn",
	.Scale = "Scale",
}

// The colours of the x, y and z handles, and of the one under the pointer or dragged.
GIZMO_AXIS_COLORS :: [3][4]f32{{0.95, 0.3, 0.3, 1}, {0.4, 0.85, 0.35, 1}, {0.35, 0.55, 1, 1}}
GIZMO_HIGHLIGHT :: [4]f32{1, 0.85, 0.3, 1}

// Where the gizmo sits on the object: its origin.
gizmo_center :: proc(app: ^App, obj: ^Object) -> Vec3 {
	return obj.transform.position
}

// How many window pixels a point is, for the gizmo's sizes.
gizmo_scale :: proc(app: ^App) -> f32 {
	return app.kit.scale if app.kit.scale > 0 else 1
}

// How near a handle the pointer picks it: a mouse or a pen within PICK_PX, a finger
// within half a touch target, so handles are finger-sized without being drawn larger.
gizmo_radius :: proc(app: ^App) -> f32 {
	r: f32 = gizmo.PICK_PX
	if app.device.pointer == .Finger do r = max(r, 0.5 * app.kit.ctx.theme.target)
	return r * gizmo_scale(app)
}

// The selected object's gizmo as it appears on screen, in viewport-local points.
gizmo_screen :: proc(app: ^App, size: [2]f32) -> (s: gizmo.Screen) {
	obj := selected_object(app)
	if obj == nil || size.x <= 0 || size.y <= 0 do return
	view_proj := camera.orbit_proj(app.camera, size.x / size.y) * camera.orbit_view(app.camera)
	center := gizmo_center(app, obj)
	arm_px := gizmo.ARM_PX * gizmo_scale(app)
	arm := arm_px * camera.orbit_world_per_px(app.camera, center, size.y)
	return gizmo.screen(view_proj, center, arm, -camera.orbit_toward(app.camera, center), size, arm_px)
}

// The handle under `at`, for the pointer in use.
gizmo_pick :: proc(app: ^App, at, size: [2]f32) -> gizmo.Handle {
	if selected_object(app) == nil do return .None
	return gizmo.pick(gizmo_screen(app, size), app.move.mode, at, gizmo_radius(app))
}

// Turns this frame's viewport input into selection changes and object moves, turns and
// scales.
move_tool_frame :: proc(app: ^App, input: Viewport_Input) {
	m := &app.move
	if !input.primary {
		move_end(app)
		m.hover = .None
		if input.hovered do m.hover = gizmo_pick(app, input.mouse_pos, input.size)
		return
	}

	if input.press {
		// A drag still open (its release never seen) ends as it is.
		move_end(app)
		m.hover = .None
		handle := gizmo_pick(app, input.mouse_pos, input.size)
		grab: Vec3
		if handle == .None {
			// Not on the gizmo: a press selects what is under the pointer, and dragging moves
			// it in the view plane, whatever the gizmo's mode.
			origin, dir := mouse_ray(app.camera, input.mouse_pos, input.size)
			index, hit, ok := scene_raycast(app, origin, dir)
			if !ok {
				app.scene.selected = -1
				return
			}
			app.scene.selected = index
			handle, grab = .View, hit
		} else {
			grab = gizmo_center(app, selected_object(app))
		}
		obj := selected_object(app)
		m.drag = {handle = handle, id = obj.id, start = obj.transform, grab = grab}
	}

	drag := &m.drag
	obj := object_by_id(app, drag.id)
	if drag.handle == .None || obj == nil do return
	// Escape puts the object back and ends the drag; the rest of the press does nothing.
	if key_pressed(&app.device, sdl.K_ESCAPE) {
		move_cancel(app)
		return
	}
	if !drag.live {
		if !app.drag.moving do return
		if !move_go_live(app, obj, input) do drag^ = {}
		return
	}
	drag.snapped = m.snap || app.device.ctrl
	t := drag.start
	origin, dir := mouse_ray(app.camera, input.mouse_pos, input.size)
	#partial switch drag.handle {
	case .X, .Y, .Z:
		axis := gizmo.AXES[int(drag.handle) - int(gizmo.Handle.X)]
		s, ok := gizmo.closest_on_axis(drag.start.position, axis, origin, dir)
		if !ok do return
		drag.amount = s - drag.axis_start
		if drag.snapped do drag.amount = gizmo.snap(drag.amount, drag.step)
		t.position += axis * drag.amount
	case .View, .YZ, .XZ, .XY:
		hit, ok := gizmo.ray_plane(origin, dir, drag.grab, drag.plane_normal)
		if !ok do return
		delta := hit - drag.grab
		if drag.handle != .View {
			// Exactly in the plane, whatever the rounding.
			delta[int(drag.handle) - int(gizmo.Handle.YZ)] = 0
		}
		if drag.snapped do for &d in delta do d = gizmo.snap(d, drag.step)
		t.position += delta
	case .Turn_X, .Turn_Y, .Turn_Z, .Turn_View:
		if drag.edge {
			drag.turned = gizmo.tangent_turn(input.mouse_pos - drag.press, drag.tangent)
		} else if hit, ok := gizmo.ray_plane(origin, dir, drag.pivot, drag.axis); ok {
			drag.turned += gizmo.plane_turn(drag.pivot, drag.axis, drag.turn_from, hit)
			drag.turn_from = hit
		}
		degrees := linalg.to_degrees(drag.turned)
		if drag.snapped do degrees = gizmo.snap(degrees, gizmo.TURN_SNAP_DEGREES)
		drag.amount = degrees
		// Turned about the world's axis: the turn comes before the object's own.
		if degrees != 0 {
			r := linalg.matrix3_rotate_f32(linalg.to_radians(degrees), drag.axis)
			turned := gizmo.rotation_degrees(r * gizmo.rotation_matrix(drag.start.rotation))
			for i in 0 ..< 3 do t.rotation[i] = gizmo.wrap_degrees(turned[i])
			t.position = drag.pivot + r * (drag.start.position - drag.pivot)
		}
	case .Scale:
		f := gizmo.scale_factor(drag.center, drag.press, input.mouse_pos, drag.arm_px)
		if drag.snapped do f = max(gizmo.snap(f, gizmo.SCALE_SNAP), gizmo.SCALE_SNAP)
		t.scale = clamp(drag.start.scale * f, MIN_OBJECT_SCALE, MAX_OBJECT_SCALE)
		f = t.scale / drag.start.scale
		drag.amount = f
		t.position = drag.pivot + (drag.start.position - drag.pivot) * f
	}
	obj.transform = t
}

// An object's scale stays between these.
MIN_OBJECT_SCALE :: 0.01
MAX_OBJECT_SCALE :: 100

// Sets the drag up from where the pointer is now, so nothing jumps by the slop a finger
// moved first. False when the handle cannot be dragged from this view (its plane seen
// edge on), and the press does nothing.
@(private = "file")
move_go_live :: proc(app: ^App, obj: ^Object, input: Viewport_Input) -> bool {
	drag := &app.move.drag
	sc := gizmo_screen(app, input.size)
	origin, dir := mouse_ray(app.camera, input.mouse_pos, input.size)
	drag.live = true
	drag.press, drag.center, drag.arm_px = input.mouse_pos, sc.center, sc.arm_px
	drag.pivot = gizmo_center(app, obj)
	drag.step = gizmo.grid_step(camera.orbit_world_per_px(app.camera, drag.pivot, input.size.y) * gizmo_scale(app))
	switch drag.handle {
	case .None:
		return false
	case .X, .Y, .Z:
		axis := gizmo.AXES[int(drag.handle) - int(gizmo.Handle.X)]
		drag.axis_start = gizmo.closest_on_axis(drag.start.position, axis, origin, dir) or_return
	case .View, .YZ, .XZ, .XY:
		if drag.handle == .View {
			drag.plane_normal = -camera.orbit_toward(app.camera, app.camera.target)
		} else {
			drag.plane_normal = gizmo.AXES[int(drag.handle) - int(gizmo.Handle.YZ)]
			drag.grab = drag.pivot
		}
		drag.grab = gizmo.ray_plane(origin, dir, drag.grab, drag.plane_normal) or_return
	case .Turn_X, .Turn_Y, .Turn_Z, .Turn_View:
		i := int(drag.handle) - int(gizmo.Handle.Turn_X)
		drag.axis = gizmo.AXES[i] if i < 3 else -camera.orbit_toward(app.camera, drag.pivot)
		// Seen nearly edge on, the ray meets the ring's plane far from the ring, and a
		// small move swings the angle wildly: the drag along the ring on screen turns it.
		hit, ok := gizmo.ray_plane(origin, dir, drag.pivot, drag.axis)
		drag.edge = !ok || abs(linalg.dot(dir, drag.axis)) < 0.2
		drag.turn_from = hit
		if drag.edge do drag.tangent = gizmo.ring_tangent(sc.rings[i][:], input.mouse_pos)
	case .Scale:
	}
	return true
}

// Ends the drag in progress, if any, as one undo step when it changed the object.
move_end :: proc(app: ^App) {
	drag := app.move.drag
	app.move.drag = {}
	obj := object_by_id(app, drag.id)
	if drag.handle == .None || obj == nil || obj.transform == drag.start do return
	history_record_transform(app, obj, drag.start, MOVE_WHAT[drag_mode(drag.handle)])
	app.move.drags += 1
	app.move.last = drag.handle
}

// Puts the object back where the drag began and ends it with nothing recorded: Escape,
// a second finger making a gesture, or a cancelled touch.
move_cancel :: proc(app: ^App) {
	drag := app.move.drag
	app.move.drag = {}
	if drag.handle == .None do return
	if obj := object_by_id(app, drag.id); obj != nil do obj.transform = drag.start
}

// What a handle does.
drag_mode :: proc(h: gizmo.Handle) -> gizmo.Mode {
	#partial switch h {
	case .Turn_X ..= .Turn_View: return .Turn
	case .Scale:                 return .Scale
	}
	return .Move
}

// What the drag in progress has done, for the label by the pointer: "X +0.250",
// "Turn Z 45°", "Scale ×1.30", with the step when it snaps.
move_readout :: proc(app: ^App) -> string {
	drag := app.move.drag
	obj := object_by_id(app, drag.id)
	// Nothing until something changed, so a click that selects shows no label.
	if !drag.live || obj == nil || obj.transform == drag.start do return ""
	text: string
	snap: string
	switch drag_mode(drag.handle) {
	case .Move:
		if drag.handle >= .X && drag.handle <= .Z {
			text = fmt.tprintf("%v %+.3f", drag.handle, drag.amount)
		} else {
			d := obj.transform.position - drag.start.position
			text = fmt.tprintf("Move %+.3f, %+.3f, %+.3f", d.x, d.y, d.z)
		}
		snap = fmt.tprintf("snap %g", drag.step)
	case .Turn:
		names := [4]string{"X", "Y", "Z", "view"}
		text = fmt.tprintf("Turn %s %+.1f°", names[int(drag.handle) - int(gizmo.Handle.Turn_X)], drag.amount)
		snap = fmt.tprintf("snap %d°", gizmo.TURN_SNAP_DEGREES)
	case .Scale:
		text = fmt.tprintf("Scale ×%.2f", drag.amount)
		snap = fmt.tprintf("snap %g", gizmo.SCALE_SNAP)
	}
	if drag.snapped do return fmt.tprintf("%s (%s)", text, snap)
	return text
}

// Puts the selected object back at the world's middle, unturned, at scale 1, as one undo
// step.
transform_reset :: proc(app: ^App) {
	obj := selected_object(app)
	if obj == nil do return
	move_end(app)
	before := obj.transform
	obj.transform = {scale = 1}
	history_record_transform(app, obj, before, "Reset transform")
}

// A drag of the inspector's Transform values: one undo step from its press to its release.
Transform_Drag :: struct {
	active: bool,
	id:     int,
	from:   Transform,
}

// Notes that the inspector changed `obj`'s transform from `before` this frame.
transform_drag_changed :: proc(app: ^App, obj: ^Object, before: Transform) {
	d := &app.ui.transform_drag
	if d.active && d.id == obj.id do return
	transform_drag_end(app, force = true)
	d^ = {active = true, id = obj.id, from = before}
}

// Ends a drag of the inspector's Transform values once the pointer lets go (or at once
// with `force`), as one undo step. Runs every frame, so a drag ends even if its section
// closed meanwhile.
transform_drag_end :: proc(app: ^App, force := false) {
	d := &app.ui.transform_drag
	if !d.active || (!force && .Left in app.device.down) do return
	d.active = false
	if obj := object_by_id(app, d.id); obj != nil do history_record_transform(app, obj, d.from, "Transform")
}

// Steps the gizmo's mode on (Move, Turn, Scale, Move): W again with the Move tool on, as
// ZBrush's W, E and R are one key here.
gizmo_cycle :: proc(app: ^App) {
	app.move.mode = gizmo.Mode((int(app.move.mode) + 1) % len(gizmo.Mode))
}

// Points the camera at the selected object.
focus_selected :: proc(app: ^App) {
	obj := selected_object(app)
	if obj == nil do return
	app.camera.target = obj.transform.position
	app.camera.distance = clamp(3.5 * obj.transform.scale, camera.MIN_DISTANCE, camera.MAX_DISTANCE)
	// Framed afresh, the view turns about what it framed until the next stroke.
	app.pivot.set, app.pivot.pinned = false, false
}

// Points the camera at the middle of all objects, far enough back to see them all.
frame_all :: proc(app: ^App) {
	if len(app.scene.objects) == 0 do return
	lo, hi := Vec3(max(f32)), Vec3(min(f32))
	for obj in app.scene.objects {
		t := obj.transform
		lo = linalg.min(lo, t.position - t.scale)
		hi = linalg.max(hi, t.position + t.scale)
	}
	app.camera.target = (lo + hi) / 2
	app.camera.distance = clamp(1.75 * linalg.length(hi - lo), camera.MIN_DISTANCE, camera.MAX_DISTANCE)
	app.pivot.set, app.pivot.pinned = false, false
}
