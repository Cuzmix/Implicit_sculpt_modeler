package main

import "core:fmt"
import "core:strings"

import "../sculpt"
import "../ui"

// Columns (Panels v2): a card opens beside the dock button that asked for it, in the
// column on that side of the screen, over the view; a press on the view closes it again,
// and goes no further, so it never sculpts. Pin keeps a card open while sculpting: on a
// tablet a column shows one card at a time and the pinned one is the resting card, which
// comes back when the card opened over it closes; with a mouse a column splits in two,
// the pinned card above the one opened under it. On a tablet the pen side's column stops
// above the pen hand's palm. A card asked for by no button (Search, the top bar, a key)
// opens in the pen side's column.

// The sides of the screen in layout terms (the left-handed layout mirrors them): the
// off-hand's (Left) and the pen hand's (Right).
Column_Side :: enum u8 {
	Left,
	Right,
}

// A card in a column, and whether it is pinned.
Column_Card :: struct {
	card:   Card,
	pinned: bool,
	faded:  bool, // a stroke passed under it: it shows faint until the stroke ends
}

// One column: its cards, oldest first (the last is in front on a tablet), the button they
// opened from and which side of it (in layout terms, as popovers take it), how far each
// card's body is scrolled, and where each was laid out (this frame's once drawn, else the
// last).
Column :: struct {
	cards:   [2]Column_Card,
	count:   int,
	at:      ui.Rect,
	side:    ui.Side,
	scrolls: [Card]f32,
	rects:   [2]ui.Rect,
	frame:   int,
}

// The width of a card, and the gap between it and its dock and between two cards.
CARD_W :: KIT_INSPECTOR_W
CARD_GAP :: 8
// The part of the window's height, from the top, that the pen side's column keeps to on a
// tablet: the lower 42 % is where the pen hand's palm rests.
CARD_PALM_TOP :: 0.58
// The fewest points a card's body gets, however little room its column has.
CARD_BODY_MIN :: 120

// Whether a column splits in two: with a mouse, which rests on no palm and has the room;
// on a tablet one card shows at a time.
columns_split :: proc(app: ^App) -> bool {
	return app.device.pointer == .Mouse
}

// The column on the side of the screen that `at` (a button) stands on.
column_of :: proc(app: ^App, at: ui.Rect) -> Column_Side {
	ctx := &app.kit.ctx
	area := ui.safe_area(ctx)
	if at.w <= 0 do return .Right
	screen_right := at.x + at.w * 0.5 > area.x + area.w * 0.5
	return .Right if screen_right != ctx.mirror else .Left
}

// Where card `c` stands, if it is in a column.
card_find :: proc(k: ^Kit_State, c: Card) -> (side: Column_Side, i: int, ok: bool) {
	for &col, s in k.cards.columns {
		for j in 0 ..< col.count do if col.cards[j].card == c do return s, j, true
	}
	return
}

// Whether card `c` shows now: in front in its column (or split beside the other).
card_shown :: proc(app: ^App, c: Card) -> bool {
	side, i, ok := card_find(&app.kit, c)
	if !ok do return false
	col := &app.kit.cards.columns[side]
	return columns_split(app) || i == col.count - 1
}

// A tap on a button that opens card `c` (at `at`, its card opening `side` of it): opens the
// card in the column beside it, or closes it when it shows already. A pinned card shown
// under another on a tablet comes to the front instead.
card_toggle :: proc(app: ^App, c: Card, at: ui.Rect, side: ui.Side) {
	k := &app.kit
	if !k.cards.set do cards_default(k)
	if s, i, ok := card_find(k, c); ok {
		col := &k.cards.columns[s]
		if !columns_split(app) && i < col.count - 1 {
			column_close_unpinned(col)
			return
		}
		card_close(app, c)
		return
	}
	column_put(app, column_of(app, at), c, at, side)
}

