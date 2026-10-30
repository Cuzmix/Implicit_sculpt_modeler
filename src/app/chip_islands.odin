package main

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

import "../ui"

// The chip bar's sections as islands (the overhaul's round 3, PR 14): each of the bar's six
// sections stands in the bar, as it comes, or on its own as an island, a small floating bar
// in the docks' style holding only that section, where the person let it go in Arrange.
// The bar closes up round what is left. An island is a setting, not a layout's: the chip bar
// stands over the spaces (it holds their tabs), so it is the same in every space and
// workspace, and switching space never moves a section under the finger that tapped it. It
// is kept from the start side, as a floating dock is, so the kit's mirror flips it for a
// left hand.

Chip_Section :: enum u8 {
	Menu, // the menu and the file with whether it is saved
	Undo, // Undo and Redo
	Spaces, // the space tabs
	Object, // the object chip
	Search, // the Search field
	End, // History and Settings
}

// Each section's name in a `chip_island` line and the exit stats.
@(rodata)
CHIP_SECTION_NAMES := [Chip_Section]string {
	.Menu   = "menu",
	.Undo   = "undo",
	.Spaces = "spaces",
	.Object = "object",
	.Search = "search",
	.End    = "end",
}

// Each section as Arrange and the Library call it.
@(rodata)
CHIP_SECTION_LABELS := [Chip_Section]string {
	.Menu   = "Menu and file",
	.Undo   = "Undo and Redo",
	.Spaces = "Spaces",
	.Object = "Object",
	.Search = "Search",
	.End    = "History and Settings",
}

// Each island's root.
@(rodata)
CHIP_ISLAND_ROOTS := [Chip_Section]string {
	.Menu   = "chip island menu",
	.Undo   = "chip island undo",
	.Spaces = "chip island spaces",
	.Object = "chip island object",
	.Search = "chip island search",
	.End    = "chip island end",
}

// How far over the bar's edge a section let go still goes back in it, in points.
CHIP_BAR_REACH :: 12

// Whether section `s` stands in the chip bar.
chip_in_bar :: proc(k: ^Kit_State, s: Chip_Section) -> bool {
	return k.islands[s] == nil
}

// Whether every section stands in the bar, as the bar comes.
chip_islands_none :: proc(k: ^Kit_State) -> bool {
	for s in Chip_Section do if !chip_in_bar(k, s) do return false
	return true
}

// The highest an island's top goes, in points down the safe area: under the bar's band,
// so it never stands where the bar is.
chip_island_top :: proc() -> f32 {
	return TOP_BAR_H + 6
}

// Every island, each a row where the person let it go, kept in the window. Sets the
// menu's and the command palette's anchors from the islands that hold them.
kit_chip_islands :: proc(app: ^App, menu_anchor, search_anchor: ^ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	area := ui.safe_area(ctx)
	for s in Chip_Section {
		at, out := k.islands[s].?
		if !out do continue
		root := CHIP_ISLAND_ROOTS[s]
		size, _ := ui.prev_layout(ctx, root)
		top := chip_island_top()
		pos := [2]f32{clamp(at.x, 0, max(area.w - size.x, 0)), clamp(at.y, top, max(area.h - size.y, top))}
		ui.begin_anchored(ctx, root, .Start, .Start, pos, {direction = .Row, padding = 4, gap = 2, radius = t.radius_large, background = .Panel, center = true})
		_ = chip_section_draw(app, s, menu_anchor, search_anchor)
		ui.end(ctx)
		// The whole island, which Arrange outlines and carries.
		k.chip_at[s] = ui.last_ended(ctx)
	}
}

