package main

import "core:strings"
import "core:testing"

// Joining makes a card a tab of the docked card above it, shown; the first card has none
// above it; taking a tab out puts it after its group as a card of its own, and taking the
// host out leaves the next tab in its place.
@(test)
stack_join_and_take_out :: proc(t: ^testing.T) {
	k := new(Kit_State)
	defer free(k)
	stack_default(k)
	s := &k.stack
	testing.expect(t, !stack_join(k, .Brush))
	testing.expect(t, stack_join(k, .Symmetry))
	testing.expect_value(t, stack_text(k), "Brush+,&Symmetry,Layers,Scene,Tools,Palettes")
	testing.expect_value(t, stack_host(s, .Symmetry), Panel_Kind.Brush)
	testing.expect_value(t, stack_shown(s, .Brush), Panel_Kind.Symmetry)
	// Layers joins the group above it, past the tab, so the group has three tabs.
	testing.expect(t, stack_join(k, .Layers))
	testing.expect_value(t, len(stack_group(s, .Brush)), 3)
	testing.expect(t, stack_take_out(k, .Symmetry))
	testing.expect_value(t, stack_text(k), "Brush+,&Layers,Symmetry+,Scene,Tools,Palettes")
	testing.expect_value(t, stack_shown(s, .Brush), Panel_Kind.Layers)
	// The host out: Layers is the group's card now, with its fold.
	testing.expect(t, stack_join(k, .Symmetry))
	testing.expect(t, stack_take_out(k, .Brush))
	testing.expect_value(t, stack_text(k), "Layers+,&Symmetry,Brush+,Scene,Tools,Palettes")
	testing.expect(t, !stack_take_out(k, .Scene))
	free_all(context.temp_allocator)
}

// A group moves, floats and is left out as one card; a tab never floats on its own, and
// the cards a fresh layout leaves out stay out of a move.
@(test)
stack_groups_move_and_float_as_one :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	k := &app.kit
	stack_default(k)
	s := &k.stack
	stack_join(k, .Symmetry)
	stack_move_to_k(k, .Brush, 2)
	testing.expect_value(t, stack_text(k), "Layers,Scene,Brush+,&Symmetry,Tools,Palettes")
	stack_move_to_k(k, .Symmetry, 0)
	testing.expect_value(t, stack_text(k), "Brush+,&Symmetry,Layers,Scene,Tools,Palettes")
	stack_float(app, .Symmetry)
	testing.expect_value(t, s.floated, bit_set[Panel_Kind]{.Brush})
	testing.expect(t, s.floated & s.joined == {})
	// A floating group cannot join, nor be joined to.
	_, ok := stack_join_target(s, .Layers)
	testing.expect(t, !ok)
	testing.expect(t, !stack_join(k, .Brush))
	free_all(context.temp_allocator)
}

// The groups are lines of a workspace's layout that read back, the shown tab marked; a
// fresh layout writes none, and names this version does not know are passed over.
@(test)
stack_groups_read_back :: proc(t: ^testing.T) {
	a: Kit_State
	stack_default(&a)
	testing.expect(t, !strings.contains(kit_layout_text(&a), "stack_group"))
	stack_join(&a, .Symmetry)
	stack_join(&a, .Layers)
	stack_show_tab(&a.stack, .Symmetry)
	text := kit_layout_text(&a)
	testing.expect(t, strings.contains(text, "stack_group card:Brush *card:Symmetry card:Layers\n"), text)
	b: Kit_State
	kit_layout_put(&b, text)
	testing.expect_value(t, stack_text(&b), stack_text(&a))
	testing.expect_value(t, stack_shown(&b.stack, .Brush), Panel_Kind.Symmetry)
	// The group line may come first: it is read once the stack's order is in place. A
	// section's palette is a tab like a card, and comes into the stack with its group.
	kit_layout_put(&b, "stack_group card:Tools card:Unknown section:Stroke card:Brush\nstack Brush+ Symmetry Layers Scene Tools Palettes\n")
	testing.expect_value(t, stack_text(&b), "Symmetry,Layers,Scene,Tools,&Stroke,&Brush,Palettes")
	// A tab is left out with its group.
	kit_layout_put(&b, "stack Brush+ Symmetry -Layers Scene Tools Palettes\nstack_group card:Layers card:Scene\n")
	testing.expect_value(t, stack_text(&b), "Brush+,Symmetry,Tools,Palettes")
	free_all(context.temp_allocator)
}

// Opening a section of a tab (Search's Show where) opens its group on that tab, putting a
// group left out back in the stack.
@(test)
stack_reveal_opens_a_group_on_its_tab :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	k := &app.kit
	panels_default(k)
	stack_default(k)
	stack_join(k, .Layers)
	stack_show_tab(&k.stack, .Symmetry)
	k.stack.open = {}
	for x in stack_group(&k.stack, .Symmetry) do k.stack.hidden += {x}
	tray_open(&app, .Layers)
	testing.expect(t, .Symmetry in k.stack.open)
	testing.expect(t, k.stack.hidden & {.Symmetry, .Layers} == {})
	testing.expect_value(t, stack_shown(&k.stack, .Symmetry), Panel_Kind.Layers)
	free_all(context.temp_allocator)
}
