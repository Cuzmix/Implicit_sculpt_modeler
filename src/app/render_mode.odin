package main

import "core:fmt"
import sdl "vendor:sdl3"

import "../render"
import "../ui"

// Scene > Render (stage 4.4, render/path.odin): the view path traced while it stays still,
// with the scene's lights, environment, materials and paint, bounced light and soft
// shadows from every light, built up a sample at a time. Not remembered, as Blender's
// rendered view is not: it is costly, and a start that put it on would surprise. Samples,
// Bounces, Denoise and Half resolution are remembered.

// Samples before the render shows instead of the viewport (or the studio's or live
// occlusion's image): by then its noise reads as a picture.
RENDER_SHOW_MIN :: 4

// Whether render mode runs: it is on, and the device can run it.
render_running :: proc(app: ^App) -> bool {
	return app.render_on && !app.path.failed && pass_shaded(app)
}

// Turns render mode on or off; on, it starts over.
render_toggle :: proc(app: ^App) {
	app.render_on = !app.render_on
	render.path_render_reset(&app.path)
}

// Runs this frame's render mode after render_viewport, `changed` saying whether anything
// was redrawn. Off, it gives back what it held on the device, which is a copy of the
// traced scene.
render_mode_frame :: proc(app: ^App, cmd: ^sdl.GPUCommandBuffer, view, proj: render.Mat4, items: []render.Draw_Item, changed: bool) {
	if !app.render_on {
		if app.path.pipeline != nil do render.path_render_destroy(&app.renderer, &app.path)
		return
	}
	// A pass pauses it, keeping what it holds on the device; it starts over once the
	// shaded picture is back, which redraws the viewport.
	if !pass_shaded(app) do return
	samples := int(clamp(app.render_samples, 1, render.RENDER_SAMPLES_MAX))
	bounces := int(clamp(app.render_bounces, 1, render.RENDER_BOUNCES_MAX))
	_ = render.render_frame(&app.renderer, &app.path, cmd, &app.target, view, proj, items, changed, samples, bounces, viewport_lights(app), app.studio_softness, app.exposure, app.render_denoise, app.render_half, render_lens(app), &app.pool)
}

// Whether render mode still has samples to build, which keeps the frames coming.
render_busy :: proc(app: ^App) -> bool {
	pr := &app.path
	return render_running(app) && pr.refused == "" && pr.samples < int(app.render_samples)
}

// The Scene palette's Render section.
kit_render :: proc(app: ^App) {
	ctx := &app.kit.ctx
	on := app.render_on
	if ui.switch_row(ctx, "Render mode", &on, keys = command_hint(app, .Render_Mode)) do command_run(app, .Render_Mode)
	samples := f32(app.render_samples)
	if ui.slider(ctx, "Samples", &samples, 16, render.RENDER_SAMPLES_MAX, .Logarithmic, fmt.tprintf("%d", app.render_samples)) do app.render_samples = i32(samples + 0.5)
	bounces := f32(app.render_bounces)
	if ui.slider(ctx, "Bounces", &bounces, 1, render.RENDER_BOUNCES_MAX, .Linear, fmt.tprintf("%d", app.render_bounces)) do app.render_bounces = i32(bounces + 0.5)
	_ = ui.switch_row(ctx, "Denoise", &app.render_denoise)
	_ = ui.switch_row(ctx, "Half resolution", &app.render_half)
	pr := &app.path
	switch {
	case app.render_on && pr.failed:
		ui.paragraph(ctx, "Render mode could not be set up on this GPU; the log says why.")
	case app.render_on && !pass_shaded(app):
		ui.paragraph(ctx, pass_paused_note(app))
	case render_running(app) && pr.refused != "":
		ui.paragraph(ctx, pr.refused)
	case render_running(app) && pr.samples > 0:
		ms := pr.total_ms / f64(max(pr.total_samples, 1))
		ui.paragraph(ctx, fmt.tprintf("Built up %d of %d samples, %.0f ms a sample.", pr.samples, app.render_samples, ms))
	}
	if render_running(app) && pr.tex_left_out > 0 {
		ui.paragraph(ctx, fmt.tprintf("Render mode shows the maps of %d textured objects; %d more show their material.", render.RENDER_TEXTURED_MAX, pr.tex_left_out))
	}
	ui.paragraph(ctx, fmt.tprintf("Path traces the view while it stays still: the lights with soft shadows as wide as the studio's Shadow softness, the environment, materials, paint and texture maps, and light bounced between surfaces. Any change starts it over; see-through objects are left out. Denoise smooths the grain along the surfaces' edges, colours and normals, less as samples build up. Half resolution traces a quarter of the pixels, four times as fast, for tablets. %s", command_keys(app, .Render_Mode)))
}

