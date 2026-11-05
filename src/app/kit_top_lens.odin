package main

import "core:fmt"
import "core:path/filepath"
import "core:time"

import "../ui"

// The top bar: three docks along the top (Top_Dock), at its start corner, on the window's
// centre line and at its end corner, each a dock of buttons the person edits as any other
// (Edit docks, the Library), so the top bar holds whatever they reach for most. At first the
// File dock holds the menu, the file chip (the file and whether it is saved), Save, Undo and
// Redo; the Spaces dock the space tabs and the object chip; the App dock Search, History and
// Settings. They are a setting, not a layout's: the Spaces dock holds the spaces' tabs, so
// the bar is the same in every space. When the corners would reach the middle
// dock, the chips give way in a fixed order (the object chip's badges, Search's field, the
// chip's tag, the file chip, the tabs to the layout's chip, the object chip to its icon), and
// only then does the middle leave the centre. Returns the menu button and the Search button,
// which the menu and the command palette open under.
kit_top_bar :: proc(app: ^App) -> (menu_anchor, search_anchor: ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	area := ui.safe_area(ctx)
	k.passes.chip_held = false
	k.object_chip_fit = .None
	k.top_at = {}
	k.space_tabs_at = {}
	width := area.w - 2 * TOP_BAR_INSET
	v := Top_Fit {
		focus   = lens_focus(k) && !k.bars_edit,
		arrange = k.bars_edit,
		edit    = k.bars_edit && k.edit_dock == nil,
		file    = !lens_focus(k),
		field   = k.search_field,
		fit     = .Full,
	}
	chip := object_chip_of(app)
	fits :: proc(w: [Top_Dock]f32, width: f32) -> bool {
		side := max(w[.File], w[.App])
		return w[.Spaces] <= width - 2 * (side + TOP_ISLAND_GAP)
	}
	for step in 0 ..< 6 {
		if fits(top_widths(app, v, chip), width) do break
		switch step {
		case 0: if v.fit > .Tag do v.fit = .Tag
		case 1: v.field = false
		case 2: if v.fit > .Name do v.fit = .Name
		case 3: v.file = false
		case 4: if v.tabs == 0 do v.tabs = 1
		case 5: if v.fit > .Icon do v.fit = .Icon
		}
	}
	// Off centre at last: the middle takes what the corners leave, and gives up the
	// layout's chip, then shrinks the object chip, before anything overlaps.
	w := top_widths(app, v, chip)
	if !v.arrange && !v.focus && w[.File] + w[.Spaces] + w[.App] + 2 * TOP_ISLAND_GAP > width {
		room := width - w[.File] - w[.App] - 2 * TOP_ISLAND_GAP
		v.tabs = 2
		rest := max(top_dock_width(app, .Spaces, v, chip, skip_chip = true), 2 * TOP_ISLAND_PAD)
		v.fit = object_chip_fit(ctx, chip, room - rest - TOP_ISLAND_PAD)
		w = top_widths(app, v, chip)
	}
	h: f32 = TOP_BAR_H - TOP_BAR_TOP
	island := ui.Box{direction = .Row, height = h, padding = TOP_ISLAND_PAD, gap = TOP_ISLAND_PAD, center = true, radius = t.radius_large, background = .Panel}
	ui.begin_anchored(ctx, "top bar", .Start, .Start, {TOP_BAR_INSET, TOP_BAR_TOP}, {direction = .Row, width = width, height = h, center = true})
	// The docks as drawn last frame, so the middle sits on the centre to the point; the sums
	// stand in on the first frame and when what shows changes. Focus's and Arrange's middle
	// holds chips whose widths the sums only guess, so it takes last frame's width whenever
	// there is one.
	drawn :: proc(ctx: ^ui.Context, name: string, sum: f32, trust := false) -> f32 {
		size, _ := ui.prev_layout(ctx, name)
		return size.x if size.x > 0 && (trust || abs(size.x - sum) < 24) else sum
	}
	used: f32 = 0
	for d in Top_Dock {
		if w[d] <= 0 do continue
		dw := drawn(ctx, TOP_DOCK_ROOTS[d], w[d], trust = d == .Spaces && (v.focus || v.arrange))
		at: f32
		switch d {
		case .File:
			at = 0
		case .Spaces:
			at = clamp((width - dw) * 0.5, used + TOP_ISLAND_GAP, max(width - w[.App] - TOP_ISLAND_GAP - dw, used + TOP_ISLAND_GAP))
		case .App:
			at = max(width - dw, used)
		}
		ui.spacer(ctx, at - used)
		ui.begin(ctx, TOP_DOCK_ROOTS[d], island)
		switch {
		case d == .Spaces && v.arrange:
			// Editing, the middle holds what editing needs in place of its buttons, or Done
			// alone when the rest has no room.
			if v.tabs == 0 do _ = arrange_top_controls(app)
			else if ui.button(ctx, "Done##arrange narrow", .Solid, .Accent, width = ARRANGE_DONE_W) do k.bars_edit = false
		case d == .Spaces && v.focus:
			top_focus_middle(app)
		case:
			top_dock_draw(app, d, v, chip, &menu_anchor, &search_anchor)
			if d == .App && v.focus do top_focus_view(app)
		}
		ui.end(ctx)
		k.top_at[d] = ui.last_ended(ctx)
		used = at + dw
	}
	ui.end(ctx)
	return
}

