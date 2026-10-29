package main

import "core:fmt"
import "core:math"
import "core:strings"

import "../poly"
import "../sculpt"
import "../ui"

// The Lens shelf (round 2 of the mockups): a floating strip of brush tiles at the bottom
// centre with All at their end, then after a divider the tool strip
// (Bar_Which.Tools: Move, Remesh, Subdivide...), and under it the names of its five
// pages (Sculpt, Paint, Move, Curve, Model), which replace the old mode switch: each page is
// a bar of its own (Bar_Which.Shelf_Sculpt on, bars.odin) that Arrange changes, as it does
// the tools. A finger or a pen swiped sideways along the shelf turns its page; the wheel over it does the same for a mouse. A tap on a tile picks
// it; a long press shows its quick settings above it, so the hand never covers them; All
// (or B) opens the brush picker, a large sheet of stroke previews over the shelf, whose
// cards can be dragged onto a tile to keep them there. The shelf is laid out as "dock",
// so whatever keeps clear of the dock keeps clear of it.

Shelf_Page :: enum u8 {
	Sculpt,
	Paint,
	Move,
	Curve,
	Model,
}

@(rodata)
SHELF_PAGE_NAMES := [Shelf_Page]string {
	.Sculpt = "Sculpt",
	.Paint  = "Paint",
	.Move   = "Move",
	.Curve  = "Curve",
	.Model  = "Model",
}

// The most tiles a page holds, and how many a tablet-shaped window shows, so the shelf ends
// before the pen hand's palm.
SHELF_MAX :: 12
SHELF_TABLET :: 8
// How many tiles the focused shelf shows (screen focus2): seven brushes, then All.
SHELF_FOCUS :: 7

// A fresh install's pages: the brushes most reached for; painting and its colours; what
// moves the surface; the curve and insert tools.
SHELF_SCULPT :: [?]Bar_Slot {
	{.Brush, int(sculpt.Brush_Kind.Clay)}, {.Brush, int(sculpt.Brush_Kind.Draw)}, {.Brush, int(sculpt.Brush_Kind.Smooth)},
	{.Brush, int(sculpt.Brush_Kind.Inflate)}, {.Brush, int(sculpt.Brush_Kind.Pinch)}, {.Brush, int(sculpt.Brush_Kind.Crease)},
	{.Brush, int(sculpt.Brush_Kind.Grab)}, {.Brush, int(sculpt.Brush_Kind.Flatten)}, {.Brush, int(sculpt.Brush_Kind.Mask)},
	{.Brush, int(sculpt.Brush_Kind.Layer)},
}
SHELF_PAINT :: [?]Bar_Slot {
	{.Brush, int(sculpt.Brush_Kind.Paint)}, {.Brush, int(sculpt.Brush_Kind.Mask)}, {.Brush, int(sculpt.Brush_Kind.Smooth)},
	{.Colors_Card, 0}, {.Swap_Colors, 0}, {.Paint_Channel, 0},
}
SHELF_MOVE :: [?]Bar_Slot {
	{.Brush, int(sculpt.Brush_Kind.Grab)}, {.Brush, int(sculpt.Brush_Kind.Snake_Hook)}, {.Brush, int(sculpt.Brush_Kind.Cloth)},
	{.Tool_Move, 0}, {.Brush, int(sculpt.Brush_Kind.Smooth)},
}
SHELF_CURVE :: [?]Bar_Slot{{.Tool_Curve, 0}, {.Tool_Insert, 0}, {.Brush, int(sculpt.Brush_Kind.Smooth)}}
// Model mode: the actions box modelling uses most (each takes the Model tool), the cages
// to start from, and the way out to sculpting. The other actions and primitives are in the
// Model palette and the All picker, for want of more tiles.
SHELF_MODEL :: [?]Bar_Slot {
	{.Model_Action, int(Model_Action.Extrude)}, {.Model_Action, int(Model_Action.Inset)}, {.Model_Action, int(Model_Action.Move)},
	{.Model_Action, int(Model_Action.Delete)}, {.Model_Action, int(Model_Action.Insert_Loop)}, {.Model_Action, int(Model_Action.Remove_Loop)},
	{.Model_Action, int(Model_Action.Bridge)}, {.Model_Action, int(Model_Action.Close_Hole)}, {.Model_Action, int(Model_Action.Weld)},
	{.Add_Cage, int(poly.Primitive.Cube)}, {.Add_Cage, int(poly.Primitive.Cylinder)}, {.Apply_Cage, 0},
}

