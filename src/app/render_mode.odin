package main

import "core:fmt"
import "core:math"

import "../render"
import "../ui"

// Scene > Render: one switch for both ways of rendering the still view, and its Quality.
// Fast is the studio render (render.Studio): ambient occlusion and soft shadows laid
// over the viewport's own shading, MatCaps and classic shading too, cheap enough for
// tablets and run where the GPU cannot path trace; remembered, as the Sculpt studio look
// starts with it. Full is render mode (stage 4.4, render/path.odin): the view path traced
// with the scene's lights, environment, materials, paint and maps, bounced light and soft
// shadows from every light, built up a sample at a time; not remembered, as Blender's
// rendered view is not: it is costly, and a start that put it on would surprise. Quality,
// Samples, Bounces, Denoise and Half resolution are remembered.

// Scene > Render's Quality.
Render_Quality :: enum u8 {
	Fast, // the studio render
	Full, // render mode, path traced
}

// Whether Scene > Render's switch is on: either quality.
render_switch_on :: proc(app: ^App) -> bool {
	return app.studio_on || app.render_on
}

// Puts the render on at `quality`, the other quality off, or with `on` false both off.
render_set :: proc(app: ^App, on: bool, quality: Render_Quality) {
	app.render_quality = quality
	if (on && quality == .Fast) != app.studio_on do studio_toggle(app)
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
		if app.path.pipeline != 0 do render.path_render_destroy(&app.renderer, &app.path)
		return
	}
	// A pass pauses it, keeping what it holds on the device; it starts over once the
	// shaded picture is back, which redraws the viewport.
	if !pass_shaded(app) do return
	samples := int(clamp(app.render_samples, 1, render.RENDER_SAMPLES_MAX))
	bounces := int(clamp(app.render_bounces, 1, render.RENDER_BOUNCES_MAX))
	_ = render.render_frame(&app.renderer, &app.path, cmd, &app.target, view, proj, items, changed, samples, bounces, viewport_lights(app), app.studio_softness, app.exposure, app.render_denoise, app.render_half, render_lens(app), &app.pool, linear = finish_wanted(app), async = render_async(app))
}

// Whether render mode's bands go to the compute queue: Async compute where the device has
// a second queue, or --async-compute wherever the backend has a compute queue at all.
// The pictures (view panes and view windows) keep theirs in the frame by choice.
render_async :: proc(app: ^App) -> bool {
	switch render.caps(&app.renderer).async_compute {
	case .Off:          return false
	case .Same_Queue:   return app.async_compute_run
	case .Second_Queue: return app.async_compute || app.async_compute_run
	}
	return false
}

// Whether render mode still has samples to build, which keeps the frames coming.
render_busy :: proc(app: ^App) -> bool {
	pr := &app.path
	return render_running(app) && pr.refused == "" && pr.samples < int(app.render_samples)
}

// What the Render card's one choice shows: off, or on at a quality.
Render_Show :: enum u8 {
	Off,
	Fast,
	Full,
}

@(rodata)
RENDER_SHOW_NAMES := [Render_Show]string {
	.Off  = "Off",
	.Fast = "Fast",
	.Full = "Full",
}

// What the render shows now.
render_show :: proc(app: ^App) -> Render_Show {
	if !render_switch_on(app) do return .Off
	return .Full if app.render_quality == .Full else .Fast
}

// The Render card's Quality presets: how many samples each quality builds up and, for
// Full, how many times light bounces. Good is each quality's default, so a fresh install
// shows it picked; Final is what a picture to keep wants.
Render_Preset :: enum u8 {
	Draft,
	Good,
	Final,
}

@(rodata)
RENDER_PRESET_NAMES := [Render_Preset]string {
	.Draft = "Draft",
	.Good  = "Good",
	.Final = "Final",
}

@(rodata)
RENDER_PRESETS_FAST := [Render_Preset]i32 {
	.Draft = 64,
	.Good  = STUDIO_SAMPLES_DEFAULT,
	.Final = STUDIO_SAMPLES_MAX,
}