// The top dock bar `which` is, or false for any other bar.
top_dock_of :: proc(which: Bar_Which) -> (Top_Dock, bool) {
	#partial switch which {
	case .Top_File:   return .File, true
	case .Top_Spaces: return .Spaces, true
	case .Top_App:    return .App, true
	}
	return {}, false
}

// The three docks of the top bar, from the start corner.
Top_Dock :: enum u8 {
	File,
	Spaces,
	App,
}

// Each top dock's bar.
@(rodata)
TOP_DOCK_BARS := [Top_Dock]Bar_Which {
	.File   = .Top_File,
	.Spaces = .Top_Spaces,
	.App    = .Top_App,
}

// Each top dock's root in the bar's row, which its drawn width is read back from; the
// whole row stays "top bar", so a control's name is "top bar/<dock>/...".
@(rodata)
TOP_DOCK_ROOTS := [Top_Dock]string {
	.File   = "file dock",
	.Spaces = "spaces dock",
	.App    = "app dock",
}

// What the top docks show this frame, from everything down to the least that still works.
Top_Fit :: struct {
	focus:   bool, // Focus's middle (the space chip, X symmetry) and View layout and Passes at the end
	arrange: bool, // editing the docks: the middle holds the editing controls
	edit:    bool, // the top docks' own buttons are edited: Edit docks, not one dock's Edit buttons
	file:    bool, // the file chip
	field:   bool, // Search as its field rather than its icon
	tabs:    int, // the space tabs (0), the layout's chip (1) or neither (2); editing, all of the controls (0) or Done alone
	fit:     Object_Chip_Fit,
}

// The room kept between two docks of the top bar, in points.
TOP_ISLAND_GAP :: 8
// The padding inside a top dock and the gap between its buttons, in points.
TOP_ISLAND_PAD :: 2

// The width Done takes alone in the middle while editing, when the other controls have no
// room (they are in the Library and Search too).
ARRANGE_DONE_W :: 84

// Whether a hairline stands between two neighbouring buttons of a top dock: after a chip
// (the file, the space tabs) and after Search, as between the bar's groups.
top_divides :: proc(prev, next: Command_Id) -> bool {
	#partial switch prev {
	case .File_Chip, .Space_Tabs, .Command_Palette: return true
	case .Main_Menu:                                return next != .File_Chip
	}
	return false
}

// How wide button `s` of a top dock stands with `v`'s give-way, in points; 0 when it gives
// way altogether.
top_slot_width :: proc(app: ^App, s: Bar_Slot, v: Top_Fit, chip: Object_Chip) -> f32 {
	ctx := &app.kit.ctx
	t := ctx.theme
	// Editing, every button stands as its icon, to be carried, removed or changed.
	if v.edit do return t.target
	#partial switch s.id {
	case .File_Chip:
		return top_file_width(app) if v.file else 0
	case .Space_Tabs:
		switch v.tabs {
		case 0: return space_tabs_width(app)
		case 1: return SPACE_CHIP_ROOM
		}
		return 0
	case .Object_Chip:
		return object_chip_width(ctx, chip, v.fit) if v.fit != .None else 0
	case .Command_Palette:
		return TOP_SEARCH_W if v.field else t.target
	}
	if _, ok := value_of(s); ok do return VALUE_CHIP.x
	return t.target
}

