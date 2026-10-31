package main

import "core:log"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"

import "../camera"
import "../geom"
import "../render"
import "../sculpt"
import "../ui"

// One frame of the run's loop, in the order it happens: what the last frame asked for
// is applied (scene commands, files, scripts, jobs), the display is waited for and the
// swapchain acquired, the events are read, the tools act, the 3D view is drawn, then the
// interface over it, and the frame is timed. run (main.odin) sets the app up, calls this
// until it stops running, and tears it down; what a frame needs from the set-up and what
// carries from one frame to the next is in Frame_Loop.

// What a frame needs from run's set-up, and what carries over from one frame to the next.
Frame_Loop :: struct {
	opts:          ^Options,
	window:        ^Window,
	main_window:   sdl.WindowID, // the view windows' events go to them, the rest to this one
	bench:         ^Gpubench,
	driven:        bool, // a run a person drives, which rests when idle; a scripted one keeps every frame
	frame_index:   int,
	bench_skipped: int, // frames --bench-after-autosave held the stroke back
	// The previous frame's, kept while timing the GPU so the next frame can wait for it.
	present_fence: render.Fence,
}

frame_step :: proc(app: ^App, loop: ^Frame_Loop) -> bool {
	idle_rest(app, loop.driven)
	frame_start := time.tick_now()
	// Before this frame records anything: the GPU times of a frame a few back.
	if times, ok := render.timestamps_frame(&app.renderer); ok {
		for span in times.ran do ring_push(&app.stats.gpu_spans[span], times.ms[span])
	}
	render.gpu_cull_frame(&app.renderer)
	setting_up := frame_settle(app, loop) or_return
	// Wait for the display, or the frame rate limit, and while timing the GPU for the
	// previous frame too, before reading input: the frame then shows the newest input
	// rather than input that sat through the wait. Changing the present mode recreates
	// the swapchain, so frame_pace runs before this frame acquires a swapchain texture.
	wait_start := time.tick_now()
	frame_pace(app, loop.window)
	render.fence_finish(&app.renderer, &loop.present_fence)
	present_cmd := render.cmd_begin(&app.renderer)
	if present_cmd == nil do return false
	swapchain, swapchain_size, acquired := render.swapchain_acquire(present_cmd, loop.window, wait = true)
	if !acquired {
		_ = render.cmd_cancel(present_cmd)
		return false
	}
	waited := time.tick_since(wait_start)
	// The acquire learned which earlier frames reached the screen.
	shown: [8]render.Present_Time
	for t in shown[:render.present_times(&app.renderer, loop.window, shown[:])] {
		ring_push(&app.stats.display_ms, f64(t.shown_ns - t.input_ns) / 1e6)
	}

	frame_events(app, loop, setting_up)
	// After the frame's events, so that a report still queued counts as the pen heard.
	pencil_leave(app)
	device_frame_end(&app.device)
	pencil_frame(app)
	pen_samples_frame_end(app)
	// Nothing below may change the scene while the autosave thread reads it.
	autosave_guard(app)

	// Resize to the size the interface asked for last frame, before it references the
	// texture, so it never draws a texture released this frame.
	want := app.ui.viewport_request
	msaa_apply(app)
	if !msaa_viewport_resize(app, u32(want.x), u32(want.y)) do return false

	// A tap's dab that waited for a second tap plays before anything this frame does.
	// A tap waiting to land lands nowhere while a job holds the scene.
	if long_job_busy(app) do app.dab_wait.active = false
	waited_dab := dab_wait_resolve(app)
	ui_start := time.tick_now()
	input := kit_frame(app, loop.window)
	if !grid_work_gpu(app) do return false
	cross_fade_gpu(app)
	view_windows_layout(app)
	ring_push(&app.stats.ui_ms, time.duration_milliseconds(time.tick_since(ui_start)))
	bench_waits := loop.opts.bench_after_autosave && app.autosave.written == 0 && !autosave_writing(app)
	if bench_waits && !setting_up do loop.bench_skipped += 1
	bench_frame := loop.frame_index - loop.bench_skipped
	if loop.opts.bench_stroke > 0 && bench_frame < loop.opts.bench_stroke && !bench_waits && !setting_up {
		input = bench_input(app, bench_frame, loop.opts.bench_stroke, loop.opts.bench_samples, loop.opts.bench_loops, {loop.opts.bench_tilt, 0}, {f32(app.target.width), f32(app.target.height)})
		// A lifted frame ends the stroke; the next frame presses again.
		if every := loop.opts.bench_stroke / (loop.opts.bench_lifts + 1); loop.opts.bench_lifts > 0 && every > 0 && (bench_frame + 1) % every == 0 {
			input.primary = false
		}
		app.device.input_at = sdl.GetTicksNS()
	} else if loop.opts.gpubench != "" {
		input = gpubench_input(app, loop.bench, {f32(app.target.width), f32(app.target.height)})
		app.device.input_at = sdl.GetTicksNS()
	}
	camera_ease_frame(app, input)
	camera_apply_input(app, input)
	if loop.opts.orbit && !setting_up do camera.orbit_spin(&app.camera, 2 * math.PI / 240)
	sculpted: Sculpt_Frame_Result
	// While a job holds the scene no tool acts on the view: a press there only says to
	// wait (the camera above still turns).
	job_holds := long_job_busy(app)
	if !job_holds do shape_pending_frame(app, input.size)
	// A gizmo drag the tool changed under ends as it is.
	if app.tool != .Move do move_end(app)
	// A press that picks a polygroup for its material (Pick a group), a colour (the
	// Eyedropper) or the point in focus (Pick focus), or moves a light in the
	// viewport, is no tool's.
	if job_holds {
		brush_stroke_finish(app)
		if input.press do long_job_refuse(app)
	} else if group_pick_frame(app, input) || eyedropper_frame(app, input) || focus_pick_frame(app, input) || lights_viewport_frame(app, input) {
		brush_stroke_finish(app)
	} else {
		// A drag the tool changed under ends as it stands, one undo step.
		if app.tool != .Model && app.model.drag.state != .None do model_drag_end(app)
		switch app.tool {
		case .Brush:
			if clip_frame(app, input) || mask_shape_frame(app, input) {
				brush_stroke_finish(app)
			} else if replay_busy(app) {
				// A replay sculpts in place of the pointer.
				sculpted = replay_frame(app, input)
			} else {
				replay_frame_begin(app)
				sculpted = sculpt_frame(app, input)
				replay_record(app, input, sculpted)
			}
		case .Move:
			replay_stop(app)
			brush_stroke_finish(app)
			move_tool_frame(app, input)
		case .Curve:
			brush_stroke_finish(app)
			if !curve_tool_frame(app, input) do return false
		case .Insert:
			brush_stroke_finish(app)
			if !insert_tool_frame(app, input) do return false
		case .Model:
			replay_stop(app)
			brush_stroke_finish(app)
			if !model_tool_frame(app, input) do return false
		}
	}
	sculpted.dabs += waited_dab.dabs
	sculpted.raycast_ms += waited_dab.raycast_ms
	sculpted.brush_ms += waited_dab.brush_ms
	cursor_predict_frame(app, input)
	cursor_update(app, input)
	draw_viewport_overlay(app, input)
	// No pass is open yet, so a pack matcap first shown this frame can be uploaded
	// (with its own command buffer) and drawn with now.
	pack_matcaps_settle(app)
	// Likewise a finished environment decode, whose prefilter has its own.
	_ = environment_poll(app)

	// The 3D viewport goes in its own command buffer, submitted ahead of the one that
	// presents, so its GPU time can be measured on its own.
	cmd := render.cmd_begin(&app.renderer)
	if cmd == nil {
		_ = render.cmd_submit(present_cmd) // holds a swapchain texture: cannot be cancelled
		return false
	}
	uploaded: int // bytes
	normals_ms: f64
	lod_ms := -1.0 // time building simplified copies; none built when negative
	if !boolean_live_update(app) {
		_ = render.cmd_submit(cmd)
		_ = render.cmd_submit(present_cmd)
		return false
	}
	draws := make([dynamic]render.Draw_Item, 0, 2 * len(app.scene.objects) + 1, context.temp_allocator)
	// What each item was made from, for the main view's shading to make it again.
	froms := make([dynamic]Item_From, 0, 2 * len(app.scene.objects) + 1, context.temp_allocator)
	for obj, i in app.scene.objects {
		// A curve is drawn by the overlay (curve_object.odin).
		if !object_draws_triangles(obj) do continue
		if vp := obj.voxel; vp != nil {
			// A voxel object draws its clay's surface, remeshed where the frame's dabs landed.
			t_flush := time.tick_now()
			bytes, damage, uploaded_ok := voxel_upload(app, cmd, obj, vp)
			normals_ms += time.duration_milliseconds(time.tick_since(t_flush))
			if !uploaded_ok {
				_ = render.cmd_submit(cmd)
				_ = render.cmd_submit(present_cmd)
				return false
			}
			uploaded += bytes
			flash_damage(app, obj, damage)
			if !object_shown(app, obj) || boolean_hides(app, obj, i) || len(vp.clay.surface.chunks) == 0 do continue
			color, live, selected := object_draw_tint(app, obj, i)
			material := object_material(app, obj)
			append(&froms, Item_From{obj = obj, index = i, tint = color, material = material})
			append(&draws, render.Draw_Item {
				mesh      = &vp.gpu,
				model     = transform_matrix(obj.transform),
				color     = color,
				material  = material.shading,
				surface   = {material.metallic, material.roughness},
				flat      = app.flat,
				look      = object_look(app, selected),
				style     = viewport_style(app),
				matcap    = material_matcap(app, material),
				lights    = viewport_lights(app),
				wireframe = app.wireframe && app.polyframe_lines,
				live      = live,
				source    = &vp.clay.surface.mesh,
				chunks    = vp.clay.surface.chunks[:],
				damage    = damage,
			})
			continue
		}
		// An object sculpting HD shows its top level around the window.
		parts := [2]^sculpt.Level{sculpt.levels_current(&obj.levels), obj.levels.hd.window}
		gpus := [2]^render.Mesh_Buffers{&obj.gpu[obj.levels.current], &obj.hd_gpu}
		for lv, part in parts {
			if lv == nil do continue
			gpu := gpus[part]
			t_flush := time.tick_now()
			ranges := sculpt.sculptor_flush(&lv.sculptor)
			normals_ms += time.duration_milliseconds(time.tick_since(t_flush))
			flash_damage(app, obj, lv.sculptor.changed_bounds)
			bytes, uploaded_ok := level_upload(app, cmd, gpu, lv, ranges)
			if !uploaded_ok {
				_ = render.cmd_submit(cmd)
				_ = render.cmd_submit(present_cmd)
				return false
			}
			uploaded += bytes
			// The textured preview follows the base level as this frame uploaded it.
			textured: ^render.Textured_Mesh
			if part == 0 do textured = texture_preview_frame(app, cmd, obj, gpu)
			// Simplified copies the end of the last frame built (lod_build_frame) go up
			// now; gpubench builds every one here before it measures anything.
			if app.simplify && app.lod_finish && !app.stroke.active && sculpt.sculptor_lod_pending(&lv.sculptor) > 0 {
				t_lod := time.tick_now()
				_, _ = sculpt.sculptor_lod_update(&lv.sculptor, finish = true)
				lod_ms = time.duration_milliseconds(time.tick_since(t_lod))
			}
			if lod_ranges, all := sculpt.sculptor_lod_uploads(&lv.sculptor); len(lod_ranges) > 0 || all {
				render.mesh_buffers_upload_lod(&app.renderer, cmd, gpu, lv.sculptor.lod.indices[:], lod_ranges, all, len(lv.mesh.indices) / 2)
				sculpt.sculptor_lod_uploaded(&lv.sculptor)
			}
			// An object out of view still uploads above, so it is current when shown again.
			if !object_shown(app, obj) do continue
			// The live boolean's preview stands in for it (drawn below).
			if boolean_hides(app, obj, i) do continue
			color, live, selected := object_draw_tint(app, obj, i)
			material := object_material(app, obj)
			// Polygon edges stand in for the triangles' edges on a level that has them: the
			// Wireframe overlay's here, a view in Wireframe's in its shading_items.
			poly_edges := part == 0 && poly_edges_shown(app, obj)
			poly_lines := poly_edges && app.wireframe && app.polyframe_lines
			append(&froms, Item_From{obj = obj, index = i, tint = color, material = material, base_map = textured != nil && textured.maps[.Base_Color] != nil, poly_edges = poly_edges})
			if textured != nil do color = textured_color(color, material, app.texture_view == .Textured && textured.maps[.Base_Color] != nil)
			// The groups are made first: the stamps say when.
			chunk_groups := sculpt.sculptor_chunk_groups(&lv.sculptor)
			group_stamps, chunk_layout := sculpt.sculptor_chunk_stamps(&lv.sculptor)
			append(&draws, render.Draw_Item {
				mesh   = gpu,
				textured = textured,
				// Off while only Material Preview asks for the preview: its shading turns it on.
				texture_view = app.texture_view if textured != nil else .Off,
				model  = transform_matrix(obj.transform),
				color  = color,
				material = material.shading,
				surface = {material.metallic, material.roughness},
				flat = app.flat || obj.cage != nil,
				look = object_look(app, selected),
				style = viewport_style(app),
				lights = viewport_lights(app),
				matcap = material_matcap(app, material),
				wireframe = app.wireframe && app.polyframe_lines && !poly_edges,
				paint  = sculpt.sculptor_has_color(&lv.sculptor) && !obj.paint_off,
				groups = (app.show_groups || app.wireframe && app.polyframe_fill) && sculpt.sculptor_has_groups(&lv.sculptor),
				// A cage shows its edges, and its faces flat, as a polygon model does; the
				// wireframe of a level with polygons shows their edges the same way.
				cage_lines = obj.cage != nil || poly_lines,
				// The HD window's mesh carries no groups.
				slots  = object_material_slots(app, obj, i) if part == 0 && sculpt.sculptor_has_groups(&lv.sculptor) else nil,
				live   = live,
				source = &lv.mesh,
				chunks = lv.sculptor.chunks,
				chunk_groups = chunk_groups,
				group_stamps = group_stamps,
				chunk_layout = chunk_layout,
				damage = lv.sculptor.changed_bounds,
				// A textured item's wireframe follows its full triangles, never a simplified copy.
				lod    = lv.sculptor.lod.tree if textured == nil else {},
				hidden = sculpt.levels_hd_hidden(&obj.levels) if part == 0 && obj.levels.hd.window != nil else sculpt.sculptor_hidden_units(&lv.sculptor),
			})
		}
	}
	flash_frame_end(app)
	// After the uploads, so the preview measures the mesh as this frame draws it.
	if checker := rebuild_preview_frame(app); checker != {} {
		for &d in draws do if d.live do d.checker = checker
	}
	if b := &app.ui.boolean; b.shown {
		if base := object_by_id(app, b.base); base != nil && object_shown(app, base) {
			material := object_material(app, base)
			color := material.selected
			if _, ghost := object_flags(app, base); ghost do color.rgb *= GHOST_SHADE
			// Drawn as the selected object is, whichever its index.
			append(&froms, Item_From{obj = base, index = app.scene.selected, tint = color, material = material})
			append(&draws, render.Draw_Item {
				mesh     = &b.preview,
				source   = &b.preview_mesh,
				model    = transform_matrix(base.transform),
				color    = color,
				material = material.shading,
				surface  = {material.metallic, material.roughness},
				flat     = app.flat,
				look     = viewport_look(app),
				style    = viewport_style(app),
				lights   = viewport_lights(app),
				matcap   = material_matcap(app, material),
				damage   = geom.AABB_EMPTY,
			})
		}
	}
	aspect := f32(app.target.width) / f32(app.target.height)
	view, proj := camera.orbit_view(app.camera), camera.orbit_proj(app.camera, aspect)
	// The main view's role lent to a view pane or given back is no turn of the view: what
	// either pane shows was already at rest, so neither is simplified for it.
	travelled := app.kit.grid.work_began || app.kit.grid.work_ended != 0
	if view_changed(app, view, proj) && !travelled do app.view_moved = time.tick_now()
	moving := time.tick_since(app.view_moved) < LOD_SETTLE
	app.renderer.lod_px = app.simplify_px if app.simplify && moving && !timelapse_capturing(app) && !turntable_recording(app) else 0
	app.renderer.floor = floor_grid_frame(app)
	app.renderer.background = background_frame(app.background)
	environment_view(app)
	// A pass with a ground of its own shows it instead of the background or the
	// environment's image, and a Silhouette stands on nothing, as the thumbnail's does.
	app.kit.passes.recording = timelapse_capturing(app) || turntable_recording(app)
	shown_pass := viewport_pass(&app.kit)
	// The main view draws its own copy of the items, shaded as its shading says; the
	// other views and pictures below take them as the materials made them and shade
	// their own. A view pane worked in shows its own shading here.
	raw := draws
	draws = make([dynamic]render.Draw_Item, len(raw), context.temp_allocator)
	copy(draws[:], raw[:])
	shading, pane := main_draw_shading(app)
	shading_items(app, draws[:], froms[:], shading, pane)
	if wipe_shown(&app.kit) {
		pass_items(draws[:], view, shading_pass(app, shading, shown_pass, pane), shading_pass(app, shading, wipe_right(&app.kit), pane), wipe_line_px(app.kit.passes.wipe_at, app.target.width))
	} else {
		pass_items(draws[:], view, shading_pass(app, shading, shown_pass, pane))
	}
	if ground, ok := pass_ground(shown_pass); ok {
		app.renderer.background = ground
		app.renderer.environment_look.background = false
	}
	if shown_pass == .Silhouette do app.renderer.floor = {}
	// The view pane worked in looks as its own picture does at rest (picture_frame): on its
	// pass's ground or the scene's (the background's colour alone for a heavy pass), a
	// silhouette without wires or paint.
	if app.kit.grid.work != 0 {
		// A heavy pass's picture stands on the background's colour alone.
		if second_pass_heavy(app.kit.grid.views[app.kit.grid.work - 1].pass) {
			app.renderer.floor = {}
			if _, own := pass_ground(shown_pass); !own {
				top := app.renderer.background.top
				app.renderer.background = {top, top}
				app.renderer.environment_look.background = false
			}
		}
		if shown_pass == .Silhouette {
			for &d in draws {
				d.wireframe, d.paint, d.groups = false, false, false
				d.matcap, d.textured, d.slots = nil, nil, nil
				d.checker = {}
			}
		}
	}
	drawn := render.render_viewport(&app.renderer, cmd, &app.target, view, proj, draws[:], app.cache_idle)
	// Anything redrawn this frame starts the samples over.
	changed := !drawn.partial || drawn.redrawn_px > 0
	// Live occlusion first: the studio shows its picture where samples it carried across a
	// turn of the view are still too few.
	live_ao_view_frame(app, cmd, view, proj, draws[:], drawn)
	// A change of Ray tracing hardware starts the studio's samples over the other way.
	if rq := app.ray_query && !app.no_ray_query_run; rq != app.renderer.ray_query {
		app.renderer.ray_query = rq
		render.studio_reset(&app.studio)
	}
	if studio_running(app) {
		// Render mode takes the GPU while it runs; the studio waits, keeping what it built.
		studio_max := 0 if render_running(app) else int(app.studio_samples)
		under := render.live_ao_texture(&app.live_ao) if live_ao_wanted(app) else nil
		_ = render.studio_frame(&app.renderer, &app.studio, cmd, &app.target, view, proj, draws[:], changed, studio_max, app.studio_ao, app.studio_shadow, viewport_lights(app), &app.pool, app.studio_softness, under)
	}
	render_mode_frame(app, cmd, view, proj, draws[:], changed)
	finish_view_frame(app, cmd, changed)
	// A --dump-viewport run's last frame draws its transparent picture, when that is on.
	if loop.opts.dump_viewport != "" && app.screenshot_transparent && loop.opts.frames > 0 && loop.frame_index == loop.opts.frames - 1 do capture_request(app, loop.opts.dump_viewport)
	capture_frame(app, cmd, view, proj, draws[:])
	// What follows draws its own views of the scene, as the materials made them.
	draws = raw

	nav_head_frame(app, cmd)
	thumbs_frame(app, cmd)
	home_frame(app, cmd)
	app.pictures_drawn = 0
	thumbnail_frame(app, cmd, draws[:], froms[:])
	grid_frame(app, cmd, draws[:], froms[:])
	view_windows_pictures(app, cmd, draws[:], froms[:])
	step_pictures_frame(app, cmd, view, proj, draws[:])
	layer_pictures_frame(app, cmd, draws[:])

	gpu_wait: time.Duration
	if app.time_gpu {
		// Nothing else is queued (the previous frame was waited for above), so the
		// time from submit to the fence is the GPU time of this work.
		submit_start := time.tick_now()
		fence := render.cmd_submit_fenced(cmd)
		if fence == nil {
			_ = render.cmd_submit(present_cmd)
			return false
		}
		render.fence_finish(&app.renderer, &fence)
		gpu_wait = time.tick_since(submit_start)
		ring_push(&app.stats.gpu_ms, time.duration_milliseconds(gpu_wait))
	} else if !render.cmd_submit(cmd) {
		_ = render.cmd_submit(present_cmd)
		return false
	}

	// The interface, the viewport image in it, into the swapchain.
	kit_ready := false
	if swapchain != nil {
		kit_ready = kit_upload(app, present_cmd)
	} else {
		_ = ui.frame_end(&app.kit.ctx)
	}
	app.stats.ui_vertices = len(app.kit.ctx.draw.vertices)
	// Once ui.frame_end settled the held control and the field with the keys.
	diag_frame(app)
	// The pass clears the image even when the interface could not be uploaded, so a
	// failed upload shows an empty frame rather than whatever the image held.
	if swapchain != nil {
		draws := kit_draws(app, &app.kit.ctx.draw) if kit_ready else nil
		render.ui_present(&app.renderer, &app.kit.pass, present_cmd, loop.window, swapchain, swapchain_size, kit_frame_color(&app.kit), draws, kit_ready)
	}
	app.kit_drew = kit_ready
	app.kit_size = swapchain_size
	// Some drivers wait for the display here rather than when the swapchain texture
	// is acquired, so this counts as waiting too.
	// The frames that changed the mesh are timed to the screen, as latency_ms is to the submit.
	render.present_input(&app.renderer, loop.window, app.device.input_at if sculpted.dabs > 0 else 0)
	present_start := time.tick_now()
	submitted := false
	if app.time_gpu {
		loop.present_fence = render.cmd_submit_fenced(present_cmd)
		submitted = loop.present_fence != nil
	} else {
		submitted = render.cmd_submit(present_cmd)
	}
	if !submitted do return false

	submitted_ns := sdl.GetTicksNS()
	waited += time.tick_since(present_start)
	view_windows_present(app)

	frame_time := time.tick_since(frame_start)
	cpu_time := frame_time - waited - gpu_wait
	ring_push(&app.stats.frame_ms, time.duration_milliseconds(frame_time))
	ring_push(&app.stats.wait_ms, time.duration_milliseconds(waited))
	ring_push(&app.stats.cpu_ms, time.duration_milliseconds(cpu_time))
	app.stats.viewport = drawn
	app.stats.cache_redraws += int(drawn.cache_redrawn)
	app.stats.partial_frames += int(drawn.partial)
	idle_note(app, drawn, sculpted.dabs)
	if sculpted.dabs > 0 {
		ring_push(&app.stats.raycast_ms, sculpted.raycast_ms)
		ring_push(&app.stats.brush_ms, sculpted.brush_ms)
		ring_push(&app.stats.normals_ms, normals_ms)
		ring_push(&app.stats.upload_kb, f64(uploaded) / 1024)
		ring_push(&app.stats.latency_ms, f64(submitted_ns - app.device.input_at) / 1e6)
		app.stats.dabs_total += sculpted.dabs
	}
	// A scripted stroke or replay changes the scene with no input to show for it.
	app.autosave.scripted = (loop.opts.bench_stroke > 0 && !bench_waits && bench_frame < loop.opts.bench_stroke) || loop.opts.gpubench != "" ||
		(loop.opts.load_strokes != "" && loop.frame_index <= max(loop.opts.bench_stroke, LOAD_STROKES_FRAME)) || (loop.opts.timelapse != "" && loop.frame_index <= loop.opts.bench_stroke)
	capture_finish(app)
	preview_frame(app)
	autosave_frame(app)
	// After the submit, in the time the frame would otherwise wait for the display:
	// building copies then adds nothing between the pen and the screen.
	if !app.lod_finish do lod_ms = lod_build_frame(app, frame_start)
	if lod_ms >= 0 do ring_push(&app.stats.lod_ms, lod_ms)
	free_all(context.temp_allocator)

	if setting_up do app.script.frames += 1
	else do loop.frame_index += 1
	if (loop.opts.frames > 0 && loop.frame_index >= loop.opts.frames) || (loop.opts.bench_stroke > 0 && loop.frame_index - loop.bench_skipped >= loop.opts.bench_stroke) {
		// A --timelapse run goes on until the recording is done.
		// So does one replaying --load-strokes, which starts the frame after.
		replaying := replay_busy(app) || (loop.opts.load_strokes != "" && loop.frame_index <= max(loop.opts.bench_stroke, LOAD_STROKES_FRAME))
		// And a --turntable run until its last frame is written.
		if (loop.opts.timelapse == "" || (loop.frame_index > loop.opts.bench_stroke && !timeline_busy(app))) && !replaying && !turntable_recording(app) do app.running = false
	}
	if loop.opts.gpubench != "" && gpubench_end_frame(app, loop.bench, time.duration_milliseconds(gpu_wait), time.duration_milliseconds(cpu_time), f64(submitted_ns - app.device.input_at) / 1e6, f64(uploaded) / 1024, sculpted.dabs) {
		app.running = false
		if !gpubench_write(app, loop.bench) do return false
	}
	return true
}

