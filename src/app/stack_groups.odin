package main

import "core:fmt"
import "core:reflect"
import "core:slice"
import "core:strconv"
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

// The tab the column `head` begins shows (a group's host begins its first column): the one
// picked, while it is still in that column, or the head.
stack_shown :: proc(s: ^Lens_Stack, head: Stack_Card) -> Stack_Card {
	v := s.shown[head]
	if v != head && v in s.joined && stack_column_head(s, v) == head do return v
	return head
}

// Columns (round 3, PR 5b-2): a group dropped beside another stands as its second column,
// with its own tabs and shown tab. Column two begins at the group's card in `s.beside` and
// runs to the group's end; a group has at most two columns.
STACK_DIVIDER :: 12

// The card that begins group `host`'s second column, if it has one.
stack_beside_of :: proc(s: ^Lens_Stack, host: Stack_Card) -> (Stack_Card, bool) {
	group := stack_group(s, host)
	for x in group[1:] do if x in s.beside do return x, true
	return {}, false
}

// The first card of card `c`'s column: its group's host, or the card beginning column two.
stack_column_head :: proc(s: ^Lens_Stack, c: Stack_Card) -> Stack_Card {
	head := stack_host(s, c)
	for x in stack_group(s, head) {
		if x in s.beside do head = x
		if x == c do break
	}
	return head
}

// The cards of the column `head` begins, in order.
stack_column :: proc(s: ^Lens_Stack, head: Stack_Card) -> []Stack_Card {
	out := make([dynamic]Stack_Card, 0, len(Stack_Card), context.temp_allocator)
	for x in stack_group(s, stack_host(s, head)) {
		if x == head {
			append(&out, x)
		} else if len(out) > 0 {
			if x in s.beside do break
			append(&out, x)
		}
	}
	return out[:]
}

// How wide group `host`'s second column stands (its own, or the stack's usual width).
stack_beside_width :: proc(k: ^Kit_State, host: Stack_Card) -> f32 {
	w := k.stack.beside_w[host]
	return clamp(w, STACK_W_MIN, STACK_W_MAX) if w > 0 else STACK_W
}

// How much wider than the stack group `host`'s card stands: its second column and the
// divider while it is open with two columns, else nothing.
stack_group_extra :: proc(k: ^Kit_State, host: Stack_Card) -> f32 {
	if host not_in k.stack.open do return 0
	if _, two := stack_beside_of(&k.stack, host); !two do return 0
	return stack_beside_width(k, host) + STACK_DIVIDER
}

// Whether group `host`'s second column stands left of its first: away from the edge the
// stack is docked on, or for a floating group the side it was dropped on.
stack_beside_left :: proc(k: ^Kit_State, host: Stack_Card) -> bool {
	if host in k.stack.floated do return host in k.stack.beside_left
	return stack_docked_right(k)
}

// Whether the docked stack stands against the window's right edge as drawn: columns are
// kept in layout terms, which the left hand's layout mirrors.
stack_docked_right :: proc(k: ^Kit_State) -> bool {
	side, _, docked := panel_docked(k, Kit_Window.Inspector)
	return (!docked || side == .Right) != k.ctx.mirror
}

