package main

import "core:math/linalg"

import "../camera"
import "../gizmo"

// The tool the left mouse button drives in the viewport.
Tool :: enum u8 {
	Move, // select objects by clicking them; move them with the gizmo or by dragging
	Brush, // sculpt the object under the cursor
}

Move_Tool :: struct {
	hover: gizmo.Handle, // handle under the cursor while no drag is active
	drag:  Move_Drag,
}

// A drag in progress. handle is None when there is none.
Move_Drag :: struct {
	handle:         gizmo.Handle,
	start_position: Vec3, // object position when the drag began
	axis_start:     f32, // .X/.Y/.Z: where along the axis the drag began
	grab:           Vec3, // .View: world point under the cursor when the drag began
	plane_normal:   Vec3, // .View: the view-plane the drag moves in
}

// The selected object's gizmo as it appears on screen, in viewport-local points.
Gizmo_View :: struct {
	center: [2]f32,
	tips:   [3][2]f32,
	tip_ok: [3]bool,
	ok:     bool,
}

gizmo_view :: proc(app: ^App, size: [2]f32) -> (gv: Gizmo_View) {
	obj := selected_object(app)
	if obj == nil || size.x <= 0 || size.y <= 0 do return
	view_proj := camera.orbit_proj(app.camera, size.x / size.y) * camera.orbit_view(app.camera)
	center := obj.transform.position
	gv.center, gv.ok = gizmo.project(view_proj, center, size)
	if !gv.ok do return
	arm := gizmo.ARM_PX * camera.orbit_world_per_px(app.camera, center, size.y)
	for axis, i in gizmo.AXES {
		gv.tips[i], gv.tip_ok[i] = gizmo.project(view_proj, center + axis * arm, size)
	}
	return
}

// Turns this frame's viewport input into selection changes and object moves.
move_tool_frame :: proc(app: ^App, input: Viewport_Input) {
	gv := gizmo_view(app, input.size)
	if !input.primary {
		app.move.drag = {}
		app.move.hover = .None
		if input.hovered && gv.ok do app.move.hover = gizmo.pick(input.mouse_pos, gv.center, gv.tips, gv.tip_ok)
		return
	}

	origin, dir := mouse_ray(app.camera, input.mouse_pos, input.size)
	if input.press {
		app.move.hover = .None
		handle := gizmo.Handle.None
		if gv.ok do handle = gizmo.pick(input.mouse_pos, gv.center, gv.tips, gv.tip_ok)
		grab: Vec3
		if handle == .None {
			// Not on the gizmo: click selects what is under the cursor, and dragging moves it.
			index, hit, ok := scene_raycast(app, origin, dir)
			if !ok {
				app.scene.selected = -1
				return
			}
			app.scene.selected = index
			handle, grab = .View, hit
		} else {
			grab = selected_object(app).transform.position
		}
		obj := selected_object(app)
		app.move.drag = {handle = handle, start_position = obj.transform.position, grab = grab}
		switch handle {
		case .X, .Y, .Z:
			app.move.drag.axis_start, _ = gizmo.closest_on_axis(obj.transform.position, gizmo.AXES[int(handle) - 1], origin, dir)
		case .View:
			app.move.drag.plane_normal = -camera.orbit_toward(app.camera, app.camera.target)
		case .None:
		}
		return
	}

	drag := app.move.drag
	obj := selected_object(app)
	if obj == nil do return
	switch drag.handle {
	case .None:
	case .X, .Y, .Z:
		axis := gizmo.AXES[int(drag.handle) - 1]
		if s, ok := gizmo.closest_on_axis(drag.start_position, axis, origin, dir); ok {
			obj.transform.position = drag.start_position + axis * (s - drag.axis_start)
		}
	case .View:
		if hit, ok := gizmo.ray_plane(origin, dir, drag.grab, drag.plane_normal); ok {
			obj.transform.position = drag.start_position + (hit - drag.grab)
		}
	}
}

// Points the camera at the selected object.
focus_selected :: proc(app: ^App) {
	obj := selected_object(app)
	if obj == nil do return
	app.camera.target = obj.transform.position
	app.camera.distance = clamp(3.5 * obj.transform.scale, camera.MIN_DISTANCE, camera.MAX_DISTANCE)
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
}
