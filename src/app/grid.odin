package main

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

import sdl "vendor:sdl3"

import "../render"
import "../ui"

// The view grid (Camera > View grid, Lens): the viewport split into one to four panes by
// a preset, never by free splits, so a layout cannot be broken. Pane 0 is the main view,
// where the camera, the tools and the heavy passes live; panes 1 to 3 are view panes,
// second views (thumbnail.odin) tiled beside it, each with its own camera and cheap pass,
// drawn only at rest so a big mesh is never drawn twice a frame while you work. The idea
// is Blender's quad view and split areas, kept to presets as ZBrush and Nomad keep one
// view, with a new pane starting as the partner a sculptor wants (front beside the
// perspective, the side beside the front) as Maya's and 3ds Max's four views do.

Grid_Preset :: enum u8 {
	Single,
	Side_By_Side,
	Stacked,
	One_Plus_Two, // a big pane on the left, two stacked on the right
	Four,
	Three_Across,
}

@(rodata)
GRID_NAMES := [Grid_Preset]string {
	.Single       = "Single",
	.Side_By_Side = "Side by side",
	.Stacked      = "Stacked",
	.One_Plus_Two = "One plus two",
	.Four         = "Four",
	.Three_Across = "Three across",
}

// The most panes a preset shows, and so view panes beside the main one.
GRID_PANES :: 4
GRID_VIEWS :: GRID_PANES - 1

// Points between two panes, where the frame shows through as their divider.
GRID_GAP :: 2
// How close a split may come to the room's edge (or, three across, to the other split).
GRID_SPLIT_MIN :: 0.2
GRID_THIRDS_MIN :: 0.15

// The grid's choices, kept by workspaces (workspaces.odin): the preset, each preset's
// splits as shares of the room (zero for its default), and each preset's view panes.
View_Grid :: struct {
	preset:    Grid_Preset,
	split:     [Grid_Preset][2]f32,
	views:     [Grid_Preset][GRID_VIEWS]Second_View,
	maximised: int, // the view pane filling the grid (1 to 3), 0 for none; never kept
	// This frame's layout, never kept: the main pane's rect in points, and each view
	// pane's picture size in pixels (zero for one not shown).
	main:      ui.Rect,
	px:        [GRID_VIEWS][2]u32,
	dragged:   int, // the divider held (1 + its index), 0 for none, for the exit stats
	drags:     int, // frames a divider moved, for the exit stats
}

// How many panes a preset shows.
grid_count :: proc(preset: Grid_Preset) -> int {
	switch preset {
	case .Single:                  return 1
	case .Side_By_Side, .Stacked:  return 2
	case .One_Plus_Two, .Three_Across: return 3
	case .Four:                    return 4
	}
	return 1
}

// A preset's splits as shares of the room: x then y, or, three across, the two x splits.
grid_split :: proc(g: ^View_Grid, preset: Grid_Preset) -> [2]f32 {
	s := g.split[preset]
	def := [2]f32{0.5, 0.5}
	if preset == .One_Plus_Two do def.x = 0.6
	if preset == .Three_Across do def = {1.0 / 3, 2.0 / 3}
	if s == {} do return def
	return grid_split_clamp(preset, s)
}

// Keeps splits clear of the room's edges and, three across, of each other.
grid_split_clamp :: proc(preset: Grid_Preset, s: [2]f32) -> [2]f32 {
	if preset == .Three_Across {
		a := clamp(s.x, GRID_THIRDS_MIN, 1 - 2 * GRID_THIRDS_MIN)
		return {a, clamp(s.y, a + GRID_THIRDS_MIN, 1 - GRID_THIRDS_MIN)}
	}
	return {clamp(s.x, GRID_SPLIT_MIN, 1 - GRID_SPLIT_MIN), clamp(s.y, GRID_SPLIT_MIN, 1 - GRID_SPLIT_MIN)}
}

