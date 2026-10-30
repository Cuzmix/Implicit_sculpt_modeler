package main

import "core:fmt"
import "core:path/filepath"
import "core:time"

import "../ui"

// The chip bar (the overhaul's round 3, which replaced the full-width top bar): one
// floating bar across the top in the docks' style, its sections split by hairlines. The
// menu and the file with whether it is saved; Undo and Redo; the spaces as tabs
// (spaces.odin); the object chip (object_chip.odin); Search; History and Settings. Home,
// Save, Import, Export and Help are in the menu, the passes on the pane. A section Arrange
// took out stands as an island of its own (chip_islands.odin) and the bar closes up round
// the rest. Returns the menu button and the Search field, which the menu and the command
// palette open under.
kit_top_bar :: proc(app: ^App) -> (menu_anchor, search_anchor: ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	area := ui.safe_area(ctx)
	k.passes.chip_held = false
	k.object_chip_fit = .None
	k.chip_at = {}
	if lens_focus(k) do return kit_top_islands(app)
	arranging := k.bars_edit
	// With every section out, the bar is drawn only while arranging, to take them back.
	if !chip_islands_none(k) {
		empty := true
		for s in Chip_Section do if chip_in_bar(k, s) do empty = false
		if empty && !arranging {
			kit_chip_islands(app, &menu_anchor, &search_anchor)
			return
		}
	}
	in_bar := [Chip_Section]bool{}
	for s in Chip_Section do in_bar[s] = chip_in_bar(k, s)
	width := area.w - 2 * TOP_BAR_INSET
	ui.begin_anchored(ctx, "top bar", .Start, .Start, {TOP_BAR_INSET, TOP_BAR_TOP}, {direction = .Row, width = width, height = TOP_BAR_H - TOP_BAR_TOP, padding = 2, gap = 2, center = true, radius = t.radius_large, background = .Panel})
	// What the row holds, for the gaps between: the bar has always counted fourteen
	// things with every section in it (the middle's spacer among them).
	things := 0
	left: f32 = 0
	if in_bar[.Menu] {
		k.chip_at[.Menu] = chip_section_draw(app, .Menu, &menu_anchor, &search_anchor)
		// The button and the file, less the gap between them, which the row counts.
		left += k.chip_at[.Menu].w - 2
		things += 2
	}
	if in_bar[.Undo] {
		if things > 0 {
			top_divider(ctx)
			left += TOP_DIVIDER_W
			things += 1
		}
		k.chip_at[.Undo] = chip_section_draw(app, .Undo, &menu_anchor, &search_anchor)
		left += 2 * t.target
		things += 2
	}
	// What the ends take, the middle gets. The object chip gives up its badges, then its
	// tag, before Search shrinks to its icon; then the chip shrinks to its icon, and last
	// the space tabs go to the layout's chip.
	before := things > 0
	tabs: f32 = space_tabs_width(app) if in_bar[.Spaces] else 0
	tab_div: f32 = TOP_DIVIDER_W if in_bar[.Spaces] && before else 0
	chip_div: f32 = TOP_DIVIDER_W if in_bar[.Object] && (before || in_bar[.Spaces]) else 0
	things += 1
	if in_bar[.Spaces] do things += 1 + (1 if before else 0)
	if in_bar[.Object] do things += 1 + (1 if before || in_bar[.Spaces] else 0)
	right: f32 = 0
	if in_bar[.Search] do things += 1
	if in_bar[.End] {
		right += 2 * t.target
		things += 2
		if in_bar[.Search] {
			right += TOP_DIVIDER_W
			things += 1
		}
	}
	row := 2 * 2 + 2 * f32(things - 1)
	middle := width - row - left - right
	chip := object_chip_of(app)
	field := false
	fit := Object_Chip_Fit.None
	if !arranging {
		with_field := middle - TOP_SEARCH_W - tabs - tab_div - chip_div
		switch {
		case !in_bar[.Object]:
			field = in_bar[.Search] && with_field >= 0
		case !in_bar[.Search]:
			fit = object_chip_fit(ctx, chip, middle - tabs - tab_div - chip_div)
		case object_chip_fit(ctx, chip, with_field) >= .Name:
			field, fit = true, object_chip_fit(ctx, chip, with_field)
		case:
			fit = object_chip_fit(ctx, chip, middle - t.target - tabs - tab_div - chip_div)
		}
	} else {
		field = in_bar[.Search] && middle - arrange_top_width(app) >= TOP_SEARCH_W + 24
	}
	if in_bar[.Search] do middle -= TOP_SEARCH_W if field else t.target
	if arranging {
		// Arranging, the middle holds what arranging needs in place of the tabs and the chip.
		pill := arrange_top_width(app)
		if middle >= pill + 8 {
			pad := (middle - pill) * 0.5
			ui.spacer(ctx, pad)
			ui.spacer(ctx, max(middle - pad - arrange_top_controls(app), 0))
		} else {
			// Too narrow for them all: Done at least, the rest being in the Library and Search.
			done_w: f32 = 84
			pad := max((middle - done_w) * 0.5, 0)
			ui.spacer(ctx, pad)
			if ui.button(ctx, "Done##arrange narrow", .Solid, .Accent, width = done_w) do k.bars_edit = false
			ui.spacer(ctx, max(middle - pad - done_w, 0))
		}
	} else if in_bar[.Spaces] && middle >= tabs + tab_div {
		if tab_div > 0 do top_divider(ctx)
		k.chip_at[.Spaces] = chip_section_draw(app, .Spaces, &menu_anchor, &search_anchor)
		used := tab_div + k.chip_at[.Spaces].w
		if fit != .None {
			top_divider(ctx)
			k.chip_at[.Object] = chip_section_draw(app, .Object, &menu_anchor, &search_anchor, fit = fit)
			used += chip_div + ctx.last_rect.w
		}
		ui.spacer(ctx, max(middle - used, 0))
	} else if in_bar[.Spaces] && middle >= WORKSPACE_CHIP_ROOM {
		used: f32 = 0
		if before {
			top_divider(ctx)
			used += TOP_DIVIDER_W
		}
		kit_workspace_chip(app)
		ui.spacer(ctx, max(middle - used - ctx.last_rect.w, 0))
	} else if !in_bar[.Spaces] && fit != .None {
		if chip_div > 0 do top_divider(ctx)
		k.chip_at[.Object] = chip_section_draw(app, .Object, &menu_anchor, &search_anchor, fit = fit)
		ui.spacer(ctx, max(middle - chip_div - ctx.last_rect.w, 0))
	} else {
		ui.spacer(ctx, max(middle, 0))
	}
	if in_bar[.Search] do k.chip_at[.Search] = chip_section_draw(app, .Search, &menu_anchor, &search_anchor, field = field)
	if in_bar[.End] {
		if in_bar[.Search] do top_divider(ctx)
		k.chip_at[.End] = chip_section_draw(app, .End, &menu_anchor, &search_anchor)
	}
	ui.end(ctx)
	// Where each section stood in the bar, for an island Arrange's Library takes out.
	if !arranging do for s in Chip_Section do if in_bar[s] && k.chip_at[s].w > 0 do k.chip_home[s] = k.chip_at[s]
	kit_chip_islands(app, &menu_anchor, &search_anchor)
	return
}

