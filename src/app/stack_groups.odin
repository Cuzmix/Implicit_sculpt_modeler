package main

import "core:fmt"
import "core:slice"
import "core:strings"

import "../ui"

// Palette groups (round 3, PR 5a): cards of the stack joined as tabs of one card, as the
// panel groups of Blender's properties, Photoshop and Nomad have them, or shown as sections
// one under another (Affinity's studio panels), each with a slim header that folds it. A group is a run in
// the stack's order, its host first and then the cards joined to it, so a group never
// splits: a move moves the whole run. The host carries everything the group has as a card
// of the stack (open, floating, left out, its window, height, size and scroll), and the
// group shows one tab's content at a time (`shown`). A group of one is a card as it was.

// The host of card `c`'s group: c, or the nearest card before it in the order that is not
// joined.
stack_host :: proc(s: ^Lens_Stack, c: Panel_Kind) -> Panel_Kind {
	host := c
	for x in s.order {
		if x not_in s.joined do host = x
		if x == c do return host
	}
	return c
}

// The cards of the group `host` begins, the host first, in the stack's order.
stack_group :: proc(s: ^Lens_Stack, host: Panel_Kind) -> []Panel_Kind {
	out := make([dynamic]Panel_Kind, 0, len(Panel_Kind), context.temp_allocator)
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
stack_shown :: proc(s: ^Lens_Stack, host: Panel_Kind) -> Panel_Kind {
	v := s.shown[host]
	if v != host && v in s.joined && stack_host(s, v) == host do return v
	return host
}

// Whether group `host` shows its cards as sections: it holds more than one and was set to.
stack_as_sections :: proc(s: ^Lens_Stack, host: Panel_Kind) -> bool {
	return host in s.sections && len(stack_group(s, host)) > 1
}

// Shows group `host` as sections, or as tabs again.
stack_sections_set :: proc(k: ^Kit_State, host: Panel_Kind, on: bool) {
	s := &k.stack
	if on do s.sections += {host}
	else do s.sections -= {host}
	s.scrolls[host] = 0
}

// Expand all (`fold` false) or Collapse all on group `host`'s sections.
stack_sections_fold :: proc(k: ^Kit_State, host: Panel_Kind, fold: bool) {
	s := &k.stack
	for x in stack_group(s, host) {
		if fold do s.folded += {x}
		else do s.folded -= {x}
	}
	s.section_folds += 1
}

// Group `host`'s name as sections: its cards' titles, in order.
stack_sections_title :: proc(app: ^App, host: Panel_Kind) -> string {
	b := strings.builder_make(context.temp_allocator)
	for x, i in stack_group(&app.kit.stack, host) {
		if i > 0 do strings.write_string(&b, " · ")
		strings.write_string(&b, stack_title(app, x))
	}
	return strings.to_string(b)
}

// Group `host`'s sections, `inner` wide: each card's slim header (chevron, icon, title and,
// folded, what it holds) and, unfolded, its content, a hairline between one and the next.
// A tap on a header folds or unfolds that section alone; a long press opens the card's
// options.
stack_sections_body :: proc(app: ^App, host: Panel_Kind, inner: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	s := &k.stack
	for x, i in stack_group(s, host) {
		ui.begin(ctx, fmt.tprintf("stack section %v", x), {direction = .Column, gap = 6, width = inner})
		if i > 0 {
			r := ui.place(ctx, {inner, 1})
			ui.fill_rect(ctx, r, 0, t.border)
		}
		folded := x in s.folded
		h := ui.area(ctx, "stack section head", {inner, t.control})
		if h.hovered || h.held do ui.fill_rect(ctx, h.rect, t.radius_small, t.fill_pressed if h.held else t.fill_hover)
		y := h.rect.y + h.rect.h * 0.5
		px := h.rect.x + 6
		ui.icon(ctx, ui.ICON_CHEVRON_RIGHT if folded else ui.ICON_CHEVRON_DOWN, {px, y}, t.icon_small - 4, t.text_secondary)
		px += 16
		ui.icon(ctx, panel_kind_icon(app, x), {px, y}, t.icon_small - 2, t.text_secondary)
		px += 16
		title := stack_title(app, x)
		ui.text(ctx, title, px, y, t.small_size, t.text, .Semibold)
		px += ui.text_width(ctx, title, t.small_size, .Semibold) + 10
		if line := stack_summary(app, x); folded && line != "" && h.rect.x + h.rect.w - px > 24 {
			ui.text(ctx, ui.text_fit(ctx, line, t.small_size, h.rect.x + h.rect.w - px - 6), h.rect.x + h.rect.w - 6, y, t.small_size, t.text_tertiary, align = .Right)
		}
		ui.tip(ctx, h.id, h.rect, "Unfold" if folded else "Fold", label = false)
		if h.clicked {
			s.folded ~= {x}
			s.section_folds += 1
		}
		if ui.secondary(ctx) do stack_menu_open(app, x, h.rect)
		if !folded do panel_body(app, x, inner)
		ui.end(ctx)
	}
}

// The host of the docked group above card `c`'s group in the stack, which Join the card
// above joins it to; false when c is a tab already, floats, is left out or is the first.
stack_join_target :: proc(s: ^Lens_Stack, c: Panel_Kind) -> (Panel_Kind, bool) {
	if c in s.joined || c in s.floated || c in s.hidden do return {}, false
	above: Maybe(Panel_Kind)
	for x in s.order {
		if x == c do break
		if x in s.joined || x in s.floated || x in s.hidden do continue
		above = x
	}
	h, ok := above.?
	return h, ok
}

// Joins card `c`'s group to the docked group above it, its cards becoming that group's
// last tabs and `c` the one shown (Join the card above).
stack_join :: proc(k: ^Kit_State, c: Panel_Kind) -> bool {
	s := &k.stack
	if !s.set do stack_default(k)
	host, ok := stack_join_target(s, c)
	if !ok do return false
	return stack_join_at(k, c, false, host, len(stack_group(s, host)))
}

// Joins card `c` to the group `host` begins, as its tabs from `slot` on (between its tabs,
// never before the host, so a join never changes a group's host): `c` alone when `tab`
// (taken out of its own group first), else c's whole group. `c` becomes the tab shown. A
// joined card's own state as a card goes: its fold, height, size and scroll are the
// host's from now on. False when there is nothing to join: into its own group, or into a
// tab.
stack_join_at :: proc(k: ^Kit_State, c: Panel_Kind, tab: bool, host: Panel_Kind, slot: int) -> bool {
	s := &k.stack
	if !s.set do stack_default(k)
	src := stack_host(s, c)
	if host in s.joined || src == host do return false
	if tab && len(stack_group(s, src)) > 1 do stack_take_out(k, c, open = false)
	if !tab && c != src do return false
	run := stack_group(s, c)
	tabs := stack_group(s, host)
	stack_order_place(s, run, tabs[clamp(slot, 1, len(tabs)) - 1], exact = true)
	for x in run {
		if s.tab == x do s.tab = host
		stack_tab_reset(s, x)
		s.joined += {x}
		// A tab is in or out of the stack as its group is.
		if host in s.hidden do s.hidden += {x}
		else do s.hidden -= {x}
	}
	s.open += {host}
	// Shown in the column it landed in.
	stack_show_tab(s, c)
	s.joins += 1
	return true
}

// Takes card `c` out of its group: it becomes a card of its own, open unless `open` is
// false, right after the group. When it was the host, the next tab takes the group's
// place as a card.
stack_take_out :: proc(k: ^Kit_State, c: Panel_Kind, open := true) -> bool {
	s := &k.stack
	if !s.set do stack_default(k)
	host := stack_host(s, c)
	group := stack_group(s, host)
	if len(group) < 2 do return false
	shown := stack_shown(s, host)
	if c == host {
		next := group[1]
		s.joined -= {next}
		if host in s.sections do s.sections += {next}
		s.sections -= {host}
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
	if open do s.open += {c}
	s.joins += 1
	return true
}

// Ungroup: every tab of the group `host` begins becomes a card of its own where it is, the
// host keeping its fold and float, the others folded.
stack_ungroup :: proc(k: ^Kit_State, host: Panel_Kind) -> bool {
	s := &k.stack
	if !s.set do stack_default(k)
	group := stack_group(s, host)
	if host in s.joined || len(group) < 2 do return false
	for x in group[1:] {
		s.joined -= {x}
		s.shown[x] = x
	}
	s.shown[host] = host
	s.joins += 1
	return true
}

// Shows tab `c` of its group.
stack_show_tab :: proc(s: ^Lens_Stack, c: Panel_Kind) {
	host := stack_host(s, c)
	if s.shown[host] != c do s.scrolls[host] = 0
	s.shown[host] = c
}

// A card's state as a card of the stack, cleared as it becomes a tab.
@(private = "file")
stack_tab_reset :: proc(s: ^Lens_Stack, c: Panel_Kind) {
	s.open -= {c}
	s.floated -= {c}
	s.windows[c], s.heights[c], s.sizes[c], s.scrolls[c] = {}, 0, {}, 0
	s.shown[c] = c
	s.sections -= {c}
}

// Takes `cards` out of the stack's order and puts them back, in their order, right after
// the group of card `after` (whose other cards stay where they are), or right after
// `after` itself when `exact`.
stack_order_place :: proc(s: ^Lens_Stack, cards: []Panel_Kind, after: Panel_Kind, exact := false) {
	last := after
	if !exact do for x in stack_group(s, stack_host(s, after)) do if !slice.contains(cards, x) do last = x
	rest := make([dynamic]Panel_Kind, 0, len(Panel_Kind), context.temp_allocator)
	for x in s.order do if !slice.contains(cards, x) do append(&rest, x)
	at := 0
	for x, i in rest do if x == last do at = i + 1
	inject_at(&rest, at, ..cards)
	for x, i in rest do s.order[i] = x
}

STACK_TAB_PAD :: 6

// The row of a group's tabs under its header, `width` wide: each tab its card's icon and
// title (icons alone when the titles do not fit), a tap showing that tab.
stack_tab_row :: proc(app: ^App, head: Panel_Kind, width: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	s := &k.stack
	group := stack_group(s, head)
	if len(group) < 2 do return
	shown := stack_shown(s, head)
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
	// Each tab is a drag source too (stack_carry.odin): carried out of the row, it goes
	// alone.
	dragged := -1
	picked := ui.tabs(ctx, "stack tabs", names, chosen, glyphs = glyphs, keys = tips if natural > room else nil, dragged = &dragged)
	// Where each tab is, for a carry's drop between them: ui.tabs shares its row out
	// evenly inside its well's padding.
	row := ui.last_ended(ctx)
	w := (row.w - 6) / f32(len(group))
	for c, i in group do s.tabs_at[c] = ui.clipped(ctx, {row.x + 3 + f32(i) * w, row.y, w, row.h})
	ui.end(ctx)
	s.row_at[head] = ui.clipped(ctx, ui.last_ended(ctx))
	if picked >= 0 do stack_show_tab(s, group[picked])
	if dragged >= 0 && s.carry == nil do s.carry = Stack_Carry{card = group[dragged], tab = true}
}

// The height the tab row takes in a floating card or the strip's panel: the tabs' well,
// the row's padding and the gap after it.
stack_tab_row_h :: proc(app: ^App, host: Panel_Kind) -> f32 {
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

// The layout's groups, a line each: `stack_group tabs card:Brush *card:Symmetry`, how it
// shows (tabs or sections), the host first and a `*` on the tab shown when it is not the
// host, a `-` on a folded section. Groups of one write none.
stack_groups_save :: proc(k: ^Kit_State, out: ^strings.Builder) {
	s := &k.stack
	if !s.set do return
	for c in s.order {
		if c in s.joined do continue
		group := stack_group(s, c)
		if len(group) < 2 do continue
		fmt.sbprintf(out, "stack_group %s", "sections" if c in s.sections else "tabs")
		for x in group do fmt.sbprintf(out, " %s%s%s", "*" if x == stack_shown(s, c) && x != c else "", "-" if x in s.folded else "", panel_kind_name(x))
		strings.write_byte(out, '\n')
	}
}

// Reads a group line as stack_groups_save writes it, once the rest of the layout is in
// place (the stack's order first): names this version does not know and cards in a group
// already are passed over, and a line left with fewer than two cards makes no group.
stack_group_read :: proc(k: ^Kit_State, f: []string) {
	s := &k.stack
	if !s.set do stack_default(k)
	members := make([dynamic]Panel_Kind, 0, len(Panel_Kind), context.temp_allocator)
	if len(f) < 2 || (f[1] != "tabs" && f[1] != "sections") do return
	shown: Maybe(Panel_Kind)
	folded: bit_set[Panel_Kind]
	for word in f[2:] {
		star := strings.has_prefix(word, "*")
		name := strings.trim_prefix(word, "*")
		fold := strings.has_prefix(name, "-")
		c, ok := panel_kind_from_name(strings.trim_prefix(name, "-"))
		if !ok || slice.contains(members[:], c) || c in s.joined || len(stack_group(s, c)) > 1 do continue
		append(&members, c)
		if star do shown = c
		if fold do folded += {c}
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
	if f[1] == "sections" do s.sections += {host}
	s.folded += folded
}

// The groups shown as sections for the exit stats, `Brush:Layers-` (the host, then each
// folded section with `-`), or "none".
stack_sections_text :: proc(k: ^Kit_State) -> string {
	s := &k.stack
	b := strings.builder_make(context.temp_allocator)
	for c in s.order {
		if c in s.joined || !stack_as_sections(s, c) do continue
		if strings.builder_len(b) > 0 do strings.write_byte(&b, ',')
		fmt.sbprint(&b, c)
		for x in stack_group(s, c) do if x in s.folded do fmt.sbprintf(&b, ":%v-", x)
	}
	return strings.to_string(b) if strings.builder_len(b) > 0 else "none"
}
