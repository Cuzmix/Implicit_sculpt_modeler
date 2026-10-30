package main

import "core:strings"
import "core:testing"

// A stack line can leave a card out with `-Card`; the layout writes it back the same way,
// and a fresh layout leaves out the look's cards (and every section's palette) without
// writing a stack line at all.
@(test)
a_stack_line_leaves_cards_out :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	fresh: Kit_State
	kit_layout_put(&fresh, "open Inspector\n")
	testing.expect_value(t, fresh.stack.hidden, STACK_HIDDEN_DEFAULT)
	testing.expect(t, !strings.contains(kit_layout_text(&fresh), "stack "), "a fresh layout writes a stack line")
	testing.expect_value(t, stack_text(&fresh), "Brush+,Symmetry,Layers,Scene,Tools")

	k: Kit_State
	kit_layout_put(&k, "open Inspector\nstack -Brush Symmetry+ Layers Scene Tools Palettes Lights Material Environment\n")
	testing.expect_value(t, k.stack.hidden, bit_set[Panel_Kind]{.Brush} + STACK_SECTION_PANELS)
	testing.expect_value(t, stack_text(&k), "Symmetry+,Layers,Scene,Tools,Lights,Material,Environment")
	text := kit_layout_text(&k)
	again: Kit_State
	kit_layout_put(&again, text)
	testing.expect(t, kit_layout_text(&again) == text, text)
	testing.expect_value(t, again.stack.hidden, bit_set[Panel_Kind]{.Brush} + STACK_SECTION_PANELS)
}

// Opening the Lights section in Lens shows its card in the stack, open, wherever the user
// was; the tall cards fold for it.
@(test)
opening_a_look_section_shows_its_card :: proc(t: ^testing.T) {
	a: App
	stack_default(&a.kit)
	testing.expect(t, .Lights in a.kit.stack.hidden)
	stack_reveal(&a, .Lights)
	testing.expect(t, .Lights not_in a.kit.stack.hidden && .Lights in a.kit.stack.open)
	testing.expect(t, .Brush not_in a.kit.stack.open)
	testing.expect_value(t, stack_card_of(&a, .Material), Panel_Kind.Material)
	testing.expect_value(t, stack_card_of(&a, .Environment), Panel_Kind.Environment)
}

// Render is the look's cards, the render in the mini view, and reads back as
// written.
@(test)
render_is_the_looks_cards :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	studio := built_in_layout(.Render)
	k: Kit_State
	kit_layout_put(&k, studio)
	testing.expect(t, kit_layout_text(&k) == studio, studio)
	testing.expect(t, k.inspector && k.thumbnail)
	testing.expect_value(t, k.stack.hidden, bit_set[Panel_Kind]{.Brush, .Symmetry, .Layers, .Scene, .Tools} + STACK_SECTION_PANELS)
	testing.expect_value(t, k.stack.open, bit_set[Panel_Kind]{.Lights, .Material})
	testing.expect_value(t, k.second.pass, Second_Pass.Render)
	testing.expect(t, !strings.contains(studio, "pinned"), studio)
}

// A workspace saved while the stack had its Palettes card reads as unchanged: the built-in
// layouts as an older build wrote them are written again as this one writes them.
@(test)
an_old_layout_with_palettes_reads_unmodified :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	model := "open Inspector\nstack Brush+ Layers Scene Symmetry -Tools Palettes\nbars\n"
	render := "thumbnail Follow Render\nopen Inspector Thumbnail\nwindow Thumbnail 1 End End 390 112 0\nstack Lights+ Material+ Environment -Brush -Symmetry -Layers -Scene -Tools Palettes\nbars\n"
	testing.expect_value(t, stack_layout_upgrade(model), built_in_layout(.Model))
	testing.expect_value(t, stack_layout_upgrade(render), built_in_layout(.Render))
	// Text that names no Palettes card is left as it is.
	sculpt := built_in_layout(.Sculpt)
	testing.expect_value(t, stack_layout_upgrade(sculpt), sculpt)
	testing.expect(t, strings.contains(stack_layout_upgrade("open Inspector\nstack_size default Palettes=200\n"), "stack_size") == false)
}