// The shelf's state, in Kit_State: its pages' lists, the page shown, the quick settings a
// long press opened, the picker's card being carried to a tile, and where the tiles were
// laid out (for the carried card to land on).
Shelf :: struct {
	lists:    [Shelf_Page]Bar_List,
	page:     Shelf_Page,
	quick:    bool,
	quick_at: ui.Rect,
	carry:    Maybe(Bar_Slot), // the card dragged from the picker, once past the slop
	carry_at: [2]f32,
	tiles:    [SHELF_MAX]ui.Rect,
	shown:    int, // tiles laid out last frame
	tools:    int, // tool buttons laid out last frame
	row:      ui.Rect, // where the brushes' row was laid out last frame
	slide:    f32, // how far the page just turned still slides in, points (eases to 0)
	wheel:    f32, // the mouse wheel over the shelf, until it adds up to a page
	// For the exit stats: cards dropped on a tile, pages turned, and of those the ones a
	// swipe or the wheel turned.
	drops:    int,
	turns:    int,
	swipes:   int,
}

// The bar that holds page `p`.
shelf_which :: proc(p: Shelf_Page) -> Bar_Which {
	return Bar_Which(int(Bar_Which.Shelf_Sculpt) + int(p))
}

// Whether bar `which` is one of the shelf's pages, and which.
shelf_page_of :: proc(which: Bar_Which) -> (Shelf_Page, bool) {
	i := int(which) - int(Bar_Which.Shelf_Sculpt)
	if i < 0 || i >= len(Shelf_Page) do return {}, false
	return Shelf_Page(i), true
}

// A fresh install's page `p`.
shelf_fresh :: proc(p: Shelf_Page) -> Bar_List {
	switch p {
	case .Sculpt:
		d := SHELF_SCULPT
		return bar_list_of(d[:])
	case .Paint:
		d := SHELF_PAINT
		return bar_list_of(d[:])
	case .Move:
		d := SHELF_MOVE
		return bar_list_of(d[:])
	case .Curve:
		d := SHELF_CURVE
		return bar_list_of(d[:])
	case .Model:
		d := SHELF_MODEL
		return bar_list_of(d[:])
	}
	return {}
}

// Puts every page back as a fresh install has it.
shelf_reset :: proc(k: ^Kit_State) {
	for p in Shelf_Page do k.shelf.lists[p] = shelf_fresh(p)
}

// The picker's item as a shelf slot: a plain brush, or a tool's command. Presets and the
// mask and hide shapes are picked from the picker, as they have no command of their own.
shelf_slot_of :: proc(it: Brush_Item) -> (Bar_Slot, bool) {
	#partial switch it.what {
	case .Slot:
		if it.slot.command.id != .None do return it.slot.command, true
		if it.slot.preset == 0 do return {.Brush, int(it.slot.kind)}, true
	case .Tool:
		return {TOOL_COMMANDS[it.tool], 0}, true
	}
	return {}, false
}

// A tile's name: a brush's own ("Clay", as the tiles are all brushes or tools), else the
// bar's name for the command.
shelf_label :: proc(s: Bar_Slot) -> string {
	if s.id == .Brush && s.arg >= 0 && s.arg < len(sculpt.Brush_Kind) do return BRUSHES[sculpt.Brush_Kind(s.arg)].name
	return bar_label(s)
}

// How much of the main pane's width the shelf leaves each side: the dial's reach from the
// off-hand edge, and as much again on the other side.
SHELF_SIDE_ROOM :: 170
// The shelf's padding, round its tiles.
SHELF_PAD :: 4
// How fast a turned page settles (per second, of what is left), and how far it starts
// from (of the row's width).
SHELF_SLIDE_RATE :: 16
SHELF_SLIDE_FROM :: 0.35
// The fewest brushes and tools the shelf gives up the other's room for: brushes down to
// six before tools go below three, then brushes down to three before the last tools go.
SHELF_KEEP_BRUSHES :: 6
SHELF_KEEP_TOOLS :: 3
SHELF_LEAST_BRUSHES :: 3

// How wide the shelf is with `brushes` tiles, All, and `tools` buttons after a divider;
// `adding` counts the + tiles Arrange puts at the end of each.
shelf_width :: proc(brushes, tools: int, adding := false) -> f32 {
	w := f32(brushes + 1 + int(adding)) * ui.BRUSH_TILE.x + 2 * SHELF_PAD
	if tools > 0 || adding do w += 9 + f32(tools + int(adding)) * MESH_TOOL
	return w
}

