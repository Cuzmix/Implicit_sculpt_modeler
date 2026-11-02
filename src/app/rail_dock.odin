package main

import "core:fmt"

import "../ui"

// The view rail's palettes dock: every rail button that holds panels (a panel's, a group's
// or Main's) shows them in the panel stack's column, where the main palette stood, rather
// than in a popover beside the rail, so the whole rail behaves as the old Palettes button
// did. A tap docks that palette, a tap on the lit one puts the column away, a tap on another
// swaps the column to it. Main is the stack itself (the cards it keeps, in its own order,
// with its folds, sizes and groups); a panel or a group shows only its panels, a group as
// its tabs or one under another. Whatever opens a card of the stack by name (Show section,
// Show panel, Search's Show where) shows Main, where that card is.

// Which rail palette the column shows; nil for Main.
Rail_Dock :: Maybe(Bar_Slot)

// Whether rail slot `s` docks a palette when tapped: a panel's button, a group or Main.
rail_docks :: proc(k: ^Kit_State, s: Bar_Slot) -> bool {
	if s.id == .Inspector do return true
	return slot_joins(k, s)
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
// rail or its group is gone.
rail_dock_valid :: proc(k: ^Kit_State) -> Rail_Dock {
	d, ok := k.rail_dock.?
	if !ok do return nil
	l := &k.view_rail
	for s in l.slots[:clamp(l.count, 0, VIEW_RAIL_MAX)] do if s == d && rail_docks(k, s) do return d
	k.rail_dock = nil
	return nil
}

// A tap on rail slot `s` (a panel's, a group's or Main's): docks its palette in the column,
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

// The column's content while it shows a rail palette rather than Main: its name, a group's
// tabs (as tabs), and its panels in a scrolling body `room` tall.
kit_rail_dock :: proc(app: ^App, outer, height: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	d, ok := rail_dock_valid(k).?
	if !ok do return
	owner := ui.id_of(ctx, "rail dock")
	// One card, as the stack's cards stand in the column, its content the panels' padding in.
	PAD :: 10
	ui.begin(ctx, "rail dock", {direction = .Column, gap = 6, padding = PAD, width = outer, radius = t.radius_large, background = .Panel})
	defer ui.end(ctx)
	room := height - 2 * PAD
	width := outer - 2 * PAD
	one: [1]Panel_Kind
	panels := slot_panels(k, &d, &one)
	gr := slot_group(k, d)
	title := rail_group_name(app, d.arg) if gr != nil else group_panel_title(app, panels[0]) if len(panels) > 0 else ""
	buttons := 2 if gr != nil else 1
	ui.begin(ctx, "rail dock head", {direction = .Row, center = true, width = width})
	room_w := width - f32(buttons) * t.target
	ui.begin(ctx, "rail dock title", {direction = .Column, width = room_w})
	ui.label(ctx, ui.text_fit(ctx, title, t.title_size, room_w, .Semibold), t.title_size, t.text, .Semibold)
	ui.end(ctx)
	if gr != nil {
		if ui.icon_button(ctx, "Group menu##rail dock", ui.ICON_MORE) do rail_group_menu_open(app, d.arg, ctx.last_rect, .Below)
	}
	if ui.icon_button(ctx, "Close##rail dock", ui.ICON_CLOSE, keys = "Esc") do k.inspector = false
	ui.end(ctx)
	if gr != nil && gr.colour > 0 {
		r := ctx.last_rect
		ui.fill_rect(ctx, {r.x, r.y + r.h + 1, width, 2}, 1, GROUP_COLOURS[gr.colour - 1])
	}
	if gr != nil && !gr.stacked && rail_group_tabs(app, d.arg, width, &k.rail_dock_scroll) do return
	head, _ := ui.prev_layout(ctx, "rail dock head")
	tabs: f32 = t.target + 6 if gr != nil && !gr.stacked else 0
	scroll := kit_scroll_begin(ctx, "rail dock body", &k.rail_dock_scroll, owner, width, max(room - head.y - tabs - 6, 160), 6)
	if gr != nil do rail_group_panels(app, d.arg, width)
	else if len(panels) > 0 do panel_body(app, panels[0], width)
	kit_scroll_end(ctx, scroll)
}

// The palette the column shows, for the exit stats: Main, a panel's kind, `group:<index>`,
// or none while the column is away.
rail_dock_text :: proc(app: ^App) -> string {
	k := &app.kit
	if !tray_shown(app) do return "none"
	d, ok := rail_dock_valid(k).?
	if !ok do return "Main"
	if d.id == .Rail_Group do return fmt.tprintf("group:%d", d.arg)
	if p, is_panel := slot_panel(d); is_panel do return fmt.tprint(p)
	return "none"
}

