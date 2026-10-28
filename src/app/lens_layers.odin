package main

import "core:fmt"

import "../sculpt"
import "../ui"

// Lens's Layers card (round 2 of the mockups, screen scene2): the selected object's
// layers newest on top, each a row with its eye, its name, its strength and a dot that is
// red while it records; the picked row is taller and holds the strength slider. Under them
// Base, the surface the layers sit on, which says "locked" while a layer records (strokes
// then go only into that layer), then New layer and the layer options. Classic's tray
// keeps its section (kit_layers_section).

// A layer row's height, in points; the picked one is as tall as its slider makes it.
LAYER_ROW_H :: 40

// The record dot's red, as the mock has it; a hollow circle (ICON_CIRCLE) while the
// layer does not record.
LAYER_RECORD_COLOR :: ui.Color{240, 106, 94, 255}

// The card's content, as the stack draws it.
kit_lens_layers :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	obj := selected_object(app)
	k.layer_rows = 0
	if obj == nil {
		ui.paragraph(ctx, "Add or select an object first.")
		return
	}
	allowed := layers_allowed(obj)
	s := object_sculptor(obj)
	layers := sculpt.sculptor_layers(s)
	selected := &app.ui.layer_selected
	selected^ = clamp(selected^, 0, max(len(layers) - 1, 0))
	recording := sculpt.sculptor_layer_recording(s)
	width := ui.fill_width(ctx)
	for i := len(layers) - 1; i >= 0; i -= 1 {
		l := &layers[i]
		picked := i == selected^
		name := fmt.tprintf("lens layer %d", i)
		// The picked row's tint, where the row was laid out last frame.
		if picked {
			if r := ui.prev_rect(ctx, name); r.w > 0 do ui.fill_rect(ctx, r, t.radius_medium, ui.color_fade(t.accent, 0.16))
		}
		ui.begin(ctx, name, {direction = .Column, width = width, height = 0 if picked else LAYER_ROW_H})
		ui.begin(ctx, fmt.tprintf("lens layer %d head", i), {direction = .Row, center = true, gap = 0})
		if ui.icon_button(ctx, fmt.tprintf("Show or hide##lens layer %d", i), ui.ICON_EYE if l.visible else ui.ICON_EYE_OFF, enabled = allowed, size = LAYER_ROW_H) {
			stroke_finish(app)
			_ = sculpt.sculptor_layer_set(s, i, l.strength, !l.visible)
			if sculpt.sculptor_stroke_end(s) do history_record(app, obj, .Layer, "Show layer" if l.visible else "Hide layer")
		}
		rec := recording == i
		// The name and the strength: a tap picks the layer.
		a := ui.area(ctx, fmt.tprintf("%s##lens layer pick %d", sculpt.sculptor_layer_name(l), i), {width - 2 * LAYER_ROW_H, LAYER_ROW_H})
		mid := a.rect.y + a.rect.h * 0.5
		if a.hovered && !picked do ui.fill_rect(ctx, a.rect, t.radius_small, t.fill_hover)
		fg := t.text if l.visible else t.text_secondary
		ui.text(ctx, ui.text_fit(ctx, sculpt.sculptor_layer_name(l), t.text_size, a.rect.w - 60, .Semibold if picked else .Regular), a.rect.x + 4, mid, t.text_size, fg, .Semibold if picked else .Regular)
		// The picked row's slider says its strength, so its head does not again.
		if !picked do ui.text(ctx, fmt.tprintf("%.2f", l.strength), a.rect.x + a.rect.w - 6, mid, t.small_size, t.text_tertiary, .Regular, .Right)
		if a.clicked do selected^ = i
		// The record dot: red while strokes go into the layer; a tap records or stops.
		d := ui.area(ctx, fmt.tprintf("Record into this layer##lens layer %d", i), {LAYER_ROW_H, LAYER_ROW_H})
		dc := [2]f32{d.rect.x + d.rect.w * 0.5, d.rect.y + d.rect.h * 0.5}
		if rec do ui.fill_circle(ctx, dc, 5, LAYER_RECORD_COLOR)
		else do ui.icon(ctx, ICON_CIRCLE, dc, t.icon_small - 2, t.text_tertiary if d.hovered else ui.color_fade(t.text_tertiary, 0.6))
		ui.tip(ctx, d.id, d.rect, "Stop recording" if rec else "Record into this layer")
		if d.clicked && allowed {
			stroke_finish(app)
			if sculpt.sculptor_layer_record(s, -1 if rec else i) do history_record(app, obj, .Layer, "Stop recording" if rec else "Record into layer")
			selected^ = i
		}
		ui.end(ctx)
		if picked do lens_layer_strength(app, obj, i, width)
		ui.end(ctx)
		k.layer_rows += 1
	}
	// Base: the surface under the layers.
	ui.begin(ctx, "lens layer base", {direction = .Row, center = true, width = width, height = LAYER_ROW_H})
	base := ui.place(ctx, {width, LAYER_ROW_H})
	mid := base.y + base.h * 0.5
	ui.icon(ctx, ICON_LOCK if recording >= 0 else ui.ICON_FRAME, {base.x + LAYER_ROW_H * 0.5, mid}, t.icon_small, t.text_secondary)
	ui.text(ctx, "Base", base.x + LAYER_ROW_H + 4, mid, t.text_size, t.text)
	ui.text(ctx, "locked" if recording >= 0 else "base", base.x + base.w - LAYER_ROW_H - 6, mid, t.small_size, t.text_tertiary, .Regular, .Right)
	ui.end(ctx)
	_ = command_button(app, .New_Layer, variant = .Light, tone = .Accent, glyph = ui.ICON_PLUS, width = width)
	if len(layers) > 0 && kit_more(app, .Layers) {
		l := &layers[selected^]
		layer_name := l.name
		if ui.text_field(ctx, fmt.tprintf("name##lens layer %d", selected^), layer_name[:], width, hint = "Name") {
			n := 0
			for n < len(layer_name) && layer_name[n] != 0 do n += 1
			sculpt.sculptor_layer_rename(s, selected^, string(layer_name[:n]))
			app.scene_edits += 1
		}
		dropped, baked := kit_button_pair(ctx, "Delete", "Bake", allowed, allowed, .Danger)
		if dropped do layer_remove(app, obj, selected^, bake = false)
		if baked do layer_remove(app, obj, selected^, bake = true)
		kit_command_pair(app, .Layer_Edit, .Layer_Edit, int(Layer_Action.Duplicate), int(Layer_Action.Invert), "Duplicate", "Invert")
		kit_command_pair(app, .Layer_Edit, .Layer_Edit, int(Layer_Action.Merge_Down), int(Layer_Action.Bake_All), "Merge down", "Bake all")
		kit_command_pair(app, .Layer_Edit, .Layer_Edit, int(Layer_Action.Move_Up), int(Layer_Action.Move_Down), "Move up", "Move down")
		_ = ui.switch_row(ctx, "Wide strength", &app.ui.layer_wide)
		ui.paragraph(ctx, fmt.tprintf("These act on the picked layer. %d on this level, %.1f MB.", len(layers), f64(sculpt.sculptor_layers_bytes(s)) / (1 << 20)))
		kit_more_end(app)
	}
	if !allowed do ui.paragraph(ctx, "Layers wait while the HD window or dynamic topology is on.")
}