@(rodata)
RENDER_PRESETS_FULL := [Render_Preset][2]i32 {
	.Draft = {256, 3},
	.Good  = {render.RENDER_SAMPLES_DEFAULT, render.RENDER_BOUNCES_DEFAULT},
	.Final = {render.RENDER_SAMPLES_MAX, 8},
}

// The preset the quality's values match exactly, or -1 when they were set by hand.
render_preset_now :: proc(app: ^App) -> int {
	for p in Render_Preset {
		switch app.render_quality {
		case .Fast: if app.studio_samples == RENDER_PRESETS_FAST[p] do return int(p)
		case .Full: if ([2]i32{app.render_samples, app.render_bounces}) == RENDER_PRESETS_FULL[p] do return int(p)
		}
	}
	return -1
}

// Sets the quality's values to preset `p`.
render_preset_set :: proc(app: ^App, p: Render_Preset) {
	switch app.render_quality {
	case .Fast: app.studio_samples = RENDER_PRESETS_FAST[p]
	case .Full: app.render_samples, app.render_bounces = RENDER_PRESETS_FULL[p].x, RENDER_PRESETS_FULL[p].y
	}
}

// The Render card's Render section: one choice of Off, Fast or Full (Blender's and Nomad's
// render toggle as a single control, where a switch beside two tabs made four states for
// three), how far the picture has built up, the Quality preset, then the quality's own
// controls, the exact values under More.
kit_render :: proc(app: ^App) {
	ctx := &app.kit.ctx
	kit_render_show(app)
	// Off has nothing to set: the qualities' controls show once one is picked, so nothing
	// looks live while nothing renders.
	if render_show(app) == .Off {
		ui.paragraph(ctx, "The view is not rendered. Fast lays occlusion and soft shadows over it; Full path traces it.", color = ctx.theme.text_secondary)
		return
	}
	kit_render_progress(app)
	presets: [len(Render_Preset)]string
	for n, i in RENDER_PRESET_NAMES do presets[i] = n
	ui.label(ctx, "Quality", ctx.theme.small_size, ctx.theme.text_tertiary)
	if picked := ui.tabs(ctx, "render preset", presets[:], render_preset_now(app)); picked >= 0 do render_preset_set(app, Render_Preset(picked))
	switch app.render_quality {
	case .Fast: kit_render_fast(app)
	case .Full: kit_render_full(app)
	}
}

// The render's one choice, Off, Fast or Full. The Render card and the shading list both
// draw it, so the view's render is the same control in either place.
kit_render_show :: proc(app: ^App) {
	ctx := &app.kit.ctx
	names: [len(Render_Show)]string
	for n, i in RENDER_SHOW_NAMES do names[i] = n
	hints := [len(Render_Show)]string{"", command_hint(app, .Studio_Render), command_hint(app, .Render_Mode)}
	if picked := ui.tabs(ctx, "render show", names[:], int(render_show(app)), keys = hints[:]); picked >= 0 {
		switch Render_Show(picked) {
		case .Off:  render_set(app, false, app.render_quality)
		case .Fast: render_set(app, true, .Fast)
		// As its command does, so whatever Full turns on with it comes too.
		case .Full: if !app.render_on do command_run(app, .Render_Mode)
		}
	}
}

