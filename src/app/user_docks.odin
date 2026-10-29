package main

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

import "../ui"

// The person's own docks (round 3's docks, PR 3d): up to four columns of any commands and
// brush values a bar may hold, made in Arrange's Library > Docks, each shown as Icons (the
// rail's buttons) or Tiles (an icon over its name, as the shelf's brushes are). A dock is a
// bar list (Bar_Which.Dock_1 + i) with a place (Place_Bar.Dock_1 + i), so customising its
// buttons, carrying it by its tag to an edge or floating it, and the layout lines are the
// rail's and the island's. Docks belong to the screen, as the rail's buttons do: each space
// and workspace keeps its own, and the built-in workspaces have none.

USER_DOCKS :: 4

Dock_Density :: enum u8 {
	Icons,
	Tiles,
}

@(rodata)
DOCK_DENSITY_NAMES := [Dock_Density]string{.Icons = "Icons", .Tiles = "Tiles"}

@(rodata)
USER_DOCK_NAMES := [USER_DOCKS]string{"Dock 1", "Dock 2", "Dock 3", "Dock 4"}

// One of the person's docks: whether it is in use, how its buttons show, and its buttons.
User_Dock :: struct {
	used:    bool,
	density: Dock_Density,
	list:    Bar_List,
}

// The size a new dock's outline is taken to have, for where it first floats.
@(private = "file")
DOCK_NEW_SIZE :: [2]f32{52, 120}

// Which dock bar `which` is, if it is one.
user_dock_of :: proc(which: Bar_Which) -> (int, bool) {
	i := int(which) - int(Bar_Which.Dock_1)
	return i, i >= 0 && i < USER_DOCKS
}

user_dock_which :: proc(i: int) -> Bar_Which {
	return Bar_Which(int(Bar_Which.Dock_1) + i)
}

user_dock_place :: proc(i: int) -> Place_Bar {
	return Place_Bar(int(Place_Bar.Dock_1) + i)
}

user_dock_zone :: proc(i: int) -> Arrange_Zone {
	return Arrange_Zone(int(Arrange_Zone.Dock_1) + i)
}

// Whether dock `i` is drawn: in use, and holding a button or being arranged (where its +
// is); Focus mode and Inspect put it away with the rest of the view's chrome.
user_dock_shown :: proc(k: ^Kit_State, i: int) -> bool {
	d := &k.docks[i]
	if !d.used do return false
	return k.bars_edit || (d.list.count > 0 && !k.focus_mode && !k.inspect.on)
}

// Where a new dock floats: its outline's top-left at the safe area's middle, in layout
// terms, whole points.
user_dock_middle :: proc(k: ^Kit_State) -> [2]f32 {
	area := ui.safe_area(&k.ctx)
	size := DOCK_NEW_SIZE
	return {math.round(max(area.w * 0.5 - size.x * 0.5, 0)), math.round(max(area.h * 0.5 - size.y * 0.5, TOP_BAR_H + 6))}
}

// Where a new dock floats: the middle, or beside the Library where the Library would
// cover it, on the side away from the off-hand (layout terms).
@(private = "file")
user_dock_spot :: proc(k: ^Kit_State) -> [2]f32 {
	at := user_dock_middle(k)
	// Asked from inside the Library, where New dock is.
	lib := ui.prev_root_rect(&k.ctx, "arrange library")
	if !k.bars_edit || k.arrange.library_off || lib.w <= 0 do return at
	area := ui.safe_area(&k.ctx)
	size := DOCK_NEW_SIZE
	// The Library's far edge from the start side, in layout terms.
	far := lib.x + lib.w - area.x
	if k.ctx.mirror do far = area.x + area.w - lib.x
	if at.x < far + 24 do at.x = math.round(min(far + 24, max(area.w - size.x - LENS_EDGE, 0)))
	return at
}

// How many docks are in use.
user_docks_used :: proc(k: ^Kit_State) -> int {
	n := 0
	for d in k.docks do if d.used do n += 1
	return n
}

// Makes the first free dock: floating in the middle (beside the Library), empty but for its +, picked for
// Reset zone. Opens Arrange first, as only Arrange fills it. False when all four are in use.
user_dock_new :: proc(app: ^App) -> bool {
	k := &app.kit
	for &d, i in k.docks {
		if d.used do continue
		d = {used = true, list = bar_fresh(user_dock_which(i))}
		k.places[user_dock_place(i)] = {edge = .Float, at = user_dock_spot(k)}
		k.dock_scroll[i] = 0
		if !k.bars_edit do command_run(app, .Customise_Bars)
		k.arrange.picked = user_dock_zone(i)
		k.arrange.docks_made += 1
		report(app, nil, {}, "Made %s: its + adds a button, and its tag carries it to an edge", USER_DOCK_NAMES[i])
		return true
	}
	report(app, nil, {.Warning}, "There are %d docks at most: delete one first", USER_DOCKS)
	return false
}

// Takes dock `i` away, its buttons and place with it.
user_dock_delete :: proc(app: ^App, i: int) {
	k := &app.kit
	d := &k.docks[i]
	if !d.used do return
	count := d.list.count
	d^ = {}
	k.places[user_dock_place(i)] = {}
	if z, ok := k.arrange.picked.?; ok && z == user_dock_zone(i) do k.arrange.picked = nil
	if b, ok := k.arrange.carry.?; ok && b == user_dock_place(i) do k.arrange.carry, k.arrange.carrying = nil, false
	if k.bar_slot.open && k.bar_slot.which == user_dock_which(i) do k.bar_slot.open = false
	k.arrange.docks_deleted += 1
	report(app, nil, {}, "Deleted %s (%d button%s)", USER_DOCK_NAMES[i], count, "" if count == 1 else "s")
}

