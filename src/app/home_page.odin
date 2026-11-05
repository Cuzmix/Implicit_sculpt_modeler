package main

import "core:fmt"
import "core:path/filepath"
import "core:strings"

import "../render"
import "../ui"

// Home's page below its heading (kit_home draws the heading and the scroll), from round 2
// of the mockups (screen home2). On a window HOME_WIDE wide or more the Continue card and
// Start new share the top row; narrower (a phone, a tablet's split view) Start new goes
// under the card. Then Recent and Autosaves as pictures, with Open and Import beside their
// tabs, or under them when narrow.

// The width from which Start new sits beside the Continue card, in points.
HOME_WIDE :: 760

// The Start new tiles, by NEW_SCENES index, in the mock's order: Sphere, Head, Cube,
// Voxel block, Plane and Empty scene; the others are More starters.
@(rodata)
HOME_STARTS := [6]int{0, 1, 6, 8, 7, 9}
@(rodata)
HOME_MORE := [4]int{2, 3, 4, 5}

// Lucide's user-round, pressed into the Head tile's ball.
@(private = "file")
ICON_HEAD :: rune(0xe46d)

// A warm clay, as the mock's starters are.
@(private = "file")
CLAY :: ui.Color{206, 170, 148, 255}
@(private = "file")
GAP :: 16
// The Continue card's and the Start new block's height side by side, and the card's
// height over Start new.
@(private = "file")
TOP_H :: 360
@(private = "file")
CARD_H_NARROW :: 260

// The page below the heading, `width` wide.
home_body :: proc(app: ^App, width: f32) {
	k := &app.kit
	ctx := &k.ctx
	if width >= HOME_WIDE {
		card_w := f32(int((width - GAP) * 0.47))
		ui.begin(ctx, "home top", {direction = .Row, gap = GAP, width = width})
		home_continue_card(app, {card_w, TOP_H})
		home_starts(app, width - card_w - GAP, TOP_H)
		ui.end(ctx)
	} else {
		home_continue_card(app, {width, CARD_H_NARROW})
		ui.spacer(ctx, 4)
		home_starts(app, width, 0)
	}

	// Recent and Autosaves, with the ways to bring a file in at their right, or under
	// their tabs when there is no room beside them.
	ui.spacer(ctx, 8)
	open_w, import_w: f32 = 120, 210
	wide := width >= HOME_WIDE
	if wide {
		ui.begin(ctx, "home recent head", {direction = .Row, gap = ui.SPACE_M, center = true, width = width})
		ui.begin(ctx, "home tabs", {direction = .Row, width = width - open_w - import_w - 16})
		home_tabs(app, 320)
		ui.end(ctx)
	} else {
		home_tabs(app, width)
		ui.begin(ctx, "home recent head", {direction = .Row, gap = ui.SPACE_M, center = true, width = width})
		open_w = (width - 8) * 0.4
		import_w = width - 8 - open_w
	}
	if command_button(app, .Open_Scene, label = "Open...", variant = .Bordered, glyph = ui.ICON_OPEN, width = open_w) do home_close(app)
	if command_button(app, .Import_Mesh, label = "Import OBJ, PLY, STL..." if wide || import_w >= 210 else "Import...", variant = .Bordered, glyph = ui.ICON_IMPORT, width = import_w) do home_close(app)
	ui.end(ctx)
	home_grid(app, width)
}