// How many of the page's `brushes` and of the `tools` fit across `room` points: what does
// not fit is still in All and in Search.
shelf_fit :: proc(brushes, tools: int, room: f32, adding := false) -> (shown_brushes, shown_tools: int) {
	b, t := brushes, tools
	for b > min(brushes, SHELF_KEEP_BRUSHES) && shelf_width(b, t, adding) > room do b -= 1
	for t > min(tools, SHELF_KEEP_TOOLS) && shelf_width(b, t, adding) > room do t -= 1
	for b > min(brushes, SHELF_LEAST_BRUSHES) && shelf_width(b, t, adding) > room do b -= 1
	for t > 0 && shelf_width(b, t, adding) > room do t -= 1
	return b, t
}

// The shelf at the bottom centre (left of it on a tablet-shaped window, clear of the palm),
// with the page names under it: the page's brushes, All, then the tools. Returns where the
// picker opens over: the shelf.
kit_shelf :: proc(app: ^App) -> (sheet_anchor: ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	sh := &k.shelf
	which := shelf_which(sh.page)
	used := bar_used(app, which)
	tools := bar_used(app, .Tools)
	n := len(used)
	if lens_palm(app) > 0 do n = min(n, SHELF_TABLET)
	area := ui.safe_area(ctx)
	shift: f32 = 0
	if lens_palm(app) > 0 do shift = -area.w * 0.09
	// Between the dial's reach and as much on the other side, of the window or, with panes
	// beside the main one, of the main pane, under which the shelf then stands, as the
	// off-hand set stays with it.
	span := area
	if g := &k.grid; grid_panes(g) > 1 && g.maximised == 0 && g.main.w > 0 {
		span = g.main
		shift = g.main.x + g.main.w * 0.5 - (area.x + area.w * 0.5)
	}
	if ctx.mirror do shift = -shift
	centre := area.x + area.w * 0.5 + shift
	room := 2 * max(min(centre - span.x, span.x + span.w - centre) - SHELF_SIDE_ROOM, 0)
	// Focused, the shelf is the brushes most reached for and All, without the page names
	// or the tools.
	focus := lens_focus(k)
	// The Model page's cage has its own tools on the page, and the mesh tools do not work
	// on a cage, so they make room for its tiles there.
	tools_here := !focus && sh.page != .Model
	m := len(tools) if tools_here else 0
	if focus do n = min(n, SHELF_FOCUS)
	n, m = shelf_fit(n, m, room, k.bars_edit && !focus)

	if !focus do lens_shelf_pages(app, shift)
	// A sideways drag that starts on any of the shelf's buttons turns the page: the shelf
	// is drag-scrolled, so a finger or a pen pressed on a tile waits to see which way it
	// goes (ui.swipe_update), and only the brushes, the page's own, slide.
	shelf_id := ui.id_of(ctx, "dock")
	shelf_at := ui.prev_rect(ctx, "dock")
	offset, turn := ui.swipe_update(ctx, shelf_id, shelf_at)
	shelf_wheel(app, shelf_at, &turn)
	if turn != 0 && shelf_turn(app, turn) do sh.swipes += 1
	// Past the first or the last page the row gives a little, as a scroll view's edge does.
	if (offset > 0 && sh.page == min(Shelf_Page)) || (offset < 0 && sh.page == max(Shelf_Page)) do offset *= 0.3
	slide := offset + sh.slide
	ui.begin_anchored(ctx, "dock", .Center, .End, {shift, t.edge + dock_lift(app)}, {direction = .Row, gap = 0, padding = SHELF_PAD, radius = t.radius_large + 4, background = .Panel, center = true, drag_scroll = true})
	adding := k.bars_edit && !focus
	// Asked for in the shelf, as the row's id is the shelf's child.
	sh.row = ui.prev_rect(ctx, "shelf brushes")
	brushes_at := sh.row
	ui.begin(ctx, "shelf brushes", {direction = .Row, gap = 0, width = f32(n + int(adding)) * ui.BRUSH_TILE.x, height = ui.BRUSH_TILE.y, clip = true})
	mark := ui.vertex_mark(ctx)
	sh.shown = n
	for s, i in used[:n] {
		name := fmt.tprintf("%s##shelf %v %d", shelf_label(s), sh.page, i)
		if ui.brush_tile(ctx, name, bar_icon(s), bar_lit(app, s), command_hint(app, s.id, s.arg)) {
			if k.bars_edit do bar_slot_open(app, which, i, ctx.last_rect)
			else do bar_slot_run(app, s, ctx.last_rect, .Above_Center)
		}
		sh.tiles[i] = ctx.last_rect
		if k.bars_edit {
			bar_edit_ring(app, ctx.last_rect)
		} else if ctx.last_id != 0 && ui.secondary(ctx) {
			// A brush's long press picks it and shows its quick settings over the tile; a
			// command's does what it does on any bar.
			if s.id == .Brush {
				command_run(app, .Brush, s.arg)
				kit_floats_close(k)
				sh.quick, sh.quick_at = true, ctx.last_rect
			} else if bar_has_more(s.id) {
				bar_slot_more(app, s, ctx.last_rect, .Above_Center)
			}
		}
		// The card carried from the picker lands on the tile it is let go over.
		if sh.carry != nil && ui.rect_contains(ctx.last_rect, sh.carry_at) do ui.stroke_rect(ctx, ctx.last_rect, t.radius_medium + 2, t.accent, 2)
	}
	if adding && ui.brush_tile(ctx, "Add##shelf add", ui.ICON_PLUS, false) do bar_choose(app, {which = which, slot = len(used), add = true})
	ui.end(ctx)
	// After the row ends, so the highlight under the picked tile, drawn as it ends, slides
	// with it.
	if slide != 0 {
		w := max(brushes_at.w, ui.BRUSH_TILE.x)
		ui.transform_since(ctx, mark, opacity = 1 - min(abs(slide) / w, 1) * 0.7, offset = {slide, 0})
	}
	if ui.brush_tile(ctx, "All##shelf all", ui.ICON_GRID, k.browser, command_hint(app, .Brush_Picker)) do brush_picker_toggle(app)
	sheet_anchor = ctx.last_rect
	// The tools, the same on every page and kept by the workspace's layout.
	sh.tools = m
	if m > 0 || (adding && tools_here) do ui.divider(ctx, 32)
	for s, i in tools[:m] do bar_slot_button(app, .Tools, i, s, MESH_TOOL)
	if adding && tools_here do bar_add_button(app, .Tools, len(tools), MESH_TOOL)
	ui.end(ctx)
	// The page the slide is heading for comes in behind it from that side, as a home
	// screen's next page does; it only shows, so it takes no press.
	if slide != 0 && brushes_at.w > 0 do shelf_peek(app, brushes_at, slide, -1 if slide > 0 else 1)
	// The page just turned slides in the rest of the way.
	sh.slide = 0 if ctx.reduced_motion || abs(sh.slide) < 0.5 else sh.slide * math.exp(-ctx.input.dt * SHELF_SLIDE_RATE)
	// The picker centres over the whole shelf, which stays in sight under it, so a card can
	// be carried down onto any tile.
	if strip := ui.prev_rect(ctx, "dock"); strip.w > 0 do sheet_anchor = strip
	return
}

