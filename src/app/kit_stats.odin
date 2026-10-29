package main

import "core:fmt"

import "../sculpt"
import "../ui"

// The Stats panel (F11, Menu > Stats, Settings > System). Simple, it says how
// smoothly the app runs in plain words, grouped as performance, mesh and memory; Advanced,
// it shows every measurement by the name the app prints on exit (`ui_ms` and so on) with
// its p50 and p99, the drawing switches for comparing speed, and what the brush costs.
// Every number is one the app measured: nothing is estimated. It is a window that starts
// at the top left, clear of the size and strength sliders, and fades in and out. Returns
// true when a press landed on it, to bring it to the front.
kit_stats :: proc(app: ^App) -> (raised: bool) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	shown := ui.presence(ctx, panel_id(Kit_Window.Stats), k.stats, t.panel_time)
	if shown <= 0 do return
	s := &app.stats
	win := &k.windows[.Stats]
	points, _ := ui.prev_layout(ctx, "points")
	mark := ui.vertex_mark(ctx)
	p := panel_begin(app, Kit_Window.Stats, "Statistics", .Start, .Start, {kit_left(app), TOP_BAR_H + 4 + points.y + 8}, {direction = .Column, gap = 2, padding = 12, width = KIT_STATS_W, radius = t.radius_large, background = .Panel, inert = !k.stats}, "F11")
	raised = p.raised
	if p.closed do k.stats = false
	slide := window_slide(ctx, win^, .Start) * (1 - shown) * 16
	if !p.body {
		panel_end(app, &p)
		ui.transform_since(ctx, mark, shown, 1, {}, {slide, 0})
		return
	}
	detail := [2]string{"Simple", "Advanced"}
	if picked := ui.tabs(ctx, "detail", detail[:], int(k.stats_advanced)); picked >= 0 do k.stats_advanced = picked == 1
	ui.spacer(ctx, 4)
	if !k.stats_advanced {
		kit_stats_simple(app)
		panel_end(app, &p)
		ui.transform_since(ctx, mark, shown, 1, {}, {slide, 0})
		return
	}
	ring :: proc(ctx: ^ui.Context, label: string, r: Sample_Ring, unit: string) {
		if r.count == 0 {
			ui.value_row(ctx, label, "not measured yet")
			return
		}
		p50, p99 := ring_percentiles(r)
		ui.value_row(ctx, label, fmt.tprintf("p50 %.2f   p99 %.2f %s", p50, p99, unit))
	}

	if ui.section(ctx, "Frame", &k.open[.Frame]) {
		ring(ctx, "Frame  frame_ms", s.frame_ms, "ms")
		ring(ctx, "CPU  cpu_ms", s.cpu_ms, "ms")
		if app.time_gpu do ring(ctx, "GPU (3D)  gpu_ms", s.gpu_ms, "ms")
		ring(ctx, "Display wait  wait_ms", s.wait_ms, "ms")
		ring(ctx, "Interface  ui_ms", s.ui_ms, "ms")
		ui.value_row(ctx, "Interface vertices  ui_vertices", fmt.tprintf("%d", s.ui_vertices))
		ring(ctx, "Brush ring  cursor_ms", s.cursor_ms, "ms")
		ui.plot(ctx, s.frame_ms.values[:], s.frame_ms.head, 0, 33.3, 64, "frame ms")
		ui.section_end(ctx)
	}

	if ui.section(ctx, "Drawing", &k.open[.Drawing]) {
		v := s.viewport
		frame_rate_controls(app, explain = false)
		if ui.switch_row(ctx, "Time GPU work", &app.time_gpu) do s.gpu_ms = {}
		ui.paragraph(ctx, "Waits for the GPU every frame.")
		ui.value_row(ctx, "Triangles drawn", fmt.tprintf("%s in %d draws", count_label(int(v.triangles)), v.draws))
		_ = ui.switch_row(ctx, "Redraw only changes", &app.renderer.partial)
		if v.partial {
			ui.paragraph(ctx, fmt.tprintf("Last frame: %.1f%% of the viewport.", 100 * f64(v.redrawn_px) / f64(max(app.target.width * app.target.height, 1))))
		} else {
			ui.paragraph(ctx, "Last frame: a full redraw.")
		}
		_ = ui.switch_row(ctx, "Skip hidden chunks", &app.renderer.cull)
		ui.paragraph(ctx, fmt.tprintf("%d off screen, %d facing away, %.2f ms.", v.culled_view, v.culled_back, v.cull_ms))
		_ = ui.switch_row(ctx, "Cache idle objects", &app.cache_idle)
		ui.paragraph(ctx, fmt.tprintf("%s, redrawn %d times.", "In use" if v.cache_used else "Not in use", s.cache_redraws))
		_ = ui.switch_row(ctx, "Simplify while moving", &app.simplify)
		pending := 0
		for obj in app.scene.objects do pending += sculpt.sculptor_lod_pending(object_sculptor(obj))
		if pending > 0 && app.simplify {
			ui.paragraph(ctx, fmt.tprintf("%d groups to build.", pending))
		} else {
			ui.paragraph(ctx, fmt.tprintf("Last frame: %d groups simplified.", v.simplified))
		}
		if app.simplify {
			_ = ui.slider(ctx, "Largest error", &app.simplify_px, 0.25, 4, .Linear, fmt.tprintf("%.2f px", app.simplify_px))
			ring(ctx, "Build", s.lod_ms, "ms")
		}
		ui.section_end(ctx)
	}

	if ui.section(ctx, "While sculpting", &k.open[.Sculpting]) {
		ring(ctx, "Raycast  raycast_ms", s.raycast_ms, "ms")
		ring(ctx, "Brush  brush_ms", s.brush_ms, "ms")
		ring(ctx, "Normals  normals_ms", s.normals_ms, "ms")
		ring(ctx, "Upload  upload_kb", s.upload_kb, "KB")
		ring(ctx, "Input to submit  latency_ms", s.latency_ms, "ms")
		ui.value_row(ctx, "Dabs", fmt.tprintf("%d", s.dabs_total))
		// The pointer's samples a stroke's frame brought, and how many of them a tablet's
		// bridge added to SDL's (pen_samples.odin): one a frame on a tablet means samples lost.
		if p := app.pen_samples; p.frames > 0 {
			ui.value_row(ctx, "Samples a frame  samples_frame_mean", fmt.tprintf("%.1f, most %d", f64(p.total) / f64(p.frames), p.most))
			ui.value_row(ctx, "Pen samples recovered  samples_coalesced", fmt.tprintf("%d", p.coalesced))
		}
		ui.value_row(ctx, "Viewport", fmt.tprintf("%d x %d px", app.target.width, app.target.height))
		undo_bytes := 0
		for obj in app.scene.objects {
			for lv in obj.levels.levels do undo_bytes += sculpt.sculptor_undo_bytes(&lv.sculptor)
			if w := obj.levels.hd.window; w != nil do undo_bytes += sculpt.sculptor_undo_bytes(&w.sculptor)
		}
		ui.value_row(ctx, "Undo", fmt.tprintf("%d steps", len(app.history.done)))
		ui.value_row(ctx, "Strokes kept", fmt.tprintf("%.1f MB", f64(undo_bytes) / (1 << 20)))
		ui.value_row(ctx, "Object snapshots", fmt.tprintf("%.1f MB", f64(app.history.swap_bytes) / (1 << 20)))
		ui.section_end(ctx)
	}
	kit_stats_last(app)
	kit_stats_help(app)
	panel_end(app, &p)
	ui.transform_since(ctx, mark, shown, 1, {}, {slide, 0})
	return
}

