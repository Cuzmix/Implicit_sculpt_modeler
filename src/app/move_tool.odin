package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

import "../camera"
import "../gizmo"
import "../sculpt"
import "../ui"

// The tool the left mouse button drives in the viewport.
Tool :: enum u8 {
	Move, // select objects by clicking them; move them with the gizmo or by dragging
	Brush, // sculpt the object under the cursor
	Curve, // draw a tube, stitches or a zipper over the surface (curve_tool.odin)
	Insert, // put a shape on the surface (curve_tool.odin)
	Model, // edit a cage's points, edges and faces (model.odin)
}

Move_Tool :: struct {
	hover: gizmo.Handle, // handle under the cursor while no drag is active
	drag:  Move_Drag,
	mode:  gizmo.Mode, // what the handles do: move, turn or scale (remembered)
	snap:  bool, // the Snap latch: every drag snaps, as Ctrl makes one drag (remembered)
	// The Pivot latch: the next press on a surface puts the pivot there instead of
	// selecting or moving, and lets go.
	pivot_latch: bool,
	pivot: Gizmo_Pivot,
	// The drags that changed an object, and the handle of the last, for the exit stats.
	drags: int,
	last:  gizmo.Handle,
	drawn: [2]f32, // where the gizmo's centre was drawn last, for the scripted scenarios
	// The other selected objects as they were when the gizmo's drag began, and when the
	// inspector's Transform values began changing: both move with the primary.
	members:      [dynamic]Member_Start,
	edit_members: [dynamic]Member_Start,
	// Posing (pose.odin): what the mask allows, where the pivot was put for it, and the
	// poses that changed the mesh with how many vertices the last one moved, for the stats.
	seen:       Pose_Seen,
	placed:     Pose_Placed,
	pose_drags: int,
	pose_moved: int,
	// The topological mask under way (pose.odin), the ones made and the last one's reach,
	// for the stats.
	topo:       Topo_Gesture,
	topo_masks: int,
	topo_reach: f32,
}

// A selected object other than the primary, and where it was when a change began.
Member_Start :: struct {
	id:    int,
	start: Transform,
}

// Where turns and scales go about, when not the object's origin: a point in the object's
// own space, so moving, turning or scaling the object carries it along, kept for that
// object only and not saved.
Gizmo_Pivot :: struct {
	set: bool,
	id:  int,
	at:  Vec3,
}

// A drag in progress, of the gizmo or of an object's body. handle is None when there is
// none. It is set up when it goes live: at once for the mouse, and for a finger or a pen
// once it moves past the slop, so a tap never nudges the object.
Move_Drag :: struct {
	handle:       gizmo.Handle,
	on_handle:    bool, // pressed on the gizmo, not on the object's body
	down:         [2]f32, // the pointer at the press
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
	offset:       Vec3, // a move across a plane: the move so far
	snapped:      bool, // this frame's change snapped
	// A handle dragged in pose mode poses the mesh instead (pose.odin): the pose set last
	// and whether one was, and the pivot as it was (and where pose mode had put it), for
	// a cancel.
	posed:        bool,
	pose:         sculpt.Pose,
	applied:      bool,
	pivot_from:   Gizmo_Pivot,
	placed_from:  Vec3,
	// A drag of a lattice point (lattice.odin), from 1: it poses as a move of the view
	// plane handle does, through the point.
	lattice:      int,
}

// What the drag does, for the undo button and the History panel.
@(rodata)
MOVE_WHAT := [gizmo.Mode]string {
	.Move  = "Move",
	.Turn  = "Turn",
	.Scale = "Scale",
	.All   = "Transform", // never a drag's: each handle of the All mode does one of the three
}

// The modes' names on the action bar's chips and the Move tab's tabs.
@(rodata)
GIZMO_MODE_NAMES := [gizmo.Mode]string {
	.Move  = "Move",
	.Turn  = "Turn",
	.Scale = "Scale",
	.All   = "All",
}

