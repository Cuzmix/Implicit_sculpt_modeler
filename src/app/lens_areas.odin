package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:time"

import sdl "vendor:sdl3"

import "../ui"

// Lens's pane gestures (round 2 screens split3 and areaGest), after Blender's areas and
// its 4.3 area docking: a drag from a pane's corner splits it, or carried on into a
// neighbour joins the two; a view pane's camera chip drags the pane onto another to swap
// the two or dock it on an edge; a divider's menu splits, joins, swaps and evens. Unlike
// Blender a drop on a pane's middle swaps rather than replaces, so no view is lost, and
// every gesture is a layout step Undo takes back in order with the scene's steps. Each
// gesture queues its change (Grid_Op), which the next layout applies before it lays the
// panes out, so nothing changes under a layout half done.

// A corner handle's target, in points, inside the pane at its visible corner.
GRID_CORNER_HIT :: 44
// How far a corner drag goes before its direction counts, and how near the corner it
// comes back to cancel.
GRID_CORNER_SLOP :: 14
GRID_CORNER_BACK :: 20
// The least a pane keeps across and down, in points, beside GRID_PANE_MIN's share: room
// for its head and its corner handles on a small screen.
GRID_PANE_MIN_PT :: 120
// Seconds the corner handles stay off after a stroke, so a stroke begun near a corner
// right after another stays a stroke, and how long a refused split shakes.
GRID_CORNER_REST :: 0.4
GRID_SHAKE :: 0.45
// How far a camera chip is dragged before it carries its pane.
GRID_CHIP_SLOP :: 10

Grid_Op_Kind :: enum u8 {
	None,
	Split,
	Join,
	Swap,
	Dock,
	Close,
	Swap_Sides,
	Even,
}

// A change to the grid's tree, queued by a gesture for the start of the next layout.
Grid_Op :: struct {
	kind:     Grid_Op_Kind,
	pane:     int, // Split's pane, Join's kept one, Swap's and Dock's moving one
	other:    int, // Join's closing pane, Swap's and Dock's target
	node:     int, // Close's, Swap_Sides' and Even's split
	vertical: bool,
	first:    bool,
	close_b:  bool,
	share:    f32,
	edge:     Grid_Edge,
	view:     Second_View, // what a split's new pane shows
}

Corner_Mode :: enum u8 {
	Undecided,
	Split,
	Join,
}

Corner_Drag :: struct {
	live:     bool, // a corner is held and its gesture still counts
	pane:     int,
	corner:   int, // 0 top left, 1 top right, 2 bottom left, 3 bottom right
	at:       [2]f32, // the corner, in points
	inward:   [2]f32, // which way is into the pane, across and down
	mode:     Corner_Mode,
	vertical: bool, // Split's cut runs up and down
	share:    f32,
	target:   int, // Join's neighbour, -1 for none
	press:    [2]f32, // where the finger went down, which the direction is read from
	finger:   [2]f32,
}

Chip_Drag :: struct {
	pane:   int, // the view pane whose chip is held, 0 for none
	from:   [2]f32,
	moving: bool, // past the slop: the chip carries its pane
	at:     [2]f32,
}

// A divider's menu (a right click or a long press on it).
Divider_Menu :: struct {
	open:   bool,
	node:   int,
	at:     ui.Rect,
	point:  [2]f32,
	serial: int, // the layout it opened on; another closes it
}

Grid_Areas :: struct {
	op:     Grid_Op,
	corner: Corner_Drag,
	chip:   Chip_Drag,
	menu:   Divider_Menu,
	// The refused fifth split's handle, and when, for its shake.
	shake_pane, shake_corner: int,
	shake_at:   f64,
	stroke_end: f64, // when the last stroke was going on
	// A divider drag's layout before it began, a step once the drag changed it.
	held:      bool,
	held_step: Grid_Step,
	// For the exit stats.
	splits, joins, swaps, docks, undos, redos, refused, cancels: int,
}

// The layout as it is now, as a step Undo would bring back.
grid_step_now :: proc(g: ^View_Grid) -> Grid_Step {
	return {tree = g.tree, views = g.views, at = time.tick_now()}
}

