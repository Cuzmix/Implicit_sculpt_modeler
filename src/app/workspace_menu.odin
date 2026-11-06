package main

import "core:fmt"
import "core:strings"

import "../ui"

// The workspace menu and what it edits: a new workspace (a copy of the layout in front, or a
// starter as it ships), and for each workspace its name, a copy, its colour, the tools that
// bring it, its layout put back and its deletion, which the toast's Undo takes back. Every
// change is written to the settings file at once, so a key bound to a slot never outlives it.

// What the menu shows and keeps between frames, in Layouts.
Workspace_Menu :: struct {
	more:   int, // the workspace whose actions show under its row, its slot + 1; 0 for none
	ties:   bool, // and its "Brought by" checklist is open
	naming: bool, // the menu shows New workspace's name field
	typing: bool, // that field had the keys, which go back when it closes
	name:   [NAME_BYTES]u8,
	from:   Starter, // what the new one starts from: None is a copy of the layout in front
	undo:   Workspace_Undo,
	made:   int, // workspaces made, renamed and deleted this run (exit stats)
	renamed: int,
	deleted: int,
	moved:   int, // tabs carried to another place
	scroll:  f32, // the list's scroll, when it is taller than the room under the bar
}

// A deleted workspace, kept for its toast's Undo: the workspace whole (its strings now the
// undo's), its slot and its place among the tabs.
Workspace_Undo :: struct {
	serial: ui.Id, // the toast; 0 for nothing to take back
	slot:   int,
	place:  int,
	w:      Workspace,
}

// A change to the workspaces is written to the settings file at once.
@(private = "file")
workspaces_store :: proc(app: ^App) {
	if app.settings_file != "" do _ = settings_save(app, app.settings_file)
}

// What a new workspace is called when no name is typed: "Workspace N", the first N free.
workspace_fresh_name :: proc(k: ^Kit_State) -> string {
	for n := len(workspace_tabs(k)) + 1; ; n += 1 {
		name := fmt.tprintf("Workspace %d", n)
		if workspace_name_free(k, name, -1) do return name
	}
}

// Makes a workspace called `typed` (the fresh name when empty) after the tab in front and
// switches to it: a copy of the layout in front, both kinds of screen, tied to nothing, when
// `from` is None; else starter `from` as it ships, with the starter's ties no other holds.
// False, saying why, when every slot is taken or the name is.
workspace_new :: proc(app: ^App, typed: string, from: Starter) -> bool {
	k := &app.kit
	ws := &k.workspaces
	name := strings.trim_space(typed)
	if name == "" do name = workspace_fresh_name(k)
	if len(name) > NAME_BYTES - 1 do name = name[:NAME_BYTES - 1]
	if !workspace_name_free(k, name, -1) {
		report(app, nil, {.Warning}, "A workspace is called %s already, or the name has ##", name)
		return false
	}
	slot := -1
	for w, i in ws.list do if w.name == "" {
		slot = i
		break
	}
	if slot < 0 {
		report(app, nil, {.Warning}, "All %d workspaces are taken: delete one first", WORKSPACE_SLOTS)
		return false
	}
	now := workspace_now(k)
	w := &ws.list[slot]
	w.name = strings.clone(name)
	w.starter = from
	if from == .None {
		// The first colour no workspace has, so tabs stay told apart; the one in front's
		// when all four are taken.
		w.tint = now.tint
		used: bit_set[0 ..< 8]
		for other in ws.list do if other.name != "" do used += {int(other.tint) % 8}
		for c in 0 ..< 4 do if c not_in used {
			w.tint = u8(c)
			break
		}
		for c in Layout_Class {
			text := kit_layout_text(k) if c == ws.class else now.kept[c] if now.kept[c] != "" else workspace_base(k, ws.current, c)
			w.base[c] = strings.clone(text)
		}
		w.page = k.shelf.page
	} else {
		w.tint = STARTER_TINTS[from]
		for t in STARTER_TIES[from] do if workspace_holding(k, t) < 0 do w.ties += {t}
		w.page = shelf_first_page(from)
	}
	// After the tab in front.
	tabs := workspace_tabs(k)
	place := len(tabs)
	for s, i in tabs do if s == ws.current do place = i + 1
	for i := len(tabs); i > place; i -= 1 do ws.order[i] = ws.order[i - 1]
	ws.order[place] = i8(slot)
	k.layouts.edit.made += 1
	workspace_switch(app, slot)
	workspaces_store(app)
	report(app, nil, {.Quiet}, "Made %s", name)
	return true
}

