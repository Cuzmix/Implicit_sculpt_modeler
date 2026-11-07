package main

import "core:fmt"
import "core:strconv"
import "core:strings"

import "../render"
import "../ui"

// Tabs in the view panes (docking DK1, after Dear ImGui's docking and VS Code's editor
// groups): each view pane holds up to PANE_TABS tabs and shows the active one. A tab has a
// kind (a 3D view for now; 2D editors join later) and its own state, so switching tabs
// brings a view back as it was left. Only the active tab draws: the pane keeps one picture
// whatever its tab count (grid_frame), which a switch draws again once, at rest, so tabs
// cost no GPU memory. The main view's pane holds only the main view, since the tools, the
// overlay and the heavy passes live there.

// The most tabs a view pane holds: more hide more than they show.
PANE_TABS :: 8

// What a tab shows. Layout lines name them, so a new kind goes at the end.
Tab_Kind :: enum u8 {
	View, // a 3D view: a second view (thumbnail.odin) with its camera and pass
	Texture, // a map of the selected object, flat (texture_tab.odin)
}

@(rodata)
TAB_KIND_ICONS := [Tab_Kind]rune {
	.View    = ui.ICON_ORBIT_VIEW,
	.Texture = ui.ICON_TEXTURE_TAB,
}

// A tab's state: every kind's, so a tab keeps what it showed whatever it shows now. A 2D
// kind draws with the interface kit inside its pane, so it needs no picture of its own.
Pane_Tab :: struct {
	kind: Tab_Kind,
	view: Second_View,
	flat: Flat_Tab,
}

// A view pane's tabs, in their order on its head, and the one it shows.
Pane_Tabs :: struct {
	tabs:   [PANE_TABS]Pane_Tab,
	count:  int,
	active: int,
}

// The view that view pane `pane` (1 to 3) shows: its active tab's. A 2D tab's is what the
// tab keeps for when it is a 3D view again, so readers that draw or count 3D views ask
// pane_shows_view first.
grid_view :: proc(g: ^View_Grid, pane: int) -> ^Second_View {
	return &pane_tab_shown(g, pane).view
}

// View pane `pane`'s active tab.
pane_tab_shown :: proc(g: ^View_Grid, pane: int) -> ^Pane_Tab {
	p := &g.tabs[pane - 1]
	return &p.tabs[clamp(p.active, 0, max(p.count - 1, 0))]
}

// Whether view pane `pane` shows a 3D view, which draws a picture and may be worked in.
pane_shows_view :: proc(g: ^View_Grid, pane: int) -> bool {
	return pane_tab_shown(g, pane).kind == .View
}

// One tab showing `v`.
pane_tabs_one :: proc(v: Second_View) -> Pane_Tabs {
	p: Pane_Tabs
	p.tabs[0] = {kind = .View, view = v}
	p.count = 1
	return p
}

// The view panes holding one tab each of `views`.
grid_tabs_of :: proc(views: [GRID_VIEWS]Second_View) -> (out: [GRID_VIEWS]Pane_Tabs) {
	for v, i in views do out[i] = pane_tabs_one(v)
	return
}

// The view pane a tab command acts on: `arg` 1 to 3 names one; 0 the view pane last
// pressed, else the first; 0 back when the grid shows no view pane.
pane_tab_target :: proc(g: ^View_Grid, arg: int) -> int {
	n := grid_panes(g)
	pane := arg if arg > 0 else g.last_place
	if pane <= 0 do pane = 1
	if pane >= n do return 0
	return pane
}

// The camera a new tab in view pane `pane` starts with: the first axis view no tab there
// shows, so a new tab is a new angle, else the active tab's.
pane_tab_new_view :: proc(g: ^View_Grid, pane: int) -> Second_View {
	p := &g.tabs[pane - 1]
	v := grid_view(g, pane)^
	v.dragging, v.turns, v.linked = false, 0, 0
	for c in Second_Camera.Front ..= Second_Camera.Bottom {
		taken := false
		for t in p.tabs[:p.count] do if t.kind == .View && t.view.camera == c do taken = true
		if !taken {
			v.camera = c
			return v
		}
	}
	return v
}