// Start new, `w` wide: the six tiles in two rows of three, then More starters by name.
// Given a height `h` (beside the Continue card) the tiles fill it; with 0 they are about
// as tall as they are wide, at most 150 points.
@(private = "file")
home_starts :: proc(app: ^App, w, h: f32) {
	ctx := &app.kit.ctx
	t := ctx.theme
	ui.begin(ctx, "home starts", {direction = .Column, gap = ui.SPACE_M, width = w, height = h})
	ui.caption(ctx, "START NEW")
	more_h := t.target
	tile_w := (w - 2 * 12) / 3
	// The More starters' row, under its label when the row cannot hold both.
	MORE_LABEL_W :: 104
	stacked := (w - MORE_LABEL_W - 4 * 6) / 4 < 72
	tile_h := f32(int((h - ctx.last_rect.h - more_h - 3 * 10) / 2)) if h > 0 else min(tile_w, 150)
	for row in 0 ..< 2 {
		ui.begin(ctx, fmt.tprintf("home starts row %d", row), {direction = .Row, gap = ui.SPACE_L})
		for i in row * 3 ..< row * 3 + 3 do home_start_tile(app, HOME_STARTS[i], {tile_w, tile_h})
		ui.end(ctx)
	}
	// The other starters, by name: they are blockouts for a figure, used less often.
	if stacked do ui.label(ctx, "More starters", t.small_size, t.text_secondary)
	ui.begin(ctx, "home more", {direction = .Row, gap = ui.SPACE_S, center = true})
	button_w := (w - 3 * 6) / 4
	if !stacked {
		more := ui.place(ctx, {MORE_LABEL_W, more_h})
		ui.text(ctx, "More starters", more.x, more.y + more.h * 0.5, t.small_size, t.text_secondary)
		button_w = (w - MORE_LABEL_W - 4 * 6) / 4
	}
	for i in HOME_MORE {
		armed := new_scene_armed(app, i)
		label := fmt.tprintf("%s##home more %d", "Discard?" if armed else NEW_SCENES[i].name, i)
		if ui.button(ctx, label, .Solid if armed else .Bordered, .Danger if armed else .Neutral, width = button_w) do home_start(app, i)
	}
	ui.end(ctx)
	ui.end(ctx)
}

// Runs New scene for NEW_SCENES[i], closing Home unless the run only armed it.
@(private = "file")
home_start :: proc(app: ^App, i: int) {
	command_run(app, .New_Scene, i)
	if !new_scene_armed(app, i) do home_close(app)
}

// What the Continue card offers.
@(private = "file")
Continue_Kind :: enum u8 {
	Recent, // the newest Recent scene
	Autosave, // with nothing on Recent, the newest autosave
	Start, // with neither, a sphere to start on
}