// Renames workspace `slot`; false, saying why, when the name is empty, taken or holds ##.
workspace_rename :: proc(app: ^App, slot: int, typed: string) -> bool {
	k := &app.kit
	if !workspace_used(k, slot) do return false
	name := strings.trim_space(typed)
	if len(name) > NAME_BYTES - 1 do name = name[:NAME_BYTES - 1]
	if !workspace_name_free(k, name, slot) {
		report(app, nil, {.Warning}, "A workspace is called %s already, or the name has ##", name)
		return false
	}
	w := &k.workspaces.list[slot]
	delete(w.name)
	w.name = strings.clone(name)
	k.layouts.edit.renamed += 1
	workspaces_store(app)
	return true
}

// Ties tool tie `t` to workspace `slot`, taking it from the one that held it, or unties it.
// The tool in hand switches nothing until its tie next changes.
workspace_tie_toggle :: proc(app: ^App, slot: int, t: Tie) {
	k := &app.kit
	if !workspace_used(k, slot) do return
	w := &k.workspaces.list[slot]
	if t in w.ties {
		w.ties -= {t}
	} else {
		if other := workspace_holding(k, t); other >= 0 do k.workspaces.list[other].ties -= {t}
		w.ties += {t}
	}
	workspaces_store(app)
}

// Gives workspace `slot` tint `tint`.
workspace_tint_set :: proc(app: ^App, slot, tint: int) {
	if !workspace_used(&app.kit, slot) do return
	app.kit.workspaces.list[slot].tint = u8(tint)
	workspaces_store(app)
}

// Puts workspace `slot`'s layout back as its base for the screen in use: the one in front's
// in place, another's by forgetting what it kept.
workspace_reset :: proc(app: ^App, slot: int) {
	k := &app.kit
	if !workspace_used(k, slot) do return
	if slot == k.workspaces.current {
		layout_reset(k)
	} else {
		w := &k.workspaces.list[slot]
		delete(w.kept[k.workspaces.class])
		w.kept[k.workspaces.class] = ""
		k.layouts.resets += 1
	}
	workspaces_store(app)
}

// Deletes workspace `slot`, the last one excepted: the one in front first gives way to its
// left neighbour (its right one when it is first), as a tap on that tab would; the keys, pie
// slots and gestures that switched to it are forgotten; the toast says which tools now bring
// no workspace, and its Undo puts it back where it was.
workspace_delete :: proc(app: ^App, slot: int) {
	k := &app.kit
	ws := &k.workspaces
	tabs := workspace_tabs(k)
	if !workspace_used(k, slot) || len(tabs) <= 1 do return
	place := 0
	for s, i in tabs do if s == slot do place = i
	if slot == ws.current do workspace_switch(app, tabs[place - 1] if place > 0 else tabs[1])
	m := &k.layouts.edit
	gone := ws.list[slot]
	ws.list[slot] = {}
	for i in place ..< WORKSPACE_SLOTS - 1 do ws.order[i] = ws.order[i + 1]
	ws.order[WORKSPACE_SLOTS - 1] = -1
	_ = command_slot_forget(app, .Workspace_Switch, slot)
	lost := strings.builder_make(context.temp_allocator)
	for t in Tie do if t in gone.ties do fmt.sbprintf(&lost, "%s%s", ", " if strings.builder_len(lost) > 0 else "", TIE_NAMES[t])
	msg := fmt.tprintf("Deleted %s", gone.name)
	if strings.builder_len(lost) > 0 do msg = fmt.tprintf("Deleted %s: the %s now bring%s no workspace", gone.name, strings.to_string(lost), "s" if card(gone.ties) == 1 else "")
	workspace_undo_clear(m)
	m.undo = {slot = slot, place = place, w = gone}
	m.undo.serial = ui.toast(&k.ctx, msg, .Info, "Undo")
	m.more, m.ties = 0, false
	m.deleted += 1
	workspaces_store(app)
}

// Frees what a delete kept for Undo.
workspace_undo_clear :: proc(m: ^Workspace_Menu) {
	w := &m.undo.w
	delete(w.name)
	for c in Layout_Class {
		delete(w.kept[c])
		delete(w.base[c])
	}
	m.undo = {}
}

// The toast's Undo: the deleted workspace comes back in its slot and place, not in front,
// with the ties no other workspace took meanwhile; refused when its slot or name was taken.
workspace_undo :: proc(app: ^App) {
	k := &app.kit
	ws := &k.workspaces
	m := &k.layouts.edit
	u := &m.undo
	if u.serial == 0 do return
	defer workspace_undo_clear(m)
	if workspace_used(k, u.slot) || !workspace_name_free(k, u.w.name, -1) {
		report(app, nil, {.Warning}, "%s's place or name is taken now", u.w.name)
		return
	}
	for t in Tie do if t in u.w.ties && workspace_holding(k, t) >= 0 do u.w.ties -= {t}
	tabs := workspace_tabs(k)
	place := min(u.place, len(tabs))
	for i := len(tabs); i > place; i -= 1 do ws.order[i] = ws.order[i - 1]
	ws.order[place] = i8(u.slot)
	ws.list[u.slot] = u.w
	u.w = {}
	workspaces_store(app)
}

