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
// the rest. Returns the menu button and the Search button, which the menu and the command
// palette open under.
kit_top_bar :: proc(app: ^App) -> (menu_anchor, search_anchor: ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	area := ui.safe_area(ctx)
	k.passes.chip_held = false
	k.object_chip_fit = .None
	k.chip_at = {}
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
	// Arranging keeps the one bar, whose middle holds what arranging needs.
	// Focus is always the three islands, its middle the workspace and X symmetry.
	if lens_focus(k) && !arranging do return kit_top_three(app, in_bar, width, focus = true)
	if k.top_islands && !arranging {
		menu_anchor, search_anchor = kit_top_three(app, in_bar, width)
		for s in Chip_Section do if in_bar[s] && k.chip_at[s].w > 0 do k.chip_home[s] = k.chip_at[s]
		kit_chip_islands(app, &menu_anchor, &search_anchor)
		return
	}
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
	// What the ends take, the middle gets. Search is an icon (the palette it opens has its
	// own field), so the object chip gives up its badges, then its tag, then shrinks to
	// its icon, and last the space tabs go to the layout's chip. With Settings' Search as
	// a field, the field stays while the chip keeps at least its name, and shrinks to the
	// icon before the chip gives up more.
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
	fit := Object_Chip_Fit.None
	field := false
	if k.search_field && in_bar[.Search] {
		if !arranging {
			with_field := middle - TOP_SEARCH_W - tabs - tab_div - chip_div
			switch {
			case !in_bar[.Object]:
				field = with_field >= 0
			case object_chip_fit(ctx, chip, with_field) >= .Name:
				field, fit = true, object_chip_fit(ctx, chip, with_field)
			}
		} else {
			field = middle - arrange_top_width(app) >= TOP_SEARCH_W + 24
		}
	}
	if in_bar[.Search] do middle -= TOP_SEARCH_W if field else t.target
	if !arranging && in_bar[.Object] && !field do fit = object_chip_fit(ctx, chip, middle - tabs - tab_div - chip_div)
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

// The room kept between two islands of the top bar, in points.
TOP_ISLAND_GAP :: 8
// The padding inside an island and the gap between its items, in points.
TOP_ISLAND_PAD :: 2

// What the three islands show, from everything down to the least that still works.
@(private = "file")
Top_Three :: struct {
	focus: bool, // Focus's middle (workspace, X symmetry) and View layout and Passes at the right
	file:  bool, // the file block after the menu button
	field: bool, // Search as its field rather than its icon
	tabs:  int, // the space tabs (0), the layout's chip (1) or neither (2)
	fit:   Object_Chip_Fit,
}

// The top bar as three islands (Settings > Interface > Top bar): the menu, the file and
// Undo and Redo at the left; the spaces and the object chip centred on the window; Search,
// History and Settings at the right. One full-width row holds them, so a control's name
// stays "top bar/..." and a section dragged in Arrange goes back by the same rectangle.
// When the sides would reach the middle island, parts give way in a fixed order (the
// chip's badges, Search's field, the chip's tag, the file block, the tabs to the layout's
// chip, the chip to its icon), and only then does the middle leave the centre.
@(private = "file")
kit_top_three :: proc(app: ^App, in_bar: [Chip_Section]bool, width: f32, focus := false) -> (menu_anchor, search_anchor: ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	chip := object_chip_of(app)
	file_w := top_file_width(app)
	// An island's width: its items, the gaps between them and its padding.
	island_w :: proc(items: []f32) -> f32 {
		w: f32 = 0
		n := 0
		for x in items do if x > 0 {
			w += x
			n += 1
		}
		return 0 if n == 0 else w + f32(n - 1) * TOP_ISLAND_PAD + 2 * TOP_ISLAND_PAD
	}
	left_w :: proc(app: ^App, in_bar: [Chip_Section]bool, v: Top_Three, file_w: f32) -> f32 {
		t := app.kit.ctx.theme
		return island_w({t.target if in_bar[.Menu] else 0, file_w if in_bar[.Menu] && v.file else 0, TOP_DIVIDER_W if in_bar[.Menu] && in_bar[.Undo] else 0, 2 * t.target + TOP_ISLAND_PAD if in_bar[.Undo] else 0})
	}
	right_w :: proc(app: ^App, in_bar: [Chip_Section]bool, v: Top_Three) -> f32 {
		t := app.kit.ctx.theme
		search: f32 = 0
		if in_bar[.Search] do search = TOP_SEARCH_W if v.field else t.target
		// Focus, with no view bar, keeps View layout and Passes here.
		view: f32 = TOP_DIVIDER_W + 2 * t.target + TOP_ISLAND_PAD if v.focus else 0
		return island_w({search, view, TOP_DIVIDER_W if in_bar[.Search] && in_bar[.End] else 0, 2 * t.target + TOP_ISLAND_PAD if in_bar[.End] else 0})
	}
	middle_w :: proc(app: ^App, in_bar: [Chip_Section]bool, v: Top_Three, chip: Object_Chip) -> f32 {
		ctx := &app.kit.ctx
		tabs: f32 = 0
		if in_bar[.Spaces] && v.tabs == 0 do tabs = space_tabs_width(app)
		if in_bar[.Spaces] && v.tabs == 1 do tabs = WORKSPACE_CHIP_ROOM
		obj: f32 = object_chip_width(ctx, chip, v.fit) if in_bar[.Object] else 0
		if v.focus do return island_w({WORKSPACE_CHIP_ROOM, FOCUS_SYMMETRY_W})
		return island_w({tabs, TOP_DIVIDER_W if tabs > 0 && obj > 0 else 0, obj})
	}
	v := Top_Three {
		focus = focus,
		file  = !focus,
		field = k.search_field && in_bar[.Search],
		tabs  = 0 if in_bar[.Spaces] else 2,
		fit   = .Full if in_bar[.Object] else .None,
	}
	fits :: proc(app: ^App, in_bar: [Chip_Section]bool, v: Top_Three, chip: Object_Chip, file_w, width: f32) -> bool {
		side := max(left_w(app, in_bar, v, file_w), right_w(app, in_bar, v))
		return middle_w(app, in_bar, v, chip) <= width - 2 * (side + TOP_ISLAND_GAP)
	}
	for step in 0 ..< 6 {
		if fits(app, in_bar, v, chip, file_w, width) do break
		switch step {
		case 0: if v.fit > .Tag do v.fit = .Tag
		case 1: v.field = false
		case 2: if v.fit > .Name do v.fit = .Name
		case 3: v.file = false
		case 4: if v.tabs == 0 do v.tabs = 1
		case 5: if v.fit > .Icon do v.fit = .Icon
		}
	}
	l, r := left_w(app, in_bar, v, file_w), right_w(app, in_bar, v)
	// Off centre at last: the middle takes what the sides leave, and gives up the layout's
	// chip, then shrinks the object chip, before anything overlaps.
	room := width - l - r - 2 * TOP_ISLAND_GAP
	if middle_w(app, in_bar, v, chip) > room {
		v.tabs = 2
		if in_bar[.Object] do v.fit = object_chip_fit(ctx, chip, room - 2 * TOP_ISLAND_PAD)
	}
	m := middle_w(app, in_bar, v, chip)
	h: f32 = TOP_BAR_H - TOP_BAR_TOP
	island := ui.Box{direction = .Row, height = h, padding = TOP_ISLAND_PAD, gap = TOP_ISLAND_PAD, center = true, radius = t.radius_large, background = .Panel}
	ui.begin_anchored(ctx, "top bar", .Start, .Start, {TOP_BAR_INSET, TOP_BAR_TOP}, {direction = .Row, width = width, height = h, center = true})
	// The islands as drawn last frame, so the middle sits on the centre to the point; the
	// sums above stand in on the first frame and when what shows changes.
	// Focus's middle holds chips whose widths the sums only guess, so it takes last
	// frame's width whenever there is one.
	drawn :: proc(ctx: ^ui.Context, name: string, sum: f32, trust := false) -> f32 {
		size, _ := ui.prev_layout(ctx, name)
		return size.x if size.x > 0 && (trust || abs(size.x - sum) < 24) else sum
	}
	used: f32 = 0
	if l > 0 {
		lw := drawn(ctx, "file island", l)
		ui.begin(ctx, "file island", island)
		if in_bar[.Menu] do k.chip_at[.Menu] = chip_section_draw(app, .Menu, &menu_anchor, &search_anchor, file = v.file)
		if in_bar[.Menu] && in_bar[.Undo] do top_divider(ctx)
		if in_bar[.Undo] do k.chip_at[.Undo] = chip_section_draw(app, .Undo, &menu_anchor, &search_anchor)
		ui.end(ctx)
		used = lw
	}
	if m > 0 {
		mw := drawn(ctx, "work island", m, trust = v.focus)
		at := clamp((width - mw) * 0.5, used + TOP_ISLAND_GAP, max(width - r - TOP_ISLAND_GAP - mw, used + TOP_ISLAND_GAP))
		ui.spacer(ctx, at - used)
		ui.begin(ctx, "work island", island)
		if v.focus do top_focus_middle(app)
		else if v.tabs == 0 do k.chip_at[.Spaces] = chip_section_draw(app, .Spaces, &menu_anchor, &search_anchor)
		if v.tabs == 1 do kit_workspace_chip(app)
		if !v.focus && v.tabs < 2 && v.fit != .None do top_divider(ctx)
		if !v.focus && v.fit != .None do k.chip_at[.Object] = chip_section_draw(app, .Object, &menu_anchor, &search_anchor, fit = v.fit)
		ui.end(ctx)
		used = at + mw
	}
	if r > 0 {
		rw := drawn(ctx, "app island", r)
		ui.spacer(ctx, max(width - rw - used, 0))
		ui.begin(ctx, "app island", island)
		if in_bar[.Search] do k.chip_at[.Search] = chip_section_draw(app, .Search, &menu_anchor, &search_anchor, field = v.field)
		if v.focus do top_focus_view(app)
		if in_bar[.Search] && in_bar[.End] do top_divider(ctx)
		if in_bar[.End] do k.chip_at[.End] = chip_section_draw(app, .End, &menu_anchor, &search_anchor)
		ui.end(ctx)
	}
	ui.end(ctx)
	return
}

// Whether the layout is focused: its workspace hides the view bar, as the built-in
// Focus does (screen focus2). The top bar is then three islands over the view, and the
// view's chips, the rail and the shelf's page names stand aside.
lens_focus :: proc(k: ^Kit_State) -> bool {
	return zone_hidden(k, .View_Bar)
}

// The width the X symmetry chip takes in Focus's middle island, in points.
FOCUS_SYMMETRY_W :: 64

// Focus's middle island: the workspace (its chip opens the switcher's menu) and X symmetry.
@(private = "file")
top_focus_middle :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	kit_workspace_chip(app)
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
	if ui.icon_button(ctx, "Passes", ICON_PASSES, selected = k.passes.menu, keys = command_hint(app, .Pass_Menu)) {
		k.passes.menu_at, k.passes.menu_side = ctx.last_rect, .Below
		pass_menu_toggle(app)
	}
	k.passes.menu_at, k.passes.menu_side = ctx.last_rect, .Below
}

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