// Turns the shelf `by` pages (on from Curve, back from Sculpt, it stays), the new page's
// brushes sliding in from the side they come from. Returns whether it turned.
shelf_turn :: proc(app: ^App, by: int) -> bool {
	sh := &app.kit.shelf
	to := Shelf_Page(clamp(int(sh.page) + by, 0, len(Shelf_Page) - 1))
	if to == sh.page do return false
	w := sh.row.w
	sh.slide = (1 if to > sh.page else -1) * w * SHELF_SLIDE_FROM
	sh.page, sh.quick = to, false
	sh.turns += 1
	return true
}

// The mouse wheel over the shelf turns its page: a notch, or a trackpad's swipe adding up
// to one, a page; down or toward you is the next.
@(private = "file")
shelf_wheel :: proc(app: ^App, at: ui.Rect, turn: ^int) {
	sh := &app.kit.shelf
	in_ := app.kit.ctx.input
	if in_.wheel == 0 || !in_.mouse_valid || !ui.rect_contains(at, in_.mouse) {
		sh.wheel = 0
		return
	}
	sh.wheel += in_.wheel
	if abs(sh.wheel) >= 1 {
		turn^ = 1 if sh.wheel < 0 else -1
		sh.wheel = 0
	}
}

// Page `page_by` from the shown one, if there is one, over the brushes' row `at`, slid
// `slide` points and a row's width further toward where it comes in from.
@(private = "file")
shelf_peek :: proc(app: ^App, at: ui.Rect, slide: f32, page_by: int) {
	k := &app.kit
	ctx := &k.ctx
	i := int(k.shelf.page) + page_by
	if i < 0 || i >= len(Shelf_Page) do return
	page := Shelf_Page(i)
	used := bar_used(app, shelf_which(page))
	ui.begin_at(ctx, "shelf peek", {at.x, at.y}, {direction = .Row, gap = 0, width = at.w, height = at.h, clip = true, inert = true})
	mark := ui.vertex_mark(ctx)
	for s, j in used[:min(len(used), int(at.w / ui.BRUSH_TILE.x) + 1)] {
		_ = ui.brush_tile(ctx, fmt.tprintf("%s##peek %v %d", shelf_label(s), page, j), bar_icon(s), false)
	}
	ui.end(ctx)
	ui.transform_since(ctx, mark, opacity = min(abs(slide) / at.w, 1), offset = {slide + f32(page_by) * at.w, 0})
}