// Keeps `s` as the newest layout step; what was undone is gone.
grid_step_push :: proc(g: ^View_Grid, s: Grid_Step) {
	u := &g.undo
	if u.back_n == GRID_UNDO {
		copy(u.back[:], u.back[1:])
		u.back_n -= 1
	}
	u.back[u.back_n] = s
	u.back_n += 1
	u.ahead_n = 0
}

// Puts step `s`'s layout in place; the pictures, which stay with their panes, are drawn
// again.
@(private = "file")
grid_step_put :: proc(app: ^App, s: Grid_Step) {
	g := &app.kit.grid
	g.tree, g.views, g.maximised = s.tree, s.views, 0
	g.serial += 1
	for &pic in app.panes do pic.key, pic.due = 0, true
	app.kit.pane_menu.open = false
	g.areas.menu.open = false
}

// Whether Undo takes back a layout step before the scene's: one is kept, nothing works in
// a pane, and it was made after the scene's last step still done.
grid_undo_first :: proc(app: ^App) -> bool {
	g := &app.kit.grid
	u := &g.undo
	if u.back_n == 0 || g.work != 0 || app.stroke.active do return false
	done := app.history.done[:]
	return len(done) == 0 || time.tick_diff(done[len(done) - 1].at, u.back[u.back_n - 1].at) >= 0
}

// Whether Redo does a layout step again before the scene's: one was undone, and it was
// made before the scene's next step to redo.
grid_redo_first :: proc(app: ^App) -> bool {
	g := &app.kit.grid
	u := &g.undo
	if u.ahead_n == 0 || g.work != 0 || app.stroke.active do return false
	undone := app.history.undone[:]
	return len(undone) == 0 || time.tick_diff(u.ahead[u.ahead_n - 1].at, undone[len(undone) - 1].at) > 0
}

grid_undo :: proc(app: ^App) {
	g := &app.kit.grid
	u := &g.undo
	if u.back_n == 0 do return
	u.back_n -= 1
	s := u.back[u.back_n]
	now := grid_step_now(g)
	now.at = s.at
	u.ahead[u.ahead_n] = now
	u.ahead_n += 1
	grid_step_put(app, s)
	g.areas.undos += 1
}

grid_redo :: proc(app: ^App) {
	g := &app.kit.grid
	u := &g.undo
	if u.ahead_n == 0 do return
	u.ahead_n -= 1
	s := u.ahead[u.ahead_n]
	now := grid_step_now(g)
	now.at = s.at
	u.back[u.back_n] = now
	u.back_n += 1
	grid_step_put(app, s)
	g.areas.redos += 1
}

// The Undo and Redo commands: the layout's step or the scene's, whichever came last.
undo_run :: proc(app: ^App) {
	if grid_undo_first(app) do grid_undo(app)
	else do history_undo(app)
}

redo_run :: proc(app: ^App) {
	if grid_redo_first(app) do grid_redo(app)
	else do history_redo(app)
}

undo_can :: proc(app: ^App) -> bool {
	return history_can_undo(app) || grid_undo_first(app)
}

redo_can :: proc(app: ^App) -> bool {
	return history_can_redo(app) || grid_redo_first(app)
}

// Moves the view panes' pictures after their views (grid_tree_set), whole, so each is
// still drawn and freed once.
grid_pictures_follow :: proc(app: ^App) {
	g := &app.kit.grid
	if !g.moved do return
	g.moved = false
	old := app.panes
	for i in 0 ..< GRID_VIEWS do app.panes[i] = old[g.was[i]]
}

// Applies the gesture's queued change, as a layout step, before the grid is laid out.
// Never while a view pane has the main view's role, whose pane numbers it holds.
grid_op_apply :: proc(app: ^App) {
	g := &app.kit.grid
	ar := &g.areas
	op := ar.op
	ar.op = {}
	if op.kind == .None || g.work != 0 do return
	before := grid_step_now(g)
	ok := false
	switch op.kind {
	case .None:
	case .Split:
		ok = grid_split_pane(g, op.pane, op.vertical, op.share, op.first, op.view) != 0
		if ok do ar.splits += 1
	case .Join:
		ok = grid_join(g, op.pane, op.other)
		if ok do ar.joins += 1
	case .Swap:
		ok = grid_swap(g, op.pane, op.other)
		if ok do ar.swaps += 1
	case .Dock:
		ok = grid_dock(g, op.pane, op.other, op.edge)
		if ok do ar.docks += 1
	case .Close:
		ok = grid_close_side(g, op.node, op.close_b)
		if ok do g.closes += 1
	case .Swap_Sides:
		ok = grid_swap_sides(g, op.node)
		if ok do ar.swaps += 1
	case .Even:
		grid_even(g, op.node)
		ok = g.tree != before.tree
		g.evens += 1
	}
	if !ok do return
	grid_step_push(g, before)
	grid_pictures_follow(app)
	app.kit.pane_menu.open = false
	ar.menu.open = false
}

