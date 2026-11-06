package main

import "core:fmt"
import "core:strings"

import "../sculpt"
import "../ui"

// The Layers card's Paint tab (Surface plan PT1): the selected object's paint layers newest
// on top, as Procreate and Substance list theirs. Polypaint is the picked layer, so the Paint
// brush, a sculpting brush's Colour channel, Fill, Gradient, Clear and Blur paint the row
// that is lit. Each row is the layer's swatch (its colour where it covers most), its name and
// opacity, an opacity bar dragged in place and its eye; what shows on the model is the stack
// composited bottom up. Under the rows, what acts on the picked layer: Move up, Move down,
// Merge down and Delete. One card for layers: the Sculpt tab is the sculpt layers.

// What the tab shows: the picked layer's opacity as a fraction and its eye, or a hint.
@(private = "file")
paint_layer_caption :: proc(l: sculpt.Paint_Layer, picked: bool) -> string {
	// A texture layer says so first, as the mock's "Texture 2K" rows do.
	kind := "Texture · " if l.texels != 0 else ""
	return fmt.tprintf("%sMix %d%% · %s%s%s", kind, int(l.opacity * 100 + 0.5), paint_channels_text(l.channels), " · hidden" if !l.visible else "", " · painting" if picked else "")
}

// A layer's channels as its row lists them: "colour, roughness, metal".
paint_channels_text :: proc(channels: sculpt.Paint_Channels) -> string {
	parts: [len(sculpt.Paint_Channel)]string
	n := 0
	for c in sculpt.Paint_Channel do if c in channels {
		parts[n] = PAINT_CHANNEL_NAMES[c]
		n += 1
	}
	return strings.join(parts[:n], ", ", context.temp_allocator) if n > 0 else "nothing"
}

@(rodata)
PAINT_CHANNEL_NAMES := [sculpt.Paint_Channel]string {
	.Color     = "colour",
	.Roughness = "roughness",
	.Metal     = "metal",
	.Height    = "height",
}

// The channel strip's toggles, short enough for a third of the card each.
@(rodata)
PAINT_CHANNEL_SHORT := [sculpt.Paint_Channel]string {
	.Color     = "Colour",
	.Roughness = "Rough",
	.Metal     = "Metal",
	.Height    = "Height",
}

// The tab's content.
kit_lens_paint_layers :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	t := ctx.theme
	s := object_sculptor(obj)
	allowed := paint_ready(app, 0)
	layers := sculpt.sculptor_paint_layers(s)
	picked := sculpt.sculptor_paint_picked(s)
	width := ui.fill_width(ctx)

	ui.begin(ctx, "lens paint head", {direction = .Row, gap = ui.SPACE_S, center = true, width = width})
	// New layer asks where the layer lives (mock 2A): on the vertices, or in a texture
	// through the UVs.
	can := command_enabled(app, .New_Paint_Layer)
	new_w := ui.text_width(ctx, "New layer", t.text_size, .Semibold) + 72
	pressed := ui.button(ctx, "New layer##lens paint new", .Solid, .Accent, new_w, ui.ICON_PLUS, can, reason = "" if can else command_reason(app, .New_Paint_Layer))
	// The menu follows the button as the card moves.
	app.kit.paint_new_anchor = ctx.last_rect
	if pressed do app.kit.paint_new_pop = !app.kit.paint_new_pop
	if picked >= 0 && picked < len(layers) {
		l := layers[picked]
		lives := "In a texture" if l.texels != 0 else "On vertices"
		ui.label(ctx, lives, t.small_size, t.text_secondary)
	}
	ui.end(ctx)

	for i := len(layers) - 1; i >= 0; i -= 1 do lens_paint_row(app, obj, i, i == picked, width, allowed)
	if len(layers) == 0 do ui.paragraph(ctx, "Paint anything, or add a layer, to start the stack: the Paint brush, a brush's Colour channel and Fill all paint the lit layer.")
	if picked >= 0 && picked < len(layers) do lens_paint_channels(app, obj, picked, width, allowed)

	// The foot shows with no layers too, its buttons off, so it stays where it is found.
	{
		ui.divider(ctx, across = true)
		ui.begin(ctx, "lens paint foot", {direction = .Row, gap = ui.SPACE_XS, center = true, width = width})
		// Up and Down as arrows, so Merge down and Delete keep their words on a narrow card.
		arrow := t.target
		half := (width - 2 * arrow - 12) / 2
		_ = command_button(app, .Paint_Layer_Edit, int(Paint_Layer_Action.Move_Up), width = arrow, glyph = ui.ICON_CHEVRON_UP, icon_only = true)
		_ = command_button(app, .Paint_Layer_Edit, int(Paint_Layer_Action.Move_Down), width = arrow, glyph = ui.ICON_CHEVRON_DOWN, icon_only = true)
		_ = command_button(app, .Paint_Layer_Edit, int(Paint_Layer_Action.Merge_Down), label = "Merge down", width = half)
		_ = command_button(app, .Paint_Layer_Edit, int(Paint_Layer_Action.Delete), label = "Delete", width = half)
		ui.end(ctx)
		if len(layers) > 0 do ui.label(ctx, fmt.tprintf("%d %s, %.1f MB beside the picked one", len(layers), "layer" if len(layers) == 1 else "layers", f64(sculpt.sculptor_paint_bytes(s)) / (1 << 20)), t.small_size, t.text_tertiary)
	}
	if !allowed do ui.paragraph(ctx, "Paint layers wait while the HD window or dynamic topology is on.")
	ui.paragraph(ctx, "Paint layers stack polypaint: each is a colour over the clay with its own opacity and eye, and what shows is every layer laid over the ones below. The lit layer is the one every paint tool paints. Every level shows the same layers, and rebuilds (Remesh, Decimate, Mirror and weld) keep what shows as one layer.")
}

