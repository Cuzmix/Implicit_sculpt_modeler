package main

import "core:testing"
import sdl "vendor:sdl3"

@(test)
tab_is_clean_view_in_lens_and_palettes_in_classic :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	tab := Chord{key = sdl.K_TAB}
	owner :: proc(app: ^App, c: Chord) -> Command_Id {
		b, _ := chord_owner(app, c)
		return b.command
	}
	testing.expect_value(t, owner(app, tab), Command_Id.Inspector)
	app.kit.chrome = .Lens
	keymap_rebuild(app)
	testing.expect_value(t, owner(app, tab), Command_Id.Clean_View)
	testing.expect_value(t, command_keys(app, .Inspector), "")
	app.kit.chrome = .Classic
	keymap_rebuild(app)
	testing.expect_value(t, owner(app, tab), Command_Id.Inspector)
}
