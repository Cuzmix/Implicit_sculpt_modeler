package main

import "core:fmt"
import "core:path/filepath"

import "../render"
import "../ui"

// The Home screen: a page over the whole window, as a tablet sculpting app's home, with
// the new scene starters down one side and the scenes to go back to as pictures beside
// them: Recent, the scenes saved or opened lately (each picture read from the start of
// its file, as a desktop modeller's splash shows its recent files), and Autosaves, the
// newest autosave of each earlier session. A tap opens; with work to lose, a first tap
// arms the tile and a second opens it, as Earlier saves does. A long press (or a
// right-click) offers to take a scene off Recent or delete an autosave. Escape, Back or
// the close button go back to the scene. It owns nothing of the scene: opening is a file
// request and a new scene a command, both run at the next frame.

// The clay the starters' balls are drawn in.
@(private = "file")
HOME_CLAY :: ui.Color{196, 190, 182, 255}

// The new scene tiles' glyphs, in NEW_SCENE_SHAPES' order: Lucide's circle, user-round,
// user, person-standing, hand and cat.
@(rodata)
HOME_SHAPE_GLYPHS := [len(NEW_SCENE_SHAPES)]rune{0xe07a, 0xe46d, 0xe19f, 0xe21e, 0xe1d7, 0xe390}

ICON_HOME :: rune(0xe0f8) // house
@(private = "file")
ICON_FILE_GONE :: rune(0xe0d1) // file-x

// A scene tile's picture is at least this wide and at most that, in points.
@(private = "file")
HOME_TILE_MIN :: 200
@(private = "file")
HOME_TILE_MAX :: 280
@(private = "file")
HOME_GAP :: 12
// The new scene column on a wide window, and the width under which the page stacks.
@(private = "file")
HOME_SIDE_W :: 236
@(private = "file")
HOME_WIDE :: 700

kit_home :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	win := ctx.input.window
	area := ui.safe_area(ctx)
	PAD :: 20
	// One root over the whole window, so no press reaches the viewport under it.
	ui.begin_at(ctx, "home", {0, 0}, {direction = .Row, width = win.x, height = win.y})
	owner := ui.id_of(ctx, "home")
	ui.fill_rect(ctx, {0, 0, win.x, win.y}, 0, ctx.theme.frame)
	ui.spacer(ctx, area.x + PAD)
	width := area.w - 2 * PAD
	ui.begin(ctx, "home page", {direction = .Column, gap = 14, width = width, height = area.y + area.h})
	ui.spacer(ctx, area.y + 8)

	// The heading, and the way back to the scene at the far end.
	ui.begin(ctx, "home head", {direction = .Row, center = true, width = width, height = t.target})
	title := ui.place(ctx, {width - t.target, t.target})
	ui.text(ctx, "Home", title.x, title.y + title.h * 0.5, t.heading_size, t.text, .Semibold)
	if ui.icon_button(ctx, "Back to the scene", ui.ICON_CLOSE, keys = "Esc") do home_close(app)
	ui.end(ctx)

	room := area.y + area.h - (ctx.last_rect.y + ctx.last_rect.h) - 14 - PAD
	if width >= HOME_WIDE {
		ui.begin(ctx, "home columns", {direction = .Row, gap = 28})
		ui.begin(ctx, "home new", {direction = .Column, gap = 8, width = HOME_SIDE_W})
		home_new_section(app, HOME_SIDE_W, 2)
		ui.end(ctx)
		right := width - HOME_SIDE_W - 28
		ui.begin(ctx, "home scenes", {direction = .Column, gap = 10, width = right})
		home_tabs(app, right)
		scroll := kit_scroll_begin(ctx, "home grid", &k.home_scroll, owner, right - 10, room - t.target - 10, HOME_GAP)
		home_grid(app, right - 10)
		kit_scroll_end(ctx, scroll)
		ui.end(ctx)
		ui.end(ctx)
	} else {
		// Narrow (a phone, a tablet's split view): one column that scrolls as a whole.
		scroll := kit_scroll_begin(ctx, "home grid", &k.home_scroll, owner, width - 10, room, HOME_GAP)
		home_new_section(app, width - 10, 3)
		ui.spacer(ctx, 6)
		home_tabs(app, width - 10)
		home_grid(app, width - 10)
		kit_scroll_end(ctx, scroll)
	}
	ui.end(ctx)
	ui.end(ctx)
	kit_home_menu(app)
}

