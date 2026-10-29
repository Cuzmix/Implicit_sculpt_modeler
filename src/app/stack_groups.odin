package main

import "core:fmt"
import "core:slice"
import "core:strings"

import "../ui"

// Palette groups (round 3, PR 5a): cards of the stack joined as tabs of one card, as the
// panel groups of Blender's properties, Photoshop and Nomad have them. A group is a run in
// the stack's order, its host first and then the cards joined to it, so a group never
// splits: a move moves the whole run. The host carries everything the group has as a card
// of the stack (open, floating, left out, its window, height, size and scroll), and the
// group shows one tab's content at a time (`shown`). A group of one is a card as it was.

// The host of card `c`'s group: c, or the nearest card before it in the order that is not
// joined.
stack_host :: proc(s: ^Lens_Stack, c: Stack_Card) -> Stack_Card {
	host := c
	for x in s.order {
		if x not_in s.joined do host = x
		if x == c do return host
	}
	return c
}

// The cards of the group `host` begins, the host first, in the stack's order.
stack_group :: proc(s: ^Lens_Stack, host: Stack_Card) -> []Stack_Card {
	out := make([dynamic]Stack_Card, 0, len(Stack_Card), context.temp_allocator)
	for x in s.order {
		if x == host {
			append(&out, x)
		} else if len(out) > 0 {
			if x not_in s.joined do break
			append(&out, x)
		}
	}
	return out[:]
}

// The tab group `host` shows: the one picked, while it is still in the group, or the host.
stack_shown :: proc(s: ^Lens_Stack, host: Stack_Card) -> Stack_Card {
	v := s.shown[host]
	if v != host && v in s.joined && stack_host(s, v) == host do return v
	return host
}

// The host of the docked group above card `c`'s group in the stack, which Join the card
// above joins it to; false when c is a tab already, floats, is left out or is the first.
stack_join_target :: proc(s: ^Lens_Stack, c: Stack_Card) -> (Stack_Card, bool) {
	if c in s.joined || c in s.floated || c in s.hidden do return {}, false
	above: Maybe(Stack_Card)
	for x in s.order {
		if x == c do break
		if x in s.joined || x in s.floated || x in s.hidden do continue
		above = x
	}
	h, ok := above.?
	return h, ok
}

// Joins card `c`'s group to the docked group above it, its cards becoming that group's
// last tabs and `c` the one shown. The joined card's own state as a card goes: its fold,
// height, size and scroll are the host's from now on.
stack_join :: proc(k: ^Kit_State, c: Stack_Card) -> bool {
	s := &k.stack
	if !s.set do stack_default(k)
	host, ok := stack_join_target(s, c)
	if !ok do return false
	run := stack_group(s, c)
	stack_order_place(s, run, host)
	for x in run do stack_tab_reset(s, x)
	s.joined += {c}
	s.open += {host}
	s.shown[host] = c
	if s.tab == c do s.tab = host
	s.joins += 1
	return true
}

// Takes card `c` out of its group: it becomes a card of its own, open, right after the
// group. When it was the host, the next tab takes the group's place as a card.
stack_take_out :: proc(k: ^Kit_State, c: Stack_Card) -> bool {
	s := &k.stack
	if !s.set do stack_default(k)
	host := stack_host(s, c)
	group := stack_group(s, host)
	if len(group) < 2 do return false
	shown := stack_shown(s, host)
	if c == host {
		next := group[1]
		s.joined -= {next}
		// What the group has as a card goes to its new host.
		if host in s.open do s.open += {next}
		if host in s.floated {
			s.floated += {next}
			s.windows[next] = s.windows[host]
			float_raise(k, next)
		}
		s.heights[next], s.sizes[next], s.scrolls[next] = s.heights[host], s.sizes[host], s.scrolls[host]
		s.shown[next] = shown if shown != host else next
		if s.tab == host do s.tab = next
		s.floated -= {host}
		s.windows[host], s.heights[host], s.sizes[host], s.scrolls[host] = {}, 0, {}, 0
		stack_order_place(s, {c}, next)
	} else {
		// Placed while it is still a tab, so the tabs after it stay in the group.
		stack_order_place(s, {c}, host)
		s.joined -= {c}
	}
	s.shown[c] = c
	s.open += {c}
	s.joins += 1
	return true
}

// Shows tab `c` of its group.
stack_show_tab :: proc(s: ^Lens_Stack, c: Stack_Card) {
	host := stack_host(s, c)
	if s.shown[host] != c do s.scrolls[host] = 0
	s.shown[host] = c
}

// A card's state as a card of the stack, cleared as it becomes a tab.
@(private = "file")
stack_tab_reset :: proc(s: ^Lens_Stack, c: Stack_Card) {
	s.open -= {c}
	s.floated -= {c}
	s.windows[c], s.heights[c], s.sizes[c], s.scrolls[c] = {}, 0, {}, 0
	s.shown[c] = c
}