// Top dock `d`'s width with `v`'s give-way: its buttons, the hairlines and gaps between them
// and its padding (the + while editing too). With `skip_chip` the object chip is left out,
// for what the rest of the middle takes.
top_dock_width :: proc(app: ^App, d: Top_Dock, v: Top_Fit, chip: Object_Chip, skip_chip := false) -> f32 {
	t := app.kit.ctx.theme
	w: f32 = 0
	n := 0
	prev := Command_Id.None
	for s in bar_used(app, TOP_DOCK_BARS[d]) {
		if skip_chip && s.id == .Object_Chip do continue
		x := top_slot_width(app, s, v, chip)
		if x <= 0 do continue
		if n > 0 && top_divides(prev, s.id) {
			w += TOP_DIVIDER_W
			n += 1
		}
		w += x
		n += 1
		prev = s.id
	}
	if v.edit {
		w += t.target
		n += 1
	}
	if n == 0 do return 0
	return w + f32(n - 1) * TOP_ISLAND_PAD + 2 * TOP_ISLAND_PAD
}

// The three docks' widths with `v`'s give-way.
top_widths :: proc(app: ^App, v: Top_Fit, chip: Object_Chip) -> (w: [Top_Dock]f32) {
	for d in Top_Dock do w[d] = top_dock_width(app, d, v, chip)
	switch {
	case v.arrange:
		w[.Spaces] = (arrange_top_width(app) if v.tabs == 0 else ARRANGE_DONE_W) + 2 * TOP_ISLAND_PAD
	case v.focus:
		w[.Spaces] = SPACE_CHIP_ROOM + FOCUS_SYMMETRY_W + 3 * TOP_ISLAND_PAD
		w[.App] += TOP_DIVIDER_W + 2 * app.kit.ctx.theme.target + 3 * TOP_ISLAND_PAD
	}
	return
}

// Draws top dock `d`'s buttons with `v`'s give-way: the chips and the bar's own buttons
// (the menu, Save with Undo and Redo's scrubbing, Search, History) as they behave there,
// anything else the person put on it as any dock's button; while editing, its + after them.
top_dock_draw :: proc(app: ^App, d: Top_Dock, v: Top_Fit, chip: Object_Chip, menu_anchor, search_anchor: ^ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	which := TOP_DOCK_BARS[d]
	used := bar_used(app, which)
	prev := Command_Id.None
	drawn := 0
	undo_at: ui.Rect
	for s, i in used {
		if top_slot_width(app, s, v, chip) <= 0 do continue
		if drawn > 0 && top_divides(prev, s.id) do top_divider(ctx)
		drawn += 1
		prev = s.id
		if v.edit {
			bar_slot_button(app, which, i, s)
			continue
		}
		#partial switch s.id {
		case .Main_Menu:
			if ui.icon_button(ctx, "Menu", ui.ICON_MENU, selected = k.menu) {
				k.menu = !k.menu
				k.menu_scroll = 0
			}
			menu_anchor^ = ctx.last_rect
		case .File_Chip:
			_ = top_file_block(app)
		case .Save_Scene:
			// It stands out while the scene has changes to save.
			if ui.icon_button(ctx, "Save scene##top save", ui.ICON_SAVE, selected = scene_unsaved(app) && app.scene_path != "", keys = command_hint(app, .Save_Scene)) do command_run(app, .Save_Scene)
		case .Undo, .Redo:
			// A long press on either, slid sideways, scrubs the History, and let go unslid
			// (or a right-click) opens the History panel, to go back or forward many steps.
			undo := s.id == .Undo
			name := fmt.tprintf("Undo %s##undo", history_next_label(app.history.done[:])) if undo else fmt.tprintf("Redo %s##redo", history_next_label(app.history.undone[:]))
			if ui.icon_button(ctx, name, ui.ICON_UNDO if undo else ui.ICON_REDO, enabled = command_enabled(app, s.id), keys = command_hint(app, s.id)) do command_run(app, s.id)
			quick_scrub_button(app, .Undo if undo else .Redo)
			undo_at = ctx.last_rect if undo_at.w <= 0 else ui.rect_union(undo_at, ctx.last_rect)
		case .Space_Tabs:
			if v.tabs == 0 {
				_ = top_space_tabs(app)
				k.space_tabs_at = ui.last_ended(ctx)
			} else {
				kit_space_chip(app)
			}
		case .Object_Chip:
			top_object_chip(app, chip, v.fit)
		case .Command_Palette:
			if v.field {
				search_anchor^ = top_search_field(app)
				continue
			}
			if ui.icon_button(ctx, "Search commands", ui.ICON_SEARCH, selected = k.palette, keys = command_hint(app, .Command_Palette)) {
				if k.palette do palette_close(app)
				else do palette_open(app)
			}
			search_anchor^ = ctx.last_rect
		case .Open_Card:
			bar_slot_button(app, which, i, s)
			// The History card's button, which the tour lights.
			if Card(s.arg) == .History do k.history_at = ctx.last_rect
		case .Settings:
			_ = top_command(app, .Settings, ui.ICON_SETTINGS, "Settings", k.settings)
		case:
			bar_slot_button(app, which, i, s)
		}
	}
	// The pen's roll over Undo and Redo steps through the History.
	if undo_at.w > 0 {
		history_roll(app, undo_at)
		pen_zone(app, undo_at, .History)
	}
	if v.edit do bar_add_button(app, which, len(used))
}

