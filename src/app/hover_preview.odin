package main

import "core:math"
import "core:time"

import "../geom"
import "../render"
import "../sculpt"

// Hover preview of the dab (Settings > Interface > Hover preview): while the pen or the
// mouse hovers over the model with a brush, the surface under the ring shows what the
// first dab of a stroke pressed there would do, deepened so a faint dab still reads, and
// the higher the pen hovers the fainter it shows. The GPU lays the dab in the mesh's own
// buffers after the frame's sculpting, the viewport draws it, and the buffers are put back
// before the frame's command buffer ends (render.sculpt_gpu_trial, sculpt_gpu_restore): the
// CPU's mesh, the undo, the readbacks and the next frame never see it, and a press the
// next frame starts its stroke from the surface as it is. The screen keeps the preview
// while nothing moves, since a frame that redraws nothing leaves the picture as it was.
//
// It runs only where a stroke's dabs would run on the GPU (Sculpt on the GPU, the brushes
// its kernels lay), for the selected object, with nothing else going on in the view, and
// up to sculpt.HOVER_VERTS_MAX vertices under the brush: past that the ring shows alone.
// It also rests while the tablet says it is warm (device_hot): a warm tablet lowers its
// clocks, which would slow the strokes that follow, and strokes come first.

// How much deeper than a stroke's first dab the preview shows it, with the pen near the
// glass (half of it at the top of its hover range).
HOVER_BOOST :: f32(3)

// What the last drawn preview left on the screen, and its counts for the exit stats.
Hover_Preview :: struct {
	// The buffers the last trial was laid in (compared, never followed) and the box round
	// what it moved in that object's space: the next frame redraws it, empty for none.
	mesh: ^render.Mesh_Buffers,
	box:  geom.Aabb,
	trials, capped: int,
	hot:    int, // frames it rested because the device was warm
	heat_checked: time.Tick, // when the device's warmth was last asked
	warm:   bool, // what it said
	verts:  int, // the last trial's, or past the cap what it would have reached
	amount: f32, // the last trial's first dab's signed amount, negative for an inverted one
	ms:     f64, // the CPU's time for the last trial
}

// Lays this frame's trial when the preview is wanted, and marks the draw items' damage:
// where the last frame's preview stood, which the buffers no longer hold, and where this
// one goes. `drawing` is false on a frame that draws nothing (a rested one), which keeps
// the picture the last frame left. After the frame's sculpting and uploads, before the
// viewport is drawn.
hover_preview_frame :: proc(app: ^App, cmd: render.Cmd, input: Viewport_Input, draws: []render.Draw_Item, drawing: bool) {
	hp := &app.hover
	if !drawing do return
	if hp.mesh != nil {
		for &d in draws do if d.mesh == hp.mesh do d.damage = geom.aabb_union(d.damage, hp.box)
		hp.mesh, hp.box = nil, geom.AABB_EMPTY
	}
	if !hover_preview_wanted(app, input) do return
	obj := selected_object(app)
	s, buffers := sculpt_gpu_trial_target(app, obj)
	if s == nil do return
	start := time.tick_now()
	// Where the ring lies on the selected object: the cursor's point when it found one.
	hit: Vec3
	if app.cursor.ok {
		hit = app.cursor.at
	} else {
		origin, dir := mouse_ray(app.camera, input.mouse_pos, input.size)
		index, at, _, ok := scene_raycast_surface(app, origin, dir, only = stroke_only(app))
		if !ok || index != app.scene.selected do return
		hit = at
	}
	t := obj.transform
	local := to_local(t, hit)
	brush := brush_hovering(app, input, t, local)
	boost := HOVER_BOOST * (1 - 0.5 * clamp(input.pen_hover, 0, 1))
	dabs, verts, ok := sculpt.sculptor_trial_dabs(s, brush, local, boost, context.temp_allocator)
	hp.verts = verts
	if !ok {
		if verts > sculpt.HOVER_VERTS_MAX do hp.capped += 1
		return
	}
	hp.amount = dabs[0].amount
	rdabs, kinds := sculpt_gpu_translate(dabs)
	if !kinds do return
	ranges := sculpt.sculptor_trial_ranges(dabs, context.temp_allocator)
	if !render.sculpt_gpu_trial(&app.renderer, cmd, buffers, rdabs, ranges) do return
	// What the dabs may move: their reach, and as far again for the deepened move.
	box := geom.AABB_EMPTY
	for d in dabs {
		r := 2 * math.sqrt(d.r2)
		box = geom.aabb_union(box, geom.Aabb{d.center - r, d.center + r})
	}
	for &d in draws do if d.mesh == buffers do d.damage = geom.aabb_union(d.damage, box)
	hp.mesh, hp.box = buffers, box
	hp.trials += 1
	hp.ms = time.duration_milliseconds(time.tick_since(start))
}

