package main

import "core:os"
import "core:testing"

@(test)
a_column_shares_its_height_by_what_each_panel_wants :: proc(t: ^testing.T) {
	out: [4]f32
	// Room for all: each gets what it wants.
	panel_water_fill({100, 200, 50}, 1000, out[:3])
	testing.expect_value(t, out[0], 100)
	testing.expect_value(t, out[1], 200)
	testing.expect_value(t, out[2], 50)
	// Short of room: the small want is met, the two large split what is left evenly.
	panel_water_fill({600, 100, 900}, 700, out[:3])
	testing.expect_value(t, out[1], 100)
	testing.expect_value(t, out[0], 300)
	testing.expect_value(t, out[2], 300)
	// One that wants less than an even share gives the rest to the others.
	panel_water_fill({1000, 1000, 1000, 40}, 640, out[:4])
	testing.expect_value(t, out[3], 40)
	testing.expect_value(t, out[0], 200)
	testing.expect_value(t, out[0] + out[1] + out[2] + out[3], 640)
}

@(test)
panels_dock_float_and_move_within_their_columns :: proc(t: ^testing.T) {
	a: App
	defer free_all(context.temp_allocator)
	k := &a.kit
	panels_default(k)
	testing.expect_value(t, len(k.panels.columns[.Right]), 1)

	// Docked at the right column's foot in the order docked; up; then to the left column,
	// ahead of what is there.
	panel_dock(&a, Kit_Window.History, .Right, 1)
	panel_dock(&a, Kit_Window.Stats, .Right, 2)
	right := k.panels.columns[.Right]
	testing.expect(t, len(right) == 3 && right[1] == Panel_Ref(Kit_Window.History) && right[2] == Panel_Ref(Kit_Window.Stats), "docked in the wrong order")
	panel_shift(&a, Kit_Window.Stats, -1)
	testing.expect(t, k.panels.columns[.Right][1] == Panel_Ref(Kit_Window.Stats), "Move up did not move it")
	panel_dock(&a, Kit_Window.Thumbnail, .Left, 0)
	panel_dock(&a, Kit_Window.Stats, .Left, 0)
	side, index, docked := panel_docked(k, Kit_Window.Stats)
	testing.expect(t, docked && side == .Left && index == 0, "not docked first on the left")
	testing.expect_value(t, len(k.panels.columns[.Right]), 2)
	// Within its own column, after the one below it.
	panel_dock(&a, Kit_Window.Stats, .Left, 2)
	_, index, _ = panel_docked(k, Kit_Window.Stats)
	testing.expect_value(t, index, 1)

	// Floating takes it out of every column.
	panel_float(&a, Kit_Window.Thumbnail)
	_, _, docked = panel_docked(k, Kit_Window.Thumbnail)
	testing.expect(t, !docked, "Float left it docked")

	// Reset panels puts everything back.
	windows_reset(k)
	testing.expect_value(t, len(k.panels.columns[.Left]), 0)
	testing.expect_value(t, len(k.panels.columns[.Right]), 1)
}

@(test)
panels_read_back_what_they_wrote :: proc(t: ^testing.T) {
	path := "build/panels_test.txt"
	defer os.remove(path)
	defer free_all(context.temp_allocator)
	a: App
	panels_default(&a.kit)
	panel_dock(&a, Kit_Window.History, .Left, 0)
	panel_dock(&a, Kit_Window.Stats, .Left, 0)
	testing.expect(t, settings_save(&a, path))

	b: App
	panels_default(&b.kit)
	settings_load(&b, path)
	testing.expect_value(t, len(b.kit.panels.columns[.Left]), 2)
	testing.expect(t, b.kit.panels.columns[.Left][0] == Panel_Ref(Kit_Window.Stats) && b.kit.panels.columns[.Left][1] == Panel_Ref(Kit_Window.History), "the left column came back wrong")
	testing.expect_value(t, len(b.kit.panels.columns[.Right]), 1)

	// Words that name nothing, and a panel named twice, are passed over.
	c: App
	panels_default(&c.kit)
	old: Panels_Old
	panels_load_line(&c.kit, {"column", "right", "Inspector", "section:Nothing", "Settings", "inspector", "Stats"}, &old)
	testing.expect_value(t, len(c.kit.panels.columns[.Right]), 2)
	testing.expect(t, c.kit.panels.columns[.Right][1] == Panel_Ref(Kit_Window.Stats), "a word that names no panel was read")
	testing.expect_value(t, len(old.kept), 0)
}

// An older file's pinned sections, as a line of their own or a column's word, come back
// as cards kept at the stack's foot in the order they were named, folded where they were;
// a section named twice, or one that is not in the tray, is passed over.
@(test)
pins_from_an_older_file_become_cards :: proc(t: ^testing.T) {
	a: App
	defer free_all(context.temp_allocator)
	k := &a.kit
	panels_default(k)
	stack_default(k)
	old: Panels_Old
	panels_load_line(k, {"pinned", "Lights", "1", "End", "Start", "30", "120", "1"}, &old)
	panels_load_line(k, {"column", "right", "Inspector", "section:Mask", "section:Lights", "section:Frame"}, &old)
	panels_load_line(k, {"pinned", "Nothing", "0", "Start", "Start", "0", "0", "0"}, &old)
	testing.expect_value(t, len(old.kept), 2)
	panels_old_settle(k, &old)
	lights, _ := panel_of_section(.Lights)
	mask, _ := panel_of_section(.Mask)
	s := &k.stack
	testing.expect(t, stack_kept(s, lights) && stack_kept(s, mask), "a pin did not become a card")
	testing.expect(t, lights not_in s.open && mask in s.open, "a fold was not kept")
	testing.expect(t, order_of(s, lights) < order_of(s, mask), "the pins came back out of order")
	testing.expect(t, stack_valid(s), "the stack is no longer whole")
	frame, ok := panel_of_section(.Frame)
	testing.expect(t, !ok || !stack_kept(s, frame), "a section with no tray place became a card")

	order_of :: proc(s: ^Lens_Stack, p: Panel_Kind) -> int {
		for x, i in s.order do if x == p do return i
		return -1
	}
}

// Pin to the stack keeps a section as a card; again, it is left out as before.
@(test)
pin_section_keeps_and_unpins :: proc(t: ^testing.T) {
	a: App
	defer free_all(context.temp_allocator)
	panels_default(&a.kit)
	p, _ := panel_of_section(.Camera)
	testing.expect(t, !command_checked(&a, .Pin_Section, int(Kit_Section.Camera)), "pinned before it was")
	command_run(&a, .Pin_Section, int(Kit_Section.Camera))
	testing.expect(t, stack_kept(&a.kit.stack, p) && a.kit.inspector, "Pin did not keep it in a shown stack")
	testing.expect(t, command_checked(&a, .Pin_Section, int(Kit_Section.Camera)), "Pin is not ticked")
	command_run(&a, .Pin_Section, int(Kit_Section.Camera))
	testing.expect(t, !stack_kept(&a.kit.stack, p), "a second Pin left it in")
}

@(test)
every_panel_has_its_own_bit :: proc(t: ^testing.T) {
	seen: u64
	for w in Kit_Window {
		b := panel_bit(w)
		testing.expectf(t, b != 0 && seen & b == 0, "%v shares a bit", w)
		seen |= b
	}
}