// The New layer menu (mock 2A): a layer on the vertices, as fine as the mesh and needing
// no UVs, or in a texture through the UVs, as fine as the texture, at the size every
// texture layer of the object shares. With no UVs the texture row says so and offers
// nothing it cannot do.
kit_paint_new_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	obj := selected_object(app)
	if obj == nil || !paint_ready(app, 0) do k.paint_new_pop = false
	if !k.paint_new_pop do return
	if !ui.popover_begin(ctx, "paint new menu", &k.paint_new_pop, k.paint_new_anchor, .Below, {direction = .Column, padding = ui.MENU_PAD, width = ui.MENU_W}) do return
	defer ui.popover_end(ctx)
	if ui.menu_item(ctx, "On vertices##paint new", glyph = ui.ICON_PLUS, hint = "As fine as the mesh. No UVs needed.", enabled = command_enabled(app, .New_Paint_Layer)) {
		k.paint_new_pop = false
		paint_layer_add(app, obj)
	}
	side := texture_layer_side(app, obj)
	has_uvs := sculpt.levels_has_uvs(&obj.levels)
	reason := "" if has_uvs else "Needs UVs: Unwrap first (Mesh > UVs)"
	if ui.menu_item(ctx, "In a texture##paint new", glyph = ui.ICON_PLUS, tag = fmt.tprintf("%dK", side / 1024) if side >= 1024 else fmt.tprintf("%d", side), tag_color = t.accent, hint = "As fine as the texture. Uses the UVs.", enabled = command_enabled(app, .New_Texture_Layer), reason = reason) {
		k.paint_new_pop = false
		texture_layer_add(app, obj)
	}
	ui.paragraph(ctx, "A texture layer takes the Bake size and stands above the vertex layers." if len(obj.levels.texels.layers) == 0 else fmt.tprintf("This object's texture layers are %d square.", obj.levels.texels.side))
}

// The channel strip (mock 1B): what the picked layer's strokes write, a toggle each, as
// Wafer's layers pick theirs. A stroke writes only the channels that are on, so a layer can
// hold roughness alone over the colour below; one channel stays on at least. Turning one
// changes nothing that shows, as an undo step.
@(private = "file")
lens_paint_channels :: proc(app: ^App, obj: ^Object, i: int, width: f32, allowed: bool) {
	ctx := &app.kit.ctx
	s := object_sculptor(obj)
	l := sculpt.sculptor_paint_layers(s)[i]
	ui.caption(ctx, fmt.tprintf("%s PAINTS", strings.to_upper(sculpt.sculptor_paint_layer_name(&l), context.temp_allocator)))
	// Height is a texture layer's alone: on the vertices the sculpt is the height.
	offered := sculpt.PAINT_CHANNELS_ALL if l.texels != 0 else sculpt.PAINT_CHANNELS_ALL - {.Height}
	gap: f32 = ui.SPACE_XS
	count := card(offered)
	w := (width - gap * f32(count - 1)) / f32(count)
	ui.begin(ctx, "lens paint channels", {direction = .Row, gap = gap, width = width})
	for c in sculpt.Paint_Channel {
		if c not_in offered do continue
		on := c in l.channels
		tip := fmt.tprintf("Strokes on this layer %s its %s", "write" if on else "leave", PAINT_CHANNEL_NAMES[c])
		if ui.toggle_button(ctx, fmt.tprintf("%s##lens paint channel", PAINT_CHANNEL_SHORT[c]), on, w, tooltip = tip) && allowed {
			next := l.channels ~ {c}
			if next == {} do continue
			stroke_finish(app)
			if sculpt.sculptor_paint_set_channels(s, i, next) do history_record(app, obj, .Paint, "Paint layer channels")
		}
	}
	ui.end(ctx)
	ui.paragraph(ctx, "Roughness and metal show on a physically based material (PBR clay, the metals, Plastic) over its own, and in Full render; classic and MatCap materials show colour only. Height on a texture layer shows as fine relief through its normals; on the vertices the sculpt itself is the height." if l.texels != 0 else "Roughness and metal show on a physically based material (PBR clay, the metals, Plastic) over its own, and in Full render; classic and MatCap materials show colour only. Height is the sculpt itself on vertices: sculpt it, or record a sculpt layer; a texture layer paints height as fine relief.")
}

