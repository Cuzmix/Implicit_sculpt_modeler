package main

import "core:strings"
import "core:testing"

// A stack line can leave a card out with `-Card`; the layout writes it back the same way,
// and a fresh layout leaves out the look's cards without writing a stack line at all.
@(test)
a_stack_line_leaves_cards_out :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	fresh: Kit_State
	kit_layout_put(&fresh, "open Inspector\n")
	testing.expect_value(t, fresh.stack.hidden, STACK_HIDDEN_DEFAULT)
	testing.expect(t, !strings.contains(kit_layout_text(&fresh), "stack "), "a fresh layout writes a stack line")
	testing.expect_value(t, stack_text(&fresh), "Brush+,Symmetry,Layers,Scene,Tools,Palettes")

	k: Kit_State
	kit_layout_put(&k, "open Inspector\nstack -Brush Symmetry+ Layers Scene Tools Palettes Lights Material Environment\n")
	testing.expect_value(t, k.stack.hidden, bit_set[Stack_Card]{.Brush})
	testing.expect_value(t, stack_text(&k), "Symmetry+,Layers,Scene,Tools,Palettes,Lights,Material,Environment")
	text := kit_layout_text(&k)
	again: Kit_State
	kit_layout_put(&again, text)
	testing.expect(t, kit_layout_text(&again) == text, text)
	testing.expect_value(t, again.stack.hidden, bit_set[Stack_Card]{.Brush})
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
	testing.expect_value(t, stack_card_of(&a, .Material), Stack_Card.Material)
	testing.expect_value(t, stack_card_of(&a, .Environment), Stack_Card.Environment)
}

// Studio in Lens is the look's cards and Palettes, the render in the mini view; in Classic
// it keeps its pinned Lights, Material and Environment panels. Both read back as written.
@(test)
studio_differs_by_chrome :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	lens := built_in_layout(.Studio, .Lens)
	k: Kit_State
	kit_layout_put(&k, lens)
	testing.expect(t, kit_layout_text(&k) == lens, lens)
	testing.expect(t, k.inspector && k.thumbnail)
	testing.expect_value(t, k.stack.hidden, bit_set[Stack_Card]{.Brush, .Symmetry, .Layers, .Scene, .Tools})
	testing.expect_value(t, k.stack.open, bit_set[Stack_Card]{.Lights, .Material})
	testing.expect_value(t, k.second.pass, Second_Pass.Render)
	testing.expect(t, !strings.contains(lens, "pinned"), lens)

	classic := built_in_layout(.Studio, .Classic)
	testing.expect(t, strings.contains(classic, "pinned Lights"), classic)
	testing.expect(t, !strings.contains(classic, "thumbnail "), classic)
	c: Kit_State
	kit_layout_put(&c, classic)
	testing.expect(t, kit_layout_text(&c) == classic, classic)
	// The other built-ins are the same in both.
	for b in Built_In do if b != .Studio do testing.expect(t, built_in_layout(b, .Lens) == built_in_layout(b, .Classic))
}

// Changing the chrome swaps a built-in workspace that is as it comes with the app for the
// other chrome's, in place when it is current, and leaves one the user saved alone.
@(test)
changing_the_chrome_swaps_untouched_built_ins :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	a: App
	k := &a.kit
	bars_reset(k)
	panels_default(k)
	workspaces_init(k)
	defer workspaces_destroy(k)
	workspace_switch(k, int(Built_In.Studio))
	workspaces_frame(k)
	testing.expect(t, !k.workspaces.modified)
	k.chrome = .Classic
	workspaces_frame(k)
	testing.expect(t, k.workspaces.list[int(Built_In.Studio)].saved == built_in_layout(.Studio, .Classic))
	testing.expect(t, kit_layout_text(k) == built_in_layout(.Studio, .Classic))
	testing.expect(t, !k.workspaces.modified)

	// Saved with a change, it is the user's and stays as saved.
	k.stats = true
	workspace_save(k)
	mine := strings.clone(kit_layout_text(k), context.temp_allocator)
	k.chrome = .Lens
	workspaces_frame(k)
	testing.expect(t, k.workspaces.list[int(Built_In.Studio)].saved == mine)
	testing.expect(t, kit_layout_text(k) == mine)
}

// The Material card always shows the preset in use, in the last place when it is not one
// of the nine it shows; each of those is a lit preset, not a MatCap.
@(test)
material_card_shows_lit_presets :: proc(t: ^testing.T) {
	card := MATERIAL_CARD
	for i in card do testing.expect(t, i >= 0 && i < FIRST_MATCAP && MATERIALS[i].matcap == 0)
	for x, n in card do for y in card[n + 1:] do testing.expect(t, x != y)
	testing.expect_value(t, material_card_balls(0), MATERIAL_CARD)
	testing.expect_value(t, material_card_balls(13)[len(MATERIAL_CARD) - 1], 13)
	testing.expect_value(t, material_card_balls(FIRST_MATCAP + 1), MATERIAL_CARD)
	testing.expect_value(t, material_card_balls(-1), MATERIAL_CARD)
}
