package main

import "core:os"
import "core:testing"

import "../sculpt"

@(private = "file")
pies_app :: proc(app: ^App) {
	app.kit.pies = PIE_DEFAULTS
	app.kit.scale = 1
}

// Every default slot holds a command a pie may hold, and its name reads back as it.
@(test)
default_pies_resolve :: proc(t: ^testing.T) {
	fresh := PIE_DEFAULTS
	for pie, n in fresh {
		for s, i in pie {
			if s.id == .None do continue
			testing.expectf(t, pie_lists(s.id), "pie %d slot %d holds %v", n, i, s.id)
			id, arg, ok := command_from_name(command_name(s.id, s.arg))
			testing.expectf(t, ok && id == s.id && arg == s.arg, "pie %d slot %d: %v %d reads back as %v %d", n, i, s.id, s.arg, id, arg)
		}
	}
	testing.expect(t, !pie_lists(.Pie))
	testing.expect(t, pie_lists(.Command_Palette), "Search may sit in a pie, though the palette does not list itself")
	free_all(context.temp_allocator)
}

// Eight slices run clockwise from the top; the middle is none.
@(test)
eight_slices_go_round_from_the_top :: proc(t: ^testing.T) {
	testing.expect_value(t, pie_slice({0, -100}, 1, 8), 0)
	testing.expect_value(t, pie_slice({100, 0}, 1, 8), 2)
	testing.expect_value(t, pie_slice({0, 100}, 1, 8), 4)
	testing.expect_value(t, pie_slice({-100, 0}, 1, 8), 6)
	testing.expect_value(t, pie_slice({-70, -71}, 1, 8), 7)
	testing.expect_value(t, pie_slice({10, 10}, 1, 8), -1)
	// At twice the scale the middle is twice as wide.
	testing.expect_value(t, pie_slice({0, -60}, 2, 8), -1)
}

// The pie key opens the pie and the same key closes it; a click on a slice runs its
// command and closes it, one on an empty or disabled slice keeps it open, one in the
// middle closes it with nothing run. The frame it opened in picks nothing.
@(test)
user_pie_picks_by_click :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	pies_app(&app)
	p := &app.ui.pie
	testing.expect(t, command_run(&app, .Pie, 0))
	testing.expect(t, p.open && p.which == 1)
	testing.expect(t, command_run(&app, .Pie, 0))
	testing.expect(t, !p.open)
	testing.expect(t, command_run(&app, .Pie, 0))
	testing.expect(t, command_run(&app, .Pie, 1))
	testing.expect(t, p.open && p.which == 2, "another pie's key switches to it")
	center := p.center

	click := proc(app: ^App, at: [2]f32) {
		input := Viewport_Input{mouse_pos = at, hovered = true}
		app.device.pressed, app.device.down = {.Left}, {.Left}
		pie_update(app, &input, false)
		app.device.pressed, app.device.down = {}, {}
		app.ui.pie.swallow = false
	}
	// The click that opened it, in its own frame, is spent.
	p^ = {open = true, which = 1, center = center, opened_frame = app.kit.frame, hover = -1}
	click(&app, center + {100, 0})
	testing.expect(t, p.open && !app.wireframe)
	app.kit.frame += 1
	click(&app, center + {100, 0})
	testing.expect(t, !p.open && app.wireframe)
	testing.expect_value(t, app.kit.pie_runs, 1)

	app.kit.pies[0][4] = {}
	p^ = {open = true, which = 1, center = center, hover = -1}
	click(&app, center + {0, 100})
	testing.expect(t, p.open, "an empty slot keeps it open")
	click(&app, center)
	testing.expect(t, !p.open && app.kit.pie_runs == 1)
}

// A command goes in a slot and comes out; Reset puts the defaults back.
@(test)
pie_slots_change :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	pies_app(&app)
	testing.expect(t, !pie_changed(&app, 2))
	app.kit.pies[2][0] = {.Remesh, 0}
	testing.expect(t, pie_changed(&app, 2))
	testing.expect_value(t, pie_names(&app, 2), "Remesh,empty,empty,empty,empty,empty,empty,empty")
	testing.expect_value(t, pie_slot_label(app.kit.pies[2][0]), "Remesh")
	testing.expect_value(t, pie_slot_label({.Stats, 0}), "Stats panel")
	testing.expect_value(t, pie_slot_label({.Brush, int(sculpt.Brush_Kind.Clay)}), command_label(.Brush, int(sculpt.Brush_Kind.Clay)))
	testing.expect_value(t, pie_slot_label({}), "Empty")
	app.kit.pies = PIE_DEFAULTS
	for n in 0 ..< USER_PIES do testing.expect(t, !pie_changed(&app, n))
	free_all(context.temp_allocator)
}