// The page names under the shelf, each a tap away; the shelf stands over them.
@(private = "file")
lens_shelf_pages :: proc(app: ^App, shift: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	sh := &k.shelf
	ui.begin_anchored(ctx, "dock pages", .Center, .End, {shift, max(t.edge - 10, 2)}, {direction = .Row, gap = 2, padding = 2, radius = t.radius_large, background = .Panel, center = true})
	for p in Shelf_Page {
		name := SHELF_PAGE_NAMES[p]
		w := ui.text_width(ctx, name, t.small_size, .Semibold) + 26
		a := ui.area(ctx, fmt.tprintf("%s page##shelf", name), {w, 24})
		on := p == sh.page
		if a.hovered && !on do ui.fill_rect(ctx, a.rect, t.radius_medium, t.fill_hover)
		ui.fill_circle(ctx, {a.rect.x + 9, a.rect.y + a.rect.h * 0.5}, 3, t.accent if on else t.text_tertiary)
		ui.text(ctx, name, a.rect.x + 16, a.rect.y + a.rect.h * 0.5, t.small_size, t.text if on else t.text_secondary, .Semibold if on else .Regular)
		if a.clicked && !on do shelf_turn(app, int(p) - int(sh.page))
	}
	ui.end(ctx)
}

// Opens the brush picker over the shelf, or closes it.
brush_picker_toggle :: proc(app: ^App) {
	k := &app.kit
	was := k.browser
	kit_floats_close(k)
	k.browser, k.browser_at, k.grid_scroll, k.grid_reveal = !was, .Dock, 0, true
}

// A long-pressed tile's quick settings, over it: the brush's name with its favourite star,
// Radius and Strength, its stroke kind, its alpha and the lazy mouse; Pin as panel keeps the
// stroke's section as a panel, and All settings opens the brush's.
kit_shelf_quick :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	sh := &k.shelf
	if !ui.popover_begin(ctx, "shelf quick", &sh.quick, sh.quick_at, .Above_Center, {direction = .Column, gap = 6, padding = 12, width = 360}) do return
	defer ui.popover_end(ctx)
	kind := app.brush.kind
	cur := brush_item_current(app)
	key := brush_item_key(app, cur)
	_, favourite := brush_favorite(&k.brushes, key)
	ui.begin(ctx, "shelf quick head", {direction = .Row, gap = 8, center = true, width = 336})
	r := ui.place(ctx, {32, 32})
	lens_stroke_preview(ctx, r, cur, app)
	ui.label(ctx, ui.text_fit(ctx, brush_item_name(app, cur), t.title_size, 360 - 24 - 40 - 8 - t.target, .Semibold), t.title_size, t.text, .Semibold)
	ui.spacer(ctx, ui.row_room(ctx) - 8 - t.target)
	if ui.icon_button(ctx, "Favorite (on)##quick" if favourite else "Favorite##quick", ICON_HEART, selected = favourite) do brush_favorite_toggle(&k.brushes, key)
	ui.end(ctx)
	_ = ui.slider(ctx, "Radius", &app.brush.radius_px, MIN_RADIUS_PX, MAX_RADIUS_PX, .Logarithmic, fmt.tprintf("%.0f px", app.brush.radius_px))
	s := brush_strength(app)
	_ = ui.slider(ctx, "Strength", s, MIN_STRENGTH, 1, .Linear, fmt.tprintf("%.2f", s^))
	if BRUSHES[kind].flags & {.Grab, .Hook, .Cloth} == {} {
		ui.caption(ctx, "STROKE")
		strokes: [len(Stroke_Mode)]string
		for m, i in Stroke_Mode do strokes[i] = STROKE_MODE_NAMES[m]
		if picked := ui.tabs(ctx, "shelf stroke kind", strokes[:], int(app.brush.stroke)); picked >= 0 do app.brush.stroke = Stroke_Mode(picked)
		ui.caption(ctx, "ALPHA")
		ui.begin(ctx, "shelf quick alphas", {direction = .Row})
		kit_alpha_cell(app, -1, 56)
		shown := 0
		for e, i in app.alphas {
			if e.gone || shown >= 5 do continue
			kit_alpha_cell(app, i, 56)
			shown += 1
		}
		ui.end(ctx)
		_ = ui.slider(ctx, "Lazy mouse", &app.brush.lazy_px, 0, 150, .Linear, "off" if app.brush.lazy_px < 0.5 else fmt.tprintf("%.0f px", app.brush.lazy_px))
	}
	ui.begin(ctx, "shelf quick actions", {direction = .Row, gap = 6})
	pinned := command_checked(app, .Pin_Section, int(Kit_Section.Stroke))
	if command_button(app, .Pin_Section, int(Kit_Section.Stroke), label = "Unpin panel" if pinned else "Pin as panel", variant = .Bordered, glyph = ui.ICON_PANEL) do sh.quick = false
	if ui.button(ctx, "All settings", .Bordered, glyph = ui.ICON_SETTINGS) {
		sh.quick = false
		brush_item_settings(app, cur)
	}
	ui.end(ctx)
}