// Whether the layout is focused: its workspace hides the view bar, as the built-in
// Focus does (screen focus2). The top bar is then three islands over the view, and the
// view's chips, the rail and the shelf's page names stand aside.
lens_focus :: proc(k: ^Kit_State) -> bool {
	return zone_hidden(k, .View_Bar)
}

// How far the islands stand in from the top of the safe area, in points.
ISLAND_TOP :: 6

// The focused top bar: Menu, Undo and Redo in an island at the off-hand corner; the
// workspace (its chip opens the switcher's menu) and X symmetry in the middle; Search,
// View layout, Passes and History at the pen side. Returns the menu button and Search, as
// the bar does.
@(private = "file")
kit_top_islands :: proc(app: ^App) -> (menu_anchor, search_anchor: ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	island := ui.Box{direction = .Row, padding = 4, gap = 2, radius = t.radius_large, background = .Panel, center = true}
	ui.begin_anchored(ctx, "top bar", .Start, .Start, {LENS_EDGE, ISLAND_TOP}, island)
	if ui.icon_button(ctx, "Menu", ui.ICON_MENU, selected = k.menu) {
		k.menu = !k.menu
		k.menu_scroll = 0
	}
	menu_anchor = ctx.last_rect
	// A long press on either, slid sideways, scrubs the History, and let go unslid (or a
	// right-click) opens the History panel, to go back or forward many steps.
	undo := fmt.tprintf("Undo %s##undo", history_next_label(app.history.done[:]))
	redo := fmt.tprintf("Redo %s##redo", history_next_label(app.history.undone[:]))
	if ui.icon_button(ctx, undo, ui.ICON_UNDO, enabled = command_enabled(app, .Undo), keys = command_hint(app, .Undo)) do command_run(app, .Undo)
	quick_scrub_button(app, .Undo)
	if ui.icon_button(ctx, redo, ui.ICON_REDO, enabled = command_enabled(app, .Redo), keys = command_hint(app, .Redo)) do command_run(app, .Redo)
	quick_scrub_button(app, .Redo)
	ui.end(ctx)

	ui.begin_anchored(ctx, "focus middle", .Center, .Start, {0, ISLAND_TOP}, island)
	w := &k.workspaces
	if a := lens_chip(ctx, "Workspace##focus", workspace_name(k, w.current), chevron = true, lit = w.menu, keys = command_hint(app, .Workspace, w.current)); a.clicked {
		was := w.menu
		kit_floats_close(k)
		w.menu = !was
	}
	w.menu_at = ctx.last_rect
	// The amber dot while the layout differs from the saved one, as the switcher has it.
	if w.modified do ui.fill_circle(ctx, {w.menu_at.x + w.menu_at.w - 6, w.menu_at.y + 12}, 3, t.warning)
	x := command_checked(app, .Symmetry_X)
	if a := lens_chip(ctx, "Symmetry X##focus", "X", glyph = ICON_SYMMETRY, lit = x, keys = command_hint(app, .Symmetry_X)); a.clicked do command_run(app, .Symmetry_X)
	if x do ui.stroke_rect(ctx, {ctx.last_rect.x, ctx.last_rect.y + (ctx.last_rect.h - LENS_CHIP_H) * 0.5, ctx.last_rect.w, LENS_CHIP_H}, t.radius_medium, t.accent, 1)
	ui.end(ctx)

	ui.begin_anchored(ctx, "focus tools", .End, .Start, {LENS_EDGE, ISLAND_TOP}, island)
	if ui.icon_button(ctx, "Search commands", ui.ICON_SEARCH, selected = k.palette, keys = command_hint(app, .Command_Palette)) {
		if k.palette do palette_close(app)
		else do palette_open(app)
	}
	search_anchor = ctx.last_rect
	// The menus these open come down from their buttons, from keys and search too.
	layout := bar_pop_showing(app, .View_Layout)
	if ui.icon_button(ctx, "View layout", ICON_VIEW_LAYOUT, selected = layout, keys = command_hint(app, .View_Layout_Menu)) do bar_pop_toggle(app, .View_Layout, ctx.last_rect, .Below)
	k.bar_at[.View_Layout], k.bar_side[.View_Layout] = ctx.last_rect, .Below
	if ui.icon_button(ctx, "Passes", ICON_PASSES, selected = k.passes.menu, keys = command_hint(app, .Pass_Menu)) {
		k.passes.menu_at, k.passes.menu_side = ctx.last_rect, .Below
		pass_menu_toggle(app)
	}
	k.passes.menu_at, k.passes.menu_side = ctx.last_rect, .Below
	if ui.icon_button(ctx, "History", ui.ICON_HISTORY, selected = k.history) do k.history = !k.history
	k.history_at = ctx.last_rect
	ui.end(ctx)
	return
}

