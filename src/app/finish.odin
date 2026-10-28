package main

import "core:fmt"
import "core:hash"
import "core:math"
import "core:mem"

import "../render"
import "../ui"

// Scene > Finish: the camera's finishing of the picture while the Render switch is on
// (render/finish.odin), as Marmoset Toolbag keeps its tone mapping, white balance,
// vignette and grain on the camera and shows them live, and as Blender's view transform
// and white balance do. They are remembered, as the exposure is, not saved with a scene.
// With every control at its none value, the default, nothing runs and the picture is the
// viewport's to the bit. Sculpting with Render off stays unfinished, so colours picked are
// the colours shown and nothing comes between the form and the eye.

Finish_Settings :: struct {
	curve:         render.Tone_Curve,
	contrast:      f32,
	saturation:    f32,
	kelvin:        f32, // the white balance's temperature: FINISH_KELVIN_NONE leaves it
	tint:          f32, // toward magenta above 0, green below
	vignette:      f32,
	vignette_soft: f32,
	lift:          f32,
	gamma:         f32,
	gain:          f32,
	grain:         f32,
	grain_size:    f32,
}

// Daylight, which the shading's white already is.
FINISH_KELVIN_NONE :: 6500
FINISH_KELVIN_MIN :: 2500
FINISH_KELVIN_MAX :: 12000
// Contrast's range: further either way, an 8-bit source's steps near black would show.
FINISH_CONTRAST_MIN :: 0.7
FINISH_CONTRAST_MAX :: 1.5

FINISH_DEFAULTS :: Finish_Settings{
	curve = .Neutral, contrast = 1, saturation = 1, kelvin = FINISH_KELVIN_NONE, tint = 0,
	vignette = 0, vignette_soft = 0.6, lift = 0, gamma = 1, gain = 1, grain = 0, grain_size = 1.5,
}

// What the finishing stack does with these settings.
finish_look :: proc(f: Finish_Settings) -> render.Finish_Look {
	look := render.Finish_Look{
		curve = f.curve, contrast = f.contrast, saturation = f.saturation, white = {1, 1, 1},
		vignette = f.vignette, vignette_soft = f.vignette_soft, lift = f.lift, gamma = f.gamma, gain = f.gain,
		grain = f.grain, grain_size = f.grain_size,
	}
	if f.kelvin != FINISH_KELVIN_NONE || f.tint != 0 {
		// The light taken as white, against daylight's, so 6500 K is no change at all, its
		// green scaled by the tint as Lightroom's and Blender's tint does.
		a, d := kelvin_rgb(f.kelvin), kelvin_rgb(FINISH_KELVIN_NONE)
		look.white = {a.r / d.r, a.g / d.g * math.pow(2, 0.5 * f.tint), a.b / d.b}
	}
	return look
}

// Whether the picture is finished this frame: the Render switch is on, the viewport is
// shaded (a pass, a wipe or a pane worked in shows unfinished, as each is a look at one
// signal), and a control is away from its none value.
finish_wanted :: proc(app: ^App) -> bool {
	return render_switch_on(app) && pass_shaded(app) && render.finish_active(finish_look(app.finish))
}

// Finishes this frame's picture after everything that makes it (render_viewport, the
// studio, render mode and live occlusion), so viewport_shown, which the panel,
// screenshots, the time-lapse and scene previews read, shows it. `changed` is whether
// anything was redrawn this frame, which with the samples and what was picked names what
// the picture holds, so a still view costs nothing.
finish_view_frame :: proc(app: ^App, cmd: render.Cmd, changed: bool) {
	if changed do app.finish_redraws += 1
	if !finish_wanted(app) {
		render.finish_reset(&app.finished)
		return
	}
	source, linear := finish_source(app)
	look := finish_look(app.finish)
	look.seed = u32(app.finish_redraws)
	_ = render.finish_frame(&app.renderer, &app.finished, cmd, source, app.target.width, app.target.height, linear, look, finish_version(app))
}

// What the finishing stack starts from: render mode's exposed linear light once it shows,
// else what the viewport would show unfinished.
@(private = "file")
finish_source :: proc(app: ^App) -> (source: render.Texture, linear: bool) {
	if render_running(app) && app.path.samples >= RENDER_SHOW_MIN {
		if t := render.render_linear_texture(&app.path); t != nil do return t, true
	}
	if t := viewport_unfinished(app); t != nil do return t, false
	return app.target.color, false
}

