package main

import "core:testing"
import sdl "vendor:sdl3"

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
	testing.expect_value(t, owner(app, Chord{key = sdl.K_TAB}), Command_Id.Clean_View)
	testing.expect_value(t, owner(app, Chord{key = sdl.K_B}), Command_Id.Brush_Picker)
	testing.expect_value(t, command_keys(app, .Inspector), "")
	keymap_rebuild(app)
	testing.expect_value(t, owner(app, Chord{key = sdl.K_TAB}), Command_Id.Clean_View)
}
