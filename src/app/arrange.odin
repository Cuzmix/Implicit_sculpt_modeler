package main

import "core:fmt"
import "core:strings"
import "../ui"

// Arrange (Lens): the one mode in which the interface's layout is changed, grown from
// Customise bars (bars.odin), whose rings, slot popovers and + tiles it keeps. While it is
// on, a head under the top bar names the workspace being arranged and offers which bars
// show, a drawer of every panel with where it goes, Reset bars, Revert, Save as new and
// Done; both columns show where a panel can be dropped, and a hidden bar shows as an
// outline in its place with Show. What is arranged is the current workspace's live layout:
// the switcher's dot says it has changed, and Save keeps it.

// The bars as the head names them, in the order it lists them.
@(rodata)
ZONE_NAMES := [Zone]string {
	.Brush_Bar  = "Brush bar",
	.View_Bar   = "View bar",
	.Dock       = "Dock",
	.Wheel      = "Wheel",
	.Action_Bar = "Next steps",
}

// The panels the drawer lists: every window a layout keeps, then each pinnable section
// pinned now.
@(private = "file")
arrange_panels :: proc(app: ^App) -> []Panel_Ref {
	out := make([dynamic]Panel_Ref, context.temp_allocator)
	for w in LAYOUT_PANELS do append(&out, Panel_Ref(w))
	for pin, sec in app.kit.panels.pins do if pin.on do append(&out, Panel_Ref(sec))
	return out[:]
}

// Where a panel is, as the drawer's choice shows it: 0 hidden, 1 the left column, 2 the
// right column, 3 floating.
@(private = "file")
ARRANGE_PLACES := [?]string{"Hidden", "Left", "Right", "Float"}

@(private = "file")
arrange_place :: proc(app: ^App, ref: Panel_Ref) -> int {
	if !panel_open(app, ref) do return 0
	side, _, docked := panel_docked(&app.kit, ref)
	if !docked do return 3
	return 1 if side == .Left else 2
}

// Puts panel `ref` where the drawer's choice says: hidden, at the end of a column, or
// floating where it last floated.
@(private = "file")
arrange_put :: proc(app: ^App, ref: Panel_Ref, place: int) {
	switch place {
	case 0:
		panel_set_open(app, ref, false)
		return
	case 1: panel_dock(app, ref, .Left, COLUMN_MAX)
	case 2: panel_dock(app, ref, .Right, COLUMN_MAX)
	case 3:
		if _, _, docked := panel_docked(&app.kit, ref); docked do panel_float(app, ref)
	}
	panel_set_open(app, ref, true)
	// The tray and the Objects card share a place, as opening either does.
	if r, ok := ref.(Kit_Window); ok && r == .Objects do app.kit.inspector = false
	if r, ok := ref.(Kit_Window); ok && r == .Inspector do app.kit.objects_card = false
}

// While arranging: the head under the top bar.
kit_arrange_head :: proc(app: ^App) {
	k := &app.kit
	if !k.bars_edit do return
	ctx := &k.ctx
	t := ctx.theme
	w := &k.workspaces
	ui.begin_anchored(ctx, "customise bars", .Center, .Start, {0, kit_top()}, {direction = .Column, gap = 6, padding = 8, radius = t.radius_large, background = .Raised})
	// Three short rows, so the head fits between the columns: what this is with Done,
	// which bars show, and what is done with panels and the layout.
	ui.begin(ctx, "arrange top", {direction = .Row, gap = 8, center = true})
	ui.begin(ctx, "customise bars text", {direction = .Column, padding = 4})
	name := workspace_name(k, w.current) if len(w.list) > 0 else "Sculpt"
	ui.label(ctx, fmt.tprintf("Arranging %s%s", name, " (changed)" if w.modified else ""), t.text_size, t.text, .Semibold)
	ui.label(ctx, "Tap a ringed button to change it, + to add one.", t.small_size, t.text_secondary)
	ui.end(ctx)
	if ui.button(ctx, "Done", .Flat, .Accent) do k.bars_edit = false
	ui.end(ctx)
	ui.begin(ctx, "arrange layout", {direction = .Row, gap = 6, center = true})
	if ui.button(ctx, "Panels", .Bordered, glyph = ui.ICON_PANEL) {
		was := k.arrange_drawer
		k.arrange_drawer = !was
	}
	k.arrange_drawer_at = ctx.last_rect
	changed := false
	for which in Bar_Which do changed ||= bar_changed(app, which)
	if ui.button(ctx, "Reset bars", .Bordered, enabled = changed) do bars_reset(k)
	_ = command_button(app, .Workspace_Revert, label = "Revert", variant = .Bordered)
	_ = command_button(app, .Workspace_Save_As, label = "Save as new", variant = .Bordered)
	ui.end(ctx)
	ui.begin(ctx, "arrange zones", {direction = .Row, gap = 4, center = true})
	ui.label(ctx, "Show", t.small_size, t.text_secondary)
	for z in Zone {
		shown := z not_in k.hidden
		w := ui.text_width(ctx, ZONE_NAMES[z], t.text_size, .Semibold) + 28
		if ui.toggle_button(ctx, fmt.tprintf("%s##zone", ZONE_NAMES[z]), shown, w, tooltip = fmt.tprintf("Show the %s in this workspace", strings.to_lower(ZONE_NAMES[z], context.temp_allocator))) {
			zone_toggle(k, z)
		}
	}
	ui.end(ctx)
	ui.end(ctx)
}

