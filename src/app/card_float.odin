package main

import "core:fmt"
import "core:strconv"
import "core:strings"

import "../ui"

// Floating cards (Panels v2): a card's title dragged out of its column tears the card out,
// and it floats where it is let go, as a window does, in front of the columns and among
// the other windows, until it is put back. Put back (its header's button), a hold on its
// grip, or a drop by its grip at a side of the window returns it to that side's column,
// pinned, since a card someone kept on screen is one they want to stay.

// How near a side of the window, in points past the dock there, a floating card's grip is
// let go to put the card back in that side's column.
CARD_RETURN_REACH :: 48

// Tears card `c` out of its column to float with its top left corner at `pos`, held by the
// press that dragged its title: from the next frame it follows the pointer as a window
// dragged by its grip does.
card_float_tear :: proc(app: ^App, c: Card, pos: [2]f32) {
	k := &app.kit
	ctx := &k.ctx
	s, i, ok := card_find(k, c)
	if !ok do return
	col := &k.cards.columns[s]
	for j in i ..< col.count - 1 do col.cards[j] = col.cards[j + 1]
	col.count -= 1
	area := ui.safe_area(ctx)
	w := &k.cards.windows[c]
	w^ = {moved = true, x = .Start, y = .Start, offset = pos - {area.x, area.y}}
	k.cards.floats += {c}
	k.cards.float_scrolls[c] = col.scrolls[c]
	k.cards.floated += 1
	float_raise(k, c)
	ui.window_grab(ctx, w, card_root_name(c), ctx.input.mouse - pos, card = true)
}

// Floats card `c` at `offset` from the safe area's top left (a layout's `card_float` line,
// or a test), out of any column it was in.
card_float_at :: proc(k: ^Kit_State, c: Card, offset: [2]f32) {
	if !k.cards.set do cards_default(k)
	if s, i, ok := card_find(k, c); ok {
		col := &k.cards.columns[s]
		for j in i ..< col.count - 1 do col.cards[j] = col.cards[j + 1]
		col.count -= 1
	}
	k.cards.windows[c] = {moved = true, x = .Start, y = .Start, offset = offset}
	k.cards.floats += {c}
	float_raise(k, c)
}

// Puts floating card `c` back in column `s`, pinned.
card_float_return :: proc(app: ^App, c: Card, s: Column_Side) {
	k := &app.kit
	if c not_in k.cards.floats do return
	card_glide_from(app, c, panel_rect(app, c))
	k.cards.floats -= {c}
	k.cards.returned += 1
	card_rest(k, s, c)
	// On a tablet a column shows one card: the one put back is its resting card now.
	col := &k.cards.columns[s]
	if !columns_split(app) && col.count > 1 {
		_, i, _ := card_find(k, c)
		col.cards[0] = col.cards[i]
		col.count = 1
	}
}

// Floating card `c`, drawn among the windows in their order; returns whether a press
// landed on it, to bring it in front.
card_float_draw :: proc(app: ^App, c: Card) -> (raised: bool) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	if c not_in k.cards.floats do return false
	w := &k.cards.windows[c]
	was_dragging := w.dragging
	mark := ui.motion_mark(ctx)
	PAD :: 10
	width := card_width(app, c)
	p := panel_begin(app, c, "", .End, .Start, {kit_right(app) + CARD_GAP, kit_top()}, {direction = .Column, gap = ui.SPACE_S, padding = PAD, width = width, radius = t.radius_large, background = .Panel}, card = true)
	inner := width - 2 * PAD
	_ = card_head(app, c, true, inner, floating = true)
	head := ctx.last_rect
	height := card_float_body(app, c, p.room - head.h - 6 - 24, max(min(p.room - head.h - 6 - 24, CARD_FLOAT_MAX_H), CARD_BODY_MIN))
	_, _ = card_content(app, c, inner, height, p.owner, &k.cards.float_scrolls[c])
	panel_end(app, &p)
	if w.dragging && !was_dragging do k.moving.lifts += 1
	card_float_motion_end(app, c, mark, panel_rect(app, c), w.dragging)
	if !w.dragging && !w.minimized do card_resize_corner(app, c, panel_rect(app, c), true, height, floating = true)
	if c == .Colours do kit_colors_menus(app)
	raised = p.raised
	// A hold on the grip puts it back on the pen side; a drag let go at a side of the
	// window puts it back in that side's column.
	if p.dock {
		card_float_return(app, c, .Right)
		return
	}
	if was_dragging && !w.dragging && c in k.cards.floats {
		if s, ok := card_return_side(app, ctx.input.mouse); ok do card_float_return(app, c, s)
	}
	return
}

// The tallest a floating card grows, so one dragged down leaves the view room.
CARD_FLOAT_MAX_H :: 640

// The column whose side of the window `at` is at: past the dock on that edge, or within
// CARD_RETURN_REACH of the window's side where it has none.
@(private = "file")
card_return_side :: proc(app: ^App, at: [2]f32) -> (s: Column_Side, ok: bool) {
	ctx := &app.kit.ctx
	area := ui.safe_area(ctx)
	right := area.x + area.w - kit_right(app) - CARD_RETURN_REACH
	left := area.x + kit_left(app) + CARD_RETURN_REACH
	switch {
	case at.x >= right: s, ok = .Right, true
	case at.x <= left:  s, ok = .Left, true
	}
	// A left-handed layout mirrors the sides.
	if ok && ctx.mirror do s = .Left if s == .Right else .Right
	return
}

// The floating cards in a layout: `card_float <card> <x> <y> <ox> <oy> <folded>`, as a
// window's line has its place (the edges it keeps to and how far in), written as for the
// right-handed layout.
cards_float_save :: proc(k: ^Kit_State, out: ^strings.Builder) {
	for c in Card do if c in k.cards.floats {
		w := k.cards.windows[c]
		if k.ctx.mirror do window_mirror(&w)
		fmt.sbprintfln(out, "card_float %s %v %v %g %g %d", card_word(c), w.x, w.y, w.offset.x, w.offset.y, int(w.minimized))
	}
}

// Reads a `card_float` line; one naming no card this build knows, or with a word missing,
// is passed over.
cards_float_read :: proc(k: ^Kit_State, f: []string) {
	if len(f) != 7 do return
	c, ok := card_from_word(f[1])
	if !ok do return
	w := ui.Window{moved = true, minimized = f[6] == "1"}
	for a in ui.Anchor {
		if strings.equal_fold(f[2], fmt.tprint(a)) do w.x = a
		if strings.equal_fold(f[3], fmt.tprint(a)) do w.y = a
	}
	x, okx := strconv.parse_f32(f[4])
	y, oky := strconv.parse_f32(f[5])
	if !okx || !oky || x != x || y != y do return
	w.offset = {clamp(x, -WINDOW_OFFSET_MAX, WINDOW_OFFSET_MAX), clamp(y, -WINDOW_OFFSET_MAX, WINDOW_OFFSET_MAX)}
	card_float_at(k, c, w.offset)
	k.cards.windows[c] = w
}

// The floating cards for the exit stats, as `Look,Mask`, or none.
cards_float_text :: proc(k: ^Kit_State) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in Card do if c in k.cards.floats {
		if strings.builder_len(b) > 0 do strings.write_byte(&b, ',')
		fmt.sbprint(&b, c)
	}
	return strings.to_string(b) if strings.builder_len(b) > 0 else "none"
}