// The panes' rects in `room`, pane 0 (the main view) first, with GRID_GAP between
// neighbours; the rest of the four are empty.
grid_cells :: proc(preset: Grid_Preset, split: [2]f32, room: ui.Rect) -> (cells: [GRID_PANES]ui.Rect) {
	G :: GRID_GAP
	r := room
	// The left (or top) part of `r` up to share `s`, and the rest past the gap.
	cut_x :: proc(r: ui.Rect, s: f32) -> (a, b: ui.Rect) {
		w := r.w * s - G * 0.5
		return {r.x, r.y, w, r.h}, {r.x + w + G, r.y, r.w - w - G, r.h}
	}
	cut_y :: proc(r: ui.Rect, s: f32) -> (a, b: ui.Rect) {
		h := r.h * s - G * 0.5
		return {r.x, r.y, r.w, h}, {r.x, r.y + h + G, r.w, r.h - h - G}
	}
	switch preset {
	case .Single:
		cells[0] = r
	case .Side_By_Side:
		cells[0], cells[1] = cut_x(r, split.x)
	case .Stacked:
		cells[0], cells[1] = cut_y(r, split.y)
	case .One_Plus_Two:
		right: ui.Rect
		cells[0], right = cut_x(r, split.x)
		cells[1], cells[2] = cut_y(right, split.y)
	case .Four:
		top, bottom := cut_y(r, split.y)
		cells[0], cells[1] = cut_x(top, split.x)
		cells[2], cells[3] = cut_x(bottom, split.x)
	case .Three_Across:
		rest: ui.Rect
		cells[0], rest = cut_x(r, split.x)
		// The second split is a share of the whole room, so it stays where it was put.
		cells[1], cells[2] = cut_x(rest, (r.w * split.y - (rest.x - r.x)) / max(rest.w, 1))
	}
	return
}

// The view panes a preset starts with: the partner a sculptor wants beside the main view.
grid_views_default :: proc(preset: Grid_Preset) -> (views: [GRID_VIEWS]Second_View) {
	for &v in views do v.pass = .Shaded
	switch preset {
	case .Single:
	case .Side_By_Side, .Stacked:
		views[0].camera = .Front
	case .One_Plus_Two, .Three_Across:
		views[0].camera, views[1].camera = .Front, .Right
	case .Four:
		views[0].camera, views[1].camera, views[2].camera = .Front, .Right, .Top
	}
	return
}

// Puts every preset's splits and view panes back as a new user finds them.
grid_reset :: proc(g: ^View_Grid) {
	g.preset, g.maximised = .Single, 0
	g.split = {}
	for preset in Grid_Preset do g.views[preset] = grid_views_default(preset)
}

// A layout's grid lines (workspaces.odin): none for Single, so every layout saved before
// the grid reads as it was; else the preset and its splits, then each view pane's camera
// and pass. A Free camera's turn is not kept, as the second view's is not.
grid_layout_lines :: proc(k: ^Kit_State) -> string {
	g := &k.grid
	if g.preset == .Single do return ""
	b := strings.builder_make(context.temp_allocator)
	s := grid_split(g, g.preset)
	// Splits in thousandths, which read back exactly, so the modified dot clears.
	fmt.sbprintf(&b, "grid %v %d %d\n", g.preset, int(math.round(s.x * 1000)), int(math.round(s.y * 1000)))
	for v, i in g.views[g.preset][:grid_count(g.preset) - 1] do fmt.sbprintf(&b, "pane %d %v %v\n", i + 1, v.camera, v.pass)
	return strings.to_string(b)
}

// Reads a layout's grid or pane line's words; a word naming nothing leaves what it named.
grid_layout_read :: proc(k: ^Kit_State, f: []string) {
	g := &k.grid
	switch {
	case f[0] == "grid" && len(f) >= 2:
		for p in Grid_Preset do if strings.equal_fold(fmt.tprint(p), f[1]) do g.preset = p
		// Its panes start as the preset's partners; the pane lines after it say otherwise.
		g.views[g.preset] = grid_views_default(g.preset)
		if len(f) < 4 do return
		x, okx := strconv.parse_int(f[2])
		y, oky := strconv.parse_int(f[3])
		if okx && oky && x > 0 && x < 1000 && y > 0 && y < 1000 do g.split[g.preset] = grid_split_clamp(g.preset, {f32(x), f32(y)} / 1000)
	case f[0] == "pane" && len(f) >= 4:
		i, ok := strconv.parse_int(f[1])
		if !ok || i < 1 || i > GRID_VIEWS do return
		v := &g.views[g.preset][i - 1]
		for c in Second_Camera do if strings.equal_fold(fmt.tprint(c), f[2]) do v.camera = c
		for p in Second_Pass do if strings.equal_fold(fmt.tprint(p), f[3]) do v.pass = p
	}
}

