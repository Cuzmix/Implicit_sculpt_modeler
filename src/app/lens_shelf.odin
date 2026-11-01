package main

import "core:fmt"
import "core:math"
import "core:strings"

import "../poly"
import "../sculpt"
import "../ui"

// The Lens shelf (round 2 of the mockups): a floating strip at the bottom centre, All at
// its off-hand end and after a divider the page's tiles, any brush or command the person
// put there (Remesh and Dynamic topology are tiles like the brushes), and under it the
// names of its pages (Brushes, Paint, Move, Curve in Sculpt; Model in Model; Render in Render; then the pages
// the person added in that space: shelf_pages), which replace the old mode switch: each page is
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
	Render,
	// The pages the person adds (New page in a page name's menu), each to the space it was
	// added in, up to six, after the built-in ones.
	Extra_1,
	Extra_2,
	Extra_3,
	Extra_4,
	Extra_5,
	Extra_6,
}

// The first of the pages the person adds.
SHELF_EXTRA_FIRST :: Shelf_Page.Extra_1

@(rodata)
SHELF_PAGE_NAMES := [Shelf_Page]string {
	.Sculpt = "Brushes",
	.Paint  = "Paint",
	.Move   = "Move",
	.Curve  = "Curve",
	.Model  = "Model",
	.Render = "Render",
	.Extra_1 = "Page",
	.Extra_2 = "Page",
	.Extra_3 = "Page",
	.Extra_4 = "Page",
	.Extra_5 = "Page",
	.Extra_6 = "Page",
}

// The most tiles a page holds, and how many full-width tiles' room a tablet-shaped window
// gives the page's row, so the shelf ends before the pen hand's palm (which holds twelve
// at SHELF_TILE_MIN; Settings > Bars > Keep the shelf clear of the palm off gives it the
// window's width). A desktop's window shows them all.
SHELF_MAX :: 24
SHELF_TABLET :: 8
// The narrowest a tile gets: a page with more tiles than fit at full width narrows them,
// down to this, before any is left out, so a tile added in Arrange is never added out of
// sight. Wide enough for the icon and a cut name, and still a finger's target.
SHELF_TILE_MIN :: 42
// How many tiles the focused shelf shows (screen focus2): seven brushes, then All.
SHELF_FOCUS :: 7

// A fresh install's pages: the brushes most reached for, with Remesh and Dynamic topology,
// which the shelf's fixed tools held before every tile became the person's; painting and
// its colours; what moves the surface; the curve and insert tools.
SHELF_SCULPT :: [?]Bar_Slot {
	{.Brush, int(sculpt.Brush_Kind.Clay)}, {.Brush, int(sculpt.Brush_Kind.Draw)}, {.Brush, int(sculpt.Brush_Kind.Smooth)},
	{.Brush, int(sculpt.Brush_Kind.Inflate)}, {.Brush, int(sculpt.Brush_Kind.Pinch)}, {.Brush, int(sculpt.Brush_Kind.Crease)},
	{.Brush, int(sculpt.Brush_Kind.Grab)}, {.Brush, int(sculpt.Brush_Kind.Flatten)}, {.Brush, int(sculpt.Brush_Kind.Mask)},
	{.Brush, int(sculpt.Brush_Kind.Layer)}, {.Remesh, 0}, {.Dyntopo_Toggle, 0},
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
// Render mode: the two renders, Material Preview and Solid, the sections a render is set up in (each
// opens beside its tile), the exposure to scrub, focus, and the ways a render leaves the
// app. A brush picked from All goes back to Sculpt, as the space follows the tool.
SHELF_RENDER :: [?]Bar_Slot {
	{.Studio_Render, 0}, {.Render_Mode, 0}, {.Shading_Mode, int(Shading_Mode.Material_Preview)}, {.Shading_Mode, int(Shading_Mode.Solid)},
	{.Show_Section, int(Kit_Section.Material)}, {.Show_Section, int(Kit_Section.Lights)}, {.Show_Section, int(Kit_Section.Environment)},
	{.Brush_Value, int(Brush_Value.Exposure)}, {.Pick_Focus, 0}, {.Screenshot, 0}, {.Record_Turntable, 0}, {.Render_Preview, 0},
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
	tile_w:   f32, // how wide they were (SHELF_TILE_MIN to a full tile)
	// How many tiles the page shown has room for, at the narrowest, as last laid out: a
	// page that has as many takes no more (bar_insert), since a new one would not show.
	fits:     int,
	row:      ui.Rect, // where the brushes' row was laid out last frame
	slide:    f32, // how far the page just turned still slides in, points (eases to 0)
	wheel:    f32, // the mouse wheel over the shelf, until it adds up to a page
	// For the exit stats: cards dropped on a tile, pages turned, and of those the ones a
	// swipe or the wheel turned.
	drops:    int,
	turns:    int,
	swipes:   int,
	active:   bool, // the brush held visited the shelf (shelf_active_item)
	// A brush being pinned to a full page, waiting for the tile it replaces, and how many
	// pins were made, for the exit stats.
	pinning:  Maybe(Bar_Slot),
	pins:     int,
	// The pages' own names (empty for the one each comes with), the added pages in use and
	// the space each was added in.
	names:    [Shelf_Page][NAME_BYTES]u8,
	extras:   bit_set[Shelf_Page],
	extra_in: [Shelf_Page]Space,
	// The menu a long press or a right click on a page's name opens, the page it is for,
	// and whether it is asking before Delete page.
	menu:     bool,
	menu_page: Shelf_Page,
	menu_at:  ui.Rect,
	deleting: bool,
	added:    int, // pages added, for the exit stats
}

// The pages space `s` shows, first to last: its own built-in ones (Sculpt's four, Model's
// and Render's one), then those added in it, in the order they were added to the slots.
shelf_pages :: proc(k: ^Kit_State, s: Space) -> []Shelf_Page {
	out := make([dynamic]Shelf_Page, 0, len(Shelf_Page), context.temp_allocator)
	for p in Shelf_Page do if shelf_page_used(k, p) && shelf_page_space(k, p) == s do append(&out, p)
	return out[:]
}

// The page a space opens on in a fresh install: its first built-in one.
shelf_first_page :: proc(s: Space) -> Shelf_Page {
	switch s {
	case .Sculpt: return .Sculpt
	case .Model:  return .Model
	case .Render: return .Render
	}
	return .Sculpt
}

// Whether page `p` is in use: every built-in one is, an added one until it is deleted.
shelf_page_used :: proc(k: ^Kit_State, p: Shelf_Page) -> bool {
	return p < SHELF_EXTRA_FIRST || p in k.shelf.extras
}

// The space page `p` belongs to.
shelf_page_space :: proc(k: ^Kit_State, p: Shelf_Page) -> Space {
	if p >= SHELF_EXTRA_FIRST do return k.shelf.extra_in[p]
	#partial switch p {
	case .Model:  return .Model
	case .Render: return .Render
	}
	return .Sculpt
}

