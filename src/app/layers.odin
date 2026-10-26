package main

import "core:fmt"
import "core:log"

import "../sculpt"
import "../ui"

// The Layers section: the selected object's sculpt layers on its current level
// (sculpt/sculpt_layers.odin), newest on top. Each row has REC (strokes go into the
// layer while it is lit), the eye, the name and the strength slider; a slider drag is
// one undo step.

// Whether the selected object's layers can change now: not in an HD window, whose
// sculptor is the window's, nor with dynamic topology.
layers_allowed :: proc(obj: ^Object) -> bool {
	return obj != nil && !object_in_hd(obj) && !object_dynamic(obj)
}

layer_add :: proc(app: ^App) {
	stroke_finish(app)
	obj := selected_object(app)
	if !layers_allowed(obj) do return
	s := object_sculptor(obj)
	index := sculpt.sculptor_layer_add(s)
	if index < 0 {
		log.warnf("layers: at most %d a level", sculpt.MAX_SCULPT_LAYERS)
		return
	}
	app.ui.layer_selected = index
	history_record(app, obj, .Layer, "New layer")
}

@(private = "file")
layer_remove :: proc(app: ^App, obj: ^Object, index: int, bake: bool) {
	stroke_finish(app)
	if sculpt.sculptor_layer_remove(object_sculptor(obj), index, bake) do history_record(app, obj, .Layer, "Bake layer" if bake else "Delete layer")
}

// The interface's Layers section: a row per layer, newest on top, with its record and
// show buttons, its name and its strength; then which layer Delete and Bake act on.
kit_layers_section :: proc(app: ^App) {
	ctx := &app.kit.ctx
	obj := selected_object(app)
	allowed := layers_allowed(obj)
	if ui.button(ctx, "New layer", .Flat, .Accent, glyph = ui.ICON_PLUS, enabled = allowed) do layer_add(app)
	if obj == nil {
		ui.paragraph(ctx, "Select an object to give it layers.")
		return
	}
	s := object_sculptor(obj)
	layers := sculpt.sculptor_layers(s)
	selected := &app.ui.layer_selected
	selected^ = clamp(selected^, 0, max(len(layers) - 1, 0))
	recording := sculpt.sculptor_layer_recording(s)
	field := ui.fill_width(ctx) - 2 * ctx.theme.target - 8
	for i := len(layers) - 1; i >= 0; i -= 1 {
		l := &layers[i]
		ui.begin(ctx, fmt.tprintf("layer %d", i), {direction = .Row, gap = 4, center = true})
		rec := recording == i
		if ui.icon_button(ctx, fmt.tprintf("Record into this layer##%d", i), ui.ICON_RECORD, selected = rec, enabled = allowed) {
			stroke_finish(app)
			if sculpt.sculptor_layer_record(s, -1 if rec else i) do history_record(app, obj, .Layer, "Layer strength")
			selected^ = i
		}
		if ui.icon_button(ctx, fmt.tprintf("Show or hide##%d", i), ui.ICON_EYE if l.visible else ui.ICON_EYE_OFF, selected = l.visible, enabled = allowed) {
			stroke_finish(app)
			_ = sculpt.sculptor_layer_set(s, i, l.strength, !l.visible)
			if sculpt.sculptor_stroke_end(s) do history_record(app, obj, .Layer, "Show layer" if l.visible else "Hide layer")
		}
		name := l.name
		if ui.text_field(ctx, fmt.tprintf("name##layer %d", i), name[:], field) {
			n := 0
			for n < len(name) && name[n] != 0 do n += 1
			sculpt.sculptor_layer_rename(s, i, string(name[:n]))
			app.scene_edits += 1
			selected^ = i
		}
		ui.end(ctx)
		strength := l.strength
		if ui.slider(ctx, fmt.tprintf("Strength##layer %d", i), &strength, -1, 2, .Linear, fmt.tprintf("%.2f", strength), enabled = allowed) {
			if !app.ui.layer_dragging {
				stroke_finish(app)
				app.ui.layer_dragging = true
			}
			_ = sculpt.sculptor_layer_set(s, i, strength, l.visible)
			selected^ = i
		}
	}
	if len(layers) > 0 {
		names := make([]string, len(layers), context.temp_allocator)
		for &l, i in layers do names[i] = sculpt.sculptor_layer_name(&l)
		if picked := ui.select(ctx, "layer to change", names, selected^); picked >= 0 do selected^ = picked
		remove, bake := kit_button_pair(ctx, "Delete", "Bake", allowed, allowed, .Danger)
		if remove do layer_remove(app, obj, selected^, bake = false)
		if bake do layer_remove(app, obj, selected^, bake = true)
		ui.paragraph(ctx, fmt.tprintf("%d on this level, %.1f MB.", len(layers), f64(sculpt.sculptor_layers_bytes(s)) / (1 << 20)))
	}
	ui.paragraph(ctx, "While a layer records, strokes also go into it; its strength then dials them from -1 to 2. Delete takes its work off, Bake keeps it as plain sculpting. Each level has its own layers; not in HD or with dynamic topology, which bakes them.")
}

// Ends a drag of a layer's strength once the pointer lets go, as one undo step. Runs
// every frame, so a drag ends even if its section closed meanwhile.
layer_drag_end :: proc(app: ^App) {
	if !app.ui.layer_dragging || .Left in app.device.down do return
	app.ui.layer_dragging = false
	if obj := selected_object(app); obj != nil && sculpt.sculptor_stroke_end(object_sculptor(obj)) {
		history_record(app, obj, .Layer, "Layer strength")
	}
}