// Lays section `s` out in the current row and answers it, as the bar and an island both
// hold it; returns the rect it took. An island holds it whole: Search as its field, the
// object chip with its badges.
chip_section_draw :: proc(app: ^App, s: Chip_Section, menu_anchor, search_anchor: ^ui.Rect, field := true, fit := Object_Chip_Fit.Full) -> ui.Rect {
	k := &app.kit
	ctx := &k.ctx
	switch s {
	case .Menu:
		if ui.icon_button(ctx, "Menu", ui.ICON_MENU, selected = k.menu) {
			k.menu = !k.menu
			k.menu_scroll = 0
		}
		menu_anchor^ = ctx.last_rect
		start := ctx.last_rect
		_ = top_file_block(app)
		return ui.rect_union(start, ctx.last_rect)
	case .Undo:
		// A long press on either, slid sideways, scrubs the History, and let go unslid (or a
		// right-click) opens the History panel, to go back or forward many steps.
		undo := fmt.tprintf("Undo %s##undo", history_next_label(app.history.done[:]))
		redo := fmt.tprintf("Redo %s##redo", history_next_label(app.history.undone[:]))
		if ui.icon_button(ctx, undo, ui.ICON_UNDO, enabled = command_enabled(app, .Undo), keys = command_hint(app, .Undo)) do command_run(app, .Undo)
		quick_scrub_button(app, .Undo)
		undo_at := ctx.last_rect
		if ui.icon_button(ctx, redo, ui.ICON_REDO, enabled = command_enabled(app, .Redo), keys = command_hint(app, .Redo)) do command_run(app, .Redo)
		quick_scrub_button(app, .Redo)
		both := ui.rect_union(undo_at, ctx.last_rect)
		history_roll(app, both)
		pen_zone(app, both, .History)
		return both
	case .Spaces:
		_ = top_space_tabs(app)
		return ui.last_ended(ctx)
	case .Object:
		chip := object_chip_of(app)
		if fit == .Full do top_object_chip(app, chip, object_chip_fit(ctx, chip, 1e4))
		else do top_object_chip(app, chip, fit)
		return ctx.last_rect
	case .Search:
		if field {
			search_anchor^ = top_search_field(app)
			return ctx.last_rect
		}
		if ui.icon_button(ctx, "Search commands", ui.ICON_SEARCH, selected = k.palette, keys = command_hint(app, .Command_Palette)) {
			if k.palette do palette_close(app)
			else do palette_open(app)
		}
		search_anchor^ = ctx.last_rect
		return ctx.last_rect
	case .End:
		if ui.icon_button(ctx, "History", ui.ICON_HISTORY, selected = k.history) do k.history = !k.history
		start := ctx.last_rect
		_ = top_command(app, .Settings, ui.ICON_SETTINGS, "Settings", k.settings)
		return ui.rect_union(start, ctx.last_rect)
	}
	return {}
}

// Takes section `s` out of the bar to an island near where it stood, on the first free
// spot under the bar, or puts it back in the bar.
chip_island_toggle :: proc(app: ^App, s: Chip_Section) {
	k := &app.kit
	if !chip_in_bar(k, s) {
		k.islands[s] = nil
		report(app, nil, {}, "%s is back in the chip bar", CHIP_SECTION_LABELS[s])
		return
	}
	k.islands[s] = chip_island_spot(app, s)
	report(app, nil, {}, "%s stands on its own: drag it in Arrange to move it, or back onto the bar", CHIP_SECTION_LABELS[s])
}

// The first spot under the bar where an island of section `s` stands clear of the view
// chips, the rail, the panels and the other islands: row by row down from the bar's band,
// nearest first to where the section stood in the bar. Layout terms, whole points. The
// Library, which is only there while arranging, may cover it until it is put away.
chip_island_spot :: proc(app: ^App, s: Chip_Section) -> [2]f32 {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	area := ui.safe_area(ctx)
	home := k.chip_home[s]
	// The island is the section with its padding round it.
	size := [2]f32{max(home.w, t.target) + 8, t.target + 8}
	if s == .Search do size.x = TOP_SEARCH_W + 8
	keep := make([dynamic]ui.Rect, 0, 16, context.temp_allocator)
	for name in ([]string{"points", "view bar", "brush bar", "navigation head"}) do append(&keep, ui.prev_root_rect(ctx, name))
	for r in k.panels.rect do append(&keep, r)
	for at, other in k.islands do if at != nil && other != s do append(&keep, k.chip_at[other])
	start := home.x if home.w > 0 else area.x + area.w * 0.5 - size.x * 0.5
	STEP :: 8
	for y := area.y + chip_island_top(); y + size.y <= area.y + area.h * 0.6; y += STEP {
		for i in 0 ..< int(area.w / STEP) * 2 {
			// Nearest first: home, then a step either side, then two, and so on.
			off := f32((i + 1) / 2 * STEP) * (1 if i % 2 == 1 else -1)
			x := clamp(start + off, area.x + LENS_EDGE, area.x + area.w - LENS_EDGE - size.x)
			box := ui.Rect{x - 4, y - 4, size.x + 8, size.y + 8}
			clear := true
			for r in keep do if r.w > 0 && ui.rect_intersect(box, r).w > 0 && ui.rect_intersect(box, r).h > 0 {
				clear = false
				break
			}
			if !clear do continue
			lx := x - area.x
			if ctx.mirror do lx = area.w - lx - size.x
			return {math.round(lx), math.round(y - area.y)}
		}
	}
	// Nowhere clear: the middle under the bar, which Arrange can move it from.
	return {math.round(max(area.w * 0.5 - size.x * 0.5, 0)), chip_island_top()}
}

