package main

import "core:fmt"
import "core:strconv"
import "core:strings"

import "../ui"

// Rail groups: panels gathered under one button of the view rail, as Photoshop's docked
// panels fold to one icon. A carried panel button let go on the middle of another makes a
// group of the two (bar_drag.odin); more join it the same way. A tap shows the group beside
// the rail as tabs or stacked one under another; a long press or a right-click on its
// button or a tab opens its menu: its name, colour, Tabs or Stacked, Pin open, Take out,
// Ungroup and Remove. Pinned, the group's panels stand in the panel stack's column too,
// joined as tabs or one after another. The rail's slot names the group by its index; the
// groups are kept with the rail (`rail_group` lines), so a workspace's layout carries them.

RAIL_GROUPS :: 12
RAIL_GROUP_PANELS :: 6
RAIL_GROUP_NAME :: 24

Rail_Group :: struct {
	used:    bool,
	panels:  [RAIL_GROUP_PANELS]Panel_Kind,
	count:   int,
	// The tab shown, as an index into panels.
	shown:   int,
	stacked: bool,
	pinned:  bool,
	// Stacked: the panels folded to their headers, by index.
	folded:  bit_set[0 ..< RAIL_GROUP_PANELS],
	// Pinned: the panels the stack left out until the pin brought them in, which unpinning
	// leaves out again (a card the stack showed anyway stays).
	brought: bit_set[Panel_Kind],
	// 0 for none, else GROUP_COLOURS[colour - 1].
	colour:  int,
	name:    [RAIL_GROUP_NAME]u8,
}

// A group's colours, as Photoshop and Finder label things: the same in every look, since a
// person picks one to find the group again.
@(rodata)
GROUP_COLOURS := [?]ui.Color{{229, 72, 77, 255}, {240, 140, 50, 255}, {230, 200, 60, 255}, {70, 180, 110, 255}, {70, 140, 230, 255}, {160, 100, 220, 255}}
@(rodata)
GROUP_COLOUR_NAMES := [len(GROUP_COLOURS)]string{"Red", "Orange", "Yellow", "Green", "Blue", "Purple"}

// The panel a bar slot shows; false for a slot that is not a panel's.
slot_panel :: proc(s: Bar_Slot) -> (Panel_Kind, bool) {
	#partial switch s.id {
	case .Show_Panel:
		if s.arg >= 0 && s.arg < STACK_CARD_COUNT do return Panel_Kind(s.arg), true
	case .Show_Section:
		if s.arg >= 0 && s.arg < TRAY_SECTIONS do return panel_of_section(Kit_Section(s.arg))
	}
	return .Brush, false
}

// The group a rail slot is; nil for any other slot.
slot_group :: proc(k: ^Kit_State, s: Bar_Slot) -> ^Rail_Group {
	if s.id != .Rail_Group || s.arg < 0 || s.arg >= RAIL_GROUPS || !k.rail_groups[s.arg].used do return nil
	return &k.rail_groups[s.arg]
}

// The panels a rail slot holds: a group's, or the one a panel's button shows; none for
// another command.
slot_panels :: proc(k: ^Kit_State, s: ^Bar_Slot, one: ^[1]Panel_Kind) -> []Panel_Kind {
	if g := slot_group(k, s^); g != nil do return g.panels[:g.count]
	if p, ok := slot_panel(s^); ok {
		one[0] = p
		return one[:]
	}
	return nil
}

// Whether a slot can join a group or be joined: a panel's button or a group.
slot_joins :: proc(k: ^Kit_State, s: Bar_Slot) -> bool {
	if slot_group(k, s) != nil do return true
	_, ok := slot_panel(s)
	return ok
}

// Group `g`'s name: the one typed, else its panels' titles ("Layers + Material").
rail_group_name :: proc(app: ^App, g: int) -> string {
	gr := &app.kit.rail_groups[g]
	if name := rename_text(gr.name[:]); name != "" do return name
	if gr.count == 0 do return "Group"
	if gr.count == 1 do return group_panel_title(app, gr.panels[0])
	if gr.count == 2 do return fmt.tprintf("%s + %s", group_panel_title(app, gr.panels[0]), group_panel_title(app, gr.panels[1]))
	return fmt.tprintf("%s + %d more", group_panel_title(app, gr.panels[0]), gr.count - 1)
}

