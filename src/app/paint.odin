package main

import "core:log"
import "core:time"
import sdl "vendor:sdl3"

import "../render"
import "../sculpt"

// Polypaint and polygroups on the app side: the Polypaint and Polygroups commands as
// undo steps, the Ctrl + Shift click that isolates a group, and their GPU upload.

// The Paint brush's colour as the sculptor takes it: sRGB bytes.
brush_color_bytes :: proc(app: ^App) -> [3]u8 {
	c := app.brush.color
	return {u8(clamp(c.r, 0, 1) * 255 + 0.5), u8(clamp(c.g, 0, 1) * 255 + 0.5), u8(clamp(c.b, 0, 1) * 255 + 0.5)}
}

// Fills the selected object with the brush colour, or clears its paint, as an undo
// step of its own (sculpt.sculptor_paint_command).
paint_command :: proc(app: ^App, command: sculpt.Paint_Command) {
	stroke_finish(app)
	obj := selected_object(app)
	if obj == nil || !paint_allowed(obj) do return
	start := time.tick_now()
	changed := sculpt.sculptor_paint_command(object_sculptor(obj), command, brush_color_bytes(app))
	log.infof("%s: %.0f ms%s", "fill paint" if command == .Fill else "clear paint", time.duration_milliseconds(time.tick_since(start)), "" if changed else ", nothing changed")
	if changed do history_record(app, obj, .Paint, "Fill paint" if command == .Fill else "Clear paint")
}

// Changes the selected object's polygroups as an undo step of its own
// (sculpt.sculptor_group_command).
group_command :: proc(app: ^App, command: sculpt.Group_Command) {
	stroke_finish(app)
	obj := selected_object(app)
	if obj == nil || !paint_allowed(obj) do return
	start := time.tick_now()
	s := object_sculptor(obj)
	changed := sculpt.sculptor_group_command(s, command, app.ui.crease_degrees)
	groups := 0
	if g := sculpt.sculptor_groups(s); g != nil {
		seen := make(map[u16]bool, 64, context.temp_allocator)
		for x in g do seen[x] = true
		groups = len(seen)
	}
	log.infof("polygroups %v: %d groups, %.0f ms%s", command, groups, time.duration_milliseconds(time.tick_since(start)), "" if changed else ", nothing changed")
	if !changed do return
	// Grouping is easiest to follow seen.
	app.show_groups = true
	history_record(app, obj, .Paint, GROUP_COMMAND_NAMES[command])
}

@(private = "file", rodata)
GROUP_COMMAND_NAMES := [sculpt.Group_Command]string {
	.Visible = "Group visible",
	.Masked  = "Group masked",
	.Creases = "Group by creases",
	.Clear   = "Clear groups",
}

// What Ctrl+W does, as ZBrush's: with something masked, the masked part becomes a group
// and the mask is cleared; otherwise what is shown becomes one.
group_shortcut :: proc(app: ^App) {
	obj := selected_object(app)
	if obj == nil do return
	if object_sculptor(obj).mask != nil && !object_dynamic(obj) && !object_in_hd(obj) {
		before := len(app.history.done)
		group_command(app, .Masked)
		if len(app.history.done) > before do mask_command(app, .Clear)
		return
	}
	group_command(app, .Visible)
}

// A Ctrl + Shift click at viewport point `at`: on a group of the object there, shows
// only that group (or, when it is all that shows, everything but it), or with `alt`
// masks it; anywhere else, or on an object without groups, shows everything. Returns
// whether a group was clicked.
group_click :: proc(app: ^App, at, size: [2]f32, alt: bool) -> bool {
	origin, dir := mouse_ray(app.camera, at, size)
	index, _, ok := scene_raycast(app, origin, dir)
	if !ok do return false
	obj := app.scene.objects[index]
	s := object_sculptor(obj)
	if !sculpt.sculptor_has_groups(s) || object_in_hd(obj) do return false
	t := obj.transform
	group, hit := sculpt.sculptor_group_at(s, to_local(t, origin), to_local_dir(t, dir))
	if !hit do return false
	stroke_finish(app)
	app.scene.selected = index
	start := time.tick_now()
	if alt {
		changed := sculpt.sculptor_mask_group(s, group)
		app.ui.mask_last = {command = .Fill, ms = time.duration_milliseconds(time.tick_since(start)), changed = changed, set = true, shape = true}
		log.infof("mask group %d: %.0f ms%s", group, app.ui.mask_last.ms, "" if changed else ", nothing changed")
		if changed do history_record(app, obj, .Mask, "Mask group")
		return true
	}
	changed := sculpt.sculptor_hide_group(s, group)
	app.ui.hide_last = {ms = time.duration_milliseconds(time.tick_since(start)), changed = changed, set = true}
	log.infof("isolate group %d: %d of %d triangles hidden, %.0f ms", group, sculpt.sculptor_hidden_count(s), object_triangle_count(obj), app.ui.hide_last.ms)
	if changed {
		history_record(app, obj, .Hide, "Isolate group")
		render.viewport_invalidate(&app.target)
	}
	return true
}

// Paint and groups work on a level's own vertices and triangles: not in an HD window,
// whose detail leaves when it closes, nor under dynamic topology, whose edits would have
// to carry them along.
paint_allowed :: proc(obj: ^Object) -> bool {
	switch {
	case object_in_hd(obj):
		log.warn("polypaint and polygroups: leave the HD window first (A)")
		return false
	case object_dynamic(obj):
		log.warn("polypaint and polygroups: not with dynamic topology on")
		return false
	}
	return true
}

// Brings the level's paint buffer up to date: everything when its colours or groups
// changed as a whole (or the buffer is new), else the vertex `ranges` the flush reported.
// Returns the bytes sent.
paint_upload :: proc(app: ^App, cmd: ^sdl.GPUCommandBuffer, gpu: ^render.Mesh_Buffers, lv: ^sculpt.Level, ranges: []sculpt.Vertex_Range) -> int {
	s := &lv.sculptor
	colors, groups := s.color, sculpt.sculptor_vertex_groups(s)
	if colors == nil && groups == nil do return 0
	stamp := sculpt.sculptor_paint_stamp(s)
	all := gpu.paint == nil || gpu.paint_stamp != stamp
	if !all && len(ranges) == 0 do return 0
	render.mesh_buffers_upload_paint(&app.renderer, cmd, gpu, colors, groups, ranges, all)
	gpu.paint_stamp = stamp
	if all do return int(gpu.vertex_capacity) * size_of(render.Paint_Packed)
	bytes := 0
	for r in ranges do bytes += int(r.count) * size_of(render.Paint_Packed)
	return bytes
}