// What page `p` is called: the name it was given, else the one it comes with.
shelf_page_name :: proc(k: ^Kit_State, p: Shelf_Page) -> string {
	if name := rename_text(k.shelf.names[p][:]); name != "" do return name
	return SHELF_PAGE_NAMES[p]
}

// Where page `p` is among `pages`; 0 when it is not there.
@(private = "file")
shelf_page_index :: proc(pages: []Shelf_Page, p: Shelf_Page) -> int {
	for q, i in pages do if q == p do return i
	return 0
}

// Names page `p` (an empty name leaves it as it is).
shelf_page_rename :: proc(k: ^Kit_State, p: Shelf_Page, name: string) {
	trimmed := strings.trim_space(name)
	if trimmed == "" || !shelf_page_used(k, p) do return
	k.shelf.names[p] = {}
	copy(k.shelf.names[p][:NAME_BYTES - 1], trimmed)
}

// Adds an empty page to the end of space `s`'s pages, named "Page N" by where it stands
// among them, and returns it; false when all six added pages are in use.
shelf_page_add :: proc(k: ^Kit_State, s: Space) -> (Shelf_Page, bool) {
	for p in SHELF_EXTRA_FIRST ..= Shelf_Page.Extra_6 {
		if p in k.shelf.extras do continue
		n := len(shelf_pages(k, s)) + 1
		k.shelf.extras += {p}
		k.shelf.extra_in[p] = s
		k.shelf.lists[p] = shelf_fresh(p)
		k.shelf.names[p] = {}
		copy(k.shelf.names[p][:NAME_BYTES - 1], fmt.tprintf("Page %d", n))
		k.shelf.added += 1
		return p, true
	}
	return {}, false
}

// Deletes added page `p` with its tiles; a built-in page stays. A space left on it goes
// back to its first page.
shelf_page_delete :: proc(k: ^Kit_State, p: Shelf_Page) {
	if p < SHELF_EXTRA_FIRST || p not_in k.shelf.extras do return
	s := k.shelf.extra_in[p]
	k.shelf.extras -= {p}
	k.shelf.lists[p] = shelf_fresh(p)
	k.shelf.names[p] = {}
	if k.spaces.page[s] == p do k.spaces.page[s] = shelf_first_page(s)
	if k.shelf.page == p do k.shelf.page = shelf_first_page(s)
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
	case .Render:
		d := SHELF_RENDER
		return bar_list_of(d[:])
	case .Extra_1, .Extra_2, .Extra_3, .Extra_4, .Extra_5, .Extra_6:
		// An added page starts empty, for the person to fill.
	}
	return {}
}

// Puts every page back as a fresh install has it: the built-in ones with their own tiles
// and names, and no added ones.
shelf_reset :: proc(k: ^Kit_State) {
	for p in Shelf_Page do k.shelf.lists[p] = shelf_fresh(p)
	k.shelf.names, k.shelf.extras, k.shelf.extra_in = {}, {}, {}
}

// The settings lines of the pages: `shelf_extra <zone> <space>` for each added page in
// use, and `shelf_page_name <zone> <name, escaped>` for each page with a name of its own,
// by the zone of the bar that holds it (BAR_ZONES). Their tiles are the bars' lines.
shelf_pages_save :: proc(k: ^Kit_State, out: ^strings.Builder) {
	for p in Shelf_Page {
		if !shelf_page_used(k, p) do continue
		zone := BAR_ZONES[shelf_which(p)]
		if p >= SHELF_EXTRA_FIRST do fmt.sbprintfln(out, "shelf_extra %s %v", zone, k.shelf.extra_in[p])
		if name := rename_text(k.shelf.names[p][:]); name != "" do fmt.sbprintfln(out, "shelf_page_name %s %s", zone, preset_escape(name))
	}
}

// Reads a shelf_extra or shelf_page_name line (`f` split by spaces), as shelf_pages_save
// writes them; one naming no page or space is passed over.
shelf_pages_load_line :: proc(k: ^Kit_State, f: []string) {
	if len(f) != 3 do return
	which, ok := bar_zone(f[1])
	if !ok do return
	p, page := shelf_page_of(which)
	if !page do return
	switch f[0] {
	case "shelf_extra":
		if p < SHELF_EXTRA_FIRST do return
		for s in Space do if fmt.tprint(s) == f[2] {
			k.shelf.extras += {p}
			k.shelf.extra_in[p] = s
		}
	case "shelf_page_name":
		k.shelf.names[p] = {}
		copy(k.shelf.names[p][:NAME_BYTES - 1], preset_unescape(f[2]))
	}
}

// The picker's item as a shelf slot: a plain brush, a preset (the library's, the person's
// own or a pack's), a tool's command, or a mask or hide shape. Everything the picker
// shows can go on the shelf.
shelf_slot_of :: proc(it: Brush_Item) -> (Bar_Slot, bool) {
	switch it.what {
	case .Slot:
		if it.slot.command.id != .None do return it.slot.command, true
		if it.slot.preset == 0 do return {.Brush, int(it.slot.kind)}, true
		if arg, ok := preset_slot_of(it.slot.preset); ok do return {.Brush_Preset, arg}, true
	case .Tool:       return {TOOL_COMMANDS[it.tool], 0}, true
	case .Mask_Shape: return {.Mask_Shape_Pick, int(it.mask)}, true
	case .Gesture:    return {.Hide_Gesture_Pick, int(it.gesture)}, true
	}
	return {}, false
}

// Whether command `id` is one of the brush picker's own: a brush, a preset, a mask or hide
// shape, which Search pins to the shelf and finds in the picker.
shelf_holds_brushes :: proc(id: Command_Id) -> bool {
	return id == .Brush || id == .Brush_Preset || id == .Mask_Shape_Pick || id == .Hide_Gesture_Pick
}

// A tile's name: a brush's own ("Clay", as the tiles are all brushes or tools), else the
// bar's name for the command.
shelf_label :: proc(app: ^App, s: Bar_Slot) -> string {
	if s.id == .Brush && s.arg >= 0 && s.arg < len(sculpt.Brush_Kind) do return BRUSHES[sculpt.Brush_Kind(s.arg)].name
	// Names too long for a tile get a short one there; the full name stays in Search, the
	// card and the action bar.
	#partial switch s.id {
	case .Dyntopo_Toggle: return "Dyntopo"
	case .Model_Action:
		#partial switch Model_Action(s.arg) {
		case .Insert_Loop:  return "Add loop"
		case .Remove_Loop:  return "Cut loop"
		}
	}
	return bar_label(app, s)
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
// The fewest tools a page's tiles give up the tools' room for, once the tiles are at their
// narrowest: a page's own tiles are what was put there, the tools are on every page.
SHELF_LEAST_TOOLS :: 2