// The Continue card, `size` big: the newest Recent scene's picture over all of it, its
// name and what the file says of it at the foot, and Open. With work to lose a first tap
// arms it (Kit_State.home_armed CONTINUE_ARMED) and a second opens, as a tile does.
@(private = "file")
home_continue_card :: proc(app: ^App, size: [2]f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	h := &app.home
	kind := Continue_Kind.Start
	path, name, line := "", "Sphere", "A fresh sphere at the Scene card's Add size, to start on."
	if len(app.recent_scenes) > 0 {
		kind, path = .Recent, app.recent_scenes[0]
		name = filepath.stem(path)
	} else if len(h.autosaves) > 0 {
		e := h.autosaves[0]
		kind, path = .Autosave, e.path
		name = fmt.tprintf("Autosave of %s", filepath.stem(e.scene)) if e.scene != "" else "Autosave of an unsaved scene"
		line = fmt.tprintf("Saved %s", saved_when(e.at))
	}
	tile: Home_Tile
	if kind != .Start do tile = home_tile(app, path)
	current := kind == .Recent && path == app.scene_path
	armed := k.home_armed == CONTINUE_ARMED && ctx.time - k.home_armed_at < NEW_SCENE_ARM_TIME
	switch {
	case kind == .Start:
	case tile.state == .Missing:
		line = "Not found"
	case kind == .Recent && tile.info.saved > 0:
		line = fmt.tprintf("Saved %s · %s vertices · %d %s", saved_when(tile.info.saved), count_label(tile.info.vertices), tile.info.objects, "object" if tile.info.objects == 1 else "objects")
	case kind == .Recent:
		line = "No picture"
	}
	if current do line = fmt.tprintf("Open now · %s", line)

	FOOT_H :: 96
	PAD :: 18
	ui.begin(ctx, "home continue", {direction = .Column, width = size.x, height = size.y})
	// The picture fills the whole card; the foot's band shades over its last part.
	tap := ui.area(ctx, "home continue picture", {size.x, size.y - FOOT_H}, drag = false)
	picture, clicked := tap.rect, tap.clicked
	card := ui.Rect{picture.x, picture.y, size.x, size.y}
	ui.fill_rect(ctx, card, t.radius_large, t.surface)
	switch {
	case tile.state == .Shown:
		lo, hi := render.picture_uv(tile.cell, tile.w, tile.h)
		ui.picture_cover(ctx, card, {image = KIT_PICTURES_IMAGE, lo = lo, hi = hi, aspect = f32(tile.w) / f32(tile.h)}, inset = 1)
	case kind == .Start:
		ui.fill_ball(ctx, {picture.x + picture.w * 0.5, picture.y + picture.h * 0.55}, min(picture.w, picture.h) * 0.36, CLAY)
	case:
		ui.icon(ctx, ICON_FILE_GONE if tile.state == .Missing else ui.ICON_IMAGE, {picture.x + picture.w * 0.5, picture.y + picture.h * 0.5}, t.icon_size + 12, t.text_tertiary)
	}
	ui.fill_rect(ctx, {card.x + 1, card.y + card.h - FOOT_H, card.w - 2, FOOT_H - 1}, 0, ui.color_fade(t.surface, 0.88))
	if tap.hovered || tap.held do ui.fill_rect(ctx, card, t.radius_large, ui.color_fade(t.text, 0.08 if tap.held else 0.04))
	ring := t.danger if armed else (t.accent if current else t.border)
	ui.stroke_rect(ctx, card, t.radius_large, ring, 2 if armed || current else 1)
	ui.tip(ctx, tap.id, picture, path if path != "" else name)

	label := "Open"
	switch {
	case armed:                  label = "Discard and open"
	case current:                label = "Back to it"
	case tile.state == .Missing: label = "Remove"
	case kind == .Autosave:      label = "Recover"
	case kind == .Start:         label = "Start"
	}
	button_w: f32 = 150 if armed else 120
	ui.begin(ctx, "home continue foot", {direction = .Row, center = true, gap = ui.SPACE_L, width = size.x, height = FOOT_H})
	ui.spacer(ctx, PAD)
	words := ui.place(ctx, {size.x - 2 * PAD - button_w - 2 * 12, FOOT_H})
	ui.text(ctx, "Continue" if kind != .Start else "Start sculpting", words.x, words.y + 22, t.small_size, t.text_secondary)
	ui.text(ctx, ui.text_fit(ctx, name, t.display_size, words.w, .Semibold), words.x, words.y + 48, t.display_size, t.text, .Semibold)
	ui.text(ctx, ui.text_fit(ctx, line, t.small_size, words.w), words.x, words.y + 74, t.small_size, t.text_tertiary if tile.state == .Missing else t.text_secondary)
	pressed := ui.button(ctx, fmt.tprintf("%s##home continue", label), .Solid, .Danger if armed else .Accent, width = button_w)
	ui.end(ctx)
	ui.end(ctx)
	if !(pressed || clicked) do return
	switch {
	case kind == .Start:
		home_start(app, 0)
	case current:
		home_close(app)
	case tile.state == .Missing:
		report(app, nil, {.Warning}, "%s is gone: it is off Recent now", filepath.base(path))
		recent_scene_drop(app, path)
	case home_work_to_lose(app) && !armed:
		k.home_armed, k.home_armed_at = CONTINUE_ARMED, max(ctx.time, 1e-6)
	case kind == .Recent:
		file_post(.Open, path)
		home_close(app)
	case:
		file_post(.Recover, h.autosaves[0].session)
		home_close(app)
	}
}

// When a scene was saved, to follow "Saved": home_when without its capital.
@(private = "file")
saved_when :: proc(at: i64) -> string {
	return strings.to_lower(home_when(at), context.temp_allocator)
}

// Kit_State.home_armed while the Continue card is armed: no tile's index + 1.
CONTINUE_ARMED :: -1

// A Start new tile `size` big for NEW_SCENES[i]: a drawing of what it starts in a well,
// and its name under it; with work to lose a first tap arms it and its name asks.
@(private = "file")
home_start_tile :: proc(app: ^App, i: int, size: [2]f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	tap := ui.area(ctx, fmt.tprintf("%s##home start %d", NEW_SCENES[i].name, i), size, drag = false)
	r := tap.rect
	armed := new_scene_armed(app, i)
	ui.fill_rect(ctx, r, t.radius_large, t.surface)
	if tap.hovered || tap.held do ui.fill_rect(ctx, r, t.radius_large, ui.color_fade(t.text, 0.08 if tap.held else 0.04))
	ui.stroke_rect(ctx, r, t.radius_large, t.danger if armed else t.border, 2 if armed else 1)
	label_h: f32 = 34
	c := [2]f32{r.x + r.w * 0.5, r.y + (r.h - label_h) * 0.5 + 6}
	s := min(r.w, r.h - label_h) * 0.5
	start_drawing(ctx, NEW_SCENES[i], c, s)
	name := "Discard?" if armed else NEW_SCENES[i].name
	ui.text(ctx, ui.text_fit(ctx, name, t.text_size, r.w - 12), c.x, r.y + r.h - label_h * 0.5 - 4, t.text_size, t.danger if armed else t.text, .Regular, .Center)
	ui.tip(ctx, tap.id, r, fmt.tprintf("New scene: %s", NEW_SCENES[i].name))
	if tap.clicked do home_start(app, i)
}