// The new scene starters, `per_row` to a row, and Open a file `width` wide.
@(private = "file")
home_new_section :: proc(app: ^App, width: f32, per_row: int) {
	k := &app.kit
	ctx := &k.ctx
	ui.caption(ctx, "NEW SCENE")
	for i in 0 ..< len(NEW_SCENE_SHAPES) {
		if i % per_row == 0 do ui.begin(ctx, fmt.tprintf("home new row %d", i / per_row), {direction = .Row, gap = 4})
		// A first tap with work to lose arms it, and its name asks.
		armed := new_scene_armed(app, i)
		name := fmt.tprint(NEW_SCENE_SHAPES[i])
		if ui.preview_tile(ctx, fmt.tprintf("%s##home new %d", "Discard?" if armed else name, i), HOME_SHAPE_GLYPHS[i], HOME_CLAY, armed).clicked {
			command_run(app, .New_Scene, i)
			if !new_scene_armed(app, i) do home_close(app)
		}
		if i % per_row == per_row - 1 || i == len(NEW_SCENE_SHAPES) - 1 do ui.end(ctx)
	}
	ui.spacer(ctx, 4)
	if command_button(app, .Open_Scene, label = "Open a file...", glyph = ui.ICON_OPEN, width = width) do home_close(app)
}

@(private = "file")
home_tabs :: proc(app: ^App, width: f32) {
	k := &app.kit
	names := [len(Home_Tab)]string{"Recent", "Autosaves"}
	if picked := ui.tabs(&k.ctx, "Home tab", names[:], int(k.home_tab), item_width = min(width * 0.5, 150)); picked >= 0 && Home_Tab(picked) != k.home_tab {
		k.home_tab, k.home_scroll, k.home_armed = Home_Tab(picked), 0, 0
	}
}

// The chosen tab's scenes as tiles, as many to a row as fit `width`.
@(private = "file")
home_grid :: proc(app: ^App, width: f32) {
	k := &app.kit
	ctx := &k.ctx
	h := &app.home
	n := len(app.recent_scenes) if k.home_tab == .Recent else len(h.autosaves)
	if n == 0 {
		switch {
		case k.home_tab == .Recent:
			ui.paragraph(ctx, "Scenes you save or open show here, with a picture of each as it was saved.", width)
		case !app.autosave.on:
			ui.paragraph(ctx, "This run keeps no autosaves.", width)
		case:
			ui.paragraph(ctx, "The newest autosave of each earlier session shows here: the last few that closed, and any that ended unexpectedly.", width)
		}
		return
	}
	cols := max(int((width + HOME_GAP) / (HOME_TILE_MIN + HOME_GAP)), 1)
	tw := min((width - HOME_GAP * f32(cols - 1)) / f32(cols), HOME_TILE_MAX)
	for i in 0 ..< n {
		if i % cols == 0 do ui.begin(ctx, fmt.tprintf("home grid row %d", i / cols), {direction = .Row, gap = HOME_GAP})
		home_scene_tile(app, i, tw)
		if i % cols == cols - 1 || i == n - 1 do ui.end(ctx)
	}
}

// When a scene was saved, short enough to share a tile's line with its size (or a row
// of the Lens menu's Open recent).
home_when :: proc(at: i64) -> string {
	s := max(unix_now() - at, 0)
	switch {
	case s < 60:        return "Just now"
	case s < 3600:      return fmt.tprintf("%d min ago", s / 60)
	case s < 86400:     return fmt.tprintf("%d h ago", s / 3600)
	case s < 2 * 86400: return "Yesterday"
	}
	return fmt.tprintf("%d days ago", s / 86400)
}

// Whether opening another scene would lose work: the same test the top bar's star makes.
home_work_to_lose :: proc(app: ^App) -> bool {
	return scene_unsaved(app) && (app.scene_path != "" || scene_has_work(app))
}

@(private = "file")
home_armed :: proc(app: ^App, i: int) -> bool {
	k := &app.kit
	return k.home_armed == i + 1 && k.ctx.time - k.home_armed_at < NEW_SCENE_ARM_TIME
}

