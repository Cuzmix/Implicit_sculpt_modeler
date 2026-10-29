package main

import "core:fmt"
import "core:strings"
import "core:testing"

import "../ui"

// New dock makes the first free dock, floating in the middle, picked, with Arrange on; four
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
	testing.expect_value(t, k.arrange.picked, Maybe(Arrange_Zone)(Arrange_Zone.Dock_4))
	testing.expect_value(t, k.places[.Dock_2], Bar_Place{edge = .Float, at = user_dock_middle(k)})
	testing.expect_value(t, user_dock_middle(k), [2]f32{774, 390})

	k.docks[1].list = bar_list_of({{.Frame_All, 0}})
	k.docks[1].density = .Tiles
	user_dock_delete(&app, 1)
	testing.expect(t, !k.docks[1].used && k.docks[1].list.count == 0)
	testing.expect_value(t, k.places[.Dock_2], Bar_Place{})
	testing.expect_value(t, k.arrange.docks_deleted, 1)
	testing.expect_value(t, user_docks_text(k), "1:icons:0,3:icons:0,4:icons:0")
	testing.expect(t, user_dock_new(&app))
	testing.expect(t, k.docks[1].used && k.docks[1].density == .Icons && k.docks[1].list.count == 0)

	// A dock dropped on the rail's edge sends the rail to float where the dock was.
	at := k.places[.Dock_1].at
	bar_place_set(&app, .Dock_1, {edge = .Right, along = 0.5})
	testing.expect_value(t, k.places[.Rail], Bar_Place{edge = .Float, at = at})
	testing.expect_value(t, bar_side(&app, .Dock_1), ui.Side.Left)
	testing.expect(t, bar_column(.Dock_1))

	// Settings > Reset > Bars takes every dock away.
	bars_reset(k)
	testing.expect_value(t, user_docks_used(k), 0)
	testing.expect_value(t, user_docks_text(k), "none")
	testing.expect(t, !strings.contains(bar_places_text(k), "dock"))
	free_all(context.temp_allocator)
}

// Docks are the layout's: their lines read back, a line this version cannot take is passed
// over, buttons of a dock the layout does not name are dropped, a dock with no place
// floats in the middle, and the settings file never holds them.
@(test)
user_docks_read_back :: proc(t: ^testing.T) {
	a: Kit_State
	a.docks[0] = {used = true, density = .Tiles, list = bar_list_of({{.Focus_Selected, 0}, {.Brush_Value, int(Brush_Value.Size)}}, .Chip)}
	a.places[.Dock_1] = {edge = .Right, along = 0.25}
	a.docks[2] = {used = true}
	a.places[.Dock_3] = {edge = .Float, at = {400, 300}}
	text := kit_layout_text(&a)
	testing.expect(t, strings.contains(text, "user_dock 1 Tiles\n"), text)
	testing.expect(t, strings.contains(text, "user_dock 3 Icons\n"), text)
	testing.expect(t, strings.contains(text, fmt.tprintf("bar dock_1 0 %s\n", command_name(.Focus_Selected, 0))), text)
	b: Kit_State
	kit_layout_put(&b, text)
	for i in 0 ..< USER_DOCKS {
		testing.expect_value(t, b.docks[i].used, a.docks[i].used)
		testing.expect_value(t, b.docks[i].density, a.docks[i].density)
		testing.expect_value(t, b.docks[i].list.count, a.docks[i].list.count)
		testing.expect_value(t, b.docks[i].list.slots, a.docks[i].list.slots)
	}
	testing.expect_value(t, b.places, a.places)

	// Out of range, an unknown density, and buttons of a dock no line makes: none of them.
	kit_layout_put(&b, "user_dock 5 Icons\nuser_dock 0 Icons\nuser_dock 2 Panels\nbars\nbar_count dock_2 1\nbar dock_2 0 frame_all\n")
	testing.expect_value(t, user_docks_used(&b), 0)
	testing.expect(t, !strings.contains(kit_layout_text(&b), "dock"))
	kit_layout_put(&b, "user_dock 2 Icons\n")
	testing.expect_value(t, b.places[.Dock_2], Bar_Place{edge = .Float, at = user_dock_middle(&b)})

	// The settings file keeps no dock.
	out := strings.builder_make(context.temp_allocator)
	bars_save(&a, &out)
	testing.expect(t, !strings.contains(strings.to_string(out), "dock_"))
	free_all(context.temp_allocator)
}
