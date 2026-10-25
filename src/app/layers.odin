package main

import "core:fmt"
import "core:log"
import imgui "deps:odin-imgui"

import "../sculpt"

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

draw_layers_section :: proc(app: ^App) {
	imgui.SeparatorText("Layers")
	obj := selected_object(app)
	allowed := layers_allowed(obj)
	imgui.BeginDisabled(!allowed)
	defer imgui.EndDisabled()
	if imgui.Button("New layer") do layer_add(app)
	if obj == nil do return
	s := object_sculptor(obj)
	layers := sculpt.sculptor_layers(s)
	selected := &app.ui.layer_selected
	selected^ = clamp(selected^, 0, max(len(layers) - 1, 0))
	imgui.SameLine()
	imgui.BeginDisabled(len(layers) == 0)
	if imgui.Button("Delete") do layer_remove(app, obj, selected^, bake = false)
	imgui.SameLine()
	if imgui.Button("Bake") do layer_remove(app, obj, selected^, bake = true)
	imgui.EndDisabled()
	recording := sculpt.sculptor_layer_recording(s)
	for i := len(layers) - 1; i >= 0; i -= 1 {
		l := &layers[i]
		imgui.PushIDInt(i32(i))
		defer imgui.PopID()
		rec := recording == i
		if rec do imgui.PushStyleColorImVec4(.Button, {0.75, 0.15, 0.15, 1})
		if imgui.SmallButton("REC") {
			stroke_finish(app)
			if sculpt.sculptor_layer_record(s, -1 if rec else i) do history_record(app, obj, .Layer, "Layer strength")
			selected^ = i
		}
		if rec do imgui.PopStyleColor()
		imgui.SameLine()
		visible := l.visible
		if imgui.Checkbox("##shown", &visible) {
			stroke_finish(app)
			_ = sculpt.sculptor_layer_set(s, i, l.strength, visible)
			if sculpt.sculptor_stroke_end(s) do history_record(app, obj, .Layer, "Show layer" if visible else "Hide layer")
		}
		imgui.SameLine()
		imgui.SetNextItemWidth(90)
		name := l.name
		if imgui.InputText("##name", cstring(&name[0]), len(name) - 1) do sculpt.sculptor_layer_rename(s, i, string(cstring(&name[0])))
		if imgui.IsItemActivated() do selected^ = i
		imgui.SameLine()
		imgui.SetNextItemWidth(-1)
		strength := l.strength
		if imgui.SliderFloat("##strength", &strength, -1, 2, "%.2f") {
			if !app.ui.layer_dragging {
				stroke_finish(app)
				app.ui.layer_dragging = true
			}
			_ = sculpt.sculptor_layer_set(s, i, strength, l.visible)
			selected^ = i
		}
		if imgui.IsItemDeactivated() && app.ui.layer_dragging {
			app.ui.layer_dragging = false
			if sculpt.sculptor_stroke_end(s) do history_record(app, obj, .Layer, "Layer strength")
		}
	}
	if len(layers) > 0 {
		imgui.TextDisabled("%s", fmt.ctprintf("%d on this level, %.1f MB; selected: %s.", len(layers),
			f64(sculpt.sculptor_layers_bytes(s)) / (1 << 20), sculpt.sculptor_layer_name(&layers[selected^])))
	}
	imgui.TextDisabled("While REC is lit, strokes also go into that layer;\nits slider then dials them from -1 to 2 (Ctrl+click\nto type more). Delete takes the layer's work off,\nBake keeps it as plain sculpting. Each level has its\nown layers; not in HD or with dynamic topology,\nwhich bakes them.")
}

@(private = "file")
layer_remove :: proc(app: ^App, obj: ^Object, index: int, bake: bool) {
	stroke_finish(app)
	if sculpt.sculptor_layer_remove(object_sculptor(obj), index, bake) do history_record(app, obj, .Layer, "Bake layer" if bake else "Delete layer")
}
