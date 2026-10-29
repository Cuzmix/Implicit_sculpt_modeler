package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:time"

import "../ui"

// The Lens menu (round 2 of the mockups, screen menu2): one list of what is done to the
// scene's file and the app, in the order a file menu has it, with the rest behind rows
// that open a submenu beside the list. A tap on such a row opens its submenu, a second
// tap closes it; with a mouse, resting on the row opens it too, as desktop menus do. A
// press outside both closes both.

Lens_Submenu :: enum u8 {
	None,
	Main, // not a submenu: the list itself, for palette_where
	New,
	Recent,
	Import,
	Export,
	Workspaces,
	More,
}

@(rodata)
LENS_SUBMENU_NAMES := [Lens_Submenu]string {
	.None       = "",
	.Main       = "",
	.New        = "New",
	.Recent     = "Open recent",
	.Import     = "Import",
	.Export     = "Export...",
	.Workspaces = "Workspaces",
	.More       = "More",
}

// Where each command is in the Lens menu, which search shows as where it lives
// (palette_where); kit_menu_lens draws the same rows.
@(rodata)
LENS_MENU_PLACE := #partial [Command_Id]Lens_Submenu {
	.Home                   = .Main,
	.Open_Scene             = .Main,
	.Save_Scene             = .Main,
	.Save_Scene_As          = .Main,
	.Save_Scene_Copy        = .Main,
	.Scene_Versions         = .Main,
	.Export_Sheet           = .Main,
	.Customise_Bars         = .Main,
	.Settings               = .Main,
	.Help                   = .Main,
	.New_Scene              = .New,
	.Open_Last_Autosave     = .Recent,
	.Import_Mesh            = .Import,
	.Get_From_Blender       = .Import,
	.Workspace_Import       = .Import,
	// The Export sheet holds these, under Menu > Export....
	.Export_Mesh            = .Export,
	.Screenshot             = .Export,
	.Screenshot_Transparent = .Export,
	.Record_Turntable       = .Export,
	.Export_Print           = .Export,
	.Send_To_Blender        = .More,
	.Workspace_Export       = .Workspaces,
	.Workspace              = .Workspaces,
	.Stats                  = .More,
	.Macros                 = .More,
	.Library                = .More,
	.Reduce_Motion          = .More,
}

// How long a mouse rests on a submenu's row before the submenu opens, in seconds.
MENU_REST :: 0.25

// The menu's and its submenus' widths, in points.
LENS_MENU_W :: 264
LENS_SUBMENU_W :: 264

// The menu under the menu button, and the submenu open beside it.
kit_menu_lens :: proc(app: ^App, anchor: ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	if !k.menu do k.menu_sub = .None
	owner := ui.id_of(ctx, "menu")
	if !ui.popover_begin(ctx, "menu", &k.menu, anchor, .Below, {direction = .Column, padding = 6, width = LENS_MENU_W}) do return
	// On a short window the list scrolls rather than running off the bottom.
	area := ui.safe_area(ctx)
	room := max(area.y + area.h - (anchor.y + anchor.h + 6) - 4 - 2 * 6, 4 * ctx.theme.target)
	_, natural := ui.prev_layout(ctx, "menu body")
	body_w := LENS_MENU_W - 2 * 6 - (f32(10) if natural.y > room else 0)
	scroll := kit_scroll_begin(ctx, "menu body", &k.menu_scroll, owner, body_w, room, 0)
	pick := false
	if command_menu_item(app, .Home) do pick = true
	ui.divider(ctx, across = true)
	lens_sub_row(app, .New, ui.ICON_PLUS)
	if command_menu_item(app, .Open_Scene) do pick = true
	lens_sub_row(app, .Recent, ui.ICON_HISTORY)
	for id in ([?]Command_Id{.Save_Scene, .Save_Scene_As, .Save_Scene_Copy, .Scene_Versions}) {
		if command_menu_item(app, id) do pick = true
	}
	ui.divider(ctx, across = true)
	lens_sub_row(app, .Import, ui.ICON_IMPORT)
	// One sheet for every way out (lens_export.odin), as round 2's export2 screen.
	if command_menu_item(app, .Export_Sheet) do pick = true
	ui.divider(ctx, across = true)
	lens_sub_row(app, .Workspaces, ui.ICON_PANEL)
	if command_menu_item(app, .Customise_Bars, label = "Customise...") do pick = true
	if command_menu_item(app, .Settings) do pick = true
	if command_menu_item(app, .Help, int(Help_Tab.Keys), "Help and shortcuts") do pick = true
	lens_sub_row(app, .More, ui.ICON_MORE)
	kit_scroll_end(ctx, scroll)
	ui.popover_end(ctx)
	if pick do k.menu = false
	if !k.menu do k.menu_sub = .None
	kit_submenu(app)
}

// A row that opens submenu `sub` beside the list: its icon, its name and a chevron, lit
// while the submenu shows.
@(private = "file")
lens_sub_row :: proc(app: ^App, sub: Lens_Submenu, glyph: rune) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	open := k.menu_sub == sub
	clicked := ui.menu_item(ctx, fmt.tprintf("%s##menu sub", LENS_SUBMENU_NAMES[sub]), glyph = glyph, highlight = open)
	r := ctx.last_rect
	ui.icon(ctx, ui.ICON_CHEVRON_RIGHT, {r.x + r.w - 10 - t.icon_small * 0.5, r.y + r.h * 0.5}, t.icon_small, t.text_tertiary)
	if open do k.menu_sub_at = r
	if clicked {
		lens_sub_open(app, .None if open else sub, r)
		return
	}
	// A mouse resting on the row opens it; a finger or a pen taps.
	m := ctx.input.mouse
	if ctx.input.pointer != .Mouse || !ctx.input.mouse_valid || !ui.rect_contains(r, m) || open do return
	if k.menu_rest_on != sub {
		k.menu_rest_on, k.menu_rest_since = sub, ctx.time
	} else if ctx.time - k.menu_rest_since >= MENU_REST {
		lens_sub_open(app, sub, r)
	}
}

