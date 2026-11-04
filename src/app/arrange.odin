package main

import "core:fmt"
import "core:strings"
import "../ui"

// Arrange: the one mode in which the interface's layout is changed, grown from Customise
// bars (bars.odin), whose rings, slot popovers and + tiles it keeps. While it is on, the
// top bar and the Library (lens_arrange.odin) offer which bars show, where every panel
// goes, Revert, Save as new and Done; both columns show where a panel can be
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

// The panels the drawer lists: every window a layout keeps.
@(private = "file")
arrange_panels :: proc(app: ^App) -> []Panel_Ref {
	out := make([dynamic]Panel_Ref, context.temp_allocator)
	for w in LAYOUT_PANELS do append(&out, Panel_Ref(w))
	return out[:]
}

// Where a panel is, as the drawer's choice shows it: 0 hidden, 1 shown.
@(private = "file")
ARRANGE_SHOWN := [?]string{"Hidden", "Shown"}

@(private = "file")
arrange_place :: proc(app: ^App, ref: Panel_Ref) -> int {
	return 1 if panel_open(app, ref) else 0
}

// Puts panel `ref` where the drawer's choice says: hidden, or shown.
@(private = "file")
arrange_put :: proc(app: ^App, ref: Panel_Ref, place: int) {
	panel_set_open(app, ref, place != 0)
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

// Every panel with where it is, to be changed with a tap: Settings > Bars.
arrange_panel_rows :: proc(app: ^App) {
	ctx := &app.kit.ctx
	t := ctx.theme
	ui.caption(ctx, "PANELS")
	for ref in arrange_panels(app) {
		ui.begin(ctx, fmt.tprintf("arrange %s", panel_name(ref)), {direction = .Row, gap = 8, center = true})
		r := ui.place(ctx, {120, t.target})
		ui.text(ctx, panel_title(app, ref), r.x, r.y + r.h * 0.5, t.text_size, t.text)
		now := arrange_place(app, ref)
		if to := ui.tabs(ctx, fmt.tprintf("place##%s", panel_name(ref)), ARRANGE_SHOWN[:], now, 66); to >= 0 && to != now do arrange_put(app, ref, to)
		ui.end(ctx)
	}
	ui.paragraph(ctx, "A card opens beside the dock button that holds it; its Pin keeps it open in the workspace.")
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
			if k.docks[.Shelf].edge != .Default do x, y, offset, _ = dock_anchor(app, .Shelf, size)
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
