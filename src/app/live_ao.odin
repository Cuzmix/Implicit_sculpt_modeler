package main

import "core:fmt"
import sdl "vendor:sdl3"

import "../render"
import "../ui"

// Live ambient occlusion (stage 4.2, render/live_ao.odin): Scene > Look's
// Occlusion while working darkens creases and contact every frame, sculpting included,
// with the studio render's Occlusion strength. A view setting, as flat shading is: the
// switch is remembered in the settings; its Reach is not.

// Tablets work it out at half size each way, a quarter of the pixels; the blur upsamples it.
LIVE_AO_SCALE :: 2 when ODIN_PLATFORM_SUBTARGET == .Android else 1
// The Reach slider: how far occluders count, as a share of the scene's radius.
LIVE_AO_REACH_DEFAULT :: 0.1
LIVE_AO_REACH_MIN :: 0.01
LIVE_AO_REACH_MAX :: 0.4

// Runs this frame's live occlusion after render_viewport, whose stats are `drawn`, while
// it is on, the studio render's too: the studio shows its own occlusion only once it has
// STUDIO_SHOW_MIN samples, and this shows until then, so sculpting with the studio on
// keeps its occlusion. A still view redraws nothing, which costs it nothing. Off, it
// makes its next run start in full.
live_ao_view_frame :: proc(app: ^App, cmd: ^sdl.GPUCommandBuffer, view, proj: render.Mat4, items: []render.Draw_Item, drawn: render.Viewport_Stats) {
	if !live_ao_wanted(app) {
		render.live_ao_reset(&app.live_ao)
		return
	}
	reach := clamp(app.live_ao_reach, LIVE_AO_REACH_MIN, LIVE_AO_REACH_MAX)
	// The AO pass shows the occlusion alone, at its full strength whatever the studio's is;
	// while wiping, each side of the line at its own pass's strength.
	left, right := live_ao_strengths(app)
	line: f32 = wipe_line_px(app.kit.passes.wipe_at, app.target.width) if wipe_shown(&app.kit) else -1
	_ = render.live_ao_frame(&app.renderer, &app.live_ao, cmd, &app.target, view, proj, items, drawn, reach, left, LIVE_AO_SCALE, right, line)
}

// The texture the viewport shows: render mode's once it has RENDER_SHOW_MIN samples, the
// studio render's while it is on and has samples enough to look better than live
// occlusion, live occlusion's while that is on, then the studio's copy of the viewport,
// else nil for the viewport's own colour. The panel,
// screenshots and the time-lapse all read it, so each shows what the others do.
viewport_shown :: proc(app: ^App) -> ^sdl.GPUTexture {
	// A view pane worked in shows the viewport as it draws, or its live occlusion when it
	// shows AO only.
	if app.kit.grid.work != 0 do return render.live_ao_texture(&app.live_ao) if live_ao_wanted(app) else nil
	if render_running(app) && app.path.samples >= RENDER_SHOW_MIN do return render.render_texture(&app.path)
	studio := studio_running(app)
	if studio && (app.studio.samples >= STUDIO_SHOW_MIN || !live_ao_wanted(app)) do return render.studio_texture(&app.studio)
	if live_ao_wanted(app) do return render.live_ao_texture(&app.live_ao)
	return nil
}

// The studio render's samples before it shows instead of live occlusion: about a quarter
// of a second at 60 frames a second, when its noise has settled below live occlusion's blur.
STUDIO_SHOW_MIN :: 16

// Whether the studio render runs: it is on, the device can run it, and the viewport is
// shaded (a pass pauses it, and it starts over once the shaded picture is back).
studio_running :: proc(app: ^App) -> bool {
	return app.studio_on && !app.studio.failed && pass_shaded(app)
}

// Scene > Look's live occlusion switch, disabled with the reason where the device
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
