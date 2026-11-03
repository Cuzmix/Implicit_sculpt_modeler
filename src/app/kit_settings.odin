package main

import "core:fmt"
import "core:strings"

import "../ui"

// Settings (Menu > Settings): the app's own preferences in one place, by section
// (settings_sections.odin), each changed at once and remembered (settings.odin) when it
// closes, when the app goes to the background and on exit. Brush and tool settings stay
// with the tool, in the inspector; the drawing switches for comparing speed stay in the
// Stats panel's Advanced view, being for development. A window wide enough has the sheet
// (kit_settings_sheet), sections down its side and the open one beside them; a narrower
// one has a panel in the inspector's place that drills down: Search settings over the
// sections, and a tap on one shows its blocks under Back, as a phone's settings do. Both
// are the same sections, search and resets.

// The interface sizes on offer, times what the display asks for. None is smaller than
// what it asks for, so every touch target stays at least 48 points (sm-store).
UI_SCALES := [?]f32{1, 1.15, 1.3, 1.5}

// The narrow panel's width.
KIT_SETTINGS_W :: 400

// Seconds Reset all settings waits for its second tap.
SETTINGS_WIPE_TIME :: 3

kit_settings :: proc(app: ^App) -> (raised: bool) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	id := ui.id_of(ctx, "settings")
	shown := ui.presence(ctx, id, k.settings, t.panel_time)
	if shown <= 0 do return
	if settings_sheet_fits(app) do return kit_settings_sheet(app, shown)
	win := &k.windows[.Settings]
	top := kit_top()
	room := window_room(app, win^, top)
	if !win.moved do room -= side_panel_below(app, KIT_SETTINGS_W)
	inner := f32(KIT_SETTINGS_W - 2 * 16)

	mark := ui.vertex_mark(ctx)
	body, closed, raised_now := ui.window_begin(ctx, "settings", "Settings", win, .End, .Start, {kit_right(app), top}, {direction = .Column, gap = 8, padding = 16, width = KIT_SETTINGS_W, radius = t.radius_large, background = .Panel, inert = !k.settings}, "Esc")
	raised = raised_now
	if closed do settings_close(app)
	if !body {
		ui.window_end(ctx)
		ui.transform_since(ctx, mark, shown, 1, {}, {window_slide(ctx, win^, .End) * (1 - shown) * 16, 0})
		return
	}
	q := settings_query(k)
	// The head: Back and the section's name while one is open, else Search settings.
	if k.settings_drill {
		ui.begin(ctx, "settings head", {direction = .Row, gap = 8, center = true, width = inner, height = t.target})
		if ui.icon_button(ctx, "Back to the sections##settings back", ui.ICON_CHEVRON_LEFT) {
			k.settings_drill, k.settings_scroll = false, 0
		}
		title := ui.place(ctx, {inner - t.target - 8, t.target})
		ui.text(ctx, SETTINGS_SECTION_NAMES[k.settings_section], title.x, title.y + title.h * 0.5, t.heading_size, t.text, .Semibold)
		ui.end(ctx)
	} else {
		_ = ui.text_field(ctx, "Search settings##narrow", k.settings_find[:], inner, hint = "Search settings")
	}

	// The list or the section scrolls in the room left between the head and the buttons below.
	body_h := max(room - 2 * 16 - 3 * 8 - 3 * t.target, 120)
	scroll := kit_scroll_begin(ctx, "settings body", &k.settings_scroll, id, inner, body_h, 4)
	k.settings_body = scroll.at
	if k.settings_drill {
		name := strings.to_lower(SETTINGS_SECTION_NAMES[k.settings_section], context.temp_allocator)
		settings_entries_draw(app, settings_section_entries(k.settings_section), q, name)
		ui.spacer(ctx, 4)
		if ui.button(ctx, fmt.tprintf("Reset %s settings", SETTINGS_SECTION_NAMES[k.settings_section]), .Bordered) do settings_section_reset(app, k.settings_section)
	} else {
		found := 0
		for s in Settings_Section {
			if q != "" && !settings_section_matches(s, q) do continue
			found += 1
			if ui.list_row(ctx, fmt.tprintf("%s##settings section", SETTINGS_SECTION_NAMES[s]), glyph = ui.ICON_CHEVRON_RIGHT).clicked {
				k.settings_section, k.settings_drill, k.settings_scroll = s, true, 0
			}
		}
		if found == 0 do ui.paragraph(ctx, "No setting has that name.", inner)
	}
	kit_scroll_end(ctx, scroll)

	ui.begin(ctx, "settings foot", {direction = .Row, gap = 8, width = inner})
	if settings_wipe_button(app, (inner - 8) * 0.5) do settings_reset_all(app)
	if ui.button(ctx, "Done", .Solid, .Accent, width = (inner - 8) * 0.5) do settings_close(app)
	ui.end(ctx)
	ui.window_end(ctx)
	ui.transform_since(ctx, mark, shown, 1, {}, {window_slide(ctx, win^, .End) * (1 - shown) * 16, 0})
	return
}

// Reset all settings, `width` wide: everything goes back only on a second tap, so a stray
// finger never wipes it all. Returns true on that second tap.
settings_wipe_button :: proc(app: ^App, width: f32) -> bool {
	k := &app.kit
	ctx := &k.ctx
	armed := k.settings_wipe > 0 && ctx.time - k.settings_wipe < SETTINGS_WIPE_TIME
	if !ui.button(ctx, "Tap again to reset all" if armed else "Reset all settings", .Light, .Danger, width = width) do return false
	if armed {
		k.settings_wipe = 0
		return true
	}
	k.settings_wipe = max(ctx.time, 1e-6)
	return false
}

// Opens Settings as Menu > Settings does, on section `s` from its top (on the narrow panel,
// drilled into it); returns whether it ran.
settings_open :: proc(app: ^App, s: Settings_Section) -> bool {
	if !command_run(app, .Settings) do return false
	app.kit.settings_section, app.kit.settings_drill, app.kit.settings_scroll = s, true, 0
	return true
}

// Closes Settings and remembers what it holds.
settings_close :: proc(app: ^App) {
	app.kit.settings = false
	if app.settings_file != "" do _ = settings_save(app, app.settings_file)
}

// `s` as it fits in `width` points: whole, or its end with "..." before it.
text_fit_end :: proc(ctx: ^ui.Context, s: string, size, width: f32) -> string {
	if ui.text_width(ctx, s, size) <= width do return s
	room := width - ui.text_width(ctx, "...", size)
	start := len(s)
	for _, i in s {
		if ui.text_width(ctx, s[i:], size) <= room {
			start = i
			break
		}
	}
	return strings.concatenate({"...", s[start:]}, context.temp_allocator)
}

// A speed from a quarter to four times the default, equal steps doubling it.
speed_slider :: proc(ctx: ^ui.Context, label: string, value: ^f32) {
	_ = ui.slider(ctx, label, value, 0.25, 4, .Logarithmic, fmt.tprintf("%.2fx", value^))
}

// A command's keys for a sentence, or `fallback` when it has none (the user took them).
key_or :: proc(keys, fallback: string) -> string {
	return keys if keys != "" else fallback
}