// Where section `s`, its outline `box` (screen points) let go with the pointer at `p`,
// goes: back in the bar when the pointer is over the bar (within CHIP_BAR_REACH of it),
// else an island with its top-left where the outline's was, in layout terms, kept under the
// bar's band.
chip_island_drop :: proc(app: ^App, box: ui.Rect, p: [2]f32) -> Maybe([2]f32) {
	k := &app.kit
	ctx := &k.ctx
	bar := ui.prev_root_rect(ctx, "top bar")
	near := ui.Rect{bar.x - CHIP_BAR_REACH, bar.y - CHIP_BAR_REACH, bar.w + 2 * CHIP_BAR_REACH, bar.h + 2 * CHIP_BAR_REACH}
	if bar.w > 0 && ui.rect_contains(near, p) do return nil
	area := ui.safe_area(ctx)
	x := box.x - area.x
	if ctx.mirror do x = area.w - x - box.w
	return [2]f32{math.round(max(x, 0)), math.round(max(box.y - area.y, chip_island_top()))}
}

// While arranging: each section drawn (in the bar or an island) outlined, a drag anywhere
// on it carrying it; its buttons wait while arranging, as a home screen's icons do. Let go
// over the bar it goes back in; elsewhere it stands there on its own. Returns whether a
// section is being carried, for the Library to step aside.
arrange_chip_sections :: proc(app: ^App) -> (carrying: bool) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	st := &k.arrange
	carried, has := st.chip_carry.?
	moving := has && st.carrying
	for s in Chip_Section {
		r := k.chip_at[s]
		if r.w <= 0 do continue
		box := ui.Rect{r.x - 2, r.y - 2, r.w + 4, r.h + 4}
		if moving && carried == s {
			m := ctx.input.mouse
			box = {st.carry_from.x - 2 + m.x - st.carry_press.x, st.carry_from.y - 2 + m.y - st.carry_press.y, r.w + 4, r.h + 4}
		}
		ui.stroke_rect(ctx, box, t.radius_medium + 2, t.accent if moving && carried == s else ui.color_fade(t.accent, 0.5), 2 if moving && carried == s else 1)
		ui.begin_at(ctx, fmt.tprintf("arrange chip %v", s), {r.x, r.y}, {direction = .Row})
		a := ui.area(ctx, fmt.tprintf("%s##arrange chip", CHIP_SECTION_LABELS[s]), {r.w, r.h}, drag = true)
		goes := "back onto the bar" if !chip_in_bar(k, s) else "out of the bar to stand on its own"
		ui.tip(ctx, a.id, a.rect, fmt.tprintf("Drag %s %s, or anywhere", CHIP_SECTION_LABELS[s], goes))
		arrange_chip_follow(app, s, r, a)
		ui.end(ctx)
	}
	carried, has = st.chip_carry.?
	if !has || !st.carrying do return false
	// The bar lights while the pointer is over it, where a section let go goes back in.
	bar := ui.prev_root_rect(ctx, "top bar")
	if bar.w > 0 {
		m := ctx.input.mouse
		over := ui.rect_contains({bar.x - CHIP_BAR_REACH, bar.y - CHIP_BAR_REACH, bar.w + 2 * CHIP_BAR_REACH, bar.h + 2 * CHIP_BAR_REACH}, m)
		ui.stroke_rect(ctx, bar, t.radius_large, t.accent if over else ui.color_fade(t.accent, 0.35), 2)
	}
	return true
}