// Group `g`'s icon on the rail: its shown panel's.
rail_group_icon :: proc(app: ^App, g: int) -> rune {
	gr := &app.kit.rail_groups[g]
	if gr.count == 0 do return ui.ICON_PANEL
	return panel_kind_icon(app, gr.panels[clamp(gr.shown, 0, gr.count - 1)])
}

// Where group `g`'s button is on the rail; false when no slot holds it.
rail_group_at :: proc(app: ^App, g: int) -> (int, bool) {
	for s, i in bar_used(app, .View_Rail) do if s.id == .Rail_Group && s.arg == g do return i, true
	return 0, false
}

// An unused group, cleared; false when every group is in use.
@(private = "file")
rail_group_new :: proc(k: ^Kit_State) -> (int, bool) {
	for &gr, i in k.rail_groups do if !gr.used {
		gr = {used = true}
		return i, true
	}
	return 0, false
}

// Joins the panels of `carried` (from rail slot `from`, or -1 for a button carried from
// Search) onto rail slot `onto`: it becomes a group holding its own panels, then the
// carried ones, the first carried one shown. Returns false, saying why, when the group would
// hold more than RAIL_GROUP_PANELS or a panel twice, or no group is free.
rail_join :: proc(app: ^App, carried: Bar_Slot, from, onto: int) -> bool {
	k := &app.kit
	used := bar_used(app, .View_Rail)
	if onto < 0 || onto >= len(used) || from == onto do return false
	target := used[onto]
	one_a, one_b: [1]Panel_Kind
	a := slot_panels(k, &target, &one_a)
	c := carried
	b := slot_panels(k, &c, &one_b)
	if len(a) == 0 || len(b) == 0 do return false
	if len(a) + len(b) > RAIL_GROUP_PANELS {
		report(app, nil, {.Warning}, "A group holds %d panels at most", RAIL_GROUP_PANELS)
		return false
	}
	for p in b do for q in a do if p == q {
		report(app, nil, {.Warning}, "The group has %s already", group_panel_title(app, p))
		return false
	}
	g: int
	if into := slot_group(k, target); into != nil {
		g = target.arg
	} else {
		ok: bool
		if g, ok = rail_group_new(k); !ok {
			report(app, nil, {.Warning}, "The rail holds %d groups at most: ungroup one first", RAIL_GROUPS)
			return false
		}
		k.rail_groups[g].panels[0] = a[0]
		k.rail_groups[g].count = 1
	}
	gr := &k.rail_groups[g]
	first := gr.count
	for p in b {
		gr.panels[gr.count] = p
		gr.count += 1
	}
	gr.shown = first
	// A group carried onto another is gone into it.
	if from_group := slot_group(k, carried); from_group != nil && carried.arg != g {
		if from_group.pinned do rail_group_pin(app, carried.arg, false)
		from_group^ = {}
	}
	bar_list(app, .View_Rail).slots[onto] = {.Rail_Group, g}
	if from >= 0 do bar_remove(app, .View_Rail, from)
	if gr.pinned do rail_group_pin(app, g, true)
	k.rail_joins += 1
	report(app, nil, {}, "%s is a group", rail_group_name(app, g))
	return true
}

// Takes panel `i` out of group `g`: it gets its own button after the group's, and a group
// left with one panel is that panel's button again. False when the rail is full.
rail_group_take_out :: proc(app: ^App, g, i: int) -> bool {
	k := &app.kit
	gr := &k.rail_groups[g]
	at, ok := rail_group_at(app, g)
	if !ok || i < 0 || i >= gr.count do return false
	if !bar_insert(app, .View_Rail, at + 1) do return false
	p := gr.panels[i]
	pinned := gr.pinned
	if pinned do rail_group_pin(app, g, false)
	copy(gr.panels[i:gr.count - 1], gr.panels[i + 1:gr.count])
	gr.count -= 1
	gr.folded = {}
	gr.shown = clamp(gr.shown, 0, gr.count - 1)
	l := bar_list(app, .View_Rail)
	l.slots[at + 1] = rail_panel_slot(p)
	if gr.count == 1 {
		l.slots[at] = rail_panel_slot(gr.panels[0])
		gr^ = {}
	} else if pinned {
		rail_group_pin(app, g, true)
	}
	k.rail_joins += 1
	return true
}

