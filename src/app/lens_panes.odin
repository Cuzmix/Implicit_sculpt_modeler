package main

import "core:fmt"

import "../render"
import "../ui"

// Split views in Lens (round 2 of the mockups, screen split2): each view pane's head as the
// main pane's chips (its camera with its colour dot, its pass, Link and Maximise), each
// divider with a grip a finger finds (a double tap evens it out, a drag to the window's
// edge closes the panes it squeezes there), the View layout menu as the six presets drawn,
// with what new panes start as and the proportion guides, and, while there are panes
// beside the main one, the panel stack shrunk to a strip of tabs beside the rail so it
// covers none of them, each tab opening its card over the view.

// What a pane a layout adds starts as: the partner the preset has always given it (the
// front, the side, the top), the main camera itself (linked), or the main view as it is
// now, to turn on its own.
New_Panes :: enum u8 {
	Front_Side,
	Same_Camera,
	Copy_View,
}

@(rodata)
NEW_PANES_NAMES := [New_Panes]string {
	.Front_Side  = "Front + Side",
	.Same_Camera = "Same camera",
	.Copy_View   = "Copy view",
}

// A view pane's camera or pass list, opened from its chip.
Pane_Menu_Kind :: enum u8 {
	Camera,
	Pass,
	Add, // the kinds of tab New tab adds
	Map, // a Texture tab's maps
}

Pane_Menu :: struct {
	open: bool,
	pane: int, // the view pane, 1 to 3
	kind: Pane_Menu_Kind,
	at:   ui.Rect,
}

// The last tap on a handle that a double tap acts on, and when it was.
Handle_Tap :: struct {
	id: ui.Id,
	at: f64,
}

// Two taps on the same handle closer together than this, in seconds, are a double tap.
HANDLE_DOUBLE_TAP :: 0.35

// Whether a tap on `id` this frame is the second of a double tap; the first is remembered.
handle_double_tap :: proc(ctx: ^ui.Context, d: ^Handle_Tap, id: ui.Id) -> bool {
	if d.id == id && ctx.time - d.at < HANDLE_DOUBLE_TAP {
		d^ = {}
		return true
	}
	d^ = {id, ctx.time}
	return false
}

// Shows the grid in `preset` (the View grid command), and starts each pane it adds to what
// is there now as Settings' choice says: the preset's own partner, the main camera, or a
// copy of the main view; each in the main view's shading.
grid_choose :: proc(app: ^App, preset: Grid_Preset) {
	k := &app.kit
	g := &k.grid
	// Never while a view pane has the main view's role, whose pane it names.
	if g.work != 0 do return
	before := grid_step_now(g)
	had, changed := grid_set(k, preset)
	if !changed do return
	grid_step_push(g, before)
	k.pane_menu.open = false
	for i in had ..< grid_count(preset) {
		v := grid_view(g, i)
		v.shading = k.passes.shading
		switch k.new_panes {
		case .Front_Side:
		case .Same_Camera:
			v.camera = .Follow
		case .Copy_View:
			v.camera = .Follow
			second_free(app, v)
		}
	}
}