// What the last frame and the set-up asked for, applied before this frame reads input:
// a waiting save, the scene command, the long job, content packs and the Blender link,
// a file request, view windows opening and closing, the selection kept in reach, the
// start-up script and plugins, and the scripted starts (time-lapse, turntable, a stroke
// file). setting_up is whether the start-up script is still setting the run up; done is
// false when a step failed and the run stops.
frame_settle :: proc(app: ^App, loop: ^Frame_Loop) -> (setting_up: bool, done: bool) {
	// A waiting save or export goes first: before a scene command or file request
	// changes what it would write. A second Save during a save (Ctrl+S again) is
	// dropped by file_apply.
	file_next := file_pending_kind()
	saves := bit_set[File_Kind]{.Save, .Save_Copy}
	save_pending(app, app.ui.scene_command.kind != .None || (file_next != .None && !(file_next in saves && app.saving.kind in saves)))
	// The scene holds still while a job runs on it (long_job.odin).
	if app.ui.scene_command.kind != .None && long_job_busy(app) {
		app.ui.scene_command = {}
		long_job_refuse(app)
	}
	if command := app.ui.scene_command; command.kind != .None {
		app.ui.scene_command = {}
		autosave_settle(app)
		// A command being recorded counts once it changed the scene (macros.odin).
		before := script_scene_state(app) if app.macro.pending.active else {}
		if !scene_run(app, command) do return false, false
		if app.macro.pending.active do macro_settle(app, script_scene_state(app) != before)
	}
	if !long_job_frame(app) do return false, false
	library_frame(app)
	link_frame(app)
	if req, ok := file_take(app); ok {
		autosave_settle(app)
		inspector_drags_end(app)
		applied := file_apply(app, req)
		file_request_free(req)
		if !applied do return false, false
	}
	// View windows open and close here, before this frame acquires anything to draw into.
	view_windows_settle(app)
	// Whatever changed the scene last frame (a command, a file, an undo), the
	// selection stays on an object in view and in reach.
	scene_folders_normalize(app)
	scene_selection_fix(app)
	materials_settle(app)
	textures_settle(app)
	if !script_frame(app) do return false, false
	if !plugins_frame(app) do return false, false
	// Until the script is done its frames are set-up: the run's own count from where
	// it ends (--frames, the bench stroke, --load-strokes, --timelapse, --ui-events).
	setting_up = app.script.running && app.script.setup
	if loop.opts.timelapse != "" && loop.frame_index == loop.opts.bench_stroke && !setting_up {
		if loop.opts.timelapse_steps > 0 do app.timeline.lapse.steps = i32(loop.opts.timelapse_steps)
		app.timeline.lapse.spin = loop.opts.timelapse_spin
		timelapse_start(app, loop.opts.timelapse)
	}
	// At the run's last frame, so that what led up to it (a script, a stroke) is done.
	if loop.opts.turntable != "" && loop.frame_index == max(loop.opts.frames - 1, loop.opts.bench_stroke, 0) && !setting_up && !turntable_recording(app) && app.turntable.frame == 0 {
		if loop.opts.turntable_frames > 0 do app.turntable_frames = i32(loop.opts.turntable_frames)
		turntable_start(app, loop.opts.turntable)
	}
	if loop.opts.load_strokes != "" && loop.frame_index == max(loop.opts.bench_stroke, LOAD_STROKES_FRAME) && !setting_up {
		if !strokes_load(app, loop.opts.load_strokes) do return false, false
		if loop.opts.replay_shift != "" {
			shift: [2]f32
			parts := strings.split(loop.opts.replay_shift, ",", context.temp_allocator)
			ok := len(parts) == 2
			for part, i in parts {
				if i >= 2 do break
				v, parsed := strconv.parse_f32(strings.trim_space(part))
				shift[i], ok = v, ok && parsed
			}
			if !ok {
				log.errorf("--replay-shift wants two pixel counts, like 120,-40")
				return false, false
			}
			replay_start(app, &app.replay.take, true, take_start(&app.replay.take) + shift)
		} else {
			replay_start(app, &app.replay.take)
		}
	}
	timeline_frame(app)
	turntable_frame(app)
	history_cap(app)
	// A point or spot light a script or an undo just made gets its place.
	lights_settle(app)
	// The shown objects' polygon edges for the wireframe, before any command buffer
	// of this frame is open (the upload waits for the copy).
	poly_edges_frame(app)
	camera_history_frame(app)
	return setting_up, true
}