// Whether the layout is focused: it hides the view bar, as the built-in
// Focus does (screen focus2). The top bar is then three islands over the view, and the
// view's chips, the rail and the shelf's page names stand aside.
lens_focus :: proc(k: ^Kit_State) -> bool {
	return zone_hidden(k, .View_Bar)
}

// The width the X symmetry chip takes in Focus's middle island, in points.
FOCUS_SYMMETRY_W :: 64

// Focus's middle island: the space (its chip opens the layout menu) and X symmetry.
@(private = "file")
top_focus_middle :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	kit_space_chip(app)
	x := command_checked(app, .Symmetry_X)
	if a := lens_chip(ctx, "Symmetry X##focus", "X", glyph = ICON_SYMMETRY, lit = x, keys = command_hint(app, .Symmetry_X)); a.clicked do command_run(app, .Symmetry_X)
	if x do ui.stroke_rect(ctx, {ctx.last_rect.x, ctx.last_rect.y + (ctx.last_rect.h - LENS_CHIP_H) * 0.5, ctx.last_rect.w, LENS_CHIP_H}, t.radius_medium, t.accent, 1)
}

// View layout and Passes, which Focus keeps at the right as its view bar is away; the
// menus they open come down from their buttons, from keys and Search too.
@(private = "file")
top_focus_view :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	top_divider(ctx)
	layout := bar_pop_showing(app, .View_Layout)
	if ui.icon_button(ctx, "View layout", ICON_VIEW_LAYOUT, selected = layout, keys = command_hint(app, .View_Layout_Menu)) do bar_pop_toggle(app, .View_Layout, ctx.last_rect, .Below)
	k.bar_at[.View_Layout], k.bar_side[.View_Layout] = ctx.last_rect, .Below
	if ui.icon_button(ctx, "Shading modes", ICON_PASSES, selected = k.passes.menu, keys = command_hint(app, .Pass_Menu)) {
		k.passes.menu_at, k.passes.menu_side = ctx.last_rect, .Below
		pass_menu_toggle(app)
	}
	k.passes.menu_at, k.passes.menu_side = ctx.last_rect, .Below
}

// How opaque the chips over the view are, of 255.
TOP_GLASS_ALPHA :: 189
// The top bar floats this far in from the safe area's sides and down from its top, in
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

// The file block's width: as wide as its widest status line whatever it says now, so
// Undo and Redo stay put when a stroke makes the scene unsaved.
top_file_width :: proc(app: ^App) -> f32 {
	ctx := &app.kit.ctx
	t := ctx.theme
	name := filepath.base(app.scene_path) if app.scene_path != "" else "Untitled"
	widest := max(ui.text_width(ctx, "Unsaved changes", t.small_size), ui.text_width(ctx, "Saved 59 min ago", t.small_size))
	return min(max(ui.text_width(ctx, name, t.text_size, .Semibold), widest) + 16, 220)
}

// The file the scene saves to over whether it is saved; returns its width.
top_file_block :: proc(app: ^App) -> f32 {
	ctx := &app.kit.ctx
	t := ctx.theme
	name := filepath.base(app.scene_path) if app.scene_path != "" else "Untitled"
	status := file_status(app, time.now())
	w := top_file_width(app)
	r := ui.place(ctx, {w, TOP_BAR_H - TOP_BAR_TOP - 8})
	mid := r.y + r.h * 0.5
	ui.text(ctx, ui.text_fit(ctx, name, t.text_size, w - 16, .Semibold), r.x + 8, mid - 8, t.text_size, t.text, .Semibold)
	shown := ui.text_fit(ctx, status, t.small_size, w - 16)
	ui.text(ctx, shown, r.x + 8, mid + 8, t.small_size, t.text_tertiary)
	// A save just made says so with a tick after the status (feedback_motion.odin).
	draw_save_tick(app, {r.x + 8 + ui.text_width(ctx, shown, t.small_size) + 4, mid + 8}, t.small_size)
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

// The Search field's width, in points: room for its hint and its keys.
TOP_SEARCH_W :: 300

// The Search field (Settings > Interface > Top bar): a tap opens the command palette
// under it, as the icon does and Ctrl+K does.
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
