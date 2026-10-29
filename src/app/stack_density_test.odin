package main

import "core:strings"
import "core:testing"

import "../ui"

// The palettes' density is the layout's: Icons writes a line that reads back, Panels
// writes none, and a word this version does not know leaves Panels.
@(test)
stack_density_reads_back :: proc(t: ^testing.T) {
	a: Kit_State
	stack_default(&a)
	testing.expect(t, !strings.contains(kit_layout_text(&a), "stack_density"))
	a.stack.density = .Icons
	text := kit_layout_text(&a)
	testing.expect(t, strings.contains(text, "stack_density icons\n"), text)
	b: Kit_State
	kit_layout_put(&b, text)
	testing.expect_value(t, b.stack.density, Stack_Density.Icons)
	kit_layout_put(&b, "stack_density tiles\n")
	testing.expect_value(t, b.stack.density, Stack_Density.Panels)
	free_all(context.temp_allocator)
}

// Shown as icons, opening a palette's section (Search's Show where, a bar's Show section)
// opens its card from its icon, as a tap on the icon would.
@(test)
stack_icons_open_the_card_asked_for :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	k := &app.kit
	panels_default(k)
	stack_default(k)
	stack_density_set(&app, .Icons)
	testing.expect(t, stack_strip_shown(&app))
	k.stack.strip_at[.Layers] = {1300, 200, 44, 44}
	tray_open(&app, .Layers)
	testing.expect(t, k.stack.tab_open)
	testing.expect_value(t, k.stack.tab, Stack_Card.Layers)
	testing.expect_value(t, k.stack.tab_at, ui.Rect{1300, 200, 44, 44})
	stack_density_set(&app, .Panels)
	testing.expect(t, !k.stack.tab_open)
	free_all(context.temp_allocator)
}