// Adds a tab showing `v` after view pane `pane`'s active one and shows it, as a layout step.
pane_tab_add :: proc(g: ^View_Grid, pane: int, v: Second_View, kind := Tab_Kind.View) -> bool {
	if pane < 1 || pane >= grid_panes(g) do return false
	p := &g.tabs[pane - 1]
	if p.count >= PANE_TABS do return false
	grid_step_push(g, grid_step_now(g))
	at := p.active + 1
	for i := p.count; i > at; i -= 1 do p.tabs[i] = p.tabs[i - 1]
	p.tabs[at] = {kind = kind, view = v}
	p.count += 1
	p.active = at
	g.tab_adds += 1
	return true
}

// Closes tab `tab` of view pane `pane`, as a layout step; the pane keeps at least one,
// since closing the pane is the divider's (or the corner's) job. The tab after it shows,
// else the one before.
pane_tab_close :: proc(g: ^View_Grid, pane, tab: int) -> bool {
	if pane < 1 || pane >= grid_panes(g) do return false
	p := &g.tabs[pane - 1]
	if p.count < 2 || tab < 0 || tab >= p.count do return false
	grid_step_push(g, grid_step_now(g))
	for i in tab ..< p.count - 1 do p.tabs[i] = p.tabs[i + 1]
	p.count -= 1
	p.tabs[p.count] = {}
	if p.active > tab || p.active >= p.count do p.active = max(p.active - 1, 0)
	g.tab_closes += 1
	return true
}

// Shows tab `tab` of view pane `pane`; not a layout step, as picking a camera is not.
pane_tab_show :: proc(g: ^View_Grid, pane, tab: int) {
	p := &g.tabs[pane - 1]
	if tab < 0 || tab >= p.count || tab == p.active do return
	p.active = tab
	g.tab_switches += 1
}

// Shows the next tab of view pane `pane` (`step` -1 the one before), round the end.
pane_tab_step :: proc(g: ^View_Grid, pane, step: int) {
	p := &g.tabs[pane - 1]
	if p.count < 2 do return
	pane_tab_show(g, pane, (p.active + step + p.count) % p.count)
}

// The tab commands: New tab, Close tab and the next or previous tab, on the view pane
// `arg` names (pane_tab_target).
pane_tab_command :: proc(app: ^App, arg: int, what: Command_Id) {
	g := &app.kit.grid
	pane := pane_tab_target(g, arg)
	if pane == 0 || g.work != 0 do return
	#partial switch what {
	case .Pane_Tab_New:
		_ = pane_tab_add(g, pane, pane_tab_new_view(g, pane))
	case .Pane_Tab_Texture:
		_ = pane_tab_add(g, pane, grid_view(g, pane)^, .Texture)
	case .Pane_Tab_Close:
		_ = pane_tab_close(g, pane, g.tabs[pane - 1].active)
	case .Pane_Tab_Next:
		pane_tab_step(g, pane, 1)
	case .Pane_Tab_Previous:
		pane_tab_step(g, pane, -1)
	}
	app.kit.pane_menu.open = false
}

// Whether a tab command can act: a view pane to act on, and for New room for a tab, for
// Close and the steps a second tab.
pane_tab_command_enabled :: proc(app: ^App, arg: int, what: Command_Id) -> bool {
	g := &app.kit.grid
	pane := pane_tab_target(g, arg)
	if pane == 0 || g.work != 0 do return false
	count := g.tabs[pane - 1].count
	return count < PANE_TABS if what == .Pane_Tab_New || what == .Pane_Tab_Texture else count > 1
}

// A view pane's layout lines: one `pane N camera pass [shading]` line a tab, in order, then
// `pane_tab N A` when the tab shown is not the first.
grid_tab_lines :: proc(b: ^strings.Builder, k: ^Kit_State, pane: int) {
	p := &k.grid.tabs[pane - 1]
	for &t in p.tabs[:max(p.count, 1)] {
		v := &t.view
		switch t.kind {
		case .View:
			fmt.sbprintf(b, "pane %d %v %v%s\n", pane, v.camera, v.pass, second_shading_words(k, v))
		case .Texture:
			fmt.sbprintf(b, "pane %d Texture %v\n", pane, t.flat.which)
		}
	}
	if p.active > 0 do fmt.sbprintf(b, "pane_tab %d %d\n", pane, p.active)
}