// The frame's events: the pointer's samples and the pen's state start afresh, the
// scripted events go in (once the set-up is done), and SDL's events are read, each going
// to a view window, the input diagnostics, the pie's Space, the peek's backquote, the
// labels' question mark, the pencil, the device and touch, or the window.
frame_events :: proc(app: ^App, loop: ^Frame_Loop, setting_up: bool) {
	// Every pointer sample, not only where the pointer ended up, so the brush can
	// follow the whole path. A pen also sends mouse events, marked PEN_MOUSEID; its
	// pressure arrives separately as an axis event.
	clear(&app.samples)
	app.pen_roll = 0
	device_frame_begin(&app.device)
	view_windows_frame_begin(app)
	// Scripted events count from the end of the set-up, and none go in before it.
	if !setting_up do kit_events_push(app, loop.window)
	e: sdl.Event
	for sdl.PollEvent(&e) {
		app.idle.events += 1
		pencil_heard(app, &e)
		if view_windows_event(app, &e, loop.main_window) do continue
		// Before anything below takes the event for itself (Space, the backquote, the pencil).
		diag_event(app, &e)
		// Space over the viewport is the brush pie's (pie.odin) rather than a key of the
		// frame; once it went down there, its release is the pie's too.
		if (e.type == .KEY_DOWN || e.type == .KEY_UP) && e.key.scancode == .SPACE {
			pie := &app.ui.pie
			if pie.space_down || (e.key.down && app.ui.viewport_hovered && !typing(app)) {
				// A tap's dab waiting for a second tap plays before the pie opens.
				if e.key.down do app.dab_wait.play = true
				if e.key.down && !e.key.repeat do pie.space_pressed = true
				if !e.key.down do pie.space_released = true
				pie.space_down = e.key.down
				continue
			}
		}
		// A held backquote peeks at the last other pass (passes.odin) until it is let go;
		// once it went down outside typing, its release is the peek's too.
		if (e.type == .KEY_DOWN || e.type == .KEY_UP) && key_of(e.key.key) == KEY_GRAVE {
			ps := &app.kit.passes
			if ps.key_held || (e.key.down && !typing(app)) {
				ps.key_held = e.key.down
				continue
			}
		}
		if help_labels_key(app, &e) do continue
		if e.type == .WINDOW_FOCUS_LOST do app.kit.passes.key_held, app.kit.labels.key_held = false, false
		if pencil_event(app, &e) || pen_samples_event(app, &e) do continue
		if pen_hover_under_finger(app, &e) do continue
		device_event(&app.device, &e)
		dab_wait_event(app, &e, loop.window)
		touch_event(app, &e, loop.window)
		#partial switch e.type {
		case .QUIT, .WINDOW_CLOSE_REQUESTED:
			app.running = false
		case .WINDOW_FOCUS_GAINED:
			link_focus(app)
		case .DROP_FILE:
			if e.drop.data != nil do file_drop(app, string(e.drop.data))
		case .SCREEN_KEYBOARD_HIDDEN:
			app.kit.keyboard_down = true
		case .SCREEN_KEYBOARD_SHOWN:
			app.kit.keyboard_down = false
		case .DID_ENTER_FOREGROUND:
			// The window comes back with a new surface, which has to ask for its frame rate again.
			app.pacer.voted_window = nil
			app.preview.background = false
			pencil_only_read(app)
		case .DID_ENTER_BACKGROUND:
			// The system may end the app from the background without another word.
			if app.settings_file != "" do _ = settings_save(app, app.settings_file)
			app.autosave.background = true
			app.preview.background = true
		case .MOUSE_MOTION:
			// The pen's samples between frames (pen_samples.odin) go in ahead of its own.
			if e.motion.which == sdl.PEN_MOUSEID do pen_samples_motion(app, {e.motion.x, e.motion.y})
			else do append(&app.samples, Input_Sample{{e.motion.x, e.motion.y}, 1, .Move, {}})
		case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
			if e.button.button == sdl.BUTTON_LEFT {
				kind := Sample_Kind.Press if e.button.down else .Release
				if e.button.which == sdl.PEN_MOUSEID do pen_samples_button(app, {e.button.x, e.button.y}, kind)
				else do append(&app.samples, Input_Sample{{e.button.x, e.button.y}, 1, kind, {}})
			}
		case .PEN_AXIS:
			#partial switch e.paxis.axis {
			case .PRESSURE:
				app.pen_pressure = e.paxis.value
				pen_samples_axes(app)
			case .XTILT, .YTILT:
				pencil_tilt_take(app, e.paxis.axis, e.paxis.value)
				pen_samples_axes(app)
			case .ROTATION:
				pen_roll_take(app, pencil_roll_degrees(e.paxis.value))
			case .DISTANCE:
				app.pen_distance = clamp(e.paxis.value, 0, 1)
			}
			app.pen_seen = true
		case .PEN_PROXIMITY_OUT:
			// A pen brought back may be turned otherwise: its first report starts afresh.
			app.pen_roll_last = nil
			app.pen_distance = 0
		}
	}
}

