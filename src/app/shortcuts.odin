package main

import sdl "vendor:sdl3"

import "../camera"
import "../sculpt"

// The keyboard shortcuts (README "Controls"), read from this frame's keys. None fires
// while a text field has the keys.
handle_shortcuts :: proc(app: ^App) {
	if typing(app) do return
	d := &app.device
	if d.ctrl && key_pressed(d, sdl.K_Z, true) {
		if d.shift do history_redo(app)
		else do history_undo(app)
	}
	if d.ctrl && key_pressed(d, sdl.K_Y, true) do history_redo(app)
	if d.ctrl && key_pressed(d, sdl.K_S) {
		if d.shift do file_dialog(app, .Save)
		else do save_scene(app)
	}
	if d.ctrl && key_pressed(d, sdl.K_O) do file_dialog(app, .Open)
	if key_pressed(d, sdl.K_F12) do file_dialog(app, .Screenshot)
	if key_pressed(d, sdl.K_W) {
		switch {
		case d.ctrl:
			group_shortcut(app)
		case d.shift:
			app.show_groups = !app.show_groups
		case !d.alt:
			app.tool = .Move
		}
	}
	if key_pressed(d, sdl.K_B) do app.tool = .Brush
	if key_pressed(d, sdl.K_C) && !d.ctrl && !d.alt do app.tool = .Curve
	if key_pressed(d, sdl.K_I) && !d.ctrl && !d.alt do app.tool = .Insert
	if !d.ctrl && !d.alt {
		// 1 to 9 and 0 pick the brushes in the order the panels list them.
		for kind, i in sculpt.Brush_Kind {
			if i >= 10 do break
			if key_pressed(d, sdl.K_0 if i == 9 else sdl.K_1 + sdl.Keycode(i)) {
				app.brush.kind = kind
				app.tool = .Brush
			}
		}
		if key_pressed(d, sdl.K_X) do app.brush.symmetry ~= {.X}
		// [ and ] step the size by a sixth, Shift with them the strength by 0.05.
		for key, i in ([2]sdl.Keycode{sdl.K_LEFTBRACKET, sdl.K_RIGHTBRACKET}) {
			if !key_pressed(d, key, true) do continue
			up := i == 1
			if d.shift {
				s := brush_strength(app)
				s^ = clamp(s^ + (0.05 if up else -0.05), MIN_STRENGTH, 1)
			} else {
				app.brush.radius_px = clamp(app.brush.radius_px * (7.0 / 6 if up else 6.0 / 7), MIN_RADIUS_PX, MAX_RADIUS_PX)
			}
		}
	}
	if d.alt && key_pressed(d, sdl.K_M) do mask_command(app, .Clear)
	if obj := selected_object(app); obj != nil && d.ctrl && key_pressed(d, sdl.K_R) {
		app.ui.scene_command = {kind = .Remesh, vertices = object_vertex_count(obj)}
	}
	if obj := selected_object(app); obj != nil && d.ctrl && key_pressed(d, sdl.K_T) {
		app.ui.scene_command = {kind = .Dyntopo, on = !object_dynamic(obj)}
	}
	if d.ctrl && key_pressed(d, sdl.K_I) do mask_command(app, .Invert)
	// Ctrl+H shows everything again and Ctrl+Shift+H swaps hidden and shown.
	if d.ctrl && key_pressed(d, sdl.K_H) do hide_command(app, .Invert if d.shift else .Show_All)
	// The keypad's 1, 3 and 7 look from the front, right and top, and with Ctrl from the
	// opposite side, as in Blender.
	for key, i in ([3]sdl.Keycode{sdl.K_KP_1, sdl.K_KP_3, sdl.K_KP_7}) {
		if !key_pressed(d, key) do continue
		views := [3][2]camera.Axis_View{{.Front, .Back}, {.Right, .Left}, {.Top, .Bottom}}
		camera.orbit_axis_view(&app.camera, views[i][1 if d.ctrl else 0])
	}
	// P (ZBrush's Persp toggle) or the keypad's 5 (Blender's) switches parallel projection.
	if (key_pressed(d, sdl.K_P) && !d.ctrl) || key_pressed(d, sdl.K_KP_5) do app.camera.ortho = !app.camera.ortho
	if key_pressed(d, sdl.K_F) {
		// Shift+F shows the edges, as ZBrush's PolyFrame; F alone frames the selection.
		if d.shift {
			app.wireframe = !app.wireframe
		} else {
			focus_selected(app)
		}
	}
	// Shift+R, as ZBrush's BPR render, switches the studio render; R alone replays the
	// recorded strokes (or else the last stroke) at the pointer, and Escape stops it.
	if key_pressed(d, sdl.K_R) && d.shift && !d.ctrl do studio_toggle(app)
	if key_pressed(d, sdl.K_R) && !d.shift && !d.ctrl && !d.alt && app.tool == .Brush do replay_shortcut(app)
	if key_pressed(d, sdl.K_ESCAPE) do replay_stop(app)
	// Shift+G shows the triangles as flat facets, beside Shift+F's wireframe.
	if key_pressed(d, sdl.K_G) && d.shift && !d.ctrl do app.flat = !app.flat
	// Delete removes the selected object; Ctrl+Z brings it back.
	if key_pressed(d, sdl.K_DELETE) && selected_object(app) != nil do app.ui.scene_command = {kind = .Delete}
	if key_pressed(d, sdl.K_A) && !d.ctrl {
		// Toggles HD sculpting: a window opens where the pointer is, on the object there.
		if obj := selected_object(app); obj != nil && object_in_hd(obj) {
			app.ui.scene_command = {kind = .Hd_Leave}
		} else if app.ui.viewport_hovered {
			app.ui.scene_command = {kind = .Hd_Enter, at = app.ui.viewport_mouse, size = app.ui.viewport_size}
		}
	}
	if obj := selected_object(app); obj != nil && key_pressed(d, sdl.K_D) {
		switch {
		case d.ctrl && d.shift:
			app.ui.scene_command = {kind = .Duplicate}
		case d.ctrl:
			app.ui.scene_command = {kind = .Subdivide}
		case d.shift:
			app.ui.scene_command = {kind = .Set_Level, level = obj.levels.current - 1}
		case:
			app.ui.scene_command = {kind = .Set_Level, level = obj.levels.current + 1}
		}
	}
}