// How far the picture has built up, as a line and a bar under the choice, or why it is not
// building: the GPU could not set it up, a pass pauses it, or the scene is refused.
@(private = "file")
kit_render_progress :: proc(app: ^App) {
	ctx := &app.kit.ctx
	t := ctx.theme
	note := ""
	done, want: int
	ms: f64
	switch render_show(app) {
	case .Off: return
	case .Fast:
		switch {
		case app.studio.failed:   note = "Fast could not be set up on this GPU; the log says why."
		case !pass_shaded(app):   note = pass_paused_note(app)
		case:                     done, want = app.studio.samples, int(app.studio_samples)
		}
	case .Full:
		pr := &app.path
		switch {
		case pr.failed:           note = "Full could not be set up on this GPU; the log says why. Fast runs on every GPU."
		case !pass_shaded(app):   note = pass_paused_note(app)
		case pr.refused != "":    note = pr.refused
		case:
			done, want = pr.samples, int(app.render_samples)
			ms = pr.total_ms / f64(max(pr.total_samples, 1))
		}
	}
	if note != "" {
		ui.paragraph(ctx, note, color = t.text_secondary)
		return
	}
	done = min(done, want)
	what := "Samples, done" if done >= want else "Samples"
	count := fmt.tprintf("%d / %d · %.0f ms each", done, want, ms) if ms >= 0.5 else fmt.tprintf("%d / %d", done, want)
	ui.value_row(ctx, fmt.tprintf("%s##render progress", what), count)
	bar := ui.area(ctx, "render progress bar", {ui.fill_width(ctx), ui.SPACE_XS})
	share := f32(done) / f32(max(want, 1))
	ui.fill_rect(ctx, bar.rect, ui.SPACE_XS * 0.5, t.track)
	if share > 0 do ui.fill_rect(ctx, {bar.rect.x, bar.rect.y, bar.rect.w * share, bar.rect.h}, ui.SPACE_XS * 0.5, t.accent)
}

// Fast's controls: the studio render's.
@(private = "file")
kit_render_fast :: proc(app: ^App) {
	ctx := &app.kit.ctx
	_ = ui.slider(ctx, "Occlusion", &app.studio_ao, 0, 1, .Linear, fmt.tprintf("%.2f", app.studio_ao))
	_ = ui.slider(ctx, "Shadow", &app.studio_shadow, 0, 1, .Linear, fmt.tprintf("%.2f", app.studio_shadow))
	if kit_more(app, .Render) {
		samples := f32(app.studio_samples)
		if ui.slider(ctx, "Samples", &samples, 16, STUDIO_SAMPLES_MAX, .Logarithmic, fmt.tprintf("%d", app.studio_samples)) do app.studio_samples = i32(samples + 0.5)
		_ = ui.slider(ctx, "Shadow softness", &app.studio_softness, render.STUDIO_SOFTNESS_MIN, render.STUDIO_SOFTNESS_MAX, .Logarithmic, fmt.tprintf("%.1f°", math.to_degrees(app.studio_softness)))
		kit_more_end(app)
	}
	ui.paragraph(ctx, "Fast lays occlusion and soft shadows over the view's own shading while it is still; quick, on every GPU.")
}

// Full's controls: render mode's.
@(private = "file")
kit_render_full :: proc(app: ^App) {
	ctx := &app.kit.ctx
	_ = ui.switch_row(ctx, "Denoise", &app.render_denoise)
	if kit_more(app, .Render) {
		samples := f32(app.render_samples)
		if ui.slider(ctx, "Samples", &samples, 16, render.RENDER_SAMPLES_MAX, .Logarithmic, fmt.tprintf("%d", app.render_samples)) do app.render_samples = i32(samples + 0.5)
		bounces := f32(app.render_bounces)
		if ui.slider(ctx, "Bounces", &bounces, 1, render.RENDER_BOUNCES_MAX, .Linear, fmt.tprintf("%d", app.render_bounces)) do app.render_bounces = i32(bounces + 0.5)
		_ = ui.switch_row(ctx, "Half resolution", &app.render_half)
		kit_more_end(app)
	}
	pr := &app.path
	if render_running(app) && pr.tex_left_out > 0 {
		ui.paragraph(ctx, fmt.tprintf("Full shows the maps of %d textured objects; %d more show their material.", render.render_textured_max(pr), pr.tex_left_out))
	}
	ui.paragraph(ctx, "Full path traces the view while it is still: every light, the environment, materials and bounced light. Half resolution is four times as fast, for tablets.")
}