// The colours of the x, y and z handles, and of the one under the pointer or dragged.
GIZMO_AXIS_COLORS :: [3][4]f32{{0.95, 0.3, 0.3, 1}, {0.4, 0.85, 0.35, 1}, {0.35, 0.55, 1, 1}}
GIZMO_HIGHLIGHT :: [4]f32{1, 0.85, 0.3, 1}

// Where the gizmo sits on the object: the pivot a tap placed, or its origin.
gizmo_center :: proc(app: ^App, obj: ^Object) -> Vec3 {
	if p := app.move.pivot; p.set && p.id == obj.id do return to_world(obj.transform, p.at)
	return obj.transform.position
}

// Whether the selected object has a pivot of its own (Reset pivot has something to do).
gizmo_pivot_set :: proc(app: ^App) -> bool {
	obj := selected_object(app)
	return obj != nil && app.move.pivot.set && app.move.pivot.id == obj.id
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
	return gizmo.screen(view_proj, center, arm, -camera.orbit_toward(app.camera, center), size, arm_px, app.move.mode)
}

// The handle under `at`, for the pointer in use.
gizmo_pick :: proc(app: ^App, at, size: [2]f32) -> gizmo.Handle {
	// A lattice's cage stands in for the gizmo.
	if selected_object(app) == nil || lattice_shown(app) != nil do return .None
	return gizmo.pick(gizmo_screen(app, size), app.move.mode, at, gizmo_radius(app))
}

// Turns this frame's viewport input into selection changes and object moves, turns and
// scales.
move_tool_frame :: proc(app: ^App, input: Viewport_Input) {
	m := &app.move
	if topo_frame(app, input) do return
	if !input.primary {
		// A tap on a handle, which moved nothing, asks for the value instead.
		d := m.drag
		slop := app.kit.ctx.theme.slop * gizmo_scale(app)
		if obj := object_by_id(app, d.id); obj != nil && d.on_handle && entry_takes(d.handle) && app.drag.travel <= slop && !drag_changed(obj, d) {
			gizmo_entry_open(app, obj, d.handle, d.down)
		}
		move_end(app)
		m.hover = .None
		app.ui.deform.lattice.hover = 0
		if input.hovered {
			m.hover = gizmo_pick(app, input.mouse_pos, input.size)
			app.ui.deform.lattice.hover = lattice_pick(app, input.mouse_pos, input.size)
		}
		pose_pivot_place(app)
		return
	}

	if input.press {
		// A drag still open (its release never seen) ends as it is.
		move_end(app)
		m.hover = .None
		if m.pivot_latch {
			// The pivot goes where the press meets a surface, of this object or another,
			// and the selection stays.
			origin, dir := mouse_ray(app.camera, input.mouse_pos, input.size)
			obj := selected_object(app)
			if _, hit, ok := scene_raycast(app, origin, dir); ok && obj != nil {
				m.pivot = {set = true, id = obj.id, at = to_local(obj.transform, hit)}
				m.pivot_latch = false
			}
			return
		}
		// A press on a lattice point drags it, through the point, across the view.
		if point := lattice_pick(app, input.mouse_pos, input.size); point > 0 {
			obj := selected_object(app)
			at := to_world(obj.transform, lattice_point(&app.ui.deform.lattice, point - 1))
			m.drag = {handle = .View, on_handle = true, down = input.mouse_pos, id = obj.id, start = obj.transform, grab = at, posed = true, lattice = point, pivot_from = m.pivot, placed_from = m.placed.at}
			return
		}
		handle := gizmo_pick(app, input.mouse_pos, input.size)
		on_handle := handle != .None
		grab: Vec3
		if handle == .None {
			// Not on the gizmo: a press selects what is under the pointer, and dragging moves
			// it in the view plane, whatever the gizmo's mode.
			origin, dir := mouse_ray(app.camera, input.mouse_pos, input.size)
			index, hit, ok := scene_raycast(app, origin, dir)
			// Shift, or Select several, adds the object to the selection or takes it out,
			// and moves nothing; missing every object then keeps the selection built so far.
			several := app.device.shift || app.kit.select_several
			if !ok {
				if !several do scene_deselect(app)
				return
			}
			if several {
				selection_toggle(app, index)
				return
			}
			selection_make_primary(app, index)
			// Ctrl, or the rail's Mask, makes a topological mask from the press instead.
			if input.mask_shape {
				topo_press(app, selected_object(app), input.mouse_pos, origin, dir, hit, input.size, input.alt)
				return
			}
			handle, grab = .View, hit
		} else {
			grab = gizmo_center(app, selected_object(app))
		}
		obj := selected_object(app)
		// In pose mode the handles pose the mesh; the body still moves the object.
		posed := on_handle && pose_mode(app)
		m.drag = {handle = handle, on_handle = on_handle, down = input.mouse_pos, id = obj.id, start = obj.transform, grab = grab, posed = posed, pivot_from = m.pivot, placed_from = m.placed.at}
		if !posed do members_take(app, &m.members)
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
		if !move_go_live(app, obj, input) || (drag.posed && !(lattice_begin(app, obj) if drag.lattice > 0 else pose_begin(app, obj))) do drag^ = {}
		return
	}
	drag.snapped = m.snap || app.device.ctrl
	// Each step a snapped drag takes is felt on a Pencil Pro, as a ruler's ticks are.
	was_amount, was_offset := drag.amount, drag.offset
	defer if drag.snapped && (drag.amount != was_amount || drag.offset != was_offset) do haptic(app, .Alignment)
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
		drag.offset = delta
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
		t = turn_about(drag.start, drag.pivot, drag.axis, degrees)
	case .Scale:
		f := gizmo.scale_factor(drag.center, drag.press, input.mouse_pos, drag.arm_px)
		if drag.snapped do f = max(gizmo.snap(f, gizmo.SCALE_SNAP), gizmo.SCALE_SNAP)
		// One factor for the whole selection, stopping where any of it reaches its limit,
		// so the selection keeps its shape.
		t = scale_about(drag.start, drag.pivot, selection_scale_clamp(f, drag.start.scale, m.members[:]))
		drag.amount = t.scale / drag.start.scale
	}
	if drag.posed {
		if drag.lattice > 0 {
			lattice_pose_set(app, obj, lattice_pose_of(app, drag.lattice, drag.start, drag.offset))
			return
		}
		pose_set(app, obj, pose_of(drag.handle, drag.start, t, drag.pivot, drag.axis, drag.amount))
		return
	}
	obj.transform = t
	members_follow(app, m.members[:], drag.start, t)
}

