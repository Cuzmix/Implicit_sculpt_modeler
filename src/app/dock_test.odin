package main

import "core:os"
import "core:testing"

import "../sculpt"

@(private = "file")
dock_app :: proc(app: ^App) {
	app.kit.dock = DOCK_DEFAULT
	app.tool = .Brush
	app.brush.kind = .Clay
	app.brush.alpha = -1
	for &s, kind in app.brush.strengths do s = BRUSHES[kind].strength
}

// A slot takes a brush or a preset; picking it picks what it holds, and the dock knows
// whether the brush is in it.
@(test)
dock_slots_hold_brushes_and_presets :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	dock_app(&app)
	testing.expect(t, !dock_changed(&app))
	testing.expect(t, dock_has_brush(&app))
	dock_put(&app, 0, .Snake_Hook)
	testing.expect(t, dock_changed(&app))
	dock_slot_pick(&app, app.kit.dock[0])
	testing.expect_value(t, app.brush.kind, sculpt.Brush_Kind.Snake_Hook)
	testing.expect(t, dock_has_brush(&app))

	command_run(&app, .Brush, int(sculpt.Brush_Kind.Clay))
	testing.expect(t, preset_save_new(&app))
	dock_put(&app, 6, .Draw, 1)
	testing.expect_value(t, app.kit.dock[6], Dock_Slot{kind = .Clay, preset = 1})
	testing.expect_value(t, dock_names(&app, 0, DOCK_PAGE), "Snake_hook,Smooth,Clay,Flatten,Inflate,Grab,Clay_1")
	// On the preset, the plain Clay slot is not lit; the preset's is.
	testing.expect(t, !dock_slot_on(&app, app.kit.dock[2]))
	testing.expect(t, dock_slot_on(&app, app.kit.dock[6]))
	// A brush no slot holds once Pinch's own slot holds another.
	dock_put(&app, 7, .Draw)
	command_run(&app, .Brush, int(sculpt.Brush_Kind.Pinch))
	testing.expect(t, !dock_has_brush(&app))
	dock_slot_pick(&app, app.kit.dock[6])
	testing.expect_value(t, app.brush.preset, 1)
}

// Deleting a preset puts its slots back to its brush and keeps later presets' slots on
// their own.
@(test)
dock_slots_follow_deleted_presets :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	dock_app(&app)
	for _ in 0 ..< 3 do testing.expect(t, preset_save_new(&app))
	dock_put(&app, 0, .Draw, 1)
	dock_put(&app, 1, .Draw, 3)
	preset_delete(&app, 0)
	testing.expect_value(t, app.kit.dock[0], Dock_Slot{kind = .Clay})
	testing.expect_value(t, app.kit.dock[1], Dock_Slot{kind = .Clay, preset = 2})
	testing.expect_value(t, dock_slot_label(&app, app.kit.dock[1]), "Clay 3")
}

// settings.txt keeps the dock, preset slots by name; a damaged or unknown line keeps the
// slot as it was.
@(test)
dock_is_remembered :: proc(t: ^testing.T) {
	path := "build/dock_test.txt"
	defer os.remove(path)
	a: App
	defer results_destroy(&a)
	dock_app(&a)
	testing.expect(t, preset_save_new(&a) && preset_save_new(&a))
	testing.expect(t, preset_rename(&a, 1, "Big 50% clay"))
	dock_put(&a, 3, .Draw, 2)
	dock_put(&a, 5, .Cloth)
	testing.expect(t, settings_save(&a, path))

	b: App
	defer results_destroy(&b)
	dock_app(&b)
	settings_load(&b, path)
	testing.expect_value(t, b.kit.dock, a.kit.dock)
	testing.expect_value(t, dock_names(&b, 0, DOCK_PAGE), "Draw,Smooth,Clay,Big_50%_clay,Inflate,Cloth,Mask")

	damaged := "dock 21 brush Draw\ndock 1 brush Nobrush\ndock 2 preset Missing\ndock 4\ndock x brush Draw\n"
	testing.expect(t, os.write_entire_file(path, transmute([]u8)damaged) == nil)
	c: App
	defer results_destroy(&c)
	dock_app(&c)
	settings_load(&c, path)
	testing.expect(t, !dock_changed(&c))
}

// Three pages of seven; a brush picked some other way brings the page that holds it,
// unless the page shown holds it too.
@(test)
dock_pages_follow_the_brush :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	dock_app(&app)
	testing.expect_value(t, dock_pages(&app), DOCK_PAGES)
	first, count := dock_page_slots(&app)
	testing.expect_value(t, [2]int{first, count}, [2]int{0, DOCK_PAGE})
	command_run(&app, .Brush, int(sculpt.Brush_Kind.Cloth))
	first, count = dock_page_slots(&app)
	testing.expect_value(t, [2]int{first, count}, [2]int{DOCK_PAGE, DOCK_PAGE})
	testing.expect_value(t, dock_names(&app, first, count), "Pinch,Crease,Layer,Snake_hook,Cloth,Morph,History")
	// Paint's page, the third, also holds Mask: picking Mask there keeps it.
	command_run(&app, .Brush, int(sculpt.Brush_Kind.Paint))
	_, _ = dock_page_slots(&app)
	command_run(&app, .Brush, int(sculpt.Brush_Kind.Mask))
	first, _ = dock_page_slots(&app)
	testing.expect_value(t, first, 2 * DOCK_PAGE)
}