// What a pane cut from pane `pane` starts as: a view pane's copy, or for the main view an
// independent camera where it is now, showing the main view's pass where a view pane can.
grid_pane_copy :: proc(app: ^App, pane: int) -> Second_View {
	g := &app.kit.grid
	if pane > 0 {
		v := g.views[pane - 1]
		v.max, v.dragging, v.turns, v.linked = false, false, 0, 0
		return v
	}
	v := Second_View{camera = .Follow, pass = .Shaded}
	second_free(app, &v)
	shown := viewport_pass(&app.kit)
	for p in Second_Pass do if p != .Studio && p != .Render && second_view_pass(p) == shown {
		v.pass = p
		break
	}
	return v
}

// A pane's name in the gestures' notes: the main view, or its camera.
grid_pane_name :: proc(g: ^View_Grid, pane: int) -> string {
	if pane <= 0 do return "Main view"
	return SECOND_CAMERA_NAMES[g.views[pane - 1].camera]
}

// Whether the corner handles take presses: in Lens, nothing maximised, no stroke going on
// or just over, nothing floating whose closing press it is, and the chrome shown.
@(private = "file")
grid_corners_on :: proc(app: ^App) -> bool {
	k := &app.kit
	ctx := &k.ctx
	g := &k.grid
	if app.stroke.active do g.areas.stroke_end = ctx.time
	if k.chrome != .Lens || g.maximised != 0 || k.clean || k.home do return false
	if g.areas.stroke_end > 0 && ctx.time - g.areas.stroke_end < GRID_CORNER_REST do return false
	return !kit_floating(app) && ctx.popup_open_prev == 0 && g.areas.chip.pane == 0
}

// The four corners of pane rect `c` as their handles stand: inside the part of the pane the
// chrome leaves free (under the see-through top bar, clear of the rails, the island and the
// dock), and which way is into the pane from each.
@(private = "file")
grid_corner_points :: proc(app: ^App, c: ui.Rect) -> (at: [4][2]f32, inward: [4][2]f32) {
	free := lens_free_area(app)
	x0, y0 := max(c.x, free.x), max(c.y, free.y)
	x1, y1 := min(c.x + c.w, free.x + free.w), min(c.y + c.h, free.y + free.h)
	// Too little of the pane is free: the handles keep to the pane itself.
	if x1 - x0 < 3 * GRID_CORNER_HIT || y1 - y0 < 3 * GRID_CORNER_HIT do x0, y0, x1, y1 = c.x, c.y, c.x + c.w, c.y + c.h
	at = {{x0, y0}, {x1, y0}, {x0, y1}, {x1, y1}}
	inward = {{1, 1}, {-1, 1}, {1, -1}, {-1, -1}}
	return
}

