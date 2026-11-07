package main

import "core:fmt"
import "core:log"
import "core:time"

import "../sculpt"
import "../ui"

// Fill layers in the Layers card's Paint tab (sculpt/paint_fill.odin): a texture layer made
// rather than painted, a colour, roughness, metal and height over the surface as far as a
// mask made from the sculpt allows (its cavities, edges, curvature, what faces up or down,
// its height, or the sculpt's mask). The picked fill layer's settings show under the
// stack; a change makes the layer again as one undo step, a slider's when it is let go,
// and Update makes it again after sculpting.

@(rodata)
FILL_MASK_NAMES := [sculpt.Fill_Mask]string {
	.Everywhere  = "Everywhere",
	.Cavities    = "Cavities",
	.Edges       = "Edges",
	.Curvature   = "Curvature",
	.Facing_Up   = "Facing up",
	.Facing_Down = "Facing down",
	.Height      = "Height",
	.Sculpt_Mask = "Sculpt mask",
}

// What each mask lays the fill on, for the card's line under the choice.
@(rodata)
FILL_MASK_HINTS := [sculpt.Fill_Mask]string {
	.Everywhere  = "The whole surface, evenly.",
	.Cavities    = "Down in creases and pores, as grime gathers.",
	.Edges       = "On crests and ridges, as wear shows.",
	.Curvature   = "Wherever the surface bends sharply, either way.",
	.Facing_Up   = "Where the surface faces up, as dust or snow settles.",
	.Facing_Down = "Where it faces down: soot, shade, drips.",
	.Height      = "From nothing at the lowest point to full at the highest.",
	.Sculpt_Mask = "Where the sculpt is masked: mask a part, then fill it.",
}

// The fill a new fill layer starts with: everywhere, in the brush's colour, roughness,
// metal and height.
fill_from_brush :: proc(app: ^App, base := sculpt.PAINT_FILL_DEFAULT) -> sculpt.Paint_Fill {
	f := base
	f.color = brush_color_bytes(app)
	f.material = {u8(clamp(app.brush.roughness, 0, 1) * 255 + 0.5), u8(clamp(app.brush.metal, 0, 1) * 255 + 0.5)}
	f.height = sculpt.height_value(clamp(app.brush.height, -1, 1))
	return f
}

// Makes the picked texture layer of `obj` with `fill` (again), as an undo step named
// `what`. The way up is the world's, in the object's own space, so Facing up and Height
// follow the scene rather than the mesh as it was modelled.
fill_layer_make :: proc(app: ^App, obj: ^Object, fill: sculpt.Paint_Fill, what: string) -> bool {
	stroke_finish(app)
	if obj == nil || !paint_allowed(obj) do return false
	start := time.tick_now()
	step := new(sculpt.Texel_Step)
	changed := sculpt.levels_texel_fill(&obj.levels, fill, to_local_dir(obj.transform, {0, 1, 0}), step)
	log.infof("%s (%s): %.0f ms%s", what, FILL_MASK_NAMES[fill.mask], time.duration_milliseconds(time.tick_since(start)), "" if changed else ", nothing changed")
	if !changed {
		sculpt.texel_step_free(step)
		free(step)
		return false
	}
	history_record_texels(app, obj, step, what)
	app.ui.fill_made += 1
	return true
}

// Adds a fill layer: a texture layer, then made with the brush's colour over the whole
// surface (two undo steps: the layer, then its fill).
fill_layer_add :: proc(app: ^App, obj: ^Object) {
	if obj == nil do return
	before := len(sculpt.sculptor_paint_layers(object_sculptor(obj)))
	texture_layer_add(app, obj, "Fill ")
	if len(sculpt.sculptor_paint_layers(object_sculptor(obj))) == before do return
	_ = fill_layer_make(app, obj, fill_from_brush(app), "Fill layer")
}

// Makes the picked fill layer again from its own settings: after sculpting, as the mask
// reads the surface as it is.
fill_layer_update :: proc(app: ^App) {
	obj := selected_object(app)
	if obj == nil do return
	layer, ok := sculpt.levels_fill_picked(&obj.levels)
	if !ok do return
	_ = fill_layer_make(app, obj, layer.fill, "Update fill layer")
}