// Ungroup: each of group `g`'s panels gets its own button where the group's was. False
// when the rail has no room for them.
rail_ungroup :: proc(app: ^App, g: int) -> bool {
	k := &app.kit
	gr := &k.rail_groups[g]
	at, ok := rail_group_at(app, g)
	if !ok do return false
	if bar_count(app, .View_Rail)^ + gr.count - 1 > bar_capacity(.View_Rail) {
		report(app, nil, {.Warning}, "%s holds %d buttons at most: remove one first", bar_title(app, .View_Rail), bar_capacity(.View_Rail))
		return false
	}
	if gr.pinned do rail_group_pin(app, g, false)
	panels := gr.panels
	n := gr.count
	gr^ = {}
	l := bar_list(app, .View_Rail)
	l.slots[at] = rail_panel_slot(panels[0])
	for p, i in panels[1:n] {
		bar_insert(app, .View_Rail, at + 1 + i)
		l.slots[at + 1 + i] = rail_panel_slot(p)
	}
	k.rail_joins += 1
	return true
}

// Takes group `g` off the rail, its panels with it.
rail_group_remove :: proc(app: ^App, g: int) {
	k := &app.kit
	if k.rail_groups[g].pinned do rail_group_pin(app, g, false)
	if at, ok := rail_group_at(app, g); ok do bar_remove(app, .View_Rail, at)
	k.rail_groups[g] = {}
}

// Pins group `g` open in the panel stack's column, or takes it out: pinned, its panels are
// kept in the stack, joined as tabs of the first or (Stacked) one after another from the
// first; unpinned, the tabs come apart and the panels the pin brought in leave again.
rail_group_pin :: proc(app: ^App, g: int, on: bool) {
	k := &app.kit
	gr := &k.rail_groups[g]
	s := &k.stack
	if !s.set do stack_default(k)
	panels := gr.panels[:gr.count]
	if gr.count == 0 do return
	// Out of whatever stack groups they were in, so the pin's own arrangement holds.
	for p in panels do if len(stack_group(s, stack_host(s, p))) > 1 do stack_take_out(k, p, open = false)
	if !on {
		for p in panels do if p in gr.brought do stack_keep(k, p, false)
		gr.pinned, gr.brought = false, {}
		return
	}
	if !gr.pinned {
		gr.brought = {}
		for p in panels do if p in s.hidden do gr.brought += {p}
	}
	gr.pinned = true
	for p in panels do stack_keep(k, p, true)
	stack_order_place(s, panels[1:], panels[0], exact = true)
	if !gr.stacked do for p, i in panels[1:] do stack_join_at(k, p, true, panels[0], i + 1)
	s.open += {panels[0]}
	if !gr.stacked do stack_show_tab(s, panels[clamp(gr.shown, 0, gr.count - 1)])
	k.inspector = true
	stack_pop_open(app)
}

// Shows group `g` as Tabs or Stacked, the pinned stack following.
rail_group_set_stacked :: proc(app: ^App, g: int, stacked: bool) {
	gr := &app.kit.rail_groups[g]
	if gr.stacked == stacked do return
	gr.stacked = stacked
	if gr.pinned do rail_group_pin(app, g, true)
}

// The groups no rail slot holds any more (a slot removed, the rail put back) are freed,
// so their indices come round again.
rail_groups_settle :: proc(k: ^Kit_State) {
	held: bit_set[0 ..< RAIL_GROUPS]
	l := &k.view_rail
	for s in l.slots[:clamp(l.count, 0, VIEW_RAIL_MAX)] do if s.id == .Rail_Group && s.arg >= 0 && s.arg < RAIL_GROUPS do held += {s.arg}
	for &gr, i in k.rail_groups do if gr.used && i not_in held do gr = {}
}

// The `rail_group` lines for every group in use: `rail_group <index> <tabs|stacked>
// <pinned> <colour> <shown> <panels, comma separated> [name, escaped]`, written with the
// view rail's lines.
rail_groups_save :: proc(k: ^Kit_State, out: ^strings.Builder) {
	for &gr, i in k.rail_groups {
		if !gr.used || gr.count == 0 do continue
		fmt.sbprintf(out, "rail_group %d %s %d %d %d ", i, "stacked" if gr.stacked else "tabs", int(gr.pinned), gr.colour, gr.shown)
		for p, j in gr.panels[:gr.count] {
			if j > 0 do strings.write_byte(out, ',')
			strings.write_string(out, panel_kind_name(p))
		}
		if name := rename_text(gr.name[:]); name != "" do fmt.sbprintf(out, " %s", preset_escape(name))
		strings.write_byte(out, '\n')
	}
}