// The Stats panel's width: room for a label and its p50 and p99 side by side.
KIT_STATS_W :: 340

// The simple view: how smoothly the app runs, the mesh, and the memory it measures, in
// plain words with their units spelled out.
@(private = "file")
kit_stats_simple :: proc(app: ^App) {
	ctx := &app.kit.ctx
	s := &app.stats
	ms :: proc(v: f32) -> string {return fmt.tprintf("%.2f ms", v)}

	ui.caption(ctx, "PERFORMANCE")
	frame50, frame99 := ring_percentiles(s.frame_ms)
	// Frames per second are the frame time turned over: the same measurement, not another.
	if frame50 > 0 do ui.value_row(ctx, "Frame rate", fmt.tprintf("%.0f frames per second", 1000 / frame50))
	ui.value_row(ctx, "Frame time, typical", ms(frame50))
	ui.value_row(ctx, "Frame time, slower moments", ms(frame99))
	ui50, ui99 := ring_percentiles(s.ui_ms)
	ui.value_row(ctx, "Interface update, typical", ms(ui50))
	ui.value_row(ctx, "Interface update, slower moments", ms(ui99))
	if app.time_gpu {
		gpu50, _ := ring_percentiles(s.gpu_ms)
		ui.value_row(ctx, "3D drawing on the GPU, typical", ms(gpu50))
	}
	switch app.frame_rate {
	case .Match_Display: ui.paragraph(ctx, "Frame rate is Match display, so the frame time includes waiting for the screen: it sits near the screen's refresh time even when the app has time to spare.")
	case .Limit:         ui.paragraph(ctx, "Frame rate is limited, so the frame time includes waiting for the limit even when the app has time to spare.")
	case .Unlimited:
	}

	if s.brush_ms.count > 0 {
		ui.spacer(ctx, 6)
		ui.caption(ctx, "WHILE SCULPTING")
		brush50, _ := ring_percentiles(s.brush_ms)
		ui.value_row(ctx, "Brush work per frame, typical", ms(brush50))
		lat50, lat99 := ring_percentiles(s.latency_ms)
		ui.value_row(ctx, "Input to the GPU, typical", ms(lat50))
		ui.value_row(ctx, "Input to the GPU, slower moments", ms(lat99))
	}

	ui.spacer(ctx, 6)
	ui.caption(ctx, "MESH")
	vertices, triangles := 0, 0
	for obj in app.scene.objects {
		vertices += object_vertex_count(obj)
		triangles += object_triangle_count(obj)
	}
	ui.value_row(ctx, "Objects", fmt.tprintf("%d", len(app.scene.objects)))
	ui.value_row(ctx, "Mesh vertices", thousands(vertices))
	ui.value_row(ctx, "Mesh triangles", thousands(triangles))
	if obj := selected_object(app); obj != nil && len(app.scene.objects) > 1 {
		ui.value_row(ctx, fmt.tprintf("%s, vertices", object_label(obj)), thousands(object_vertex_count(obj)))
	}
	// Nothing is drawn while nothing in the view changes: the last picture is shown again.
	drawn := thousands(int(s.viewport.triangles)) if s.viewport.triangles > 0 else "none, view unchanged"
	ui.value_row(ctx, "Triangles drawn last frame", drawn)

	ui.spacer(ctx, 6)
	ui.caption(ctx, "MEMORY")
	undo_bytes := app.history.swap_bytes
	for obj in app.scene.objects {
		for lv in obj.levels.levels do undo_bytes += sculpt.sculptor_undo_bytes(&lv.sculptor)
		if w := obj.levels.hd.window; w != nil do undo_bytes += sculpt.sculptor_undo_bytes(&w.sculptor)
	}
	ui.value_row(ctx, "Undo history", fmt.tprintf("%.1f MB in %d steps", f64(undo_bytes) / (1 << 20), len(app.history.done)))
	ui.paragraph(ctx, "The memory the whole app uses is not measured yet, so it is not shown.")
	kit_stats_last(app)
	kit_stats_help(app)
}