// One layer's row: its swatch and name (a tap picks it), the opacity bar and the eye.
@(private = "file")
lens_paint_row :: proc(app: ^App, obj: ^Object, i: int, picked: bool, width: f32, allowed: bool) {
	ctx := &app.kit.ctx
	t := ctx.theme
	s := object_sculptor(obj)
	l := sculpt.sculptor_paint_layers(s)[i]
	name := fmt.tprintf("lens paint layer %d", i)
	if picked {
		if r := ui.prev_rect(ctx, name); r.w > 0 {
			ui.fill_rect(ctx, r, t.radius_medium, ui.color_fade(t.accent, 0.16))
			ui.stroke_rect(ctx, r, t.radius_medium, ui.color_fade(t.accent, 0.45), 1)
		}
	}
	fade: f32 = 1 if l.visible else 0.5
	ui.begin(ctx, name, {direction = .Row, center = true, gap = ui.SPACE_M, width = width, height = LAYER_ROW_H, padding = ui.SPACE_S})
	words_w := width - LAYER_PICTURE - LAYER_SLIDER_W - t.target - 32
	a := ui.area(ctx, fmt.tprintf("%s##lens paint pick %d", sculpt.sculptor_paint_layer_name(&l), i), {LAYER_PICTURE + 8 + words_w, 44}, drag = false)
	sw := ui.Rect{a.rect.x, a.rect.y + 2, LAYER_PICTURE, LAYER_PICTURE}
	ui.fill_rect(ctx, sw, t.radius_small, t.fill)
	if c, ok := paint_layer_swatch(app, obj, i); ok {
		ui.fill_rect(ctx, {sw.x + 6, sw.y + 6, sw.w - 12, sw.h - 12}, t.radius_small, ui.color_fade(c, fade))
	} else {
		ui.icon(ctx, ICON_LAYERS, {sw.x + sw.w * 0.5, sw.y + sw.h * 0.5}, t.icon_small, ui.color_fade(t.text_tertiary, fade))
	}
	weight: ui.Font = .Semibold if picked else .Regular
	tx := a.rect.x + LAYER_PICTURE + 8
	ui.text(ctx, ui.text_fit(ctx, sculpt.sculptor_paint_layer_name(&l), t.text_size, words_w, weight), tx, a.rect.y + 13, t.text_size, ui.color_fade(t.text, fade), weight)
	ui.text(ctx, ui.text_fit(ctx, paint_layer_caption(l, picked), t.caption_size, words_w), tx, a.rect.y + 33, t.caption_size, ui.color_fade(t.text_tertiary, fade))
	if a.clicked && allowed {
		stroke_finish(app)
		sculpt.sculptor_paint_pick(s, i)
	}
	lens_paint_opacity(app, obj, i, LAYER_SLIDER_W, fade, allowed)
	if ui.icon_button(ctx, fmt.tprintf("Show or hide##lens paint layer %d", i), ui.ICON_EYE if l.visible else ui.ICON_EYE_OFF, enabled = allowed, size = t.target) {
		stroke_finish(app)
		if sculpt.sculptor_paint_set(s, i, !l.visible, l.opacity) && sculpt.sculptor_stroke_end(s) do history_record(app, obj, .Paint, "Hide paint layer" if l.visible else "Show paint layer")
	}
	ui.end(ctx)
}

// A row's opacity: a slim bar filled to the opacity, dragged in place as one undo step
// (layer_drag_finish ends it on release, as a sculpt layer's strength).
@(private = "file")
lens_paint_opacity :: proc(app: ^App, obj: ^Object, i: int, w, fade: f32, enabled: bool) {
	ctx := &app.kit.ctx
	t := ctx.theme
	s := object_sculptor(obj)
	l := sculpt.sculptor_paint_layers(s)[i]
	a := ui.area(ctx, fmt.tprintf("Opacity##lens paint layer %d", i), {w, LAYER_ROW_H})
	track := ui.Rect{a.rect.x + 6, a.rect.y + a.rect.h * 0.5 - 2, a.rect.w - 12, 4}
	if enabled && a.held {
		v := clamp((a.mouse.x - track.x) / max(track.w, 1), 0, 1)
		v = f32(int(v * 100 + 0.5)) / 100
		if v != l.opacity {
			if !app.ui.layer_dragging || app.ui.layer_drag_id != obj.id || !app.ui.layer_drag_paint {
				layer_drag_finish(app)
				stroke_finish(app)
				app.ui.layer_dragging, app.ui.layer_drag_id, app.ui.layer_drag_paint = true, obj.id, true
			}
			_ = sculpt.sculptor_paint_set(s, i, l.visible, v)
		}
	}
	colour := ui.color_fade(t.accent, fade * (1 if enabled else 0.4))
	ui.fill_rect(ctx, track, 2, t.track)
	now := track.x + track.w * l.opacity
	ui.fill_rect(ctx, {track.x, track.y, max(now - track.x, 1), track.h}, 2, colour)
	ui.fill_circle(ctx, {now, track.y + track.h * 0.5}, 6 if a.held else 5, ui.color_fade(t.text, fade))
	ui.tip(ctx, a.id, a.rect, fmt.tprintf("Opacity %d%%: drag to fade the layer over the ones below", int(l.opacity * 100 + 0.5)))
}
