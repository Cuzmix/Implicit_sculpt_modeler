package main

import "core:testing"

// Tab is Clean view, as the mockups have it, Palettes keeping its button; B opens the
// brush picker.
@(test)
tab_is_clean_view_and_b_the_brush_picker :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	owner :: proc(app: ^App, c: Chord) -> Command_Id {
		b, _ := chord_owner(app, c)
		return b.command
	}
	testing.expect_value(t, owner(app, Chord{key = KEY_TAB}), Command_Id.Clean_View)
	testing.expect_value(t, owner(app, Chord{key = KEY_B}), Command_Id.Brush_Picker)
	keymap_rebuild(app)
	testing.expect_value(t, owner(app, Chord{key = KEY_TAB}), Command_Id.Clean_View)
}

// A window the system resizes as it opens (a screen smaller than the size asked for) is
// placed once its controls were laid out for the new size: the frame the resize arrives
// on reads the last frame's rects, laid out for the old one, so the view waits a frame
// rather than land where the resize happened to fall.
@(test)
the_view_is_placed_after_a_resize_settles :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	k := &app.kit
	k.grid.tree = grid_preset_tree(.Single)
	step :: proc(app: ^App, frame: int, window: [2]f32) {
		app.kit.frame = frame
		app.kit.ctx.input.window = window
		lens_view_frame(app)
	}
	step(app, 1, {1600, 900})
	step(app, 2, {1600, 900})
	step(app, 3, {1536, 795})
	testing.expect(t, !k.view_started, "the view was placed on the frame the window changed size")
	step(app, 4, {1536, 795})
	testing.expect(t, k.view_started, "the view was not placed once the size held")
}
