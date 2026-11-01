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

	// A current file, so the old tools strip (version 12) does not join the pages.
	damaged := "version 12\nbar_count view_rail 2\nbar view_rail 0 No_Such_Command\nbar view_rail 1 Floor_Grid\nbar view_rail 99 Wireframe\nbar_count bottom_tools x\n" +
		"chrome classic\npanes_under_panels 0\nbar_count right_rail 1\nbar right_rail 0 Remesh\nbar dock 0 Remesh\ndock_count 9\ndock 0 command Remesh\ndock 1 brush Clay\ndock_pack 2 set Stone\n"
	testing.expect(t, os.write_entire_file(path, transmute([]u8)damaged) == nil)
	c: App
	defer results_destroy(&c)
	bars_reset(&c.kit)
	settings_load(&c, path)
	testing.expect_value(t, bar_names(&c, .View_Rail), "Show_Panel:Scene,Floor_Grid")
	for which in Bar_Which do if which != .View_Rail do testing.expectf(t, !bar_changed(&c, which), "%v changed", which)
}

// The view rail starts with its panels, the View island with the view's tools, and is kept as the other bars are:
// whole in settings.txt and in a workspace's layout once it changes, as a fresh install's
// otherwise.
@(test)
view_rail_is_a_bar_of_its_own :: proc(t: ^testing.T) {
	path := "build/view_rail_test.txt"
	defer os.remove(path)
	a: App
	defer results_destroy(&a)
	bars_reset(&a.kit)
	testing.expect_value(t, bar_names(&a, .View_Rail), "Show_Panel:Scene,Show_Section:Layers,Show_Section:Material")
	testing.expect_value(t, bar_names(&a, .View_Island), "View_Layout_Menu,Symmetry_X,Wireframe,Show_Section:Lights,Focus_Selected")
	testing.expect(t, !bar_changed(&a, .View_Rail) && !bar_changed(&a, .View_Island))
	bar_remove(&a, .View_Rail, 2)
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

// A tap on the shelf's Retopologize tile runs the command, so with nothing to run it on
// the tile is dimmed as the other tools are; its section is what its long press opens.
@(test)
retopologize_tile_runs_the_command :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	bars_reset(&app.kit)
	testing.expect(t, !bar_enabled(&app, {.Retopologize, 0}), "Retopologize takes a tap with no object")
	testing.expect(t, bar_has_more(.Retopologize), "Retopologize lost its long press")
}

// A carried button let go within its bar moves there, before the button it is let go by;
// on another bar it goes there and off its own; a full bar, one that has it already and
// one that does not take it refuse; let go clear of the bars it comes off, and Undo puts
// it back where it was.
@(test)
bars_drag_and_drop :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	bars_reset(&app.kit)
	// The rail with four view tools, as it held before the View island took them.
	rail_tools := [?]Bar_Slot{{.View_Layout_Menu, 0}, {.Pass_Menu, 0}, {.Camera_Menu, 0}, {.Show_Section, int(Kit_Section.Lights)}}
	app.kit.view_rail = bar_list_of(rail_tools[:], bar_default_look(.View_Rail))
	// The wireframe joins the rail's four, at its end, for the strip to take later.
	bar_put(&app, {which = .View_Rail, slot = 4, add = true}, {.Wireframe, 0})
	rail := bar_used(&app, .View_Rail)
	camera := Bar_Carry{slot = rail[2], look = .Chip, from = .View_Rail, from_slot = 2}
	testing.expect(t, bar_drop(&app, camera, {which = .View_Rail, at = 0, ok = true}))
	testing.expect_value(t, bar_used(&app, .View_Rail)[0], Bar_Slot{.Camera_Menu, 0})
	testing.expect_value(t, bar_used(&app, .View_Rail)[1], Bar_Slot{.View_Layout_Menu, 0})
	// Let go after itself, it stays.
	first := Bar_Carry{slot = {.Camera_Menu, 0}, look = .Chip, from = .View_Rail, from_slot = 0}
	testing.expect(t, bar_drop(&app, first, {which = .View_Rail, at = 1, ok = true}))
	testing.expect_value(t, bar_used(&app, .View_Rail)[0], Bar_Slot{.Camera_Menu, 0})
	// Down the bar: before the button at 3 is after the one at 2 once it has left its place.
	testing.expect(t, bar_drop(&app, first, {which = .View_Rail, at = 3, ok = true}))
	testing.expect_value(t, bar_used(&app, .View_Rail)[2], Bar_Slot{.Camera_Menu, 0})

	// Onto the tool strip: it joins there and leaves the rail.
	n := bar_count(&app, .View_Rail)^
	wire := Bar_Carry{slot = {.Wireframe, 0}, look = .Chip, from = .View_Rail, from_slot = 4}
	testing.expect_value(t, bar_used(&app, .View_Rail)[4], wire.slot)
	spots := []Bar_Spot{{which = .Tools, slot = 0, rect = {0, 0, 40, 40}}}
	target, found := bar_target(&app, wire, spots, {30, 20})
	testing.expect(t, found && target.ok && target.at == 1)
	testing.expect(t, bar_drop(&app, wire, target))
	testing.expect_value(t, bar_used(&app, .Tools)[1], wire.slot)
	testing.expect_value(t, bar_count(&app, .View_Rail)^, n - 1)
	// The strip has it now: from Search it is refused there.
	again, _ := bar_target(&app, {slot = wire.slot}, spots, {10, 20})
	testing.expect(t, !again.ok)
	// A brush is the shelf's and the docks', never the rail's.
	ok, _ := bar_takes(.View_Rail, {.Brush, 0})
	testing.expect(t, !ok)
	ok, _ = bar_takes(.Shelf_Sculpt, {.Brush, 0})
	testing.expect(t, ok)
	// Full: the strip holds TOOLS_MAX.
	for bar_count(&app, .Tools)^ < TOOLS_MAX do bar_put(&app, {which = .Tools, slot = 0, add = true}, {.Flat_Shading, 0})
	full, _ := bar_target(&app, {slot = {.Polygroups, 0}, from = .View_Rail, from_slot = 0}, spots, {10, 20})
	testing.expect(t, !full.ok)

	// Off: it comes off the rail, and Undo puts it back in its place.
	before := bar_names(&app, .View_Rail)
	focus := Bar_Carry{slot = bar_used(&app, .View_Rail)[3], look = .Chip, from = .View_Rail, from_slot = 3}
	bar_drop_off(&app, focus)
	testing.expect_value(t, bar_count(&app, .View_Rail)^, n - 2)
	bar_removed_undo(&app)
	testing.expect_value(t, bar_names(&app, .View_Rail), before)
}
