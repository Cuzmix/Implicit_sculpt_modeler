package main

import "core:fmt"

import "../sculpt"
import "../ui"

// Lens's Layers panel (panels P1, round 3 tab 13): the selected object's layers newest on
// top, after Procreate's and ZBrush's. The head has New layer, which starts it recording,
// the level the layers belong to, and Wide ±5, ZBrush's multiplier, as one chip. Each row
// is the layer's picture of where it worked (layer_pictures.odin), its name with the red
// dot while it records (a tap on the dot records or stops), its strength as a slider to
// drag in place (−1 to 2, the bar filled from 0) and its eye; a hidden layer fades. Resting
// on a row or pressing it tints where that layer worked on the model, as the History does
// for a step; a sideways swipe to the left opens Merge down and Delete on the row, as iOS
// lists do; a long press, a right click or the pen's side button opens the layer's menu.
// Under the rows Base sculpt, everything outside the layers, then Duplicate, Merge down,
// Bake all and the menu. The Object palette keeps its Layers section too
// (kit_layers_section).

// A layer row's height, in points, and its picture's side.
LAYER_ROW_H :: 56
LAYER_PICTURE :: 40
// The mask badge's side, on the picture's corner.
LAYER_MASK_SIDE :: 20
// The strength slider's width on a row.
LAYER_SLIDER_W :: 92
// How far a row slides open to show Merge down and Delete.
LAYER_SWIPE_W :: 92

// The record dot's red, as the mock has it; a hollow circle (ICON_CIRCLE) while the
// layer does not record.
LAYER_RECORD_COLOR :: ui.Color{240, 106, 94, 255}

// What the panel keeps between frames: the row swiped open (its object, and its index + 1;
// 0 for none), the layer menu, and the tint a row asks for this frame.
Layer_Panel :: struct {
	swiped_id:   int,
	swiped:      int,
	swipes:      int, // rows swiped open, for the exit stats
	menu:        bool,
	menu_at:     ui.Rect,
	menu_id:     int, // the object and layer the menu is for
	menu_layer:  int,
	menus:       int,
	tint_id:     int, // the object and layer (index + 1) a row is rested on or pressed this frame
	tint_layer:  int,
	tint_time:   f64, // the frame (the kit's clock) that asked
	tints:       int,
	tint_last:   int, // the layer tinted last, for counting new tints
}

// The card's content, as the stack draws it.
kit_lens_layers :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	lp := &k.layer_panel
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
	if lp.swiped_id != obj.id || lp.swiped > len(layers) do lp.swiped = 0

	// The head: New layer, the level and Wide ±5.
	ui.begin(ctx, "lens layers head", {direction = .Row, gap = 6, center = true, width = width})
	_ = command_button(app, .New_Layer, label = "New layer", variant = .Solid, tone = .Accent, glyph = ui.ICON_PLUS, width = ui.text_width(ctx, "New layer", t.text_size, .Semibold) + 52)
	level := HD_LEVEL if object_in_hd(obj) else obj.levels.current
	level_text := "HD window" if level == HD_LEVEL else fmt.tprintf("Level %d of %d", level + 1, len(obj.levels.levels))
	ui.label(ctx, level_text, t.small_size, t.text_secondary)
	// The row's gap comes once more before the chip.
	ui.spacer(ctx, ui.row_room(ctx) - lens_chip_width(ctx, "Wide ±5") - 6)
	if a := lens_chip(ctx, "Wide strength: ±5 instead of −1 to 2##lens layers", "Wide ±5", lit = app.ui.layer_wide); a.clicked do app.ui.layer_wide = !app.ui.layer_wide
	ui.end(ctx)

	for i := len(layers) - 1; i >= 0; i -= 1 {
		lens_layer_row(app, obj, i, width, allowed, recording)
		k.layer_rows += 1
	}

	// Base sculpt: the surface under the layers.
	base := ui.place(ctx, {width, 48})
	mid := base.y + base.h * 0.5
	ui.fill_rect(ctx, {base.x + 4, mid - 18, 36, 36}, t.radius_small, t.fill)
	ui.icon(ctx, ICON_LOCK if recording >= 0 else ui.ICON_FRAME, {base.x + 22, mid}, t.icon_small, t.text_secondary)
	ui.text(ctx, "Base sculpt", base.x + 50, mid - 8, t.text_size, t.text)
	under := "locked while a layer records" if recording >= 0 else "everything outside the layers"
	ui.text(ctx, ui.text_fit(ctx, under, t.caption_size, base.w - 56), base.x + 50, mid + 10, t.caption_size, t.text_tertiary)

	// The foot: what acts on the picked layer, and its menu.
	if len(layers) > 0 {
		ui.divider(ctx, across = true)
		ui.begin(ctx, "lens layers foot", {direction = .Row, gap = 4, center = true, width = width})
		third := (width - t.target - 12) / 3
		_ = command_button(app, .Layer_Edit, int(Layer_Action.Duplicate), label = "Duplicate", width = third)
		_ = command_button(app, .Layer_Edit, int(Layer_Action.Merge_Down), label = "Merge down", width = third)
		_ = command_button(app, .Layer_Edit, int(Layer_Action.Bake_All), label = "Bake all", width = third)
		if ui.icon_button(ctx, "Layer menu##lens layers foot", ui.ICON_MORE, enabled = allowed) do layer_menu_open(app, obj, selected^, ctx.last_rect, .Above_Center)
		ui.end(ctx)
	}
	if !allowed do ui.paragraph(ctx, "Layers wait while the HD window or dynamic topology is on.")
}