// Lens's corner handles on every pane `cells` lays out, before the panes' heads so the
// chips win where the two meet, and the corner gesture held on one: split, join or cancel.
lens_pane_corners :: proc(app: ^App, cells: [GRID_PANES]ui.Rect, n: int) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	g := &k.grid
	cd := &g.areas.corner
	on := grid_corners_on(app)
	if !on && !cd.live do return
	for i in 0 ..< n {
		at, inward := grid_corner_points(app, cells[i])
		for c in 0 ..< 4 {
			mine := cd.live && cd.pane == i && cd.corner == c
			if !on && !mine do continue
			p, s := at[c], inward[c]
			hit := ui.Rect{p.x if s.x > 0 else p.x - GRID_CORNER_HIT, p.y if s.y > 0 else p.y - GRID_CORNER_HIT, GRID_CORNER_HIT, GRID_CORNER_HIT}
			ui.begin_at(ctx, fmt.tprintf("pane corner %d %d", i, c), {hit.x, hit.y}, {width = hit.w, height = hit.h})
			a := ui.area(ctx, "corner", {hit.w, hit.h})
			ui.end(ctx)
			if a.pressed do cd^ = {live = true, pane = i, corner = c, at = p, inward = s, target = -1, press = a.mouse, finger = a.mouse}
			mine = cd.live && cd.pane == i && cd.corner == c
			// On touch and pen the handles always show; with a mouse, once it comes near.
			near := ctx.input.pointer != .Mouse || linalg.length(ctx.input.mouse - p) < 72 || mine
			if near {
				shake: f32 = 0
				if g.areas.shake_pane == i && g.areas.shake_corner == c {
					since := f32(ctx.time - g.areas.shake_at)
					if since < GRID_SHAKE do shake = math.sin(since * 48) * 5 * (1 - since / GRID_SHAKE)
				}
				q := p + s * 3 + {shake, 0}
				color := t.accent if mine || a.hovered else ui.color_fade(t.text, 0.7)
				ui.line(ctx, q, q + {s.x * 12, 0}, color, 2)
				ui.line(ctx, q, q + {0, s.y * 12}, color, 2)
			}
			if !mine do continue
			if a.held do corner_track(app, a.mouse, cells, n)
			else do corner_release(app, n)
		}
	}
}

// The corner gesture as the finger moves to `m`: back at the corner it waits, inward it
// splits the pane along the axis it went first, out into a neighbour it joins the two.
// Esc, a second finger or the system taking the touch back cancels it.
@(private = "file")
corner_track :: proc(app: ^App, m: [2]f32, cells: [GRID_PANES]ui.Rect, n: int) {
	k := &app.kit
	ctx := &k.ctx
	g := &k.grid
	cd := &g.areas.corner
	if app.touch.fingers.count >= 2 || key_pressed(&app.device, sdl.K_ESCAPE) || ctx.input.cancel {
		cd.live = false
		g.areas.cancels += 1
		return
	}
	cd.finger = m
	c := cells[cd.pane]
	// Back at the corner, or not yet past the slop from the press, it waits.
	if linalg.length(m - cd.at) < GRID_CORNER_BACK || linalg.length(m - cd.press) < GRID_CORNER_SLOP {
		cd.mode = .Undecided
		return
	}
	inside := m.x >= c.x && m.x <= c.x + c.w && m.y >= c.y && m.y <= c.y + c.h
	if inside {
		if cd.mode != .Split {
			d := m - cd.press
			cd.mode, cd.vertical = .Split, abs(d.x) >= abs(d.y)
		}
		start, size := c.y, c.h
		along := m.y
		if cd.vertical do start, size, along = c.x, c.w, m.x
		s := (along - start) / max(size, 1)
		if ctx.input.ctrl {
			best: f32 = 0.5
			for f in ([]f32{0.25, 1.0 / 3, 0.5, 2.0 / 3, 0.75}) do if abs(f - s) < abs(best - s) do best = f
			s = best
		}
		least := GRID_PANE_MIN_PT / max(size, 1)
		cd.share = clamp(s, least, 1 - least)
		return
	}
	cd.mode, cd.target = .Join, -1
	for i in 0 ..< n {
		r := cells[i]
		if i != cd.pane && m.x >= r.x && m.x <= r.x + r.w && m.y >= r.y && m.y <= r.y + r.h do cd.target = i
	}
}

// The corner let go: the split or join it showed, or nothing when it came back to the
// corner. A fifth pane is refused with a shake.
@(private = "file")
corner_release :: proc(app: ^App, n: int) {
	g := &app.kit.grid
	cd := &g.areas.corner
	defer cd.live = false
	switch cd.mode {
	case .Undecided:
		g.areas.cancels += 1
	case .Split:
		if n >= GRID_PANES {
			g.areas.shake_pane, g.areas.shake_corner, g.areas.shake_at = cd.pane, cd.corner, app.kit.ctx.time
			g.areas.refused += 1
			return
		}
		// The new pane is the part on the corner's side: the part the finger swept.
		first := cd.inward.x > 0 if cd.vertical else cd.inward.y > 0
		g.areas.op = {kind = .Split, pane = cd.pane, vertical = cd.vertical, share = cd.share, first = first, view = grid_pane_copy(app, cd.pane)}
	case .Join:
		if cd.target >= 0 && grid_joinable(g, cd.pane, cd.target) do g.areas.op = {kind = .Join, pane = cd.pane, other = cd.target}
		else do g.areas.cancels += 1
	}
}

