package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

import "../camera"
import "../gizmo"
import "../ui"

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
	// The Pivot latch: the next press on a surface puts the pivot there instead of
	// selecting or moving, and lets go.
	pivot_latch: bool,
	pivot: Gizmo_Pivot,
	// The drags that changed an object, and the handle of the last, for the exit stats.
	drags: int,
	last:  gizmo.Handle,
	drawn: [2]f32, // where the gizmo's centre was drawn last, for the scripted scenarios
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
		// A tap on a handle, which moved nothing, asks for the value instead.
		d := m.drag
		slop := app.kit.ctx.theme.slop * gizmo_scale(app)
		if obj := object_by_id(app, d.id); obj != nil && d.on_handle && entry_takes(d.handle) && app.drag.travel <= slop && obj.transform == d.start {
			gizmo_entry_open(app, obj, d.handle, d.down)
		}
		move_end(app)
		m.hover = .None
		if input.hovered do m.hover = gizmo_pick(app, input.mouse_pos, input.size)
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
		handle := gizmo_pick(app, input.mouse_pos, input.size)
		on_handle := handle != .None
		grab: Vec3
		if handle == .None {
			// Not on the gizmo: a press selects what is under the pointer, and dragging moves
			// it in the view plane, whatever the gizmo's mode.
			origin, dir := mouse_ray(app.camera, input.mouse_pos, input.size)
			index, hit, ok := scene_raycast(app, origin, dir)
			if !ok {
				scene_deselect(app)
				return
			}
			app.scene.selected = index
			handle, grab = .View, hit
		} else {
			grab = gizmo_center(app, selected_object(app))
		}
		obj := selected_object(app)
		m.drag = {handle = handle, on_handle = on_handle, down = input.mouse_pos, id = obj.id, start = obj.transform, grab = grab}
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
		t = turn_about(drag.start, drag.pivot, drag.axis, degrees)
	case .Scale:
		f := gizmo.scale_factor(drag.center, drag.press, input.mouse_pos, drag.arm_px)
		if drag.snapped do f = max(gizmo.snap(f, gizmo.SCALE_SNAP), gizmo.SCALE_SNAP)
		t = scale_about(drag.start, drag.pivot, f)
		drag.amount = t.scale / drag.start.scale
	}
	obj.transform = t
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
		t = scale_about(t, pivot, target / t.scale)
	case:
		return false
	}
	obj.transform = t
	history_record_transform(app, obj, before, MOVE_WHAT[drag_mode(handle)])
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
	ui.caption(ctx, strings.to_upper(gizmo_entry_title(e.handle), context.temp_allocator))
	hint := "Degrees, such as 90"
	if obj != nil {
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
}