// Follows a press on section `s` (its rect `r`) by its overlay `a`: past the slop it carries
// the section, and let go puts it where it was dropped (chip_island_drop).
@(private = "file")
arrange_chip_follow :: proc(app: ^App, s: Chip_Section, r: ui.Rect, a: ui.Area) {
	k := &app.kit
	ctx := &k.ctx
	st := &k.arrange
	if a.pressed {
		st.carry = nil
		st.chip_carry, st.carry_from, st.carry_press, st.carrying = s, r, a.mouse, false
		return
	}
	carried, ok := st.chip_carry.?
	if !ok || carried != s do return
	if a.held {
		d := a.mouse - st.carry_press
		if !st.carrying && d.x * d.x + d.y * d.y > ctx.theme.slop * ctx.theme.slop {
			st.carrying = true
			ui.long_cancel(ctx)
		}
		return
	}
	if st.carrying {
		box := ui.Rect{st.carry_from.x + a.mouse.x - st.carry_press.x, st.carry_from.y + a.mouse.y - st.carry_press.y, st.carry_from.w, st.carry_from.h}
		k.islands[s] = chip_island_drop(app, box, a.mouse)
		st.chip_carries += 1
	}
	st.chip_carry, st.carrying = nil, false
}

// Library > Docks' chip bar row: a toggle for each section, lit while it is in the bar; a
// tap takes it out to an island or puts it back. All in the bar puts every one back.
library_chip_sections :: proc(app: ^App, width: f32) {
	k := &app.kit
	ctx := &k.ctx
	ui.caption(ctx, "CHIP BAR")
	gap: f32 = 6
	cell := (width - 2 * gap) / 3
	for row in 0 ..< 2 {
		ui.begin(ctx, fmt.tprintf("library chips %d", row), {direction = .Row, gap = gap, width = width})
		for i in 0 ..< 3 {
			s := Chip_Section(row * 3 + i)
			if ui.toggle_button(ctx, fmt.tprintf("%s##library chip", CHIP_SECTION_LABELS[s]), chip_in_bar(k, s), cell, tooltip = "In the chip bar; tap to stand it on its own" if chip_in_bar(k, s) else "On its own; tap to put it back in the chip bar") do chip_island_toggle(app, s)
		}
		ui.end(ctx)
	}
	if ui.button(ctx, "All in the bar##library chips", .Bordered, width = width, enabled = !chip_islands_none(k)) {
		k.islands = {}
		report(app, nil, {}, "Every section is back in the chip bar")
	}
}

// The settings file's island lines, `chip_island <section> <x> <y>`, one for each section
// out of the bar.
chip_islands_save :: proc(k: ^Kit_State, out: ^strings.Builder) {
	for at, s in k.islands {
		p, out_of_bar := at.?
		if out_of_bar do fmt.sbprintfln(out, "chip_island %s %g %g", CHIP_SECTION_NAMES[s], p.x, p.y)
	}
}

// Reads a `chip_island <section> <x> <y>` line; a section or a number this version does not
// take leaves the section in the bar.
chip_island_read :: proc(k: ^Kit_State, f: []string) {
	if len(f) != 4 do return
	for name, s in CHIP_SECTION_NAMES {
		if name != f[1] do continue
		x, x_ok := strconv.parse_f32(f[2])
		y, y_ok := strconv.parse_f32(f[3])
		if !x_ok || !y_ok || !(abs(x) < 1e30) || !(abs(y) < 1e30) do return
		k.islands[s] = [2]f32{clamp(x, 0, 1e5), clamp(y, 0, 1e5)}
	}
}

// The islands for the exit stats: `undo:600:300,search:20:60` (each section out of the bar
// with its top-left), or none.
chip_islands_text :: proc(k: ^Kit_State) -> string {
	out := strings.builder_make(context.temp_allocator)
	for at, s in k.islands {
		p, out_of_bar := at.?
		if !out_of_bar do continue
		if strings.builder_len(out) > 0 do strings.write_byte(&out, ',')
		fmt.sbprintf(&out, "%s:%.0f:%.0f", CHIP_SECTION_NAMES[s], p.x, p.y)
	}
	if strings.builder_len(out) == 0 do return "none"
	return strings.to_string(out)
}