// Opens card `c` where it shows already, or in the pen side's column beside the dock on
// that side (Search, the top bar, keys and scripts, which have no button beside it).
card_open :: proc(app: ^App, c: Card) {
	k := &app.kit
	if !k.cards.set do cards_default(k)
	if s, i, ok := card_find(k, c); ok {
		col := &k.cards.columns[s]
		if !columns_split(app) && i < col.count - 1 do column_close_unpinned(col)
		return
	}
	col := &k.cards.columns[.Right]
	at, side := col.at, col.side
	if col.count == 0 || at.w <= 0 do at, side = column_default_anchor(app)
	column_put(app, .Right, c, at, side)
}

// Where the pen side's column opens when no button asked: beside the dock on that edge,
// under the top bar.
@(private = "file")
column_default_anchor :: proc(app: ^App) -> (at: ui.Rect, side: ui.Side) {
	ctx := &app.kit.ctx
	area := ui.safe_area(ctx)
	x := area.x + area.w - kit_right(app) + CARD_GAP
	if ctx.mirror do x = area.x + kit_right(app) - CARD_GAP
	return {x, area.y + kit_top(), 0, 0}, .Left
}

// Puts card `c` in column `s`, opened from `at`: the pinned cards stay, the card opened
// over them before goes, and a full column lets its oldest go.
@(private = "file")
column_put :: proc(app: ^App, s: Column_Side, c: Card, at: ui.Rect, side: ui.Side) {
	k := &app.kit
	col := &k.cards.columns[s]
	column_close_unpinned(col)
	if col.count == len(col.cards) {
		col.cards[0] = col.cards[1]
		col.count -= 1
	}
	col.cards[col.count] = {card = c}
	col.count += 1
	col.at, col.side = at, side
	col.scrolls[c] = 0
	k.cards.opens += 1
}

// Closes the cards of column `col` that are not pinned.
@(private = "file")
column_close_unpinned :: proc(col: ^Column) -> (closed: bool) {
	n := 0
	for i in 0 ..< col.count {
		if col.cards[i].pinned {
			col.cards[n] = col.cards[i]
			n += 1
		} else {
			closed = true
		}
	}
	col.count = n
	return
}

// Closes card `c`, pinned or not.
card_close :: proc(app: ^App, c: Card) {
	k := &app.kit
	s, i, ok := card_find(k, c)
	if !ok do return
	col := &k.cards.columns[s]
	for j in i ..< col.count - 1 do col.cards[j] = col.cards[j + 1]
	col.count -= 1
	k.cards.closes += 1
}

// Pins card `c`, or unpins it. On a tablet a pinned card is its column's resting card, so
// pinning one lets the column's others go.
card_pin :: proc(app: ^App, c: Card) {
	k := &app.kit
	s, i, ok := card_find(k, c)
	if !ok do return
	col := &k.cards.columns[s]
	col.cards[i].pinned = !col.cards[i].pinned
	k.cards.pins += 1
	if !col.cards[i].pinned || columns_split(app) do return
	col.cards[0] = col.cards[i]
	col.count = 1
}

// Whether card `c` is pinned.
card_pinned :: proc(k: ^Kit_State, c: Card) -> bool {
	s, i, ok := card_find(k, c)
	return ok && k.cards.columns[s].cards[i].pinned
}

// Puts card `c` pinned in column `s` (a layout's `column` line), after the cards there.
card_rest :: proc(k: ^Kit_State, s: Column_Side, c: Card) {
	if !k.cards.set do cards_default(k)
	if _, _, ok := card_find(k, c); ok do return
	col := &k.cards.columns[s]
	if col.count == len(col.cards) do return
	col.cards[col.count] = {card = c, pinned = true}
	col.count += 1
}

// Before the cards are laid out: a press on the view closes every card not pinned, and
// goes no further, as a popover's dismissing press does, so it never sculpts.
columns_update :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	if !k.cards.set do cards_default(k)
	if ctx.input.pressed == {} || !ctx.input.mouse_valid || !(ctx.pointer_root == 0 || ctx.viewport_drag) do return
	closed := false
	for &col in k.cards.columns do if column_close_unpinned(&col) do closed = true
	if !closed do return
	ctx.swallow = true
	ctx.viewport_drag = false
	ctx.pointer_root = 0
}