// The picker's width and its card grid's columns.
SHEET_W :: 1000
SHEET_COLUMNS :: 4

// The brush picker (All on the shelf, or B): a large sheet over the shelf with the
// categories down its left in the app's order, then a search field, the shelf's page names
// (which narrow All to what each page is for), Install pack and Close, then every brush as
// a card showing its stroke on clay. A tap on a card picks it and closes the sheet, a long
// press shows its settings, and a drag carries it onto a shelf tile to keep it there.
kit_brush_sheet :: proc(app: ^App, anchor: ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	p := &k.brushes
	sh := &k.shelf
	brush_recent_track(app)
	if p.category == .Pack && p.pack >= len(app.library.packs) do p.category = .All
	shelf_carry_update(app)
	if !k.browser do return
	area := ui.safe_area(ctx)
	width := min(f32(SHEET_W), area.w - 2 * t.edge - 16)
	room := max(anchor.y - area.y - kit_top() - 24, 260)
	owner := ui.id_of(ctx, "brush sheet")
	if !ui.popover_begin(ctx, "brush sheet", &k.browser, anchor, .Above_Center, {direction = .Row, gap = 0, padding = 0, width = width, height = room}) do return
	defer ui.popover_end(ctx)
	all := brush_items_all(app)
	side := brush_palette_categories(app, owner, all[:], room)
	main_w := width - side
	ui.begin(ctx, "brush sheet main", {direction = .Column, gap = 8, padding = 12, width = main_w})
	ui.begin(ctx, "brush sheet head", {direction = .Row, gap = 8, center = true, width = main_w - 24})
	p.searching = true
	_ = ui.text_field(ctx, "Search brushes", p.search[:], min(300, main_w * 0.36), hold = p.search_focus, hint = fmt.tprintf("Search %d brushes", len(all)))
	p.search_focus = false
	pages: [len(Shelf_Page)]string
	for name, i in SHELF_PAGE_NAMES do pages[i] = name
	if picked := ui.tabs(ctx, "brush sheet page", pages[:], int(sh.page), item_width = 72); picked >= 0 && Shelf_Page(picked) != sh.page do shelf_turn(app, picked - int(sh.page))
	IMPORT_W :: 104
	ui.spacer(ctx, ui.row_room(ctx) - 8 - IMPORT_W - 8 - t.target)
	_ = command_button(app, .Pick_Pack, label = "Import", variant = .Bordered, width = IMPORT_W, glyph = ui.ICON_PLUS)
	if ui.icon_button(ctx, "Close", ui.ICON_CLOSE, keys = "Esc") do k.browser = false
	ui.end(ctx)
	list := brush_sheet_list(app, all[:])
	inner := main_w - 24
	card_w := (inner - f32(SHEET_COLUMNS - 1) * 10) / SHEET_COLUMNS
	CARD_H :: 110
	grid_h := room - 24 - t.target - 8 - 36
	scroll := kit_scroll_begin(ctx, "brush sheet grid", &k.grid_scroll, owner, inner, grid_h, 10)
	pick, settings: Maybe(Brush_Item)
	for l, i in list {
		if i % SHEET_COLUMNS == 0 do ui.begin(ctx, fmt.tprintf("brush sheet row %d", i / SHEET_COLUMNS), {direction = .Row, gap = 10})
		a := ui.area(ctx, fmt.tprintf("%s##sheet %s", l.name, l.key), {card_w, CARD_H})
		on := brush_item_on(app, l.item)
		ui.fill_rect(ctx, a.rect, t.radius_large, t.accent_soft if on else t.surface)
		if a.hovered && !on do ui.fill_rect(ctx, a.rect, t.radius_large, t.fill_hover)
		ui.stroke_rect(ctx, a.rect, t.radius_large, t.accent if on else t.border, 1)
		lens_stroke_preview(ctx, {a.rect.x + 8, a.rect.y + 8, a.rect.w - 16, 70}, l.item, app)
		name := ui.text_fit(ctx, l.name, t.small_size, a.rect.w - 40, .Semibold)
		ui.text(ctx, name, a.rect.x + 10, a.rect.y + a.rect.h - 16, t.small_size, t.accent if on else t.text, .Semibold)
		if _, fav := brush_favorite(p, l.key); fav do ui.icon(ctx, ICON_HEART, {a.rect.x + a.rect.w - 16, a.rect.y + a.rect.h - 16}, t.icon_small - 2, t.warning)
		ui.tip(ctx, a.id, a.rect, l.name, brush_item_hint(app, l.item))
		// A drag past the slop carries the card toward the shelf; it is no tap then.
		if a.held && sh.carry == nil && math.abs(ctx.input.mouse.y - ctx.press_mouse.y) + math.abs(ctx.input.mouse.x - ctx.press_mouse.x) > t.slop * 2 {
			if s, ok := shelf_slot_of(l.item); ok {
				sh.carry, sh.carry_at = s, ctx.input.mouse
				ui.press_used(ctx)
			}
		}
		if a.clicked && sh.carry == nil do pick = l.item
		if ui.secondary(ctx) do settings = l.item
		if i % SHEET_COLUMNS == SHEET_COLUMNS - 1 || i == len(list) - 1 do ui.end(ctx)
	}
	if len(list) == 0 do ui.paragraph(ctx, "No brush has that in its name." if brush_query(p) != "" else "Nothing here yet.", inner)
	kit_scroll_end(ctx, scroll)
	ui.label(ctx, "Drag a brush onto the shelf to keep it there. Long press for its settings.", t.small_size, t.text_secondary)
	ui.end(ctx)
	if it, ok := pick.?; ok {
		brush_item_pick(app, it)
		p.picks += 1
		k.browser = false
	}
	if it, ok := settings.?; ok {
		brush_item_settings(app, it)
		p.picks += 1
		k.browser = false
	}
}