// A pill of `text` centred at `at`, in `fill` with `ink` text.
@(private = "file")
grid_pill :: proc(ctx: ^ui.Context, text: string, at: [2]f32, fill, ink: ui.Color) {
	t := ctx.theme
	w := ui.text_width(ctx, text, t.small_size, .Semibold) + 22
	ui.fill_rect(ctx, {at.x - w * 0.5, at.y - 14, w, 28}, 14, fill)
	ui.text(ctx, text, at.x, at.y, t.small_size, ink, .Semibold, .Center)
}

// What the gestures show over the panes while they go on: the split's line, share and new
// part, the join's growing and closing panes, and the chip drag's targets.
lens_areas_overlay :: proc(app: ^App, cells: [GRID_PANES]ui.Rect, n: int) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	g := &k.grid
	cd := &g.areas.corner
	if k.chrome != .Lens do return
	ui.begin_at(ctx, "pane gestures", {0, 0}, {width = 0, height = 0})
	defer ui.end(ctx)
	if cd.live && cd.mode != .Undecided {
		// The way from the corner to the finger, dotted.
		d := cd.finger - cd.at
		steps := int(linalg.length(d) / 8)
		for j in 0 ..< steps do ui.fill_circle(ctx, cd.at + d * (f32(j) / f32(max(steps, 1))), 1.5, ui.color_fade(t.text, 0.8))
		ui.stroke_circle(ctx, cd.finger, 16, t.text, 2)
	}
	if cd.live && cd.mode == .Split {
		c := cells[cd.pane]
		first := cd.inward.x > 0 if cd.vertical else cd.inward.y > 0
		a, b := grid_cut_rect(c, cd.vertical, cd.share, GRID_GAP)
		fresh := a if first else b
		if n < GRID_PANES {
			ui.fill_rect(ctx, fresh, 0, ui.color_fade(t.accent, 0.16))
			ui.stroke_rect(ctx, fresh, 0, ui.color_fade(t.accent, 0.6), 1)
			grid_pill(ctx, fmt.tprintf("New pane · copies %s", grid_pane_name(g, cd.pane)), {fresh.x + fresh.w * 0.5, fresh.y + fresh.h * 0.5}, ui.color_fade(t.frame, 0.9), t.text)
		}
		line := ui.Rect{a.x + a.w, c.y, GRID_GAP, c.h} if cd.vertical else ui.Rect{c.x, a.y + a.h, c.w, GRID_GAP}
		ui.fill_rect(ctx, line, 0, t.accent)
		left := int(math.round(cd.share * 100))
		label := fmt.tprintf("Split · %d / %d", left, 100 - left) if n < GRID_PANES else "Up to four panes"
		grid_pill(ctx, label, cd.finger + {0, -44}, t.accent if n < GRID_PANES else t.surface, t.on_accent if n < GRID_PANES else t.text)
		grid_pill(ctx, "Back to the corner cancels · into the next pane joins", cd.finger + {0, 44}, ui.color_fade(t.frame, 0.9), t.text_secondary)
	}
	if cd.live && cd.mode == .Join {
		keep := cells[cd.pane]
		ui.fill_rect(ctx, keep, 0, ui.color_fade(t.accent, 0.14))
		ui.stroke_rect(ctx, keep, 0, t.accent, 2)
		if cd.target >= 0 {
			c := cells[cd.target]
			note := "Let go to join"
			if cd.target == 0 do note = "The main view stays"
			else if !grid_joinable(g, cd.pane, cd.target) do note = "These panes don't line up"
			if note == "Let go to join" do ui.fill_rect(ctx, c, 0, ui.color_fade(t.frame, 0.7))
			grid_pill(ctx, note, {c.x + c.w * 0.5, c.y + c.h * 0.5}, ui.color_fade(t.frame, 0.9), t.text)
		}
	}
	chip := &g.areas.chip
	if chip.pane != 0 && chip.moving {
		target, zone := chip_target(g, cells, n, chip.at)
		if target >= 0 {
			c := cells[target]
			mid := [2]f32{c.x + c.w * 0.5, c.y + c.h * 0.5}
			preview := c
			switch zone {
			case 0:
				ui.fill_rect(ctx, cells[chip.pane], 0, ui.color_fade(t.accent, 0.12))
			case 1 + int(Grid_Edge.Left):   preview.w *= 0.5
			case 1 + int(Grid_Edge.Right):  preview.x, preview.w = c.x + c.w * 0.5, c.w * 0.5
			case 1 + int(Grid_Edge.Top):    preview.h *= 0.5
			case 1 + int(Grid_Edge.Bottom): preview.y, preview.h = c.y + c.h * 0.5, c.h * 0.5
			}
			ui.fill_rect(ctx, preview, 0, ui.color_fade(t.accent, 0.22))
			// The five targets, after Blender's area docking: the middle swaps, the four
			// triangles dock on their edge.
			lit :: proc(t: ui.Theme, on: bool) -> ui.Color {return t.accent if on else ui.color_fade(t.text, 0.75)}
			ui.fill_rect(ctx, {mid.x - 22, mid.y - 22, 44, 44}, 8, ui.color_fade(t.frame, 0.85))
			ui.stroke_rect(ctx, {mid.x - 22, mid.y - 22, 44, 44}, 8, lit(t, zone == 0), 2)
			arrows := [4][3][2]f32 {
				{{-58, 0}, {-42, -12}, {-42, 12}},
				{{58, 0}, {42, -12}, {42, 12}},
				{{0, -58}, {-12, -42}, {12, -42}},
				{{0, 58}, {-12, 42}, {12, 42}},
			}
			for tri, e in arrows {
				pts := [3][2]f32{mid + tri[0], mid + tri[1], mid + tri[2]}
				ui.fill_convex(ctx, pts[:], lit(t, zone == 1 + e))
			}
			sides := [Grid_Edge]string{.Left = "left", .Right = "right", .Top = "on top", .Bottom = "below"}
			grid_pill(ctx, "Swap" if zone == 0 else fmt.tprintf("Dock %s", sides[Grid_Edge(zone - 1)]), mid + {0, 84}, ui.color_fade(t.frame, 0.9), t.text)
		}
		grid_pill(ctx, grid_pane_name(g, chip.pane), chip.at + {0, -28}, t.accent, t.on_accent)
	}
}

