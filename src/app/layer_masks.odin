package main

import "../sculpt"

// Layer masks in the Layers panel (panels P2b; sculpt/layer_masks.odin holds the masks).
// Each layer row has a mask square after its picture: a dashed square while the layer
// has no mask, the mask's glyph once it has one, ringed in the accent while it is picked.
// A tap on the square picks the layer's mask and the Mask brush, as Photoshop's tap on a
// layer mask's thumbnail makes the brushes paint it; every mask brush, shape and command
// then paints that mask, and the view shows it. A tap again puts the sculpt mask and the
// brush from before back. The pick also ends by itself (layer_mask_frame) once the work
// leaves it: another object, another tool or a brush that does not mask, Home, the HD
// window or dynamic topology, with the brush left as it was then picked. The layer menu's
// Mask section paints, inverts and clears a layer's mask and copies the sculpt mask in,
// each one History step.

// The layer mask the interface picked, and the brush it put the Mask brush in place of.
Layer_Mask_Paint :: struct {
	id:     int, // the object whose layer mask is picked; 0 for none
	tool:   Tool,
	kind:   sculpt.Brush_Kind,
	preset: int,
	picks:  int, // the picks made, for the exit stats
}

// What the layer menu's Mask section does to a layer's mask besides painting it.
Layer_Mask_Edit :: enum u8 {
	Invert,
	Clear,
	From_Sculpt,
}

// Picks layer `index`'s mask of `obj` for painting and the Mask brush, remembering the
// brush to put back.
layer_mask_paint :: proc(app: ^App, obj: ^Object, index: int) {
	stroke_finish(app)
	layer_drag_finish(app)
	if !layers_allowed(obj) do return
	lm := &app.ui.layer_mask
	// A pick already under way keeps the brush it began from.
	if lm.id != 0 && lm.id != obj.id do layer_mask_stop(app, restore = false)
	if lm.id == 0 do lm.tool, lm.kind, lm.preset = app.tool, app.brush.kind, app.brush.preset
	if !sculpt.sculptor_layer_mask_pick(object_sculptor(obj), index) {
		lm.id = 0
		return
	}
	lm.id = obj.id
	lm.picks += 1
	app.ui.layer_selected = index
	if app.tool != .Brush || app.brush.kind != .Mask || app.brush.preset != 0 do _ = command_run(app, .Brush, int(sculpt.Brush_Kind.Mask))
	l := &sculpt.sculptor_layers(object_sculptor(obj))[index]
	report(app, Kit_Section.Layers, {.Quiet}, "Painting %s's mask: the mask brushes and commands paint it until you tap its square again", sculpt.sculptor_layer_name(l))
}

// Puts the sculpt mask back on the object whose layer mask is picked; with `restore`, and
// the Mask brush still on, the brush from before the pick too.
layer_mask_stop :: proc(app: ^App, restore: bool) {
	lm := &app.ui.layer_mask
	if lm.id == 0 do return
	if obj := object_by_id(app, lm.id); obj != nil && obj.voxel == nil {
		stroke_finish(app)
		_ = sculpt.sculptor_layer_mask_pick(object_sculptor(obj), -1)
	}
	lm.id = 0
	if !restore || app.tool != .Brush || app.brush.kind != .Mask || app.brush.preset != 0 do return
	if lm.preset != 0 {
		preset_use(app, lm.preset)
	} else {
		app.brush.kind = lm.kind
		app.tool = lm.tool
	}
	space_picked(app)
}

// The layer whose mask the interface has picked on `obj`, or -1.
layer_mask_painting :: proc(app: ^App, obj: ^Object) -> int {
	if obj == nil || obj.voxel != nil || app.ui.layer_mask.id != obj.id do return -1
	return sculpt.sculptor_layer_mask_picked(object_sculptor(obj))
}

// Ends the pick once the work leaves it, each frame: the object no longer selected, a
// tool or brush that does not paint the mask, Home, the HD window or dynamic topology,
// or the sculptor having dropped the pick itself (a level change, a layer deleted or
// merged, an undo of one).
layer_mask_frame :: proc(app: ^App) {
	lm := &app.ui.layer_mask
	if lm.id == 0 do return
	obj := object_by_id(app, lm.id)
	keep := obj != nil && obj == selected_object(app) && layers_allowed(obj) && !app.kit.home
	keep = keep && app.tool == .Brush && .Mask in BRUSHES[app.brush.kind].flags
	keep = keep && layer_mask_painting(app, obj) >= 0
	if !keep do layer_mask_stop(app, restore = false)
}

// Inverts, clears or fills from the sculpt mask layer `index`'s mask of `obj`, as one
// History step, whether or not that mask is picked; a mask picked before stays picked.
layer_mask_edit :: proc(app: ^App, obj: ^Object, index: int, edit: Layer_Mask_Edit) {
	stroke_finish(app)
	layer_drag_finish(app)
	if !layers_allowed(obj) || obj != selected_object(app) do return
	s := object_sculptor(obj)
	before := sculpt.sculptor_layer_mask_picked(s)
	if before != index && !sculpt.sculptor_layer_mask_pick(s, index) do return
	switch edit {
	case .Invert:
		mask_command(app, .Invert, toast = true)
	case .Clear:
		mask_command(app, .Clear, toast = true)
	case .From_Sculpt:
		if sculpt.sculptor_layer_mask_from_sculpt(s) {
			history_record(app, obj, .Mask, "Mask from the sculpt mask")
			report(app, Kit_Section.Layers, {.Undo}, "The layer's mask is now the sculpt mask")
		}
	}
	if before != index do _ = sculpt.sculptor_layer_mask_pick(s, before)
}

// Whether `obj` has a sculpt mask to copy into a layer's mask.
layer_mask_sculpt_ready :: proc(obj: ^Object) -> bool {
	if obj == nil || obj.voxel != nil do return false
	m := sculpt.sculptor_sculpt_mask(object_sculptor(obj))
	if m == nil do return false
	for k in m do if k != 0 do return true
	return false
}