// The search's text, trimmed and in lower case.
brush_query :: proc(p: ^Brush_Palette) -> string {
	return strings.to_lower(strings.trim_space(string(cstring(raw_data(p.search[:])))), context.temp_allocator)
}

// What the sheet's grid shows: the browser's list, and with All, only what the shelf's
// page is for (Sculpt: the clay, crease, smooth and history brushes and the presets; Paint:
// painting and masks; Move: moving and cloth; Curve: curves, inserts, clipping and hiding).
brush_sheet_list :: proc(app: ^App, all: []Listed_Brush) -> []Listed_Brush {
	p := &app.kit.brushes
	list := brush_palette_list(app, all)
	if p.category != .All || brush_query(p) != "" do return list
	out := make([dynamic]Listed_Brush, context.temp_allocator)
	for l in list {
		c := brush_item_category(l.item)
		page: Shelf_Page
		#partial switch c {
		case .Paint, .Mask:              page = .Paint
		case .Move, .Cloth:              page = .Move
		case .Curve_Insert, .Clip_Hide:  page = .Curve
		case:                            page = .Sculpt
		}
		if l.item.what == .Tool && l.item.tool == .Model do page = .Model
		if page == app.kit.shelf.page do append(&out, l)
	}
	return out[:]
}

// Follows the card carried from the picker: it shows under the pointer, and let go over a
// shelf tile it takes that tile's place on the page shown.
@(private = "file")
shelf_carry_update :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	sh := &k.shelf
	s, ok := sh.carry.?
	if !ok do return
	in_ := ctx.input
	sh.carry_at = in_.mouse
	if in_.cancel {
		sh.carry = nil
		return
	}
	if .Left in in_.down {
		label := shelf_label(s)
		w := ui.text_width(ctx, label, t.small_size, .Semibold) + 44
		// Above the finger, which would cover it; the tile under the finger is ringed.
		r := ui.Rect{in_.mouse.x - w * 0.5, in_.mouse.y - 64, w, 36}
		ui.begin_at(ctx, "shelf carry", {r.x, r.y}, {width = r.w, height = r.h, inert = true})
		ui.fill_rect(ctx, r, t.radius_medium, t.frame)
		ui.stroke_rect(ctx, r, t.radius_medium, t.accent, 1.5)
		ui.icon(ctx, bar_icon(s), {r.x + 18, r.y + r.h * 0.5}, t.icon_small, t.text)
		ui.text(ctx, label, r.x + 32, r.y + r.h * 0.5, t.small_size, t.text, .Semibold)
		ui.end(ctx)
		return
	}
	sh.carry = nil
	which := shelf_which(sh.page)
	for r, i in sh.tiles[:sh.shown] {
		if !ui.rect_contains(r, in_.mouse) do continue
		bar_list(app, which).slots[i] = s
		sh.drops += 1
		report(app, nil, {}, "The %s shelf now has %s", SHELF_PAGE_NAMES[sh.page], shelf_label(s))
		return
	}
}