// Builds simplified copies for the first object level that waits for any, a batch or
// more, in the time left of the frame the display allows (the refresh with vsync, the
// limit with a limit; LOD_FRAME_BUDGET at most, and that when there is no beat). Never
// during a stroke, whose frames should stay as short as they can be. What it builds goes
// up in the next frame's uploads. Returns the time it took, negative when it built nothing.
lod_build_frame :: proc(app: ^App, frame_start: time.Tick) -> f64 {
	if !app.simplify || app.stroke.active do return -1
	for obj in app.scene.objects {
		if obj.voxel != nil do continue
		parts := [2]^sculpt.Level{sculpt.levels_current(&obj.levels), obj.levels.hd.window}
		for lv in parts {
			if lv == nil || sculpt.sculptor_lod_pending(&lv.sculptor) == 0 do continue
			start := time.tick_now()
			_, _ = sculpt.sculptor_lod_update(&lv.sculptor, budget = lod_budget(app, frame_start))
			return time.duration_milliseconds(time.tick_since(start))
		}
	}
	return -1
}

// Whether any object level still waits for simplified copies: the frames that build
// them are work, so the app does not rest while they wait (idle_note).
lod_waiting :: proc(app: ^App) -> bool {
	if !app.simplify do return false
	for obj in app.scene.objects {
		if obj.voxel != nil do continue
		if sculpt.sculptor_lod_pending(&sculpt.levels_current(&obj.levels).sculptor) > 0 do return true
		if w := obj.levels.hd.window; w != nil && sculpt.sculptor_lod_pending(&w.sculptor) > 0 do return true
	}
	return false
}

// LOD_FRAME_BUDGET, or less where the display sets a beat: what is left of it after the
// frame so far, keeping LOD_SLACK for the next frame to start in time.
LOD_SLACK :: 1 * time.Millisecond

lod_budget :: proc(app: ^App, frame_start: time.Tick) -> time.Duration {
	// While the view moves the copies are what it lacks: a frame drawing everything is
	// slow and leaves no spare time, so the copies take the whole budget and arrive in
	// seconds rather than a batch a frame.
	if time.tick_since(app.view_moved) < LOD_SETTLE do return sculpt.LOD_FRAME_BUDGET
	hz: f32
	switch app.frame_rate {
	case .Match_Display: hz = display_refresh(app.window)
	case .Limit:         hz = f32(clamp(app.frame_limit, FRAME_LIMIT_MIN, FRAME_LIMIT_MAX))
	case .Unlimited:
	}
	if hz <= 0 do return sculpt.LOD_FRAME_BUDGET
	left := time.Duration(1e9 / f64(hz)) - time.tick_since(frame_start) - LOD_SLACK
	return clamp(left, 0, sculpt.LOD_FRAME_BUDGET)
}
