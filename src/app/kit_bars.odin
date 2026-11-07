package main

import "core:fmt"
import "core:math"

import "../sculpt"
import "../ui"

// What the bars round the view share (the top bar is kit_top_lens.odin, the off-hand
// island and view rail lens_chrome.odin, the shelf lens_shelf.odin):
// the interface's looks, the one popover a bar button opens beside itself, and where the
// panels start clear of the bars.

// The interface's built-in themes (Settings > Interface > Look, themes.odin): Lens's
// near-black frame and sea green, Studio's greys and orange, Graphite's cool blue, Paper's
// light warm greys, Midnight's pure black and High contrast's plain white on black. New
// ones go at the end: the settings file names them, and themes of a person's own name
// the one they began as.
Look :: enum u8 {
	Lens,
	Studio,
	Graphite,
	Paper,
	Midnight,
	High_Contrast,
}

@(rodata)
LOOK_NAMES := [Look]string {
	.Lens          = "Lens",
	.Studio        = "Studio",
	.Graphite      = "Graphite",
	.Paper         = "Paper",
	.Midnight      = "Midnight",
	.High_Contrast = "High contrast",
}

// The top bar's height, and how far the side bars sit from the window's edges, in points.
TOP_BAR_H :: 52
BAR_EDGE :: 4

// What a bar's popover holds: the three symmetry axes, what the polyframe shows, Remesh's
// quick menu, the Shading or Camera menu, or the view layout. A section or card a button
// opens shows in the card column beside it instead (column.odin).
Bar_Pop_Kind :: enum u8 {
	Symmetry,
	Polyframe,
	Remesh_Quick,
	Shading,
	Camera,
	View_Layout,
	Value, // a brush value's slider and steps (brush_values.odin)
	Value_Menu, // a value item's menu: its look, its section, its moves
	Dock_Menu, // a dock's ⋯: add a button, its lines and names (docks.odin)
	View_Gizmo, // the view gizmo's style, held or right-clicked on it (view_gizmo.odin)
}

// The one popover the bars open: one at a time, beside the button that opened it.
Bar_Pop :: struct {
	open:    bool,
	kind:    Bar_Pop_Kind,
	at:      ui.Rect,
	side:    ui.Side,
	scroll:  f32,
	// The value a Value popover or menu is for, and for the menu the bar and slot it is on
	// and whether its Add another value list is open.
	value:   Brush_Value,
	which:   Bar_Which,
	slot:    int,
	adding:  bool,
	// The dock a Dock_Menu is for.
	dock:    Dock_Id,
}

// Opens the bars' popover with `kind` beside `at`, or closes it when it already shows
// that, as a second tap on its button does.
bar_pop_toggle :: proc(app: ^App, kind: Bar_Pop_Kind, at: ui.Rect, side: ui.Side) {
	k := &app.kit
	p := &k.bar_pop
	if p.open && p.kind == kind {
		p.open = false
		return
	}
	kit_floats_close(k)
	k.bar_pop = {open = true, kind = kind, at = at, side = side}
}

// Whether the bars' popover shows `kind`.
bar_pop_showing :: proc(app: ^App, kind: Bar_Pop_Kind) -> bool {
	p := &app.kit.bar_pop
	return p.open && p.kind == kind
}

// Opens the Shading or Camera menu beside its button on a bar, or closes it: the button's
// tap, and its command from search, keys or a pie. Where the button is not shown, the menu
// opens beside the top of the view rail.
bar_menu_toggle :: proc(app: ^App, kind: Bar_Pop_Kind) {
	k := &app.kit
	at, side := k.bar_at[kind], k.bar_side[kind]
	if at.w <= 0 do at, side = ui.prev_rect(&k.ctx, "view bar"), dock_side(app, .Rail)
	bar_pop_toggle(app, kind, at, side)
}

// Where the panels under the top bar start, from the top of the safe area.
kit_top :: proc() -> f32 {
	return TOP_BAR_H + 16
}

// How far in from the safe area's left edge (in layout terms) the panels start, clear of
// the bar standing on it: the off-hand island (laid out as "brush bar") where it is as it
// comes, or whichever Arrange put there.
kit_left :: proc(app: ^App) -> f32 {
	return BAR_EDGE + kit_edge_width(app, .Left) + 8
}

// How far in from the safe area's right edge the panels on the right start, clear of the
// bar standing on it: the view rail (laid out as "view bar") as it comes.
kit_right :: proc(app: ^App) -> f32 {
	return BAR_EDGE + kit_edge_width(app, .Right) + 8
}

