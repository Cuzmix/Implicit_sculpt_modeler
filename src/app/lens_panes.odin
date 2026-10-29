package main

import "core:fmt"

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
// copy of the main view.
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
		v := &g.views[i - 1]
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
// of them over the pane's corner: its camera (the dot of the camera it sees through, its
// name, "ortho" for the six axis views; a tap lists the cameras, a drag carries the pane
// over `cells`, lens_areas.odin), its pass (a tap lists them), Link, Maximise or Restore,
// and on the desktop a window of its own. A narrow pane shows as many as fit, from the
// camera on.
lens_pane_head :: proc(app: ^App, i: int, at: [2]f32, r: ui.Rect, cells: [GRID_PANES]ui.Rect, n: int) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	g := &k.grid
	sv := &g.views[i - 1]
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
	dot, _ := second_color(t, sv, i)
	ortho := sv.camera >= .Front && sv.camera <= .Bottom
	// As the mock's chips: the projection with "linked" while the pane follows the main
	// camera, an axis view with "ortho", and "free" for its own camera.
	name := SECOND_CAMERA_NAMES[sv.camera]
	sub := "ortho" if ortho else ""
	#partial switch sv.camera {
	case .Follow:
		name, sub = "Ortho" if app.camera.ortho else "Persp", "linked"
	case .Mirror:
		sub = "linked"
	case .Free:
		name, sub = "Own camera", "free"
	}
	if lens_chip_width(ctx, name, sub, dot = true, chevron = true) > left do sub = ""
	_ = fits(&left, lens_chip_width(ctx, name, sub, dot = true, chevron = true))
	left = max(left, 0)
	cam := lens_chip(ctx, fmt.tprintf("Camera##pane %d", i), name, sub, dot = dot, chevron = true, lit = m.open && m.pane == i && m.kind == .Camera)
	dragged := lens_chip_drag(app, i, cam, cells, n)
	if cam.clicked && !dragged do pane_menu_toggle(k, i, .Camera, cam.rect)
	icon := lens_chip_width(ctx, "", glyph = ICON_LINK)
	if fits(&left, lens_chip_width(ctx, SECOND_PASS_NAMES[sv.pass], chevron = true)) {
		pass := lens_chip(ctx, fmt.tprintf("Shows##pane %d", i), SECOND_PASS_NAMES[sv.pass], chevron = true, lit = m.open && m.pane == i && m.kind == .Pass)
		if pass.clicked do pane_menu_toggle(k, i, .Pass, pass.rect)
	}
	if fits(&left, icon) {
		linked := second_linked(sv)
		link := lens_chip(ctx, fmt.tprintf("%s##pane %d", "Unlink from the main camera" if linked else "Link to the main camera", i), "", glyph = ICON_LINK, lit = linked)
		if link.clicked do second_link_toggle(app, sv)
	}
	maxed := g.maximised == i
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
	if !ui.popover_begin(ctx, "pane menu", &m.open, m.at, .Below, {direction = .Column, padding = 6, width = 200}) do return
	defer ui.popover_end(ctx)
	if m.pane < 1 || m.pane > GRID_VIEWS do return
	sv := &g.views[m.pane - 1]
	switch m.kind {
	case .Camera:
		ui.caption(ctx, "  CAMERA")
		for c in Second_Camera {
			if !ui.menu_item(ctx, SECOND_CAMERA_NAMES[c], checked = sv.camera == c) do continue
			if c == .Free do second_free(app, sv)
			else do sv.camera = c
			m.open = false
		}
	case .Pass:
		ui.caption(ctx, "  SHOWS")
		for p in Second_Pass {
			if !ui.menu_item(ctx, SECOND_PASS_NAMES[p], checked = sv.pass == p) do continue
			sv.pass = p
			m.open = false
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

// Whether the panel stack shows as its strip of tabs: in Lens, docked, with panes beside
// the main one.
stack_strip_shown :: proc(app: ^App) -> bool {
	k := &app.kit
	if grid_panes(&k.grid) < 2 do return false
	_, _, docked := panel_docked(k, Kit_Window.Inspector)
	return docked
}

// The strip's width: one button and the panel's padding round it.
STACK_STRIP_W :: 44 + 2 * 4

// The stack as a strip of tabs beside the rail, one for each docked card in the stack's
// order; a tap opens that card over the view, beside the strip, and another closes it.
kit_stack_strip :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	s := &k.stack
	if !s.set do stack_default(k)
	ui.begin(ctx, "stack strip", {direction = .Column, gap = 2, padding = 4, width = STACK_STRIP_W, radius = ctx.theme.radius_large, background = .Panel, center = true})
	defer ui.end(ctx)
	for c in s.order {
		if c in s.floated || c in s.hidden do continue
		on := s.tab_open && s.tab == c
		if ui.icon_button(ctx, fmt.tprintf("%s##stack tab", stack_title(app, c)), STACK_CARD_ICONS[c] if c != .Brush else stack_brush_icon(app), selected = on) {
			if on {
				s.tab_open = false
			} else {
				kit_floats_close(k)
				s.tab, s.tab_open, s.tab_at = c, true, ctx.last_rect
				s.tabs += 1
			}
		}
	}
}

// The card a strip's tab opened, beside the strip: its title, Float (out of the stack, as
// a card of its own) and Close, then its content, scrolling in the room below.
kit_stack_tab :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	s := &k.stack
	if s.tab_open && !stack_strip_shown(app) do s.tab_open = false
	width := stack_width(k)
	PADDING :: 10
	inner := width - 2 * PADDING
	owner := ui.id_of(ctx, "stack tab")
	if !ui.popover_begin(ctx, "stack tab", &s.tab_open, s.tab_at, .Left, {direction = .Column, gap = 6, padding = PADDING, width = width}) do return
	defer ui.popover_end(ctx)
	c := s.tab
	ui.begin(ctx, "stack tab head", {direction = .Row, center = true, width = inner})
	title := ui.area(ctx, "stack tab title", {inner - 2 * t.target, t.target})
	y := title.rect.y + title.rect.h * 0.5
	ui.icon(ctx, STACK_CARD_ICONS[c] if c != .Brush else stack_brush_icon(app), {title.rect.x + 9, y}, t.icon_small, t.text_secondary)
	ui.text(ctx, stack_title(app, c), title.rect.x + 26, y, t.text_size, t.text, .Semibold)
	if ui.icon_button(ctx, "Float", ui.ICON_PANEL) {
		stack_float(app, c)
		s.tab_open = false
	}
	if ui.icon_button(ctx, "Close", ui.ICON_CLOSE, keys = "Esc") do s.tab_open = false
	ui.end(ctx)
	area := ui.safe_area(ctx)
	room := max(area.y + area.h - s.tab_at.y - 2 * PADDING - t.target - 6 - 16, 160)
	scroll := kit_scroll_begin(ctx, "stack tab body", &s.scrolls[c], owner, inner, room, 6)
	stack_card_body(app, c, inner)
	kit_scroll_end(ctx, scroll)
}