// The cards in their columns, over the view and under the floating windows.
kit_columns :: proc(app: ^App) {
	k := &app.kit
	if !k.cards.set do cards_default(k)
	for &col, s in k.cards.columns {
		if col.count == 0 do continue
		first := 0 if columns_split(app) else col.count - 1
		x, y, room := column_place(app, s, &col)
		shown := col.count - first
		each := room if shown == 1 else (room - CARD_GAP) * 0.5
		for i in first ..< col.count {
			// Placed above its button, the card's foot stands at the button's head.
			top := y
			if col.side == .Above_Center && shown == 1 {
				h := ui.prev_rect(&k.ctx, card_root_name(col.cards[i].card)).h
				top = y + room - (h if h > 0 else room)
			}
			card_draw(app, &col, i, {x, top}, each)
			y += each + CARD_GAP
		}
		col.frame = k.frame
	}
}

// Where column `s` goes: its left edge and top, and the room its cards share down to what
// stands under it (the shelf where they would meet; on a tablet, the pen side's palm).
@(private = "file")
column_place :: proc(app: ^App, s: Column_Side, col: ^Column) -> (x, y, room: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	area := ui.safe_area(ctx)
	at, side := col.at, col.side
	// A left-handed layout mirrors the sides its buttons name.
	if ctx.mirror && (side == .Left || side == .Right) do side = .Right if side == .Left else .Left
	bottom := area.y + area.h - t.edge
	#partial switch side {
	case .Left, .Right:
		x = at.x - CARD_GAP - CARD_W if side == .Left else at.x + at.w + CARD_GAP
		// The column runs from under the top bar whichever button opened it, so two cards
		// split the whole height rather than what lies under the lower button.
		y = area.y + kit_top()
	case .Below:
		x = at.x + at.w * 0.5 - CARD_W * 0.5
		y = at.y + at.h + CARD_GAP
	case:
		x = at.x + at.w * 0.5 - CARD_W * 0.5
		y = area.y + kit_top()
		bottom = at.y - CARD_GAP
	}
	x = clamp(x, area.x + t.edge, max(area.x + area.w - t.edge - CARD_W, area.x + t.edge))
	// Clear of the shelf where they would meet across.
	if side != .Above_Center {
		lo, hi := shelf_bottom_span(app)
		left := x - area.x
		if ctx.mirror do left = area.w - (left + CARD_W)
		if hi + CARD_GAP > left && lo - CARD_GAP < left + CARD_W do bottom = min(bottom, area.y + area.h - dock_stack(app) - CARD_GAP)
	}
	if s == .Right && !columns_split(app) do bottom = min(bottom, area.y + area.h * CARD_PALM_TOP)
	room = max(bottom - y, CARD_BODY_MIN + t.target)
	return
}

// The root container name card `c` is laid out under.
card_root_name :: proc(c: Card) -> string {
	return fmt.tprintf("card %v", c)
}