// How wide the bar on `edge` was laid out last frame; 0 for none (a floating bar stands
// on neither).
@(private = "file")
kit_edge_width :: proc(app: ^App, edge: Dock_Edge) -> f32 {
	k := &app.kit
	w: f32 = 0
	for b in Dock_Id do if dock_edge(k, b) == edge && dock_shown(k, b) {
		bar, _ := ui.prev_layout(&k.ctx, DOCK_ROOTS[b])
		w = max(w, bar.x)
	}
	return w
}

// Where a card under the top bar (the first-run tip, the recovery offer) goes: under the
// window's middle where that clears the off-hand island on the left and the view rail and
// the card column on the right, else in the middle of the room between them; lower down where
// it would meet the readout. Returns its shift from the middle, its width (at
// most `most`, at least `least`) and its top; false when even that does not fit.
kit_card_place :: proc(app: ^App, most, least: f32) -> (shift, w, top: f32, fits: bool) {
	k := &app.kit
	area := ui.safe_area(&k.ctx)
	left := kit_left(app)
	right := kit_right(app) + cards_right_room(app)
	room := area.w - left - right
	if room < least do return
	w = min(most, room)
	if (area.w - w) * 0.5 < left || (area.w + w) * 0.5 > area.w - right do shift = left + room * 0.5 - area.w * 0.5
	top = kit_top() + 4
	// How far the readout reaches in from its side, which the layout may have put on the
	// right; the card's shift counts from the island's side as the offsets do.
	points := ui.prev_rect(&k.ctx, "points")
	reach := area.x + area.w - points.x if k.ctx.mirror else points.x - area.x + points.w
	if points.w > 0 && area.w * 0.5 + shift - w * 0.5 < reach + 8 do top = points_bottom(app)
	return shift, w, top, true
}

// How far down from the safe area's top the readout ("points") reaches, with a margin
// under them.
points_bottom :: proc(app: ^App) -> f32 {
	points, _ := ui.prev_layout(&app.kit.ctx, "points")
	return TOP_BAR_H + 4 + points.y + 8
}

// Where the off-hand island's top goes, in points down the safe area, from last frame's
// size: centred down the left edge, kept between the readout and the shelf where it
// fits, and raised clear of the modifier wheel in the corner under it where there is room,
// so the wheel keeps its corner. A window too short for that keeps it clear of the shelf
// and puts the chips beside it.
brush_bar_top :: proc(app: ^App) -> f32 {
	ctx := &app.kit.ctx
	area := ui.safe_area(ctx)
	bar, _ := ui.prev_layout(ctx, "brush bar")
	low := area.h - ctx.theme.edge - dock_stack(app) - 8 - bar.y
	top := clamp((area.h - bar.y) * 0.5, points_bottom(app), max(low, points_bottom(app)))
	if rail_shown(&app.kit) == .Left {
		above := area.h - ctx.theme.edge - rail_size(app).y - 8 - bar.y
		if above >= points_bottom(app) do top = min(top, above)
	}
	if low < points_bottom(app) do top = max(low, TOP_BAR_H + 4)
	return top
}

// How far above the edge's margin the shelf sits, for its page names under it.
SHELF_LIFT :: 22

// Where the shelf sits above the edge's margin, which what stands over it (the action bar,
// the modifier wheel, a shape's bar) keeps clear of: on the margin itself in Focus, which
// shows no page names.
dock_lift :: proc(app: ^App) -> f32 {
	return 0 if lens_focus(&app.kit) else SHELF_LIFT
}