// The pane under `at` a dragged chip would drop on, and how: 0 swaps (the middle third),
// 1 + an edge docks there (the triangles between the diagonals); -1 for none.
chip_target :: proc(g: ^View_Grid, cells: [GRID_PANES]ui.Rect, n: int, at: [2]f32) -> (target, zone: int) {
	target = -1
	for i in 0 ..< n {
		r := cells[i]
		if i != g.areas.chip.pane && at.x >= r.x && at.x <= r.x + r.w && at.y >= r.y && at.y <= r.y + r.h do target = i
	}
	if target < 0 do return
	c := cells[target]
	rel := [2]f32{(at.x - c.x) / max(c.w, 1) * 2 - 1, (at.y - c.y) / max(c.h, 1) * 2 - 1}
	if abs(rel.x) < 1.0 / 3 && abs(rel.y) < 1.0 / 3 do return target, 0
	if abs(rel.x) >= abs(rel.y) do return target, 1 + int(Grid_Edge.Left if rel.x < 0 else Grid_Edge.Right)
	return target, 1 + int(Grid_Edge.Top if rel.y < 0 else Grid_Edge.Bottom)
}

// A view pane's camera chip `a` as a handle: past the slop it carries the pane, and let go
// over another pane it swaps or docks there. Returns whether the chip was dragged, so its
// tap does not open the list.
lens_chip_drag :: proc(app: ^App, pane: int, a: ui.Area, cells: [GRID_PANES]ui.Rect, n: int) -> (dragged: bool) {
	g := &app.kit.grid
	chip := &g.areas.chip
	if a.pressed do chip^ = {pane = pane, from = a.mouse, at = a.mouse}
	if chip.pane != pane do return false
	if a.held {
		chip.at = a.mouse
		if !chip.moving && linalg.length(a.mouse - chip.from) > GRID_CHIP_SLOP do chip.moving = true
		if chip.moving && (app.touch.fingers.count >= 2 || key_pressed(&app.device, sdl.K_ESCAPE) || app.kit.ctx.input.cancel) {
			chip^ = {}
			g.areas.cancels += 1
		}
		return chip.moving
	}
	dragged = chip.moving
	if dragged {
		target, zone := chip_target(g, cells, n, chip.at)
		if target >= 0 && zone == 0 do g.areas.op = {kind = .Swap, pane = pane, other = target}
		else if target >= 0 do g.areas.op = {kind = .Dock, pane = pane, other = target, edge = Grid_Edge(zone - 1)}
	}
	chip^ = {}
	return
}