// Whether the drag has changed anything yet: the object's place, or in pose mode its mesh.
drag_changed :: proc(obj: ^Object, d: Move_Drag) -> bool {
	return d.applied && !pose_is_still(d.pose) if d.posed else obj.transform != d.start
}

// `factor` kept to what the primary (at scale `from`) and each of `list` can take, so a
// scale of the selection stops where any of it reaches its limit and keeps its shape.
selection_scale_clamp :: proc(factor, from: f32, list: []Member_Start) -> f32 {
	lo, hi := MIN_OBJECT_SCALE / from, MAX_OBJECT_SCALE / from
	for mb in list {
		lo = max(lo, MIN_OBJECT_SCALE / mb.start.scale)
		hi = min(hi, MAX_OBJECT_SCALE / mb.start.scale)
	}
	return clamp(factor, lo, max(lo, hi))
}

// Notes where the selected objects other than the primary are now, in `list`.
members_take :: proc(app: ^App, list: ^[dynamic]Member_Start) {
	clear(list)
	ids := selection_ids(app)
	if len(ids) < 2 do return
	for id in ids[1:] {
		if obj := object_by_id(app, id); obj != nil do append(list, Member_Start{id, obj.transform})
	}
}

// Places each of `list` as the primary went from `from` to `to`.
members_follow :: proc(app: ^App, list: []Member_Start, from, to: Transform) {
	for mb in list {
		if obj := object_by_id(app, mb.id); obj != nil do obj.transform = transform_follow(from, to, mb.start)
	}
}

// Records each of `list` that moved as part of the newest undo step, and forgets them.
members_record :: proc(app: ^App, list: ^[dynamic]Member_Start, what: string) {
	for mb in list {
		if obj := object_by_id(app, mb.id); obj != nil do history_record_transform(app, obj, mb.start, what, chain = true)
	}
	clear(list)
}

