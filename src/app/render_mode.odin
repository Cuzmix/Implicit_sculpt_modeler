package main

import "core:fmt"
import "core:math"

import "../render"
import "../ui"

// Scene > Render: one switch for both ways of rendering the still view, and its Quality.
// Preview is the studio render (render.Studio): ambient occlusion and soft shadows laid
// over the viewport's own shading, MatCaps and classic shading too, cheap enough for
// tablets and run where the GPU cannot path trace; remembered, as the Sculpt studio look
// starts with it. Full is render mode (stage 4.4, render/path.odin): the view path traced
// with the scene's lights, environment, materials, paint and maps, bounced light and soft
// shadows from every light, built up a sample at a time; not remembered, as Blender's
// rendered view is not: it is costly, and a start that put it on would surprise. Quality,
// Samples, Bounces, Denoise and Half resolution are remembered.

// Scene > Render's Quality.
Render_Quality :: enum u8 {
	Preview, // the studio render
	Full, // render mode, path traced
}

// Whether Scene > Render's switch is on: either quality.
render_switch_on :: proc(app: ^App) -> bool {
	return app.studio_on || app.render_on
}

// Puts the render on at `quality`, the other quality off, or with `on` false both off.
render_set :: proc(app: ^App, on: bool, quality: Render_Quality) {
	app.render_quality = quality
	if (on && quality == .Preview) != app.studio_on do studio_toggle(app)
	if (on && quality == .Full) != app.render_on do render_toggle(app)
}

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
render_mode_frame :: proc(app: ^App, cmd: render.Cmd, view, proj: render.Mat4, items: []render.Draw_Item, changed: bool) {
	if !app.render_on {
		if app.path.pipeline != nil do render.path_render_destroy(&app.renderer, &app.path)
		return
	}
	// A pass pauses it, keeping what it holds on the device; it starts over once the
	// shaded picture is back, which redraws the viewport.
	if !pass_shaded(app) do return
	samples := int(clamp(app.render_samples, 1, render.RENDER_SAMPLES_MAX))
	bounces := int(clamp(app.render_bounces, 1, render.RENDER_BOUNCES_MAX))
	_ = render.render_frame(&app.renderer, &app.path, cmd, &app.target, view, proj, items, changed, samples, bounces, viewport_lights(app), app.studio_softness, app.exposure, app.render_denoise, app.render_half, render_lens(app), &app.pool, linear = finish_wanted(app))
}

// Whether render mode still has samples to build, which keeps the frames coming.
render_busy :: proc(app: ^App) -> bool {
	pr := &app.path
	return render_running(app) && pr.refused == "" && pr.samples < int(app.render_samples)
}

// The Scene palette's Render section: the switch and Quality, then the chosen quality's
// own controls.
kit_render :: proc(app: ^App) {
	ctx := &app.kit.ctx
	on := render_switch_on(app)
	if ui.switch_row(ctx, "Render", &on, keys = command_hint(app, .Studio_Render)) do command_run(app, .Studio_Render)
	names := [2]string{"Preview", "Full"}
	hints := [2]string{"", command_hint(app, .Render_Mode)}
	if picked := ui.tabs(ctx, "render quality", names[:], int(app.render_quality), keys = hints[:]); picked >= 0 && Render_Quality(picked) != app.render_quality {
		// On, Full runs as its command does; otherwise only the quality changes.
		if on && Render_Quality(picked) == .Full do command_run(app, .Render_Mode)
		else do render_set(app, on, Render_Quality(picked))
	}
	switch app.render_quality {
	case .Preview: kit_render_preview(app)
	case .Full:    kit_render_full(app)
	}
}