// The picked layer's strength slider, as the Layers section's: −1 to 2, or ±5 with Wide
// strength (or a strength set wide); a drag is one undo step.
@(private = "file")
lens_layer_strength :: proc(app: ^App, obj: ^Object, i: int, width: f32) {
	ctx := &app.kit.ctx
	s := object_sculptor(obj)
	l := &sculpt.sculptor_layers(s)[i]
	strength := l.strength
	lo, hi := f32(-1), f32(2)
	dragged := app.ui.layer_dragging && app.ui.layer_drag_id == obj.id
	wide := app.ui.layer_drag_wide if dragged else (app.ui.layer_wide || strength < lo || strength > hi)
	if wide do lo, hi = -5, 5
	ui.begin(ctx, fmt.tprintf("lens layer %d strength", i), {direction = .Column, width = width, padding = 4})
	if ui.slider(ctx, fmt.tprintf("Strength##lens layer %d", i), &strength, lo, hi, .Linear, fmt.tprintf("%.2f", strength), enabled = layers_allowed(obj)) {
		if !app.ui.layer_dragging || app.ui.layer_drag_id != obj.id {
			layer_drag_finish(app)
			stroke_finish(app)
			app.ui.layer_dragging, app.ui.layer_drag_id, app.ui.layer_drag_wide = true, obj.id, wide
		}
		_ = sculpt.sculptor_layer_set(s, i, strength, l.visible)
	}
	ui.end(ctx)
}
