package main

import "core:fmt"
import "core:slice"
import "core:strings"

import "../ui"

// Lens's search (round 2 of the mockups, screen search2): the command palette centred
// under the top bar, its results grouped while something is typed (commands, brushes,
// then panels and settings, each in the order they ranked), each row saying where what it
// runs lives, and the picked row offering to put it on a bar. kit_palette draws it; this
// file holds what Lens adds.

Palette_Group :: enum u8 {
	Commands,
	Brushes,
	Panels,
}

@(rodata)
PALETTE_GROUP_NAMES := [Palette_Group]string {
	.Commands = "COMMANDS",
	.Brushes  = "BRUSHES",
	.Panels   = "PANELS AND SETTINGS",
}

// The search's width in Lens, and a result row's height (two lines), in points.
LENS_SEARCH_W :: 520
LENS_ROW_H :: 40
// The most result rows Lens's search shows.
LENS_SEARCH_ROWS :: 9

// How many result rows fit in `room` points under the top bar with `groups` captions
// among them, besides the field, the help, the footer and the padding: from 2 up to
// LENS_SEARCH_ROWS.
lens_search_rows :: proc(room: f32, groups: int) -> int {
	fixed: f32 = 16 + 46 + 24 + 58 + 46 + 24 + 24 * f32(groups)
	return clamp(int((room - fixed) / (LENS_ROW_H + 2)), 2, LENS_SEARCH_ROWS)
}

// The width of the picked row's Put on a bar button.
LENS_PUT_W :: 116

// The group a result shows under.
palette_group :: proc(e: Palette_Entry) -> Palette_Group {
	if e.kind == .Settings_Tab do return .Panels
	#partial switch e.id {
	case .Brush:                                return .Brushes
	case .Show_Section, .Pin_Section, .Settings, .Help: return .Panels
	}
	return .Commands
}

// The hits ordered by group, keeping their rank inside each, and the groups they hold.
// In the temp allocator.
palette_group_hits :: proc(hits: []Palette_Hit, entries: []Palette_Entry) -> (out: []Palette_Hit, groups: bit_set[Palette_Group]) {
	sorted := make([dynamic]Palette_Hit, 0, len(hits), context.temp_allocator)
	for g in Palette_Group {
		for h in hits {
			if palette_group(entries[h.entry]) != g do continue
			append(&sorted, h)
			groups += {g}
		}
	}
	return sorted[:], groups
}

// The commands the Lens top bar runs, for where they live.
@(rodata)
TOP_BAR_COMMANDS := [?]Command_Id{.Undo, .Redo, .Command_Palette, .Settings, .Workspace}

// Where the entry lives, as its second line says it: a Settings tab, a panel, the shelf
// page or the picker for a brush, the tray's section a command's control is in, a bar it
// is on, the menu (and its submenu) or the top bar; "" where only keys or gestures run it.
palette_where :: proc(app: ^App, e: Palette_Entry) -> string {
	if e.kind == .Settings_Tab do return "Settings"
	if e.id == .Show_Section {
		sec := Kit_Section(e.arg)
		if c := stack_card_of(app, sec); c != .Palettes && c != .Brush do return fmt.tprintf("Panel · %s card", STACK_CARD_NAMES[c])
		return fmt.tprintf("Panel · %s palette", palette_name(section_palette(sec)))
	}
	s := Bar_Slot{e.id, e.arg}
	if e.id == .Brush {
		for p in Shelf_Page do if slice.contains(bar_used(app, shelf_which(p)), s) do return fmt.tprintf("Shelf · %s", SHELF_PAGE_NAMES[p])
		return "Brush picker"
	}
	if sec, ok := COMMAND_HOMES[e.id].?; ok do return fmt.tprintf("%s palette · %s", palette_name(section_palette(sec)), tray_section_title(sec))
	if slice.contains(bar_used(app, .View_Rail), s) do return "View rail"
	for p in Shelf_Page do if slice.contains(bar_used(app, shelf_which(p)), s) do return fmt.tprintf("Shelf · %s", SHELF_PAGE_NAMES[p])
	if slice.contains(bar_used(app, .Brush_Pie), s) do return "Brush pie"
	switch place := LENS_MENU_PLACE[e.id]; place {
	case .None:
	case .Main: return "Menu"
	case .New, .Recent, .Import, .Export, .Workspaces, .More: return fmt.tprintf("Menu · %s", LENS_SUBMENU_NAMES[place])
	}
	if slice.contains(TOP_BAR_COMMANDS[:], e.id) do return "Top bar"
	return ""
}

