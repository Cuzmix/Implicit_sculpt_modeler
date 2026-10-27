package main

import "core:fmt"
import "core:path/filepath"
import "core:strings"

import "../ui"

// The Library panel (Menu > Library, or Search): Install pack at its top, a pack waiting
// on Replace, then the person's own alphas and every pack installed, each with what it
// holds and Remove. It takes the inspector's place on the right as Settings, Help and
// Macros do.

KIT_LIBRARY_W :: KIT_SETTINGS_W

// Seconds a pack's Remove waits for its second tap.
PACK_REMOVE_ARM_TIME :: 3

// Opens the Library panel in the inspector's place, unfolded and in front.
library_open :: proc(app: ^App) {
	k := &app.kit
	if k.settings do settings_close(app)
	k.help, k.macros, k.library, k.pack_armed = false, false, true, 0
	k.windows[.Library].minimized = false
	window_raise(k, .Library)
}

kit_library :: proc(app: ^App) -> (raised: bool) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	id := ui.id_of(ctx, "library")
	shown := ui.presence(ctx, id, k.library, t.panel_time)
	if shown <= 0 do return
	win := &k.windows[.Library]
	top := kit_top()
	room := window_room(app, win^, top)
	if !win.moved do room -= side_panel_below(app, KIT_LIBRARY_W)
	inner := f32(KIT_LIBRARY_W - 2 * 16)
	l := &app.library

	mark := ui.vertex_mark(ctx)
	body, closed, raised_now := ui.window_begin(ctx, "library", "Library", win, .End, .Start, {kit_right(app), top}, {direction = .Column, gap = 8, padding = 16, width = KIT_LIBRARY_W, radius = t.radius_large, background = .Panel, inert = !k.library}, "Esc")
	raised = raised_now
	if closed do k.library = false
	if body {
		_ = command_button(app, .Pick_Pack, variant = .Bordered, width = inner, glyph = ui.ICON_IMPORT)
		if w := l.worker; w != nil {
			ui.label(ctx, ui.text_fit(ctx, fmt.tprintf("Installing %s...", filepath.base(w.path)), t.caption_size, inner), t.caption_size, t.text_secondary)
		}
		if u := l.pending; u != nil do kit_pack_pending(app, u, inner)
		ui.caption(ctx, fmt.tprintf("INSTALLED  %d PACK%s", len(l.packs), "" if len(l.packs) == 1 else "S"))

		// The list scrolls in the room the controls above and the note below leave.
		foot := "This run keeps no library: it keeps no settings." if l.folder == "" else fmt.tprintf("A content pack is a .sculptpack file: a ZIP archive of images under alphas/, brush presets in brushes.txt and a pack.txt naming it. Packs only add to what is built in and hold no code. They are kept in the folder %s beside the settings file.", filepath.base(l.folder))
		_, foot_size := ui.prev_layout(ctx, "library foot")
		_, head_size := ui.prev_layout(ctx, "library pending")
		extra := head_size.y + 8 if l.pending != nil else 0
		if l.worker != nil do extra += t.caption_size * 1.4 + 8
		body_h := max(room - 2 * 16 - 3 * 8 - t.target - t.caption_size * 1.4 - foot_size.y - extra, 120)
		scroll := kit_scroll_begin(ctx, "library body", &k.library_scroll, id, inner, body_h, 4)
		kit_library_row(app, -1, inner)
		for _, i in l.packs do kit_library_row(app, i, inner)
		if len(l.packs) == 0 do ui.paragraph(ctx, "No packs yet. Install pack adds one from a .sculptpack file; its alphas then show in the Brush palette's Alpha section and its presets in the brush browser, under its name.")
		kit_scroll_end(ctx, scroll)
		ui.begin(ctx, "library foot", {direction = .Column, width = inner})
		ui.paragraph(ctx, foot)
		ui.end(ctx)
	}
	ui.window_end(ctx)
	ui.transform_since(ctx, mark, shown, 1, {}, {window_slide(win^, .End) * (1 - shown) * 16, 0})
	return
}

