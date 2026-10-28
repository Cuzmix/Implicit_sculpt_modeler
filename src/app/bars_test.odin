package main

import "core:os"
import "core:testing"

// The right bar's column and the bottom bar's strip take any command, in any order, up
// to their size; the dock keeps one slot at least.
@(test)
bars_insert_move_and_remove :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	bars_reset(&app.kit)
	testing.expect(t, !bar_changed(&app, .Shortcuts) && !bar_changed(&app, .Tools) && !bar_changed(&app, .Dock))
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

	// A dock slot takes a command; the last slot cannot go.
	bar_put(&app, {which = .Dock, slot = 2}, {.Remesh, 0})
	testing.expect_value(t, dock_names(&app, 0, 4), "Draw,Smooth,Remesh,Flatten")
	for _ in 0 ..< DOCK_DEFAULT_COUNT do bar_remove(&app, .Dock, 0)
	testing.expect_value(t, len(dock_used(&app)), 1)
}

// settings.txt keeps the bars that changed whole, and the dock's commands and count; a
// fresh install's bars write nothing, and an unknown command keeps the slot as it was.
@(test)
bars_are_remembered :: proc(t: ^testing.T) {
	path := "build/bars_test.txt"
	defer os.remove(path)
	a: App
	defer results_destroy(&a)
	bars_reset(&a.kit)
	bar_remove(&a, .Shortcuts, 9)
	bar_put(&a, {which = .Shortcuts, slot = 10, add = true}, {.Ortho_Toggle, 0})
	bar_put(&a, {which = .Dock, slot = 21, add = true}, {.Subdivide, 0})
	bar_put(&a, {which = .Dock, slot = 0}, {.Brush, 3})
	testing.expect(t, settings_save(&a, path))

	b: App
	defer results_destroy(&b)
	bars_reset(&b.kit)
	settings_load(&b, path)
	testing.expect_value(t, bar_names(&b, .Shortcuts), bar_names(&a, .Shortcuts))
	testing.expect_value(t, bar_names(&b, .Tools), bar_names(&a, .Tools))
	testing.expect_value(t, len(dock_used(&b)), DOCK_DEFAULT_COUNT + 1)
	testing.expect_value(t, b.kit.dock[21].command, Bar_Slot{.Subdivide, 0})
	testing.expect_value(t, b.kit.dock[0].command, Bar_Slot{.Brush, 3})

	damaged := "bar_count right_rail 2\nbar right_rail 0 No_Such_Command\nbar right_rail 1 Wireframe\nbar right_rail 99 Wireframe\nbar_count bottom_tools x\nbar dock 0 Remesh\ndock 0 command Nothing\n"
	testing.expect(t, os.write_entire_file(path, transmute([]u8)damaged) == nil)
	c: App
	defer results_destroy(&c)
	bars_reset(&c.kit)
	settings_load(&c, path)
	testing.expect_value(t, bar_names(&c, .Shortcuts), "Shading_Menu,Wireframe")
	testing.expect(t, !bar_changed(&c, .Tools))
	testing.expect(t, !bar_changed(&c, .Dock))
}

// The Lens view rail starts with its eight view tools and is kept as the other bars are:
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
	testing.expect(t, bar_changed(&a, .View_Rail) && !bar_changed(&a, .Shortcuts))
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
