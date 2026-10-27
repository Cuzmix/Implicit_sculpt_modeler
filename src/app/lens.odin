package main

import "core:fmt"

import "../gizmo"
import "../render"
import "../ui"

// Scene > Lens: render mode's depth of field (render.Lens). Depth of field and Blur are
// remembered; the point in focus is the session's, as Blender keeps a focus object with
// the camera rather than the file: by default the pivot the view turns about, so framing
// something focuses it (as Nomad does), or a point Pick focus took from the model (as
// KeyShot's pick focus point), which stays in focus while the view turns round it. New
// scene and Open go back to the pivot.

// Blur's value at the start: a lens a few hundredths of the scene's size across, which
// softens what is a scene's radius nearer or farther without hiding its shape.
RENDER_BLUR_DEFAULT :: 0.4

// The lens render mode traces through this frame: none while depth of field is off, so
// moving the pivot then starts nothing over.
render_lens :: proc(app: ^App) -> render.Lens {
	if !app.render_dof do return {}
	return {on = true, blur = app.render_blur, focus = focus_point(app)}
}

// The point in focus (world): the picked one, or the pivot.
focus_point :: proc(app: ^App) -> Vec3 {
	if at, ok := app.focus.?; ok do return at
	return app.camera.target
}

// The Pick focus command: the next press on the model sets the point in focus; run
// again before that, it waits no more.
focus_pick_command :: proc(app: ^App) {
	app.ui.focus_armed = !app.ui.focus_armed
}

// Follows an armed Pick focus with this frame's input: the press on the viewport and the
// drag after it put the focus where the pointer meets the model, so the marker follows
// the finger, and letting go keeps the last; a press that meets nothing leaves the focus
// as it was. Returns true while the press is Pick focus's, so no tool takes it.
focus_pick_frame :: proc(app: ^App, input: Viewport_Input) -> bool {
	u := &app.ui
	if !u.focus_held {
		if !u.focus_armed || !input.press do return false
		u.focus_armed, u.focus_held, u.focus_hit = false, true, false
	}
	origin, dir := mouse_ray(app.camera, input.mouse_pos, input.size)
	if _, at, _, ok := scene_raycast_surface(app, origin, dir); ok {
		app.focus = at
		u.focus_hit = true
	}
	if input.primary do return true
	u.focus_held = false
	if u.focus_hit {
		at := focus_point(app)
		report(app, Kit_Section.Lens, {.Quiet}, "Focus at %.2f, %.2f, %.2f", at.x, at.y, at.z)
	} else {
		report(app, Kit_Section.Lens, {.Warning}, "Pick focus: the press missed every object")
	}
	return true
}

// Whether the focus marker shows: while Pick focus waits or is held, and while the Lens
// section is open with depth of field on.
focus_marker_shown :: proc(app: ^App) -> bool {
	u := &app.ui
	if u.focus_armed || u.focus_held do return true
	k := &app.kit
	return app.render_dof && k.inspector && k.tab == .Scene && tray_section(app, .Scene) == .Lens
}

// The focus marker, in the light markers' style: a ring on a dark plate with four ticks
// reaching in, a camera's focus mark, over the point in focus.
draw_focus_marker :: proc(app: ^App, o: Overlay, size: [2]f32) {
	if !focus_marker_shown(app) do return
	s, ok := gizmo.project(view_proj_of(app, size), focus_point(app), size)
	if !ok do return
	px := gizmo_scale(app)
	r := 11 * px
	white := overlay_color({1, 1, 1, 0.95})
	overlay_circle(o, s, r, overlay_color({0.08, 0.08, 0.09, 0.6}), 5 * px)
	overlay_circle(o, s, r, white, 2 * px)
	for d in ([4][2]f32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do overlay_line(o, s + d * (r + 5 * px), s + d * (r - 5 * px), white, 2 * px)
	overlay_disc(o, s, 2 * px, white)
}

// The Scene palette's Lens section.
kit_lens :: proc(app: ^App) {
	ctx := &app.kit.ctx
	_ = ui.switch_row(ctx, "Depth of field", &app.render_dof)
	_ = ui.slider(ctx, "Blur", &app.render_blur, 0, 1, .Linear, fmt.tprintf("%.2f", app.render_blur))
	kit_command_pair(app, .Pick_Focus, .Focus_Pivot, tone_a = .Accent if app.ui.focus_armed else .Neutral)
	_, picked := app.focus.?
	ui.paragraph(ctx, "In focus: a point picked on the model." if picked else "In focus: the pivot the view turns about.")
	if app.render_dof && !app.render_on do ui.paragraph(ctx, "Depth of field shows in render mode.")
	ui.paragraph(ctx, fmt.tprintf("Render mode blurs what is nearer or farther than the point in focus, as a camera's lens does. Blur is how wide the lens is, as a share of the scene's size. Pick focus takes the point from the next press on the model; it stays in focus while the view turns round it, until Focus on the pivot, New scene or Open. %s", command_keys(app, .Pick_Focus)))
}
