package main

import "core:fmt"
import "core:path/filepath"
import "core:time"

import "../ui"

// The Lens top bar, after the Sculpt Workspace Directions mockups: the menu, the file and
// whether it is saved, Undo and Redo at the left; the workspaces as a pill of segments in
// the middle; Search, History and Settings at the right. Home, Save, Import, Export and
// Help are in the menu, the passes on the pane. Returns the menu button and the Search
// field, which the menu and the command palette open under.
kit_top_bar_lens :: proc(app: ^App) -> (menu_anchor, search_anchor: ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	area := ui.safe_area(ctx)
	k.passes.chip_held = false
	ui.begin_anchored(ctx, "top bar", .Start, .Start, {0, 0}, {direction = .Row, width = area.w, height = TOP_BAR_H, padding = 2, gap = 2, center = true})
	// See-through, as the mockups' glass bar: the picture runs on under it, the frame's
	// colour over it at three quarters, and a faint light line along its foot.
	bar := ui.Rect{0, 0, ctx.input.window.x, area.y + TOP_BAR_H}
	ui.fill_rect(ctx, bar, 0, {t.frame.r, t.frame.g, t.frame.b, TOP_GLASS_ALPHA})
	ui.fill_rect(ctx, {bar.x, bar.y + bar.h - 1, bar.w, 1}, 0, {255, 255, 255, 15})
	ui.spacer(ctx, 6)
	if ui.icon_button(ctx, "Menu", ui.ICON_MENU, selected = k.menu) {
		k.menu = !k.menu
		k.menu_scroll = 0
	}
	menu_anchor = ctx.last_rect
	file_w := top_file_block(app)
	top_divider(ctx)
	undo := fmt.tprintf("Undo %s##undo", history_next_label(app.history.done[:]))
	redo := fmt.tprintf("Redo %s##redo", history_next_label(app.history.undone[:]))
	if ui.icon_button(ctx, undo, ui.ICON_UNDO, enabled = command_enabled(app, .Undo), keys = command_hint(app, .Undo)) do command_run(app, .Undo)
	if ui.icon_button(ctx, redo, ui.ICON_REDO, enabled = command_enabled(app, .Redo), keys = command_hint(app, .Redo)) do command_run(app, .Redo)
	// What the ends take, the middle gets: the pill where it fits, else the chip; Search
	// shrinks to its icon before the switcher goes to a chip.
	left := 6 + 3 * t.target + file_w + 13 + 2 * 4
	right := 2 * t.target + 12
	middle := area.w - left - right - TOP_SEARCH_W - 8
	pill := top_pill_width(app)
	field := middle >= pill + 24
	if !field do middle = area.w - left - right - t.target - 8
	// The switcher sits in the middle of the room left, laid out in the bar's row.
	if middle >= pill + 8 {
		pad := (middle - pill) * 0.5
		ui.spacer(ctx, pad)
		ui.spacer(ctx, max(middle - pad - top_workspace_pill(app), 0))
	} else if middle >= WORKSPACE_CHIP_ROOM {
		pad := (middle - WORKSPACE_CHIP_ROOM) * 0.5
		ui.spacer(ctx, pad)
		kit_workspace_chip(app)
		ui.spacer(ctx, max(middle - pad - ctx.last_rect.w, 0))
	} else {
		ui.spacer(ctx, max(middle, 0))
	}
	if field {
		search_anchor = top_search_field(app)
	} else {
		if ui.icon_button(ctx, "Search commands", ui.ICON_SEARCH, selected = k.palette, keys = command_hint(app, .Command_Palette)) {
			if k.palette do palette_close(app)
			else do palette_open(app)
		}
		search_anchor = ctx.last_rect
	}
	ui.spacer(ctx, 4)
	if ui.icon_button(ctx, "History", ui.ICON_HISTORY, selected = k.history) do k.history = !k.history
	_ = top_command(app, .Settings, ui.ICON_SETTINGS, "Settings", k.settings)
	ui.end(ctx)
	return
}

// The Search field's width, in points.
TOP_SEARCH_W :: 300
// How opaque the see-through top bar is, of 255.
TOP_GLASS_ALPHA :: 189

@(private = "file")
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
	r := ui.place(ctx, {13, 24})
	ui.fill_rect(ctx, {r.x + 6, r.y, 1, r.h}, 0, ctx.theme.border)
}

