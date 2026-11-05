package main

import "core:fmt"

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
	return fmt.tprintf("Mix %d%%%s%s", int(l.opacity * 100 + 0.5), " · hidden" if !l.visible else "", " · painting" if picked else "")
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
	_ = command_button(app, .New_Paint_Layer, label = "New layer", variant = .Solid, tone = .Accent, glyph = ui.ICON_PLUS, width = ui.text_width(ctx, "New layer", t.text_size, .Semibold) + 52)
	ui.label(ctx, "On vertices", t.small_size, t.text_secondary)
	ui.end(ctx)

	for i := len(layers) - 1; i >= 0; i -= 1 do lens_paint_row(app, obj, i, i == picked, width, allowed)
	if len(layers) == 0 do ui.paragraph(ctx, "Paint anything, or add a layer, to start the stack: the Paint brush, a brush's Colour channel and Fill all paint the lit layer.")

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