// One card at `pos`, at most `room` tall: its header (icon, title, what it holds; the
// Symmetry card's axes; Pin and Close), then its body, scrolling where it is taller.
@(private = "file")
card_draw :: proc(app: ^App, col: ^Column, i: int, pos: [2]f32, room: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	entry := &col.cards[i]
	c := entry.card
	name := card_root_name(c)
	PAD :: 10
	// A stroke that passes under it fades it until the stroke ends, so the work under it
	// shows; the stroke stays the view's all the while.
	if !ui.viewport_dragging(ctx) || !app.ui.viewport_stroke {
		entry.faded = false
	} else if !entry.faded && ui.rect_contains(col.rects[i], ctx.input.mouse) {
		entry.faded = true
		k.panels_faded += 1
	}
	owner := ui.hash_under(0, name)
	fade := ui.tween(ctx, ui.salt(owner, 0x6a6465), PANEL_FADED if entry.faded else 1, t.hover_time)
	mark := ui.vertex_mark(ctx)
	shown := ui.presence(ctx, ui.salt(owner, 0x6f70656e), true, t.panel_time)
	ui.begin_at(ctx, name, pos, {direction = .Column, gap = 6, padding = PAD, width = CARD_W, radius = t.radius_large, background = .Panel})
	inner := f32(CARD_W - 2 * PAD)
	card_head(app, entry, inner)
	head := ctx.last_rect
	height := max(room - 2 * PAD - head.h - 6, CARD_BODY_MIN)
	scroll := kit_scroll_begin(ctx, "card body", &col.scrolls[c], owner, inner, height, 6)
	reveal_at := card_body(app, c, inner, scroll.at.y, scroll.shown)
	kit_scroll_end(ctx, scroll)
	k.cards.bodies[c] = {scroll.at, scroll.limit}
	if reveal_at >= 0 {
		col.scrolls[c] = reveal_at
		k.cards.reveal = nil
	}
	ui.end(ctx)
	col.rects[i] = ui.last_ended(ctx)
	if fade < 1 || shown < 1 do ui.transform_since(ctx, mark, fade * shown, 1, {}, {0, (1 - shown) * 12})
}

// A card's header: its icon, title and what it holds; the Symmetry card's axes as chips;
// Pin and Close.
@(private = "file")
card_head :: proc(app: ^App, entry: ^Column_Card, inner: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	c := entry.card
	CHIP :: 26
	ui.begin(ctx, "card head", {direction = .Row, width = inner, center = true})
	extras: f32 = 2 * t.target
	if c == .Symmetry do extras += 3 * CHIP + 4
	head := ui.area(ctx, "card title", {max(inner - extras, t.target), t.target})
	y := head.rect.y + head.rect.h * 0.5
	x := head.rect.x + 4
	ui.icon(ctx, card_icon(app, c), {x + 8, y}, t.icon_small, t.text_secondary)
	x += 26
	title := ui.text_fit(ctx, card_title(c), t.text_size, head.rect.x + head.rect.w - x - 6, .Semibold)
	ui.text(ctx, title, x, y, t.text_size, t.text, .Semibold)
	x += ui.text_width(ctx, title, t.text_size, .Semibold) + 10
	if line := card_summary(app, c); line != "" && head.rect.x + head.rect.w - x > 24 {
		ui.text(ctx, ui.text_fit(ctx, line, t.small_size, head.rect.x + head.rect.w - x - 6), head.rect.x + head.rect.w - 6, y, t.small_size, t.text_tertiary, align = .Right)
	}
	if c == .Symmetry {
		// The axes as small chips, a full target tall to press, a letter on a lit square
		// while on.
		for axis in sculpt.Axis {
			a := ui.area(ctx, fmt.tprintf("%v##card axis", axis), {CHIP, t.target})
			on := axis in app.brush.symmetry
			chip := ui.Rect{a.rect.x + 2, a.rect.y + a.rect.h * 0.5 - 11, CHIP - 4, 22}
			ui.fill_rect(ctx, chip, t.radius_small, t.accent_soft if on else (t.fill_hover if a.hovered else t.surface))
			if on do ui.stroke_rect(ctx, chip, t.radius_small, t.accent, 1)
			ui.text(ctx, fmt.tprint(axis), chip.x + chip.w * 0.5, chip.y + chip.h * 0.5, t.small_size, t.accent if on else t.text_secondary, .Semibold, .Center)
			ui.tip(ctx, a.id, a.rect, fmt.tprintf("Symmetry across %v", axis), command_hint(app, .Symmetry_X) if axis == .X else "")
			if a.clicked do app.brush.symmetry ~= {axis}
		}
		ui.spacer(ctx, 4)
	}
	if ui.icon_button(ctx, "Unpin" if entry.pinned else "Pin: keep it open while you sculpt", ICON_PIN, selected = entry.pinned) do card_pin(app, c)
	if ui.icon_button(ctx, "Close##card", ui.ICON_CLOSE) do card_close(app, c)
	ui.end(ctx)
}