// Takes every dock away, as a fresh layout has none.
user_docks_clear :: proc(k: ^Kit_State) {
	k.docks = {}
	for i in 0 ..< USER_DOCKS do k.places[user_dock_place(i)] = {}
}

// The layout's dock lines, `user_dock <n> <density>`, one for each dock in use; its
// buttons and place are written as every bar's are.
user_docks_save :: proc(k: ^Kit_State, out: ^strings.Builder) {
	for d, i in k.docks do if d.used do fmt.sbprintfln(out, "user_dock %d %v", i + 1, d.density)
}

// Reads a `user_dock <n> <density>` line; a number or density this version does not know
// is passed over.
user_dock_read :: proc(k: ^Kit_State, f: []string) {
	if len(f) != 3 do return
	n, ok := strconv.parse_int(f[1])
	if !ok || n < 1 || n > USER_DOCKS do return
	for name, density in DOCK_DENSITY_NAMES do if name == f[2] {
		k.docks[n - 1].used, k.docks[n - 1].density = true, density
	}
}

// After a layout is put: a dock in use with no place floats in the middle, as a new one
// does, so it never stands at a Default that names no edge.
user_docks_settle :: proc(k: ^Kit_State) {
	for d, i in k.docks do if d.used && k.places[user_dock_place(i)].edge == .Default {
		k.places[user_dock_place(i)] = {edge = .Float, at = user_dock_middle(k)}
	}
}

// The docks for the exit stats: `1:icons:3,2:tiles:0` (number, density, buttons), or none.
user_docks_text :: proc(k: ^Kit_State) -> string {
	out := strings.builder_make(context.temp_allocator)
	for d, i in k.docks {
		if !d.used do continue
		if strings.builder_len(out) > 0 do strings.write_byte(&out, ',')
		fmt.sbprintf(&out, "%d:%s:%d", i + 1, strings.to_lower(DOCK_DENSITY_NAMES[d.density], context.temp_allocator), d.list.count)
	}
	if strings.builder_len(out) == 0 do return "none"
	return strings.to_string(out)
}

// Every dock shown, each a column where its place says, scrolling where the column has
// less room than its buttons.
kit_user_docks :: proc(app: ^App) {
	k := &app.kit
	for i in 0 ..< USER_DOCKS do if user_dock_shown(k, i) do kit_user_dock(app, i)
}

@(private = "file")
kit_user_dock :: proc(app: ^App, i: int) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	d := &k.docks[i]
	which := user_dock_which(i)
	root := PLACE_BAR_ROOTS[user_dock_place(i)]
	size, _ := ui.prev_layout(ctx, root)
	x, y, offset, room := bar_place_anchor(app, user_dock_place(i), size)
	ui.begin_anchored(ctx, root, x, y, offset, {direction = .Column, padding = 3, radius = t.radius_large, background = .Panel, center = true})
	tile := d.density == .Tiles
	cell := ui.BRUSH_TILE.x if tile else t.target
	used := bar_used(app, which)
	step := ui.BRUSH_TILE.y if tile else t.target
	scroll := kit_scroll_begin(ctx, fmt.tprintf("%s body", root), &k.dock_scroll[i], ui.id_of(ctx, root), cell, max(room - 12, step * 2), 0)
	for s, slot in used do bar_slot_button(app, which, slot, s, tile = tile)
	if k.bars_edit do bar_add_button(app, which, len(used), cell)
	kit_scroll_end(ctx, scroll)
	ui.end(ctx)
}

// Library > Docks: each dock in use with how its buttons show and Delete, then New dock.
library_docks :: proc(app: ^App, width: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	ui.caption(ctx, fmt.tprintf("YOUR DOCKS  %d OF %d", user_docks_used(k), USER_DOCKS))
	for &d, i in k.docks {
		if !d.used do continue
		ui.begin(ctx, fmt.tprintf("library dock %d", i), {direction = .Row, gap = 8, center = true, width = width})
		r := ui.place(ctx, {width - 2 * 76 - t.target - 24, t.target})
		ui.text(ctx, fmt.tprintf("%s · %d", USER_DOCK_NAMES[i], d.list.count), r.x, r.y + r.h * 0.5, t.text_size, t.text)
		names := [len(Dock_Density)]string{"Icons", "Tiles"}
		if picked := ui.tabs(ctx, fmt.tprintf("Buttons show##dock %d", i), names[:], int(d.density), 76); picked >= 0 do d.density = Dock_Density(picked)
		if ui.icon_button(ctx, fmt.tprintf("Delete %s##library dock", USER_DOCK_NAMES[i]), ui.ICON_TRASH) do user_dock_delete(app, i)
		ui.end(ctx)
	}
	_ = command_button(app, .New_Dock, label = "New dock", variant = .Bordered, width = width)
	ui.paragraph(ctx, "A dock is a column of any commands and brush values, as the rail is. Its + adds one from Search, a tap on a button moves or removes it, and its tag in the view carries it to the left or right edge or anywhere. Each workspace keeps its own docks.")
}