// The workspace menu, from the lit tab, the chevron, the + or the workspace chip: a row for
// each workspace (a tap switches to it; its ⋯ shows its actions under it, Reset layout among
// them), then New workspace with its name and what it starts from.
kit_layout_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	l := &k.layouts
	m := &l.edit
	if !l.menu && m.typing {
		ctx.text_focus = 0
		m.typing = false
	}
	if !l.menu do m.naming, m.more, m.ties, m.scroll = false, 0, false, 0
	owner := ui.id_of(ctx, "layout menu")
	if !ui.popover_begin(ctx, "layout menu", &l.menu, l.menu_at, .Below, {direction = .Column, gap = 0, padding = ui.MENU_PAD, width = ui.MENU_W}) do return
	defer ui.popover_end(ctx)
	inner := f32(ui.MENU_W - 2 * ui.MENU_PAD)
	tabs := workspace_tabs(k)
	// New workspace's form stands alone: the list is the chevron's.
	if m.naming {
		workspace_naming(app)
		return
	}
	ui.caption(ctx, "  WORKSPACES")
	picked := false
	// The rows scroll when twelve workspaces and an open one's actions are taller than the
	// room under the bar.
	room := max(ctx.input.window.y - (l.menu_at.y + l.menu_at.h) - 2 * ui.MENU_PAD - 3 * t.target, 3 * t.target)
	body := kit_scroll_begin(ctx, "workspace rows", &m.scroll, owner, inner, room, 0)
	for slot in tabs {
		w := &k.workspaces.list[slot]
		ui.begin(ctx, fmt.tprintf("workspace row %d", slot), {direction = .Row, width = inner, center = true})
		ui.begin(ctx, "switch", {direction = .Column, width = inner - t.target})
		// Its own icon, as its tab shows it, rather than the command's.
		if ui.menu_item(ctx, fmt.tprintf("%s##workspace %d", w.name, slot), keys = command_hint(app, .Workspace_Switch, slot), glyph = STARTER_ICONS[w.starter], checked = slot == k.workspaces.current) {
			command_run(app, .Workspace_Switch, slot)
			picked = true
		}
		ui.end(ctx)
		if ui.icon_button(ctx, fmt.tprintf("%s's actions##workspace more", w.name), ui.ICON_MORE, selected = m.more == slot + 1, size = t.control) {
			m.more = 0 if m.more == slot + 1 else slot + 1
			m.ties, m.naming = false, false
		}
		ui.end(ctx)
		row := ctx.last_rect
		if m.more == slot + 1 do workspace_actions(app, slot, row, len(tabs))
	}
	kit_scroll_end(ctx, body)
	// Below the list, so it stays in sight however far the list scrolls.
	ui.divider(ctx, across = true)
	if ui.menu_item(ctx, "New workspace...##workspace", glyph = ui.ICON_PLUS, enabled = len(tabs) < WORKSPACE_SLOTS, reason = "All twelve workspaces are taken") {
		workspace_naming_open(k)
	}
	if picked && !m.naming do l.menu = false
}

// Opens the workspace menu on New workspace's name field, starting from the layout in front.
workspace_naming_open :: proc(k: ^Kit_State) {
	m := &k.layouts.edit
	m.naming, m.more, m.ties, m.from = true, 0, false, .None
	m.name = {}
	k.layouts.menu = true
}

// New workspace's name field, what it starts from, and Make and Cancel.
@(private = "file")
workspace_naming :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	m := &k.layouts.edit
	ui.caption(ctx, "  NEW WORKSPACE")
	fresh := workspace_fresh_name(k)
	_ = ui.text_field(ctx, "name##new workspace", m.name[:len(m.name) - 1], hold = k.layouts.menu, hint = fresh)
	m.typing = true
	ui.caption(ctx, "  START FROM")
	options := make([]string, len(Starter), context.temp_allocator)
	for s in Starter do options[s] = fmt.tprintf("This layout (%s)", workspace_now(k).name) if s == .None else fmt.tprintf("%s as it ships", STARTER_NAMES[s])
	if picked := ui.select(ctx, "start from##new workspace", options, int(m.from)); picked >= 0 do m.from = Starter(picked)
	note := "Opened by its tab only" if m.from == .None else fmt.tprintf("Opened by its tab and the tools %s ships with", STARTER_NAMES[m.from])
	ui.paragraph(ctx, note, f32(ui.MENU_W - 2 * ui.MENU_PAD), t.text_secondary)
	// Create is the one primary action, solid; Cancel stays quiet.
	half := (f32(ui.MENU_W - 2 * ui.MENU_PAD) - ui.SPACE_M) * 0.5
	ui.begin(ctx, "new workspace buttons", {direction = .Row, gap = ui.SPACE_M})
	make_it := ui.button(ctx, "Create", .Solid, .Accent, width = half)
	cancel := ui.button(ctx, "Cancel", .Flat, .Neutral, width = half)
	ui.end(ctx)
	d := &app.device
	make_it ||= key_pressed(d, KEY_RETURN) || key_pressed(d, KEY_KP_ENTER)
	if make_it && workspace_new(app, rename_text(m.name[:]), m.from) {
		m.naming = false
		k.layouts.menu = false
	}
	if cancel do m.naming = false
	if !m.naming {
		ctx.text_focus = 0
		m.typing = false
	}
}

