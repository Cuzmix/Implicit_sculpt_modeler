package main

import "core:strings"
import "core:testing"

// Every section has one home: a card, a title, and a draw proc where a palette table lists
// it; every card holds at least one section.
@(test)
every_section_has_one_card :: proc(t: ^testing.T) {
	held: [Card]int
	for sec in Section {
		held[section_card(sec)] += 1
		testing.expectf(t, section_title(sec) != "", "%v has no title", sec)
		if sec == .Brush || sec == .Symmetry || section_card(sec) in OWN_BODY_CARDS do continue
		_, draw, obj_draw, found := bar_section(nil, sec)
		testing.expectf(t, found && (draw != nil || obj_draw != nil), "%v has nothing that draws it", sec)
	}
	for n, c in held do testing.expectf(t, n >= 1, "%v holds no section", c)
	testing.expect_value(t, card_sections_count(.Mesh), 10)
	for c in Card {
		got, ok := card_from_word(card_word(c))
		testing.expect(t, ok && got == c)
	}
}

// A dock button opens its card beside it; another tap closes it; a press on the view
// closes it and goes no further.
@(test)
a_card_opens_beside_its_button_and_a_press_on_the_view_closes_it :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	a: App
	k := &a.kit
	cards_default(k)
	at := [2]f32{1500, 200}
	card_toggle(&a, .Mesh, {at.x, at.y, 44, 44}, .Left)
	testing.expect(t, card_shown(&a, .Mesh))
	testing.expect_value(t, columns_text(k), "left:;right:Mesh")
	card_toggle(&a, .Mesh, {at.x, at.y, 44, 44}, .Left)
	testing.expect(t, !card_shown(&a, .Mesh), "a second tap left it open")
	card_toggle(&a, .Mesh, {at.x, at.y, 44, 44}, .Left)
	k.ctx.input.pressed = {.Left}
	k.ctx.input.mouse_valid = true
	columns_update(&a)
	testing.expect(t, !card_shown(&a, .Mesh) && k.ctx.swallow, "the press on the view sculpted or left the card")
}

// With a mouse a column splits: the pinned card stays above the one opened under it. On a
// tablet one card shows, and the pinned one comes back when the other closes.
@(test)
a_pinned_card_rests_in_its_column :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	a: App
	k := &a.kit
	cards_default(k)
	a.device.pointer = .Mouse
	card_open(&a, .Tool)
	card_pin(&a, .Tool)
	card_open(&a, .Mask)
	testing.expect_value(t, columns_text(k), "left:;right:Tool*,Mask")
	testing.expect(t, card_shown(&a, .Tool) && card_shown(&a, .Mask), "a mouse's column did not split")
	a.device.pointer = .Pen
	testing.expect(t, !card_shown(&a, .Tool) && card_shown(&a, .Mask), "a tablet shows two cards in the pen's column")
	card_close(&a, .Mask)
	testing.expect(t, card_shown(&a, .Tool), "the pinned card did not come back")
	// Pinning on a tablet lets the column's other cards go.
	card_open(&a, .Mask)
	card_pin(&a, .Mask)
	testing.expect_value(t, columns_text(k), "left:;right:Mask*")
}

// A layout keeps the pinned cards as `column` lines, and reads them back; Render pins the
// Look card.
@(test)
pinned_cards_are_the_layouts :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	fresh: Kit_State
	kit_layout_put(&fresh, "")
	testing.expect(t, !strings.contains(kit_layout_text(&fresh), "column"), "a fresh layout pins a card")
	k: Kit_State
	kit_layout_put(&k, "column right Mesh\ncolumn left Symmetry\ncolumn left Nonesuch\n")
	testing.expect_value(t, columns_text(&k), "left:Symmetry*;right:Mesh*")
	text := kit_layout_text(&k)
	again: Kit_State
	kit_layout_put(&again, text)
	testing.expect_value(t, kit_layout_text(&again), text)
	render: Kit_State
	kit_layout_put(&render, built_in_layout(.Render))
	testing.expect(t, card_pinned(&render, .Look))
}

// Show where opens the section's card, unfolds the section and marks it for the scroll; a
// brush section switches to the brush.
@(test)
show_where_opens_the_card_on_its_section :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	a: App
	k := &a.kit
	cards_default(k)
	testing.expect(t, .Remesh in k.cards.shut)
	testing.expect(t, card_show(&a, .Rebuild))
	testing.expect(t, card_shown(&a, .Mesh) && .Remesh not_in k.cards.shut && k.more[.Remesh])
	testing.expect_value(t, k.cards.reveal.? or_else .Brush, Section.Remesh)
	testing.expect(t, section_on_screen(&a, .Remesh))
	testing.expect(t, !card_show(&a, .Undo), "Undo has a home on a card")
	for sec, id in COMMAND_HOMES {
		if s, ok := sec.?; ok do testing.expectf(t, section_title(s) != "", "%v's home has no title", id)
	}
}

// A card floats out of its column and keeps its place in a layout; put back, it rests
// pinned in the column; a dock button's tap on a floating card closes it.
@(test)
a_floating_card_keeps_its_place_and_comes_back_pinned :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	a: App
	k := &a.kit
	cards_default(k)
	card_open(&a, .Mask)
	card_float_at(k, .Mask, {300, 200})
	testing.expect_value(t, columns_text(k), "left:;right:")
	testing.expect_value(t, cards_float_text(k), "Mask")
	testing.expect(t, card_shown(&a, .Mask), "a floating card does not show")
	text := kit_layout_text(k)
	testing.expect(t, strings.contains(text, "card_float Mask Start Start 300 200 0\n"), "the layout lost the floating card")
	again: Kit_State
	kit_layout_put(&again, text)
	testing.expect_value(t, cards_float_text(&again), "Mask")
	testing.expect_value(t, again.cards.windows[.Mask].offset, [2]f32{300, 200})
	card_float_return(&a, .Mask, .Right)
	testing.expect_value(t, columns_text(k), "left:;right:Mask*")
	testing.expect_value(t, cards_float_text(k), "none")
	card_float_at(k, .Mask, {10, 10})
	card_toggle(&a, .Mask, {1500, 200, 44, 44}, .Left)
	testing.expect(t, !card_shown(&a, .Mask), "a dock button's tap left the floating card open")
}