// How wide the shelf is with `brushes` tiles, All, and `tools` buttons after a divider;
// `adding` counts the + tiles Arrange puts at the end of each.
shelf_width :: proc(brushes, tools: int, adding := false, tile: f32 = ui.BRUSH_TILE.x) -> f32 {
	w := f32(brushes + int(adding)) * tile + ui.BRUSH_TILE.x + 2 * SHELF_PAD
	if tools > 0 || adding do w += 9 + f32(tools + int(adding)) * MESH_TOOL
	return w
}

// How many of the page's `brushes` and of the `tools` fit across `room` points with tiles
// `tile` wide: what does not fit is still in All and in Search.
shelf_fit :: proc(brushes, tools: int, room: f32, adding := false, tile: f32 = ui.BRUSH_TILE.x) -> (shown_brushes, shown_tools: int) {
	b, t := brushes, tools
	for b > min(brushes, SHELF_KEEP_BRUSHES) && shelf_width(b, t, adding, tile) > room do b -= 1
	for t > min(tools, SHELF_KEEP_TOOLS) && shelf_width(b, t, adding, tile) > room do t -= 1
	for b > min(brushes, SHELF_LEAST_BRUSHES) && shelf_width(b, t, adding, tile) > room do b -= 1
	for t > 0 && shelf_width(b, t, adding, tile) > room do t -= 1
	// The room the tools gave up last takes back as many tiles as it holds.
	for b < brushes && shelf_width(b + 1, t, adding, tile) <= room do b += 1
	return b, t
}

// How many of the page's `brushes` and of the `tools` show across `room`, and how wide the
// tiles are. Every tile shows while it can: at full width with the tools down to
// SHELF_KEEP_TOOLS if need be, else narrower, down to SHELF_TILE_MIN and there with the
// tools down to SHELF_LEAST_TOOLS; only then are tiles left out, as shelf_fit leaves them. With `row` above 0 (a tablet-shaped window,
// SHELF_TABLET tiles' room) the tiles' row is no wider than that either.
shelf_layout :: proc(brushes, tools: int, room: f32, adding: bool, row: f32 = 0) -> (shown_brushes, shown_tools: int, tile: f32) {
	for tile = ui.BRUSH_TILE.x; ; tile = max(tile - 2, SHELF_TILE_MIN) {
		t := tools
		least := SHELF_LEAST_TOOLS if tile <= SHELF_TILE_MIN else SHELF_KEEP_TOOLS
		for t > min(tools, least) && shelf_width(brushes, t, adding, tile) > room do t -= 1
		fits := shelf_width(brushes, t, adding, tile) <= room && (row <= 0 || f32(brushes + int(adding)) * tile <= row)
		if fits do return brushes, t, tile
		if tile <= SHELF_TILE_MIN do break
	}
	shown_brushes, shown_tools = shelf_fit(brushes, tools, room, adding, tile)
	if row > 0 do shown_brushes = min(shown_brushes, max(int(row / tile) - int(adding), 0))
	return
}