// The Search field's width, in points.
TOP_SEARCH_W :: 300
// How opaque the chips over the view are, of 255.
TOP_GLASS_ALPHA :: 189
// The chip bar floats this far in from the safe area's sides and down from its top, in
// points; TOP_BAR_H is the room it takes, those points with it.
TOP_BAR_INSET :: 8
TOP_BAR_TOP :: 4
// A hairline between sections takes this much of the row.
TOP_DIVIDER_W :: 13

top_command :: proc(app: ^App, id: Command_Id, glyph: rune, name: string, selected := false) -> bool {
	ctx := &app.kit.ctx
	if ui.icon_button(ctx, name, glyph, selected || command_checked(app, id), command_enabled(app, id), command_hint(app, id)) {
		command_run(app, id)
		return true
	}
	return false
}

// A hairline between groups of the bar.
@(private = "file")
top_divider :: proc(ctx: ^ui.Context) {
	r := ui.place(ctx, {TOP_DIVIDER_W, 24})
	ui.fill_rect(ctx, {r.x + 6, r.y, 1, r.h}, 0, ctx.theme.border)
}

// The file the scene saves to over whether it is saved; returns its width.
top_file_block :: proc(app: ^App) -> f32 {
	ctx := &app.kit.ctx
	t := ctx.theme
	name := filepath.base(app.scene_path) if app.scene_path != "" else "Untitled"
	status := file_status(app, time.now())
	// As wide as its widest status line whatever it says now, so Undo and Redo stay put
	// when a stroke makes the scene unsaved.
	widest := max(ui.text_width(ctx, "Unsaved changes", t.small_size), ui.text_width(ctx, "Saved 59 min ago", t.small_size))
	w := min(max(ui.text_width(ctx, name, t.text_size, .Semibold), widest) + 16, 220)
	r := ui.place(ctx, {w, TOP_BAR_H - TOP_BAR_TOP - 8})
	mid := r.y + r.h * 0.5
	ui.text(ctx, ui.text_fit(ctx, name, t.text_size, w - 16, .Semibold), r.x + 8, mid - 8, t.text_size, t.text, .Semibold)
	shown := ui.text_fit(ctx, status, t.small_size, w - 16)
	ui.text(ctx, shown, r.x + 8, mid + 8, t.small_size, t.text_tertiary)
	// A save just made says so with a tick after the status (feedback_motion.odin).
	draw_save_tick(app, {r.x + 8 + ui.text_width(ctx, shown, t.small_size) + 4 + t.small_size * 0.5, mid + 8}, t.small_size)
	return w
}