// Opens divider `node`'s menu at `point`.
divider_menu_open :: proc(app: ^App, node: int, point: [2]f32) {
	k := &app.kit
	kit_floats_close(k)
	k.grid.areas.menu = {open = true, node = node, at = {point.x - 1, point.y - 1, 2, 2}, point = point, serial = k.grid.serial}
}

// A divider's menu: Split here (the pane on the side pressed, cut across through the point
// pressed), Join (keeping either side when both are single panes; the main view always
// stays), Swap sides and Even out.
kit_divider_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	g := &k.grid
	m := &g.areas.menu
	if m.open && (m.serial != g.serial || k.chrome != .Lens || m.node >= g.tree.count || !g.tree.nodes[m.node].split) do m.open = false
	if !ui.popover_begin(ctx, "divider menu", &m.open, m.at, .Below, {direction = .Column, padding = 6, width = 240}) do return
	defer ui.popover_end(ctx)
	node := g.tree.nodes[m.node]
	n := grid_panes(g)
	room := view_grid_room(app)
	cells, rooms := grid_tree_cells(&g.tree, room)
	// The pane beside the divider on the side pressed.
	divs, count := grid_dividers(&g.tree, rooms)
	mid: f32
	for d in divs[:count] do if d.node == m.node do mid = d.line.x + d.line.w * 0.5 if node.vertical else d.line.y + d.line.h * 0.5
	probe := m.point
	if node.vertical do probe.x = mid + (-12 if m.point.x < mid else 12)
	else do probe.y = mid + (-12 if m.point.y < mid else 12)
	side := -1
	for i in 0 ..< n {
		r := cells[i]
		if probe.x >= r.x && probe.x <= r.x + r.w && probe.y >= r.y && probe.y <= r.y + r.h do side = i
	}
	ui.caption(ctx, "  DIVIDER")
	if ui.menu_item(ctx, "Split here", enabled = n < GRID_PANES && side >= 0, hint = "" if n < GRID_PANES else "Up to four panes") {
		c := cells[side]
		share := (m.point.x - c.x) / max(c.w, 1) if !node.vertical else (m.point.y - c.y) / max(c.h, 1)
		g.areas.op = {kind = .Split, pane = side, vertical = !node.vertical, share = share, first = false, view = grid_pane_copy(app, side)}
		m.open = false
	}
	a, b := g.tree.nodes[node.a], g.tree.nodes[node.b]
	if !a.split && !b.split {
		if b.pane != 0 && ui.menu_item(ctx, fmt.tprintf("Join, keep %s", grid_pane_name(g, int(a.pane)))) {
			g.areas.op = {kind = .Join, pane = int(a.pane), other = int(b.pane)}
			m.open = false
		}
		if a.pane != 0 && ui.menu_item(ctx, fmt.tprintf("Join, keep %s", grid_pane_name(g, int(b.pane)))) {
			g.areas.op = {kind = .Join, pane = int(b.pane), other = int(a.pane)}
			m.open = false
		}
	} else {
		_ = ui.menu_item(ctx, "Join", enabled = false, hint = "Only two single panes join")
	}
	if ui.menu_item(ctx, "Swap sides") {
		g.areas.op = {kind = .Swap_Sides, node = m.node}
		m.open = false
	}
	if ui.menu_item(ctx, "Even out") {
		g.areas.op = {kind = .Even, node = m.node}
		m.open = false
	}
}