// Where `t` goes when the primary goes from `from` to `to`: the same move, turn and scale
// about the same points, so the selection keeps its shape and spacing. What did not
// change is left exactly as it was (a move turns nothing, even by rounding).
transform_follow :: proc(from, to, t: Transform) -> Transform {
	if from == to do return t
	out := t
	k: f32 = 1 if to.scale == from.scale else to.scale / from.scale
	r := matrix[3, 3]f32{1, 0, 0, 0, 1, 0, 0, 0, 1}
	if to.rotation != from.rotation {
		r = gizmo.rotation_matrix(to.rotation) * linalg.transpose(gizmo.rotation_matrix(from.rotation))
		turned := gizmo.rotation_degrees(r * gizmo.rotation_matrix(t.rotation))
		for i in 0 ..< 3 do out.rotation[i] = gizmo.wrap_degrees(turned[i])
	}
	out.scale = clamp(t.scale * k, MIN_OBJECT_SCALE, MAX_OBJECT_SCALE)
	out.position = to.position + r * ((t.position - from.position) * k)
	return out
}

// `t` turned `degrees` about the world axis `axis` through `pivot`: the turn comes before
// the object's own, and the pivot stays put. Only turns write the rotation.
turn_about :: proc(t: Transform, pivot, axis: Vec3, degrees: f32) -> Transform {
	if degrees == 0 do return t
	out := t
	r := linalg.matrix3_rotate_f32(linalg.to_radians(degrees), linalg.normalize(axis))
	turned := gizmo.rotation_degrees(r * gizmo.rotation_matrix(t.rotation))
	for i in 0 ..< 3 do out.rotation[i] = gizmo.wrap_degrees(turned[i])
	out.position = pivot + r * (t.position - pivot)
	return out
}

// `t` scaled by `factor` about `pivot`, the scale kept between MIN_OBJECT_SCALE and
// MAX_OBJECT_SCALE.
scale_about :: proc(t: Transform, pivot: Vec3, factor: f32) -> Transform {
	out := t
	out.scale = clamp(t.scale * factor, MIN_OBJECT_SCALE, MAX_OBJECT_SCALE)
	if out.scale == t.scale do return t
	out.position = pivot + (t.position - pivot) * (out.scale / t.scale)
	return out
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
		// A lattice point follows the pointer from where it was pressed, the travel past
		// the slop included, so it stays under the pointer through the drag.
		if drag.lattice > 0 do origin, dir = mouse_ray(app.camera, drag.down, input.size)
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
	topo_end(app)
	drag := app.move.drag
	app.move.drag = {}
	obj := object_by_id(app, drag.id)
	if drag.posed {
		// A click, or a drag that came back to where it began, leaves no step.
		if obj != nil && drag_changed(obj, drag) {
			if pose_end(app, obj, drag.handle, "Lattice" if drag.lattice > 0 else "") && drag.lattice > 0 do lattice_moved(app, drag.lattice, drag.pose)
		} else if obj != nil do sculpt.sculptor_pose_cancel(object_sculptor(obj))
		return
	}
	if drag.handle == .None || obj == nil || obj.transform == drag.start {
		clear(&app.move.members)
		return
	}
	history_record_transform(app, obj, drag.start, MOVE_WHAT[drag_mode(drag.handle)])
	members_record(app, &app.move.members, MOVE_WHAT[drag_mode(drag.handle)])
	app.move.drags += 1
	app.move.last = drag.handle
}

