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

// What the Layers section's More options do to the selected layer (app.ui.layer_selected).
Layer_Action :: enum u8 {
	Duplicate,
	Invert,
	Merge_Down,
	Move_Up,
	Move_Down,
	Bake_All,
}

@(rodata)
LAYER_ACTION_NAMES := [Layer_Action]string {
	.Duplicate  = "Duplicate layer",
	.Invert     = "Invert layer",
	.Merge_Down = "Merge layer down",
	.Move_Up    = "Move layer up",
	.Move_Down  = "Move layer down",
	.Bake_All   = "Bake all layers",
}

// Whether `action` can run on the selected object's selected layer now.
layer_action_ready :: proc(app: ^App, action: Layer_Action) -> bool {
	obj := selected_object(app)
	if !layers_allowed(obj) do return false
	s := object_sculptor(obj)
	layers := sculpt.sculptor_layers(s)
	i := app.ui.layer_selected
	if len(layers) == 0 || i < 0 || i >= len(layers) do return false
	switch action {
	case .Duplicate:  return len(layers) < sculpt.MAX_SCULPT_LAYERS
	case .Invert:     return sculpt.sculptor_layer_used(layers[i])
	case .Merge_Down: return i > 0
	case .Move_Up:    return i < len(layers) - 1
	case .Move_Down:  return i > 0
	case .Bake_All:   return true
	}
	return false
}

// Runs `action` on the selected layer (Bake all on every layer) as one History step.
layer_action :: proc(app: ^App, action: Layer_Action) {
	stroke_finish(app)
	layer_drag_finish(app)
	if !layer_action_ready(app, action) do return
	obj := selected_object(app)
	s := object_sculptor(obj)
	i := &app.ui.layer_selected
	done := false
	switch action {
	case .Duplicate:
		if at := sculpt.sculptor_layer_duplicate(s, i^); at >= 0 do i^, done = at, true
	case .Invert:
		done = sculpt.sculptor_layer_invert(s, i^)
	case .Merge_Down:
		if sculpt.sculptor_layer_merge_down(s, i^) do i^, done = i^ - 1, true
	case .Move_Up, .Move_Down:
		up := action == .Move_Up
		if sculpt.sculptor_layer_move(s, i^, up) do i^, done = i^ + (1 if up else -1), true
	case .Bake_All:
		if sculpt.sculptor_layers_bake(s) do i^, done = 0, true
	}
	if done do history_record(app, obj, .Layer, LAYER_ACTION_NAMES[action])
}

// Deletes layer `index` (or bakes it into the surface) as one History step.
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
	_ = command_button(app, .New_Layer, tone = .Accent, glyph = ui.ICON_PLUS)
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
		// Wide strength reaches five times either way (and a strength set wide shows whole
		// on the narrow slider's range).
		lo, hi := f32(-1), f32(2)
		// A drag keeps the range it began on, so dragging a wide strength back into the
		// narrow range does not change the scale under the pointer.
		dragged := app.ui.layer_dragging && app.ui.layer_drag_id == obj.id && i == selected^
		wide := app.ui.layer_drag_wide if dragged else (app.ui.layer_wide || strength < lo || strength > hi)
		if wide do lo, hi = -5, 5
		if ui.slider(ctx, fmt.tprintf("Strength##layer %d", i), &strength, lo, hi, .Linear, fmt.tprintf("%.2f", strength), enabled = allowed) {
			if !app.ui.layer_dragging || app.ui.layer_drag_id != obj.id {
				layer_drag_finish(app)
				stroke_finish(app)
				app.ui.layer_dragging, app.ui.layer_drag_id, app.ui.layer_drag_wide = true, obj.id, wide
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
	if kit_more(app, .Layers) {
		kit_command_pair(app, .Layer_Edit, .Layer_Edit, int(Layer_Action.Duplicate), int(Layer_Action.Invert), "Duplicate", "Invert")
		kit_command_pair(app, .Layer_Edit, .Layer_Edit, int(Layer_Action.Merge_Down), int(Layer_Action.Bake_All), "Merge down", "Bake all")
		kit_command_pair(app, .Layer_Edit, .Layer_Edit, int(Layer_Action.Move_Up), int(Layer_Action.Move_Down), "Move up", "Move down")
		_ = ui.switch_row(ctx, "Wide strength", &app.ui.layer_wide)
		ui.paragraph(ctx, "These act on the layer picked above. Duplicate adds a hidden copy above it (its eye shows it, doubling the work). Invert turns its work the other way. Merge down puts what it and the layer under it show into that one, at full strength, without moving the surface. Move up and Move down change the order. Bake all keeps every layer's work as plain sculpting, as one step. Wide strength lets the sliders go from -5 to 5. Layers hold sculpting only, not polypaint.")
		kit_more_end(app)
	}
	ui.paragraph(ctx, "While a layer records, strokes also go into it; its strength then dials them from -1 to 2. Delete takes its work off, Bake keeps it as plain sculpting. Each level has its own layers; Subdivide moves the top level's up to the new level, Delete higher carries the higher levels' down, and rebuilds (Remesh, Decimate, Mirror and weld, Slice, Make boolean) carry them onto the new mesh. Not in HD or with dynamic topology, which bakes them.")
}

// Ends a drag of a layer's strength once the pointer lets go, as one undo step. Runs
// every frame, so a drag ends even if its section closed meanwhile.
layer_drag_end :: proc(app: ^App) {
	if app.ui.layer_dragging && .Left not_in app.device.down do layer_drag_finish(app)
}

// Ends a layer strength drag still held, as its undo step, before a scene command or an
// undo changes what the drag's layer is part of (Subdivide moves layers to another
// level). A drag that goes on after it is a step of its own. Not stroke_finish, which
// the frame runs whenever the viewport is not pressed, as it is not during a drag.
layer_drag_finish :: proc(app: ^App) {
	if !app.ui.layer_dragging do return
	app.ui.layer_dragging = false
	// The drag's own object: a pen can select another while a finger holds the slider.
	if obj := object_by_id(app, app.ui.layer_drag_id); obj != nil && sculpt.sculptor_stroke_end(object_sculptor(obj)) {
		history_record(app, obj, .Layer, "Layer strength")
	}
}
