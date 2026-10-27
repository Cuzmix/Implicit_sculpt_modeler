package main

import "core:testing"

// Without the gradient both edges are the top colour, which the renderer paints flat;
// with it each edge has its own, fully opaque.
@(test)
the_background_is_flat_or_a_gradient :: proc(t: ^testing.T) {
	b := Background_Settings{top = {0.1, 0.2, 0.3}, bottom = {0.4, 0.5, 0.6}}
	flat := background_frame(b)
	testing.expect_value(t, flat.top, [4]f32{0.1, 0.2, 0.3, 1})
	testing.expect_value(t, flat.bottom, flat.top)
	b.gradient = true
	g := background_frame(b)
	testing.expect_value(t, g.top, [4]f32{0.1, 0.2, 0.3, 1})
	testing.expect_value(t, g.bottom, [4]f32{0.4, 0.5, 0.6, 1})
}

// The background's colours are settings lines, so a script sets them and the settings
// file keeps them; a channel past 0 to 1 is refused.
@(test)
background_colours_are_settings :: proc(t: ^testing.T) {
	app: App
	app.background = BACKGROUND_DEFAULT
	for key in ([2]string{"background_top", "background_bottom"}) {
		line := setting_line(key)
		testing.expectf(t, line.parse != nil, "%s is a settings line", key)
		if line.parse == nil do continue
		v, ok := line.parse({"0.5", "0.25", "1"})
		testing.expect(t, ok)
		line.apply(&app, v)
		testing.expect_value(t, line.text(&app), "0.5 0.25 1")
		_, ok = line.parse({"0.5", "1.5", "0"})
		testing.expect(t, !ok)
		_, ok = line.parse({"0.5", "0.5"})
		testing.expect(t, !ok)
	}
	testing.expect_value(t, app.background.top, [3]f32{0.5, 0.25, 1})
	testing.expect_value(t, app.background.bottom, [3]f32{0.5, 0.25, 1})
	row, found := script_setting("background_gradient")
	testing.expect(t, found && row.type == bool)
}
