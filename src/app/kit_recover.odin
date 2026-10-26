package main

import "core:fmt"
import "core:path/filepath"

import "../ui"

// The recovery card: after a crash, under the tool bar where the first-run tips go, it
// offers the newest autosave the crashed run left (autosave.odin). Recover opens it in
// place of the scene, Not now (or Escape) keeps it for the next start, Discard deletes
// it. The scene stays usable while it shows; with several crashed runs, the next one
// comes once this one is answered.

recover_shown :: proc(app: ^App) -> bool {
	a := &app.autosave
	return len(a.offers) > 0 && !a.offer_hidden && !side_panel_open(&app.kit) && !kit_floating(app)
}

// The card's sentence for an offer: when, how much, and which file.
recover_text :: proc(o: Recover_Offer) -> string {
	what := ""
	if o.info.objects > 0 {
		what = fmt.tprintf(" has %d %s and %s vertices", o.info.objects, "object" if o.info.objects == 1 else "objects", count_label(o.info.vertices))
	}
	file := fmt.tprintf(" (%s)", filepath.base(o.info.scene)) if o.info.scene != "" else ""
	return fmt.tprintf("Sculpt closed before your last changes were saved. The autosave from %s%s%s.", wall_ago(o.at), what, file)
}

kit_recover :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	k.recover_shown = false
	if !recover_shown(app) do return
	o := app.autosave.offers[0]
	shift, w, top, fits := kit_card_place(app, 460, 280)
	if !fits do return
	k.recover_shown = true
	mark := ui.vertex_mark(ctx)
	ui.begin_anchored(ctx, "recover", .Center, .Start, {shift, top}, {direction = .Column, gap = 8, padding = 14, width = w, radius = t.radius_large + 4, background = .Panel})
	ui.begin(ctx, "recover title", {direction = .Row, gap = 10, center = true})
	ui.begin(ctx, "recover badge", {width = 36, height = 36, radius = t.radius_medium, background = .Track})
	ui.end(ctx)
	r := ctx.last_rect
	ui.icon(ctx, ui.ICON_HISTORY, {r.x + 18, r.y + 18}, t.icon_size, t.accent)
	ui.label(ctx, "Recover your work?", t.text_size, t.text, .Semibold)
	ui.end(ctx)
	ui.paragraph(ctx, recover_text(o), color = t.text)
	ui.begin(ctx, "recover buttons", {direction = .Row, gap = 8})
	third := (w - 2 * 14 - 2 * 8) / 3
	if ui.button(ctx, "Recover", .Solid, .Accent, width = third) do file_post(.Recover, o.session)
	if ui.button(ctx, "Not now", .Bordered, width = third) do app.autosave.offer_hidden = true
	if ui.button(ctx, "Discard", .Flat, .Danger, width = third) do file_post(.Discard_Autosave, o.session)
	ui.end(ctx)
	ui.end(ctx)
	shown := ui.tween_from(ctx, ui.id_of(ctx, fmt.tprintf("recover %s", o.session)), 0, 1, t.panel_time)
	ui.transform_since(ctx, mark, shown, offset = {0, (shown - 1) * 8})
}
