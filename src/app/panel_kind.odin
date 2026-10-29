package main

import "core:fmt"
import "core:reflect"
import "core:strings"

import "../ui"

// What a panel holds (round 3, PR 4): a card of the stack (lens_stack.odin) or a section
// of the tray, as a pinned panel shows it (panels.odin). The panel groups to come hold
// these, so one set of procs gives any of them its title, icon, folded line and content,
// and a group draws whatever it holds without knowing which kind it is. The stack and the
// pinned panels draw their content through panel_body too, so the two never drift apart.
Panel_Kind :: union {
	Stack_Card,
	Kit_Section,
}

// Its title, as its header shows it.
panel_kind_title :: proc(app: ^App, kind: Panel_Kind) -> string {
	switch v in kind {
	case Stack_Card:  return stack_title(app, v)
	case Kit_Section: return tray_section_title(v)
	}
	return ""
}

// Its icon: the card's, or the one Show section has on a bar.
panel_kind_icon :: proc(app: ^App, kind: Panel_Kind) -> rune {
	switch v in kind {
	case Stack_Card:
		if v == .Brush do return stack_brush_icon(app)
		return STACK_CARD_ICONS[v]
	case Kit_Section:
		return bar_icon({.Show_Section, int(v)})
	}
	return ui.ICON_PANEL
}

// What it holds, in a few words, for its folded header.
panel_kind_summary :: proc(app: ^App, kind: Panel_Kind) -> string {
	switch v in kind {
	case Stack_Card:  return stack_summary(app, v)
	case Kit_Section: return panel_summary(app, v)
	}
	return ""
}

// Its content, `inner` points wide: a card's body, or a section's controls (asking for an
// object first when the section is an object's and none is selected).
panel_body :: proc(app: ^App, kind: Panel_Kind, inner: f32) {
	switch v in kind {
	case Stack_Card:
		stack_card_body(app, v, inner)
	case Kit_Section:
		ctx := &app.kit.ctx
		_, draw, obj_draw, found := bar_section(app, v)
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
}

// Its name in a layout line: `card:Brush` or `section:Stroke`.
panel_kind_name :: proc(kind: Panel_Kind) -> string {
	switch v in kind {
	case Stack_Card:  return fmt.tprintf("card:%v", v)
	case Kit_Section: return fmt.tprintf("section:%v", v)
	}
	return ""
}

// The kind a layout line names; false for a name this version does not know, or a section
// no panel shows.
panel_kind_from_name :: proc(name: string) -> (Panel_Kind, bool) {
	what, _, which := strings.partition(name, ":")
	switch what {
	case "card":
		if c, ok := reflect.enum_from_name(Stack_Card, which); ok do return c, true
	case "section":
		if s, ok := reflect.enum_from_name(Kit_Section, which); ok && panel_pinnable(s) do return s, true
	}
	return nil, false
}
