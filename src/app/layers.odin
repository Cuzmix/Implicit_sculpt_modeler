package main

import "core:log"

import "../sculpt"

// What the Layers card (lens_layers.odin) acts with: the selected object's sculpt layers
// on its current level (sculpt/sculpt_layers.odin), adding, removing and baking them, and
// a strength drag as one undo step.

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
	paint := app.ui.layer_drag_paint
	app.ui.layer_drag_paint = false
	if obj := object_by_id(app, app.ui.layer_drag_id); obj != nil && sculpt.sculptor_stroke_end(object_sculptor(obj)) {
		if paint do history_record(app, obj, .Paint, "Paint layer opacity")
		else do history_record(app, obj, .Layer, "Layer strength")
	}
}
