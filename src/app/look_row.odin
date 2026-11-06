package main

import "../ui"

// The looks row: the four looks in a row under the pointer, to pick one without opening the
// shading list. Holding the shading chip past a long press (finger, pen or mouse) brings it
// up under the chip; holding L brings it up where the pointer is. Sliding sideways points
// at a look and letting go picks it; letting go off the row picks nothing. A quick tap of L
// steps to the next look instead.

// One look's cell in the row, in points: room for its glyph over its name.
LOOK_ROW_CELL_W :: 72
LOOK_ROW_CELL_H :: 56
// How long L may be held and still be a tap that steps to the next look, in seconds.
LOOK_ROW_TAP :: 0.25

// Where the row stands, in the interface's points: centred on `row_at`, kept inside the
// window.
look_row_rect :: proc(k: ^Kit_State) -> ui.Rect {
	w := f32(len(SHADING_LOOKS)) * LOOK_ROW_CELL_W + 2 * ui.SPACE_S
	h := f32(LOOK_ROW_CELL_H) + 2 * ui.SPACE_S
	win := k.ctx.input.window
	x := clamp(k.passes.row_at.x - w * 0.5, ui.SPACE_M, max(win.x - w - ui.SPACE_M, ui.SPACE_M))
	y := clamp(k.passes.row_at.y - h * 0.5, ui.SPACE_M, max(win.y - h - ui.SPACE_M, ui.SPACE_M))
	return {x, y, w, h}
}

// The look under the pointer, as an index into SHADING_LOOKS, or -1 off the row. Up and
// down within reach of the row still point, so a pen sliding sideways need not stay on it.
look_row_hover :: proc(k: ^Kit_State) -> int {
	r := look_row_rect(k)
	p := k.ctx.input.mouse
	if p.y < r.y - LOOK_ROW_CELL_H || p.y > r.y + r.h + LOOK_ROW_CELL_H do return -1
	i := int((p.x - r.x - ui.SPACE_S) / LOOK_ROW_CELL_W)
	return i if p.x >= r.x && i >= 0 && i < len(SHADING_LOOKS) else -1
}

// L went down or up over the app (frame_events), outside typing: down brings the row up at
// the pointer, up picks the look pointed at, or steps to the next look after a quick tap.
look_row_key :: proc(app: ^App, down: bool) {
	k := &app.kit
	ps := &k.passes
	if down {
		if ps.row_key do return
		ps.row, ps.row_key, ps.row_key_at = true, true, k.ctx.time
		ps.row_at = k.ctx.input.mouse
		return
	}
	if !ps.row_key do return
	ps.row_key = false
	if k.ctx.time - ps.row_key_at < LOOK_ROW_TAP {
		ps.row = false
		look_step(app)
		return
	}
	look_row_pick(app)
}

// The next look after the one shown, Flat going round to Clay; a pass showing gives way to
// the look shown.
look_step :: proc(app: ^App) {
	shown := main_shading_mode(app)
	at := 0
	for m, i in SHADING_LOOKS do if m == shown || (m == .Full && shown == .Rendered) do at = i
	command_run(app, .Shading_Mode, int(SHADING_LOOKS[(at + 1) % len(SHADING_LOOKS)]))
}

// Picks the look pointed at, if any, and puts the row away.
@(private = "file")
look_row_pick :: proc(app: ^App) {
	ps := &app.kit.passes
	ps.row = false
	if i := look_row_hover(&app.kit); i >= 0 {
		ps.row_picks += 1
		command_run(app, .Shading_Mode, int(SHADING_LOOKS[i]))
	}
}

// Each frame after the interface: the chip held past a long press brings the row up under
// it, and letting the chip go picks; then the row, over everything, while it is up.
look_row_frame :: proc(app: ^App) {
	k := &app.kit
	ps := &k.passes
	if ps.chip_held && !ps.row {
		ps.row = true
		chip := ps.chip_at
		ps.row_at = {chip.x + chip.w * 0.5, chip.y + chip.h + ui.SPACE_M + (LOOK_ROW_CELL_H + 2 * ui.SPACE_S) * 0.5}
	}
	if ps.row && !ps.row_key && !ps.chip_held do look_row_pick(app)
	if ps.row do look_row_draw(app)
}

@(private = "file")
look_row_draw :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	r := look_row_rect(k)
	hover := look_row_hover(k)
	shown := main_shading_mode(app)
	ui.layer_begin(ctx)
	ui.shadow_rect(ctx, r, t.radius_large, t.panel_shadow)
	ui.fill_rect(ctx, r, t.radius_large, t.surface_raised)
	ui.stroke_rect(ctx, r, t.radius_large, t.border, 1)
	for m, i in SHADING_LOOKS {
		cell := ui.Rect{r.x + ui.SPACE_S + f32(i) * LOOK_ROW_CELL_W, r.y + ui.SPACE_S, LOOK_ROW_CELL_W, LOOK_ROW_CELL_H}
		on := m == shown || (m == .Full && shown == .Rendered)
		if i == hover do ui.fill_rect(ctx, cell, t.radius_small, ui.color_mix(t.surface_raised, t.accent, 0.22))
		color := t.accent if on || i == hover else t.text
		mid := [2]f32{cell.x + cell.w * 0.5, cell.y + cell.h * 0.5}
		ui.icon(ctx, SHADING_MODE_ICONS[m], {mid.x, mid.y - 9}, t.icon_small, color)
		ui.text(ctx, SHADING_MODE_NAMES[m], mid.x, mid.y + 12, t.small_size, color, .Semibold if on else .Regular, .Center)
	}
}
