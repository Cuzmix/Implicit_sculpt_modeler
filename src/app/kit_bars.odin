package main

import "core:fmt"
import "core:math"

import "../sculpt"
import "../ui"

// What the bars round the view share (the top bar is kit_top_lens.odin, the off-hand
// island, view chips, view rail and mini view lens_chrome.odin, the shelf lens_shelf.odin):
// the interface's looks, the one popover a bar button opens beside itself, and where the
// panels start clear of the bars.

// The interface's colours (Settings > Interface): Lens's near-black frame and sea green,
// Studio's greys and orange, or Graphite's cool blue.
Look :: enum u8 {
	Lens,
	Studio,
	Graphite,
}

@(rodata)
LOOK_THEMES := [Look]ui.Theme {
	.Lens     = ui.THEME_LENS,
	.Studio   = ui.THEME_STUDIO,
	.Graphite = ui.THEME_DARK,
}

@(rodata)
LOOK_NAMES := [Look]string {
	.Lens     = "Lens",
	.Studio   = "Studio",
	.Graphite = "Graphite",
}

// The top bar's height, and how far the side bars sit from the window's edges, in points.
TOP_BAR_H :: 52
BAR_EDGE :: 4

// What a bar's popover holds: one tray section, the three symmetry axes, what the
// polyframe shows, Remesh's quick menu, the Shading or Camera menu, or the view layout.
Bar_Pop_Kind :: enum u8 {
	Section,
	Symmetry,
	Polyframe,
	Remesh_Quick,
	Shading,
	Camera,
	View_Layout,
	Value, // a brush value's slider and steps (brush_values.odin)
	Value_Menu, // a value item's menu: its look, its section, its moves
}

// The one popover the bars open: one at a time, beside the button that opened it.
Bar_Pop :: struct {
	open:    bool,
	kind:    Bar_Pop_Kind,
	section: Kit_Section,
	at:      ui.Rect,
	side:    ui.Side,
	scroll:  f32,
	// The value a Value popover or menu is for, and for the menu the bar and slot it is on
	// and whether its Add another value list is open.
	value:   Brush_Value,
	which:   Bar_Which,
	slot:    int,
	adding:  bool,
}

// Opens the bars' popover with `kind` (and `section`) beside `at`, or closes it when it
// already shows that, as a second tap on its button does.
bar_pop_toggle :: proc(app: ^App, kind: Bar_Pop_Kind, at: ui.Rect, side: ui.Side, section := Kit_Section.Stroke) {
	k := &app.kit
	p := &k.bar_pop
	if p.open && p.kind == kind && (kind != .Section || p.section == section) {
		p.open = false
		return
	}
	kit_floats_close(k)
	k.bar_pop = {open = true, kind = kind, section = section, at = at, side = side}
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
	if at.w <= 0 do at, side = ui.prev_rect(&k.ctx, "view bar"), .Left
	bar_pop_toggle(app, kind, at, side)
}

// Where the panels under the top bar start, from the top of the safe area.
kit_top :: proc() -> f32 {
	return TOP_BAR_H + 16
}

// How far in from the safe area's left edge the panels start, clear of the off-hand island
// (laid out as "brush bar").
kit_left :: proc(app: ^App) -> f32 {
	bar, _ := ui.prev_layout(&app.kit.ctx, "brush bar")
	return BAR_EDGE + bar.x + 8
}

// How far in from the safe area's right edge the panels on the right start, clear of
// the view rail (laid out as "view bar").
kit_right :: proc(app: ^App) -> f32 {
	bar, _ := ui.prev_layout(&app.kit.ctx, "view bar")
	return BAR_EDGE + bar.x + 8
}

// Where a card under the top bar (the first-run tip, the recovery offer) goes: under the
// window's middle where that clears the off-hand island on the left and the view rail and
// the stack on the right, else in the middle of the room between them; lower down where
// it would meet the view chips. Returns its shift from the middle, its width (at
// most `most`, at least `least`) and its top; false when even that does not fit.
kit_card_place :: proc(app: ^App, most, least: f32) -> (shift, w, top: f32, fits: bool) {
	k := &app.kit
	area := ui.safe_area(&k.ctx)
	left := kit_left(app)
	right := kit_right(app) + (KIT_SETTINGS_W + 8 if side_panel_open(k) else tray_width(app) + 8 if k.inspector else 0)
	room := area.w - left - right
	if room < least do return
	w = min(most, room)
	if (area.w - w) * 0.5 < left || (area.w + w) * 0.5 > area.w - right do shift = left + room * 0.5 - area.w * 0.5
	top = kit_top() + 4
	// How far the view chips reach in from their side, which the layout may have put on the
	// right; the card's shift counts from the island's side as the offsets do.
	points := ui.prev_rect(&k.ctx, "points")
	reach := area.x + area.w - points.x if k.ctx.mirror else points.x - area.x + points.w
	if points.w > 0 && area.w * 0.5 + shift - w * 0.5 < reach + 8 do top = points_bottom(app)
	return shift, w, top, true
}