// Reads a rail_group line; a damaged one, or one naming no panel this build knows, is
// passed over. A pinned group's panels are already in the stack's own lines, so reading
// it keeps the flag only.
rail_group_read :: proc(k: ^Kit_State, f: []string) {
	if len(f) < 7 do return
	g, g_ok := strconv.parse_int(f[1])
	pinned, p_ok := strconv.parse_int(f[3])
	colour, c_ok := strconv.parse_int(f[4])
	shown, s_ok := strconv.parse_int(f[5])
	if !g_ok || !p_ok || !c_ok || !s_ok || g < 0 || g >= RAIL_GROUPS || (f[2] != "tabs" && f[2] != "stacked") do return
	gr := Rail_Group{used = true, stacked = f[2] == "stacked", pinned = pinned == 1, colour = clamp(colour, 0, len(GROUP_COLOURS))}
	names := f[6]
	for name in strings.split_iterator(&names, ",") {
		p, ok := panel_kind_from_name(name)
		if !ok || gr.count >= RAIL_GROUP_PANELS do continue
		dup := false
		for q in gr.panels[:gr.count] do dup ||= q == p
		if dup do continue
		gr.panels[gr.count] = p
		gr.count += 1
	}
	if gr.count == 0 do return
	gr.shown = clamp(shown, 0, gr.count - 1)
	if len(f) >= 8 {
		name := preset_unescape(strings.join(f[7:], " ", context.temp_allocator))
		copy(gr.name[:RAIL_GROUP_NAME - 1], name)
	}
	k.rail_groups[g] = gr
}

// Group `g`'s button on the rail: its shown panel's icon, with a dot of its colour and a
// line for each further panel at its foot, so a group reads as more than one panel. A tap
// shows the group beside it; a long press or right-click opens its menu.
rail_group_button :: proc(app: ^App, slot: int, s: Bar_Slot, named: string, width: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	g := s.arg
	gr := slot_group(k, s)
	if gr == nil do return
	side := bar_side(app, .View_Rail)
	lit := bar_pop_showing(app, .Group) && k.bar_pop.group == g || gr.pinned && tray_shown(app)
	name := fmt.tprintf("%s##%v %d", rail_group_name(app, g), Bar_Which.View_Rail, slot)
	if ui.icon_button(ctx, name, rail_group_icon(app, g), lit, true, "", 0, true, named, width) {
		if k.bars_edit do bar_slot_open(app, .View_Rail, slot, ctx.last_rect)
		else do rail_group_open(app, g, ctx.last_rect, side)
	}
	r := ctx.last_rect
	if k.bars_edit {
		bar_edit_ring(app, r)
		bar_slot_lift(app, .View_Rail, slot, s)
		return
	}
	// One short line for each panel under the icon, the group's colour where it has one.
	tone := GROUP_COLOURS[gr.colour - 1] if gr.colour > 0 else t.text_secondary
	dash: f32 = 5
	gap: f32 = 2
	across := f32(gr.count) * dash + f32(gr.count - 1) * gap
	x := r.x + (min(r.w, t.target) - across) * 0.5
	for i in 0 ..< gr.count do ui.fill_rect(ctx, {x + f32(i) * (dash + gap), r.y + r.h - 6, dash, 2}, 1, tone)
	if ctx.last_id != 0 && ui.secondary(ctx) do rail_group_menu_open(app, g, r, side)
	bar_slot_lift(app, .View_Rail, slot, s)
}

// Opens group `g` beside `at`, or closes it on a second tap.
rail_group_open :: proc(app: ^App, g: int, at: ui.Rect, side: ui.Side) {
	k := &app.kit
	p := &k.bar_pop
	if p.open && p.kind == .Group && p.group == g {
		p.open = false
		return
	}
	kit_floats_close(k)
	k.bar_pop = {open = true, kind = .Group, group = g, at = at, side = side}
}