// The View layout menu in Lens: the six presets as small drawings of their panes, what
// new panes start as, the proportion guides, then the render preview and a view window.
kit_view_layout_lens :: proc(app: ^App, width: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	ui.begin(ctx, "view layout head", {direction = .Row, center = true, width = width})
	head := ui.area(ctx, "view layout title", {width, 28})
	ui.icon(ctx, ui.ICON_GRID, {head.rect.x + 8, head.rect.y + 14}, t.icon_small, t.text_secondary)
	ui.text(ctx, "View layout", head.rect.x + 24, head.rect.y + 14, t.text_size, t.text, .Semibold)
	if keys := command_keys(app, .View_Layout_Menu); keys != "" {
		kw := ui.text_width(ctx, keys, t.small_size) + 12
		key := ui.Rect{head.rect.x + head.rect.w - kw, head.rect.y + 4, kw, 20}
		ui.fill_rect(ctx, key, t.radius_small, t.fill)
		ui.text(ctx, keys, key.x + kw * 0.5, key.y + 10, t.small_size, t.text_tertiary, .Regular, .Center)
	}
	ui.end(ctx)
	GAP :: 8
	tile_w := (width - 2 * GAP) / 3
	tile_h := tile_w * 0.62
	for row in 0 ..< 2 {
		ui.begin(ctx, fmt.tprintf("view layout row %d", row), {direction = .Row, gap = GAP})
		for col in 0 ..< 3 {
			preset := Grid_Preset(row * 3 + col)
			a := ui.area(ctx, fmt.tprintf("%s##layout", GRID_NAMES[preset]), {tile_w, tile_h + 22})
			shape, plain := grid_shape(&k.grid)
			on := plain && shape == preset
			pic := ui.Rect{a.rect.x, a.rect.y, tile_w, tile_h}
			ui.fill_rect(ctx, pic, t.radius_medium, t.accent_soft if on else (t.fill_hover if a.hovered else t.fill))
			ui.stroke_rect(ctx, pic, t.radius_medium, t.accent if on else t.border, 1.5 if on else 1)
			// The preset's panes as they lie at its usual splits, with a gap between them.
			tree := grid_preset_tree(preset)
			cells, _ := grid_tree_cells(&tree, {pic.x + 7, pic.y + 7, pic.w - 14, pic.h - 14})
			for c in cells[:grid_count(preset)] do ui.fill_rect(ctx, {c.x + 1.5, c.y + 1.5, c.w - 3, c.h - 3}, 3, t.accent if on else t.border_strong)
			ui.text(ctx, ui.text_fit(ctx, GRID_NAMES[preset], t.small_size, tile_w), a.rect.x, a.rect.y + tile_h + 12, t.small_size, t.accent if on else t.text_secondary)
			ui.tip(ctx, a.id, a.rect, command_label(.View_Grid, int(preset)), command_hint(app, .View_Grid, int(preset)))
			if a.clicked do command_run(app, .View_Grid, int(preset))
		}
		ui.end(ctx)
	}
	ui.spacer(ctx, 4)
	ui.caption(ctx, "NEW PANES START AS")
	names: [len(New_Panes)]string
	for name, p in NEW_PANES_NAMES do names[p] = name
	if picked := ui.tabs(ctx, "New panes start as", names[:], int(k.new_panes)); picked >= 0 do k.new_panes = New_Panes(picked)
	guides := app.scene.guides.shown
	if ui.switch_row(ctx, "Proportion guides on ortho panes", &guides, keys = command_hint(app, .View_Guides)) do command_run(app, .View_Guides)
	ui.divider(ctx, width, across = true)
	_ = command_menu_item(app, .Render_Preview)
	_ = command_menu_item(app, .View_Window)
}

// View pane `i`'s head in Lens, at `at` in pane rect `r`: the main pane's chips, one row
// of them over the pane's corner: its tabs (grid_tabs.odin; one tab is its camera chip, the
// dot of the camera it sees through, its name, "ortho" for the six axis views; a tap lists
// the cameras, a drag carries the pane over `cells`, lens_areas.odin), New tab, then the
// active tab's pass (a tap lists them), Link, Maximise or Restore, and on the desktop a
// window of its own. A narrow pane shows as many as fit, from the tabs on.
lens_pane_head :: proc(app: ^App, i: int, at: [2]f32, r: ui.Rect, cells: [GRID_PANES]ui.Rect, n: int) {
	k := &app.kit
	ctx := &k.ctx
	g := &k.grid
	sv := grid_view(g, i)
	m := &k.pane_menu
	free := lens_free_area(app)
	left := min(r.x + r.w, free.x + free.w) - 6 - at.x
	GAP :: 6
	// Once one does not fit, none after it shows, so the chips keep their order.
	fits :: proc(left: ^f32, w: f32) -> bool {
		if w > left^ {
			left^ = -1
			return false
		}
		left^ -= w + GAP
		return true
	}
	ui.begin_at(ctx, fmt.tprintf("view pane %d head", i), at, {direction = .Row, gap = GAP, center = true})
	tab := pane_tab_shown(g, i)
	chip_menu := Pane_Menu_Kind.Camera if tab.kind == .View else .Map
	cam, rest := lens_pane_tabs(app, i, left, m.open && m.pane == i && m.kind == chip_menu)
	left = max(rest - GAP, 0)
	dragged := lens_chip_drag(app, i, cam, cells, n)
	if cam.clicked && !dragged do pane_menu_toggle(k, i, chip_menu, cam.rect)
	icon := lens_chip_width(ctx, "", glyph = ICON_LINK)
	// New tab, beside the tabs as a browser's is: its list of kinds; its tip says two 3D
	// views read best side by side, which tabs cannot show.
	if g.tabs[i - 1].count < PANE_TABS && fits(&left, icon) {
		add := lens_chip(ctx, fmt.tprintf("New tab (side by side shows both at once)##pane %d new tab", i), "", glyph = ui.ICON_PLUS, lit = m.open && m.pane == i && m.kind == .Add)
		if add.clicked do pane_menu_toggle(k, i, .Add, add.rect)
	}
	maxed := g.maximised == i
	if tab.kind != .View {
		// A 2D tab's own chips: its zoom (a tap fits, or shows one texel a pixel), then
		// Maximise.
		zoom := "Fit" if tab.flat.zoom <= 0 else "1:1"
		if fits(&left, lens_chip_width(ctx, zoom, glyph = ui.ICON_ZOOM_IN)) {
			z := lens_chip(ctx, fmt.tprintf("%s##pane %d zoom", "One texel a pixel" if tab.flat.zoom <= 0 else "Fit the map", i), zoom, glyph = ui.ICON_ZOOM_IN)
			if z.clicked do flat_zoom_toggle(app, &tab.flat)
		}
		if maxed || fits(&left, icon) {
			grow := lens_chip(ctx, fmt.tprintf("%s##pane %d", "Restore" if maxed else "Maximise", i), "", glyph = ui.ICON_MINIMISE if maxed else ui.ICON_RESTORE, lit = maxed)
			if grow.clicked do g.maximised = 0 if maxed else i
		}
		ui.end(ctx)
		return
	}
	shows := second_shows_name(sv)
	if fits(&left, lens_chip_width(ctx, shows, chevron = true)) {
		pass := lens_chip(ctx, fmt.tprintf("Shows##pane %d", i), shows, chevron = true, lit = m.open && m.pane == i && m.kind == .Pass)
		if pass.clicked do pane_menu_toggle(k, i, .Pass, pass.rect)
	}
	if fits(&left, icon) {
		linked := second_linked(sv)
		link := lens_chip(ctx, fmt.tprintf("%s##pane %d", "Unlink from the main camera" if linked else "Link to the main camera", i), "", glyph = ICON_LINK, lit = linked)
		if link.clicked do second_link_toggle(app, sv)
	}
	if maxed || fits(&left, icon) {
		grow := lens_chip(ctx, fmt.tprintf("%s##pane %d", "Restore" if maxed else "Maximise", i), "", glyph = ui.ICON_MINIMISE if maxed else ui.ICON_RESTORE, lit = maxed)
		if grow.clicked do g.maximised = 0 if maxed else i
	}
	if VIEW_WINDOWS_AVAILABLE && fits(&left, icon) {
		if win := lens_chip(ctx, fmt.tprintf("Open in a window##pane %d", i), "", glyph = ICON_VIEW_WINDOW); win.clicked do view_window_request(app, sv^)
	}
	ui.end(ctx)
}