// A pack installed already, by name and author, waiting on Replace or Keep.
@(private = "file")
kit_pack_pending :: proc(app: ^App, u: ^Pack_Unpacked, inner: f32) {
	ctx := &app.kit.ctx
	old := ""
	for p in app.library.packs do if strings.equal_fold(p.name, u.info.name) && strings.equal_fold(p.author, u.info.author) do old = p.version
	ui.begin(ctx, "library pending", {direction = .Column, gap = 8, width = inner})
	ui.paragraph(ctx, fmt.tprintf("%s is installed already%s. Replace it with the one in %s%s? Its alphas keep their names, so presets that use them keep working.", u.info.name, "" if old == "" else fmt.tprintf(" (version %s)", old), u.source, "" if u.info.version == "" else fmt.tprintf(" (version %s)", u.info.version)))
	ui.begin(ctx, "library pending buttons", {direction = .Row, gap = 8, width = inner})
	half := (inner - 8) * 0.5
	if ui.button(ctx, "Replace", .Solid, .Accent, width = half) do pack_pending_answer(app, true)
	if ui.button(ctx, "Keep the old one", .Bordered, width = half) do pack_pending_answer(app, false)
	ui.end(ctx)
	ui.end(ctx)
}

// Whether pack `i` had its Remove tapped once, within PACK_REMOVE_ARM_TIME.
pack_remove_armed :: proc(app: ^App, i: int) -> bool {
	k := &app.kit
	return k.pack_armed == i + 1 && k.ctx.time - k.pack_armed_at < PACK_REMOVE_ARM_TIME
}

// One row: the person's own alphas (`i` -1), or pack `i` with its author, version,
// licence and what it holds, and Remove, which asks for a second tap in the line under
// the name.
@(private = "file")
kit_library_row :: proc(app: ^App, i: int, inner: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	armed := i >= 0 && pack_remove_armed(app, i)
	ui.begin(ctx, fmt.tprintf("library row %d", i + 1), {direction = .Row, width = inner, center = true})
	words := inner - (t.target if i >= 0 else 0)
	ui.begin(ctx, fmt.tprintf("library words %d", i + 1), {direction = .Column, width = words})
	name, detail: string
	if i < 0 {
		name = "Your own"
		detail = fmt.tprintf("%d alpha%s from Load image", app.library.alphas, "" if app.library.alphas == 1 else "s")
	} else {
		p := app.library.packs[i]
		name = p.name
		detail = pack_holds(p)
		if p.version != "" do detail = fmt.tprintf("%s · %s", p.version, detail)
		if p.author != "" do detail = fmt.tprintf("by %s · %s", p.author, detail)
		if p.license != "" do detail = fmt.tprintf("%s · %s", detail, p.license)
		if armed do detail = "Tap the bin again to remove it"
	}
	ui.label(ctx, ui.text_fit(ctx, name, t.text_size, words - 4, .Semibold), font = .Semibold, color = t.text)
	ui.label(ctx, ui.text_fit(ctx, detail, t.caption_size, words - 4), t.caption_size, t.danger if armed else t.text_tertiary)
	if i >= 0 && app.library.packs[i].description != "" {
		ui.label(ctx, ui.text_fit(ctx, app.library.packs[i].description, t.caption_size, words - 4), t.caption_size, t.text_tertiary)
	}
	ui.end(ctx)
	if i >= 0 {
		p := app.library.packs[i]
		if ui.icon_button(ctx, fmt.tprintf("Remove %s##pack remove %d", p.name, i + 1), ui.ICON_TRASH, selected = armed, enabled = !pack_busy(app)) {
			if armed {
				k.pack_armed = 0
				_ = pack_remove(app, i)
			} else {
				k.pack_armed, k.pack_armed_at = i + 1, max(ctx.time, 1e-6)
			}
		}
	}
	ui.end(ctx)
}
