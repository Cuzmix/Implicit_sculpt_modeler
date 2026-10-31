package main

import "core:hash"
import "core:log"
import "core:math"


import "../camera"
import "../render"
import "../ui"

// Cross-fades (the overhaul's round 3, PR 13): when the main view's pass or look changes,
// or a long job swaps a new mesh in, the picture the view showed a moment before stays over
// it and fades out, so the change reads as a change of the same view rather than a jump.
// Blender, ZBrush and Nomad cut to the new shading at once; a short dissolve keeps the eye
// on the form while the shading changes under it, and costs one texture copy.
//
// The kept picture is a copy of the texture the main pane showed last frame, made on the
// GPU before this frame draws over it (as the still a worked view pane leaves behind,
// grid_work_gpu), and the interface draws it over the viewport with an alpha that falls
// from 1 to 0. No shader or buffer changes: the interface's image draw already tints.
// The fade belongs to one camera: the first turn, zoom or resize ends it, since an old
// picture over a moving view is a ghost, not a dissolve.

Cross_Fade :: struct {
	still:     render.Viewport_Target, // the picture that fades out
	on:        bool,
	kind:      Motion_Kind, // .Look_Fade or .Mesh_Fade
	at:        f64, // the interface's clock when it began
	copy:      bool, // the still is to be copied before this frame draws
	camera:    camera.Orbit, // the view it belongs to
	key:       u64, // the pass and look as the last frame's interface ended
	keyed:     bool,
	// What the main pane showed last frame, at what size: the source of the next still.
	last:      render.Texture,
	last_size: [2]u32,
	// For the exit stats.
	looks:     int,
	meshes:    int,
}

// How long each fade runs: a look change is a glance, a new mesh a little longer, so the
// eye catches what the rebuild changed.
LOOK_FADE_SECONDS :: 0.25
MESH_FADE_SECONDS :: 0.4

// The image id the interface draws the fading picture with.
KIT_FADE_STILL_IMAGE :: KIT_WORK_STILL_IMAGE + 1

// What decides how the main view looks, as far as a change of it fades: the pass, the
// material, the shading switches and the render switch. Sliders (cavity, rim, lights,
// background colours) are left out: a drag changes them every frame, and a fade per frame is
// no fade.
look_key :: proc(app: ^App) -> u64 {
	Look_Key :: struct {
		pass:         render.View_Pass,
		material:     int,
		texture_view: render.Texture_View,
		styled, render_on, studio_on, live_ao_on, wireframe, flat, groups, gradient: bool,
	}
	key := Look_Key{
		pass = viewport_pass(&app.kit), material = app.material, texture_view = app.texture_view,
		styled = app.styled, render_on = app.render_on, studio_on = app.studio_on, live_ao_on = app.live_ao_on,
		wireframe = app.wireframe, flat = app.flat, groups = app.show_groups, gradient = app.background.gradient,
	}
	return hash.fnv64a(([^]u8)(&key)[:size_of(key)])
}

// Starts a fade of `kind` from what the main pane showed last frame, unless that kind of
// motion is off, a view pane is worked in, the camera is driven by a recording, a replay or
// the timeline, or last frame's picture is gone or of another size.
cross_fade_start :: proc(app: ^App, kind: Motion_Kind) {
	f := &app.cross_fade
	if ui.motion_duration(&app.kit.ctx, motion_class(kind), 1) <= 0 do return
	if app.kit.grid.work != 0 || turntable_recording(app) || timeline_busy(app) || replay_busy(app) do return
	if f.last == nil || f.last_size != {app.target.width, app.target.height} || !cross_fade_source_alive(app, f.last) do return
	f.on, f.kind, f.at, f.copy, f.camera = true, kind, app.kit.ctx.time, true, app.camera
	if kind == .Look_Fade do f.looks += 1
	else do f.meshes += 1
}

// Whether `tex` is still a texture the viewport owns: the target's colour or one of the
// pictures shown in its place. A switch turned off this frame may have released its own.
@(private = "file")
cross_fade_source_alive :: proc(app: ^App, tex: render.Texture) -> bool {
	return tex == app.target.color || tex == render.finish_texture(&app.finished) || tex == render.studio_texture(&app.studio) ||
		tex == render.live_ao_texture(&app.live_ao) || tex == render.render_texture(&app.path)
}

// How much of the old picture shows now, 1 to 0, eased out; 0 once the fade is over or the
// view moved, which ends it.
cross_fade_alpha :: proc(app: ^App) -> f32 {
	f := &app.cross_fade
	if !f.on do return 0
	run := ui.motion_duration(&app.kit.ctx, motion_class(f.kind), LOOK_FADE_SECONDS if f.kind == .Look_Fade else MESH_FADE_SECONDS)
	t := f32(app.kit.ctx.time - f.at) / max(run, 1e-6)
	if run <= 0 || t >= 1 || t < 0 || f.camera != app.camera || app.kit.grid.work != 0 {
		f.on = false
		return 0
	}
	// Ease out: most of the change shows at once, the last of the old picture lingers.
	return 1 - math.sqrt(t)
}

// Over the main pane at `r`, right after its picture: the fading picture. Drawn every frame
// the main pane shows, so a fade that starts later this frame (cross_fade_frame_end) has
// its quad; its alpha is set as the frame's interface is uploaded (cross_fade_tint), and it
// is not drawn at all while no fade runs (kit_draws).
cross_fade_draw :: proc(app: ^App, r: ui.Rect) {
	ui.image(&app.kit.ctx, r, KIT_FADE_STILL_IMAGE)
}

// At the end of the frame's interface: a pass or look changed since last frame starts a
// fade, its quad already drawn, so the old picture covers this frame's new one whole.
cross_fade_frame_end :: proc(app: ^App) {
	f := &app.cross_fade
	key := look_key(app)
	if f.keyed && key != f.key && app.kit.frame > 2 do cross_fade_start(app, .Look_Fade)
	f.key, f.keyed = key, true
}

// After the interface, before anything this frame draws: copies last frame's picture into
// the still when a fade began this frame.
cross_fade_gpu :: proc(app: ^App) {
	f := &app.cross_fade
	if !f.copy do return
	f.copy = false
	if !render.viewport_copy(&app.renderer, &f.still, f.last, f.last_size.x, f.last_size.y) {
		log.warnf("cross-fade: no copy of the last picture: %s", platform_error())
		f.on = false
	}
}

// Sets the fading picture's alpha in the frame's interface (`dl`, as it is uploaded).
cross_fade_tint :: proc(app: ^App, dl: ^ui.Draw_List) {
	a := u8(math.round(cross_fade_alpha(app) * 255))
	for c in dl.cmds {
		if c.texture != .Image || c.image != KIT_FADE_STILL_IMAGE do continue
		for i in dl.indices[c.first_index:][:c.index_count] do dl.vertices[i].color.a = a
	}
}

// What the main pane shows this frame, for the next fade's still.
cross_fade_shown :: proc(app: ^App, shown: render.Texture) {
	app.cross_fade.last, app.cross_fade.last_size = shown, {app.target.width, app.target.height}
}

cross_fade_destroy :: proc(app: ^App) {
	render.viewport_target_destroy(&app.renderer, &app.cross_fade.still)
}