// The shelf at the bottom centre (left of it on a tablet-shaped window, clear of the palm),
// with the page names under it: the page's brushes, All, then the tools. Returns where the
// picker opens over: the shelf.
kit_shelf :: proc(app: ^App) -> (sheet_anchor: ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	sh := &k.shelf
	pages := shelf_pages(k, k.spaces.current)
	if !shelf_page_used(k, sh.page) || shelf_page_space(k, sh.page) != k.spaces.current do sh.page = pages[0]
	which := shelf_which(sh.page)
	used := bar_used(app, which)
	n := len(used)
	// On a tablet-shaped window the tiles' row keeps to SHELF_TABLET full tiles' width.
	palm := lens_palm(app) > 0 && k.shelf_palm
	row: f32 = SHELF_TABLET * ui.BRUSH_TILE.x if palm else 0
	area := ui.safe_area(ctx)
	shift: f32 = 0
	if palm do shift = -area.w * 0.09
	// Between the dial's reach and as much on the other side, of the window or, with panes
	// beside the main one, of the main pane, under which the shelf then stands, as the
	// off-hand set stays with it.
	span := area
	// The main pane's own rect, so the shelf stays put while a view pane is worked in.
	if g := &k.grid; grid_panes(g) > 1 && g.maximised == 0 && g.home.w > 0 {
		span = g.home
		shift = g.home.x + g.home.w * 0.5 - (area.x + area.w * 0.5)
	}
	if ctx.mirror do shift = -shift
	centre := area.x + area.w * 0.5 + shift
	room := 2 * max(min(centre - span.x, span.x + span.w - centre) - SHELF_SIDE_ROOM, 0) - SHELF_DIVIDER_W
	// Moved in Arrange (bar_place.odin), it stands where its place says, with that room;
	// its page names stay under it.
	place_x, place_y := ui.Anchor.Center, ui.Anchor.End
	place_at := [2]f32{shift, t.edge + dock_lift(app)}
	pages_x, pages_y := ui.Anchor.Center, ui.Anchor.End
	pages_at := [2]f32{shift, max(t.edge - 10, 2)}
	if k.places[.Shelf].edge != .Default {
		size, _ := ui.prev_layout(ctx, "dock")
		pages, _ := ui.prev_layout(ctx, "dock pages")
		place_x, place_y, place_at, room = bar_place_anchor(app, .Shelf, size)
		room -= 2 * SHELF_PAD
		pages_x = .Start
		pages_at.x = place_at.x + size.x * 0.5 - pages.x * 0.5
		if place_y == .Start do pages_y, pages_at.y = .Start, place_at.y + size.y + 2
	}
	// Focused, the shelf is All and the tiles most reached for, without the page names.
	focus := lens_focus(k)
	if focus do n = min(n, SHELF_FOCUS)
	// The Add tile shows while arranging, and on an empty page (one just added) always, so
	// the page says what it is for and a tap fills it.
	adding := (k.bars_edit || n == 0) && !focus
	tile: f32
	n, _, tile = shelf_layout(n, 0, room, adding, row)
	// A brush picked from All, Search or the pie that is not among the tiles shown visits
	// the shelf as the first tile after All, so what the pen holds is always in sight; the
	// shelf grows toward the off-hand side for it, so the tiles under the pen hand stay put.
	active, active_on := shelf_active_item(app, used[:n], k.bars_edit)
	if active_on {
		room = max(room - ui.BRUSH_TILE.x, 0)
		n, _, tile = shelf_layout(len(used) if !focus else min(len(used), SHELF_FOCUS), 0, room, adding, row)
		if k.places[.Shelf].edge == .Default {
			// Left-handed, begin_anchored turns the offset round, so it grows right then.
			off := ui.BRUSH_TILE.x * 0.5
			place_at.x -= off
			pages_at.x -= off
		}
	}

	if !focus do lens_shelf_pages(app, pages_x, pages_y, pages_at)
	// A sideways drag that starts on any of the shelf's buttons turns the page: the shelf
	// is drag-scrolled, so a finger or a pen pressed on a tile waits to see which way it
	// goes (ui.swipe_update), and only the brushes, the page's own, slide.
	shelf_id := ui.id_of(ctx, "dock")
	shelf_at := ui.prev_rect(ctx, "dock")
	offset, turn := ui.swipe_update(ctx, shelf_id, shelf_at)
	shelf_wheel(app, shelf_at, &turn)
	if turn != 0 && shelf_turn(app, turn) do sh.swipes += 1
	// Past the first or the last page the row gives a little, as a scroll view's edge does.
	if (offset > 0 && sh.page == pages[0]) || (offset < 0 && sh.page == pages[len(pages) - 1]) do offset *= 0.3
	slide := offset + sh.slide
	// Pinning to a full page waits for a tile; Escape, the system taking the pointer back, a
	// press clear of the shelf or a page turned (shelf_turn) gives it up.
	if sh.pinning != nil {
		in_ := ctx.input
		outside := .Left in in_.pressed && shelf_at.w > 0 && !ui.rect_contains(shelf_at, in_.mouse)
		if key_pressed(&app.device, KEY_ESCAPE) || in_.cancel || outside {
			sh.pinning = nil
			report(app, nil, {}, "Pin to shelf cancelled")
		}
	}
	ui.begin_anchored(ctx, "dock", place_x, place_y, place_at, {direction = .Row, gap = 0, padding = SHELF_PAD, radius = t.radius_large + 4, background = .Panel, center = true, drag_scroll = true})
	// All at the off-hand end beside the dial, a thumb's reach (first, or last when
	// left-handed), then the visiting tile; All is never taken off, as every page's way to
	// the rest.
	visiting: ui.Rect
	if !ctx.mirror do visiting = shelf_head(app, active, active_on, which)
	// Asked for in the shelf, as the row's id is the shelf's child.
	sh.row = ui.prev_rect(ctx, "shelf brushes")
	brushes_at := sh.row
	ui.begin(ctx, "shelf brushes", {direction = .Row, gap = 0, width = f32(n + int(adding)) * tile, height = ui.BRUSH_TILE.y, clip = true})
	mark := ui.vertex_mark(ctx)
	sh.shown, sh.tile_w = n, tile
	// What the page has room for, as many as fit at the narrowest; never fewer than it shows.
	most, _, _ := shelf_layout(SHELF_MAX, 0, room, adding, row)
	sh.fits = max(most, n)
	for s, i in used[:n] {
		// A brush value is a chip as on any bar, scrubbed up and down so a sideways
		// swipe still turns the page.
		if v, ok := value_of(s); ok {
			value_item(app, which, i, v, {tile, ui.BRUSH_TILE.y}, column = false)
			sh.tiles[i] = ctx.last_rect
			continue
		}
		name := fmt.tprintf("%s##shelf %v %d", shelf_label(app, s), sh.page, i)
		if ui.brush_tile(ctx, name, bar_icon(app, s), bar_lit(app, s), command_hint(app, s.id, s.arg), width = tile) {
			if pin, pinning := sh.pinning.?; pinning {
				// Pinning to a full page: the tile tapped gives its place to the brush.
				bar_list(app, which).slots[i] = pin
				sh.pinning = nil
				report(app, nil, {}, "%s is on %s in place of %s", shelf_label(app, pin), shelf_page_name(k, sh.page), shelf_label(app, s))
				sh.pins += 1
			} else if k.bars_edit do bar_slot_open(app, which, i, ctx.last_rect)
			else do bar_slot_run(app, s, ctx.last_rect, .Above_Center)
		}
		if sh.pinning != nil do ui.stroke_rect(ctx, ctx.last_rect, t.radius_medium + 2, t.warning, 1)
		sh.tiles[i] = ctx.last_rect
		if k.bars_edit {
			bar_edit_ring(app, ctx.last_rect)
		} else if ctx.last_id != 0 && ui.secondary(ctx) {
			// A brush's long press picks it and shows its quick settings over the tile; a
			// command's does what it does on any bar.
			if s.id == .Brush || s.id == .Brush_Preset {
				command_run(app, s.id, s.arg)
				kit_floats_close(k)
				sh.quick, sh.quick_at = true, ctx.last_rect
			} else if bar_has_more(s.id) {
				bar_slot_more(app, s, ctx.last_rect, .Above_Center)
			}
		}
		// The card carried from the picker lands on the tile it is let go over.
		if sh.carry != nil && ui.rect_contains(ctx.last_rect, sh.carry_at) do ui.stroke_rect(ctx, ctx.last_rect, t.radius_medium + 2, t.accent, 2)
		bar_slot_lift(app, which, i, s)
	}
	if adding {
		if ui.brush_tile(ctx, "Add##shelf add", ui.ICON_PLUS, false, width = tile) do bar_choose(app, {which = which, slot = len(used), add = true})
		bar_spot(app, which, len(used), ctx.last_rect, end = true)
	}
	ui.end(ctx)
	// After the row ends, so the highlight under the picked tile, drawn as it ends, slides
	// with it.
	if slide != 0 {
		w := max(brushes_at.w, ui.BRUSH_TILE.x)
		ui.transform_since(ctx, mark, opacity = 1 - min(abs(slide) / w, 1) * 0.7, offset = {slide, 0}, follows = true)
	}
	if ctx.mirror do visiting = shelf_head(app, active, active_on, which)
	ui.end(ctx)
	// The visiting tile's pin, after the shelf ends so it is on top of it for the pointer.
	if active_on do shelf_visiting_pin(app, active, which, visiting)
	pen_zone(app, shelf_at, .Shelf, shelf_id)
	// The pen's roll over the shelf, where no value chip on it took the roll, turns its
	// page as a swipe does: a page for every SHELF_ROLL_PAGE degrees, clockwise the next.
	if roll := ui.area_roll(ctx, shelf_id, shelf_at, shelf_id); roll != 0 {
		if step := ui.roll_steps(ctx, roll, SHELF_ROLL_PAGE); step != 0 && shelf_turn(app, 1 if step > 0 else -1) {
			sh.swipes += 1
			haptic(app, .Alignment)
			ui.roll_hint(ctx, fmt.tprintf("Page: %s", shelf_page_name(k, sh.page)))
		}
	}
	// The page the slide is heading for comes in behind it from that side, as a home
	// screen's next page does; it only shows, so it takes no press.
	if slide != 0 && brushes_at.w > 0 do shelf_peek(app, brushes_at, slide, -1 if slide > 0 else 1)
	// The page just turned slides in the rest of the way.
	sh.slide = 0 if !ui.motion_moves(ctx, motion_class(.Pages)) || abs(sh.slide) < 0.5 else sh.slide * math.exp(-ctx.input.dt * SHELF_SLIDE_RATE)
	// The picker centres over the whole shelf, which stays in sight under it, so a card can
	// be carried down onto any tile.
	if strip := ui.prev_rect(ctx, "dock"); strip.w > 0 do sheet_anchor = strip
	sh.active = active_on
	return
}

