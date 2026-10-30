package main

import "core:strings"
import "core:testing"

// Where the stack goes is the layout's: a fresh layout writes no line for it, Left and
// Float read back as written, and Reset panels docks it on the right again.
@(test)
stack_place_reads_back :: proc(t: ^testing.T) {
	a: App
	defer free_all(context.temp_allocator)
	k := &a.kit
	panels_default(k)
	stack_default(k)
	testing.expect(t, !strings.contains(kit_layout_text(k), "stack_place"), "a fresh layout names where the stack goes")
	for place in ([?]Stack_Place{.Left, .Float}) {
		stack_place_set(&a, place)
		text := kit_layout_text(k)
		b: App
		kit_layout_put(&b.kit, text)
		testing.expect_value(t, b.kit.stack.place, place)
		testing.expect_value(t, kit_layout_text(&b.kit), text)
	}
	testing.expect_value(t, k.panels.moves, 2)
	windows_reset(k)
	_, docked := stack_docked(k)
	testing.expect(t, docked && k.stack.place == .Right, "Reset panels left the stack where it was")
	// Words that name no place leave it on the right.
	stack_place_read(k, {"stack_place", "upside_down"})
	testing.expect_value(t, k.stack.place, Stack_Place.Right)
}

// An older file's columns say where the stack goes: the column that names Inspector, or
// floating when a right column line leaves it out; a left column alone leaves it on the
// right, as such a file had it. The windows a column held float.
@(test)
old_column_lines_settle_the_stack_place :: proc(t: ^testing.T) {
	Case :: struct {
		lines: [2][]string,
		place: Stack_Place,
	}
	cases := [?]Case{
		{{{"column", "left", "Inspector", "Stats"}, {"column", "right"}}, .Left},
		{{{"column", "right", "Stats", "History"}, nil}, .Float},
		{{{"column", "left", "Colors"}, nil}, .Right},
		{{{"column", "right", "Inspector", "Stats"}, {"column", "middle", "Inspector"}}, .Right},
	}
	for c, i in cases {
		a: App
		k := &a.kit
		panels_default(k)
		stack_default(k)
		old: Panels_Old
		for line in c.lines do if line != nil do panels_load_line(k, line, &old)
		panels_old_settle(k, &old)
		testing.expectf(t, k.stack.place == c.place, "case %d: the stack went %v", i, k.stack.place)
		testing.expectf(t, len(old.kept) == 0, "case %d: a window became a card", i)
	}
	free_all(context.temp_allocator)
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