// Puts the object back where the drag began and ends it with nothing recorded: Escape,
// a second finger making a gesture, or a cancelled touch.
move_cancel :: proc(app: ^App) {
	topo_cancel(app)
	drag := app.move.drag
	app.move.drag = {}
	if drag.handle == .None do return
	if drag.posed {
		if obj := object_by_id(app, drag.id); obj != nil do sculpt.sculptor_pose_cancel(object_sculptor(obj))
		app.move.pivot, app.move.placed.at = drag.pivot_from, drag.placed_from
		return
	}
	if obj := object_by_id(app, drag.id); obj != nil do obj.transform = drag.start
	for mb in app.move.members {
		if obj := object_by_id(app, mb.id); obj != nil do obj.transform = mb.start
	}
	clear(&app.move.members)
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
	if g := app.move.topo; g.phase == .Live do return fmt.tprintf("Mask reach %.3f", g.reach)
	drag := app.move.drag
	obj := object_by_id(app, drag.id)
	// Nothing until something changed, so a click that selects shows no label.
	if !drag.live || obj == nil || !drag_changed(obj, drag) do return ""
	text: string
	snap: string
	switch drag_mode(drag.handle) {
	case .Move:
		if drag.handle >= .X && drag.handle <= .Z {
			text = fmt.tprintf("%v %+.3f", drag.handle, drag.amount)
		} else {
			d := drag.offset if drag.posed else obj.transform.position - drag.start.position
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
	case .All: // drag_mode never gives it: each handle does one of the three
	}
	if drag.posed do text = fmt.tprintf("%s: %s", "Lattice" if drag.lattice > 0 else "Pose", text)
	if drag.snapped do return fmt.tprintf("%s (%s)", text, snap)
	return text
}

// Puts each selected object back at the world's middle, unturned, at scale 1, as one
// undo step: each by itself, as Blender's Clear transform does, not as a group.
transform_reset :: proc(app: ^App) {
	move_end(app)
	transform_drag_end(app, force = true)
	recorded := false
	for id in selection_ids(app) {
		obj := object_by_id(app, id)
		if obj == nil do continue
		before := obj.transform
		obj.transform = {scale = 1}
		if before == obj.transform do continue
		history_record_transform(app, obj, before, "Reset transform", chain = recorded)
		recorded = true
	}
}

// A drag of the inspector's Transform values: one undo step from its press to its release.
Transform_Drag :: struct {
	active: bool,
	id:     int,
	from:   Transform,
}

// Notes that the inspector changed `obj`'s transform from `before` this frame; the rest
// of the selection follows it.
transform_drag_changed :: proc(app: ^App, obj: ^Object, before: Transform) {
	d := &app.ui.transform_drag
	if !d.active || d.id != obj.id {
		transform_drag_end(app, force = true)
		d^ = {active = true, id = obj.id, from = before}
		members_take(app, &app.move.edit_members)
	}
	// The Scale value stops where any of the selection reaches its limit.
	if len(app.move.edit_members) > 0 && obj.transform.scale != d.from.scale {
		obj.transform.scale = d.from.scale * selection_scale_clamp(obj.transform.scale / d.from.scale, d.from.scale, app.move.edit_members[:])
	}
	members_follow(app, app.move.edit_members[:], d.from, obj.transform)
}

// Ends a drag of the inspector's Transform values once the pointer lets go (or at once
// with `force`), as one undo step. Runs every frame, so a drag ends even if its section
// closed meanwhile.
transform_drag_end :: proc(app: ^App, force := false) {
	d := &app.ui.transform_drag
	if !d.active || (!force && .Left in app.device.down) do return
	d.active = false
	if obj := object_by_id(app, d.id); obj != nil && obj.transform != d.from {
		history_record_transform(app, obj, d.from, "Transform")
		members_record(app, &app.move.edit_members, "Transform")
	}
	clear(&app.move.edit_members)
}

// The value a tap on a handle asks for: an arm's position along its axis, a ring's turn
// in degrees, or the scale. Not the plane squares or the centre, which move in two or
// three axes at once.
Gizmo_Entry :: struct {
	open:   bool,
	typing: bool, // its field had the keys, which go back when it closes
	id:     int, // the object
	handle: gizmo.Handle,
	at:     ui.Rect, // the tap, in points, that it opens over
	text:   [32]u8,
	refused: bool, // the last Enter was no value
}

entry_takes :: proc(h: gizmo.Handle) -> bool {
	#partial switch h {
	case .X, .Y, .Z, .Turn_X ..= .Turn_View, .Scale: return true
	}
	return false
}