// The room a divider takes in the shelf's row: after All.
SHELF_DIVIDER_W :: 9

// The item the visiting tile shows, and whether it shows: the brush, preset or curve tool
// held, when the shelf is not being arranged and no tile shown (`tiles`) is lit for it
// already. A tool such as Move or Model lights its own tile, so it visits none.
shelf_active_item :: proc(app: ^App, tiles: []Bar_Slot, arranging: bool) -> (it: Brush_Item, shows: bool) {
	if arranging do return
	if shelf_page_space(&app.kit, app.kit.shelf.page) != .Sculpt do return
	it = brush_item_current(app)
	if it.what == .Tool && it.tool == .Model do return
	if !brush_item_on(app, it) do return
	for s in tiles do if bar_lit(app, s) do return
	return it, true
}

// The shelf's end on the off-hand side: All, the divider and the visiting tile, if one
// visits, in that order from the off-hand edge (mirrored when left-handed). Returns where
// the visiting tile stands.
@(private = "file")
shelf_head :: proc(app: ^App, active: Brush_Item, active_on: bool, which: Bar_Which) -> (visiting: ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	all :: proc(app: ^App) {
		if ui.brush_tile(&app.kit.ctx, "All##shelf all", ui.ICON_GRID, app.kit.browser, command_hint(app, .Brush_Picker)) do brush_picker_toggle(app)
	}
	if !ctx.mirror {
		all(app)
		ui.divider(ctx, 32)
	}
	if active_on do visiting = shelf_visiting_tile(app, active, which)
	if ctx.mirror {
		ui.divider(ctx, 32)
		all(app)
	}
	return
}

// The visiting tile: the brush held that is not on the page, lit, ringed by a dashed line
// as a guest is; it returns where it stands, for its pin (shelf_visiting_pin), drawn
// once the shelf ends.
// A tap or a long press on it shows its quick settings over it, as a long press on a
// shelf tile does.
@(private = "file")
shelf_visiting_tile :: proc(app: ^App, it: Brush_Item, which: Bar_Which) -> ui.Rect {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	sh := &k.shelf
	name := fmt.tprintf("%s##shelf visiting", brush_item_name(app, it))
	tapped := ui.brush_tile(ctx, name, brush_item_icon(it), true, brush_item_hint(app, it))
	at := ctx.last_rect
	if tapped || (ctx.last_id != 0 && ui.secondary(ctx)) {
		if it.what == .Slot {
			kit_floats_close(k)
			sh.quick, sh.quick_at = true, at
		} else {
			brush_item_settings(app, it)
		}
	}
	shelf_dashed_ring(ctx, {at.x + 3, at.y + 3, at.w - 6, at.h - 6}, t.accent)
	return at
}

// The visiting tile's pin over its top corner `at` on the pen side, where the eye goes from
// the tile, that keeps the brush on page `which`.
@(private = "file")
shelf_visiting_pin :: proc(app: ^App, it: Brush_Item, which: Bar_Which, at: ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	sh := &k.shelf
	slot, pinnable := shelf_slot_of(it)
	if !pinnable do return
	r := ui.Rect{at.x + at.w - 20 if !ctx.mirror else at.x - 4, at.y - 4, 24, 24}
	ui.begin_at(ctx, "shelf visiting pin", {r.x, r.y}, {direction = .Row})
	a := ui.area(ctx, "Pin to shelf##visiting", {r.w, r.h})
	ui.fill_circle(ctx, {r.x + 12, r.y + 12}, 10, t.surface_raised)
	ui.stroke_circle(ctx, {r.x + 12, r.y + 12}, 10, t.border_strong, 1)
	ui.icon(ctx, ICON_PIN, {r.x + 12, r.y + 12}, 12, t.text if !a.hovered else t.accent)
	ui.tip(ctx, a.id, r, fmt.tprintf("Pin %s to %s", brush_item_name(app, it), shelf_page_name(k, sh.page)), "Keeps it on this page")
	if a.clicked do shelf_pin(app, slot, which)
	ui.end(ctx)
}

// A dashed outline round `r`: short strokes along each side, the visiting tile's mark.
@(private = "file")
shelf_dashed_ring :: proc(ctx: ^ui.Context, r: ui.Rect, c: ui.Color) {
	DASH :: 5
	GAP :: 4
	for x := r.x + 6; x < r.x + r.w - 6; x += DASH + GAP {
		w := min(DASH, r.x + r.w - 6 - x)
		ui.fill_rect(ctx, {x, r.y, w, 1.5}, 0, c)
		ui.fill_rect(ctx, {x, r.y + r.h - 1.5, w, 1.5}, 0, c)
	}
	for y := r.y + 6; y < r.y + r.h - 6; y += DASH + GAP {
		h := min(DASH, r.y + r.h - 6 - y)
		ui.fill_rect(ctx, {r.x, y, 1.5, h}, 0, c)
		ui.fill_rect(ctx, {r.x + r.w - 1.5, y, 1.5, h}, 0, c)
	}
}

// The Lucide pin, the visiting tile's way onto the page, and its struck-through twin for
// taking a tile off.
ICON_PIN :: rune(0xe259)
ICON_PIN_OFF :: rune(0xe2b6)

// Keeps `slot` on shelf page `which`: first after All, where it visited, so it does not
// move. A page with no room asks for the tile it replaces (the next tap on one), saying
// so; Undo on the note takes a pin back off.
shelf_pin :: proc(app: ^App, slot: Bar_Slot, which: Bar_Which) {
	k := &app.kit
	sh := &k.shelf
	page, _ := shelf_page_of(which)
	for s in bar_used(app, which) do if s == slot {
		report(app, nil, {}, "%s is already on %s", shelf_label(app, slot), shelf_page_name(k, page))
		return
	}
	count := bar_count(app, which)
	if count^ >= bar_capacity(which) || (page == sh.page && sh.fits > 0 && count^ >= sh.fits) {
		sh.pinning = slot
		report(app, nil, {}, "%s is full: tap the tile %s replaces", shelf_page_name(k, page), shelf_label(app, slot))
		return
	}
	l := bar_list(app, which)
	copy(l.slots[1:count^ + 1], l.slots[0:count^])
	copy(l.looks[1:count^ + 1], l.looks[0:count^])
	l.slots[0], l.looks[0] = slot, bar_default_look(which)
	count^ += 1
	sh.pins += 1
	k.bar_removed = {carry = {slot = slot, from = which, from_slot = 0}, serial = ui.toast(&k.ctx, fmt.tprintf("%s is on %s", shelf_label(app, slot), shelf_page_name(k, page)), .Success, "Undo"), pinned = true}
}

