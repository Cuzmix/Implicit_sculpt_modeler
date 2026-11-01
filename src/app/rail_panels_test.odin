package main

import "core:testing"

// The cards come first in Panel_Kind, as Show panel's argument assumes.
@(test)
show_panel_takes_the_cards :: proc(t: ^testing.T) {
	testing.expect_value(t, card(STACK_CARDS), STACK_CARD_COUNT)
	for c in Panel_Kind do testing.expectf(t, (int(c) < STACK_CARD_COUNT) == (c in STACK_CARDS), "%v", c)
}

// The Panels picker puts a card on the rail as Show panel and a section's palette as Show
// section, takes either off again with a second tap, keeps to the rail's cap, and the
// rail's slot names come back from a saved settings file.
@(test)
panels_picker_puts_panels_on_the_rail :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	bars_reset(&app.kit)
	testing.expect(t, rail_panel_toggle(&app, .Symmetry))
	testing.expect(t, rail_panel_toggle(&app, .Camera))
	testing.expect_value(t, bar_names(&app, .View_Rail), "Objects_Card,Show_Section:Layers,Show_Section:Material,Show_Panel:Symmetry,Show_Section:Camera")
	// The rail's Material is the section's palette, which counts as the Material card; a tap
	// on the card's tile takes it off.
	_, on := rail_panel_at(&app, .Material)
	testing.expect(t, on)
	testing.expect(t, !rail_panel_toggle(&app, .Material))
	testing.expect(t, rail_panel_toggle(&app, .Material))
	testing.expect(t, !rail_panel_toggle(&app, .Symmetry))
	testing.expect_value(t, bar_names(&app, .View_Rail), "Objects_Card,Show_Section:Layers,Show_Section:Camera,Show_Panel:Material")
	id, arg, ok := command_from_name("Show_Panel:Lights")
	testing.expect(t, ok && id == .Show_Panel && Panel_Kind(arg) == .Lights)

	// Full, it refuses another and leaves the rail as it was.
	for c in Panel_Kind {
		if bar_count(&app, .View_Rail)^ >= bar_capacity(.View_Rail) do break
		if _, there := rail_panel_at(&app, c); !there do rail_panel_toggle(&app, c)
	}
	testing.expect_value(t, bar_count(&app, .View_Rail)^, bar_capacity(.View_Rail))
	before := bar_names(&app, .View_Rail)
	for c in Panel_Kind do if _, there := rail_panel_at(&app, c); !there {
		testing.expect(t, !rail_panel_toggle(&app, c))
		break
	}
	testing.expect_value(t, bar_names(&app, .View_Rail), before)
}

// Show panel opens its card in the stack, bringing back a card the stack left out, and
// says so through its checked state.
@(test)
show_panel_opens_the_card :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	bars_reset(&app.kit)
	stack_default(&app.kit)
	testing.expect(t, .Lights in app.kit.stack.hidden)
	command_run(&app, .Show_Panel, int(Panel_Kind.Lights))
	testing.expect(t, .Lights not_in app.kit.stack.hidden)
	testing.expect(t, .Lights in app.kit.stack.open)
	testing.expect(t, app.kit.inspector)
}