// Reads a `pane` line into view pane `i`'s tabs: the first since the `panes` line takes the
// first tab, each later one adds a tab; a word naming nothing leaves what it named.
grid_tab_line_read :: proc(k: ^Kit_State, i: int, f: []string) {
	g := &k.grid
	p := &g.tabs[i - 1]
	at := 0
	if i - 1 in g.tabs_read {
		if p.count >= PANE_TABS do return
		at = p.count
		p.tabs[at] = {kind = .View, view = {camera = .Front, pass = .Shaded}}
		p.count += 1
	}
	g.tabs_read += {i - 1}
	p.tabs[at].kind = .View
	if strings.equal_fold(f[2], "Texture") {
		p.tabs[at].kind = .Texture
		for m in render.Texture_Map do if strings.equal_fold(fmt.tprint(m), f[3]) do p.tabs[at].flat.which = m
		return
	}
	v := &p.tabs[at].view
	for c in Second_Camera do if strings.equal_fold(fmt.tprint(c), f[2]) do v.camera = c
	for s in Second_Pass do if strings.equal_fold(fmt.tprint(s), f[3]) do v.pass = s
	// The pane's shading follows its pass, in layouts since per-view shading; one
	// without it is a fresh view's.
	v.shading = {}
	if len(f) > 4 do shading_words_read(k, &v.shading, f[4:])
}

// Reads a `pane_tab N A` line: which tab view pane N shows.
grid_tab_active_read :: proc(g: ^View_Grid, f: []string) {
	if len(f) < 3 do return
	i, ok := strconv.parse_int(f[1])
	a, ok2 := strconv.parse_int(f[2])
	if !ok || !ok2 || i < 1 || i > GRID_VIEWS do return
	p := &g.tabs[i - 1]
	if a >= 0 && a < p.count do p.active = a
}

// The tab strip's segments, in points: the gap between two and the least an inactive one
// shrinks to (its dot alone).
PANE_TAB_DOT_W :: 28

// A tab's label on its segment: for a 3D view the projection with "linked" while it
// follows the main camera, an axis view with "ortho", "free" for its own camera; for a
// texture its map.
pane_tab_label :: proc(app: ^App, tab: ^Pane_Tab) -> (name, sub: string) {
	if tab.kind == .Texture do return TEXTURE_MAP_LABELS[tab.flat.which], "map"
	sv := &tab.view
	name = SECOND_CAMERA_NAMES[sv.camera]
	if sv.camera >= .Front && sv.camera <= .Bottom do sub = "ortho"
	#partial switch sv.camera {
	case .Follow:
		name, sub = "Ortho" if app.camera.ortho else "Persp", "linked"
	case .Mirror:
		sub = "linked"
	case .Free:
		name, sub = "Own camera", "free"
	}
	return
}

// A tab's mark before its label: a 3D view's camera dot, a 2D kind's icon.
pane_tab_mark :: proc(t: ui.Theme, tab: ^Pane_Tab, pane: int) -> (dot: Maybe(ui.Color), glyph: rune) {
	if tab.kind != .View do return nil, TAB_KIND_ICONS[tab.kind]
	c, _ := second_color(t, &tab.view, pane)
	return c, 0
}

