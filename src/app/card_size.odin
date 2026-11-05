package main

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

import "../ui"

// Every card's resize corner, as a toolbar's (arrange_resize_corner): a quarter curve on
// the card's foot, on the side facing the view, drawn while the pointer is on it or it is
// dragged. In a column a drag sideways sets the card's width, the column keeping the
// window's height; a floating card's corner, at its bottom right, sets its width and its
// body's height, as a window's in Affinity does. Widths go in CARD_SIZE_STEP steps from the
// card's own (card_width_base) to half the window, and a double tap on the corner puts the
// card back to its own size. Each space's layout keeps the sizes (`card_size` lines).

// The steps a width or height moves in while its corner is dragged, in points.
CARD_SIZE_STEP :: 10

// How wide card `c` is: its own width (card_width_base) until its corner widened it, at
// most half the window (never under its own).
card_width :: proc(app: ^App, c: Card) -> f32 {
	base := card_width_base(c)
	w := app.kit.cards.sizes[c].x
	if w <= base do return base
	return min(w, card_width_most(app, c))
}

// The widest card `c` may be: half the window, never less than its own width.
@(private = "file")
card_width_most :: proc(app: ^App, c: Card) -> f32 {
	return max(ui.safe_area(&app.kit.ctx).w * 0.5, card_width_base(c))
}

// How tall floating card `c`'s body is, given the most the window leaves it (`room`): the
// height its corner set, or `fit` (the most a floating card takes on its own) until then.
card_float_body :: proc(app: ^App, c: Card, room, fit: f32) -> f32 {
	h := app.kit.cards.sizes[c].y
	if h <= 0 do return fit
	return clamp(h, CARD_BODY_MIN, max(room, CARD_BODY_MIN))
}

// Card `c`'s resize corner on the card laid out at `r`: on its `right` foot or its left,
// `body` the height its body had, `floating` while it floats (its corner then sets the
// height too). Laid out after the card, as its own panel over it, so a press on it is the
// corner's and never the card's.
card_resize_corner :: proc(app: ^App, c: Card, r: ui.Rect, right: bool, body: f32, floating: bool) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	if r.w <= 0 || cards_as_sheet(k) do return
	// Inside the card's foot but for its edge's few points, so it keeps clear of the
	// shelf's corner where the card's column stops above the shelf.
	cx := r.x + r.w - DOCK_CORNER + 4 if right else r.x - 4
	cy := r.y + r.h - DOCK_CORNER
	ui.begin_at(ctx, fmt.tprintf("card corner %v", c), {cx, cy}, {direction = .Row})
	a := ui.area(ctx, fmt.tprintf("Resize %s##card corner", card_title(c)), {DOCK_CORNER, DOCK_CORNER})
	ui.end(ctx)
	cs := &k.cards
	if a.pressed {
		cs.sizing, cs.sizing_from, cs.sizing_press, cs.sizing_was = c, {r.w, body}, a.mouse, cs.sizes[c]
		if floating {
			// From now on the card keeps its top left where it is, so its corner follows
			// the pointer as it grows.
			area := ui.safe_area(ctx)
			w := &cs.windows[c]
			w.moved, w.x, w.y, w.offset = true, .Start, .Start, {r.x - area.x, r.y - area.y}
		}
	}
	if a.clicked && handle_double_tap(ctx, &cs.sizing_tap, a.id) {
		if cs.sizes[c] != {} do cs.resizes += 1
		cs.sizes[c] = {}
		cs.sizing = nil
	}
	active := false
	if sized, ok := cs.sizing.?; ok && sized == c {
		active = a.held
		if a.held {
			d := a.mouse - cs.sizing_press
			width := cs.sizing_from.x + (d.x if right else -d.x)
			width = clamp(math.round(width / CARD_SIZE_STEP) * CARD_SIZE_STEP, card_width_base(c), card_width_most(app, c))
			size := [2]f32{width if width > card_width_base(c) else 0, cs.sizes[c].y}
			if floating do size.y = max(math.round((cs.sizing_from.y + d.y) / CARD_SIZE_STEP) * CARD_SIZE_STEP, CARD_BODY_MIN)
			cs.sizes[c] = size
		} else {
			if cs.sizes[c] != cs.sizing_was do cs.resizes += 1
			cs.sizing = nil
		}
	}
	lit := active || a.hovered
	tip := "Drag to size the card; a double tap puts it back"
	if !lit {
		ui.tip(ctx, a.id, a.rect, tip)
		return
	}
	// The curve on the card's round corner, as a toolbar's, with its width while dragged.
	rad := t.radius_large
	o := [2]f32{r.x + r.w - rad if right else r.x + rad, r.y + r.h - rad}
	pts: [9][2]f32
	for i in 0 ..< len(pts) {
		ang := f32(i) / f32(len(pts) - 1) * math.PI * 0.5
		dx, dy := math.cos(ang) * rad, math.sin(ang) * rad
		pts[i] = {o.x + (dx if right else -dx), o.y + dy}
	}
	ui.polyline(ctx, pts[:], t.accent, 3.5 if active else 2.5)
	ui.tip(ctx, a.id, a.rect, tip)
	if active {
		words := fmt.tprintf("%.0f pt", r.w)
		if floating do words = fmt.tprintf("%.0f × %.0f pt", r.w, r.h)
		tw := ui.text_width(ctx, words, t.small_size, .Semibold) + 2 * ui.SPACE_S
		// Beside the card's foot, over the view, clear of the shelf under the column.
		ph := ui.line_height(t.small_size) + ui.SPACE_XS
		pill := ui.Rect{r.x + r.w + ui.SPACE_S if right else r.x - tw - ui.SPACE_S, r.y + r.h - ph, tw, ph}
		ui.fill_rect(ctx, pill, pill.h * 0.5, t.accent)
		ui.text(ctx, words, pill.x + pill.w * 0.5, pill.y + pill.h * 0.5, t.small_size, t.on_accent, .Semibold, .Center)
	}
}

// The cards' sizes in a layout: `card_size <card> <width> <height>` for each card its
// corner sized (0 for a size left as it comes).
cards_size_save :: proc(k: ^Kit_State, out: ^strings.Builder) {
	for c in Card do if k.cards.sizes[c] != {} do fmt.sbprintfln(out, "card_size %s %g %g", card_word(c), k.cards.sizes[c].x, k.cards.sizes[c].y)
}

// Reads a `card_size` line; one naming no card this build knows, or with a word missing or
// not a number, is passed over.
cards_size_read :: proc(k: ^Kit_State, f: []string) {
	if len(f) != 4 do return
	c, ok := card_from_word(f[1])
	if !ok do return
	w, okw := strconv.parse_f32(f[2])
	h, okh := strconv.parse_f32(f[3])
	if !okw || !okh || w != w || h != h do return
	k.cards.sizes[c] = {clamp(w, 0, WINDOW_OFFSET_MAX), clamp(h, 0, WINDOW_OFFSET_MAX)}
}

// The sized cards for the exit stats, as `References:420x0`, or none.
cards_size_text :: proc(k: ^Kit_State) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in Card do if k.cards.sizes[c] != {} {
		if strings.builder_len(b) > 0 do strings.write_byte(&b, ',')
		fmt.sbprintf(&b, "%v:%gx%g", c, k.cards.sizes[c].x, k.cards.sizes[c].y)
	}
	return strings.to_string(b) if strings.builder_len(b) > 0 else "none"
}