// Opens submenu `sub` beside row `r`, or closes the one open with None.
lens_sub_open :: proc(app: ^App, sub: Lens_Submenu, r: ui.Rect) {
	k := &app.kit
	k.menu_sub, k.menu_sub_at, k.menu_rest_on = sub, r, .None
	if sub != .None do k.menu_subs += 1
}

// The submenu open beside the menu: what its row names.
@(private = "file")
kit_submenu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	if k.menu_sub == .None || k.menu_sub == .Main do return
	open := true
	sub := k.menu_sub
	if !ui.popover_begin(ctx, fmt.tprintf("menu sub %v", sub), &open, k.menu_sub_at, .Right, {direction = .Column, padding = 6, width = LENS_SUBMENU_W}) do return
	pick := false
	switch sub {
	case .None, .Main:
	case .New:
		ui.caption(ctx, "  NEW SCENE")
		pick = menu_new_scenes(app, LENS_SUBMENU_W - 2 * 6)
	case .Recent:
		pick = lens_recent_list(app)
		ui.divider(ctx, across = true)
		if command_menu_item(app, .Open_Last_Autosave) do pick = true
	case .Import:
		if command_menu_item(app, .Import_Mesh) do pick = true
		if LINK_AVAILABLE && command_menu_item(app, .Get_From_Blender) do pick = true
		if command_menu_item(app, .Workspace_Import) do pick = true
	case .Export:
		// Not a submenu: the Export sheet holds what it held.
	case .Workspaces:
		ui.caption(ctx, "  WORKSPACES")
		w := &k.workspaces
		for ws, slot in w.list {
			if !ws.used do continue
			if command_menu_item(app, .Workspace, slot, label = fmt.tprintf("%s##menu workspace %d", workspace_name(k, slot), slot)) do pick = true
		}
		ui.divider(ctx, across = true)
		if command_menu_item(app, .Workspace_Export) do pick = true
		if ui.menu_item(ctx, "Workspace options...", glyph = ui.ICON_SETTINGS) {
			// The switcher's own menu opens where the switcher is, after this one closes.
			at := w.menu_at
			kit_floats_close(k)
			w.menu, w.menu_at = true, at
			menu_close_all(app)
			ui.popover_end(ctx)
			return
		}
	case .More:
		if LINK_AVAILABLE && command_menu_item(app, .Send_To_Blender) do pick = true
		// The menu stays open over the two that switch something on or off.
		_ = command_menu_item(app, .Stats)
		if command_menu_item(app, .Macros) do pick = true
		if command_menu_item(app, .Library) do pick = true
		_ = command_menu_item(app, .Reduce_Motion)
	}
	ui.popover_end(ctx)
	if !open do k.menu_sub = .None
	if pick do menu_close_all(app)
}

// Closes the menu and its submenu, as a pick in either does.
@(private = "file")
menu_close_all :: proc(app: ^App) {
	app.kit.menu, app.kit.menu_sub = false, .None
}

// The most recent scenes the submenu lists.
MENU_RECENT_MAX :: 8

// The recent scenes, newest first, each with when it was saved. A tap opens one as Home's
// tile does: the scene open now just closes the menu, a file gone leaves Recent with a
// note, and a scene with work to lose asks first ("Discard changes and open?"), opening on
// a second tap. Returns whether a row was picked.
@(private = "file")
lens_recent_list :: proc(app: ^App) -> (pick: bool) {
	k := &app.kit
	ctx := &k.ctx
	ui.caption(ctx, "  RECENT")
	if len(app.recent_scenes) == 0 {
		ui.paragraph(ctx, "Scenes you save or open show here.")
		return
	}
	n := min(len(app.recent_scenes), MENU_RECENT_MAX)
	for i in 0 ..< n {
		path := app.recent_scenes[i]
		armed := k.menu_recent_armed == i + 1 && ctx.time - k.menu_recent_armed_at < NEW_SCENE_ARM_TIME
		when_text := "Open now" if path == app.scene_path else ""
		missing := false
		if when_text == "" {
			if saved, err := os.modification_time_by_path(path); err == nil {
				when_text = home_when(time.time_to_unix(saved))
			} else {
				when_text, missing = "Not found", true
			}
		}
		label := "Discard changes and open?" if armed else filepath.base(path)
		if !ui.menu_item(ctx, fmt.tprintf("%s##menu recent %d", label, i), when_text, ICON_OBJECT_BOX, tone = .Danger if armed else .Neutral, keys_muted = missing) do continue
		switch {
		case path == app.scene_path:
			pick = true
		case missing:
			report(app, nil, {.Warning}, "%s is gone: it is off Recent now", filepath.base(path))
			recent_scene_drop(app, path)
			return
		case home_work_to_lose(app) && !armed:
			k.menu_recent_armed, k.menu_recent_armed_at = i + 1, max(ctx.time, 1e-6)
		case:
			file_post(.Open, path)
			k.menu_recent_opens += 1
			pick = true
		}
	}
	return
}