// The bar Put on a bar puts the entry on: a brush on the shelf's page shown (Sculpt's
// first page from Render's, which holds no brushes), a brush value on the off-hand island
// beside the others, anything else on the view rail.
palette_bar_for :: proc(app: ^App, e: Palette_Entry) -> Bar_Which {
	#partial switch e.id {
	case .Brush:       return .Shelf_Sculpt if app.kit.shelf.page == .Render else shelf_which(app.kit.shelf.page)
	case .Brush_Value: return .Offhand
	}
	return .View_Rail
}

// Puts the entry at the end of its bar (palette_bar_for), saying so; one already there
// stays where it is and the note says so, and a full bar refuses as bar_insert does.
// Returns whether it was put.
palette_put_on_bar :: proc(app: ^App, e: Palette_Entry) -> bool {
	if e.kind != .Command || !bar_lists(e.id) do return false
	which := palette_bar_for(app, e)
	s := Bar_Slot{e.id, e.arg}
	if slice.contains(bar_used(app, which), s) {
		report(app, nil, {}, "%s has %s already", bar_title(which), bar_label(s))
		return false
	}
	before := bar_count(app, which)^
	bar_put(app, {which = which, slot = before, add = true}, s)
	if bar_count(app, which)^ == before do return false
	app.kit.palette_bar_puts += 1
	return true
}

// A result row in Lens: its icon, its name over where it lives, its shortcut (or a tick
// while it is on), and on the picked row Put on a bar. Returns whether the row was tapped,
// long pressed (or right-clicked) and whether Put on a bar was.
lens_palette_row :: proc(app: ^App, e: Palette_Entry, title, id: string, width: f32, enabled, picked: bool) -> (ran, shown, put: bool) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	lives := palette_where(app, e)
	can_put := picked && k.palette_for == nil && e.kind == .Command && bar_lists(e.id)
	put_w: f32 = LENS_PUT_W if can_put else 0
	ui.begin(ctx, fmt.tprintf("%s##row", id), {direction = .Row})
	a := ui.area(ctx, id, {width - put_w, LENS_ROW_H})
	shown = ui.secondary(ctx)
	r := a.rect
	full := ui.Rect{r.x, r.y, width, r.h}
	if picked do ui.fill_rect(ctx, full, t.radius_small + 2, ui.color_fade(t.accent, 0.16))
	if a.held do ui.fill_rect(ctx, full, t.radius_small + 2, t.fill_pressed)
	else if a.hovered && !picked do ui.fill_rect(ctx, full, t.radius_small + 2, t.fill_hover)
	fg := t.text if enabled else ui.color_fade(t.text_secondary, 0.4)
	mid := r.y + r.h * 0.5
	ui.icon(ctx, palette_icon(e), {r.x + 10 + t.icon_small * 0.5, mid}, t.icon_small, fg if !enabled else t.text_secondary)
	x := r.x + 20 + t.icon_small
	keys := command_keys(app, e.id, e.arg) if e.kind == .Command else ""
	checked := e.kind == .Command && command_checked(app, e.id, e.arg)
	right := r.x + r.w - 10
	keys_w := ui.text_width(ctx, keys, t.small_size) + 12 if keys != "" && !checked else (t.icon_small + 12 if checked else 0)
	room := right - x - keys_w
	// A section by its own name, the palette it is on said under it.
	name := tray_section_title(Kit_Section(e.arg)) if e.kind == .Command && e.id == .Show_Section else ui.label_text(title)
	shown_title := ui.text_fit(ctx, name, t.text_size, room)
	if lives == "" {
		ui.text(ctx, shown_title, x, mid, t.text_size, fg)
	} else {
		ui.text(ctx, shown_title, x, r.y + 13, t.text_size, fg)
		ui.text(ctx, ui.text_fit(ctx, lives, t.caption_size, room), x, r.y + 29, t.caption_size, t.text_tertiary)
	}
	if e.kind == .Command && favourite_find(app, e.id, e.arg) >= 0 {
		after := x + ui.text_width(ctx, shown_title, t.text_size) + 6 + t.icon_small * 0.35
		ui.icon(ctx, ui.ICON_STAR, {after, r.y + (13 if lives != "" else r.h * 0.5)}, t.icon_small * 0.7, t.accent)
	}
	if checked do ui.icon(ctx, ui.ICON_CHECK, {right - t.icon_small * 0.5, mid}, t.icon_small, t.accent)
	else if keys != "" do ui.text(ctx, keys, right, mid, t.small_size, t.text_tertiary, .Regular, .Right)
	ran = a.clicked
	if can_put {
		b := ui.area(ctx, fmt.tprintf("Put on a bar##palette put %s", id), {put_w, LENS_ROW_H})
		pill := ui.Rect{b.rect.x + 2, b.rect.y + (b.rect.h - 28) * 0.5, b.rect.w - 8, 28}
		ui.fill_rect(ctx, pill, t.radius_small + 2, t.surface)
		if b.held do ui.fill_rect(ctx, pill, t.radius_small + 2, t.fill_pressed)
		else if b.hovered do ui.fill_rect(ctx, pill, t.radius_small + 2, t.fill_hover)
		ui.stroke_rect(ctx, pill, t.radius_small + 2, t.border, 1)
		ui.icon(ctx, ui.ICON_PLUS, {pill.x + 14, pill.y + pill.h * 0.5}, t.icon_small - 2, t.text)
		ui.text(ctx, "Put on a bar", pill.x + 26, pill.y + pill.h * 0.5, t.small_size, t.text, .Semibold)
		ui.tip(ctx, b.id, pill, fmt.tprintf("Put it on %s", strings.to_lower(bar_title(palette_bar_for(app, e)), context.temp_allocator)), "Ctrl+Enter")
		put = b.clicked
	}
	ui.end(ctx)
	return
}

