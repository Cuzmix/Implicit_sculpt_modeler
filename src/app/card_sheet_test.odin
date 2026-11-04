package main

import "core:testing"

import "../ui"

// Under 900 points wide a card opens as a sheet over the lower part of the window, and at
// a desktop's width beside its dock.
@(test)
cards_are_a_sheet_on_a_narrow_window :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	k := &app.kit
	ui.frame_begin(&k.ctx, {window = {820, 1180}, pixel_density = 1, dt = 1.0 / 60})
	testing.expect(t, cards_as_sheet(k))
	ui.frame_end(&k.ctx)
	ui.frame_begin(&k.ctx, {window = {1600, 900}, pixel_density = 1, dt = 1.0 / 60})
	testing.expect(t, !cards_as_sheet(k))
	ui.frame_end(&k.ctx)
}
