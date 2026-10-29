package main

import "core:os"
import "core:testing"

// The shelf's tool strip and the view rail take any command, in any order, up to their
// size.
@(test)
bars_insert_move_and_remove :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	bars_reset(&app.kit)
	for which in Bar_Which do testing.expectf(t, !bar_changed(&app, which), "%v starts changed", which)
	testing.expect_value(t, bar_names(&app, .Tools), "Tool_Move,Remesh,Dyntopo_Toggle,Retopologize,Subdivide,Live_Boolean")

	bar_put(&app, {which = .Tools, slot = 0, add = true}, {.Ortho_Toggle, 0})
	testing.expect_value(t, bar_names(&app, .Tools), "Ortho_Toggle,Tool_Move,Remesh,Dyntopo_Toggle,Retopologize,Subdivide,Live_Boolean")
	testing.expect_value(t, bar_move(&app, .Tools, 0, 1), 1)
	testing.expect_value(t, bar_move(&app, .Tools, 6, 1), 6) // past the end: stays
	bar_remove(&app, .Tools, 0)
	testing.expect_value(t, bar_names(&app, .Tools), "Ortho_Toggle,Remesh,Dyntopo_Toggle,Retopologize,Subdivide,Live_Boolean")
	testing.expect(t, bar_changed(&app, .Tools))

	// Full: an eighth fits, a ninth does not.
	bar_put(&app, {which = .Tools, slot = 6, add = true}, {.Wireframe, 0})
	bar_put(&app, {which = .Tools, slot = 7, add = true}, {.Flat_Shading, 0})
	testing.expect_value(t, bar_count(&app, .Tools)^, TOOLS_MAX)
	bar_put(&app, {which = .Tools, slot = 8, add = true}, {.Polygroups, 0})
	testing.expect_value(t, bar_count(&app, .Tools)^, TOOLS_MAX)

	// Every slot can go.
	for _ in 0 ..< TOOLS_MAX do bar_remove(&app, .Tools, 0)
	testing.expect_value(t, bar_names(&app, .Tools), "none")
}

// settings.txt keeps the bars that changed whole; a fresh install's bars write nothing, an
// unknown command keeps the slot as it was, and the lines of the bars the Classic layout
// had (the right bar's right_rail, the dock's) are passed over.
@(test)
bars_are_remembered :: proc(t: ^testing.T) {
	path := "build/bars_test.txt"
	defer os.remove(path)
	a: App
	defer results_destroy(&a)
	bars_reset(&a.kit)
	bar_remove(&a, .Tools, 2)
	bar_put(&a, {which = .Tools, slot = 4, add = true}, {.Ortho_Toggle, 0})
	bar_put(&a, {which = .Shelf_Paint, slot = 0}, {.Brush, 3})
	testing.expect(t, settings_save(&a, path))

	b: App
	defer results_destroy(&b)
	bars_reset(&b.kit)
	settings_load(&b, path)
	testing.expect_value(t, bar_names(&b, .Tools), bar_names(&a, .Tools))
	testing.expect_value(t, bar_names(&b, .Shelf_Paint), bar_names(&a, .Shelf_Paint))

	damaged := "bar_count view_rail 2\nbar view_rail 0 No_Such_Command\nbar view_rail 1 Floor_Grid\nbar view_rail 99 Wireframe\nbar_count bottom_tools x\n" +
		"chrome classic\npanes_under_panels 0\nbar_count right_rail 1\nbar right_rail 0 Remesh\nbar dock 0 Remesh\ndock_count 9\ndock 0 command Remesh\ndock 1 brush Clay\ndock_pack 2 set Stone\n"
	testing.expect(t, os.write_entire_file(path, transmute([]u8)damaged) == nil)
	c: App
	defer results_destroy(&c)
	bars_reset(&c.kit)
	settings_load(&c, path)
	testing.expect_value(t, bar_names(&c, .View_Rail), "View_Layout_Menu,Floor_Grid")
	for which in Bar_Which do if which != .View_Rail do testing.expectf(t, !bar_changed(&c, which), "%v changed", which)
}

// The view rail starts with its eight view tools and is kept as the other bars are:
// whole in settings.txt and in a workspace's layout once it changes, as a fresh install's
// otherwise.
@(test)
view_rail_is_a_bar_of_its_own :: proc(t: ^testing.T) {
	path := "build/view_rail_test.txt"
	defer os.remove(path)
	a: App
	defer results_destroy(&a)
	bars_reset(&a.kit)
	testing.expect_value(t, bar_names(&a, .View_Rail), "View_Layout_Menu,Pass_Menu,Camera_Menu,Focus_Selected,Symmetry_X,Wireframe,Show_Section:Lights,Thumbnail")
	testing.expect(t, !bar_changed(&a, .View_Rail))
	bar_remove(&a, .View_Rail, 5)
	bar_put(&a, {which = .View_Rail, slot = 0, add = true}, {.Floor_Grid, 0})
	testing.expect(t, bar_changed(&a, .View_Rail) && !bar_changed(&a, .Tools))
	testing.expect(t, settings_save(&a, path))

	b: App
	defer results_destroy(&b)
	bars_reset(&b.kit)
	settings_load(&b, path)
	testing.expect_value(t, bar_names(&b, .View_Rail), bar_names(&a, .View_Rail))

	// A workspace's layout carries it, and a layout that names no bars puts it back.
	text := kit_layout_text(&a.kit)
	c: App
	defer results_destroy(&c)
	bars_reset(&c.kit)
	kit_layout_put(&c.kit, text)
	testing.expect_value(t, bar_names(&c, .View_Rail), bar_names(&a, .View_Rail))
	kit_layout_put(&c.kit, "bars\n")
	testing.expect(t, !bar_changed(&c, .View_Rail))
}
