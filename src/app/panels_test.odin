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

// Pin to the stack keeps a section as a card; again, it is left out as before.
@(test)
pin_section_keeps_and_unpins :: proc(t: ^testing.T) {
	a: App
	defer free_all(context.temp_allocator)
	panels_default(&a.kit)
	p := Panel_Kind.Camera
	testing.expect(t, !command_checked(&a, .Pin_Section, int(Panel_Kind.Camera)), "pinned before it was")
	command_run(&a, .Pin_Section, int(Panel_Kind.Camera))
	testing.expect(t, stack_kept(&a.kit.stack, p) && a.kit.inspector, "Pin did not keep it in a shown stack")
	testing.expect(t, command_checked(&a, .Pin_Section, int(Panel_Kind.Camera)), "Pin is not ticked")
	command_run(&a, .Pin_Section, int(Panel_Kind.Camera))
	testing.expect(t, !stack_kept(&a.kit.stack, p), "a second Pin left it in")
}
