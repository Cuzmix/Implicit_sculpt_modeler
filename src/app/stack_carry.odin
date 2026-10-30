package main

import "core:fmt"
import "core:math/linalg"

import sdl "vendor:sdl3"

import "../ui"

// Carrying palettes (round 3, PR 5b): a card's grip carries its group, and a tab dragged
// out of a group's row carries that tab alone. While it is held, the target under the
// pointer shows: a group's header or tab row joins it (a mark where the tab would go),
// the line between the docked cards moves it there, and well clear of the stack it floats
// where it is let go. A pill over the pointer says which. In the strip of icons, an icon
// carried past the others reorders the strip, and one resting on another icon for twice the
// long press (a ring fills round it) joins that group. The targets are the rects laid
// out this frame (`seen`), tested front to back: floating groups first, then the docked
// stack, so a floating group over the docked cards takes the drop. Escape, or a cancelled
// touch, drops nothing.

// What a carry holds: a group (by any of its cards) or, with `tab`, one tab.
Stack_Carry :: struct {
	card:    Panel_Kind,
	tab:     bool,
	started: bool,
}

Stack_Target_Kind :: enum u8 {
	None, // nothing changes: over itself, or its own place
	Join, // tabs of `host`'s group from `slot`
	Line, // the docked cards' slot `at`
	Float,
	Beside, // `host`'s second column, on its left with `left`
}

Stack_Target :: struct {
	kind:  Stack_Target_Kind,
	host:  Panel_Kind,
	slot:  int,
	at:    int,
	strip: bool, // the line is between the strip's icons
	left:  bool,
	// A drop beside that has no room: a docked group's goes below it, a floating one's
	// joins it as a tab.
	no_room: bool,
}

// How far beyond a group's side its beside target reaches, over the view.
STACK_BESIDE_REACH :: 96

