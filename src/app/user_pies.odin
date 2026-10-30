package main

import "core:fmt"
import "core:strings"

import "../sculpt"
import "../ui"

// The user's pies and favourites. Four pies of eight slots, each a registry command,
// open at the pointer with Q, Shift+Q or their own keys, as Blender's Q Quick Favourites
// and ZBrush for iPad's quick menu; favourites are commands starred in the palette,
// listed first while nothing is typed. Both are filled from the palette (its star and
// Put in a pie buttons), and the pie editor empties slots or puts the defaults back.

USER_PIES :: 4
PIE_SLOTS :: 8
MAX_FAVOURITES :: 16

// A command and its argument; `id == .None` is an empty slot.
Pie_Slot :: struct {
	id:  Command_Id,
	arg: int,
}

// The pies a fresh install has: the view and the object, and the mask and hiding; the
// other two wait for the user.
PIE_DEFAULTS :: [USER_PIES][PIE_SLOTS]Pie_Slot {
	{{.Focus_Selected, 0}, {.Frame_All, 0}, {.Wireframe, 0}, {.Flat_Shading, 0}, {.Ortho_Toggle, 0}, {.Studio_Render, 0}, {.Remesh, 0}, {.Command_Palette, 0}},
	{
		{.Mask, int(sculpt.Mask_Command.Clear)}, {.Mask, int(sculpt.Mask_Command.Invert)}, {.Mask, int(sculpt.Mask_Command.Blur)}, {.Mask, int(sculpt.Mask_Command.Sharpen)},
		{.Mask, int(sculpt.Mask_Command.Grow)}, {.Mask, int(sculpt.Mask_Command.Shrink)}, {.Show_All, 0}, {.Invert_Hidden, 0},
	},
	{},
	{},
}

// Whether a command can sit in a pie: not one that acts where the pointer is over the
// model (the pie is under it), and not a pie or the object menu, a menu opening a menu
// being a menu in a menu.
pie_lists :: proc(id: Command_Id) -> bool {
	if id == .Input_Diagnostics do return DIAGNOSTICS
	return id != .None && id != .Pie && id != .Brush_Pie && id != .Object_Menu && id != .Hd_Toggle && id != .Replay_Stroke && id != .Eyedropper
}

// Whether a pie must wait: a stroke, a drag on the viewport, the S/U adjust or Space's
// brush pie held.
pie_busy :: proc(app: ^App) -> bool {
	return app.stroke.active || app.ui.adjust.kind != .None || app.ui.pie.space_down || (ui.viewport_dragging(&app.kit.ctx) && .Left in app.device.down)
}

// Opens user pie `n` (from 0).
pie_toggle_user :: proc(app: ^App, n: int) {
	pie_toggle(app, n + 1)
}

// Opens pie `which` (0 the brushes, else a user pie) for a tap or click, at the pointer
// when it is over the viewport, else in the middle of the window, kept whole inside it;
// the same pie again closes it, another takes its place.
pie_toggle :: proc(app: ^App, which: int) {
	p := &app.ui.pie
	if p.open && p.which == which {
		p.open = false
		return
	}
	k := &app.kit
	area := ui.safe_area(&k.ctx)
	s := k.scale
	// In the main pane's coordinates, as the brush pie's and the overlay's are.
	o := app.ui.viewport_origin
	center := app.device.mouse - o if app.ui.viewport_hovered && !k.laying_out else [2]f32{area.x + area.w * 0.5, area.y + area.h * 0.5} * s - o
	if p.open do center = p.center
	// The labels reach past the ring a little; keep them on screen too.
	r := (PIE_OUTER + 24) * s
	lo, hi := [2]f32{area.x, area.y} * s + r - o, [2]f32{area.x + area.w, area.y + area.h} * s - r - o
	center = {clamp(center.x, lo.x, max(hi.x, lo.x)), clamp(center.y, lo.y, max(hi.y, lo.y))}
	p^ = {open = true, which = which, center = center, opened = input_clock(app), shown_at = k.ctx.time, opened_frame = k.frame, hover = -1, space_down = p.space_down}
	if k.palette do palette_close(app)
	kit_floats_close(k)
}

// The slots a pie shows: eight, the brush pie's (0) and a user pie's.
pie_slot_count :: proc(app: ^App, which: int) -> int {
	return PIE_SLOTS
}

// Whether `id` with `arg` is starred, and where.
favourite_find :: proc(app: ^App, id: Command_Id, arg: int) -> int {
	k := &app.kit
	for f, i in k.favourites[:k.favourite_count] do if f.id == id && f.arg == arg do return i
	return -1
}

// Stars the command, or takes its star away. Returns false when MAX_FAVOURITES are
// starred already.
favourite_toggle :: proc(app: ^App, id: Command_Id, arg: int) -> bool {
	k := &app.kit
	if i := favourite_find(app, id, arg); i >= 0 {
		copy(k.favourites[i:k.favourite_count], k.favourites[i + 1:k.favourite_count])
		k.favourite_count -= 1
		k.favourites[k.favourite_count] = {}
		return true
	}
	if k.favourite_count == MAX_FAVOURITES {
		report(app, nil, {.Warning}, "%d commands are starred already: take a star away first", MAX_FAVOURITES)
		return false
	}
	k.favourites[k.favourite_count] = {id, arg}
	k.favourite_count += 1
	return true
}

// The favourites as palette entries, in the order they were starred.
favourite_entries :: proc(app: ^App) -> []Palette_Entry {
	k := &app.kit
	out := make([]Palette_Entry, k.favourite_count, context.temp_allocator)
	for f, i in k.favourites[:k.favourite_count] do out[i] = {.Command, f.id, f.arg}
	return out
}

