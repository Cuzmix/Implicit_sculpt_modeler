package main

import "core:testing"

import "../ui"

// Show where finds every command COMMAND_HOMES places: it opens the section's card as the
// tray drew it (the Brush card for the brush's), and with every argument the section
// lists that card lays out a control for it.
@(test)
show_where_finds_every_home :: proc(t: ^testing.T) {
	app: App
	_ = section_scene(&app)
	defer section_scene_free(&app)
	// One light, so the Lights section shows a light's controls (Place highlight).
	app.scene.lights.count, app.scene.lights.lights[0].on = 1, true
	ctx := &app.kit.ctx
	for home, id in COMMAND_HOMES {
		sec, ok := home.?
		if !ok do continue
		for arg in 0 ..< max(COMMANDS[id].args, 1) {
			testing.expect(t, tray_show(&app, id, arg))
			revealed, _ := app.kit.stack.revealed.?
			testing.expectf(t, revealed == sec, "%v:%d opened %v", id, arg, revealed)
			card := stack_card_of(&app, sec, exact = true)
			testing.expectf(t, palette_on_screen(&app, card), "%v:%d left %v off screen", id, arg, card)
			ui.frame_begin(ctx, {window = {1600, 900}, pixel_density = 1, dt = 1.0 / 60})
			ui.begin_anchored(ctx, "tray", .End, .Start, {0, 0}, {direction = .Column, width = KIT_INSPECTOR_W})
			panel_body(&app, card, KIT_INSPECTOR_W - 16)
			found := ctx.marked.found
			ui.end(ctx)
			ui.frame_end(ctx)
			free_all(context.temp_allocator)
			testing.expectf(t, found, "%v:%d has no control in %v", id, arg, sec)
		}
	}
}

