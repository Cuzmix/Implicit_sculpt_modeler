package main

import "core:fmt"
import "core:strings"

import "../ui"

// What a panel holds: a card of its own (STACK_CARDS: Brush, Symmetry, Layers, Scene, Tools
// and the look's cards) or a section's card (one of the three palettes' sections: the
// brush's, the object's and the scene's). One enum names every card, so the stack, the
// groups, the bars, Search, keys and scripts all say "card" the same way, and one set of
// procs gives any of them its title, icon, folded line and content: a group draws whatever
// it holds without knowing which kind it is, and a visiting section and a kept one draw
// through panel_body alike, so the two never drift apart.

// Its title, as its header shows it.
panel_kind_title :: proc(app: ^App, kind: Panel_Kind) -> string {
	if panel_is_section(kind) do return tray_section_title(kind)
	return stack_title(app, kind)
}

// Its icon, as its header and its button on a bar show it.
panel_kind_icon :: proc(app: ^App, kind: Panel_Kind) -> rune {
	if panel_is_section(kind) do return SECTION_ICONS[kind]
	if kind == .Brush do return stack_brush_icon(app)
	return STACK_CARD_ICONS[kind]
}

// What it holds, in a few words, for its folded header.
panel_kind_summary :: proc(app: ^App, kind: Panel_Kind) -> string {
	if panel_is_section(kind) do return section_summary(app, kind)
	return stack_summary(app, kind)
}

// Its content, `inner` points wide: a card's body, or a section's controls (asking for an
// object first when the section is an object's and none is selected). Every panel is part
// of the tray, so search's Show where can mark a control on any of them (the Layers card's
// New layer, say).
panel_body :: proc(app: ^App, kind: Panel_Kind, inner: f32) {
	k := &app.kit
	k.in_tray = true
	defer k.in_tray = false
	hints := hints_push(app)
	defer k.ctx.hints = hints
	if !panel_is_section(kind) {
		stack_card_body(app, kind, inner)
		return
	}
	sec := kind
	for s in OBJECT_SECTIONS do if s.section == sec do k.object_page = s.page
	ctx := &app.kit.ctx
	_, draw, obj_draw, found := bar_section(app, sec)
	obj := selected_object(app)
	switch {
	case !found:
		ui.paragraph(ctx, "Nothing to show here.")
	case obj_draw != nil && obj == nil:
		ui.paragraph(ctx, "Add or select an object first.")
	case obj_draw != nil:
		obj_draw(app, obj)
	case:
		draw(app)
	}
}

// Its name in a group's line: `card:Brush` or `section:Stroke` (the full sections by their
// section's name, `section:Layers`).
panel_kind_name :: proc(kind: Panel_Kind) -> string {
	if panel_is_section(kind) do return fmt.tprintf("section:%v", kind)
	return fmt.tprintf("card:%v", kind)
}

// The kind a group's line names; false for a name this version does not know, or a
// section no palette shows.
panel_kind_from_name :: proc(name: string) -> (Panel_Kind, bool) {
	what, _, which := strings.partition(name, ":")
	switch what {
	case "card":
		for c in STACK_CARDS do if which == fmt.tprint(c) do return c, true
	case "section":
		for p in STACK_SECTION_PANELS do if which == fmt.tprint(p) do return p, true
	}
	return .Brush, false
}

// Its word in the stack's and the sizes' lines: a card bare, as every build has written it
// (`Brush`), a section's palette as in a group's line (`section:Mask`), so a build that
// knows no sections passes over it.
panel_word :: proc(kind: Panel_Kind) -> string {
	if panel_is_section(kind) do return panel_kind_name(kind)
	return fmt.tprint(kind)
}

// The kind a stack or sizes line's word names, any case; false for one this version does
// not know.
panel_from_word :: proc(word: string) -> (Panel_Kind, bool) {
	if strings.has_prefix(word, "section:") do return panel_kind_from_name(word)
	for c in STACK_CARDS do if strings.equal_fold(word, fmt.tprint(c)) do return c, true
	return .Brush, false
}