// Workspace `slot`'s actions, under its row: Rename, Duplicate, its colour, Brought by (the
// tools that bring it, each tagged with where it is now), Reset layout and Delete.
@(private = "file")
workspace_actions :: proc(app: ^App, slot: int, row: ui.Rect, count: int) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	m := &k.layouts.edit
	w := &k.workspaces.list[slot]
	inner := f32(ui.MENU_W - 2 * ui.MENU_PAD)
	// Indented a step under its row, a hairline after, so where one workspace's actions end
	// shows.
	ui.begin(ctx, fmt.tprintf("workspace actions %d", slot), {direction = .Column, width = inner, padding = ui.SPACE_XL})
	defer ui.divider(ctx, across = true)
	defer ui.end(ctx)
	if ui.menu_item(ctx, "Rename...##workspace", glyph = ui.ICON_RENAME) {
		k.rename = {open = true, workspace = slot + 1, at = row}
		k.layouts.menu = false
	}
	if ui.menu_item(ctx, "Duplicate##workspace", glyph = ui.ICON_DUPLICATE, enabled = count < WORKSPACE_SLOTS, reason = "All twelve workspaces are taken") {
		if slot != k.workspaces.current do workspace_switch(app, slot)
		_ = workspace_new(app, fmt.tprintf("%s copy", w.name), .None)
		m.more = 0
		k.layouts.menu = false
		return
	}
	ui.begin(ctx, "workspace tints", {direction = .Row, gap = ui.SPACE_S, padding = ui.SPACE_XS})
	for c, i in t.tints {
		if ui.swatch(ctx, fmt.tprintf("Colour %d##workspace tint", i + 1), c, t.target, selected = int(w.tint) == i).clicked do workspace_tint_set(app, slot, i)
	}
	ui.end(ctx)
	tied := strings.builder_make(context.temp_allocator)
	for tie in Tie do if tie in w.ties do fmt.sbprintf(&tied, "%s%s", ", " if strings.builder_len(tied) > 0 else "", TIE_NAMES[tie])
	summary := strings.to_string(tied) if strings.builder_len(tied) > 0 else "its tab only"
	ties_tag := fmt.tprintf("%d tool%s", card(w.ties), "" if card(w.ties) == 1 else "s") if w.ties != {} else "tab only"
	if ui.menu_item(ctx, "Opened by##workspace", glyph = ui.ICON_CHEVRON_DOWN if m.ties else ui.ICON_CHEVRON_RIGHT, tag = ties_tag, tag_color = t.text_tertiary, hint = fmt.tprintf("Now: %s. A tool ticked here brings this workspace when it is picked; ticking one another workspace holds moves it here.", summary)) do m.ties = !m.ties
	if m.ties {
		// A step further in, under their fold.
		ui.begin(ctx, "workspace ties", {direction = .Column, width = inner - 2 * ui.SPACE_XL, padding = ui.SPACE_M})
		defer ui.end(ctx)
		for tie in Tie {
			holder := workspace_holding(k, tie)
			tag := "" if holder == slot else fmt.tprintf("in %s", k.workspaces.list[holder].name) if holder >= 0 else "nowhere"
			if ui.menu_item(ctx, fmt.tprintf("%s##tie %v", TIE_NAMES[tie], tie), checked = tie in w.ties, tag = tag, tag_color = t.text_tertiary) do workspace_tie_toggle(app, slot, tie)
		}
	}
	// The one in front's is the Reset layout command, with its keys; another's forgets what it kept.
	if slot == k.workspaces.current {
		_ = command_menu_item(app, .Layout_Reset, label = "Reset layout##workspace")
	} else if ui.menu_item(ctx, "Reset layout##workspace", glyph = ui.ICON_RESET_LAYOUT, enabled = layout_changed(k, slot), reason = "Its layout is as it started") {
		workspace_reset(app, slot)
	}
	if ui.menu_item(ctx, "Delete##workspace", glyph = ui.ICON_TRASH, tone = .Danger, enabled = count > 1, reason = "The last workspace stays") {
		workspace_delete(app, slot)
		k.layouts.menu = false
	}
}
