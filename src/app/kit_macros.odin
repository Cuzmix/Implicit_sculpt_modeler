package main

import "core:fmt"
import "core:path/filepath"

import "../ui"

// The Macros panel (Menu > Macros, or Search): Record macro and Run script at its top,
// then every macro kept, each with Run, a key, Rename and Delete. It takes the
// inspector's place on the right as Settings and Help do, so the model stays in view
// while a macro runs on it.

KIT_MACROS_W :: KIT_SETTINGS_W

// Seconds a macro's Delete waits for its second tap.
MACRO_DELETE_ARM_TIME :: 3

kit_macros :: proc(app: ^App) -> (raised: bool) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	id := ui.id_of(ctx, "macros")
	shown := ui.presence(ctx, id, k.macros, t.panel_time)
	if shown <= 0 do return
	win := &k.windows[.Macros]
	top := kit_top()
	room := window_room(app, win^, top)
	if !win.moved do room -= side_panel_below(app, KIT_MACROS_W)
	inner := f32(KIT_MACROS_W - 2 * 16)

	mark := ui.vertex_mark(ctx)
	body, closed, raised_now := ui.window_begin(ctx, "macros", "Macros", win, .End, .Start, {kit_right(app), top}, {direction = .Column, gap = 8, padding = 16, width = KIT_MACROS_W, radius = t.radius_large, background = .Panel, inert = !k.macros}, "Esc")
	raised = raised_now
	if closed do k.macros = false
	if body {
		m := &app.macro
		half := (inner - 8) * 0.5
		ui.begin(ctx, "macros head", {direction = .Row, gap = 8, width = inner})
		if m.recording {
			_ = command_button(app, .Macro_Record, label = "Stop recording", variant = .Solid, tone = .Danger, width = half, glyph = ui.ICON_STOP)
		} else {
			_ = command_button(app, .Macro_Record, variant = .Bordered, width = half, glyph = ui.ICON_RECORD)
		}
		_ = command_button(app, .Run_Script, variant = .Bordered, width = half, glyph = ui.ICON_OPEN)
		ui.end(ctx)
		kept := 0
		for s in m.slots do kept += int(s.name != "")
		ui.caption(ctx, fmt.tprintf("SAVED  %d OF %d", kept, MACRO_SLOTS))

		// The list scrolls in the room the buttons above and the note below leave.
		foot := "This run keeps no files: its macros last until the app closes." if m.folder == "" else fmt.tprintf("Each macro is a script file (macro-01.cmd and on) in the folder %s beside the settings file, to edit there or share; Run script runs any such file.", filepath.base(m.folder))
		_, foot_size := ui.prev_layout(ctx, "macros foot")
		body_h := max(room - 2 * 16 - 4 * 8 - 2 * t.target - t.caption_size * 1.4 - foot_size.y, 120)
		scroll := kit_scroll_begin(ctx, "macros body", &k.macros_scroll, id, inner, body_h, 4)
		if kept == 0 do ui.paragraph(ctx, "None yet. Tap Record macro, run the commands to repeat (by key, button, menu, pie or Search), then Stop and name it. Strokes and view changes are not recorded.")
		for s, slot in m.slots do if s.name != "" do kit_macro_row(app, slot, inner)
		kit_scroll_end(ctx, scroll)
		ui.begin(ctx, "macros foot", {direction = .Column, width = inner})
		ui.paragraph(ctx, foot)
		ui.end(ctx)
	}
	ui.window_end(ctx)
	ui.transform_since(ctx, mark, shown, 1, {}, {window_slide(win^, .End) * (1 - shown) * 16, 0})
	return
}

// Whether the macro in `slot` had its Delete tapped once, within MACRO_DELETE_ARM_TIME.
macro_delete_armed :: proc(app: ^App, slot: int) -> bool {
	k := &app.kit
	return k.macro_armed == slot + 1 && k.ctx.time - k.macro_armed_at < MACRO_DELETE_ARM_TIME
}

// One macro: its name and keys, then Run, Key, Rename and Delete, each a touch target.
// Delete asks for a second tap, in the line under the name, so a stray finger never
// loses a macro.
@(private = "file")
kit_macro_row :: proc(app: ^App, slot: int, inner: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	s := app.macro.slots[slot]
	armed := macro_delete_armed(app, slot)
	ui.begin(ctx, fmt.tprintf("macro row %d", slot + 1), {direction = .Row, width = inner, center = true})
	words := inner - 4 * t.target
	ui.begin(ctx, fmt.tprintf("macro words %d", slot + 1), {direction = .Column, width = words})
	ui.label(ctx, ui.text_fit(ctx, s.name, t.text_size, words - 4, .Semibold), font = .Semibold, color = t.text)
	keys := hint_join(command_chords(app, .Run_Macro, slot), gesture_text(app, .Run_Macro, slot))
	detail := "Tap the bin again to delete it" if armed else keys if keys != "" else fmt.tprintf("Macro %d, no key", slot + 1)
	ui.label(ctx, ui.text_fit(ctx, detail, t.caption_size, words - 4), t.caption_size, t.danger if armed else t.text_tertiary)
	ui.end(ctx)
	run := ui.icon_button(ctx, fmt.tprintf("Run %s##macro run %d", s.name, slot + 1), ui.ICON_PLAY, enabled = command_enabled(app, .Run_Macro, slot), keys = command_hint(app, .Run_Macro, slot))
	key := ui.icon_button(ctx, fmt.tprintf("Give it a key##macro key %d", slot + 1), ui.ICON_KEYBOARD)
	rename := ui.icon_button(ctx, fmt.tprintf("Rename##macro rename %d", slot + 1), ui.ICON_PENCIL)
	delete_tap := ui.icon_button(ctx, fmt.tprintf("Delete##macro delete %d", slot + 1), ui.ICON_TRASH, selected = armed)
	ui.end(ctx)
	row := ctx.last_rect
	switch {
	case run:
		k.macro_armed = 0
		_ = command_run(app, .Run_Macro, slot)
	case key:
		k.macro_armed = 0
		bind_open(app, .Run_Macro, slot, row)
	case rename:
		k.macro_armed = 0
		kit_floats_close(k)
		k.rename = {open = true, id = slot, macro = true, at = row}
	case delete_tap && armed:
		k.macro_armed = 0
		_ = macro_delete(app, slot)
	case delete_tap:
		k.macro_armed, k.macro_armed_at = slot + 1, max(ctx.time, 1e-6)
	}
}