// Shows or hides zone `z` in the current layout, closing what floated from it.
zone_toggle :: proc(k: ^Kit_State, z: Zone) {
	k.hidden ~= {z}
	if z in k.hidden {
		kit_floats_close(k)
		k.bar_scrub = {}
	}
}

// The drawer of panels, under its button: each with where it is, to be changed with a tap.
kit_arrange_drawer :: proc(app: ^App) {
	k := &app.kit
	if !k.bars_edit do k.arrange_drawer = false
	ctx := &k.ctx
	t := ctx.theme
	if !ui.popover_begin(ctx, "arrange panels", &k.arrange_drawer, k.arrange_drawer_at, .Below, {direction = .Column, gap = 6, padding = 10, width = 420}) do return
	defer ui.popover_end(ctx)
	ui.caption(ctx, "PANELS")
	for ref in arrange_panels(app) {
		ui.begin(ctx, fmt.tprintf("arrange %s", panel_name(ref)), {direction = .Row, gap = 8, center = true})
		r := ui.place(ctx, {120, t.target})
		// The tray by what it is, not by the palette it shows now.
		title := panel_title(app, ref)
		if w, ok := ref.(Kit_Window); ok && w == .Inspector do title = "Palette tray"
		ui.text(ctx, title, r.x, r.y + r.h * 0.5, t.text_size, t.text)
		now := arrange_place(app, ref)
		if to := ui.tabs(ctx, fmt.tprintf("place##%s", panel_name(ref)), ARRANGE_PLACES[:], now, 66); to >= 0 && to != now do arrange_put(app, ref, to)
		ui.end(ctx)
	}
	ui.paragraph(ctx, "A section of the tray becomes a panel of its own with Pin as a panel, on its bar button's popover or in Search.")
}

// While arranging: each hidden bar as an outline where it would be, with Show.
kit_arrange_ghosts :: proc(app: ^App) {
	k := &app.kit
	if !k.bars_edit || k.hidden == {} do return
	ctx := &k.ctx
	t := ctx.theme
	area := ui.safe_area(ctx)
	for z in Zone {
		// The side bars' places are taken by the columns, which move out to the edges
		// when the bars hide; the head's Show switches bring those back.
		if z not_in k.hidden || z == .Brush_Bar || z == .View_Bar do continue
		// Where the bar sits, as an anchor and a size: along the bottom, or in the corner.
		x, y := ui.Anchor.Start, ui.Anchor.End
		offset := [2]f32{t.edge, t.edge}
		size := [2]f32{132, 132}
		#partial switch z {
		case .Dock:       x, y, offset, size = .Center, .End, {0, t.edge + DOCK_LIFT}, {420, t.target + 16}
		case .Action_Bar: x, y, offset, size = .Center, .End, {0, t.edge + DOCK_LIFT + t.target + 32}, {300, t.target}
		}
		if ctx.mirror && x != .Center do x = .End if x == .Start else .Start
		size = {min(size.x, area.w - 32), min(size.y, area.h - 32)}
		ui.begin_anchored(ctx, fmt.tprintf("hidden %v", z), x, y, offset, {direction = .Column, width = size.x, height = size.y, center = true})
		box := ui.prev_rect(ctx, fmt.tprintf("hidden %v", z))
		if box.w > 0 do ui.stroke_rect(ctx, box, t.radius_large, ui.color_fade(t.text_tertiary, 0.8), 1)
		label := fmt.tprintf("Show the %s##ghost", strings.to_lower(ZONE_NAMES[z], context.temp_allocator))
		if ui.button(ctx, label, .Light, glyph = ui.ICON_EYE) do zone_toggle(k, z)
		ui.end(ctx)
	}
}