// The bars' popover (Bar_Pop), beside the button that opened it.
kit_bar_popover :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	p := &k.bar_pop
	switch p.kind {
	case .Symmetry:
		if !ui.popover_begin(ctx, "bar symmetry", &p.open, p.at, p.side, {direction = .Column, gap = ui.SPACE_XS, padding = ui.POPOVER_PAD, width = ui.POPOVER_W}) do return
		defer ui.popover_end(ctx)
		symmetry_controls(app)
	case .Polyframe:
		if !ui.popover_begin(ctx, "bar polyframe", &p.open, p.at, p.side, {direction = .Column, gap = ui.SPACE_XS, padding = ui.POPOVER_PAD, width = ui.POPOVER_W}) do return
		defer ui.popover_end(ctx)
		ui.caption(ctx, "POLYFRAME SHOWS")
		ui.begin(ctx, "polyframe parts", {direction = .Row, gap = ui.SPACE_XS})
		if ui.toggle_button(ctx, "Lines", app.polyframe_lines, 96, tooltip = "The selected object's edges") do app.polyframe_lines = !app.polyframe_lines
		if ui.toggle_button(ctx, "Fill", app.polyframe_fill, 96, tooltip = "The selected object's polygroups in their colours") do app.polyframe_fill = !app.polyframe_fill
		ui.end(ctx)
	case .Remesh_Quick:
		if !ui.popover_begin(ctx, "bar remesh", &p.open, p.at, p.side, {direction = .Column, gap = ui.SPACE_S, padding = ui.SPACE_L, width = ui.POPOVER_W}) do return
		defer ui.popover_end(ctx)
		kit_remesh_quick(app)
	case .Shading:
		if !ui.popover_begin(ctx, "bar shading", &p.open, p.at, p.side, {direction = .Column, padding = ui.MENU_PAD, width = ui.MENU_W}) do return
		defer ui.popover_end(ctx)
		kit_shading_menu(app)
	case .Camera:
		if !ui.popover_begin(ctx, "bar camera", &p.open, p.at, p.side, {direction = .Column, padding = ui.MENU_PAD, width = ui.MENU_W}) do return
		defer ui.popover_end(ctx)
		kit_camera_menu(app)
	case .View_Layout:
		if !ui.popover_begin(ctx, "bar view layout", &p.open, p.at, p.side, {direction = .Column, gap = ui.SPACE_M, padding = ui.SPACE_L, width = VIEW_LAYOUT_W + 24}) do return
		defer ui.popover_end(ctx)
		kit_view_layout_lens(app, VIEW_LAYOUT_W)
	case .Value:
		kit_value_pop(app)
	case .Value_Menu:
		kit_value_menu(app)
	case .Dock_Menu:
		kit_dock_menu(app)
	case .View_Gizmo:
		kit_view_gizmo_pop(app)
	}
}

// The symmetry axes, Local, and the radial copies: the bar's Symmetry popover and the
// Symmetry card.
symmetry_controls :: proc(app: ^App) {
	ctx := &app.kit.ctx
	ui.caption(ctx, "SYMMETRY")
	ui.begin(ctx, "symmetry axes", {direction = .Row, gap = ui.SPACE_XS})
	for axis in sculpt.Axis {
		name := fmt.tprint(axis)
		tip := fmt.tprintf("Symmetry across %s", name)
		if ui.toggle_button(ctx, name, axis in app.brush.symmetry, 48, command_hint(app, .Symmetry_X) if axis == .X else "", tip) do app.brush.symmetry ~= {axis}
	}
	if ui.toggle_button(ctx, "Local", app.brush.sym_local, 64, command_hint(app, .Local_Symmetry), COMMANDS[.Local_Symmetry].help) do command_run(app, .Local_Symmetry)
	ui.end(ctx)
	ui.caption(ctx, "RADIAL")
	ui.begin(ctx, "radial axes", {direction = .Row, gap = ui.SPACE_XS})
	if ui.toggle_button(ctx, "Radial", app.brush.radial_on, 64, command_hint(app, .Radial_Symmetry), COMMANDS[.Radial_Symmetry].help) do command_run(app, .Radial_Symmetry)
	for axis in sculpt.Axis {
		name := fmt.tprintf("%v##radial", axis)
		if ui.toggle_button(ctx, name, app.brush.radial_axis == axis, 48, tooltip = fmt.tprintf("Copies round the %v axis", axis)) do app.brush.radial_axis = axis
	}
	ui.end(ctx)
	count := f32(app.brush.radial_count)
	if ui.slider(ctx, "Copies", &count, RADIAL_MIN, sculpt.RADIAL_MAX, .Linear, fmt.tprintf("%d", app.brush.radial_count)) {
		app.brush.radial_count = i32(math.round(count))
		app.brush.radial_on = true
	}
	_ = ui.switch_row(ctx, "Feather", &app.brush.feather)
	_ = ui.switch_row(ctx, "Show the symmetry line", &app.kit.symmetry_line)
}

// Section `sec`, wherever its card's table lists it: its title and what draws it
// (for the object sections, with the object).
bar_section :: proc(app: ^App, sec: Section) -> (title: string, draw: proc(app: ^App), obj_draw: proc(app: ^App, obj: ^Object), found: bool) {
	for s in BRUSH_SECTIONS do if s.section == sec do return s.title, s.draw, nil, true
	for s in SCENE_SECTIONS do if s.section == sec do return s.title, s.draw, nil, true
	for s in OBJECT_SECTIONS do if s.section == sec do return s.title, nil, s.draw, true
	return
}

