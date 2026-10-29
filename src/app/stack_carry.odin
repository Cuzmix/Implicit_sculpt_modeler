package main

import "core:fmt"
import "core:math/linalg"

import sdl "vendor:sdl3"

import "../ui"

// Carrying palettes (round 3, PR 5b): a card's grip carries its group, and a tab dragged
// out of a group's row carries that tab alone. While it is held, the target under the
// pointer shows: a group's header or tab row joins it (a mark where the tab would go),
// the line between the docked cards moves it there, and well clear of the stack it floats
// where it is let go. A pill over the pointer says which. The targets are the rects laid
// out this frame (`seen`), tested front to back: floating groups first, then the docked
// stack, so a floating group over the docked cards takes the drop. Escape, or a cancelled
// touch, drops nothing.

// What a carry holds: a group (by any of its cards) or, with `tab`, one tab.
Stack_Carry :: struct {
	card:    Stack_Card,
	tab:     bool,
	started: bool,
}

Stack_Target_Kind :: enum u8 {
	None, // nothing changes: over itself, or its own place
	Join, // tabs of `host`'s group from `slot`
	Line, // the docked cards' slot `at`
	Float,
}

Stack_Target :: struct {
	kind: Stack_Target_Kind,
	host: Stack_Card,
	slot: int,
	at:   int,
}

// Called before the stack and its floating cards are laid out: the targets are this
// frame's only, so a card not drawn now (the stack shown as icons, a card left out or
// joined) is no target.
stack_frame_begin :: proc(k: ^Kit_State) {
	s := &k.stack
	s.seen = {}
	s.drop_at, s.head_at, s.row_at, s.tabs_at = {}, {}, {}, {}
}

// Follows the carry, once a frame after the stack and the floating cards are drawn (so
// its marks come out over them): while held, the target's mark and the pill; let go, the
// drop.
stack_carry_update :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	s := &k.stack
	in_ := ctx.input
	if s.carry_off {
		s.carry, s.target = nil, {}
		if .Left not_in in_.down do s.carry_off = false
		return
	}
	carry, ok := s.carry.?
	if !ok {
		s.target = {}
		return
	}
	if !carry.started {
		// What the strip opened over the view would cover the targets.
		carry.started = true
		s.carry = carry
		s.tab_open = false
	}
	if in_.cancel || key_pressed(&app.device, sdl.K_ESCAPE) {
		s.carry, s.target = nil, {}
		s.carry_off = .Left in in_.down
		return
	}
	target := stack_carry_target(app, in_.mouse, carry)
	s.target = target
	if .Left in in_.down {
		stack_carry_draw(app, carry, target, in_.mouse)
		return
	}
	s.carry, s.target = nil, {}
	stack_carry_drop(app, carry, target, in_.mouse)
}

// What letting `carry` go at `p` would do.
stack_carry_target :: proc(app: ^App, p: [2]f32, carry: Stack_Carry) -> Stack_Target {
	k := &app.kit
	s := &k.stack
	src := stack_host(s, carry.card)
	#reverse for ref in k.order {
		c, card := ref.(Stack_Card)
		if !card || c not_in s.floated || c not_in s.seen || !ui.rect_contains(s.drop_at[c], p) do continue
		if c == src do return {}
		return {kind = .Join, host = c, slot = stack_tab_slot(s, c, p)}
	}
	// A docked header is a band map: its top quarter (and a folded card's bottom one) is the
	// line, so folded cards still reorder; its middle and the tab row join.
	for c in s.order {
		if c in s.floated || c in s.hidden || c in s.joined || c not_in s.seen do continue
		if c == src && !carry.tab do continue
		if row := s.row_at[c]; row.w > 0 && ui.rect_contains(row, p) {
			if c == src do return {}
			return {kind = .Join, host = c, slot = stack_tab_slot(s, c, p)}
		}
		h := s.head_at[c]
		if h.w <= 0 || !ui.rect_contains(h, p) do continue
		band := max(h.h * 0.25, 10)
		if p.y < h.y + band || (c not_in s.open && p.y > h.y + h.h - band) do break
		if c == src do return {}
		return {kind = .Join, host = c, slot = len(stack_group(s, c))}
	}
	at, outside := stack_drop_at(app, p, carry.card if carry.tab else src)
	if outside do return {kind = .Float}
	if !carry.tab && src not_in s.floated && at == stack_docked_place(s, src) do return {}
	return {kind = .Line, at = at}
}

// The tab slot of group `host` under `p`: after the last tab whose middle `p` is past, and
// never before the host; after the last tab where the group shows no row.
@(private = "file")
stack_tab_slot :: proc(s: ^Lens_Stack, host: Stack_Card, p: [2]f32) -> int {
	group := stack_group(s, host)
	if s.row_at[host].w <= 0 do return len(group)
	slot := 1
	for x, i in group do if r := s.tabs_at[x]; r.w > 0 && p.x > r.x + r.w * 0.5 do slot = max(i + 1, 1)
	return slot
}

// How many docked groups stand above group `c`.
@(private = "file")
stack_docked_place :: proc(s: ^Lens_Stack, c: Stack_Card) -> int {
	n := 0
	for x in s.order {
		if x == c do break
		if x not_in s.floated && x not_in s.hidden && x not_in s.joined do n += 1
	}
	return n
}

