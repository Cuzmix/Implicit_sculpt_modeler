package main

import "core:testing"
import sdl "vendor:sdl3"

import "../ui"

// Each scheme's buttons do what Settings > Keys and Help say; the left button alone is
// left to the tool, the fingers and empty space.
@(test)
mouse_schemes_turn_pan_and_zoom :: proc(t: ^testing.T) {
	Case :: struct {
		held:              ui.Buttons,
		ctrl, shift, alt:  bool,
		zbrush, blender, maya: Drag_Owner,
	}
	cases := [?]Case {
		{{.Right}, false, false, false, .Orbit, .Orbit, .Orbit},
		{{.Right}, false, true, false, .Pan, .Pan, .Pan},
		{{.Right}, false, false, true, .Pan, .Pan, .Zoom},
		{{.Right}, true, false, false, .Zoom, .Zoom, .Zoom},
		{{.Middle}, false, false, false, .Pan, .Orbit, .Pan},
		{{.Middle}, false, true, false, .Pan, .Pan, .Pan},
		{{.Middle}, true, false, false, .Zoom, .Zoom, .Zoom},
		{{.Middle}, false, false, true, .Pan, .Orbit, .Pan},
		{{.Left}, false, false, true, .Orbit, .Orbit, .Orbit},
		// The right button wins over the middle, as it is read first.
		{{.Right, .Middle}, false, false, false, .Orbit, .Orbit, .Orbit},
	}
	for c in cases {
		for scheme in Mouse_Scheme {
			want := [Mouse_Scheme]Drag_Owner{.ZBrush = c.zbrush, .Blender = c.blender, .Maya = c.maya}[scheme]
			got, decided := mouse_button_owner(scheme, c.held, c.ctrl, c.shift, c.alt)
			testing.expectf(t, decided && got == want, "%v %v ctrl=%v shift=%v alt=%v: %v, not %v", scheme, c.held, c.ctrl, c.shift, c.alt, got, want)
		}
	}
	for scheme in Mouse_Scheme {
		_, decided := mouse_button_owner(scheme, {.Left}, false, false, false)
		testing.expect(t, !decided)
		_, decided = mouse_button_owner(scheme, {.Left}, true, false, true)
		testing.expect(t, !decided, "Ctrl+Alt with the left button unmasks, a tool's")
	}
}

@(private = "file")
listed :: proc(rows: []Palette_Entry, id: Command_Id, arg := 0) -> bool {
	for e in rows do if e.id == id && e.arg == arg do return true
	return false
}

// The search finds a command by its name, by a whole key, or by a key's last part, and
// follows the keys the user moved.
@(test)
keys_are_found_by_name_or_key :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	all := keys_rows(&app, "")
	commands := 0
	for e in palette_entries() do if e.kind == .Command do commands += 1
	testing.expect_value(t, len(all), commands)

	rows := keys_rows(&app, "ctrl+z")
	testing.expect_value(t, len(rows), 1)
	testing.expect(t, listed(rows, .Undo))
	testing.expect(t, listed(keys_rows(&app, "Ctrl+Shift"), .Redo))
	testing.expect(t, listed(keys_rows(&app, "wire"), .Wireframe))
	rows = keys_rows(&app, "q")
	testing.expect(t, listed(rows, .Pie, 0) && listed(rows, .Pie, 1))
	testing.expect(t, !listed(rows, .Undo))
	// A modifier alone is no key's last part: "s" is not every Shift chord.
	testing.expect(t, !listed(keys_rows(&app, "s"), .Redo))
	testing.expect(t, listed(keys_rows(&app, "shift+f"), .Wireframe))

	testing.expect(t, bind_assign(&app, .Wireframe, 0, {sdl.K_K, {}, false}))
	testing.expect(t, !listed(keys_rows(&app, "shift+f"), .Wireframe))
	testing.expect(t, listed(keys_rows(&app, "k"), .Wireframe))
	free_all(context.temp_allocator)
}

// The tab's Reset puts every key and the mouse back.
@(test)
keys_tab_resets :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	app.nav = NAV_DEFAULT
	testing.expect(t, bind_assign(&app, .Wireframe, 0, {sdl.K_K, {}, false}))
	app.nav.mouse_scheme = .Blender
	settings_reset(&app, .Keys)
	testing.expect_value(t, app.key_override_count, 0)
	testing.expect_value(t, app.nav.mouse_scheme, Mouse_Scheme.ZBrush)
	testing.expect_value(t, command_keys(&app, .Wireframe), "Shift+F")
}