// Takes `cards` out of the stack's order and puts them back, in their order, right after
// the group of card `after` (whose other cards stay where they are).
@(private = "file")
stack_order_place :: proc(s: ^Lens_Stack, cards: []Stack_Card, after: Stack_Card) {
	last := after
	for x in stack_group(s, stack_host(s, after)) do if !slice.contains(cards, x) do last = x
	rest := make([dynamic]Stack_Card, 0, len(Stack_Card), context.temp_allocator)
	for x in s.order do if !slice.contains(cards, x) do append(&rest, x)
	at := 0
	for x, i in rest do if x == last do at = i + 1
	inject_at(&rest, at, ..cards)
	for x, i in rest do s.order[i] = x
}

STACK_TAB_PAD :: 6

// The row of a group's tabs under its header, `width` wide: each tab its card's icon and
// title (icons alone when the titles do not fit), a tap showing that tab.
stack_tab_row :: proc(app: ^App, host: Stack_Card, width: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	s := &k.stack
	group := stack_group(s, host)
	if len(group) < 2 do return
	shown := stack_shown(s, host)
	room := width - 2 * STACK_TAB_PAD - 6
	natural: f32 = 0
	for c in group do natural += ui.text_width(ctx, panel_kind_title(app, c), t.text_size, .Semibold) + 28 + t.icon_small + 6
	names := make([]string, len(group), context.temp_allocator)
	glyphs := make([]rune, len(group), context.temp_allocator)
	tips := make([]string, len(group), context.temp_allocator)
	chosen := 0
	for c, i in group {
		title := panel_kind_title(app, c)
		names[i] = title if natural <= room else fmt.tprintf("##%v", c)
		glyphs[i] = panel_kind_icon(app, c)
		tips[i] = title
		if c == shown do chosen = i
	}
	ui.begin(ctx, "stack tab row", {direction = .Column, padding = STACK_TAB_PAD, width = width})
	picked := ui.tabs(ctx, "stack tabs", names, chosen, glyphs = glyphs, keys = tips if natural > room else nil)
	ui.end(ctx)
	if picked >= 0 do stack_show_tab(s, group[picked])
}

// The height the tab row takes in a floating card or the strip's panel: the tabs' well,
// the row's padding and the gap after it.
stack_tab_row_h :: proc(app: ^App, host: Stack_Card) -> f32 {
	if len(stack_group(&app.kit.stack, host)) < 2 do return 0
	return app.kit.ctx.theme.control + 2 * STACK_TAB_PAD + 6
}

// The tab each group shows where it is not its host, for the exit stats:
// `Brush=Symmetry`, or "none".
stack_shown_text :: proc(k: ^Kit_State) -> string {
	s := &k.stack
	b := strings.builder_make(context.temp_allocator)
	for c in s.order {
		if c in s.joined do continue
		v := stack_shown(s, c)
		if v == c do continue
		if strings.builder_len(b) > 0 do strings.write_byte(&b, ',')
		fmt.sbprintf(&b, "%v=%v", c, v)
	}
	return strings.to_string(b) if strings.builder_len(b) > 0 else "none"
}

// The layout's groups, a line each: `stack_group card:Brush *card:Symmetry`, the host
// first and a `*` on the tab shown when it is not the host. Groups of one write none.
stack_groups_save :: proc(k: ^Kit_State, out: ^strings.Builder) {
	s := &k.stack
	if !s.set do return
	for c in s.order {
		if c in s.joined do continue
		group := stack_group(s, c)
		if len(group) < 2 do continue
		shown := stack_shown(s, c)
		strings.write_string(out, "stack_group")
		for x in group do fmt.sbprintf(out, " %s%s", "*" if x == shown && x != c else "", panel_kind_name(x))
		strings.write_byte(out, '\n')
	}
}

// Reads a group line as stack_groups_save writes it, once the rest of the layout is in
// place (the stack's order first): names this version does not know, sections (which
// groups do not hold yet) and cards in a group already are passed over, and a line left
// with fewer than two cards makes no group.
stack_group_read :: proc(k: ^Kit_State, f: []string) {
	s := &k.stack
	if !s.set do stack_default(k)
	members := make([dynamic]Stack_Card, 0, len(Stack_Card), context.temp_allocator)
	shown: Maybe(Stack_Card)
	for word in f[1:] {
		kind, ok := panel_kind_from_name(strings.trim_prefix(word, "*"))
		if !ok do continue
		c, card := kind.(Stack_Card)
		if !card || slice.contains(members[:], c) || c in s.joined || len(stack_group(s, c)) > 1 do continue
		append(&members, c)
		if strings.has_prefix(word, "*") do shown = c
	}
	if len(members) < 2 do return
	host := members[0]
	tabs := members[1:]
	stack_order_place(s, tabs, host)
	for c in tabs {
		stack_tab_reset(s, c)
		s.joined += {c}
		// A tab is in or out of the stack as its group is.
		if host in s.hidden do s.hidden += {c}
		else do s.hidden -= {c}
	}
	if v, ok := shown.?; ok do s.shown[host] = v
}