// Preview's controls: the studio render's.
@(private = "file")
kit_render_preview :: proc(app: ^App) {
	ctx := &app.kit.ctx
	_ = ui.slider(ctx, "Occlusion", &app.studio_ao, 0, 1, .Linear, fmt.tprintf("%.2f", app.studio_ao))
	_ = ui.slider(ctx, "Shadow", &app.studio_shadow, 0, 1, .Linear, fmt.tprintf("%.2f", app.studio_shadow))
	samples := f32(app.studio_samples)
	if ui.slider(ctx, "Samples", &samples, 16, STUDIO_SAMPLES_MAX, .Logarithmic, fmt.tprintf("%d", app.studio_samples)) do app.studio_samples = i32(samples + 0.5)
	if kit_more(app, .Render) {
		_ = ui.slider(ctx, "Shadow softness", &app.studio_softness, render.STUDIO_SOFTNESS_MIN, render.STUDIO_SOFTNESS_MAX, .Logarithmic, fmt.tprintf("%.1f°", math.to_degrees(app.studio_softness)))
		kit_more_end(app)
	}
	switch {
	case app.studio_on && app.studio.failed:
		ui.paragraph(ctx, "Preview could not be set up on this GPU; the log says why.")
	case app.studio_on && !pass_shaded(app):
		ui.paragraph(ctx, pass_paused_note(app))
	case studio_running(app) && app.studio.samples > 0 && app.studio.samples < int(app.studio_samples):
		ui.paragraph(ctx, fmt.tprintf("Built up %d of %d samples.", app.studio.samples, app.studio_samples))
	}
	ui.paragraph(ctx, fmt.tprintf("Preview lays ambient occlusion and soft shadows over the viewport's own shading, MatCaps too, building them up while the view stays still; any change starts them over. It is quick, and runs on every GPU. Shadow softness is how wide a light of size 0 is. Full path traces the view instead. %s", command_keys(app, .Studio_Render)))
}

// Full's controls: render mode's.
@(private = "file")
kit_render_full :: proc(app: ^App) {
	ctx := &app.kit.ctx
	samples := f32(app.render_samples)
	if ui.slider(ctx, "Samples", &samples, 16, render.RENDER_SAMPLES_MAX, .Logarithmic, fmt.tprintf("%d", app.render_samples)) do app.render_samples = i32(samples + 0.5)
	bounces := f32(app.render_bounces)
	if ui.slider(ctx, "Bounces", &bounces, 1, render.RENDER_BOUNCES_MAX, .Linear, fmt.tprintf("%d", app.render_bounces)) do app.render_bounces = i32(bounces + 0.5)
	_ = ui.switch_row(ctx, "Denoise", &app.render_denoise)
	_ = ui.switch_row(ctx, "Half resolution", &app.render_half)
	pr := &app.path
	switch {
	case app.render_on && pr.failed:
		ui.paragraph(ctx, "Full could not be set up on this GPU; the log says why. Preview runs on every GPU.")
	case app.render_on && !pass_shaded(app):
		ui.paragraph(ctx, pass_paused_note(app))
	case render_running(app) && pr.refused != "":
		ui.paragraph(ctx, pr.refused)
	case render_running(app) && pr.samples > 0:
		ms := pr.total_ms / f64(max(pr.total_samples, 1))
		ui.paragraph(ctx, fmt.tprintf("Built up %d of %d samples, %.0f ms a sample.", pr.samples, app.render_samples, ms))
	}
	if render_running(app) && pr.tex_left_out > 0 {
		ui.paragraph(ctx, fmt.tprintf("Full shows the maps of %d textured objects; %d more show their material.", render.RENDER_TEXTURED_MAX, pr.tex_left_out))
	}
	ui.paragraph(ctx, fmt.tprintf("Full path traces the view while it stays still: the lights with soft shadows (their own size, or Preview's Shadow softness), the environment, materials, paint and texture maps, and light bounced between surfaces; a MatCap shows as its colour. Any change starts it over; see-through objects are left out. Denoise smooths the grain along the surfaces' edges, colours and normals, less as samples build up. Half resolution traces a quarter of the pixels, four times as fast, for tablets. Lens adds depth of field. %s", command_keys(app, .Render_Mode)))
}