// What a start makes, drawn about `s` points across at `c`: a lit ball for the sphere
// and the head (with the head's glyph pressed in), a box in three shaded faces, a flat
// slab, a block of voxel squares, or a dashed square with a plus for an empty scene.
@(private = "file")
start_drawing :: proc(ctx: ^ui.Context, start: New_Start, c: [2]f32, s: f32) {
	t := ctx.theme
	shade :: proc(col: ui.Color, f: f32) -> ui.Color {
		return {u8(clamp(f32(col.r) * f, 0, 255)), u8(clamp(f32(col.g) * f, 0, 255)), u8(clamp(f32(col.b) * f, 0, 255)), col.a}
	}
	r := s * 0.8
	switch start.kind {
	case .Empty:
		box := ui.Rect{c.x - r * 0.75, c.y - r * 0.75, r * 1.5, r * 1.5}
		ui.stroke_rect(ctx, box, t.radius_medium, t.text_tertiary, 1)
		ui.icon(ctx, ui.ICON_PLUS, c, t.icon_size + 4, t.text_secondary)
	case .Voxels:
		CELLS :: 7
		side := r * 1.4
		cell := side / CELLS
		for y in 0 ..< CELLS do for x in 0 ..< CELLS {
			// Lit from the upper left, as the balls are.
			f := 1.08 - 0.05 * f32(x + y) / 2
			ui.fill_rect(ctx, {c.x - side * 0.5 + f32(x) * cell, c.y - side * 0.5 + f32(y) * cell, cell - 1.5, cell - 1.5}, 1, shade(CLAY, f))
		}
	case .Mesh:
		#partial switch start.shape {
		case .Cube:
			// An isometric box: the top lit most, the left face next, the right darkest.
			w, hh := r * 0.82, r * 0.47
			top := [4][2]f32{{c.x, c.y - r}, {c.x + w, c.y - r + hh}, {c.x, c.y - r + 2 * hh}, {c.x - w, c.y - r + hh}}
			left := [4][2]f32{top[3], top[2], {c.x, c.y + r}, {c.x - w, c.y + r - hh}}
			right := [4][2]f32{top[2], top[1], {c.x + w, c.y + r - hh}, {c.x, c.y + r}}
			ui.fill_convex(ctx, top[:], shade(CLAY, 1.08))
			ui.fill_convex(ctx, left[:], shade(CLAY, 0.82))
			ui.fill_convex(ctx, right[:], shade(CLAY, 0.62))
		case .Plane:
			// The same box squashed to a slab.
			w, hh, thick := r * 1.05, r * 0.3, r * 0.14
			top := [4][2]f32{{c.x, c.y - hh}, {c.x + w, c.y}, {c.x, c.y + hh}, {c.x - w, c.y}}
			left := [4][2]f32{top[3], top[2], {c.x, c.y + hh + thick}, {c.x - w, c.y + thick}}
			right := [4][2]f32{top[2], top[1], {c.x + w, c.y + thick}, {c.x, c.y + hh + thick}}
			ui.fill_convex(ctx, top[:], shade(CLAY, 1.05))
			ui.fill_convex(ctx, left[:], shade(CLAY, 0.78))
			ui.fill_convex(ctx, right[:], shade(CLAY, 0.6))
		case:
			ui.fill_ball(ctx, c, r * 0.9, CLAY)
			if start.shape == .Head {
				stamp := ui.Color{CLAY.r / 3, CLAY.g / 3, CLAY.b / 3, 210}
				ui.icon(ctx, ICON_HEAD, c, t.icon_size + 10, stamp)
			}
		}
	}
}
