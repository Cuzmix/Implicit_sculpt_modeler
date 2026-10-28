package main

import "core:testing"

import "../sculpt"

// Each result's second line names where it lives: the shelf for a brush on it, the
// picker for one that is not, the tray's section, the view rail, the menu and its
// submenus, the top bar, Settings and the panels.
@(test)
palette_where_names_each_home :: proc(t: ^testing.T) {
	a: App
	defer results_destroy(&a)
	bars_reset(&a.kit)
	cmd :: proc(id: Command_Id, arg := 0) -> Palette_Entry {return {.Command, id, arg}}
	testing.expect_value(t, palette_where(&a, cmd(.Brush, int(sculpt.Brush_Kind.Clay))), "Shelf · Sculpt")
	testing.expect_value(t, palette_where(&a, cmd(.Brush, int(sculpt.Brush_Kind.Morph))), "Brush picker")
	testing.expect_value(t, palette_where(&a, cmd(.Floor_Grid)), "Scene palette · Floor grid")
	testing.expect_value(t, palette_where(&a, cmd(.View_Layout_Menu)), "View rail")
	testing.expect_value(t, palette_where(&a, cmd(.Save_Scene)), "Menu")
	testing.expect_value(t, palette_where(&a, cmd(.Export_Mesh)), "Menu · Export")
	testing.expect_value(t, palette_where(&a, cmd(.Undo)), "Top bar")
	testing.expect_value(t, palette_where(&a, cmd(.Flat_Shading)), "")
	testing.expect_value(t, palette_where(&a, {kind = .Settings_Tab, arg = int(Settings_Tab.Touch)}), "Settings")
	testing.expect_value(t, palette_where(&a, cmd(.Show_Section, int(Kit_Section.Layers))), "Panel · Layers card")
	testing.expect_value(t, palette_where(&a, cmd(.Show_Section, int(Kit_Section.Remesh))), "Panel · Object palette")
}

// Grouping puts commands, then brushes, then panels and settings, each in the order it
// ranked, and says which groups there are.
@(test)
palette_groups_keep_rank_inside_each :: proc(t: ^testing.T) {
	entries := []Palette_Entry{
		{.Command, .Brush, int(sculpt.Brush_Kind.Clay)},
		{kind = .Settings_Tab, arg = 0},
		{.Command, .Wireframe, 0},
		{.Command, .Brush, int(sculpt.Brush_Kind.Draw)},
		{.Command, .Remesh, 0},
	}
	hits := []Palette_Hit{{entry = 0}, {entry = 1}, {entry = 2}, {entry = 3}, {entry = 4}}
	out, groups := palette_group_hits(hits, entries)
	order: [5]int
	for h, i in out do order[i] = h.entry
	testing.expect_value(t, order, [5]int{2, 4, 0, 3, 1})
	testing.expect_value(t, groups, bit_set[Palette_Group]{.Commands, .Brushes, .Panels})
}

// Put on a bar puts a brush at the end of the shelf's page shown and a command at the end
// of the view rail; again, it leaves either where it is.
@(test)
put_on_a_bar_goes_where_it_belongs :: proc(t: ^testing.T) {
	a: App
	defer results_destroy(&a)
	bars_reset(&a.kit)
	a.kit.shelf.page = .Paint
	snake := Palette_Entry{.Command, .Brush, int(sculpt.Brush_Kind.Snake_Hook)}
	rail := bar_count(&a, .View_Rail)^
	paint := bar_count(&a, .Shelf_Paint)^
	testing.expect(t, palette_put_on_bar(&a, snake))
	testing.expect_value(t, bar_count(&a, .Shelf_Paint)^, paint + 1)
	testing.expect_value(t, bar_used(&a, .Shelf_Paint)[paint], Bar_Slot{.Brush, int(sculpt.Brush_Kind.Snake_Hook)})
	testing.expect(t, !palette_put_on_bar(&a, snake))
	testing.expect_value(t, bar_count(&a, .Shelf_Paint)^, paint + 1)
	wire := Palette_Entry{.Command, .Flat_Shading, 0}
	testing.expect(t, palette_put_on_bar(&a, wire))
	testing.expect_value(t, bar_count(&a, .View_Rail)^, rail + 1)
	testing.expect_value(t, palette_where(&a, wire), "View rail")
	testing.expect(t, !palette_put_on_bar(&a, {kind = .Settings_Tab}))
	testing.expect_value(t, a.kit.palette_bar_puts, 2)
}