// Shows the grid in `preset`; a pane that filled it gives the room back.
grid_set :: proc(k: ^Kit_State, preset: Grid_Preset) {
	k.grid.preset, k.grid.maximised = preset, 0
}

// The grid's room in points: the whole window in Single, as the viewport always was, and
// with more panes while they run under the panels (Settings > Interface, the default); else
// the room between the docked columns (as last laid out), so no pane lies under one. Too
// narrow a room between them keeps the window.
view_grid_room :: proc(app: ^App) -> ui.Rect {
	k := &app.kit
	win := k.ctx.input.window
	whole := ui.Rect{0, 0, win.x, win.y}
	if k.grid.preset == .Single || k.panes_under do return whole
	lo, hi := f32(0), win.x
	for side in Column_Side {
		c := k.panels.rect[side]
		if c.w <= 0 do continue
		if c.x + c.w * 0.5 < win.x * 0.5 do lo = max(lo, c.x + c.w + GRID_COLUMN_GAP)
		else do hi = min(hi, c.x - GRID_COLUMN_GAP)
	}
	if hi - lo < win.x * 0.4 do return whole
	return {lo, 0, hi - lo, win.y}
}

// Where a docked left column ends, so a pane's head that would lie under it starts right of
// it instead while the panes run under the panels; 0 with none.
grid_left_column_edge :: proc(app: ^App) -> f32 {
	k := &app.kit
	edge: f32 = 0
	for side in Column_Side {
		c := k.panels.rect[side]
		if c.w > 0 && c.x + c.w * 0.5 < k.ctx.input.window.x * 0.5 do edge = max(edge, c.x + c.w + GRID_COLUMN_GAP)
	}
	return edge
}

// Points between a docked column and the grid.
GRID_COLUMN_GAP :: 8
// The width of a divider's grab strip, in points, centred on its gap.
GRID_GRAB :: 16

// A divider: the gap it lies along, which split it moves (0 x, 1 y) and its direction.
@(private = "file")
Grid_Divider :: struct {
	line:     ui.Rect,
	axis:     int,
	vertical: bool,
}

// The dividers a preset has, along its panes' gaps.
@(private = "file")
grid_dividers :: proc(preset: Grid_Preset, cells: [GRID_PANES]ui.Rect, room: ui.Rect) -> (out: [2]Grid_Divider, n: int) {
	right_of :: proc(c: ui.Rect, room: ui.Rect) -> ui.Rect {return {c.x + c.w, room.y, GRID_GAP, room.h}}
	below :: proc(c: ui.Rect, x0, x1: f32) -> ui.Rect {return {x0, c.y + c.h, x1 - x0, GRID_GAP}}
	end := room.x + room.w
	switch preset {
	case .Single:
	case .Side_By_Side:
		out[0], n = {right_of(cells[0], room), 0, true}, 1
	case .Stacked:
		out[0], n = {below(cells[0], room.x, end), 1, false}, 1
	case .One_Plus_Two:
		out[0] = {right_of(cells[0], room), 0, true}
		out[1], n = {below(cells[1], cells[1].x, end), 1, false}, 2
	case .Four:
		out[0] = {right_of(cells[0], room), 0, true}
		out[1], n = {below(cells[0], room.x, end), 1, false}, 2
	case .Three_Across:
		out[0] = {right_of(cells[0], room), 0, true}
		out[1], n = {right_of(cells[1], room), 1, true}, 2
	}
	return
}