// The keys line under Lens's results, and the picked command's Star, Put in a pie and
// Assign key at its end.
lens_palette_footer :: proc(app: ^App, e: Maybe(Palette_Entry), width: f32, anchor: ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	ui.begin(ctx, "palette footer", {direction = .Row, center = true, height = t.target})
	hint := "Enter run · Tab show where it lives · Ctrl+Enter put on a bar" if k.palette_for == nil else "Enter choose · Esc close"
	buttons: f32 = 3 * t.target
	r := ui.place(ctx, {width - 16 - buttons, t.target})
	ui.text(ctx, ui.text_fit(ctx, hint, t.caption_size, r.w - 8), r.x + 4, r.y + r.h * 0.5, t.caption_size, t.text_tertiary)
	if c, ok := e.?; ok && c.kind == .Command && k.palette_for == nil {
		starred := favourite_find(app, c.id, c.arg) >= 0
		if ui.icon_button(ctx, "Starred##palette star" if starred else "Star##palette star", ui.ICON_STAR, selected = starred) {
			if favourite_toggle(app, c.id, c.arg) do pies_saved(app)
		}
		if ui.icon_button(ctx, "Put in a pie##palette pie", ui.ICON_PIE, enabled = pie_lists(c.id)) do pie_editor_open(app, c.id, c.arg, anchor)
		if ui.icon_button(ctx, "Assign key##palette key", ui.ICON_KEYBOARD) do bind_open(app, c.id, c.arg, ctx.last_rect)
	}
	ui.end(ctx)
}

// Where Lens's search opens: centred across the window under the top bar. The rect it
// returns runs from that left edge to the Search button's far edge (or from the button to
// the right edge, when Search is on the left), so a tap on Search closes it rather than
// counting as a press outside and opening it again.
lens_search_anchor :: proc(app: ^App, search: ui.Rect, width: f32) -> (anchor: ui.Rect, side: ui.Side) {
	area := ui.safe_area(&app.kit.ctx)
	left := area.x + (area.w - width) * 0.5
	if search.x + search.w >= left + width * 0.5 {
		return {left, search.y, max(search.x + search.w - left, 1), search.h}, .Below
	}
	return {search.x, search.y, max(left + width - search.x, 1), search.h}, .Below_End
}