// Lets `carry` go on `target` at `p`.
@(private = "file")
stack_carry_drop :: proc(app: ^App, carry: Stack_Carry, target: Stack_Target, p: [2]f32) {
	k := &app.kit
	s := &k.stack
	src := stack_host(s, carry.card)
	switch target.kind {
	case .None:
		return
	case .Join:
		if !stack_join_at(k, carry.card, carry.tab, target.host, target.slot) do return
	case .Line:
		if carry.tab do stack_take_out(k, carry.card)
		stack_move_to(app, carry.card if carry.tab else src, target.at)
	case .Float:
		if carry.tab {
			// A tab floats as large as the card it came out of.
			r := s.rects[src]
			stack_take_out(k, carry.card)
			s.rects[carry.card] = r
		}
		stack_float(app, carry.card if carry.tab else src, p)
	}
	s.drops += 1
}

// The carry's marks: the line, the tab slot or the group outlined, and over the pointer a
// pill with what is carried and what letting go does.
@(private = "file")
stack_carry_draw :: proc(app: ^App, carry: Stack_Carry, target: Stack_Target, p: [2]f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	s := &k.stack
	src := stack_host(s, carry.card)
	hint := ""
	switch target.kind {
	case .None:
	case .Line:
		x, w: f32
		for c in s.order {
			if c in s.floated || c in s.hidden || c in s.joined || c not_in s.seen do continue
			x, w = s.drop_at[c].x, s.drop_at[c].w
			break
		}
		y := stack_drop_y(app, target.at, carry.card if carry.tab else src)
		ui.fill_rect(ctx, {x, y - 1.5, w, 3}, 1.5, t.accent)
		hint = "Move here"
	case .Join:
		host := target.host
		group := stack_group(s, host)
		ui.stroke_rect(ctx, s.drop_at[host], t.radius_large, t.accent, 2)
		// The mark goes over the row, never into it, so the tabs under the pointer stay put.
		if row := s.row_at[host]; row.w > 0 {
			r := s.tabs_at[group[target.slot - 1]]
			ui.fill_rect(ctx, {r.x + r.w - 1.5, row.y + 6, 3, row.h - 12}, 1.5, t.accent)
		}
		hint = fmt.tprintf("Join %s", stack_title(app, stack_shown(s, host)))
	case .Float:
		hint = "Float here"
	}
	name := stack_title(app, carry.card if carry.tab else stack_shown(s, src))
	text := fmt.tprintf("%s · %s", name, hint) if hint != "" else name
	w := ui.text_width(ctx, text, t.small_size, .Semibold) + 44
	area := ui.safe_area(ctx)
	box := ui.Rect{clamp(p.x - w * 0.5, area.x + 8, area.x + area.w - w - 8), max(p.y - 72, area.y + 8), w, 32}
	ui.fill_rect(ctx, box, 16, t.surface)
	ui.stroke_rect(ctx, box, 16, t.accent if target.kind != .None else t.border_strong, 1)
	ui.icon(ctx, panel_kind_icon(app, carry.card if carry.tab else stack_shown(s, src)), {box.x + 18, box.y + 16}, t.icon_small, t.text_secondary)
	ui.text(ctx, text, box.x + 32, box.y + 16, t.small_size, t.text, .Semibold)
}

// Where among the other docked cards card `carried` let go at `p` lands (how many of them
// are above it), and whether `p` is well clear of the stack, to float the card.
stack_drop_at :: proc(app: ^App, p: [2]f32, carried: Stack_Card) -> (at: int, outside: bool) {
	s := &app.kit.stack
	lo, hi: [2]f32
	first := true
	for c in s.order {
		if c in s.floated || c in s.hidden || c in s.joined || c not_in s.seen do continue
		r := s.drop_at[c]
		if r.w <= 0 || r.h <= 0 do continue
		if c != carried && p.y > r.y + r.h * 0.5 do at += 1
		a, b := [2]f32{r.x, r.y}, [2]f32{r.x + r.w, r.y + r.h}
		lo, hi = (a if first else linalg.min(lo, a)), (b if first else linalg.max(hi, b))
		first = false
	}
	REACH :: 48
	outside = first || p.x < lo.x - REACH || p.x > hi.x + REACH || p.y > hi.y + REACH
	return
}

// The y of the line between the docked cards (but `carried`) where slot `at` is.
stack_drop_y :: proc(app: ^App, at: int, carried: Stack_Card) -> f32 {
	s := &app.kit.stack
	i := 0
	last: f32 = 0
	for c in s.order {
		if c in s.floated || c in s.hidden || c in s.joined || c not_in s.seen || c == carried do continue
		r := s.drop_at[c]
		if i == at do return r.y - COLUMN_GAP * 0.5
		last = r.y + r.h + COLUMN_GAP * 0.5
		i += 1
	}
	return last
}

// The carry for the exit stats: `none`, the group's host, or `Card:tab`; and the target
// under it.
stack_carry_text :: proc(k: ^Kit_State) -> string {
	c, ok := k.stack.carry.?
	if !ok do return "none"
	return fmt.tprintf("%v:tab", c.card) if c.tab else fmt.tprint(stack_host(&k.stack, c.card))
}
