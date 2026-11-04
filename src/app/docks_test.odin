package main

import "core:fmt"
import "core:strings"
import "core:testing"

import "../ui"

// New dock makes the first free dock, floating in the middle, with Arrange on; four
// at most; a deleted dock goes with its buttons and place, and the next New dock is that
// one again, empty.
@(test)
new_docks_float_and_delete :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	k := &app.kit
	ui.frame_begin(&k.ctx, {window = {1600, 900}, pixel_density = 1, dt = 1.0 / 60})
	ui.frame_end(&k.ctx)
	for _ in 0 ..< USER_DOCKS do testing.expect(t, user_dock_new(&app))
	testing.expect(t, !user_dock_new(&app))
	testing.expect_value(t, user_docks_used(k), USER_DOCKS)
	testing.expect(t, k.bars_edit)
	// Each new dock is the one being filled: only its buttons are edited.
	testing.expect_value(t, k.edit_dock, Maybe(Dock_Id)(Dock_Id.Dock_4))
	testing.expect(t, dock_editing(k, .Dock_4) && !dock_editing(k, .Dock_1) && !dock_editing(k, .Rail))
	testing.expect(t, bar_editing(k, user_dock_which(3)) && !bar_editing(k, .View_Rail))
	testing.expect_value(t, k.docks[.Dock_2].place, Dock_Place{edge = .Float, at = user_dock_middle(k)})
	testing.expect_value(t, user_dock_middle(k), [2]f32{774, 390})

	k.dock_lists[1] = bar_list_of({{.Frame_All, 0}})
	k.docks[.Dock_2].more_lines = 2
	user_dock_delete(&app, 1)
	testing.expect(t, !k.docks[.Dock_2].used && k.dock_lists[1].count == 0)
	testing.expect_value(t, k.docks[.Dock_2], Dock{})
	testing.expect_value(t, k.arrange.docks_deleted, 1)
	testing.expect_value(t, user_docks_text(k), "1:0,3:0,4:0")
	testing.expect(t, user_dock_new(&app))
	testing.expect(t, k.docks[.Dock_2].used && dock_lines(k, .Dock_2) == 1 && k.dock_lists[1].count == 0)

	// A dock dropped on the rail's edge sends the rail to float where the dock was.
	at := k.docks[.Dock_1].at
	dock_place_set(&app, .Dock_1, {edge = .Right, along = 0.5})
	testing.expect_value(t, k.docks[.Rail].place, Dock_Place{edge = .Float, at = at})
	testing.expect_value(t, bar_side(&app, .Dock_1), ui.Side.Left)
	testing.expect(t, bar_column(.Dock_1))

	// Settings > Reset > Bars takes every dock away and puts the built-in ones back.
	bars_reset(k)
	testing.expect_value(t, user_docks_used(k), 0)
	testing.expect_value(t, user_docks_text(k), "none")
	testing.expect_value(t, dock_places_text(k), "offhand:default,rail:default,shelf:default")
	free_all(context.temp_allocator)
}

// Docks are the layout's: their lines read back with their places, lines and names, a
// line this version cannot take is passed over, buttons of a dock the layout does not name
// are dropped, and the settings file never holds them.
@(test)
docks_read_back :: proc(t: ^testing.T) {
	a: Kit_State
	a.docks[.Dock_1] = {used = true, place = {edge = .Right, along = 0.25}, more_lines = 1, names = .Always}
	a.dock_lists[0] = bar_list_of({{.Focus_Selected, 0}, {.Brush_Value, int(Brush_Value.Size)}}, .Chip)
	a.docks[.Dock_3] = {used = true, place = {edge = .Float, at = {400, 300}}, more_off = true}
	a.docks[.Offhand] = {place = {edge = .Right, along = 0.25}}
	a.docks[.Rail] = {more_lines = 2, names = .Off}
	a.docks[.Shelf] = {place = {edge = .Top, along = 0.2}}
	text := kit_layout_text(&a)
	testing.expect(t, strings.contains(text, "dock dock1 Right 0.25 0 0 2 Always 1\n"), text)
	testing.expect(t, strings.contains(text, "dock dock3 Float 0 400 300 1 Wide 0\n"), text)
	testing.expect(t, strings.contains(text, "dock rail Default 0 0 0 3 Off 1\n"), text)
	testing.expect(t, strings.contains(text, "dock shelf Top 0.2 0 0 1 Wide 1\n"), text)
	testing.expect(t, strings.contains(text, fmt.tprintf("bar dock_1 0 %s\n", command_name(.Focus_Selected, 0))), text)
	b: Kit_State
	kit_layout_put(&b, text)
	for d in Dock_Id {
		want := a.docks[d]
		// A built-in dock read back is marked in use, which nothing reads.
		if DOCK_HOME[d] != .Float do want.used = b.docks[d].used
		testing.expect_value(t, b.docks[d], want)
	}
	testing.expect_value(t, b.dock_lists[0], a.dock_lists[0])
	testing.expect_value(t, b.dock_lists[2].count, 0)
	testing.expect_value(t, dock_looks_text(&b), "offhand:1:wide,rail:3:off,shelf:1:wide,dock1:2:always,dock3:1:wide:nomore")

	// Wrong counts, names, edges and numbers, and buttons of a dock no line makes: none of them.
	kit_layout_put(&b, "dock dock5 Float 0 0 0 1 Wide 1\ndock shelf Left 0.5 0 0 1 Wide 1\ndock shelf Right 0.5 0 0 1 Wide 1\ndock offhand Left NaN 0 0 1 Wide 1\ndock offhand Float 0 inf 0 1 Wide 1\ndock rail Default 0 0 0 1 Tiles 1\ndock offhand Left 0 0 0 1\nbars\nbar_count dock_2 1\nbar dock_2 0 frame_all\n")
	testing.expect_value(t, user_docks_used(&b), 0)
	for d in Dock_Id do testing.expect_value(t, b.docks[d], Dock{})
	testing.expect(t, !strings.contains(kit_layout_text(&b), "dock"))

	// The settings file keeps no dock.
	out := strings.builder_make(context.temp_allocator)
	bars_save(&a, &out)
	testing.expect(t, !strings.contains(strings.to_string(out), "dock_"))
	free_all(context.temp_allocator)
}