// What the last operation did and how long it took, as its toast or section said.
@(private = "file")
kit_stats_last :: proc(app: ^App) {
	r := app.result
	if r.text == "" do return
	ctx := &app.kit.ctx
	ui.spacer(ctx, 6)
	ui.caption(ctx, "LAST OPERATION")
	ui.paragraph(ctx, r.text)
	if r.detail != "" do ui.paragraph(ctx, r.detail)
}

// What "typical" and "slower moments" (p50 and p99) mean, folded until asked for: a
// tooltip would never show to a finger.
@(private = "file")
kit_stats_help :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	ui.spacer(ctx, 4)
	if ui.section(ctx, "What do these numbers mean?", &k.open[.Stats_Help]) {
		ui.paragraph(ctx, "Times are in milliseconds (ms), thousandths of a second; at 60 frames per second each frame has 16.7 ms.")
		ui.paragraph(ctx, fmt.tprintf("Typical is the median, p50, of the last %d frames: half took less, half took more.", HISTORY))
		ui.paragraph(ctx, "Slower moments is the 99th percentile, p99: 99 in every 100 frames took this long or less. It shows the hitches without being the single slowest frame.")
		ui.paragraph(ctx, "Interface update is only the time to lay out the panels: one part of a frame, not the whole of it, and not on its own a measure of how fast the app is.")
		ui.section_end(ctx)
	}
}

// `n` with thousands apart: 1,250,000.
thousands :: proc(n: int) -> string {
	digits := fmt.tprintf("%d", n)
	out := make([dynamic]u8, 0, len(digits) + len(digits) / 3, context.temp_allocator)
	for c, i in transmute([]u8)digits {
		if i > 0 && (len(digits) - i) % 3 == 0 do append(&out, ',')
		append(&out, c)
	}
	return string(out[:])
}
