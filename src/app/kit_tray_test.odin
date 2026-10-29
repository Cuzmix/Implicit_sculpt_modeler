package main

import "core:testing"

import "../ui"

// Show where finds every command COMMAND_HOMES places: on its palette and section, with
// every argument the palette lists, the tray's content lays out a control for it.
@(test)
show_where_finds_every_home :: proc(t: ^testing.T) {
	app: App
	_ = section_scene(&app)
	defer section_scene_free(&app)
	// One light, so the Lights section shows a light's controls (Place highlight).
	app.scene.lights.count, app.scene.lights.lights[0].on = 1, true
	ctx := &app.kit.ctx
	for home, id in COMMAND_HOMES {
		sec, ok := home.?
		if !ok do continue
		for arg in 0 ..< max(COMMANDS[id].args, 1) {
			testing.expect(t, tray_show(&app, id, arg))
			testing.expectf(t, app.kit.tab == section_palette(sec) && tray_section(&app, app.kit.tab) == sec, "%v:%d opened %v", id, arg, app.kit.tab)
			ui.frame_begin(ctx, {window = {1600, 900}, pixel_density = 1, dt = 1.0 / 60})
			ui.begin_anchored(ctx, "tray", .End, .Start, {0, 0}, {direction = .Column, width = KIT_INSPECTOR_W})
			app.kit.in_tray = true
			switch app.kit.tab {
			case .Tool:   kit_tool_tab(&app)
			case .Object: kit_object_tab(&app)
			case .Scene:  kit_scene_tab(&app)
			}
			app.kit.in_tray = false
			found := ctx.marked.found
			ui.end(ctx)
			ui.frame_end(ctx)
			free_all(context.temp_allocator)
			testing.expectf(t, found, "%v:%d has no control in %v", id, arg, sec)
		}
	}
}

// Every section is on the palette its range says, and each palette lists each of its
// sections once.
@(test)
tray_sections_match_their_palettes :: proc(t: ^testing.T) {
	app: App
	kit_init(&app)
	defer ui.destroy(&app.kit.ctx)
	for tab in Kit_Tab {
		seen: [Kit_Section]int
		for s in tray_sections(&app, tab) {
			seen[s.section] += 1
			testing.expectf(t, section_palette(s.section) == tab, "%v listed on %v", s.section, tab)
			testing.expect(t, tray_section_title(s.section) == s.title)
		}
		for n, sec in seen do testing.expectf(t, n <= 1, "%v listed %d times", sec, n)
	}
}