// The file the scene saves to over whether it is saved; returns its width.
@(private = "file")
top_file_block :: proc(app: ^App) -> f32 {
	ctx := &app.kit.ctx
	t := ctx.theme
	name := filepath.base(app.scene_path) if app.scene_path != "" else "Untitled"
	status := file_status(app, time.now())
	// As wide as its widest status line whatever it says now, so Undo and Redo stay put
	// when a stroke makes the scene unsaved.
	widest := max(ui.text_width(ctx, "Unsaved changes", t.small_size), ui.text_width(ctx, "Saved 59 min ago", t.small_size))
	w := min(max(ui.text_width(ctx, name, t.text_size, .Semibold), widest) + 16, 220)
	r := ui.place(ctx, {w, TOP_BAR_H - 8})
	mid := r.y + r.h * 0.5
	ui.text(ctx, ui.text_fit(ctx, name, t.text_size, w - 16, .Semibold), r.x + 8, mid - 8, t.text_size, t.text, .Semibold)
	ui.text(ctx, ui.text_fit(ctx, status, t.small_size, w - 16), r.x + 8, mid + 8, t.small_size, t.text_tertiary)
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

// The pill's segments, as tabs lay them out: each workspace in use, by slot.
@(private = "file")
top_pill_items :: proc(app: ^App) -> (names: []string, slots: []int) {
	k := &app.kit
	n := 0
	for ws in k.workspaces.list do if ws.used do n += 1
	names = make([]string, n, context.temp_allocator)
	slots = make([]int, n, context.temp_allocator)
	i := 0
	for ws, slot in k.workspaces.list {
		if !ws.used do continue
		names[i], slots[i] = workspace_name(k, slot), slot
		i += 1
	}
	return
}

// One segment's width in the pill, as ui.tabs sizes it.
@(private = "file")
top_segment_width :: proc(ctx: ^ui.Context, name: string) -> f32 {
	return ui.text_width(ctx, name, ctx.theme.text_size, .Semibold) + 28
}

// The pill's width: its segments in their well, then "+".
top_pill_width :: proc(app: ^App) -> f32 {
	ctx := &app.kit.ctx
	names, _ := top_pill_items(app)
	w: f32 = 2 * 3 + ctx.theme.control
	for name in names do w += top_segment_width(ctx, name)
	return w
}

// The workspace switcher as a pill: a tap on a segment switches to that
// workspace (Ctrl+1 to 4 do too), a tap on the current one or on "+" opens the switcher's
// menu (save, save as new, export, import, revert, reset, rename, delete). The current one
// carries the amber dot while its layout differs from the saved one. Returns its width.
@(private = "file")
top_workspace_pill :: proc(app: ^App) -> f32 {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	w := &k.workspaces
	names, slots := top_pill_items(app)
	chosen := 0
	for slot, i in slots do if slot == w.current do chosen = i
	keys := make([]string, len(slots), context.temp_allocator)
	for slot, i in slots do keys[i] = command_hint(app, .Workspace, slot)
	ui.begin(ctx, "workspace pill", {direction = .Row, center = true, background = .Track, radius = t.radius_medium + 1.5})
	start := ctx.last_rect.x
	picked := ui.tabs(ctx, "Workspaces", names, chosen, keys = keys)
	// The last segment: the segments' height and where they stand.
	seg := ctx.last_rect
	if picked >= 0 {
		if slots[picked] == w.current {
			was := w.menu
			kit_floats_close(k)
			w.menu = !was
		} else {
			command_run(app, .Workspace, slots[picked])
		}
	}
	// The amber dot on the current segment, right of its name.
	x := start + 3
	for name, i in names {
		sw := top_segment_width(ctx, name)
		if i == chosen && w.modified do ui.fill_circle(ctx, {x + sw - 9, seg.y + seg.h * 0.5}, 3, t.warning)
		if i == chosen do w.menu_at = {x, seg.y, sw, seg.h}
		x += sw
	}
	if ui.icon_button(ctx, "Workspace options", ICON_PLUS_SMALL, selected = w.menu, size = t.control) {
		was := w.menu
		kit_floats_close(k)
		w.menu = !was
		w.menu_at = ctx.last_rect
	}
	plus := ctx.last_rect
	ui.end(ctx)
	return plus.x + plus.w - start
}

// Lucide's plus, for the pill's "+".
ICON_PLUS_SMALL :: rune(0xe141)

// The Search field: a tap opens the command palette under it (Ctrl+K does too).
@(private = "file")
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