// Whether pie `n` differs from a fresh install's.
pie_changed :: proc(app: ^App, n: int) -> bool {
	fresh := PIE_DEFAULTS
	return app.kit.pies[n] != fresh[n]
}

// A pie for the exit stats: each slot's command name, "empty" for none, comma separated.
pie_names :: proc(app: ^App, n: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	for s, i in app.kit.pies[n] {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, command_name(s.id, s.arg) if s.id != .None else "empty")
	}
	return strings.to_string(b)
}

// A slot's label, short enough for a tile or a slice.
pie_slot_label :: proc(s: Pie_Slot) -> string {
	if s.id == .None do return "Empty"
	return palette_label({.Command, s.id, s.arg})
}

// The editor: for `id` (with `arg`) to put in a slot, or `.None` to empty slots only.
pie_editor_open :: proc(app: ^App, id: Command_Id, arg: int, at: ui.Rect) {
	k := &app.kit
	if k.palette do palette_close(app)
	kit_floats_close(k)
	k.pie_editor, k.pie_put, k.pie_editor_at, k.pie_scroll = true, {id, arg}, at, 0
}

// The pie editor: the four pies as rows of eight slot tiles. With a command to put, a tap
// puts it in that slot; a long press (or a right-click) empties one; Reset pies puts the
// defaults back. Its body scrolls when the window is short.
kit_pie_editor :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	width := ui.BRUSH_TILE.x * PIE_SLOTS
	area := ui.safe_area(ctx)
	at := k.pie_editor_at
	if at.w <= 0 do at = {area.x + area.w * 0.5, area.y + kit_top(), 0, 0}
	owner := ui.id_of(ctx, "pie editor")
	size, _ := ui.prev_layout(ctx, "pie editor")
	if !ui.popover_begin(ctx, "pie editor", &k.pie_editor, at, .Below, {direction = .Column, gap = 4, padding = 12, width = width + 24}) do return
	defer ui.popover_end(ctx)
	put := k.pie_put
	ui.begin(ctx, "pie editor head", {direction = .Row, center = true})
	ui.begin(ctx, "pie editor title", {direction = .Column, width = width - t.target})
	ui.caption(ctx, "PUT IN A PIE" if put.id != .None else "PIES")
	ui.label(ctx, fmt.tprintf("%s: tap a slot", command_label(put.id, put.arg)) if put.id != .None else "Long press or right-click a slot to empty it", font = .Semibold, color = t.text)
	ui.end(ctx)
	if ui.icon_button(ctx, "Close", ui.ICON_CLOSE, keys = "Esc") do k.pie_editor = false
	ui.end(ctx)
	body, _ := ui.prev_layout(ctx, "pie slots")
	besides := size.y - body.y if size.y > 0 else 140
	room := max(area.y + area.h - (at.y + at.h + 6) - 8 - besides, area.y + area.h - 16 - besides)
	scroll := kit_scroll_begin(ctx, "pie slots", &k.pie_scroll, owner, width, max(room, ui.BRUSH_TILE.y * 2), 2)
	// The brush pie first, as it is the one a sculptor opens most: a tap puts the
	// command being put, or without one chooses a command in Search, as a bar's slot does.
	brush_keys := command_keys(app, .Brush_Pie)
	ui.caption(ctx, fmt.tprintf("BRUSH PIE · %s", brush_keys) if brush_keys != "" else "BRUSH PIE")
	ui.begin(ctx, "pie row brush", {direction = .Row, gap = 0})
	for &s, i in k.brush_pie.slots[:PIE_SLOTS] {
		glyph := ui.ICON_PLUS if s.id == .None else bar_icon(s)
		lit := put.id != .None && s == put
		if ui.brush_tile(ctx, fmt.tprintf("%s##pie brush %d", shelf_label(s) if s.id != .None else "Empty", i), glyph, lit) {
			if put.id != .None && bar_lists(put.id) {
				s = put
				pies_saved(app)
			} else if put.id == .None {
				k.pie_editor = false
				bar_choose(app, {which = .Brush_Pie, slot = i})
			}
		}
		if ui.secondary(ctx) && s.id != .None {
			s = {}
			pies_saved(app)
		}
	}
	ui.end(ctx)
	for n in 0 ..< USER_PIES {
		keys := command_keys(app, .Pie, n)
		ui.caption(ctx, fmt.tprintf("PIE %d · %s", n + 1, keys) if keys != "" else fmt.tprintf("PIE %d", n + 1))
		ui.begin(ctx, fmt.tprintf("pie row %d", n), {direction = .Row, gap = 0})
		for &s, i in k.pies[n] {
			glyph := ui.ICON_PLUS if s.id == .None else (COMMANDS[s.id].icon if COMMANDS[s.id].icon != 0 else ui.ICON_WAND)
			lit := put.id != .None && s == put
			if ui.brush_tile(ctx, fmt.tprintf("%s##pie %d %d", pie_slot_label(s), n, i), glyph, lit) && put.id != .None {
				s = put
				pies_saved(app)
			}
			if ui.secondary(ctx) && s.id != .None {
				s = {}
				pies_saved(app)
			}
		}
		ui.end(ctx)
	}
	kit_scroll_end(ctx, scroll)
	changed := false
	for n in 0 ..< USER_PIES do changed ||= pie_changed(app, n)
	changed ||= bar_changed(app, .Brush_Pie)
	if ui.button(ctx, "Reset pies", .Bordered, enabled = changed) {
		k.pies = PIE_DEFAULTS
		k.brush_pie = bar_fresh(.Brush_Pie)
		pies_saved(app)
	}
}

// A change to the pies or the favourites is written at once, as one to the keys is.
pies_saved :: proc(app: ^App) {
	if app.settings_file != "" do _ = settings_save(app, app.settings_file)
}
