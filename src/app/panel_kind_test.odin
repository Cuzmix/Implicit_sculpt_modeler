package main

import "core:fmt"
import "core:strings"
import "core:testing"

// Every card and every section's palette has a name and a word that read back as itself,
// and a title; a name this version does not know, or a section no palette shows, reads as
// nothing.
@(test)
panel_kinds_read_back :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	for c in Panel_Kind {
		kind, ok := panel_kind_from_name(panel_kind_name(c))
		testing.expect(t, ok && kind == c, panel_kind_name(c))
		kind, ok = panel_from_word(panel_word(c))
		testing.expect(t, ok && kind == c, panel_word(c))
		testing.expect(t, panel_kind_title(&app, c) != "")
	}
	for s in Kit_Section do if int(s) >= TRAY_SECTIONS {
		_, ok := panel_of_section(s)
		testing.expect(t, !ok, "a Stats section has no palette")
		_, ok = panel_kind_from_name(fmt.tprintf("section:%v", s))
		testing.expect(t, !ok)
	}
	for name in ([]string{"card:Nope", "section:", "section:Frame", "card:Mask", "window:Stats", "", "Brush"}) {
		_, ok := panel_kind_from_name(name)
		testing.expect(t, !ok, name)
	}
	for word in ([]string{"Nope", "section:Nope", "Mask", "card:Brush"}) {
		_, ok := panel_from_word(word)
		testing.expect(t, !ok, word)
	}
	free_all(context.temp_allocator)
}

// Each tray section has its own palette and each palette its own section, the full Layers,
// Material and Lights sections beside their cards and Environment's its card.
@(test)
panel_of_section_is_one_to_one :: proc(t: ^testing.T) {
	hit: bit_set[Panel_Kind]
	for s in Kit_Section do if int(s) < TRAY_SECTIONS {
		p, ok := panel_of_section(s)
		testing.expect(t, ok, "every tray section has a palette")
		testing.expect(t, p not_in hit, "no two sections share a palette")
		hit += {p}
		if back, is := panel_section(p); is do testing.expect_value(t, back, s)
		else do testing.expect(t, s == .Environment && p == .Environment)
	}
	testing.expect_value(t, hit, STACK_SECTION_PANELS + {.Environment})
	p, _ := panel_of_section(.Layers)
	testing.expect_value(t, p, Panel_Kind.Layer_Settings)
	testing.expect_value(t, panel_kind_name(.Layer_Settings), "section:Layers")
	testing.expect_value(t, panel_word(.Layers), "Layers")
	free_all(context.temp_allocator)
}

// A fresh layout's stack writes nothing, as it did before sections could be cards; a layout
// that puts a section's palette in the stack, with a height, reads back as written, and a
// card line from before then leaves every section out.
@(test)
a_section_in_the_stack_reads_back :: proc(t: ^testing.T) {
	k := new(Kit_State)
	defer free(k)
	stack_default(k)
	testing.expect_value(t, kit_layout_stack_lines(k), "")
	k.stack.hidden -= {.Mask}
	k.stack.open += {.Mask}
	stack_move_to_k(k, .Mask, 1)
	k.stack.heights[.Mask] = 200
	text := kit_layout_stack_lines(k)
	// Moving a card among the docked ones leaves those left out where they were, so Tools
	// takes the place Mask had in the order.
	testing.expect_value(t, text, "stack Brush+ section:Mask+ Symmetry Layers Scene -Lights -Material -Environment Tools\nstack_size default section:Mask=200\n")

	c := new(Kit_State)
	defer free(c)
	stack_default(c)
	for line in strings.split_lines(strings.trim_space(text), context.temp_allocator) {
		f := strings.fields(line, context.temp_allocator)
		if f[0] == "stack" do stack_layout_read(c, f)
		else do stack_sizes_read(c, f)
	}
	testing.expect_value(t, stack_text(c), "Brush+,Mask+,Symmetry,Layers,Scene,Tools")
	testing.expect_value(t, c.stack.heights[.Mask], f32(200))
	testing.expect_value(t, kit_layout_stack_lines(c), text)
	stack_layout_read(c, {"stack", "Brush+", "Symmetry", "Layers", "Scene", "Tools", "Palettes"})
	testing.expect(t, STACK_SECTION_PANELS <= c.stack.hidden, "a line naming no section leaves them all out")
	free_all(context.temp_allocator)
}

// The stack's own lines of a layout, as kit_layout_text writes them.
@(private = "file")
kit_layout_stack_lines :: proc(k: ^Kit_State) -> string {
	b := strings.builder_make(context.temp_allocator)
	stack_layout_save(k, &b)
	stack_sizes_save(k, &b)
	return strings.to_string(b)
}