// One layer's row: its picture and name (which pick it, tint it, swipe and open its menu),
// the record dot, the strength slider and the eye; swiped open, Merge down and Delete in
// place of the slider and the eye.
@(private = "file")
lens_layer_row :: proc(app: ^App, obj: ^Object, i: int, width: f32, allowed: bool, recording: int) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	lp := &k.layer_panel
	s := object_sculptor(obj)
	l := &sculpt.sculptor_layers(s)[i]
	picked := i == app.ui.layer_selected
	name := fmt.tprintf("lens layer %d", i)
	open := lp.swiped == i + 1
	// The picked row's tint, where the row was laid out last frame.
	if picked {
		if r := ui.prev_rect(ctx, name); r.w > 0 {
			ui.fill_rect(ctx, r, t.radius_medium, ui.color_fade(t.accent, 0.16))
			ui.stroke_rect(ctx, r, t.radius_medium, ui.color_fade(t.accent, 0.45), 1)
		}
	}
	fade: f32 = 1 if l.visible else 0.5
	ui.begin(ctx, name, {direction = .Row, center = true, gap = 0, width = width, height = LAYER_ROW_H})
	// A press anywhere but on the open row's actions closes it, as a list does. Asked in the
	// row, whose child the actions are.
	if open && .Left in ctx.input.pressed && !ui.rect_contains(ui.prev_rect(ctx, fmt.tprintf("lens layer %d actions", i)), ctx.input.mouse) {
		lp.swiped, open = 0, false
	}
	// The picture and the name: a drag-scrolled zone, so a finger's sideways swipe there
	// opens the row and a tap picks the layer.
	zone_w := width - (LAYER_SWIPE_W if open else LAYER_SLIDER_W + t.target)
	zone_name := fmt.tprintf("lens layer %d zone", i)
	offset, turn := ui.swipe_update(ctx, ui.id_of(ctx, zone_name), ui.prev_rect(ctx, zone_name))
	if turn == 1 && allowed {
		lp.swiped_id, lp.swiped = obj.id, i + 1
		lp.swipes += 1
	} else if turn == -1 && open {
		lp.swiped = 0
	}
	mark := ui.vertex_mark(ctx)
	ui.begin(ctx, zone_name, {direction = .Row, center = true, gap = 8, width = zone_w, height = LAYER_ROW_H, padding = 6, drag_scroll = true})
	p := ui.area(ctx, fmt.tprintf("Layer picture##lens layer %d", i), {LAYER_PICTURE, LAYER_PICTURE}, drag = false)
	pic := p.rect
	if !layer_picture_draw(app, obj, i, pic, fade) {
		ui.fill_rect(ctx, pic, t.radius_small, t.fill)
		ui.icon(ctx, ICON_LAYERS, {pic.x + pic.w * 0.5, pic.y + pic.h * 0.5}, t.icon_small, ui.color_fade(t.text_tertiary, fade))
	}
	on_mask := lens_layer_mask_badge(app, obj, i, p, picked, fade)
	rec := recording == i
	words_w := zone_w - LAYER_PICTURE - 20
	// The record dot beside the name, and the name with its strength under it as one area
	// to tap, rest on, swipe and hold.
	ui.begin(ctx, fmt.tprintf("lens layer %d words", i), {direction = .Row, center = true, gap = 0, width = words_w})
	// The record dot: red while strokes go into the layer; a tap records or stops.
	d := ui.area(ctx, fmt.tprintf("Record into this layer##lens layer %d", i), {24, 44}, drag = false)
	dc := [2]f32{d.rect.x + 8, d.rect.y + 13}
	if rec {
		ui.fill_circle(ctx, dc, 7, ui.color_fade(LAYER_RECORD_COLOR, 0.25))
		ui.fill_circle(ctx, dc, 4.5, LAYER_RECORD_COLOR)
	} else {
		ui.icon(ctx, ICON_CIRCLE, dc, t.icon_small - 4, t.text_tertiary if d.hovered else ui.color_fade(t.text_tertiary, 0.6))
	}
	ui.tip(ctx, d.id, d.rect, "Stop recording" if rec else "Record into this layer")
	if d.clicked && allowed {
		stroke_finish(app)
		if sculpt.sculptor_layer_record(s, -1 if rec else i) do history_record(app, obj, .Layer, "Stop recording" if rec else "Record into layer")
		app.ui.layer_selected = i
	}
	weight: ui.Font = .Semibold if picked else .Regular
	a := ui.area(ctx, fmt.tprintf("%s##lens layer pick %d", sculpt.sculptor_layer_name(l), i), {words_w - 24, 44}, drag = false)
	if ui.secondary(ctx) && allowed do layer_menu_open(app, obj, i, {ctx.input.mouse.x, ctx.input.mouse.y, 1, 1}, .Pointer)
	ui.text(ctx, ui.text_fit(ctx, sculpt.sculptor_layer_name(l), t.text_size, a.rect.w, weight), a.rect.x, a.rect.y + 13, t.text_size, ui.color_fade(t.text, fade), weight)
	caption := fmt.tprintf("%.2f%s", l.strength, " · recording" if rec else " · painting mask" if layer_mask_painting(app, obj) == i else " · hidden" if !l.visible else "")
	ui.text(ctx, caption, a.rect.x - 24 + 2, a.rect.y + 33, t.caption_size, LAYER_RECORD_COLOR if rec else ui.color_fade(t.text_tertiary, fade))
	ui.end(ctx)
	ui.end(ctx)
	ui.transform_since(ctx, mark, offset = {min(offset, 0) if !open else max(offset, 0), 0})
	if a.clicked || (p.clicked && !on_mask) {
		if open do lp.swiped = 0
		else do app.ui.layer_selected = i
	}
	if ((a.hovered || p.hovered) && ctx.input.pointer != .Finger) || a.held || p.held do layer_tint_rest(app, obj, i)

	if open {
		// Swiped open: Merge down and Delete, as an iOS list's row offers them.
		ui.begin(ctx, fmt.tprintf("lens layer %d actions", i), {direction = .Row, gap = 4, center = true, width = LAYER_SWIPE_W})
		if ui.icon_button(ctx, fmt.tprintf("Merge down##lens layer swipe %d", i), ICON_MERGE, enabled = allowed && i > 0) {
			app.ui.layer_selected = i
			layer_action(app, .Merge_Down)
			lp.swiped = 0
		}
		if ui.icon_button(ctx, fmt.tprintf("Delete layer##lens layer swipe %d", i), ui.ICON_TRASH, enabled = allowed) {
			layer_remove(app, obj, i, bake = false)
			lp.swiped = 0
		}
		ui.end(ctx)
	} else {
		lens_layer_strength(app, obj, i, LAYER_SLIDER_W, fade)
		if ui.icon_button(ctx, fmt.tprintf("Show or hide##lens layer %d", i), ui.ICON_EYE if l.visible else ui.ICON_EYE_OFF, enabled = allowed, size = t.target) {
			stroke_finish(app)
			_ = sculpt.sculptor_layer_set(s, i, l.strength, !l.visible)
			if sculpt.sculptor_stroke_end(s) do history_record(app, obj, .Layer, "Show layer" if l.visible else "Hide layer")
		}
	}
	ui.end(ctx)
}