// Opens the value entry for `handle` over `at` (viewport pixels), empty, so what is typed
// is the value; the field's hint says what it is now.
gizmo_entry_open :: proc(app: ^App, obj: ^Object, handle: gizmo.Handle, at: [2]f32) {
	k := &app.kit
	kit_floats_close(k)
	p := at / gizmo_scale(app)
	k.gizmo_entry = {open = true, id = obj.id, handle = handle, at = {p.x - 1, p.y - 1, 2, 2}}
}

// What the entry asks for, for its title.
gizmo_entry_title :: proc(h: gizmo.Handle) -> string {
	#partial switch h {
	case .X:         return "Position X"
	case .Y:         return "Position Y"
	case .Z:         return "Position Z"
	case .Turn_X:    return "Turn about X, degrees"
	case .Turn_Y:    return "Turn about Y, degrees"
	case .Turn_Z:    return "Turn about Z, degrees"
	case .Turn_View: return "Turn about the view, degrees"
	}
	return "Scale"
}

// What the value entry asks for in pose mode, and what Enter does with it.
@(rodata)
POSE_ENTRY_TITLES := [gizmo.Mode]string {
	.Move  = "offset",
	.Turn  = "turn, degrees",
	.Scale = "scale factor",
	.All   = "value", // never a handle's (drag_mode)
}
@(rodata)
POSE_ENTRY_NOTES := [gizmo.Mode]string {
	.Move  = "Enter moves the unmasked part that far along the arm.",
	.Turn  = "Enter turns the unmasked part that far about the ring's axis.",
	.Scale = "Enter scales the unmasked part by it; +0.5 adds half.",
	.All   = "", // never a handle's (drag_mode)
}

// Places `obj` by the value typed for `handle`, as one undo step. A number sets an arm's
// position or the scale; "+0.5" adds to it, and "*2" (or "x2") multiplies the scale. A
// ring's value is the turn, in degrees, from where it is. False, changing nothing, when
// the text is no value.
gizmo_entry_apply :: proc(app: ^App, obj: ^Object, handle: gizmo.Handle, text: string) -> bool {
	s := strings.trim_space(text)
	op: u8
	if len(s) > 0 && (s[0] == '+' || s[0] == '*' || s[0] == 'x') {
		op = s[0]
		s = strings.trim_space(s[1:])
	}
	v, ok := strconv.parse_f32(s)
	if !ok || math.is_nan(v) || math.is_inf(v) do return false
	// In pose mode the value poses the unmasked part instead (pose.odin).
	if pose_mode(app) && obj == selected_object(app) do return pose_entry_apply(app, obj, handle, op, v)
	// The rest of the selection, as it is now, follows; an inspector drag still open (which
	// keeps its own list) ends first.
	transform_drag_end(app, force = true)
	members_take(app, &app.move.edit_members)
	defer clear(&app.move.edit_members)
	before := obj.transform
	t := before
	pivot := gizmo_center(app, obj)
	#partial switch handle {
	case .X, .Y, .Z:
		i := int(handle) - int(gizmo.Handle.X)
		switch op {
		case '+': t.position[i] += v
		case 0:   t.position[i] = v
		case:     return false
		}
	case .Turn_X ..= .Turn_View:
		if op != 0 && op != '+' do return false
		i := int(handle) - int(gizmo.Handle.Turn_X)
		axis := gizmo.AXES[i] if i < 3 else -camera.orbit_toward(app.camera, pivot)
		t = turn_about(t, pivot, axis, v)
	case .Scale:
		target: f32
		switch op {
		case '+':      target = t.scale + v
		case '*', 'x': target = t.scale * v
		case:          target = v
		}
		if target <= 0 do return false
		t = scale_about(t, pivot, selection_scale_clamp(target / t.scale, t.scale, app.move.edit_members[:]))
	case:
		return false
	}
	obj.transform = t
	if t == before do return true
	history_record_transform(app, obj, before, MOVE_WHAT[drag_mode(handle)])
	members_follow(app, app.move.edit_members[:], before, t)
	members_record(app, &app.move.edit_members, MOVE_WHAT[drag_mode(handle)])
	return true
}

