package main

import "core:fmt"

import sdl "vendor:sdl3"

import "../sculpt"
import "../ui"
import "../voxel"

// The History panel's Settings page (History revamp H4), after Nomad's history settings:
// the memory the History may use beside the steps it keeps, where the memory goes, which
// changes become steps and how going back behaves. The same blocks stand in Settings >
// Files, so either place changes the one setting.

// Settings: the blocks under their captions, in the panel's width.
kit_history_settings :: proc(app: ^App, width: f32) {
	ctx := &app.kit.ctx
	entries := [?]Settings_Entry{{.Undo_History, "MEMORY"}, {.History_Steps, "WHAT BECOMES A STEP"}, {.History_Back, "GOING BACK"}}
	ui.begin(ctx, "history settings", {direction = .Column, gap = 6, width = width})
	for e in entries {
		ui.caption(ctx, e.caption)
		settings_block(app, e.block)
	}
	ui.end(ctx)
}

// Where the memory goes, as Nomad's memory stats show it: the meshes and their levels, the
// History, the textures, each with a bar against what the device has.
history_memory_rows :: proc(app: ^App) {
	ctx := &app.kit.ctx
	t := ctx.theme
	meshes, textures := 0, 0
	for obj in app.scene.objects {
		if obj.voxel != nil {
			meshes += voxel.clay_bytes(&obj.voxel.clay) - obj.voxel.clay.history.bytes
		} else {
			meshes += sculpt.levels_bytes(&obj.levels)
		}
		textures += textures_bytes(obj.textures)
	}
	history, _ := history_memory(app)
	ram := int(sdl.GetSystemRAM()) << 20
	Row :: struct {
		label:  string,
		bytes:  int,
		colour: ui.Color,
	}
	rows := [?]Row{{"Meshes and levels", meshes, overlay_color(KIND_COLORS[.Mask])}, {"History", history, overlay_color(KIND_COLORS[.Stroke])}, {"Textures", textures, overlay_color(KIND_COLORS[.Transform])}}
	width := ui.fill_width(ctx)
	for r in rows {
		cell := ui.place(ctx, {width, 22})
		mid := cell.y + cell.h * 0.5
		ui.fill_rect(ctx, {cell.x, mid - 4.5, 9, 9}, 2, r.colour)
		ui.text(ctx, r.label, cell.x + 18, mid, t.small_size, t.text_secondary)
		bar := ui.Rect{cell.x + cell.w - 90, mid - 2, 90, 4}
		ui.text(ctx, bytes_label(r.bytes) if r.bytes > 0 else "none", bar.x - 10, mid, t.small_size, t.text if r.bytes > 0 else t.text_tertiary, .Semibold, .Right)
		ui.fill_rect(ctx, bar, 2, t.track)
		if ram > 0 && r.bytes > 0 do ui.fill_rect(ctx, {bar.x, bar.y, max(bar.w * min(f32(r.bytes) / f32(ram), 1), 2), bar.h}, 2, r.colour)
	}
	if ram > 0 do ui.paragraph(ctx, fmt.tprintf("This device has %s of memory in all.", bytes_label(ram)), color = t.text_tertiary)
}