// What a brush does, drawn small: a stroke laid on a strip of clay, shaded light above and
// dark below, its path and width by the brush (an arc for Draw, a wide one for Inflate, a
// narrow groove for Crease, a hook for Grab), as Procreate's library shows each brush's
// stroke. A tool or a mask shape shows its icon on the strip.
lens_stroke_preview :: proc(ctx: ^ui.Context, r: ui.Rect, it: Brush_Item, app: ^App) {
	t := ctx.theme
	CLAY :: ui.Color{184, 148, 130, 255}
	ui.fill_rect(ctx, r, t.radius_small, CLAY)
	if it.what != .Slot {
		ui.icon(ctx, brush_item_icon(it), {r.x + r.w * 0.5, r.y + r.h * 0.5}, min(r.h * 0.5, 26), {90, 62, 50, 255})
		return
	}
	kind := it.slot.kind
	Shape :: enum {Arc, Wave, Flat, Vee, Hook, Ripple}
	shape := Shape.Wave
	width: f32 = 0.2
	body := ui.Color{231, 201, 184, 255}
	#partial switch kind {
	case .Draw, .Morph, .History: shape, width = .Arc, 0.2
	case .Inflate:                shape, width = .Arc, 0.34
	case .Smooth:                 shape, width = .Flat, 0.28
	case .Flatten, .Layer:        shape, width = .Flat, 0.22
	case .Pinch:                  shape, width = .Vee, 0.09
	case .Crease:                 shape, width = .Vee, 0.07
	case .Grab, .Snake_Hook:      shape, width = .Hook, 0.18
	case .Cloth:                  shape, width = .Ripple, 0.14
	case .Mask:                   body = {58, 63, 71, 255}
	case .Paint:
		c := color_bytes(app.brush.color)
		body = {c.r, c.g, c.b, 255}
	}
	N :: 24
	pts: [N + 1][2]f32
	w := r.h * width
	for i in 0 ..= N {
		f := f32(i) / N
		x := r.x + r.w * (0.1 + 0.8 * f)
		y: f32
		switch shape {
		case .Arc:    y = -math.sin(f * math.PI) * 0.22
		case .Wave:   y = -math.sin(f * math.PI) * 0.12 + math.sin(f * math.PI * 3) * 0.05
		case .Flat:   y = 0
		case .Vee:    y = -(0.5 - abs(f - 0.5)) * 0.3
		case .Hook:   y = 0.2 - f * f * 0.45
		case .Ripple: y = math.sin(f * math.PI * 4) * 0.08
		}
		pts[i] = {x, r.y + r.h * (0.55 + y)}
	}
	shadow := ui.Color{122, 90, 76, 255}
	light := ui.Color{251, 233, 223, 200}
	lift :: proc(p: [N + 1][2]f32, by: f32) -> (out: [N + 1][2]f32) {
		for q, i in p do out[i] = q + {0, by}
		return
	}
	if kind == .Crease || kind == .Pinch {
		// A groove: dark in the middle with a lit lip above it.
		dark := lift(pts, 0)
		ui.polyline(ctx, dark[:], {91, 62, 51, 255}, w)
		lip := lift(pts, -w)
		ui.polyline(ctx, lip[:], light, w * 0.4)
		return
	}
	under := lift(pts, w * 0.3)
	ui.polyline(ctx, under[:], shadow, w)
	ui.polyline(ctx, pts[:], body, w)
	if kind != .Mask && kind != .Paint {
		top := lift(pts, -w * 0.3)
		ui.polyline(ctx, top[:], light, w * 0.35)
	}
}