// Lays out the grid under every panel: the viewport's image in the main pane, each view
// pane with its picture, its camera and pass and Maximise, and the dividers. Sets where
// the main pane goes (k.grid.main) and each picture's size.
kit_grid :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	g := &k.grid
	room := view_grid_room(app)
	split := grid_split(g, g.preset)
	cells := grid_cells(g.preset, split, room)
	n := grid_count(g.preset)
	if g.maximised >= n do g.maximised = 0
	// Each pane on whole pixels, so the main view's input size and its target's agree
	// exactly and its unsmoothed image never shimmers.
	if g.preset != .Single {
		px := ctx.input.pixel_density
		for &c in cells[:n] {
			x0, y0 := math.round(c.x * px) / px, math.round(c.y * px) / px
			x1, y1 := math.round((c.x + c.w) * px) / px, math.round((c.y + c.h) * px) / px
			c = {x0, y0, x1 - x0, y1 - y0}
		}
	}
	g.main = cells[0]
	ui.image(ctx, g.main, KIT_VIEWPORT_IMAGE)
	// With other panes beside it, the main pane is outlined in the main camera's colour, the
	// colour of the dots of the panes linked to it: the pane the tools act in.
	if n > 1 && g.maximised == 0 {
		m := g.main
		ui.stroke_rect(ctx, {m.x + 1, m.y + 1, m.w - 2, m.h - 2}, 0, ctx.theme.camera[0], 2)
	}
	// What is drawn over the main view (overlay.odin) goes here, under the view panes.
	k.layer = ui.layer_mark(ctx)
	kit_wipe(app, g.main)
	guides_frame(app)
	kit_guides(app, g.main, app.camera, "main")
	// While a divider is dragged the pictures keep their size, stretched, as the main
	// view's does: each is drawn again at its new size once it is let go.
	resizing := g.dragged != 0
	if !resizing do g.px = {}
	d := ctx.input.pixel_density
	for i in 1 ..< n {
		if g.maximised != 0 && g.maximised != i do continue
		r := room if g.maximised == i else cells[i]
		if !resizing do g.px[i - 1] = {u32(r.w * d + 0.5), u32(r.h * d + 0.5)}
		kit_view_pane(app, i, r)
	}
	if g.maximised != 0 do return
	dividers, count := grid_dividers(g.preset, cells, room)
	g.dragged = 0
	for div, i in dividers[:count] {
		grab := div.line
		if div.vertical do grab.x, grab.w = grab.x + grab.w * 0.5 - GRID_GRAB * 0.5, GRID_GRAB
		else do grab.y, grab.h = grab.y + grab.h * 0.5 - GRID_GRAB * 0.5, GRID_GRAB
		ui.begin_at(ctx, fmt.tprintf("grid divider %d", i), {grab.x, grab.y}, {width = grab.w, height = grab.h})
		a := ui.area(ctx, "grab", {grab.w, grab.h})
		t := ctx.theme
		color := t.accent if a.held else t.border_strong if a.hovered else t.frame
		ui.fill_rect(ctx, div.line, 0, color)
		if a.held {
			g.dragged = i + 1
			s := split
			s[div.axis] = (a.mouse.x - room.x) / room.w if div.vertical else (a.mouse.y - room.y) / room.h
			s = grid_split_clamp(g.preset, s)
			if s != split do g.drags += 1
			g.split[g.preset] = s
		}
		ui.end(ctx)
	}
}

