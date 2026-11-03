package main

import "core:fmt"

import "../ui"

// Cards popped out of a dock's button: a card or section button anywhere but the rail
// (whose buttons dock their card in the stack's column, rail_dock.odin), and a button's
// long press that opens its section, show that card as a window of its own beside the
// button, one at a time, as Affinity's studio buttons pop out their panels. It is the
// stack's own floating card, so it has the stack's header, tabs or sections, resize
// handles and carry; while popped out its header holds Keep open (it stays as a floating
// card of the stack) and Close. A second tap on the button, Close, or another card popped
// out puts it back as it was: left out of the stack again, or folded where it stood. A
// card the stack shows already opens there instead, and a floating one comes to the front.

// The card popped out (its group's host) and how it was before, to put it back.
Card_Pop :: struct {
	host:    Panel_Kind,
	on:      bool,
	hidden:  bool, // it was left out of the stack (with its group)
	open:    bool,
	pops:    int, // for the exit stats
	// The button it popped out of and which side of it, to place it again by its laid-out
	// size the first frame that size is known (`place`).
	at:      ui.Rect,
	side:    ui.Side,
	place:   bool,
}

// The popped window's size as it is placed before it was ever laid out.
@(private = "file")
CARD_POP_SIZE :: [2]f32{STACK_W + 20, 360}

// Pops card `c` out beside `at` (the button, on `side` of it), or puts it back when it is
// the one popped out already.
card_pop_toggle :: proc(app: ^App, c: Panel_Kind, at: ui.Rect, side: ui.Side) {
	k := &app.kit
	s := &k.stack
	if !s.set do stack_default(k)
	host := stack_host(s, c)
	if k.card_pop.on && k.card_pop.host == host {
		card_pop_close(app)
		return
	}
	card_pop_close(app)
	kit_floats_close(k)
	// Already a window of its own: it comes to the front on that tab.
	if host in s.floated {
		stack_show_tab(s, c)
		s.folded -= {c}
		s.open += {host}
		float_raise(k, host)
		return
	}
	// Shown in the docked stack: it opens there.
	if host not_in s.hidden && k.inspector && !side_panel_open(k) {
		stack_reveal_card(app, c)
		return
	}
	k.card_pop = {host = host, on = true, hidden = host in s.hidden, open = host in s.open, pops = k.card_pop.pops + 1, at = at, side = side, place = true}
	for x in stack_group(s, host) do s.hidden -= {x}
	s.floated += {host}
	s.open += {host}
	stack_show_tab(s, c)
	s.folded -= {c}
	float_raise(k, host)
	size := s.sizes[host]
	if size.x <= 0 do size.x = CARD_POP_SIZE.x
	if size.y <= 0 do size.y = CARD_POP_SIZE.y
	card_pop_place(app, size)
}

// Places the popped card of `size` beside its button, clamped into the window.
card_pop_place :: proc(app: ^App, size: [2]f32) {
	k := &app.kit
	p := &k.card_pop
	at, side := p.at, p.side
	pos: [2]f32
	GAP :: 8
	#partial switch side {
	case .Left:         pos = {at.x - GAP - size.x, at.y}
	case .Above_Center: pos = {at.x + at.w * 0.5 - size.x * 0.5, at.y - GAP - size.y}
	case .Below:        pos = {at.x + at.w * 0.5 - size.x * 0.5, at.y + at.h + GAP}
	case:               pos = {at.x + at.w + GAP, at.y}
	}
	// A left-handed layout mirrors the sides its buttons name.
	if k.ctx.mirror && (side == .Left || side == .Right) do pos.x = at.x + at.w + GAP if side == .Left else at.x - GAP - size.x
	area := ui.safe_area(&k.ctx)
	pos.x = clamp(pos.x, area.x, max(area.x + area.w - size.x, area.x))
	pos.y = clamp(pos.y, area.y + kit_top(), max(area.y + area.h - size.y, area.y + kit_top()))
	ui.window_move(&k.ctx, &k.stack.windows[p.host], pos, size, 10)
}

// Pops out the card that holds section `sec` (the Brush card for a brush section while
// the brush is the tool, its group unfolded there).
card_pop_section :: proc(app: ^App, sec: Panel_Kind, at: ui.Rect, side: ui.Side) {
	c := stack_card_of(app, sec)
	card_pop_toggle(app, c, at, side)
	if c == .Brush do app.kit.stack.shut -= {sec}
}

// Puts the card popped out back as it was.
card_pop_close :: proc(app: ^App) {
	k := &app.kit
	p := &k.card_pop
	if !p.on do return
	s := &k.stack
	p.on = false
	if p.host not_in s.floated do return
	s.floated -= {p.host}
	s.windows[p.host] = {}
	if p.hidden do for x in stack_group(s, p.host) do s.hidden += {x}
	if !p.open do s.open -= {p.host}
}

// Keep open: the card popped out stays as a floating card of the stack.
card_pop_keep :: proc(app: ^App) {
	k := &app.kit
	if !k.card_pop.on do return
	k.card_pop.on = false
	stack_keep(k, k.card_pop.host, true)
}

// Whether card `c` (a group's host) is the one popped out.
card_popped :: proc(k: ^Kit_State, c: Panel_Kind) -> bool {
	return k.card_pop.on && k.card_pop.host == c && c in k.stack.floated
}

// Whether the popped card shows card or section `c`: for a bar button's lit state.
card_pop_shows :: proc(k: ^Kit_State, c: Panel_Kind) -> bool {
	s := &k.stack
	if !card_popped(k, stack_host(s, c)) do return false
	host := stack_host(s, c)
	if stack_as_sections(s, host) do return c not_in s.folded
	return stack_shown(s, host) == c
}

// The card popped out for the exit stats, or none.
card_pop_text :: proc(k: ^Kit_State) -> string {
	if !card_popped(k, k.card_pop.host) do return "none"
	return fmt.tprint(stack_shown(&k.stack, k.card_pop.host))
}