// The value entry, over the handle tapped: a field that has the keys while it is open,
// Apply (or Enter) and Cancel (or Escape, or a press outside).
kit_gizmo_entry :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	e := &k.gizmo_entry
	obj := object_by_id(app, e.id)
	if e.open && (obj == nil || app.tool != .Move) do e.open = false
	if !e.open && e.typing {
		ctx.text_focus = 0
		e.typing = false
	}
	if !ui.popover_begin(ctx, "gizmo entry", &e.open, e.at, .Above_Center, {direction = .Column, gap = 4, padding = 12, width = 280}) do return
	defer ui.popover_end(ctx)
	posing := pose_mode(app)
	title := gizmo_entry_title(e.handle)
	if posing do title = fmt.tprintf("Pose: %s", POSE_ENTRY_TITLES[drag_mode(e.handle)])
	ui.caption(ctx, strings.to_upper(title, context.temp_allocator))
	hint := "Degrees, such as 90"
	if posing {
		#partial switch e.handle {
		case .X, .Y, .Z: hint = "Offset, such as 0.5"
		case .Scale:     hint = "Factor, such as 1.5"
		}
	} else if obj != nil {
		#partial switch e.handle {
		case .X, .Y, .Z: hint = fmt.tprintf("Now %.3f", obj.transform.position[int(e.handle) - int(gizmo.Handle.X)])
		case .Scale:     hint = fmt.tprintf("Now %.3f", obj.transform.scale)
		}
	}
	_ = ui.text_field(ctx, "value##gizmo entry", e.text[:], hold = e.open, hint = hint)
	e.typing ||= e.open
	n := 0
	for n < len(e.text) && e.text[n] != 0 do n += 1
	note := "Enter applies it; +0.5 adds to it."
	switch {
	case e.refused:                    note = "That is no value: type a number, such as 0.5."
	case posing:                       note = POSE_ENTRY_NOTES[drag_mode(e.handle)]
	case drag_mode(e.handle) == .Turn: note = "Enter turns it that far about the ring's axis."
	case e.handle == .Scale:           note = "Enter sets it; +0.5 adds, *2 doubles."
	}
	ui.paragraph(ctx, note)
	apply, cancel := kit_button_pair(ctx, "Apply", "Cancel", tone_a = .Accent)
	d := &app.device
	apply ||= e.open && (key_pressed(d, sdl.K_RETURN) || key_pressed(d, sdl.K_KP_ENTER))
	if apply && e.open && obj != nil {
		if gizmo_entry_apply(app, obj, e.handle, string(e.text[:n])) do e.open = false
		else do e.refused = true
	}
	if cancel do e.open = false
}

// Steps the gizmo's mode on (Move, Turn, Scale, All, Move): W again with the Move tool
// on, as ZBrush's W, E and R are one key here.
gizmo_cycle :: proc(app: ^App) {
	app.move.mode = gizmo.Mode((int(app.move.mode) + 1) % len(gizmo.Mode))
}

// Points the camera at the selected object (in Lens, in the middle of the room the
// controls leave).
focus_selected :: proc(app: ^App) {
	obj := selected_object(app)
	if obj == nil do return
	app.camera.target = obj.transform.position
	app.camera.distance = clamp(3.5 * obj.transform.scale, camera.MIN_DISTANCE, camera.MAX_DISTANCE)
	// Framed afresh, the view turns about what it framed until the next stroke.
	app.pivot.set, app.pivot.pinned = false, false
	view_fit_free(app, true)
}

// Points the camera at the middle of the objects in view, far enough back to see them
// all.
frame_all :: proc(app: ^App) {
	lo, hi := Vec3(max(f32)), Vec3(min(f32))
	for obj in app.scene.objects {
		if !object_shown(app, obj) do continue
		t := obj.transform
		lo = linalg.min(lo, t.position - t.scale)
		hi = linalg.max(hi, t.position + t.scale)
	}
	if lo.x > hi.x do return
	app.camera.target = (lo + hi) / 2
	app.camera.distance = clamp(1.75 * linalg.length(hi - lo), camera.MIN_DISTANCE, camera.MAX_DISTANCE)
	app.pivot.set, app.pivot.pinned = false, false
	view_fit_free(app, true)
}
