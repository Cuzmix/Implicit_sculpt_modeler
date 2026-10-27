package main

import "core:fmt"
import sdl "vendor:sdl3"

import "../render"
import "../ui"

// Live ambient occlusion (stage 4.2, render/live_ao.odin): Scene > Studio render's
// Occlusion while working darkens creases and contact every frame, sculpting included,
// with the studio render's Occlusion strength. A view setting, as flat shading is: the
// switch is remembered in the settings; its Reach is not, as the studio's strengths are not.

// Tablets work it out at half size each way, a quarter of the pixels; the blur upsamples it.
LIVE_AO_SCALE :: 2 when ODIN_PLATFORM_SUBTARGET == .Android else 1
// The Reach slider: how far occluders count, as a share of the scene's radius.
LIVE_AO_REACH_DEFAULT :: 0.1
LIVE_AO_REACH_MIN :: 0.01
LIVE_AO_REACH_MAX :: 0.4

// Runs this frame's live occlusion after render_viewport, whose stats are `drawn`, while
// it is on and the studio render is not (which shows converged occlusion of its own);
// otherwise makes its next run start in full.
live_ao_view_frame :: proc(app: ^App, cmd: ^sdl.GPUCommandBuffer, view, proj: render.Mat4, items: []render.Draw_Item, drawn: render.Viewport_Stats) {
	if !app.live_ao_on || app.studio_on {
		render.live_ao_reset(&app.live_ao)
		return
	}
	reach := clamp(app.live_ao_reach, LIVE_AO_REACH_MIN, LIVE_AO_REACH_MAX)
	_ = render.live_ao_frame(&app.renderer, &app.live_ao, cmd, &app.target, view, proj, items, drawn, reach, app.studio_ao, LIVE_AO_SCALE)
}

// The texture the viewport shows: the studio render's while it is on, live occlusion's
// while that is on, else nil for the viewport's own colour. The panel, screenshots and
// the time-lapse all read it, so each shows what the others do.
viewport_shown :: proc(app: ^App) -> ^sdl.GPUTexture {
	if app.studio_on do return render.studio_texture(&app.studio)
	if app.live_ao_on do return render.live_ao_texture(&app.live_ao)
	return nil
}

// Scene > Studio render's live occlusion switch, disabled with the reason where the device
// cannot read depth in a shader.
kit_live_ao :: proc(app: ^App) {
	ctx := &app.kit.ctx
	supported := render.live_ao_supported(&app.renderer, &app.live_ao)
	on := app.live_ao_on
	if ui.switch_row(ctx, "Occlusion while working", &on, enabled = supported, keys = command_hint(app, .Live_Occlusion)) do command_run(app, .Live_Occlusion)
	switch {
	case !app.renderer.depth_sampled: ui.paragraph(ctx, "Occlusion while working needs a GPU that can read depth in a shader; this one cannot.")
	case !supported:                  ui.paragraph(ctx, "Occlusion while working could not be set up on this GPU; the log says why.")
	}
}

// The Reach slider, under the section's More.
kit_live_ao_reach :: proc(app: ^App) {
	ctx := &app.kit.ctx
	_ = ui.slider(ctx, "Reach", &app.live_ao_reach, LIVE_AO_REACH_MIN, LIVE_AO_REACH_MAX, .Logarithmic, fmt.tprintf("%.3f", app.live_ao_reach))
}
