package main

import "../ui"

// Sheets: what is opened to read or set something and then put away, one presentation for
// Settings, Help, Macros and Export. A sheet comes down centred under the top bar, as wide
// as it asks or as the window leaves less a margin each side, and as tall as its content
// or the window allows; its head names it beside Close (Esc), and a press anywhere outside
// it puts it away, swallowed on the view so dismissing never sculpts. What stays beside
// the work while sculpting is a card (cards.odin), never a sheet, so a sheet is not moved,
// pinned or kept in a layout.

// The padding inside a sheet, and the margin it keeps from the window's sides and foot.
SHEET_PAD :: 16
SHEET_MARGIN :: 16

// Whether Settings, Help or Macros is open: they are one at a time, each opening closing
// the others (Export's sheet closes with what floats, kit_floats_close).
sheet_open :: proc(k: ^Kit_State) -> bool {
	return k.settings || k.help || k.macros
}

// Closes Settings, Help or Macros, whichever is open; Settings remembers what it holds.
sheet_close :: proc(app: ^App) {
	if app.kit.settings do settings_close(app)
	app.kit.help, app.kit.macros = false, false
}

// Begins sheet `name` while `open^` is true (and while it leaves): its head with `glyph`,
// `title`, `note` on the right in a quieter colour, and Close. Returns false when there is
// nothing to draw; otherwise the width inside its padding and the height its body has
// under the head, and the caller ends it with sheet_end.
sheet_begin :: proc(app: ^App, name, title: string, glyph: rune, open: ^bool, width: f32, note := "", gap: f32 = 8) -> (inner, room: f32, shown: bool) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	area := ui.safe_area(ctx)
	w := min(width, area.w - 2 * SHEET_MARGIN)
	top := kit_top() + 8
	at := ui.Rect{area.x + (area.w - w) * 0.5, top, 0, 0}
	if !ui.popover_begin(ctx, name, open, at, .Pointer, {direction = .Column, gap = gap, padding = SHEET_PAD, width = w}) do return
	inner = w - 2 * SHEET_PAD
	room = max(area.y + area.h - top - SHEET_MARGIN - 2 * SHEET_PAD - t.target - gap, 160)

	ui.begin(ctx, "sheet head", {direction = .Row, center = true, gap = 8, width = inner})
	mark := ui.place(ctx, {t.icon_size, t.target})
	ui.icon(ctx, glyph, {mark.x + mark.w * 0.5, mark.y + mark.h * 0.5}, t.icon_size, t.text)
	head := ui.place(ctx, {inner - mark.w - t.target - 16, t.target})
	ui.text(ctx, title, head.x, head.y + head.h * 0.5, t.heading_size * 1.15, t.text, .Semibold)
	if note != "" {
		fit := ui.text_fit(ctx, note, t.small_size, head.w - ui.text_width(ctx, title, t.heading_size * 1.15) - 24)
		ui.text(ctx, fit, head.x + head.w, head.y + head.h * 0.5, t.small_size, t.text_secondary, .Regular, .Right)
	}
	if ui.icon_button(ctx, "Close", ui.ICON_CLOSE, keys = "Esc") do open^ = false
	ui.end(ctx)
	return inner, room, true
}

sheet_end :: proc(app: ^App) {
	ui.popover_end(&app.kit.ctx)
}

// Settings, Help and Macros, the one that is open, under what floats from them (a key's
// Assign, a theme's menu, a colour's picker), which is drawn after.
kit_sheets :: proc(app: ^App) {
	kit_settings(app)
	kit_help(app)
	kit_macros(app)
}