// Takes tile `at` off shelf page `which`, with Undo on the note, as a tile dragged off.
shelf_unpin :: proc(app: ^App, which: Bar_Which, at: int) {
	used := bar_used(app, which)
	if at < 0 || at >= len(used) do return
	bar_drop_off(app, {slot = used[at], from = which, from_slot = at, look = bar_list(app, which).looks[at]})
}

// Puts the old tools strip's tools (Bar_Which.Tools) at the end of every Sculpt page that
// lacks them, while the page has room: settings from before version 12.
shelf_tools_merge :: proc(app: ^App) {
	for page in shelf_pages(&app.kit, .Sculpt) {
		which := shelf_which(page)
		for s in bar_used(app, .Tools) {
			if _, held := shelf_holds(app, which, s); held do continue
			count := bar_count(app, which)
			if count^ >= bar_capacity(which) do break
			l := bar_list(app, which)
			l.slots[count^], l.looks[count^] = s, bar_default_look(which)
			count^ += 1
		}
	}
}

// Whether `slot` is on shelf page `which`, and where.
shelf_holds :: proc(app: ^App, which: Bar_Which, slot: Bar_Slot) -> (at: int, ok: bool) {
	for s, i in bar_used(app, which) do if s == slot do return i, true
	return
}

// Turns the shelf `by` pages among the space's (on from its last, back from its first, it
// stays), the new page's brushes sliding in from the side they come from. Returns whether
// it turned.
shelf_turn :: proc(app: ^App, by: int) -> bool {
	sh := &app.kit.shelf
	pages := shelf_pages(&app.kit, app.kit.spaces.current)
	at := shelf_page_index(pages, sh.page)
	to := pages[clamp(at + by, 0, len(pages) - 1)]
	if to == sh.page do return false
	w := sh.row.w
	sh.slide = (1 if by > 0 else -1) * w * SHELF_SLIDE_FROM
	sh.page, sh.quick, sh.pinning = to, false, nil
	sh.turns += 1
	return true
}

// The degrees of the pen's roll over the shelf that turn a page: more than a choice's
// step, since a page changes every tile under the hand.
SHELF_ROLL_PAGE :: 40

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
	pages := shelf_pages(k, k.spaces.current)
	i := shelf_page_index(pages, k.shelf.page) + page_by
	if i < 0 || i >= len(pages) do return
	page := pages[i]
	used := bar_used(app, shelf_which(page))
	ui.begin_at(ctx, "shelf peek", {at.x, at.y}, {direction = .Row, gap = 0, width = at.w, height = at.h, clip = true, inert = true})
	mark := ui.vertex_mark(ctx)
	tile := k.shelf.tile_w if k.shelf.tile_w > 0 else ui.BRUSH_TILE.x
	for s, j in used[:min(len(used), int(at.w / tile) + 1)] {
		_ = ui.brush_tile(ctx, fmt.tprintf("%s##peek %v %d", shelf_label(app, s), page, j), bar_icon(app, s), false, width = tile)
	}
	ui.end(ctx)
	ui.transform_since(ctx, mark, opacity = min(abs(slide) / at.w, 1), offset = {slide + f32(page_by) * at.w, 0}, follows = true)
}

// The page names under the shelf, each a tap away; the shelf stands over them. A long
// press or a right click on a name opens its menu (Rename, New page, Delete page), and while
// arranging a + after the names adds a page.
@(private = "file")
lens_shelf_pages :: proc(app: ^App, x, y: ui.Anchor, at: [2]f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	sh := &k.shelf
	ui.begin_anchored(ctx, "dock pages", x, y, at, {direction = .Row, gap = 2, padding = 2, radius = t.radius_large, background = .Panel, center = true})
	pages := shelf_pages(k, k.spaces.current)
	here := shelf_page_index(pages, sh.page)
	for p, i in pages {
		name := ui.text_fit(ctx, shelf_page_name(k, p), t.small_size, SHELF_PAGE_NAME_W, .Semibold)
		w := ui.text_width(ctx, name, t.small_size, .Semibold) + 26
		// By the page, not its name, so a renamed page keeps its press.
		a := ui.area(ctx, fmt.tprintf("page %v##shelf", p), {w, 24})
		on := p == sh.page
		if a.hovered && !on do ui.fill_rect(ctx, a.rect, t.radius_medium, t.fill_hover)
		ui.fill_circle(ctx, {a.rect.x + 9, a.rect.y + a.rect.h * 0.5}, 3, t.accent if on else t.text_tertiary)
		ui.text(ctx, name, a.rect.x + 16, a.rect.y + a.rect.h * 0.5, t.small_size, t.text if on else t.text_secondary, .Semibold if on else .Regular)
		ui.tip(ctx, a.id, a.rect, shelf_page_name(k, p), "Long press or right click to rename it or add a page")
		if a.clicked && !on do shelf_turn(app, i - here)
		if ui.secondary(ctx) do shelf_page_menu_open(k, p, a.rect)
	}
	if k.bars_edit && !lens_focus(k) {
		a := ui.area(ctx, "add page##shelf", {28, 24})
		if a.hovered do ui.fill_rect(ctx, a.rect, t.radius_medium, t.fill_hover)
		ui.icon(ctx, ui.ICON_PLUS, {a.rect.x + a.rect.w * 0.5, a.rect.y + a.rect.h * 0.5}, t.icon_small - 2, t.text_secondary)
		ui.tip(ctx, a.id, a.rect, "New page", "Adds an empty page to this space's shelf")
		if a.clicked do shelf_page_new(app)
	}
	ui.end(ctx)
}

// The widest a page's name shows under the shelf; a longer one is cut.
SHELF_PAGE_NAME_W :: 120

// Opens page `p`'s menu over its name at `at`.
shelf_page_menu_open :: proc(k: ^Kit_State, p: Shelf_Page, at: ui.Rect) {
	kit_floats_close(k)
	k.shelf.menu, k.shelf.menu_page, k.shelf.menu_at, k.shelf.deleting = true, p, at, false
}

// Adds an empty page to the space's shelf and turns to it, saying so; with all six added
// pages in use it says that instead.
shelf_page_new :: proc(app: ^App) {
	k := &app.kit
	p, ok := shelf_page_add(k, k.spaces.current)
	if !ok {
		report(app, nil, {.Warning}, "The shelf has %d pages of your own already: delete one first", int(Shelf_Page.Extra_6) - int(SHELF_EXTRA_FIRST) + 1)
		return
	}
	pages := shelf_pages(k, k.spaces.current)
	_ = shelf_turn(app, shelf_page_index(pages, p) - shelf_page_index(pages, k.shelf.page))
	report(app, nil, {}, "Added %s to the shelf: put brushes on it in Arrange or from Search", shelf_page_name(k, p))
}