// A view pane at `r`: its picture, which a drag turns and the wheel zooms, and over its
// top left corner (clear of the top bar and the brush bar) its camera, its pass and
// Maximise or Restore.
@(private = "file")
kit_view_pane :: proc(app: ^App, i: int, r: ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	g := &k.grid
	sv := &g.views[g.preset][i - 1]
	ui.begin_at(ctx, fmt.tprintf("view pane %d", i), {r.x, r.y}, {width = r.w, height = r.h})
	a := ui.area(ctx, "picture", {r.w, r.h})
	ui.fill_rect(ctx, a.rect, 0, t.pane)
	if app.panes[i - 1].shown != nil do ui.image(ctx, a.rect, KIT_PANE_IMAGE + u64(i - 1))
	second_view_input(app, sv, a)
	ui.end(ctx)
	if app.panes[i - 1].shown != nil do kit_guides(app, r, app.panes[i - 1].orbit, fmt.tprintf("pane %d", i))
	head := [2]f32{max(r.x, kit_left(app), grid_left_column_edge(app)) + 6, max(r.y, kit_top() - 8) + 6}
	// Under the panels a docked right column may cover the pane's right part: a head too
	// wide for the room left of it takes two rows, so Link and Maximise stay in reach.
	room := r.x + r.w - head.x - 6
	for side in Column_Side {
		c := k.panels.rect[side]
		if c.w > 0 && c.x > head.x && c.x < r.x + r.w do room = min(room, c.x - GRID_COLUMN_GAP - head.x)
	}
	narrow := room < 2 * 4 + 14 + 2 * GRID_SELECT_W + 2 * t.target + 4 * 4
	ui.begin_at(ctx, fmt.tprintf("view pane %d head", i), head, {direction = .Column, gap = 0, padding = 4, radius = t.radius_large, background = .Panel})
	ui.begin(ctx, "first row", {direction = .Row, center = true, gap = 4})
	dot, ring := second_color(t, sv, i)
	camera_dot(ctx, dot, ring)
	cameras := make([]string, len(Second_Camera), context.temp_allocator)
	for name, c in SECOND_CAMERA_NAMES do cameras[c] = name
	if picked := ui.select(ctx, "Camera", cameras, int(sv.camera), GRID_SELECT_W); picked >= 0 && Second_Camera(picked) != sv.camera {
		if Second_Camera(picked) == .Free do second_free(app, sv)
		else do sv.camera = Second_Camera(picked)
	}
	linked := second_linked(sv)
	link :: proc(app: ^App, sv: ^Second_View, linked: bool) {
		if ui.icon_button(&app.kit.ctx, "Unlink from the main camera" if linked else "Link to the main camera", ICON_LINK, selected = linked) do second_link_toggle(app, sv)
	}
	if narrow {
		link(app, sv, linked)
		ui.end(ctx)
		ui.begin(ctx, "second row", {direction = .Row, center = true, gap = 4})
		ui.spacer(ctx, 14)
	}
	passes := make([]string, len(Second_Pass), context.temp_allocator)
	for name, kind in SECOND_PASS_NAMES do passes[kind] = name
	if picked := ui.select(ctx, "Shows", passes, int(sv.pass), GRID_SELECT_W); picked >= 0 do sv.pass = Second_Pass(picked)
	if !narrow do link(app, sv, linked)
	maxed := g.maximised == i
	if ui.icon_button(ctx, "Restore" if maxed else "Maximise", ui.ICON_MINIMISE if maxed else ui.ICON_RESTORE, selected = maxed) do g.maximised = 0 if maxed else i
	ui.end(ctx)
	ui.end(ctx)
}

// A view pane's selects, in points: room for "Curvature" and "Mirrored".
GRID_SELECT_W :: 116

// Lucide's link: a view's camera tied to the main one.
ICON_LINK :: rune(0xe108)

// Draws each view pane shown whose picture is due, as the second view does (thumbnail.odin).
grid_frame :: proc(app: ^App, cmd: ^sdl.GPUCommandBuffer, draws: []render.Draw_Item) {
	k := &app.kit
	for &pic, i in app.panes {
		size := k.grid.px[i]
		if k.home || size.x == 0 || size.y == 0 {
			pic.shown, pic.due = nil, false
			continue
		}
		picture_frame(app, cmd, draws, &k.grid.views[k.grid.preset][i], &pic, size, 1)
	}
}

// Whether a view pane waits to be drawn again, which keeps the frames coming.
grid_due :: proc(app: ^App) -> bool {
	for pic in app.panes do if pic.due do return true
	return false
}

grid_destroy :: proc(app: ^App) {
	for &pic in app.panes do picture_destroy(app, &pic)
}

// A point in window coordinates in the main pane's, as Viewport_Input has it.
viewport_point :: proc(app: ^App, p: [2]f32) -> [2]f32 {
	return p - app.ui.viewport_origin
}