// How much a panel `width` wide on the right, where it starts, gives up at its foot so as
// to stay clear of the shelf (laid out as "dock") and the action bar over it where the
// two would meet.
side_panel_below :: proc(app: ^App, width: f32) -> f32 {
	ctx := &app.kit.ctx
	area := ui.safe_area(ctx)
	dock, _ := ui.prev_layout(ctx, "dock")
	if area.w * 0.5 + dock.x * 0.5 + 8 > area.w - kit_right(app) - width do return dock_stack(app) + 8
	return 0
}

// How far down from the safe area's top the view chips ("points") reach, with a margin
// under them.
points_bottom :: proc(app: ^App) -> f32 {
	points, _ := ui.prev_layout(&app.kit.ctx, "points")
	return TOP_BAR_H + 4 + points.y + 8
}

// Where the off-hand island's top goes, in points down the safe area, from last frame's
// size: centred down the left edge, kept between the view chips and the shelf where it
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

// The tool strip's buttons' size, the touch target, which keeps the shelf narrow enough
// to leave the stack beside it in a 1600-point window.
MESH_TOOL :: 48
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
	t := ctx.theme
	p := &k.bar_pop
	switch p.kind {
	case .Symmetry:
		if !ui.popover_begin(ctx, "bar symmetry", &p.open, p.at, p.side, {direction = .Column, gap = 4, padding = 10, width = 248}) do return
		defer ui.popover_end(ctx)
		symmetry_controls(app)
	case .Polyframe:
		if !ui.popover_begin(ctx, "bar polyframe", &p.open, p.at, p.side, {direction = .Column, gap = 4, padding = 10, width = 220}) do return
		defer ui.popover_end(ctx)
		ui.caption(ctx, "POLYFRAME SHOWS")
		ui.begin(ctx, "polyframe parts", {direction = .Row, gap = 4})
		if ui.toggle_button(ctx, "Lines", app.polyframe_lines, 96, tooltip = "The selected object's edges") do app.polyframe_lines = !app.polyframe_lines
		if ui.toggle_button(ctx, "Fill", app.polyframe_fill, 96, tooltip = "The selected object's polygroups in their colours") do app.polyframe_fill = !app.polyframe_fill
		ui.end(ctx)
	case .Remesh_Quick:
		if !ui.popover_begin(ctx, "bar remesh", &p.open, p.at, p.side, {direction = .Column, gap = 6, padding = 12, width = REMESH_QUICK_W}) do return
		defer ui.popover_end(ctx)
		kit_remesh_quick(app)
	case .Shading:
		if !ui.popover_begin(ctx, "bar shading", &p.open, p.at, p.side, {direction = .Column, padding = 6, width = 268}) do return
		defer ui.popover_end(ctx)
		kit_shading_menu(app)
	case .Camera:
		if !ui.popover_begin(ctx, "bar camera", &p.open, p.at, p.side, {direction = .Column, padding = 6, width = 268}) do return
		defer ui.popover_end(ctx)
		kit_camera_menu(app)
	case .View_Layout:
		if !ui.popover_begin(ctx, "bar view layout", &p.open, p.at, p.side, {direction = .Column, gap = 8, padding = 12, width = VIEW_LAYOUT_W + 24}) do return
		defer ui.popover_end(ctx)
		kit_view_layout_lens(app, VIEW_LAYOUT_W)
	case .Value:
		kit_value_pop(app)
	case .Value_Menu:
		kit_value_menu(app)
	case .Section:
		WIDTH :: KIT_INSPECTOR_W
		PADDING :: 12
		owner := ui.id_of(ctx, "bar section")
		size, _ := ui.prev_layout(ctx, "bar section")
		if !ui.popover_begin(ctx, "bar section", &p.open, p.at, p.side, {direction = .Column, gap = 6, padding = PADDING, width = WIDTH}) do return
		defer ui.popover_end(ctx)
		title, draw, obj_draw, found := bar_section(app, p.section)
		ui.begin(ctx, "bar section head", {direction = .Row, center = true})
		pinnable := panel_pinnable(p.section)
		ui.begin(ctx, "bar section title", {direction = .Column, width = WIDTH - 2 * PADDING - (2 if pinnable else 1) * t.target})
		ui.label(ctx, title, t.title_size, t.text, .Semibold)
		ui.end(ctx)
		// Pin keeps the popover's section as a panel of its own, in the right column.
		if pinnable && ui.icon_button(ctx, command_label(.Pin_Section, int(p.section)), ui.ICON_PANEL, selected = command_checked(app, .Pin_Section, int(p.section)), keys = command_hint(app, .Pin_Section, int(p.section))) {
			if !command_checked(app, .Pin_Section, int(p.section)) do command_run(app, .Pin_Section, int(p.section))
			p.open = false
		}
		if ui.icon_button(ctx, "Close", ui.ICON_CLOSE, keys = "Esc") do p.open = false
		ui.end(ctx)
		// The body scrolls in the room the window leaves under the popover's top, or over
		// the bottom bar up to the top bar.
		area := ui.safe_area(ctx)
		head := size.y - (ui.prev_rect(ctx, "bar section body").h if size.y > 0 else 0)
		room := max(area.y + area.h - p.at.y - 8 - head, 160)
		if p.side == .Above_Center do room = max(p.at.y - area.y - kit_top() - 8 - head, 160)
		scroll := kit_scroll_begin(ctx, "bar section body", &p.scroll, owner, WIDTH - 2 * PADDING, room, 6)
		obj := selected_object(app)
		switch {
		case !found:
			ui.paragraph(ctx, "Nothing to show here.")
		case obj_draw != nil && obj == nil:
			ui.paragraph(ctx, "Add or select an object first.")
		case obj_draw != nil:
			obj_draw(app, obj)
		case:
			draw(app)
		}
		kit_scroll_end(ctx, scroll)
	}
}