// A page name's menu, over it: Rename, New page, and for a page of one's own Delete page,
// which asks first when the page has tiles, as nothing undoes it; a built-in page given a
// name of its own can have its name back.
kit_shelf_page_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	sh := &k.shelf
	p := sh.menu_page
	if sh.menu && (!shelf_page_used(k, p) || shelf_page_space(k, p) != k.spaces.current) do sh.menu = false
	if !ui.popover_begin(ctx, "shelf page menu", &sh.menu, sh.menu_at, .Above_Center, {direction = .Column, gap = 0, padding = 6, width = 240}) do return
	defer ui.popover_end(ctx)
	picked := false
	name := shelf_page_name(k, p)
	if sh.deleting {
		ui.caption(ctx, fmt.tprintf("  DELETE %s?", strings.to_upper(name, context.temp_allocator)))
		ui.paragraph(ctx, fmt.tprintf("Its %d tiles go with it, for good.", sh.lists[p].count))
		yes, no := kit_button_pair(ctx, "Delete", "Keep it", tone_a = .Danger)
		if yes {
			shelf_page_delete(k, p)
			report(app, nil, {}, "Deleted the shelf's %s page", name)
			picked = true
		}
		if no do sh.deleting = false
	} else {
		ui.caption(ctx, fmt.tprintf("  %s ON THE SHELF", strings.to_upper(name, context.temp_allocator)))
		if ui.menu_item(ctx, "Rename…##shelf page") {
			k.rename = {open = true, shelf_page = int(p) + 1, at = sh.menu_at}
			sh.menu = false
		}
		_, full := shelf_page_full(k)
		if ui.menu_item(ctx, "New page##shelf page", glyph = ui.ICON_PLUS, enabled = !full, reason = "The shelf has six pages of your own already") {
			shelf_page_new(app)
			picked = true
		}
		if p < SHELF_EXTRA_FIRST && rename_text(sh.names[p][:]) != "" && ui.menu_item(ctx, fmt.tprintf("Call it %s again##shelf page", SHELF_PAGE_NAMES[p])) {
			sh.names[p] = {}
			picked = true
		}
		if p >= SHELF_EXTRA_FIRST && ui.menu_item(ctx, "Delete page##shelf page", tone = .Danger) {
			if sh.lists[p].count > 0 {
				sh.deleting = true
			} else {
				shelf_page_delete(k, p)
				report(app, nil, {}, "Deleted the shelf's %s page", name)
				picked = true
			}
		}
	}
	if picked do sh.menu = false
}

// How many added pages are in use, and whether all six are.
shelf_page_full :: proc(k: ^Kit_State) -> (used: int, full: bool) {
	used = card(k.shelf.extras)
	return used, used >= int(Shelf_Page.Extra_6) - int(SHELF_EXTRA_FIRST) + 1
}

// Opens the brush picker over the shelf, or closes it.
brush_picker_toggle :: proc(app: ^App) {
	k := &app.kit
	was := k.browser
	kit_floats_close(k)
	k.browser, k.browser_at, k.grid_scroll, k.grid_reveal = !was, .Dock, 0, true
}

