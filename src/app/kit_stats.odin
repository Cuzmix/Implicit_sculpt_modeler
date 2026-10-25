package main

import "core:fmt"

import "../sculpt"
import "../ui"

// The Stats panel (F11, Menu > Stats): what each frame costs, the drawing shortcuts that
// can be switched off for comparison, and what the brush costs while sculpting. It
// floats at the top left, clear of the size and strength sliders, and fades in and out.
kit_stats :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	shown := ui.presence(ctx, ui.id_of(ctx, "stats"), k.stats, t.panel_time)
	if shown <= 0 do return
	s := &app.stats
	sliders, _ := ui.prev_layout(ctx, "sliders")
	mark := ui.vertex_mark(ctx)
	ui.begin_anchored(ctx, "stats", .Start, .Start, {t.edge + sliders.x + 8, t.edge + t.target + 8}, {direction = .Column, gap = 2, padding = 12, width = KIT_STATS_W, radius = t.radius_large, background = .Panel, inert = !k.stats})
	ui.caption(ctx, "STATS")
	ring :: proc(ctx: ^ui.Context, label: string, r: Sample_Ring, unit: string) {
		p50, p99 := ring_percentiles(r)
		ui.value_row(ctx, label, fmt.tprintf("p50 %.2f   p99 %.2f %s", p50, p99, unit))
	}

	if ui.section(ctx, "Frame", &k.open[.Frame]) {
		ring(ctx, "Frame", s.frame_ms, "ms")
		ring(ctx, "CPU", s.cpu_ms, "ms")
		if app.time_gpu do ring(ctx, "GPU (3D)", s.gpu_ms, "ms")
		ring(ctx, "Display wait", s.wait_ms, "ms")
		ring(ctx, "Interface", s.ui_ms, "ms")
		ui.plot(ctx, s.frame_ms.values[:], s.frame_ms.head, 0, 33.3, 64, "frame ms")
		ui.section_end(ctx)
	}

	if ui.section(ctx, "Drawing", &k.open[.Drawing]) {
		v := s.viewport
		_ = ui.switch_row(ctx, "VSync", &app.vsync)
		switch app.renderer.present_mode {
		case .VSYNC:     ui.paragraph(ctx, "Frame rate capped at the display's.")
		case .MAILBOX:   ui.paragraph(ctx, "Off: mailbox.")
		case .IMMEDIATE: ui.paragraph(ctx, "Off: immediate, may tear.")
		}
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
		ring(ctx, "Raycast", s.raycast_ms, "ms")
		ring(ctx, "Brush", s.brush_ms, "ms")
		ring(ctx, "Normals", s.normals_ms, "ms")
		ring(ctx, "Upload", s.upload_kb, "KB")
		ring(ctx, "Input to submit", s.latency_ms, "ms")
		ui.value_row(ctx, "Dabs", fmt.tprintf("%d", s.dabs_total))
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
	ui.end(ctx)
	ui.transform_since(ctx, mark, shown, 1, {}, {-(1 - shown) * 16, 0})
}

// The Stats panel's width: room for a label and its p50 and p99 side by side.
KIT_STATS_W :: 320