// Opens group `g`'s menu beside `at`.
rail_group_menu_open :: proc(app: ^App, g: int, at: ui.Rect, side: ui.Side) {
	k := &app.kit
	kit_floats_close(k)
	k.bar_pop = {open = true, kind = .Group_Menu, group = g, at = at, side = side}
}

// Group `g` beside its button: its name and colour, Pin and Close, then as Tabs a row of
// its panels' names over the shown one, or Stacked each panel under a header that folds
// it. A long press or right-click on a tab opens the group's menu too.
kit_group_pop :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	p := &k.bar_pop
	g := p.group
	if g < 0 || g >= RAIL_GROUPS || !k.rail_groups[g].used {
		p.open = false
		return
	}
	gr := &k.rail_groups[g]
	owner := ui.id_of(ctx, "bar group")
	if !ui.popover_begin(ctx, "bar group", &p.open, p.at, p.side, {direction = .Column, gap = 6, padding = PANEL_POP_PAD, width = PANEL_POP_W}) do return
	defer ui.popover_end(ctx)
	panel_pop_head(app, "bar group head", rail_group_name(app, g), 2)
	if ui.icon_button(ctx, "Pin open in the panel stack", ICON_PIN, selected = gr.pinned) do rail_group_pin(app, g, !gr.pinned)
	if ui.icon_button(ctx, "Group menu", ui.ICON_MORE) {
		rail_group_menu_open(app, g, p.at, p.side)
		return
	}
	if ui.icon_button(ctx, "Close", ui.ICON_CLOSE, keys = "Esc") do p.open = false
	ui.end(ctx)
	if gr.colour > 0 {
		r := ctx.last_rect
		ui.fill_rect(ctx, {r.x, r.y + r.h + 1, PANEL_POP_W - 2 * PANEL_POP_PAD, 2}, 1, GROUP_COLOURS[gr.colour - 1])
	}
	inner: f32 = PANEL_POP_W - 2 * PANEL_POP_PAD
	if !gr.stacked {
		// The tabs, each a button of its own so a long press on one opens the menu.
		ui.begin(ctx, "group tabs", {direction = .Row, gap = 2})
		w := (inner - 2 * f32(gr.count - 1)) / f32(gr.count)
		for i in 0 ..< gr.count {
			title := group_panel_title(app, gr.panels[i])
			if ui.toggle_button(ctx, fmt.tprintf("%s##group tab %d", ui.text_fit(ctx, title, t.text_size, w - 8, .Semibold), i), i == gr.shown, w, tooltip = title) {
				gr.shown = i
				p.scroll = 0
				if gr.pinned do stack_show_tab(&k.stack, gr.panels[i])
			}
			if ui.secondary(ctx) {
				rail_group_menu_open(app, g, ctx.last_rect, .Below)
				ui.end(ctx)
				return
			}
		}
		ui.end(ctx)
	}
	room := panel_pop_room(app, "bar group", "bar group body")
	scroll := kit_scroll_begin(ctx, "bar group body", &p.scroll, owner, inner, room, 6)
	if gr.stacked {
		for i in 0 ..< gr.count {
			c := gr.panels[i]
			folded := i in gr.folded
			if ui.menu_item(ctx, fmt.tprintf("%s##group head %d", group_panel_title(app, c), i), glyph = panel_kind_icon(app, c), hint = panel_kind_summary(app, c) if folded else "") {
				gr.folded ~= {i}
			}
			if ui.secondary(ctx) do rail_group_menu_open(app, g, ctx.last_rect, .Below)
			if !folded do panel_body(app, c, inner)
		}
	} else {
		panel_body(app, gr.panels[clamp(gr.shown, 0, gr.count - 1)], inner)
	}
	kit_scroll_end(ctx, scroll)
}