// What the source holds besides the texture: the redraws, the studio's samples and
// strengths, render mode's samples and how they were shown, and live occlusion's runs.
@(private = "file")
finish_version :: proc(app: ^App) -> u64 {
	Version :: struct {
		redraws:          u64,
		studio_samples:   int,
		studio_strengths: [2]f32,
		path_samples:     int,
		path_exposure:    f32,
		path_denoised:    bool,
		ao_runs:          int,
		ao_key:           u64,
	}
	v := Version{
		app.finish_redraws, app.studio.samples, app.studio.strengths, app.path.samples, app.path.exposure, app.path.denoised,
		app.live_ao.full + app.live_ao.partial, app.live_ao.key,
	}
	return hash.fnv64a(mem.ptr_to_bytes(&v))
}

// A fingerprint of the finishing a picture of the scene shows, 0 while none: scene
// previews take a new picture when it changes.
finish_fingerprint :: proc(app: ^App) -> u64 {
	if !finish_wanted(app) do return 0
	f := app.finish
	return max(hash.fnv64a(mem.ptr_to_bytes(&f)), 1)
}

// The Reset finish command: every control back to its none value.
finish_reset_command :: proc(app: ^App) {
	app.finish = FINISH_DEFAULTS
}

// The Scene palette's Finish section.
kit_finish :: proc(app: ^App) {
	ctx := &app.kit.ctx
	f := &app.finish
	names := [len(render.Tone_Curve)]string{"Neutral", "AgX", "ACES"}
	if picked := ui.tabs(ctx, "tone curve", names[:], int(f.curve)); picked >= 0 do f.curve = render.Tone_Curve(picked)
	_ = ui.slider(ctx, "Contrast", &f.contrast, FINISH_CONTRAST_MIN, FINISH_CONTRAST_MAX, .Linear, fmt.tprintf("%.2f", f.contrast))
	_ = ui.slider(ctx, "Temperature", &f.kelvin, FINISH_KELVIN_MIN, FINISH_KELVIN_MAX, .Logarithmic, fmt.tprintf("%.0f K", f.kelvin))
	_ = ui.slider(ctx, "Vignette", &f.vignette, 0, 1, .Linear, fmt.tprintf("%.2f", f.vignette))
	_ = ui.slider(ctx, "Grain", &f.grain, 0, 1, .Linear, fmt.tprintf("%.2f", f.grain))
	if kit_more(app, .Finish) {
		_ = ui.slider(ctx, "Saturation", &f.saturation, 0, 2, .Linear, fmt.tprintf("%.2f", f.saturation))
		_ = ui.slider(ctx, "Tint", &f.tint, -1, 1, .Linear, fmt.tprintf("%+.2f", f.tint))
		_ = ui.slider(ctx, "Lift", &f.lift, -0.2, 0.2, .Linear, fmt.tprintf("%+.2f", f.lift))
		_ = ui.slider(ctx, "Gamma", &f.gamma, 0.5, 2, .Logarithmic, fmt.tprintf("%.2f", f.gamma))
		_ = ui.slider(ctx, "Gain", &f.gain, 0.5, 2, .Logarithmic, fmt.tprintf("%.2f", f.gain))
		_ = ui.slider(ctx, "Vignette softness", &f.vignette_soft, 0.05, 1, .Linear, fmt.tprintf("%.2f", f.vignette_soft))
		_ = ui.slider(ctx, "Grain size", &f.grain_size, 1, 4, .Linear, fmt.tprintf("%.1f px", f.grain_size))
		_ = command_button(app, .Finish_Reset, width = ui.fill_width(ctx))
		kit_more_end(app)
	}
	switch {
	case app.finished.failed:
		ui.paragraph(ctx, "Finishing could not be set up on this GPU; the log says why.")
	case !render_switch_on(app) && render.finish_active(finish_look(app.finish)):
		ui.paragraph(ctx, "The finish shows while Render is on.")
	}
	ui.paragraph(ctx, fmt.tprintf("Finishes the picture as a camera does, while Render is on: the tone curve that brings light into the display's range (Neutral keeps picked colours as they are; AgX rolls bright light off over more stops toward white, as film does; ACES gives more contrast and colour), Contrast about mid grey, white balance (Temperature and Tint: a higher temperature warms the picture), a Vignette toward the corners and film Grain. Lift, Gamma and Gain raise the blacks, the midtones and the whites. It shows in screenshots, the time-lapse and the turntable too. %s", command_keys(app, .Finish_Reset)))
}
