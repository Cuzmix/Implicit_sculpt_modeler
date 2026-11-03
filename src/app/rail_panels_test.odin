package main

import "core:testing"

// The Panels picker puts a card or a section's card on the rail as Open card, takes either
// off again with a second tap, keeps to the rail's cap, and the
// rail's slot names come back from a saved settings file.
@(test)
panels_picker_puts_panels_on_the_rail :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	bars_reset(&app.kit)
	testing.expect(t, rail_panel_toggle(&app, .Tools))
	testing.expect(t, rail_panel_toggle(&app, .Camera))
	testing.expect_value(t, bar_names(&app, .View_Rail), "Inspector,Open_Card:Scene,Open_Card:Layers,Open_Card:Material,Open_Card:Symmetry,Open_Card:Lights,Open_Card:Tools,Open_Card:Camera")
	// A tap on the Material card's tile takes it off and a second puts it back at the foot.
	_, on := rail_panel_at(&app, .Material)
	testing.expect(t, on)
	testing.expect(t, !rail_panel_toggle(&app, .Material))
	testing.expect(t, rail_panel_toggle(&app, .Material))
	testing.expect(t, !rail_panel_toggle(&app, .Tools))
	testing.expect_value(t, bar_names(&app, .View_Rail), "Inspector,Open_Card:Scene,Open_Card:Layers,Open_Card:Symmetry,Open_Card:Lights,Open_Card:Camera,Open_Card:Material")
	id, arg, ok := command_from_name("Open_Card:Lights")
	testing.expect(t, ok && id == .Open_Card && Panel_Kind(arg) == .Lights)
	// The Objects card's old name is no command.
	id, arg, ok = command_from_name("Open_Card:Camera")
	testing.expect(t, ok && id == .Open_Card && Panel_Kind(arg) == .Camera)
	_, _, ok = command_from_name("Objects_Card")
	testing.expect(t, !ok)

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

// Open card opens its card in the stack, bringing back a card the stack left out, and
// says so through its checked state.
@(test)
show_panel_opens_the_card :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	bars_reset(&app.kit)
	stack_default(&app.kit)
	testing.expect(t, .Lights in app.kit.stack.hidden)
	command_run(&app, .Open_Card, int(Panel_Kind.Lights))
	testing.expect(t, .Lights not_in app.kit.stack.hidden)
	testing.expect(t, .Lights in app.kit.stack.open)
	testing.expect(t, app.kit.inspector)
}

// What opened the retired Objects card (a layout that kept it open, Arrange's Show) opens
// the Scene card with its pictures instead, drawing no window of its own.
@(test)
objects_card_opens_the_scene_card :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	bars_reset(&app.kit)
	stack_default(&app.kit)
	app.kit.objects_card = true
	testing.expect(t, !kit_objects_card(&app))
	testing.expect(t, !app.kit.objects_card && app.kit.scene_pictures && app.kit.inspector)
	testing.expect(t, .Scene in app.kit.stack.open && .Scene not_in app.kit.stack.hidden)
}