// Joins card `c` (alone when `tab`, else its group) to group `host` as its second column,
// or as the last tabs of the second column it has already, keeping the first column's
// shown tab; `left` says the side for a floating group.
stack_beside_join :: proc(k: ^Kit_State, c: Stack_Card, tab: bool, host: Stack_Card, left: bool) -> bool {
	s := &k.stack
	_, two := stack_beside_of(s, host)
	shown := stack_shown(s, host)
	if !stack_join_at(k, c, tab, host, len(stack_group(s, host))) do return false
	if two do return true
	// A one-column group: the card joined last is column two's beginning.
	s.beside += {c}
	s.shown[c], s.shown[host] = c, shown
	if left do s.beside_left += {host}
	else do s.beside_left -= {host}
	return true
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
// last tabs and `c` the one shown (Join the card above).
stack_join :: proc(k: ^Kit_State, c: Stack_Card) -> bool {
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
stack_join_at :: proc(k: ^Kit_State, c: Stack_Card, tab: bool, host: Stack_Card, slot: int) -> bool {
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
stack_take_out :: proc(k: ^Kit_State, c: Stack_Card, open := true) -> bool {
	s := &k.stack
	if !s.set do stack_default(k)
	host := stack_host(s, c)
	group := stack_group(s, host)
	if len(group) < 2 do return false
	shown := stack_shown(s, host)
	if c == host {
		next := group[1]
		s.joined -= {next}
		// With the first column emptied, the second is the group's only one.
		s.beside -= {next}
		s.beside_w[next] = s.beside_w[host]
		if host in s.beside_left do s.beside_left += {next}
		s.beside_left -= {host}
		s.beside_w[host] = 0
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
		// The second column's first card out: the next card of that column begins it, or
		// the group is one column again.
		if c in s.beside {
			s.beside -= {c}
			for x, i in group do if x == c && i + 1 < len(group) {
				next := group[i + 1]
				s.beside += {next}
				if s.shown[c] != c do s.shown[next] = s.shown[c]
			}
		}
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
stack_ungroup :: proc(k: ^Kit_State, host: Stack_Card) -> bool {
	s := &k.stack
	if !s.set do stack_default(k)
	group := stack_group(s, host)
	if host in s.joined || len(group) < 2 do return false
	for x in group[1:] {
		s.joined -= {x}
		s.shown[x] = x
		s.beside -= {x}
	}
	s.shown[host] = host
	s.beside_left -= {host}
	s.joins += 1
	return true
}

// Shows tab `c` of its group.
stack_show_tab :: proc(s: ^Lens_Stack, c: Stack_Card) {
	head := stack_column_head(s, c)
	if s.shown[head] != c do s.scrolls[stack_host(s, c)] = 0
	s.shown[head] = c
}

// A card's state as a card of the stack, cleared as it becomes a tab.
@(private = "file")
stack_tab_reset :: proc(s: ^Lens_Stack, c: Stack_Card) {
	s.open -= {c}
	s.floated -= {c}
	s.windows[c], s.heights[c], s.sizes[c], s.scrolls[c] = {}, 0, {}, 0
	s.shown[c] = c
	s.beside -= {c}
	s.beside_left -= {c}
	s.beside_w[c] = 0
}

// Takes `cards` out of the stack's order and puts them back, in their order, right after
// the group of card `after` (whose other cards stay where they are), or right after
// `after` itself when `exact`.
@(private = "file")
stack_order_place :: proc(s: ^Lens_Stack, cards: []Stack_Card, after: Stack_Card, exact := false) {
	last := after
	if !exact do for x in stack_group(s, stack_host(s, after)) do if !slice.contains(cards, x) do last = x
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
stack_tab_row :: proc(app: ^App, head: Stack_Card, width: f32, always := false) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	s := &k.stack
	group := stack_column(s, head)
	if len(group) < 2 && !always do return
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

// A two-column group's tab rows, side by side over its columns, `outer` wide: column
// two's on the side stack_beside_left says.
stack_columns_tabs :: proc(app: ^App, host: Stack_Card, outer: f32) {
	k := &app.kit
	ctx := &k.ctx
	s := &k.stack
	b, two := stack_beside_of(s, host)
	if !two do return
	w2 := stack_beside_width(k, host)
	w1 := outer - w2 - STACK_DIVIDER
	ui.begin(ctx, "stack columns tabs", {direction = .Row, gap = STACK_DIVIDER, width = outer})
	if stack_beside_left(k, host) {
		stack_tab_row(app, b, w2, always = true)
		stack_tab_row(app, host, w1, always = true)
	} else {
		stack_tab_row(app, host, w1, always = true)
		stack_tab_row(app, b, w2, always = true)
	}
	ui.end(ctx)
}

// A two-column group's bodies, `inner` wide in all: each column's shown tab, the divider
// between them dragging column two's width (a double tap puts the usual one back).
stack_columns_bodies :: proc(app: ^App, host: Stack_Card, inner: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	s := &k.stack
	b, two := stack_beside_of(s, host)
	if !two do return
	left := stack_beside_left(k, host)
	// Column two's body keeps the share of the card's padding its tab row has.
	w2 := stack_beside_width(k, host) - 8
	w1 := inner - w2 - STACK_DIVIDER
	ui.begin(ctx, "stack columns", {direction = .Row, width = inner})
	for i in 0 ..< 3 {
		part := i if !left else 2 - i
		switch part {
		case 0:
			ui.begin(ctx, "stack column one", {direction = .Column, gap = 6, width = w1})
			panel_body(app, stack_shown(s, host), w1)
			ui.end(ctx)
		case 2:
			ui.begin(ctx, "stack column two", {direction = .Column, gap = 6, width = w2})
			panel_body(app, stack_shown(s, b), w2)
			ui.end(ctx)
		case 1:
			h := max(s.bodies[host].h, 60)
			g := ui.area(ctx, "stack column divider", {STACK_DIVIDER, h})
			ui.tip(ctx, g.id, g.rect, "Drag to set the second column's width; double tap for the usual width")
			if g.pressed do s.drag = {kind = .Beside, card = host, press = g.mouse, before = stack_beside_width(k, host)}
			mine := s.drag.kind == .Beside && s.drag.card == host
			if mine && g.held {
				d := g.mouse.x - s.drag.press.x
				s.beside_w[host] = clamp(stack_snap(s.drag.before + (-d if left else d)), STACK_W_MIN, STACK_W_MAX)
			} else if mine {
				if stack_beside_width(k, host) != s.drag.before do s.resizes += 1
				s.drag = {}
			}
			if g.clicked && handle_double_tap(ctx, &s.tap, g.id) {
				s.beside_w[host] = 0
				s.resizes += 1
			}
			color := t.accent if mine && g.held else (t.text_secondary if g.hovered else t.border_strong)
			ui.fill_rect(ctx, {g.rect.x + g.rect.w * 0.5 - 1.5, g.rect.y + 8, 3, max(g.rect.h - 16, 8)}, 1.5, color)
		}
	}
	ui.end(ctx)
}

// The height the tab row takes in a floating card or the strip's panel: the tabs' well,
// the row's padding and the gap after it.
stack_tab_row_h :: proc(app: ^App, host: Stack_Card) -> f32 {
	if len(stack_column(&app.kit.stack, host)) < 2 && stack_group_extra(&app.kit, host) == 0 do return 0
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
		strings.write_string(out, "stack_group")
		head := c
		for x in group {
			if x in s.beside {
				strings.write_string(out, " |")
				head = x
			}
			fmt.sbprintf(out, " %s%s", "*" if x == stack_shown(s, head) && x != head else "", panel_kind_name(x))
		}
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
	shown, beside, shown_beside: Maybe(Stack_Card)
	bar := false
	for word in f[1:] {
		if word == "|" {
			bar = true
			continue
		}
		kind, ok := panel_kind_from_name(strings.trim_prefix(word, "*"))
		if !ok do continue
		c, card := kind.(Stack_Card)
		if !card || slice.contains(members[:], c) || c in s.joined || len(stack_group(s, c)) > 1 do continue
		append(&members, c)
		// The first card after `|` (never the host) begins column two.
		if bar && beside == nil && len(members) > 1 do beside = c
		star := strings.has_prefix(word, "*")
		if star && beside == nil do shown = c
		if star && beside != nil do shown_beside = c
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
	if b, ok := beside.?; ok {
		s.beside += {b}
		if v, has := shown_beside.?; has do s.shown[b] = v
	}
}

// The groups with two columns for the exit stats: `Brush=Symmetry:312` (the host, the
// card beginning column two and its width), or "none".
stack_columns_text :: proc(k: ^Kit_State) -> string {
	s := &k.stack
	b := strings.builder_make(context.temp_allocator)
	for c in s.order {
		if c in s.joined do continue
		x, two := stack_beside_of(s, c)
		if !two do continue
		if strings.builder_len(b) > 0 do strings.write_byte(&b, ',')
		fmt.sbprintf(&b, "%v=%v:%d", c, x, int(stack_beside_width(k, c)))
	}
	return strings.to_string(b) if strings.builder_len(b) > 0 else "none"
}

// The second columns' widths that differ from the usual, a line `stack_beside Brush=320`
// (an older build passes over it).
stack_beside_save :: proc(k: ^Kit_State, out: ^strings.Builder) {
	s := &k.stack
	if !s.set do return
	any := false
	for c in s.order {
		if c in s.joined || s.beside_w[c] <= 0 do continue
		if _, two := stack_beside_of(s, c); !two do continue
		if !any do strings.write_string(out, "stack_beside")
		any = true
		fmt.sbprintf(out, " %v=%d", c, int(stack_beside_width(k, c)))
	}
	if any do strings.write_byte(out, '\n')
}

// Reads a `stack_beside` line; words it cannot read are passed over.
stack_beside_read :: proc(k: ^Kit_State, f: []string) {
	s := &k.stack
	if !s.set do stack_default(k)
	for word in f[1:] {
		name, _, value := strings.partition(word, "=")
		w, ok := strconv.parse_f32(value)
		if !ok || w <= 0 do continue
		if c, known := reflect.enum_from_name(Stack_Card, name); known do s.beside_w[c] = clamp(stack_snap(w), STACK_W_MIN, STACK_W_MAX)
	}
}
