package main

import "core:fmt"
import "core:strings"
import "../ui"

// Arrange: the one mode in which the interface's layout is changed, grown from Customise
// bars (bars.odin), whose rings, slot popovers and + tiles it keeps. While it is on, the
// top bar and the Library (lens_arrange.odin) offer which bars show, where every panel
// goes, Reset zone, Revert, Save as new and Done; both columns show where a panel can be
// dropped, and a hidden bar shows as an outline in its place with Show. What is arranged
// is the current workspace's live layout: the switcher's dot says it has changed, and
// Save keeps it.

// The bars as the Library's Show chips name them, in the order it lists them.
@(rodata)
ZONE_NAMES := [Zone]string {
	.Brush_Bar  = "Off-hand island",
	.View_Bar   = "View rail",
	.Dock       = "Shelf",
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

// The Show chips: one for each bar, lit while the workspace shows it.
arrange_show_chips :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
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
}

// Shows or hides zone `z` in the current layout, closing what floated from it.
zone_toggle :: proc(k: ^Kit_State, z: Zone) {
	k.hidden ~= {z}
	if z in k.hidden do kit_floats_close(k)
}

// Every panel with where it is, to be changed with a tap: the Library's Panels tab.
arrange_panel_rows :: proc(app: ^App) {
	ctx := &app.kit.ctx
	t := ctx.theme
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
		case .Dock:       x, y, offset, size = .Center, .End, {0, t.edge + dock_lift(app)}, {420, t.target + 16}
		case .Action_Bar: x, y, offset, size = .Center, .End, {0, t.edge + dock_lift(app) + t.target + 32}, {300, t.target}
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