// View pane `i`'s tab strip on its head row, with `left` points to spend: with one tab, its
// chip as ever (a 3D view's camera chip); with more, every tab as a segment of one glass
// pill, the active one the chip (its list on a tap, a drag carrying the pane) and the rest
// their mark and name, dimmed, shrinking to their marks when room is short; a tap shows
// one. Returns the active segment's area, and the points left.
lens_pane_tabs :: proc(app: ^App, i: int, left: f32, menu_lit: bool) -> (active: ui.Area, rest: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	g := &k.grid
	p := &g.tabs[i - 1]
	count := max(p.count, 1)
	active_at := clamp(p.active, 0, count - 1)
	shown := pane_tab_shown(g, i)
	name, sub := pane_tab_label(app, shown)
	dot, glyph := pane_tab_mark(t, shown, i)
	width :: proc(ctx: ^ui.Context, name, sub: string, dot: Maybe(ui.Color), glyph: rune, chevron: bool) -> f32 {
		return lens_chip_width(ctx, name, sub, glyph, dot != nil, chevron)
	}
	if count == 1 {
		if width(ctx, name, sub, dot, glyph, true) > left do sub = ""
		w := width(ctx, name, sub, dot, glyph, true)
		active = lens_chip(ctx, fmt.tprintf("Camera##pane %d", i) if shown.kind == .View else fmt.tprintf("Map##pane %d", i), name, sub, glyph = glyph, dot = dot, chevron = true, lit = menu_lit)
		return active, left - w
	}
	// Widths first: the active segment whole (its sub dropped when short), the others whole
	// while everything fits, else their marks alone.
	if width(ctx, name, sub, dot, glyph, true) + f32(count - 1) * PANE_TAB_DOT_W > left do sub = ""
	active_w := width(ctx, name, sub, dot, glyph, true)
	widths: [PANE_TABS]f32
	total := active_w
	for j in 0 ..< count do if j != active_at {
		n, _ := pane_tab_label(app, &p.tabs[j])
		d, gl := pane_tab_mark(t, &p.tabs[j], i)
		widths[j] = width(ctx, n, "", d, gl, false)
		total += widths[j]
	}
	compact := total > left
	if compact {
		total = active_w
		for j in 0 ..< count do if j != active_at {
			widths[j] = PANE_TAB_DOT_W
			total += widths[j]
		}
	}
	widths[active_at] = active_w
	// The segments run as one row with no gap, the pill drawn under them once the first
	// is placed, so each segment is its own area and takes its own taps.
	ui.begin(ctx, fmt.tprintf("pane %d tabs", i), {direction = .Row, center = true})
	for j in 0 ..< count {
		w := widths[j]
		tab := &p.tabs[j]
		d, gl := pane_tab_mark(t, tab, i)
		n, s := pane_tab_label(app, tab)
		id: string
		switch {
		case j != active_at:      id = fmt.tprintf("%s##pane %d tab %d", n, i, j)
		case tab.kind == .View:   id = fmt.tprintf("Camera##pane %d", i)
		case:                     id = fmt.tprintf("Map##pane %d", i)
		}
		a := ui.area(ctx, id, {w, t.target})
		pill := ui.Rect{a.rect.x, a.rect.y + (a.rect.h - LENS_CHIP_H) * 0.5, total, LENS_CHIP_H}
		if j == 0 {
			ui.fill_rect(ctx, pill, t.radius_medium, ui.Color{t.frame.r, t.frame.g, t.frame.b, TOP_GLASS_ALPHA})
			ui.stroke_rect(ctx, pill, t.radius_medium, t.border, 1)
		}
		seg := ui.Rect{a.rect.x + 2, pill.y + 2, w - 4, pill.h - 4}
		if j == active_at {
			ui.fill_rect(ctx, seg, t.radius_medium - 2, t.fill_pressed if a.held else t.fill_hover if a.hovered else t.fill)
			lens_chip_draw(ctx, {a.rect.x, pill.y, w, pill.h}, name, sub, glyph = glyph, dot = dot, chevron = true, lit = menu_lit, glass = false)
			ui.tip(ctx, a.id, a.rect, "Camera" if tab.kind == .View else "Map")
			active = a
			continue
		}
		if a.hovered || a.held do ui.fill_rect(ctx, seg, t.radius_medium - 2, t.fill_pressed if a.held else t.fill_hover)
		cy := pill.y + pill.h * 0.5
		x := a.rect.x + (w * 0.5 if compact else LENS_CHIP_PAD + 4)
		if c, ok := d.?; ok do ui.fill_circle(ctx, {x, cy}, 4, ui.color_fade(c, 0.7))
		else do ui.icon(ctx, gl, {x + (0 if compact else t.icon_small * 0.5 - 4), cy}, t.icon_small, t.text_tertiary)
		if !compact {
			tx := a.rect.x + LENS_CHIP_PAD + (14 if d != nil else t.icon_small + 6)
			ui.text(ctx, n, tx, cy, t.small_size, t.text_secondary, .Semibold)
		}
		ui.tip(ctx, a.id, a.rect, fmt.tprintf("%s %s", n, s) if s != "" else n, command_keys(app, .Pane_Tab_Next) if j == (active_at + 1) % count else "")
		if a.clicked do pane_tab_show(g, i, j)
	}
	ui.end(ctx)
	return active, left - total
}