// Called before the stack and its floating cards are laid out: the targets are this
// frame's only, so a card not drawn now (the stack shown as icons, a card left out or
// joined) is no target.
stack_frame_begin :: proc(k: ^Kit_State) {
	s := &k.stack
	s.seen, s.strip_seen = {}, {}
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
	stack_dwell_update(k, in_.mouse)
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
		c, card := ref.(Panel_Kind)
		if !card || c not_in s.floated || c not_in s.seen || !ui.rect_contains(s.drop_at[c], p) do continue
		if c == src do return {}
		return {kind = .Join, host = c, slot = stack_tab_slot(s, c, p)}
	}
	// Just beyond a group's side, over the view: beside it, as its second column. A docked
	// group's is on the view's side only, as the stack grows away from its edge.
	#reverse for ref in k.order {
		c, card := ref.(Panel_Kind)
		if !card || c not_in s.floated || c not_in s.seen || c == src do continue
		r := s.drop_at[c]
		if p.y < r.y || p.y > r.y + r.h do continue
		if p.x >= r.x - STACK_BESIDE_REACH && p.x < r.x do return stack_beside_target(app, c, true, carry)
		if p.x > r.x + r.w && p.x <= r.x + r.w + STACK_BESIDE_REACH do return stack_beside_target(app, c, false, carry)
	}
	if t, ok := stack_strip_target(app, p, carry); ok do return t
	for c in s.order {
		if c in s.floated || c in s.hidden || c in s.joined || c not_in s.seen || c == src do continue
		r := s.drop_at[c]
		if p.y < r.y || p.y > r.y + r.h do continue
		if stack_beside_left(k, c) {
			if p.x >= r.x - STACK_BESIDE_REACH && p.x < r.x do return stack_beside_target(app, c, true, carry)
		} else if p.x > r.x + r.w && p.x <= r.x + r.w + STACK_BESIDE_REACH {
			return stack_beside_target(app, c, false, carry)
		}
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

// Beside group `c` on its left or right: its second column, or where there is no room for
// one with 360 points of view left beside the rail, below it (docked) or a tab (floating).
@(private = "file")
stack_beside_target :: proc(app: ^App, c: Panel_Kind, left: bool, carry: Stack_Carry) -> Stack_Target {
	k := &app.kit
	s := &k.stack
	r := s.drop_at[c]
	w := stack_beside_width(k, c) + STACK_DIVIDER
	area := ui.safe_area(&k.ctx)
	ROOM :: 360 + 80
	room := r.x - w - area.x if left else area.x + area.w - (r.x + r.w + w)
	if _, two := stack_beside_of(s, c); two || room >= ROOM do return {kind = .Beside, host = c, left = left}
	if c in s.floated do return {kind = .Join, host = c, slot = len(stack_group(s, c)), no_room = true}
	src := stack_host(s, carry.card)
	at := 0
	for x in s.order {
		if x in s.floated || x in s.hidden || x in s.joined do continue
		if carry.tab || x != src do at += 1
		if x == c do break
	}
	if !carry.tab && src not_in s.floated && at == stack_docked_place(s, src) do return {no_room = true}
	return {kind = .Line, at = at, no_room = true}
}

// Over the strip of icons (or near it): resting on another group's icon long enough joins
// it, anywhere else the line between the icons; false away from the strip.
@(private = "file")
stack_strip_target :: proc(app: ^App, p: [2]f32, carry: Stack_Carry) -> (Stack_Target, bool) {
	k := &app.kit
	s := &k.stack
	if s.strip_seen == {} do return {}, false
	src := stack_host(s, carry.card)
	lo, hi: [2]f32
	first := true
	at := 0
	for c in s.order {
		if c not_in s.strip_seen do continue
		r := s.strip_at[c]
		if (carry.tab || c != src) && p.y > r.y + r.h * 0.5 do at += 1
		a, b := [2]f32{r.x, r.y}, [2]f32{r.x + r.w, r.y + r.h}
		lo, hi = (a if first else linalg.min(lo, a)), (b if first else linalg.max(hi, b))
		first = false
	}
	REACH :: 48
	if p.x < lo.x - REACH || p.x > hi.x + REACH || p.y < lo.y - REACH || p.y > hi.y + REACH do return {}, false
	if s.dwell_on && s.dwell != src && stack_dwell(k) >= 1 do return {kind = .Join, host = s.dwell, slot = len(stack_group(s, s.dwell))}, true
	if !carry.tab && src not_in s.floated && at == stack_docked_place(s, src) do return {}, true
	return {kind = .Line, at = at, strip = true}, true
}

// Follows the strip's icon under `p`: the rest starts again on another icon, or once the
// pointer strays past the slop, so passing over an icon never joins it.
@(private = "file")
stack_dwell_update :: proc(k: ^Kit_State, p: [2]f32) {
	s := &k.stack
	under: Maybe(Panel_Kind)
	for c in s.order do if c in s.strip_seen && ui.rect_contains(s.strip_at[c], p) do under = c
	c, ok := under.?
	if !ok {
		s.dwell_on = false
		return
	}
	if !s.dwell_on || s.dwell != c || linalg.length(p - s.dwell_at) > k.ctx.theme.slop {
		s.dwell, s.dwell_on, s.dwell_from, s.dwell_at = c, true, k.ctx.time, p
	}
}

// How far the rest on an icon has come toward joining it, 1 once it would: twice the long
// press, so it is never a tap's or a pass's.
stack_dwell :: proc(k: ^Kit_State) -> f32 {
	if !k.stack.dwell_on do return 0
	return f32(k.ctx.time - k.stack.dwell_from) / (2 * k.ctx.theme.long_press)
}

// The tab slot of group `host` under `p`: after the last tab whose middle `p` is past, and
// never before the host; after the last tab where the group shows no row.
@(private = "file")
stack_tab_slot :: proc(s: ^Lens_Stack, host: Panel_Kind, p: [2]f32) -> int {
	group := stack_group(s, host)
	if s.row_at[host].w <= 0 do return len(group)
	slot := 1
	for x, i in group do if r := s.tabs_at[x]; r.w > 0 && p.x > r.x + r.w * 0.5 do slot = max(i + 1, 1)
	return slot
}

// How many docked groups stand above group `c`.
@(private = "file")
stack_docked_place :: proc(s: ^Lens_Stack, c: Panel_Kind) -> int {
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
	case .Beside:
		if !stack_beside_join(k, carry.card, carry.tab, target.host, target.left) do return
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
		x, w, y: f32
		if target.strip {
			x, w, y = stack_strip_line(s, target.at, carry.card if carry.tab else src)
		} else {
			for c in s.order {
				if c in s.floated || c in s.hidden || c in s.joined || c not_in s.seen do continue
				x, w = s.drop_at[c].x, s.drop_at[c].w
				break
			}
			y = stack_drop_y(app, target.at, carry.card if carry.tab else src)
		}
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
	case .Beside:
		// The part the second column would take, beside the group.
		r := s.drop_at[target.host]
		w := stack_beside_width(k, target.host)
		x := r.x - w - STACK_DIVIDER if target.left else r.x + r.w + STACK_DIVIDER
		if _, two := stack_beside_of(s, target.host); two {
			ui.stroke_rect(ctx, r, t.radius_large, t.accent, 2)
		} else {
			ui.fill_rect(ctx, {x, r.y, w, r.h}, t.radius_large, ui.color_fade(t.accent, 0.16))
			ui.stroke_rect(ctx, {x, r.y, w, r.h}, t.radius_large, t.accent, 2)
		}
		hint = fmt.tprintf("Beside %s", stack_title(app, stack_shown(s, target.host)))
	}
	if target.no_room && target.kind != .None do hint = "No room beside: goes below" if target.kind != .Join else "No room beside: joins as a tab"
	// Resting on another icon of the strip: the icon grows a little and the ring fills
	// round it toward joining its group.
	if s.dwell_on && s.dwell != src && s.dwell in s.strip_seen {
		r := s.strip_at[s.dwell]
		g := ui.Rect{r.x - r.w * 0.04, r.y - r.h * 0.04, r.w * 1.08, r.h * 1.08}
		ui.stroke_rect(ctx, g, t.radius_medium, t.accent, 2)
		ui.hold_ring(ctx, {r.x + r.w * 0.5, r.y + r.h * 0.5}, r.w * 0.5 + 8, stack_dwell(k))
		if target.kind != .Join do hint = fmt.tprintf("Hold to join %s", stack_title(app, stack_shown(s, s.dwell)))
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
stack_drop_at :: proc(app: ^App, p: [2]f32, carried: Panel_Kind) -> (at: int, outside: bool) {
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

// Where the line between the strip's icons (but `carried`'s) at slot `at` goes: its x,
// width and y.
@(private = "file")
stack_strip_line :: proc(s: ^Lens_Stack, at: int, carried: Panel_Kind) -> (x, w, y: f32) {
	i := 0
	for c in s.order {
		if c not_in s.strip_seen || c == carried do continue
		r := s.strip_at[c]
		x, w = r.x, r.w
		if i == at do return x, w, r.y - 1
		y = r.y + r.h + 1
		i += 1
	}
	return
}

// The y of the line between the docked cards (but `carried`) where slot `at` is.
stack_drop_y :: proc(app: ^App, at: int, carried: Panel_Kind) -> f32 {
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