// Opens the list `kind` for view pane `pane` under its chip at `at`, or closes it when it
// is the one open.
@(private = "file")
pane_menu_toggle :: proc(k: ^Kit_State, pane: int, kind: Pane_Menu_Kind, at: ui.Rect) {
	m := &k.pane_menu
	if m.open && m.pane == pane && m.kind == kind {
		m.open = false
		return
	}
	kit_floats_close(k)
	m^ = {open = true, pane = pane, kind = kind, at = at}
}

// A view pane's camera or pass list, under the chip it opened from.
kit_pane_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	m := &k.pane_menu
	g := &k.grid
	if m.open && (m.pane < 1 || m.pane >= grid_panes(g)) do m.open = false
	// As wide as the main view's list, for Solid's tabs.
	if !ui.popover_begin(ctx, "pane menu", &m.open, m.at, .Below, {direction = .Column, padding = ui.MENU_PAD, width = ui.MENU_W}) do return
	defer ui.popover_end(ctx)
	if m.pane < 1 || m.pane > GRID_VIEWS do return
	sv := grid_view(g, m.pane)
	tab := pane_tab_shown(g, m.pane)
	switch m.kind {
	case .Add:
		ui.caption(ctx, "  NEW TAB")
		if ui.menu_item(ctx, "3D view", glyph = TAB_KIND_ICONS[.View], keys = command_keys(app, .Pane_Tab_New)) {
			_ = pane_tab_add(g, m.pane, pane_tab_new_view(g, m.pane))
			m.open = false
		}
		if ui.menu_item(ctx, "Texture", glyph = TAB_KIND_ICONS[.Texture], hint = "The selected object's maps, flat") {
			_ = pane_tab_add(g, m.pane, sv^, .Texture)
			m.open = false
		}
	case .Map:
		ui.caption(ctx, "  MAP")
		obj := selected_object(app)
		for which in render.Texture_Map {
			has := obj != nil && obj.textures.image[which] != nil
			if ui.menu_item(ctx, fmt.tprintf("%s##tab map", TEXTURE_MAP_LABELS[which]), checked = tab.flat.which == which, hint = "" if has else "none") {
				tab.flat.which = which
				m.open = false
			}
		}
		pane_menu_tab_rows(app, m.pane)
	case .Camera:
		ui.caption(ctx, "  CAMERA")
		for c in Second_Camera {
			if !ui.menu_item(ctx, SECOND_CAMERA_NAMES[c], checked = sv.camera == c) do continue
			if c == .Free do second_free(app, sv)
			else do sv.camera = c
			m.open = false
		}
		pane_menu_tab_rows(app, m.pane)
	case .Pass:
		// The pane's own shading, as the main view's list has it: the looks (their options
		// under them, the list staying open for them), then the passes.
		ui.caption(ctx, "  SHADING")
		at := second_shows_index(sv)
		shaded := at < SECOND_SHOWS_MODES && SECOND_SHOWS[at].pass == .Shaded
		for e, j in SECOND_SHOWS {
			if j == SECOND_SHOWS_MODES {
				if shaded do shading_options(app, &sv.shading, false, looks = false)
				ui.caption(ctx, "  INSPECT")
			}
			name := SHADING_MODE_NAMES[e.mode] if j < SECOND_SHOWS_MODES else SECOND_PASS_NAMES[e.pass]
			hint := ui.hint_short(SHADING_MODE_HINTS[e.mode]) if j < SECOND_SHOWS_MODES else ""
			if !ui.menu_item(ctx, fmt.tprintf("%s##pane shows", name), checked = at == j, hint = hint) do continue
			second_shows_set(sv, j)
			if j >= SECOND_SHOWS_MODES || e.pass != .Shaded do m.open = false
		}
	}
}