// A row's mask badge, on its picture's lower right corner, as Photoshop shows a layer's
// mask beside its picture: the mask's glyph once the layer has one, dashed with a plus on
// the picked row while it has none, ringed in the accent while it is painted. A tap on the
// picture's right half, where the badge is, picks the mask and the Mask brush, or puts the
// sculpt mask and the brush from before back; the row stays narrow enough for the name.
// True when the picture's press is the badge's.
@(private = "file")
lens_layer_mask_badge :: proc(app: ^App, obj: ^Object, i: int, p: ui.Area, picked: bool, fade: f32) -> bool {
	ctx := &app.kit.ctx
	t := ctx.theme
	s := object_sculptor(obj)
	painting := layer_mask_painting(app, obj) == i
	has := sculpt.sculptor_layer_has_mask(s, i)
	if !has && !picked && !painting do return false
	pic := p.rect
	sq := ui.Rect{pic.x + pic.w - LAYER_MASK_SIDE + 3, pic.y + pic.h - LAYER_MASK_SIDE + 3, LAYER_MASK_SIDE, LAYER_MASK_SIDE}
	c := [2]f32{sq.x + sq.w * 0.5, sq.y + sq.h * 0.5}
	reach := ui.Rect{pic.x + pic.w * 0.5, pic.y, pic.w * 0.5, pic.h}
	over := ui.rect_contains(reach, ctx.input.mouse)
	// A ring of the panel's colour parts the badge from the picture under it.
	ui.fill_rect(ctx, {sq.x - 2, sq.y - 2, sq.w + 4, sq.h + 4}, t.radius_small + 2, t.surface)
	if has {
		ui.fill_rect(ctx, sq, t.radius_small, ui.color_fade(t.text, fade * 0.9))
		ui.icon(ctx, ICON_CONTRAST, c, t.icon_small - 8, t.surface)
	} else {
		// A dashed square: three short strokes a side, as an empty slot reads.
		line := ui.color_fade(t.text_secondary, fade * (1 if p.hovered && over else 0.8))
		ui.fill_rect(ctx, sq, t.radius_small, t.fill)
		dash := f32(LAYER_MASK_SIDE) / 5
		for k in 0 ..< 3 {
			o := f32(k) * dash * 2
			ui.fill_rect(ctx, {sq.x + o, sq.y, dash, 1}, 0, line)
			ui.fill_rect(ctx, {sq.x + o, sq.y + sq.h - 1, dash, 1}, 0, line)
			ui.fill_rect(ctx, {sq.x, sq.y + o, 1, dash}, 0, line)
			ui.fill_rect(ctx, {sq.x + sq.w - 1, sq.y + o, 1, dash}, 0, line)
		}
		ui.icon(ctx, ui.ICON_PLUS, c, t.icon_small - 10, line)
	}
	if painting do ui.stroke_rect(ctx, {sq.x - 2, sq.y - 2, sq.w + 4, sq.h + 4}, t.radius_small + 2, t.accent, 2)
	if over do ui.tip(ctx, p.id, reach, "Stop painting the mask" if painting else "Paint this layer's mask" if has else "Add a mask to this layer: paint where it hides")
	if p.clicked && over && layers_allowed(obj) {
		if painting do layer_mask_stop(app, restore = true)
		else do layer_mask_paint(app, obj, i)
		return true
	}
	return p.clicked && over
}

