package main

import "core:fmt"

import "../ui"

// The view rail's palettes dock: every rail button that holds a card (a card's or Main's)
// shows it in the panel stack's column, where the main palette stood, rather than in a
// popover beside the rail, so the whole rail behaves as the old Palettes button did. A tap
// docks that palette, a tap on the lit one puts the column away, a tap on another swaps the
// column to it. Main is the stack itself (the cards it keeps, in its own order, with its
// folds, sizes and groups); a card's button shows only that card. Cards are grouped in the
// stack alone (stack_groups.odin). Whatever opens a card of the stack by name (Open card,
// Search's Show where) shows Main, where that card is.

// Which rail palette the column shows; nil for Main.
Rail_Dock :: Maybe(Bar_Slot)

// The card a bar slot shows; false for a slot that is not a card's.
slot_panel :: proc(s: Bar_Slot) -> (Panel_Kind, bool) {
	if s.id == .Open_Card && s.arg >= 0 && s.arg < len(Panel_Kind) do return Panel_Kind(s.arg), true
	return .Brush, false
}

// Whether rail slot `s` docks a palette when tapped: a card's button or Main.
rail_docks :: proc(k: ^Kit_State, s: Bar_Slot) -> bool {
	if s.id == .Inspector do return true
	_, ok := slot_panel(s)
	return ok
}

// Whether the column shows rail slot `s`'s palette now (Main for the Inspector's slot).
rail_dock_is :: proc(app: ^App, s: Bar_Slot) -> bool {
	k := &app.kit
	if !tray_shown(app) do return false
	d, ok := rail_dock_valid(k).?
	if s.id == .Inspector do return !ok
	return ok && d == s
}

// The palette the column shows: the rail slot's, or nil (Main) once that slot is off the
// rail.
rail_dock_valid :: proc(k: ^Kit_State) -> Rail_Dock {
	d, ok := k.rail_dock.?
	if !ok do return nil
	l := &k.view_rail
	for s in l.slots[:clamp(l.count, 0, VIEW_RAIL_MAX)] do if s == d && rail_docks(k, s) do return d
	k.rail_dock = nil
	return nil
}

// A tap on rail slot `s` (a card's or Main's): docks its palette in the column,
// or puts the column away when it shows that palette already.
rail_dock_toggle :: proc(app: ^App, s: Bar_Slot) {
	k := &app.kit
	kit_floats_close(k)
	if s.id == .Inspector {
		// Main from another palette stays open and turns to Main; otherwise it is the
		// Palettes command it always was (narrow windows pop the column).
		if _, other := rail_dock_valid(k).?; other && tray_shown(app) {
			k.rail_dock = nil
			return
		}
		k.rail_dock = nil
		command_run(app, .Inspector)
		return
	}
	if rail_dock_is(app, s) {
		k.inspector = false
		return
	}
	side_panel_close(app)
	k.rail_dock = s
	k.rail_dock_scroll = 0
	k.inspector = true
	if _, docked := stack_docked(k); docked && stack_narrow(app) do stack_pop(app, true)
	k.rail_docks += 1
}

// The column's content while it shows a card's rail palette rather than Main: its name and
// the card's body, scrolling, `height` tall.
kit_rail_dock :: proc(app: ^App, outer, height: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	d, ok := rail_dock_valid(k).?
	if !ok do return
	p, _ := slot_panel(d)
	owner := ui.id_of(ctx, "rail dock")
	// One card, as the stack's cards stand in the column, its content the panels' padding in.
	PAD :: 10
	ui.begin(ctx, "rail dock", {direction = .Column, gap = 6, padding = PAD, width = outer, radius = t.radius_large, background = .Panel})
	defer ui.end(ctx)
	room := height - 2 * PAD
	width := outer - 2 * PAD
	title := tray_section_title(p) if panel_is_section(p) else stack_title(app, p)
	ui.begin(ctx, "rail dock head", {direction = .Row, center = true, width = width})
	room_w := width - t.target
	ui.begin(ctx, "rail dock title", {direction = .Column, width = room_w})
	ui.label(ctx, ui.text_fit(ctx, title, t.title_size, room_w, .Semibold), t.title_size, t.text, .Semibold)
	ui.end(ctx)
	if ui.icon_button(ctx, "Close##rail dock", ui.ICON_CLOSE, keys = "Esc") do k.inspector = false
	ui.end(ctx)
	head, _ := ui.prev_layout(ctx, "rail dock head")
	scroll := kit_scroll_begin(ctx, "rail dock body", &k.rail_dock_scroll, owner, width, max(room - head.y - 6, 160), 6)
	panel_body(app, p, width)
	kit_scroll_end(ctx, scroll)
}

// The palette the column shows, for the exit stats: Main, a card's kind, or none while the
// column is away.
rail_dock_text :: proc(app: ^App) -> string {
	k := &app.kit
	if !tray_shown(app) do return "none"
	d, ok := rail_dock_valid(k).?
	if !ok do return "Main"
	if p, is_panel := slot_panel(d); is_panel do return fmt.tprint(p)
	return "none"
}