// Whether stack row `l` of `obj` is a fill layer.
layer_is_fill :: proc(obj: ^Object, l: sculpt.Paint_Layer) -> bool {
	if l.texels == 0 do return false
	layer := sculpt.texels_layer(&obj.levels.texels, l.texels)
	return layer != nil && layer.filled
}

// Whether the selected object's picked paint layer is a fill layer.
fill_layer_picked :: proc(app: ^App) -> bool {
	obj := selected_object(app)
	if obj == nil || !paint_ready(app, 0) do return false
	_, ok := sculpt.levels_fill_picked(&obj.levels)
	return ok
}

// The picked fill layer's settings (mock: Substance's fill layer properties): the mask,
// what it lays down, the mask's strength and levels, Invert, and Update. A slider's drag
// changes a copy, and the layer is made again when it is let go, so a drag never remakes a
// texture each frame.
kit_lens_paint_fill :: proc(app: ^App, obj: ^Object, width: f32, allowed: bool) {
	ctx := &app.kit.ctx
	t := ctx.theme
	layer, ok := sculpt.levels_fill_picked(&obj.levels)
	if !ok do return
	u := &app.ui
	if !u.fill_editing || u.fill_obj != obj.id || u.fill_layer != layer.id do u.fill_edit, u.fill_editing = layer.fill, false
	f := &u.fill_edit
	before := f^

	ui.caption(ctx, "FILL")
	names: [len(sculpt.Fill_Mask)]string
	for name, m in FILL_MASK_NAMES do names[m] = name
	if picked := ui.select(ctx, "Fill mask##lens paint fill", names[:], int(f.mask), width); picked >= 0 && allowed do f.mask = sculpt.Fill_Mask(picked)
	ui.label(ctx, FILL_MASK_HINTS[f.mask], t.small_size, t.text_secondary)

	// What it lays down: the fill's colour, and the brush's colour, roughness, metal and
	// height taken into it.
	ui.begin(ctx, "lens paint fill colour", {direction = .Row, gap = ui.SPACE_S, center = true, width = width})
	_ = ui.swatch(ctx, "Fill colour##lens paint fill", {f.color.r, f.color.g, f.color.b, 255}, t.target)
	if ui.button(ctx, "Take the brush's colour##lens paint fill", .Bordered, width = width - t.target - ui.SPACE_S, enabled = allowed) do f^ = fill_from_brush(app, f^)
	ui.end(ctx)

	if f.mask == .Cavities || f.mask == .Edges || f.mask == .Curvature {
		_ = ui.slider(ctx, "Strength##lens paint fill", &f.strength, 0, 1, .Linear, fmt.tprintf("%.0f%%", f.strength * 100), enabled = allowed)
	}
	if f.mask != .Everywhere {
		_ = ui.slider(ctx, "From##lens paint fill", &f.low, 0, 1, .Linear, fmt.tprintf("%.0f%%", f.low * 100), enabled = allowed)
		_ = ui.slider(ctx, "To##lens paint fill", &f.high, 0, 1, .Linear, fmt.tprintf("%.0f%%", f.high * 100), enabled = allowed)
		_ = ui.switch_row(ctx, "Invert the mask##lens paint fill", &f.invert, enabled = allowed)
	}
	_ = command_button(app, .Fill_Layer_Update, label = "Update from the sculpt", variant = .Bordered, width = width)
	ui.paragraph(ctx, "A fill layer is made, not painted: its colour, roughness, metal and height go where its mask says, read from the sculpt as it is. Sculpting leaves it as it was; Update makes it again from the surface now. Strokes may paint on it, and making it again replaces them.")

	// A change made while a slider is held waits for the release.
	if f^ != before {
		u.fill_editing, u.fill_obj, u.fill_layer = true, obj.id, layer.id
	}
	if u.fill_editing && .Left not_in ctx.input.down {
		u.fill_editing = false
		if f^ != layer.fill do _ = fill_layer_make(app, obj, f^, "Fill layer settings")
	}
}