// A row's strength: a slim bar `w` points wide filled from 0 to the strength, −1 to 2,
// or ±5 with Wide ±5 (or a strength set wide), dragged in place; a drag is one undo step.
@(private = "file")
lens_layer_strength :: proc(app: ^App, obj: ^Object, i: int, w, fade: f32) {
	ctx := &app.kit.ctx
	t := ctx.theme
	s := object_sculptor(obj)
	l := &sculpt.sculptor_layers(s)[i]
	strength := l.strength
	lo, hi := f32(-1), f32(2)
	dragged := app.ui.layer_dragging && app.ui.layer_drag_id == obj.id
	wide := app.ui.layer_drag_wide if dragged else (app.ui.layer_wide || strength < lo || strength > hi)
	if wide do lo, hi = -5, 5
	enabled := layers_allowed(obj)
	a := ui.area(ctx, fmt.tprintf("Strength##lens layer %d", i), {w, LAYER_ROW_H})
	track := ui.Rect{a.rect.x + 6, a.rect.y + a.rect.h * 0.5 - 2, a.rect.w - 12, 4}
	at :: proc(track: ui.Rect, v, lo, hi: f32) -> f32 {return track.x + track.w * clamp((v - lo) / (hi - lo), 0, 1)}
	if enabled && a.held {
		// Dragging a layer's strength picks it, as the foot's buttons then act on it.
		app.ui.layer_selected = i
		v := lo + (hi - lo) * clamp((a.mouse.x - track.x) / max(track.w, 1), 0, 1)
		// A hundredth at a time, as the value reads, and 0 and 1 catch the drag a little.
		v = f32(int(v * 100 + (0.5 if v >= 0 else -0.5))) / 100
		if abs(v) < 0.04 do v = 0
		if abs(v - 1) < 0.04 do v = 1
		if v != strength {
			if !app.ui.layer_dragging || app.ui.layer_drag_id != obj.id {
				layer_drag_finish(app)
				stroke_finish(app)
				app.ui.layer_dragging, app.ui.layer_drag_id, app.ui.layer_drag_wide = true, obj.id, wide
			}
			_ = sculpt.sculptor_layer_set(s, i, v, l.visible)
		}
	}
	colour := ui.color_fade(t.accent, fade * (1 if enabled else 0.4))
	ui.fill_rect(ctx, track, 2, t.track)
	zero, now := at(track, 0, lo, hi), at(track, l.strength, lo, hi)
	ui.fill_rect(ctx, {min(zero, now), track.y, max(abs(now - zero), 1), track.h}, 2, colour)
	ui.fill_rect(ctx, {zero - 0.5, track.y - 3, 1, track.h + 6}, 0, t.text_tertiary)
	ui.fill_circle(ctx, {now, track.y + track.h * 0.5}, 6 if a.held else 5, ui.color_fade(t.text, fade))
	ui.tip(ctx, a.id, a.rect, fmt.tprintf("Strength %.2f: drag to dial the layer's work up, down, past full or into reverse", l.strength))
}