// The symmetry axes, Local, and the radial copies: the bar's Symmetry popover and the Lens
// stack's Symmetry panel.
symmetry_controls :: proc(app: ^App) {
	ctx := &app.kit.ctx
	ui.caption(ctx, "SYMMETRY")
	ui.begin(ctx, "symmetry axes", {direction = .Row, gap = 4})
	for axis in sculpt.Axis {
		name := fmt.tprint(axis)
		tip := fmt.tprintf("Symmetry across %s", name)
		if ui.toggle_button(ctx, name, axis in app.brush.symmetry, 48, command_hint(app, .Symmetry_X) if axis == .X else "", tip) do app.brush.symmetry ~= {axis}
	}
	if ui.toggle_button(ctx, "Local", app.brush.sym_local, 64, command_hint(app, .Local_Symmetry), COMMANDS[.Local_Symmetry].help) do command_run(app, .Local_Symmetry)
	ui.end(ctx)
	ui.caption(ctx, "RADIAL")
	ui.begin(ctx, "radial axes", {direction = .Row, gap = 4})
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
}

// Section `sec` of the tray, wherever its palette lists it: its title and what draws it
// (for the Object palette's, with the object).
bar_section :: proc(app: ^App, sec: Kit_Section) -> (title: string, draw: proc(app: ^App), obj_draw: proc(app: ^App, obj: ^Object), found: bool) {
	for s in BRUSH_SECTIONS do if s.section == sec do return s.title, s.draw, nil, true
	for s in SCENE_SECTIONS do if s.section == sec do return s.title, s.draw, nil, true
	for s in OBJECT_SECTIONS do if s.section == sec do return s.title, nil, s.draw, true
	return
}

ICON_MATERIAL :: rune(0xe5a2) // eclipse: a lit sphere
ICON_COLOUR :: rune(0xe1dd) // palette
ICON_OBJECTS :: rune(0xe104) // layers
ICON_SPLIT :: rune(0xe445) // split
ICON_MERGE :: rune(0xe444) // merge
ICON_ORTHO :: rune(0xe529) // cuboid
ICON_SYMMETRY :: rune(0xe362) // flip-horizontal-2
ICON_ADD :: rune(0xe086) // circle-plus: brushes raise and build
ICON_SUBTRACT :: rune(0xe083) // circle-minus: brushes dig and carve
ICON_SWAP_COLORS :: rune(0xe24a) // arrow-left-right
// The paint channel's three states: the surface, the surface and its colour, the colour.
ICON_CHANNEL_SCULPT :: rune(0xe231) // mountain
ICON_CHANNEL_BOTH :: rune(0xe5a1) // blend
ICON_CHANNEL_COLOR :: rune(0xe0b8) // droplet
ICON_LOCAL_SYMMETRY :: rune(0xe364) // flip-vertical-2: a mirror through the object's own middle
ICON_WIREFRAME :: rune(0xe0ec) // grid-3x3
ICON_FLOOR :: rune(0xe2fe) // axis-3d: the axes over the floor
ICON_TRANSPARENCY :: rune(0xe4a7) // square-stack: shapes seen through one another
ICON_SOLO :: rune(0xe53b) // scan-eye
ICON_GIZMO :: rune(0xe2e5) // move-3d
ICON_REMESH :: rune(0xe0eb) // globe: a sphere of even lines
ICON_DYNTOPO :: rune(0xe129) // network
ICON_RETOPO :: rune(0xe504) // grid-2x2
ICON_SUBDIVIDE :: rune(0xe62d) // grid-2x2-plus
ICON_BOOLEAN :: rune(0xe5a1) // blend
ICON_SHADING :: rune(0xe0a1) // contrast: a sphere half lit
ICON_CHEVRON_LEFT :: rune(0xe072)
ICON_CUSTOMISE :: rune(0xe1f9) // pencil
ICON_CAMERA :: rune(0xe068) // camera