// Group `g`'s menu: its name, its colour, Tabs or Stacked, Pin open, each panel with Take
// out, then Ungroup and Remove from the rail.
kit_group_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	p := &k.bar_pop
	g := p.group
	if g < 0 || g >= RAIL_GROUPS || !k.rail_groups[g].used {
		p.open = false
		return
	}
	gr := &k.rail_groups[g]
	if !ui.popover_begin(ctx, "group menu", &p.open, p.at, p.side, {direction = .Column, gap = 6, padding = PANEL_POP_PAD, width = PANEL_POP_W}) do return
	defer ui.popover_end(ctx)
	panel_pop_head(app, "group menu head", "Group", 0)
	if ui.icon_button(ctx, "Close", ui.ICON_CLOSE, keys = "Esc") do p.open = false
	ui.end(ctx)
	ui.caption(ctx, "NAME")
	ui.text_field(ctx, "name##group", gr.name[:RAIL_GROUP_NAME - 1], hint = rail_group_name(app, g) if rename_text(gr.name[:]) == "" else "")
	ui.caption(ctx, "COLOUR")
	ui.begin(ctx, "group colours", {direction = .Row, gap = 4})
	side := (PANEL_POP_W - 2 * PANEL_POP_PAD - 4 * f32(len(GROUP_COLOURS))) / f32(len(GROUP_COLOURS) + 1)
	if ui.swatch(ctx, "No colour", t.frame, side, gr.colour == 0, empty = true).clicked do gr.colour = 0
	for c, i in GROUP_COLOURS do if ui.swatch(ctx, GROUP_COLOUR_NAMES[i], c, side, gr.colour == i + 1).clicked do gr.colour = i + 1
	ui.end(ctx)
	ui.caption(ctx, "SHOW AS")
	if v := ui.tabs(ctx, "group show as", {"Tabs", "Stacked"}, 1 if gr.stacked else 0); v >= 0 do rail_group_set_stacked(app, g, v == 1)
	pinned := gr.pinned
	if ui.switch_row(ctx, "Pin open in the panel stack", &pinned) do rail_group_pin(app, g, pinned)
	ui.caption(ctx, "PANELS")
	for i in 0 ..< gr.count {
		c := gr.panels[i]
		if ui.menu_item(ctx, fmt.tprintf("Take out %s##group out %d", group_panel_title(app, c), i), glyph = panel_kind_icon(app, c)) {
			if rail_group_take_out(app, g, i) do p.open = k.rail_groups[g].used
			return
		}
	}
	ui.divider(ctx, PANEL_POP_W - 2 * PANEL_POP_PAD, across = true)
	if ui.menu_item(ctx, "Ungroup", glyph = ICON_SPLIT) {
		if rail_ungroup(app, g) do p.open = false
		return
	}
	if ui.menu_item(ctx, "Remove from the rail", glyph = ui.ICON_TRASH, tone = .Danger) {
		rail_group_remove(app, g)
		p.open = false
	}
}

// Whether carried `c`, the pointer at `p` over spot `sp`, would join the button there as a
// group: a panel or group carried from the rail or Search, onto the middle third of
// another panel button or group on the rail (the outer thirds still put it beside).
rail_join_spot :: proc(app: ^App, c: Bar_Carry, sp: Bar_Spot, p: [2]f32) -> bool {
	k := &app.kit
	if sp.which != .View_Rail || sp.end do return false
	if from, ok := c.from.?; ok && (from != .View_Rail || c.from_slot == sp.slot) do return false
	used := bar_used(app, .View_Rail)
	if sp.slot < 0 || sp.slot >= len(used) || !slot_joins(k, c.slot) || !slot_joins(k, used[sp.slot]) do return false
	r := sp.rect
	if !bar_column(.View_Rail) do return p.x > r.x + r.w / 3 && p.x < r.x + r.w * 2 / 3
	return p.y > r.y + r.h / 3 && p.y < r.y + r.h * 2 / 3
}

// The groups in use for the exit stats: `index:tabs|stacked:pinned:panel+panel`, comma
// separated, or "none".
rail_groups_text :: proc(k: ^Kit_State) -> string {
	b := strings.builder_make(context.temp_allocator)
	for &gr, i in k.rail_groups {
		if !gr.used do continue
		if strings.builder_len(b) > 0 do strings.write_byte(&b, ',')
		fmt.sbprintf(&b, "%d:%s:%d:", i, "stacked" if gr.stacked else "tabs", int(gr.pinned))
		for p, j in gr.panels[:gr.count] {
			if j > 0 do strings.write_byte(&b, '+')
			fmt.sbprint(&b, p)
		}
	}
	if strings.builder_len(b) == 0 do return "none"
	return strings.to_string(b)
}

// A panel's name in a group: its section's own title for a section's palette ("Layers",
// as the rail's button said it), else the card's.
group_panel_title :: proc(app: ^App, p: Panel_Kind) -> string {
	if sec, ok := panel_section(p); ok do return tray_section_title(sec)
	return stack_title(app, p)
}