// Opens the menu of layer `index` of `obj` beside `anchor`.
layer_menu_open :: proc(app: ^App, obj: ^Object, index: int, anchor: ui.Rect, side: ui.Side) {
	lp := &app.kit.layer_panel
	lp.menu, lp.menu_at, lp.menu_id, lp.menu_layer = true, anchor, obj.id, index
	lp.swiped = 0
	lp.menus += 1
	app.ui.layer_selected = index
}

// The layer menu, over every panel: everything that acts on one layer.
kit_layer_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	lp := &k.layer_panel
	obj := object_by_id(app, lp.menu_id)
	if obj == nil || selected_object(app) != obj {
		lp.menu = false
		return
	}
	s := object_sculptor(obj)
	layers := sculpt.sculptor_layers(s)
	i := lp.menu_layer
	if i < 0 || i >= len(layers) {
		lp.menu = false
		return
	}
	if !ui.popover_begin(ctx, "layer menu", &lp.menu, lp.menu_at, .Pointer if lp.menu_at.w <= 1 else .Above_Center, {direction = .Column, gap = 0, padding = 6, width = 280}) do return
	defer ui.popover_end(ctx)
	l := &layers[i]
	allowed := layers_allowed(obj)
	app.ui.layer_selected = i
	ui.begin(ctx, "layer menu head", {direction = .Column, gap = 2, padding = 8})
	ui.label(ctx, sculpt.sculptor_layer_name(l), t.text_size, t.text, .Semibold)
	ui.label(ctx, fmt.tprintf("%s · strength %.2f%s", object_label(obj), l.strength, "" if l.visible else " · hidden"), t.small_size, t.text_secondary)
	ui.end(ctx)
	ui.divider(ctx, across = true)
	rec := sculpt.sculptor_layer_recording(s) == i
	picked := false
	if ui.menu_item(ctx, "Rename...", glyph = ui.ICON_PENCIL) {
		app.kit.rename = {open = true, id = obj.id, layer = i + 1, at = lp.menu_at}
		picked = true
	}
	if ui.menu_item(ctx, "Stop recording" if rec else "Record into it", glyph = ICON_CIRCLE, enabled = allowed) {
		stroke_finish(app)
		if sculpt.sculptor_layer_record(s, -1 if rec else i) do history_record(app, obj, .Layer, "Stop recording" if rec else "Record into layer")
		picked = true
	}
	if ui.menu_item(ctx, "Hide" if l.visible else "Show", glyph = ui.ICON_EYE_OFF if l.visible else ui.ICON_EYE, enabled = allowed) {
		stroke_finish(app)
		_ = sculpt.sculptor_layer_set(s, i, l.strength, !l.visible)
		if sculpt.sculptor_stroke_end(s) do history_record(app, obj, .Layer, "Show layer" if l.visible else "Hide layer")
		picked = true
	}
	ui.divider(ctx, across = true)
	// The layer's mask: painting it, and what acts on it whole.
	painting := layer_mask_painting(app, obj) == i
	has := sculpt.sculptor_layer_has_mask(s, i)
	if ui.menu_item(ctx, "Stop painting the mask" if painting else "Paint its mask" if has else "Add a mask", glyph = ICON_CONTRAST, enabled = allowed) {
		if painting do layer_mask_stop(app, restore = true)
		else do layer_mask_paint(app, obj, i)
		picked = true
	}
	if ui.menu_item(ctx, "Invert the mask", glyph = ICON_FLIP_VIEW, enabled = allowed, hint = "Hides the layer where it showed and shows it where it hid") {
		layer_mask_edit(app, obj, i, .Invert)
		picked = true
	}
	if ui.menu_item(ctx, "Mask from the sculpt mask", glyph = ui.ICON_COPY, enabled = allowed && layer_mask_sculpt_ready(obj), hint = "Hides the layer where the sculpt mask is") {
		layer_mask_edit(app, obj, i, .From_Sculpt)
		picked = true
	}
	if ui.menu_item(ctx, "Delete the mask", glyph = ui.ICON_TRASH, enabled = allowed && has, hint = "Shows the whole layer again; undo brings the mask back") {
		layer_mask_edit(app, obj, i, .Clear)
		picked = true
	}
	ui.divider(ctx, across = true)
	Row :: struct {
		action: Layer_Action,
		label:  string,
		glyph:  rune,
	}
	rows := [?]Row{{.Duplicate, "Duplicate", ui.ICON_COPY}, {.Invert, "Invert", ICON_FLIP_VIEW}, {.Merge_Down, "Merge down", ICON_MERGE}, {.Move_Up, "Move up", ui.ICON_CHEVRON_UP}, {.Move_Down, "Move down", ui.ICON_CHEVRON_DOWN}}
	for r in rows {
		if ui.menu_item(ctx, fmt.tprintf("%s##layer menu", r.label), glyph = r.glyph, enabled = layer_action_ready(app, r.action)) {
			layer_action(app, r.action)
			picked = true
		}
	}
	ui.divider(ctx, across = true)
	if ui.menu_item(ctx, "Bake into the base", glyph = ICON_LOCK, enabled = allowed, hint = "Keeps the layer's work at its strength in the surface and takes the layer away") {
		layer_remove(app, obj, i, bake = true)
		picked = true
	}
	if ui.menu_item(ctx, "Delete layer##layer menu", glyph = ui.ICON_TRASH, tone = .Danger, enabled = allowed, hint = "Takes the layer and its work away; undo brings it back") {
		layer_remove(app, obj, i, bake = false)
		picked = true
	}
	if picked do lp.menu = false
}