// A Lens divider's grab strip across its gap, in points: wide enough for a finger.
GRID_GRAB_LENS :: 24

// The View layout menu's content width in Lens: three preset drawings and their gaps.
VIEW_LAYOUT_W :: 260

// How close to its split's edge a divider is let go to close the side it squeezes there.
GRID_CLOSE_REACH :: 36

// Divider `div` of the grid in Lens, held through `a`: its grip, a double tap that evens
// its split out, and the drag to its split's edge that closes the side it squeezes there
// (the panes there dim while it would; the main view never closes).
grid_divider_lens :: proc(app: ^App, div: Grid_Divider, a: ui.Area, cells: [GRID_PANES]ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	g := &k.grid
	line, vertical := div.line, div.vertical
	mid := [2]f32{line.x + line.w * 0.5, line.y + line.h * 0.5}
	pill := ui.Rect{mid.x - 4, mid.y - 22, 8, 44} if vertical else ui.Rect{mid.x - 22, mid.y - 4, 44, 8}
	ui.fill_rect(ctx, pill, 4, t.accent if a.held else t.surface)
	ui.stroke_rect(ctx, pill, 4, t.border_strong if !a.held else t.accent, 1)
	if a.clicked && handle_double_tap(ctx, &g.tap, a.id) do g.areas.op = {kind = .Even, node = div.node}
	if a.held {
		along := a.mouse.x if vertical else a.mouse.y
		lo := div.room.x if vertical else div.room.y
		hi := lo + (div.room.w if vertical else div.room.h)
		g.closing = 0
		near, far := along < lo + GRID_CLOSE_REACH, along > hi - GRID_CLOSE_REACH
		if !near && !far do return
		if grid_side_closes(&g.tree, div.node, far) {
			g.closing, g.closing_far = div.node + 1, far
			node := g.tree.nodes[div.node]
			side := int(node.b if far else node.a)
			for d, j in g.tree.nodes[:g.tree.count] do if !d.split && grid_tree_holds(&g.tree, side, j) {
				c := cells[d.pane]
				ui.fill_rect(ctx, c, 0, ui.color_fade(t.frame, 0.7))
				ui.text(ctx, "Let go to close", c.x + c.w * 0.5, c.y + c.h * 0.5, t.text_size, t.text, .Semibold, .Center)
			}
		} else {
			ui.text(ctx, "The main view stays", mid.x + (16 if vertical else 0), mid.y + (0 if vertical else 18), t.small_size, t.text_secondary, .Semibold)
		}
		return
	}
	if g.closing != div.node + 1 do return
	g.closing = 0
	g.areas.op = {kind = .Close, node = div.node, close_b = g.closing_far}
}

// The tab's own rows at the end of its chip's list: another tab in the pane, and closing
// this one while the pane keeps another.
@(private = "file")
pane_menu_tab_rows :: proc(app: ^App, pane: int) {
	k := &app.kit
	g := &k.grid
	m := &k.pane_menu
	p := &g.tabs[pane - 1]
	ui.divider(&k.ctx, 248, across = true)
	if p.count < PANE_TABS && ui.menu_item(&k.ctx, "New tab", keys = command_keys(app, .Pane_Tab_New)) {
		_ = pane_tab_add(g, pane, pane_tab_new_view(g, pane))
		m.open = false
	}
	if p.count > 1 && ui.menu_item(&k.ctx, "Close tab", keys = command_keys(app, .Pane_Tab_Close)) {
		_ = pane_tab_close(g, pane, p.active)
		m.open = false
	}
}
