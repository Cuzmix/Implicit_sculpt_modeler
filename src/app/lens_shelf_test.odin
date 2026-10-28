package main

import "core:os"
import "core:testing"
import sdl "vendor:sdl3"

import "../sculpt"

// Each shelf page is a bar of its own: a fresh install's brushes, changed by the bars'
// procs, kept whole in settings.txt, and left out of a workspace's layout, as the dock is.
@(test)
shelf_pages_are_bars_kept_in_settings_not_layouts :: proc(t: ^testing.T) {
	path := "build/shelf_test.txt"
	defer os.remove(path)
	a: App
	defer results_destroy(&a)
	bars_reset(&a.kit)
	testing.expect_value(t, bar_names(&a, .Shelf_Sculpt), "Brush:Clay,Brush:Draw,Brush:Smooth,Brush:Inflate,Brush:Pinch,Brush:Crease,Brush:Grab,Brush:Flatten,Brush:Mask,Brush:Layer")
	testing.expect_value(t, bar_names(&a, .Shelf_Curve), "Tool_Curve,Tool_Insert,Brush:Smooth")
	for p in Shelf_Page do testing.expect(t, !bar_changed(&a, shelf_which(p)))
	page, ok := shelf_page_of(.Shelf_Move)
	testing.expect(t, ok && page == .Move)
	_, ok = shelf_page_of(.View_Rail)
	testing.expect(t, !ok)

	bar_put(&a, {which = .Shelf_Paint, slot = 0, add = true}, {.Brush, int(sculpt.Brush_Kind.Inflate)})
	bar_remove(&a, .Shelf_Sculpt, 9)
	testing.expect(t, bar_changed(&a, .Shelf_Paint) && bar_changed(&a, .Shelf_Sculpt) && !bar_changed(&a, .Shelf_Move))
	testing.expect_value(t, bar_capacity(.Shelf_Sculpt), SHELF_MAX)
	testing.expect(t, settings_save(&a, path))

	b: App
	defer results_destroy(&b)
	bars_reset(&b.kit)
	settings_load(&b, path)
	testing.expect_value(t, bar_names(&b, .Shelf_Paint), bar_names(&a, .Shelf_Paint))
	testing.expect_value(t, bar_names(&b, .Shelf_Sculpt), bar_names(&a, .Shelf_Sculpt))

	// A workspace's layout neither carries the pages nor puts them back.
	text := kit_layout_text(&a.kit)
	c: App
	defer results_destroy(&c)
	bars_reset(&c.kit)
	kit_layout_put(&c.kit, text)
	testing.expect(t, !bar_changed(&c, .Shelf_Paint))
	kit_layout_put(&a.kit, "bars\n")
	testing.expect(t, bar_changed(&a, .Shelf_Paint))
}

// What the picker can put on a tile: a plain brush or a tool's command; a preset has no
// command of its own, so it stays in the picker.
@(test)
shelf_takes_brushes_and_tools :: proc(t: ^testing.T) {
	s, ok := shelf_slot_of({what = .Slot, slot = {kind = .Crease}})
	testing.expect(t, ok && s == Bar_Slot{.Brush, int(sculpt.Brush_Kind.Crease)})
	s, ok = shelf_slot_of({what = .Tool, tool = .Curve})
	testing.expect(t, ok && s.id == .Tool_Curve)
	_, ok = shelf_slot_of({what = .Slot, slot = {kind = .Clay, preset = 1}})
	testing.expect(t, !ok)
	testing.expect_value(t, shelf_label({.Brush, int(sculpt.Brush_Kind.Snake_Hook)}), "Snake hook")
}

// B picks the Sculpt tool in Classic and opens the brush picker in Lens.
@(test)
b_opens_the_brush_picker_in_lens :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	b := Chord{key = sdl.K_B}
	owner :: proc(app: ^App, c: Chord) -> Command_Id {
		b, _ := chord_owner(app, c)
		return b.command
	}
	testing.expect_value(t, owner(app, b), Command_Id.Tool_Sculpt)
	app.kit.chrome = .Lens
	keymap_rebuild(app)
	testing.expect_value(t, owner(app, b), Command_Id.Brush_Picker)
	command_run(app, .Brush_Picker)
	testing.expect(t, app.kit.browser && app.kit.browser_at == .Dock)
	command_run(app, .Brush_Picker)
	testing.expect(t, !app.kit.browser)
}

// Lens's brush pie is a bar of eight: a fresh install's brushes clockwise from the top,
// kept in settings.txt and left out of a workspace's layout, as the shelf's pages are.
@(test)
brush_pie_is_a_bar_kept_in_settings :: proc(t: ^testing.T) {
	path := "build/brush_pie_test.txt"
	defer os.remove(path)
	a: App
	defer results_destroy(&a)
	bars_reset(&a.kit)
	a.kit.chrome = .Lens
	testing.expect_value(t, bar_names(&a, .Brush_Pie), "Brush:Clay,Brush:Draw,Brush:Inflate,Brush:Crease,Brush:Grab,Brush:Flatten,Brush:Pinch,Brush:Smooth")
	testing.expect_value(t, pie_slot_count(&a, 0), PIE_SLOTS)
	testing.expect(t, pie_slot(&a, 0, 4) == Bar_Slot{.Brush, int(sculpt.Brush_Kind.Grab)})
	testing.expect(t, pie_slot(&a, 0, PIE_SLOTS) == Bar_Slot{})

	bar_put(&a, {which = .Brush_Pie, slot = 0}, {.Brush, int(sculpt.Brush_Kind.Snake_Hook)})
	testing.expect(t, bar_changed(&a, .Brush_Pie))
	testing.expect(t, settings_save(&a, path))
	b: App
	defer results_destroy(&b)
	bars_reset(&b.kit)
	settings_load(&b, path)
	testing.expect_value(t, bar_names(&b, .Brush_Pie), bar_names(&a, .Brush_Pie))

	c: App
	defer results_destroy(&c)
	bars_reset(&c.kit)
	kit_layout_put(&c.kit, kit_layout_text(&a.kit))
	testing.expect(t, !bar_changed(&c, .Brush_Pie))
}
