package main

import "core:fmt"
import "core:strings"

import "../ui"

// The Settings panel (Menu > Settings): the app's own preferences in one place, by
// category, each changed at once and remembered (settings.odin) when the panel closes,
// when the app goes to the background and on exit. It takes the inspector's place on the
// right while open, so the model stays in view and a change to the camera or the touch
// gestures can be tried as it is made. Brush and tool settings stay with the tool, in the
// inspector; the drawing switches for comparing speed stay in the Stats panel's
// Advanced view, being for development.
Settings_Tab :: enum u8 {
	Interface,
	Camera,
	Touch,
	Keys,
	Performance,
}

SETTINGS_TAB_NAMES := [Settings_Tab]string {
	.Interface   = "Interface",
	.Camera      = "Camera",
	.Touch       = "Touch",
	.Keys        = "Keys",
	// "Performance" is wider than a fifth of the panel; the statistics and the frame rate are the
	// system's side of things.
	.Performance = "System",
}

// The interface sizes on offer, times what the display asks for. None is smaller than
// what it asks for, so every touch target stays at least 48 points (sm-store).
UI_SCALES := [?]f32{1, 1.15, 1.3, 1.5}

// The Settings panel's width.
KIT_SETTINGS_W :: 400

// Seconds Reset everything waits for its second tap.
SETTINGS_WIPE_TIME :: 3

kit_settings :: proc(app: ^App) -> (raised: bool) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	id := ui.id_of(ctx, "settings")
	shown := ui.presence(ctx, id, k.settings, t.panel_time)
	if shown <= 0 do return
	if k.chrome == .Lens && lens_settings_fits(app) do return kit_settings_lens(app, shown)
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
	names: [len(Settings_Tab)]string
	for tab in Settings_Tab do names[int(tab)] = SETTINGS_TAB_NAMES[tab]
	if picked := ui.tabs(ctx, "settings tabs", names[:], int(k.settings_tab)); picked >= 0 && Settings_Tab(picked) != k.settings_tab {
		k.settings_tab = Settings_Tab(picked)
		k.settings_scroll = 0
	}

	// The category scrolls in the room left between the tabs and the buttons below.
	body_h := max(room - 2 * 16 - 3 * 8 - 3 * t.target, 120)
	scroll := kit_scroll_begin(ctx, "settings body", &k.settings_scroll, id, inner, body_h, 4)
	k.settings_body = scroll.at
	settings_entries_draw(app, settings_tab_entries(k.settings_tab))
	ui.spacer(ctx, 4)
	if ui.button(ctx, fmt.tprintf("Reset %s settings", SETTINGS_TAB_NAMES[k.settings_tab]), .Bordered) do settings_reset(app, k.settings_tab)
	kit_scroll_end(ctx, scroll)

	// Everything goes back only on a second tap, so a stray finger never wipes it all.
	ui.begin(ctx, "settings foot", {direction = .Row, gap = 8, width = inner})
	armed := k.settings_wipe > 0 && ctx.time - k.settings_wipe < SETTINGS_WIPE_TIME
	if ui.button(ctx, "Tap again to reset all" if armed else "Reset everything", .Light, .Danger, width = (inner - 8) * 0.5) {
		if armed {
			settings_reset_all(app)
			k.settings_wipe = 0
		} else do k.settings_wipe = max(ctx.time, 1e-6)
	}
	if ui.button(ctx, "Done", .Solid, .Accent, width = (inner - 8) * 0.5) do settings_close(app)
	ui.end(ctx)
	ui.window_end(ctx)
	ui.transform_since(ctx, mark, shown, 1, {}, {window_slide(ctx, win^, .End) * (1 - shown) * 16, 0})
	return
}

// Opens Settings as Menu > Settings does, on `tab` from its top; returns whether it ran.
settings_open :: proc(app: ^App, tab: Settings_Tab) -> bool {
	if !command_run(app, .Settings) do return false
	app.kit.settings_tab, app.kit.settings_scroll = tab, 0
	app.kit.settings_section = SETTINGS_TAB_SECTION[tab]
	return true
}

// Closes the Settings panel and remembers what it holds.
settings_close :: proc(app: ^App) {
	app.kit.settings = false
	if app.settings_file != "" do _ = settings_save(app, app.settings_file)
}

// Puts one of Classic's tabs back as a fresh install has it: each of its blocks.
settings_reset :: proc(app: ^App, tab: Settings_Tab) {
	for e in settings_tab_entries(tab) do settings_block_reset(app, e.block)
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