// Card `c`'s scroll, wherever it is (its column's), for what scrolls it from inside (a
// row dragged near the body's edge); nil while it is in no column.
card_scroll :: proc(k: ^Kit_State, c: Card) -> ^f32 {
	s, _, ok := card_find(k, c)
	if !ok do return nil
	return &k.cards.columns[s].scrolls[c]
}

// Where card `c` was laid out (this frame or the last) while it shows; empty otherwise.
card_rect :: proc(app: ^App, c: Card) -> ui.Rect {
	k := &app.kit
	s, i, ok := card_find(k, c)
	if !ok || !card_shown(app, c) || k.cards.columns[s].frame < k.frame - 1 do return {}
	return k.cards.columns[s].rects[i]
}

// How far a card pinned on the pen side reaches in from the dock on that edge (its width
// and gap), for what keeps clear of a card that stays; 0 with none.
cards_right_room :: proc(app: ^App) -> f32 {
	if column_rest_rect(app, .Right).w > 0 do return CARD_W + CARD_GAP
	return 0
}

// Whether section `sec` is on screen: its card shown and the section unfolded.
section_on_screen :: proc(app: ^App, sec: Section) -> bool {
	return card_shown(app, section_card(sec)) && sec not_in app.kit.cards.shut
}

// Where the pinned card in front of column `s` was laid out (this frame or the last),
// for what keeps clear of a card that stays; empty with none.
column_rest_rect :: proc(app: ^App, s: Column_Side) -> ui.Rect {
	k := &app.kit
	col := &k.cards.columns[s]
	if col.frame < k.frame - 1 do return {}
	r: ui.Rect
	first := 0 if columns_split(app) else col.count - 1
	for i in max(first, 0) ..< col.count {
		if !col.cards[i].pinned do continue
		r = col.rects[i] if r.w <= 0 else ui.rect_union(r, col.rects[i])
	}
	return r
}

// The columns' lines in a layout: `column left|right <card>` for each pinned card, which a
// workspace keeps open; cards opened for a moment are no layout's.
columns_save :: proc(k: ^Kit_State, out: ^strings.Builder) {
	for &col, s in k.cards.columns {
		for i in 0 ..< col.count {
			if !col.cards[i].pinned do continue
			fmt.sbprintfln(out, "column %s %s", "left" if s == .Left else "right", card_word(col.cards[i].card))
		}
	}
}

// Reads a `column left|right <card>` line; one naming no card this build knows is passed
// over.
columns_read :: proc(k: ^Kit_State, f: []string) {
	if len(f) < 3 do return
	s: Column_Side
	switch {
	case strings.equal_fold(f[1], "left"):  s = .Left
	case strings.equal_fold(f[1], "right"): s = .Right
	case: return
	}
	if c, ok := card_from_word(f[2]); ok do card_rest(k, s, c)
}

// The columns for the exit stats: each side's cards oldest first, * on a pinned one, or
// none.
columns_text :: proc(k: ^Kit_State) -> string {
	b := strings.builder_make(context.temp_allocator)
	for &col, s in k.cards.columns {
		if strings.builder_len(b) > 0 do strings.write_byte(&b, ';')
		fmt.sbprintf(&b, "%s:", "left" if s == .Left else "right")
		for i in 0 ..< col.count {
			if i > 0 do strings.write_byte(&b, ',')
			fmt.sbprintf(&b, "%v%s", col.cards[i].card, "*" if col.cards[i].pinned else "")
		}
	}
	return strings.to_string(b)
}

// The card in front of the pen side's column for the exit stats, or none.
card_front_text :: proc(k: ^Kit_State) -> string {
	col := &k.cards.columns[.Right]
	if col.count == 0 do return "none"
	return strings.to_lower(fmt.tprint(col.cards[col.count - 1].card), context.temp_allocator)
}