// A long-pressed tile's quick settings, over it: the brush's name with its favourite star,
// Radius and Strength, its stroke kind, its alpha and the lazy mouse; Pin to the stack keeps
// the stroke's section as a card of the stack, and All settings opens the brush's.
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
	_ = ui.slider(ctx, "Size", &app.brush.radius_px, MIN_RADIUS_PX, MAX_RADIUS_PX, .Logarithmic, fmt.tprintf("%.0f px", app.brush.radius_px))
	s := brush_strength(app)
	_ = ui.slider(ctx, "Strength", s, MIN_STRENGTH, 1, .Linear, fmt.tprintf("%.2f", s^))
	if BRUSHES[kind].flags & {.Grab, .Hook, .Cloth} == {} {
		ui.caption(ctx, "STROKE")
		stroke_tabs(app, "shelf stroke kind")
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
		kit_stabiliser(app, full = false)
	}
	// A sculpting brush can lay the main colour as it goes (Paint_Toggle), Nomad's Paint
	// switch, which took the place of the shelf's own Paint tile; the Paint brushes always do.
	if channel_brush(kind) && .Paint not_in BRUSHES[kind].flags {
		painting := app.brush.channel != .Sculpt
		if ui.switch_row(ctx, "Also paint colour", &painting, keys = command_hint(app, .Paint_Toggle)) do command_run(app, .Paint_Toggle)
	}
	ui.begin(ctx, "shelf quick actions", {direction = .Row, gap = 6})
	// Pin to shelf keeps the brush on the page shown, Remove from shelf takes it off.
	if slot, ok := shelf_slot_of(cur); ok {
		which := shelf_which(sh.page)
		at, held := shelf_holds(app, which, slot)
		if ui.icon_button(ctx, "Remove from shelf##quick" if held else "Pin to shelf##quick", ICON_PIN_OFF if held else ICON_PIN, selected = held) {
			sh.quick = false
			if held do shelf_unpin(app, which, at)
			else do shelf_pin(app, slot, which)
		}
	}
	pinned := command_checked(app, .Pin_Section, int(Kit_Section.Stroke))
	if command_button(app, .Pin_Section, int(Kit_Section.Stroke), label = "Unpin from the stack" if pinned else "Pin to the stack", variant = .Bordered, glyph = ui.ICON_PANEL) do sh.quick = false
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
// press shows its settings, a swipe up or down scrolls the cards, and a drag that starts
// sideways carries a card onto a shelf tile to keep it there.
// A page tab's width on the brush sheet, and the narrowest its search field gets before
// Import gives up its label, in points.
SHEET_TAB_W :: 72
SHEET_FIELD_MIN :: 140

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
	// The head fits the sheet's width (a narrow window, an iPad held upright): the search
	// field first gives up its room down to SHEET_FIELD_MIN, then Import becomes its icon,
	// then the page tabs go to a row of their own under the head.
	GAP :: 8
	IMPORT_W :: 104
	head_w := main_w - 24
	// The space's pages, each narrowing All to what it is for.
	pages := shelf_pages(k, k.spaces.current)
	tabs_w := f32(len(pages)) * SHEET_TAB_W + 6
	import_w: f32 = IMPORT_W
	free := head_w - tabs_w - t.target - 3 * GAP
	if free - import_w < SHEET_FIELD_MIN do import_w = t.target
	wrap := free - import_w < SHEET_FIELD_MIN
	if wrap do free = head_w - t.target - 2 * GAP
	field_w := clamp(free - import_w, 0, min(300, main_w * 0.36))
	ui.begin(ctx, "brush sheet head", {direction = .Row, gap = GAP, center = true, width = head_w})
	p.searching = true
	_ = ui.text_field(ctx, "Search brushes", p.search[:], field_w, hold = p.search_focus, hint = fmt.tprintf("Search %d brushes", len(all)))
	p.search_focus = false
	names := make([]string, len(pages), context.temp_allocator)
	for p, i in pages do names[i] = ui.text_fit(ctx, shelf_page_name(k, p), t.small_size, SHEET_TAB_W - 8)
	here := shelf_page_index(pages, sh.page)
	if !wrap {
		if picked := ui.tabs(ctx, "brush sheet page", names, here, item_width = SHEET_TAB_W); picked >= 0 && picked != here do shelf_turn(app, picked - here)
	}
	ui.spacer(ctx, ui.row_room(ctx) - GAP - import_w - GAP - t.target)
	if import_w == IMPORT_W {
		_ = command_button(app, .Pick_Pack, label = "Import", variant = .Bordered, width = IMPORT_W, glyph = ui.ICON_PLUS)
	} else if ui.icon_button(ctx, "Import", ui.ICON_PLUS, keys = command_hint(app, .Pick_Pack)) {
		command_run(app, .Pick_Pack)
	}
	if ui.icon_button(ctx, "Close", ui.ICON_CLOSE, keys = "Esc") do k.browser = false
	ui.end(ctx)
	if wrap {
		if picked := ui.tabs(ctx, "brush sheet page", names, here, item_width = SHEET_TAB_W); picked >= 0 && picked != here do shelf_turn(app, picked - here)
	}
	list := brush_sheet_list(app, all[:])
	inner := main_w - 24
	card_w := (inner - f32(SHEET_COLUMNS - 1) * 10) / SHEET_COLUMNS
	CARD_H :: 110
	grid_h := room - 24 - t.target - 8 - 36
	// The tabs' own row, when they went under the head.
	if wrap do grid_h -= t.control + 8
	scroll := kit_scroll_begin(ctx, "brush sheet grid", &k.grid_scroll, owner, inner, grid_h, 10)
	pick, settings: Maybe(Brush_Item)
	for l, i in list {
		if i % SHEET_COLUMNS == 0 do ui.begin(ctx, fmt.tprintf("brush sheet row %d", i / SHEET_COLUMNS), {direction = .Row, gap = 10})
		// A card does not take the drag on the press, so a finger or a pen swiped up or down
		// over the cards scrolls the grid (drag = false); one going sideways first carries it.
		a := ui.area(ctx, fmt.tprintf("%s##sheet %s", l.name, l.key), {card_w, CARD_H}, drag = false)
		on := brush_item_on(app, l.item)
		ui.fill_rect(ctx, a.rect, t.radius_large, t.accent_soft if on else t.surface)
		if a.hovered && !on do ui.fill_rect(ctx, a.rect, t.radius_large, t.fill_hover)
		ui.stroke_rect(ctx, a.rect, t.radius_large, t.accent if on else t.border, 1)
		lens_stroke_preview(ctx, {a.rect.x + 8, a.rect.y + 8, a.rect.w - 16, 70}, l.item, app)
		name := ui.text_fit(ctx, l.name, t.small_size, a.rect.w - 40, .Semibold)
		ui.text(ctx, name, a.rect.x + 10, a.rect.y + a.rect.h - 16, t.small_size, t.accent if on else t.text, .Semibold)
		if _, fav := brush_favorite(p, l.key); fav do ui.icon(ctx, ICON_HEART, {a.rect.x + a.rect.w - 16, a.rect.y + a.rect.h - 16}, t.icon_small - 2, t.warning)
		ui.tip(ctx, a.id, a.rect, l.name, brush_item_hint(app, l.item))
		// A drag past the slop carries the card toward the shelf; it is no tap then. A finger
		// or a pen has to start it sideways (claim_drag across), as up and down scrolls the
		// grid; a mouse, which scrolls with the wheel, carries it whichever way it goes.
		if a.held && sh.carry == nil && ui.claim_drag(ctx, 0) && math.abs(ctx.input.mouse.y - ctx.press_mouse.y) + math.abs(ctx.input.mouse.x - ctx.press_mouse.x) > t.slop * 2 {
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
	ui.label(ctx, "Swipe up or down to see more. Drag a brush sideways, then onto the shelf, to keep it there. Long press for its settings.", t.small_size, t.text_secondary)
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
	// Render's page holds no brushes, so its picker lists them all, as a page of one's own
	// does, being for whatever its owner puts on it.
	if p.category != .All || brush_query(p) != "" || app.kit.shelf.page == .Render || app.kit.shelf.page >= SHELF_EXTRA_FIRST do return list
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
		label := shelf_label(app, s)
		w := ui.text_width(ctx, label, t.small_size, .Semibold) + 44
		// Above the finger, which would cover it; the tile under the finger is ringed.
		r := ui.Rect{in_.mouse.x - w * 0.5, in_.mouse.y - 64, w, 36}
		ui.begin_at(ctx, "shelf carry", {r.x, r.y}, {width = r.w, height = r.h, inert = true})
		ui.fill_rect(ctx, r, t.radius_medium, t.frame)
		ui.stroke_rect(ctx, r, t.radius_medium, t.accent, 1.5)
		ui.icon(ctx, bar_icon(app, s), {r.x + 18, r.y + r.h * 0.5}, t.icon_small, t.text)
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
		report(app, nil, {}, "The shelf's %s page now has %s", shelf_page_name(k, sh.page), shelf_label(app, s))
		return
	}
}

// What a brush does, drawn small: the picture the brush made of its own stroke
// (brush_previews.odin) when it has one; until then, and for what has none, a stroke
// sketched on a strip of clay, shaded light above and dark below, its path and width by the
// brush (an arc for Draw, a wide one for Inflate, a narrow groove for Crease, a hook for
// Grab), as Procreate's library shows each brush's stroke. A tool or a mask shape shows its
// icon on the strip.
lens_stroke_preview :: proc(ctx: ^ui.Context, r: ui.Rect, it: Brush_Item, app: ^App) {
	t := ctx.theme
	CLAY :: ui.Color{184, 148, 130, 255}
	ui.fill_rect(ctx, r, t.radius_small, CLAY)
	if it.what == .Slot && brush_preview_draw(app, brush_item_key(app, it), r) do return
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
	case .Flatten, .Layer, .Clay_Strips, .Trim_Dynamic: shape, width = .Flat, 0.22
	case .Pinch:                  shape, width = .Vee, 0.09
	case .Crease:                 shape, width = .Vee, 0.07
	case .Grab, .Snake_Hook, .Elastic: shape, width = .Hook, 0.18
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