// The tab's scene `i` as a tile `tw` wide: its picture, its name and when it was saved.
@(private = "file")
home_scene_tile :: proc(app: ^App, i: int, tw: f32) {
	k := &app.kit
	ctx := &k.ctx
	h := &app.home
	recent := k.home_tab == .Recent
	path, name, line := "", "", ""
	crashed := false
	if recent {
		path = app.recent_scenes[i]
		name = filepath.stem(path)
	} else {
		e := h.autosaves[i]
		path, crashed = e.path, e.crashed
		name = fmt.tprintf("Autosave of %s", filepath.base(e.scene)) if e.scene != "" else "Autosave of an unsaved scene"
		line = home_when(e.at)
	}
	tile := home_tile(app, path)
	current := recent && path == app.scene_path
	armed := home_armed(app, i)
	switch {
	case tile.state == .Missing:
		line = "Not found"
	case recent && tile.info.saved > 0:
		line = fmt.tprintf("%s · %s vertices", home_when(tile.info.saved), count_label(tile.info.vertices))
	case recent && tile.state == .None:
		line = "Saved before scenes kept a picture"
	}
	if current do line = "Open now"
	if crashed do line = fmt.tprintf("%s · did not close", line)

	pic := ui.Picture{glyph = ui.ICON_IMAGE}
	switch tile.state {
	case .Shown:
		pic.lo, pic.hi = render.picture_uv(tile.cell, tile.w, tile.h)
		pic.image, pic.aspect = KIT_PICTURES_IMAGE, f32(tile.w) / f32(tile.h)
	case .Missing:
		pic.glyph = ICON_FILE_GONE
	case .None, .Waiting, .Asked:
	}
	ring := ui.Tile_Ring.Danger if armed else (.Accent if current else .Hairline)
	res := ui.picture_tile(ctx, fmt.tprintf("%s##home tile %s", path, path), tw, pic, name, line, k.ctx.theme.warning if crashed else {}, ring, "Discard changes and open?" if armed else "", tile.state == .Missing)
	clicked, menu := res.clicked, res.menu
	if menu {
		k.home_menu, k.home_menu_at, k.home_menu_item, k.home_menu_armed = true, res.picture, i, false
		return
	}
	if !clicked do return
	switch {
	case current:
		home_close(app)
	case recent && tile.state == .Missing:
		report(app, nil, {.Warning}, "%s is gone: it is off Recent now", filepath.base(path))
		recent_scene_drop(app, path)
	case home_work_to_lose(app) && !armed:
		k.home_armed, k.home_armed_at = i + 1, max(ctx.time, 1e-6)
	case recent:
		file_post(.Open, path)
		home_close(app)
	case:
		file_post(.Recover, h.autosaves[i].session)
		home_close(app)
	}
}

// A tile's long press menu: Remove from Recent, or Delete for an autosave after a second
// tap, since it cannot be undone.
@(private = "file")
kit_home_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	h := &app.home
	if !ui.popover_begin(ctx, "home menu", &k.home_menu, k.home_menu_at, .Below, {direction = .Column, padding = 6, width = 240}) do return
	i := k.home_menu_item
	if k.home_tab == .Recent && i < len(app.recent_scenes) {
		if ui.menu_item(ctx, "Remove from Recent", glyph = ui.ICON_CLOSE) {
			recent_scene_drop(app, app.recent_scenes[i])
			k.home_menu = false
		}
		ui.paragraph(ctx, "The file stays where it is.")
	} else if k.home_tab == .Autosaves && i < len(h.autosaves) {
		label := "Tap again to delete" if k.home_menu_armed else "Delete this autosave"
		if ui.menu_item(ctx, label, glyph = ui.ICON_TRASH, tone = .Danger) {
			if k.home_menu_armed {
				file_post(.Discard_Autosave, h.autosaves[i].session)
				e := h.autosaves[i]
				delete(e.session)
				delete(e.path)
				delete(e.scene)
				ordered_remove(&h.autosaves, i)
				k.home_menu = false
			} else {
				k.home_menu_armed = true
			}
		}
	} else {
		k.home_menu = false
	}
	ui.popover_end(ctx)
}
