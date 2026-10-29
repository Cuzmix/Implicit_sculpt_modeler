package main

import "core:fmt"

import "../ui"

// Paint as a toggle (the overhaul's round 3, PR 8b), as Nomad's Paint switch and ZBrush's
// Rgb/Zadd pair: at the end of the Sculpt dock, its dot the main colour. On, the sculpting
// brushes lay colour, moving the surface too (Sculpt + paint) or not (Paint only), as the
// colour island's switch says; off, they only sculpt. The brush's channel stays the one
// truth, so strokes, replay and files are unchanged; the toggle only remembers which
// painting channel to turn back on (Brush_Settings.paint_on).

// Turns painting on (the channel remembered) or off (Sculpt, remembering the channel).
paint_toggle :: proc(app: ^App) {
	b := &app.brush
	if b.channel == .Sculpt {
		b.channel = b.paint_on if b.paint_on != .Sculpt else .Both
	} else {
		b.paint_on, b.channel = b.channel, .Sculpt
	}
}

// Whether the colour island shows: in Sculpt, while the brushes paint (or the Paint brush,
// which always does, is held), with the dock in sight and History not in its place.
colour_island_shown :: proc(app: ^App) -> bool {
	k := &app.kit
	if k.spaces.current != .Sculpt || app.tool != .Brush || zone_hidden(k, .Dock) || k.history || lens_focus(k) do return false
	return app.brush.channel != .Sculpt || .Paint in BRUSHES[app.brush.kind].flags
}

// How far the action bar and the offer line stand higher for the island under them, from
// last frame's layout.
colour_island_lift :: proc(app: ^App) -> f32 {
	if !colour_island_shown(app) do return 0
	if size, _ := ui.prev_layout(&app.kit.ctx, "colour island"); size.y > 0 do return size.y + ACTION_BAR_GAP
	return 0
}

// The swatches of the colours picked last that the island shows, at most.
ISLAND_HISTORY :: 5

// The colour island, over the dock while painting: the main colour's well (a tap opens the
// colour popover on it), the second colour (a tap swaps them), the colours picked last, the
// Eyedropper and, for the sculpting brushes, Sculpt + paint or Paint only.
kit_colour_island :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	b := &app.brush
	c := &k.colors
	k.colour_island = colour_island_shown(app)
	if !k.colour_island do return
	dock := shelf_bottom_size(app)
	room := action_bar_room(app)
	segment := channel_brush(b.kind)
	segment_w: f32 = 260 if segment else 0
	fixed := t.target * 2 + 8 + t.target + segment_w + 4 * ACTION_BAR_PADDING
	history := clamp(int((room - fixed) / (SWATCH_SIDE + 2)), 0, min(ISLAND_HISTORY, c.history_count))
	mark := ui.vertex_mark(ctx)
	ui.begin_anchored(ctx, "colour island", .Center, .End, {0, t.edge + dock_lift(app) + dock.y + ACTION_BAR_GAP}, {direction = .Row, gap = 6, padding = ACTION_BAR_PADDING, radius = t.radius_large + 4, background = .Panel, center = true})
	// The main colour's well, as a colour field's: the popover sets it, taken next frame.
	well := "Main colour##colour island"
	id := ui.id_of(ctx, well)
	open := c.pop && c.pop_of == id
	if open && c.pop_dirty {
		b.color = c.pop_set
		c.pop_dirty = false
	}
	if ui.swatch(ctx, well, overlay_color({b.color.r, b.color.g, b.color.b, 1}), t.target, selected = open).clicked {
		if open do c.pop = false
		else do c.pop, c.pop_of, c.pop_dirty, c.pop_changed, c.pop_scroll = true, id, false, false, 0
		open = c.pop
	}
	if open do c.pop_at, c.pop_value, c.pop_alive = ctx.last_rect, b.color, true
	if ui.swatch(ctx, "Second colour: tap to swap##colour island", overlay_color({b.color2.r, b.color2.g, b.color2.b, 1}), t.target * 0.75).clicked do command_run(app, .Swap_Colors)
	if history > 0 {
		ui.divider(ctx, 24)
		for rgb, i in c.history[:history] {
			if ui.swatch(ctx, fmt.tprintf("%s##island history %d", hex_text(rgb), i), shade(rgb), SWATCH_SIDE).clicked {
				b.color = rgb
				color_history_push(c, rgb)
			}
		}
	}
	_ = command_button(app, .Eyedropper, glyph = COMMANDS[.Eyedropper].icon, icon_only = true)
	if segment {
		ui.divider(ctx, 24)
		names := [2]string{"Sculpt + paint", "Paint only"}
		on := 1 if b.channel == .Color else 0
		ui.begin(ctx, "colour island channel", {direction = .Column, width = segment_w})
		if picked := ui.tabs(ctx, "Paint channel", names[:], on); picked >= 0 {
			b.channel = .Color if picked == 1 else .Both
			b.paint_on = b.channel
		}
		ui.end(ctx)
	}
	ui.end(ctx)
	// It rises into place as painting turns on, as a popover does.
	shown := ui.presence(ctx, ui.id_of(ctx, "colour island shown"), true, t.popover_time, motion_class(.Popovers))
	if shown < 1 do ui.transform_since(ctx, mark, shown, offset = {0, (1 - shown) * 8})
}

// The Paint toggle's tile at the end of the Sculpt dock, on the pen side beside it as the
// active brush's tile stands on the other: lit while the brushes paint, a dot of the main
// colour in its corner. Laid out where the dock stood last frame, so the dock never moves.
shelf_paint_toggle :: proc(app: ^App) {
	ctx := &app.kit.ctx
	t := ctx.theme
	b := &app.brush
	strip := ui.prev_rect(ctx, "dock")
	if strip.w <= 0 do return
	w := PAINT_TOGGLE_W - 6
	x := strip.x - 6 - w if ctx.mirror else strip.x + strip.w + 6
	ui.begin_at(ctx, "shelf paint", {x, strip.y}, {direction = .Row, gap = 0, padding = SHELF_PAD, radius = t.radius_large + 4, background = .Panel, center = true, height = strip.h})
	defer ui.end(ctx)
	if ui.brush_tile(ctx, "Paint##shelf paint", ui.ICON_PAINTBRUSH, b.channel != .Sculpt, command_hint(app, .Paint_Toggle)) do command_run(app, .Paint_Toggle)
	r := ctx.last_rect
	dot := [2]f32{r.x + r.w - 14, r.y + 14}
	ui.fill_circle(ctx, dot, 5, overlay_color({b.color.r, b.color.g, b.color.b, 1}))
	ui.stroke_circle(ctx, dot, 5, t.border_strong, 1)
}

// The width the Paint toggle takes beside the dock: its tile, padding and the gap.
PAINT_TOGGLE_W :: ui.BRUSH_TILE.x + 2 * SHELF_PAD + 6
