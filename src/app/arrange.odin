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

// The panels the drawer lists: every window a layout keeps (a pinned section is a card of
// the stack, which goes where the stack goes).
@(private = "file")
arrange_panels :: proc(app: ^App) -> []Panel_Ref {
	out := make([dynamic]Panel_Ref, context.temp_allocator)
	for w in LAYOUT_PANELS do append(&out, Panel_Ref(w))
	return out[:]
}

// Where a panel is, as the drawer's choice shows it: 0 hidden, then for the stack 1 docked
// on the left, 2 docked on the right, 3 floating, and for the other windows 1 shown.
@(private = "file")
ARRANGE_PLACES := [?]string{"Hidden", "Left", "Right", "Float"}
@(private = "file")
ARRANGE_SHOWN := [?]string{"Hidden", "Shown"}

@(private = "file")
arrange_place :: proc(app: ^App, ref: Panel_Ref) -> int {
	if !panel_open(app, ref) do return 0
	if ref != Panel_Ref(Kit_Window.Inspector) do return 1
	switch app.kit.stack.place {
	case .Left:  return 1
	case .Right: return 2
	case .Float:
	}
	return 3
}

// Puts panel `ref` where the drawer's choice says: hidden, or shown (the stack docked on a
// side or floating where it last floated).
@(private = "file")
arrange_put :: proc(app: ^App, ref: Panel_Ref, place: int) {
	if place == 0 {
		panel_set_open(app, ref, false)
		return
	}
	if ref == Panel_Ref(Kit_Window.Inspector) {
		switch place {
		case 1: stack_place_set(app, .Left)
		case 2: stack_place_set(app, .Right)
		case 3: stack_place_set(app, .Float)
		}
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
		is_stack := ref == Panel_Ref(Kit_Window.Inspector)
		if is_stack do title = "Panel stack"
		ui.text(ctx, title, r.x, r.y + r.h * 0.5, t.text_size, t.text)
		now := arrange_place(app, ref)
		places := ARRANGE_PLACES[:] if is_stack else ARRANGE_SHOWN[:]
		if to := ui.tabs(ctx, fmt.tprintf("place##%s", panel_name(ref)), places, now, 66); to >= 0 && to != now do arrange_put(app, ref, to)
		ui.end(ctx)
	}
	ui.paragraph(ctx, "A section becomes a card kept in the stack with Pin to the stack, on its card's More, its bar button's popover or in Search.")
	// How the docked palettes show: their cards, or a strip of icons that open them.
	ui.begin(ctx, "arrange palettes density", {direction = .Row, gap = 8, center = true})
	r := ui.place(ctx, {120, t.target})
	ui.text(ctx, "Palettes show", r.x, r.y + r.h * 0.5, t.text_size, t.text)
	names := [len(Stack_Density)]string{"Panels", "Icons"}
	if to := ui.tabs(ctx, "Palettes show##arrange", names[:], int(app.kit.stack.density), 100); to >= 0 do stack_density_set(app, Stack_Density(to))
	ui.end(ctx)
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
		case .Dock:
			x, y, offset, size = .Center, .End, {0, t.edge + dock_lift(app)}, {420, t.target + 16}
			// Where Arrange put the shelf, if it moved it.
			if k.places[.Shelf].edge != .Default do x, y, offset, _ = bar_place_anchor(app, .Shelf, size)
		case .Action_Bar: x, y, offset, size = .Center, .End, {0, t.edge + dock_lift(app) + t.target + 32}, {300, t.target}
		}
		// begin_anchored mirrors the anchor for the left hand itself.
		size = {min(size.x, area.w - 32), min(size.y, area.h - 32)}
		ui.begin_anchored(ctx, fmt.tprintf("hidden %v", z), x, y, offset, {direction = .Column, width = size.x, height = size.y, center = true})
		box := ui.prev_rect(ctx, fmt.tprintf("hidden %v", z))
		if box.w > 0 do ui.stroke_rect(ctx, box, t.radius_large, ui.color_fade(t.text_tertiary, 0.8), 1)
		label := fmt.tprintf("Show the %s##ghost", strings.to_lower(ZONE_NAMES[z], context.temp_allocator))
		if ui.button(ctx, label, .Light, glyph = ui.ICON_EYE) do zone_toggle(k, z)
		ui.end(ctx)
	}
}