// Whether the scene is saved, as the file block's second line says it at `now`: unsaved
// changes, never saved, or how long ago its file was written.
file_status :: proc(app: ^App, now: time.Time) -> string {
	unsaved := scene_unsaved(app) && (app.scene_path != "" || scene_has_work(app))
	if unsaved do return "Unsaved changes"
	if app.scene_path == "" || app.saved_at == {} do return "Not saved"
	return saved_ago(time.diff(app.saved_at, now))
}

// "Saved just now", "Saved 2 min ago", "Saved 3 h ago" or "Saved 4 days ago".
saved_ago :: proc(d: time.Duration) -> string {
	m := int(time.duration_minutes(d))
	switch {
	case m < 1:       return "Saved just now"
	case m < 60:      return fmt.tprintf("Saved %d min ago", m)
	case m < 48 * 60: return fmt.tprintf("Saved %d h ago", m / 60)
	}
	return fmt.tprintf("Saved %d days ago", m / (24 * 60))
}

// Lucide's plus.
ICON_PLUS_SMALL :: rune(0xe141)

// The Search field: a tap opens the command palette under it (Ctrl+K does too).
top_search_field :: proc(app: ^App) -> ui.Rect {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	a := ui.area(ctx, "Search field", {TOP_SEARCH_W, t.target})
	r := ui.Rect{a.rect.x, a.rect.y + (a.rect.h - 34) * 0.5, a.rect.w, 34}
	ui.fill_rect(ctx, r, t.radius_medium, t.surface)
	ui.stroke_rect(ctx, r, t.radius_medium, t.border, 1)
	if a.held do ui.fill_rect(ctx, r, t.radius_medium, t.fill_pressed)
	else if a.hovered do ui.fill_rect(ctx, r, t.radius_medium, t.fill_hover)
	if k.palette do ui.stroke_rect(ctx, r, t.radius_medium, t.accent, 1)
	mid := r.y + r.h * 0.5
	ui.icon(ctx, ui.ICON_SEARCH, {r.x + 18, mid}, 16, t.text_tertiary)
	keys := command_keys(app, .Command_Palette)
	kw: f32 = 0
	if keys != "" {
		kw = ui.text_width(ctx, keys, t.caption_size, .Semibold) + 10
		chip := ui.Rect{r.x + r.w - 8 - kw, mid - 10, kw, 20}
		ui.fill_rect(ctx, chip, t.radius_small, t.track)
		ui.text(ctx, keys, chip.x + chip.w * 0.5, mid, t.caption_size, t.text_secondary, .Semibold, .Center)
	}
	hint := ui.text_fit(ctx, "Search commands, brushes, panels", t.small_size, r.w - 36 - kw - 16)
	ui.text(ctx, hint, r.x + 34, mid, t.small_size, t.text_tertiary)
	ui.tip(ctx, a.id, r, "Search commands", command_hint(app, .Command_Palette))
	if a.clicked {
		if k.palette do palette_close(app)
		else do palette_open(app)
	}
	return r
}