// Stars go on and off in the order given, up to MAX_FAVOURITES; the palette lists them
// first only while nothing is typed.
@(test)
favourites_come_first :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	testing.expect(t, favourite_toggle(&app, .Wireframe, 0))
	testing.expect(t, favourite_toggle(&app, .Remesh, 0))
	testing.expect(t, favourite_toggle(&app, .Mask, int(sculpt.Mask_Command.Invert)))
	testing.expect(t, favourite_toggle(&app, .Remesh, 0))
	testing.expect_value(t, app.kit.favourite_count, 2)
	testing.expect_value(t, favourite_find(&app, .Mask, int(sculpt.Mask_Command.Invert)), 1)
	testing.expect_value(t, favourite_find(&app, .Remesh, 0), -1)

	entries := palette_entries()
	enabled := make([]bool, len(entries), context.temp_allocator)
	for &e in enabled do e = true
	recent := []Palette_Entry{{.Command, .Frame_All, 0}}
	hits := palette_rank("", entries, recent, enabled, favourite_entries(&app))
	testing.expect_value(t, entries[hits[0].entry], Palette_Entry{.Command, .Wireframe, 0})
	testing.expect_value(t, entries[hits[1].entry], Palette_Entry{.Command, .Mask, int(sculpt.Mask_Command.Invert)})
	testing.expect_value(t, entries[hits[2].entry], Palette_Entry{.Command, .Frame_All, 0})
	// Typed, the best match wins whether starred or not.
	hits = palette_rank("frame all", entries, nil, enabled, favourite_entries(&app))
	testing.expect_value(t, entries[hits[0].entry], Palette_Entry{.Command, .Frame_All, 0})

	for id in Command_Id {
		if app.kit.favourite_count == MAX_FAVOURITES do break
		if palette_lists(id) && COMMANDS[id].args == 0 && favourite_find(&app, id, 0) < 0 do testing.expect(t, favourite_toggle(&app, id, 0))
	}
	testing.expect_value(t, app.kit.favourite_count, MAX_FAVOURITES)
	testing.expect(t, !favourite_toggle(&app, .Help, 1), "a seventeenth star is refused")
	testing.expect_value(t, app.kit.favourite_count, MAX_FAVOURITES)
	free_all(context.temp_allocator)
}

// settings.txt keeps the pies that changed, whole, and the stars in order; a damaged or
// unknown line is skipped and the slot keeps its default.
@(test)
pies_are_remembered :: proc(t: ^testing.T) {
	path := "build/user_pies_test.txt"
	defer os.remove(path)
	a: App
	defer results_destroy(&a)
	pies_app(&a)
	a.kit.pies[2][0] = {.Remesh, 0}
	a.kit.pies[2][7] = {.Brush, int(sculpt.Brush_Kind.Clay)}
	a.kit.pies[0][7] = {}
	_ = favourite_toggle(&a, .Flat_Shading, 0)
	_ = favourite_toggle(&a, .Help, 1)
	testing.expect(t, settings_save(&a, path))

	data, _ := os.read_entire_file(path, context.allocator)
	defer delete(data)
	extra := "pie 1 0 Nothing\npie 4 0 Remesh\npie 1 9 Remesh\npie 1 1 Pie:1\npie 1\nfavourite Nothing\nfavourite Flat_Shading\nfavourite Command_Palette\n"
	full := make([]u8, len(data) + len(extra))
	defer delete(full)
	copy(full, data)
	copy(full[len(data):], extra)
	testing.expect(t, os.write_entire_file(path, full) == nil)

	b: App
	defer results_destroy(&b)
	pies_app(&b)
	settings_load(&b, path)
	testing.expect_value(t, b.kit.pies, a.kit.pies)
	testing.expect_value(t, b.kit.favourite_count, 2)
	testing.expect_value(t, b.kit.favourites[0], Pie_Slot{.Flat_Shading, 0})
	testing.expect_value(t, b.kit.favourites[1], Pie_Slot{.Help, 1})
	free_all(context.temp_allocator)
}
