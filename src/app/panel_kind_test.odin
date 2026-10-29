package main

import "core:testing"

// Every card and every section a panel shows has a name that reads back as itself and a
// title; a name this version does not know, or a section no panel shows, reads as nothing.
@(test)
panel_kinds_read_back :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	for c in Stack_Card {
		kind, ok := panel_kind_from_name(panel_kind_name(c))
		testing.expect(t, ok && kind == Panel_Kind(c), panel_kind_name(c))
		testing.expect(t, panel_kind_title(&app, c) != "")
	}
	for s in Kit_Section do if panel_pinnable(s) {
		kind, ok := panel_kind_from_name(panel_kind_name(s))
		testing.expect(t, ok && kind == Panel_Kind(s), panel_kind_name(s))
		testing.expect(t, panel_kind_title(&app, s) != "")
	}
	for s in Kit_Section do if !panel_pinnable(s) {
		_, ok := panel_kind_from_name(panel_kind_name(s))
		testing.expect(t, !ok, panel_kind_name(s))
	}
	for name in ([]string{"card:Nope", "section:", "window:Stats", "", "Brush"}) {
		_, ok := panel_kind_from_name(name)
		testing.expect(t, !ok, name)
	}
	free_all(context.temp_allocator)
}