// Puts the mesh back as it was before this frame's trial, once everything showing the
// preview is drawn and before the frame's command buffer is submitted.
hover_preview_restore :: proc(app: ^App, cmd: render.Cmd) {
	render.sculpt_gpu_restore(&app.renderer, cmd)
}

// Whether the preview shows this frame: switched on, a brush in hand over the model and
// not pressed, a pen hovering or a mouse (a finger has no hover), and nothing else at work
// in the view (a stroke, a gesture's or the adjust's outline, a job, a render, a replay
// or a recording).
hover_preview_wanted :: proc(app: ^App, input: Viewport_Input) -> bool {
	if !app.hover_preview || app.tool != .Brush || app.kit.ctx.input.pointer == .Finger do return false
	if !input.hovered || input.primary || input.dragging do return false
	// A press that would paint the mask, run the hide gesture (smooth and invert together:
	// clip.odin) or leave the button to the view (Alt alone) lays no dab to show.
	m := hover_mods(app)
	if m.mask || (m.smooth && m.invert) || (m.alt && !app.device.ctrl) do return false
	if app.stroke.active || app.stroke_edit.open || app.ui.pie.open || app.clip.active || app.mask_shape.active || app.ui.adjust.kind != .None do return false
	if long_job_busy(app) || replay_busy(app) || studio_running(app) || render_running(app) || timelapse_capturing(app) || turntable_recording(app) do return false
	if device_hot(app) {
		if !app.hover.warm do report(app, Section.Brush, {.Quiet}, "Hover preview rests while the device is warm")
		app.hover.hot += 1
		app.hover.warm = true
		return false
	}
	app.hover.warm = false
	return true
}

// How often the device's warmth is asked: it changes over minutes.
HEAT_CHECK :: time.Second

// Whether the tablet says it is warm enough to lower its clocks: iPadOS's thermal state
// serious or worse, Android's status severe or worse. Asked once a second; never on the
// desktop, which says nothing of it.
device_hot :: proc(app: ^App) -> bool {
	when ODIN_PLATFORM_SUBTARGET_IOS || ODIN_PLATFORM_SUBTARGET == .Android {
		hp := &app.hover
		if hp.heat_checked != {} && time.tick_since(hp.heat_checked) < HEAT_CHECK do return hp.warm
		hp.heat_checked = time.tick_now()
		when ODIN_PLATFORM_SUBTARGET_IOS do return sculpt_ios_thermal() >= 2
		else do return sculpt_android_thermal() >= 3
	} else {
		return false
	}
}

when ODIN_PLATFORM_SUBTARGET_IOS {
	// ios/sculpt_ios.m: NSProcessInfo's thermal state, 0 nominal to 3 critical.
	@(default_calling_convention = "c")
	foreign {
		sculpt_ios_thermal :: proc() -> i32 ---
	}
}

when ODIN_PLATFORM_SUBTARGET == .Android {
	// android/app/jni/android_main.c: Android's thermal status, 0 none to 6 shutdown, -1
	// where Android has none to give (before API 30).
	@(default_calling_convention = "c")
	foreign {
		sculpt_android_thermal :: proc() -> i32 ---
	}
}
