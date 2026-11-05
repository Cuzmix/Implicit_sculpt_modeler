package main

import "core:fmt"
import "core:path/filepath"
import "core:strings"

import "../ui"

// The Library's packs: its sidebar's Manage packs page (Install pack and Make a pack at
// its top, a pack waiting on Replace, then the person's own alphas and every pack
// installed, each with what it holds and Remove), and a pack's own page, which shows its
// row above its presets. Both are drawn in the Library sheet (kit_brush_sheet).

// The Library's `pack` while its Manage packs page is shown.
PACKS_MANAGE :: -1

// Seconds a pack's Remove waits for its second tap.
PACK_REMOVE_ARM_TIME :: 3

// Opens the Library on its Manage packs page.
library_packs_open :: proc(app: ^App) {
	k := &app.kit
	p := &k.brushes
	kit_floats_close(k)
	p.adding = nil
	p.category, p.pack, p.searching, p.search = .Pack, PACKS_MANAGE, false, {}
	k.browser, k.grid_scroll, k.library_scroll, k.pack_armed = true, 0, 0, 0
	p.side_scroll, p.side_reveal = 0, true
}

// The Manage packs page in the room `height` high: the buttons, what is installing or
// waiting, the rows in a body that scrolls, and the note on what a pack is.
kit_library_manage :: proc(app: ^App, owner: ui.Id, inner, height: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	l := &app.library
	kit_command_pair(app, .Pick_Pack, .Save_Pack, label_a = "Install pack...", label_b = "Make a pack...")
	if w := l.worker; w != nil {
		ui.label(ctx, ui.text_fit(ctx, fmt.tprintf("Installing %s...", filepath.base(w.path)), t.caption_size, inner), t.caption_size, t.text_secondary)
	}
	if u := l.pending; u != nil do kit_pack_pending(app, u, inner)
	ui.caption(ctx, fmt.tprintf("INSTALLED  %d PACK%s", len(l.packs), "" if len(l.packs) == 1 else "S"))

	// The list scrolls in the room the controls above and the note below leave.
	foot := "This run keeps no library: it keeps no settings." if l.folder == "" else fmt.tprintf("A content pack is a .sculptpack file: a ZIP archive of images under alphas/, brush presets in brushes.txt, OBJ or PLY meshes under meshes/ and a pack.txt naming it. Make a pack writes your own alphas and presets as one, named after its file. Packs only add to what is built in and hold no code. They are kept in the folder %s beside the settings file.", filepath.base(l.folder))
	_, foot_size := ui.prev_layout(ctx, "library foot")
	_, head_size := ui.prev_layout(ctx, "library pending")
	extra := head_size.y + 8 if l.pending != nil else 0
	if l.worker != nil do extra += ui.line_height(t.caption_size) + 8
	body_h := max(height - 3 * 8 - t.target - ui.CAPTION_H - foot_size.y - extra, 120)
	scroll := kit_scroll_begin(ctx, "library body", &k.library_scroll, owner, inner, body_h, 4)
	kit_library_row(app, -1, inner)
	for _, i in l.packs do kit_library_row(app, i, inner)
	if len(l.packs) == 0 do ui.paragraph(ctx, "No packs yet. Install pack adds one from a .sculptpack file; its alphas then show in the Brush card's Alpha section, its presets here under its name and its meshes in New scene and Add object.", inner)
	kit_scroll_end(ctx, scroll)
	ui.begin(ctx, "library foot", {direction = .Column, width = inner})
	ui.paragraph(ctx, foot, inner)
	ui.end(ctx)
}

// A pack installed already, by name and author, waiting on Replace or Keep.
@(private = "file")
kit_pack_pending :: proc(app: ^App, u: ^Pack_Unpacked, inner: f32) {
	ctx := &app.kit.ctx
	old := ""
	for p in app.library.packs do if strings.equal_fold(p.name, u.info.name) && strings.equal_fold(p.author, u.info.author) do old = p.version
	ui.begin(ctx, "library pending", {direction = .Column, gap = ui.SPACE_M, width = inner})
	ui.paragraph(ctx, fmt.tprintf("%s is installed already%s. Replace it with the one in %s%s? Its alphas keep their names, so presets that use them keep working.", u.info.name, "" if old == "" else fmt.tprintf(" (version %s)", old), u.source, "" if u.info.version == "" else fmt.tprintf(" (version %s)", u.info.version)))
	ui.begin(ctx, "library pending buttons", {direction = .Row, gap = ui.SPACE_M, width = inner})
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
		detail = fmt.tprintf("%d alpha%s from Load image and %d preset%s, which Make a pack writes", app.library.alphas, "" if app.library.alphas == 1 else "s", app.preset_count, "" if app.preset_count == 1 else "s")
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
