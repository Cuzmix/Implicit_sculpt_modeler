package main

import "core:strings"
import "core:testing"

// The stack's order and open cards go in a workspace's layout only once they differ from
// a fresh layout's, and read back as they were written.
@(test)
stack_layout_reads_back_as_written :: proc(t: ^testing.T) {
	k := new(Kit_State)
	defer free(k)
	stack_default(k)
	b := strings.builder_make(context.temp_allocator)
	stack_layout_save(k, &b)
	testing.expect_value(t, strings.to_string(b), "")
	stack_move_to_k(k, .Scene, 0)
	k.stack.open = {.Scene, .Layers}
	strings.builder_reset(&b)
	stack_layout_save(k, &b)
	line := strings.to_string(b)
	testing.expect_value(t, line, "stack Scene+ Brush Symmetry Layers+ Tools Palettes -Lights -Material -Environment\n")

	c := new(Kit_State)
	defer free(c)
	stack_default(c)
	stack_layout_read(c, strings.fields(strings.trim_space(line), context.temp_allocator))
	testing.expect(t, c.stack.order == k.stack.order && c.stack.open == k.stack.open)
	// Cards a line leaves out keep their places after those it names.
	stack_layout_read(c, {"stack", "Palettes+", "nothing"})
	testing.expect_value(t, stack_text(c), "Palettes+,Scene,Brush,Symmetry,Layers,Tools")
	// A line from before the Tools card puts it after Scene.
	stack_layout_read(c, {"stack", "Scene+", "Brush", "Symmetry", "Layers+", "Palettes"})
	testing.expect_value(t, stack_text(c), "Scene+,Tools,Brush,Symmetry,Layers+,Palettes")
}

// Moving a card among the docked ones leaves a floating card where it was in the order.
@(test)
stack_move_keeps_floating_cards_in_place :: proc(t: ^testing.T) {
	k := new(Kit_State)
	defer free(k)
	stack_default(k)
	k.stack.floated = {.Symmetry}
	stack_move_to_k(k, .Brush, 2)
	testing.expect_value(t, stack_text(k), "Layers,Symmetry^,Scene,Brush+,Tools,Palettes")
}

// A section opens the card that holds it: the brush's on Brush (unfolding its group), Layers
// and Objects on their own, the rest on Palettes; the tall cards fold for another.
@(test)
stack_reveal_opens_the_card_of_a_section :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	stack_default(&app.kit)
	app.tool = .Brush
	stack_reveal(app, .Pen)
	testing.expect(t, .Brush in app.kit.stack.open && .Pen not_in app.kit.stack.shut)
	stack_reveal(app, .Objects)
	testing.expect_value(t, app.kit.stack.open, bit_set[Panel_Kind]{.Scene})
	stack_reveal(app, .Remesh)
	testing.expect_value(t, app.kit.stack.open, bit_set[Panel_Kind]{.Scene, .Remesh})
	testing.expect_value(t, stack_card_of(app, .Layers), Panel_Kind.Layers)
	testing.expect_value(t, stack_card_of(app, .Layers, exact = true), Panel_Kind.Layer_Settings)
	testing.expect_value(t, stack_card_of(app, .Objects, exact = true), Panel_Kind.Objects)
	testing.expect_value(t, stack_card_of(app, .Environment, exact = true), Panel_Kind.Environment)
	testing.expect_value(t, stack_card_of(app, .Stroke, exact = true), Panel_Kind.Brush)
	app.tool = .Move
	testing.expect_value(t, stack_card_of(app, .Stroke), Panel_Kind.Stroke)
}

// A section opened comes in as the visit at the docked stack's foot, before Palettes, and
// is no part of the layout; the next one opened takes its place.
@(test)
a_visit_gives_way_to_the_next :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	app := new(App)
	defer free(app)
	k := &app.kit
	stack_default(k)
	fresh := kit_layout_text(k)
	stack_reveal(app, .Paint)
	testing.expect_value(t, stack_visit_text(k), "Paint")
	testing.expect_value(t, stack_text(k), "Brush,Symmetry,Layers,Scene,Tools,Paint+,Palettes")
	stack_reveal(app, .Mask)
	testing.expect_value(t, stack_text(k), "Brush,Symmetry,Layers,Scene,Tools,Mask+,Palettes")
	testing.expect(t, .Paint in k.stack.hidden)
	testing.expect_value(t, k.stack.visits, 2)
	// Only the Brush card's fold is the layout's; the visit is not.
	k.stack.open += {.Brush}
	testing.expect_value(t, kit_layout_text(k), fresh)
	// Opening it again, or a card, keeps it as it is.
	stack_reveal(app, .Mask)
	stack_reveal(app, .Layers)
	testing.expect_value(t, stack_visit_text(k), "Mask")
	testing.expect_value(t, k.stack.moves, 0)
}

// A pinned visit stays when the next section is opened, and is part of the layout; so is
// one carried into a group, even once it is taken out again.
@(test)
a_kept_visit_stays :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	app := new(App)
	defer free(app)
	k := &app.kit
	stack_default(k)
	stack_reveal(app, .Paint)
	stack_keep(k, .Paint, true)
	stack_reveal(app, .Mask)
	testing.expect_value(t, stack_text(k), "Brush,Symmetry,Layers,Scene,Tools,Paint+,Mask+,Palettes")
	testing.expect(t, .Paint not_in k.stack.hidden && .Mask not_in k.stack.hidden)
	testing.expect(t, strings.contains(kit_layout_text(k), "section:Paint+"), kit_layout_text(k))
	testing.expect(t, !strings.contains(kit_layout_text(k), "section:Mask"), kit_layout_text(k))
	// Carried into a group, the visit is kept.
	testing.expect(t, stack_join(k, .Mask))
	stack_visit_settle(&k.stack)
	testing.expect_value(t, stack_visit_text(k), "none")
	testing.expect(t, stack_take_out(k, .Mask))
	stack_reveal(app, .Sets)
	testing.expect(t, .Mask not_in k.stack.hidden, "a visit once kept stays kept")
	testing.expect(t, stack_valid(&k.stack))
	// Unpinning leaves it out again.
	stack_keep(k, .Paint, false)
	testing.expect(t, .Paint in k.stack.hidden)
	testing.expect(t, stack_valid(&k.stack))
}

// Windows, pinned panels and floated cards share one floating order: a card floated comes
// in front of the windows, a window raised goes in front of it, and nothing is in the
// order twice.
@(test)
floating_cards_and_panels_share_one_order :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	k := &app.kit
	panels_default(k)
	stack_default(k)
	n := len(k.order)
	stack_float(app, .Layers)
	testing.expect_value(t, k.order[len(k.order) - 1], Float_Ref(Panel_Kind.Layers))
	window_raise(k, Kit_Window.Stats)
	testing.expect_value(t, k.order[len(k.order) - 1], Float_Ref(Kit_Window.Stats))
	float_raise(k, Panel_Kind.Layers)
	float_raise(k, Panel_Kind.Layers)
	testing.expect_value(t, k.order[len(k.order) - 1], Float_Ref(Panel_Kind.Layers))
	testing.expect_value(t, len(k.order), n + 1)
	float_raise(k, nil)
	testing.expect_value(t, len(k.order), n + 1)
}
