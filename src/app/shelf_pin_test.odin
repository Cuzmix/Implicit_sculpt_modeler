package main

import "core:testing"

import "../sculpt"
import "../ui"

// Settings from before version 12 held a tools strip beside the shelf's pages: its tools
// join each Sculpt page once, after what the page holds, skipping a tool already there and
// stopping where the page is full.
@(test)
shelf_tools_join_the_pages_once :: proc(t: ^testing.T) {
	app: App
	kit_init(&app)
	defer ui.destroy(&app.kit.ctx)
	defer workspaces_destroy(&app.kit)
	paint := len(bar_used(&app, .Shelf_Paint))
	shelf_tools_merge(&app)
	// The fresh Brushes page is full already; Paint takes the six, less what it holds.
	testing.expect_value(t, len(bar_used(&app, .Shelf_Sculpt)), SHELF_MAX)
	page := bar_used(&app, .Shelf_Paint)
	testing.expect(t, len(page) > paint)
	testing.expect(t, len(page) <= SHELF_MAX)
	for s, i in page do for u in page[i + 1:] do testing.expect(t, s != u)
	_, moved := shelf_holds(&app, .Shelf_Move, {.Tool_Move, 0})
	testing.expect(t, moved)
	// Model's page is not a Sculpt page and gets none.
	_, model := shelf_holds(&app, .Shelf_Model, {.Retopologize, 0})
	testing.expect(t, !model)
}

// Pinning puts the brush first on a page with room, once, and Undo takes it off again; a
// full page waits for the tile it replaces.
@(test)
shelf_pin_puts_the_brush_first :: proc(t: ^testing.T) {
	app: App
	kit_init(&app)
	defer ui.destroy(&app.kit.ctx)
	defer workspaces_destroy(&app.kit)
	elastic := Bar_Slot{.Brush, int(sculpt.Brush_Kind.Elastic)}
	count := len(bar_used(&app, .Shelf_Curve))
	shelf_pin(&app, elastic, .Shelf_Curve)
	testing.expect_value(t, bar_used(&app, .Shelf_Curve)[0], elastic)
	testing.expect_value(t, len(bar_used(&app, .Shelf_Curve)), count + 1)
	shelf_pin(&app, elastic, .Shelf_Curve)
	testing.expect_value(t, len(bar_used(&app, .Shelf_Curve)), count + 1)
	bar_removed_undo(&app)
	_, held := shelf_holds(&app, .Shelf_Curve, elastic)
	testing.expect(t, !held)
	testing.expect_value(t, app.kit.shelf.pins, 1)
	shelf_pin(&app, elastic, .Shelf_Sculpt)
	_, waiting := app.kit.shelf.pinning.?
	testing.expect(t, waiting)
	_, on := shelf_holds(&app, .Shelf_Sculpt, elastic)
	testing.expect(t, !on)
}
