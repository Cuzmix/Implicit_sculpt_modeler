package main

import "core:testing"
import sdl "vendor:sdl3"

import "../camera"
import "../sculpt"

@(test)
every_command_has_words :: proc(t: ^testing.T) {
	for c, id in COMMANDS {
		if id == .None do continue
		testing.expectf(t, c.label != "", "%v has no label", id)
		testing.expectf(t, c.help != "", "%v has no help", id)
		testing.expectf(t, c.run != nil, "%v does nothing", id)
	}
}

// One chord, one meaning: no two default bindings share a key and modifiers, and every
// argument is one its command takes.
@(test)
default_bindings_are_unique :: proc(t: ^testing.T) {
	for a, i in DEFAULT_BINDINGS {
		c := COMMANDS[a.command]
		testing.expectf(t, c.args == 0 ? a.arg == 0 : a.arg >= 0 && a.arg < c.args, "%v bound with argument %d", a.command, a.arg)
		for b in DEFAULT_BINDINGS[i + 1:] {
			same := a.chord.key == b.chord.key && a.chord.mods == b.chord.mods
			testing.expectf(t, !same, "%s runs both %v and %v", chord_text(a.chord), a.command, b.command)
		}
	}
}

@(test)
chords_read_as_menus_show_them :: proc(t: ^testing.T) {
	cases := [?]struct {
		chord: Chord,
		text:  string,
	} {
		{{sdl.K_Z, {.Ctrl, .Shift}, true}, "Ctrl+Shift+Z"},
		{{sdl.K_F, {.Shift}, false}, "Shift+F"},
		{{sdl.K_M, {.Alt}, false}, "Alt+M"},
		{{sdl.K_F12, {}, false}, "F12"},
		{{sdl.K_F1, {}, false}, "F1"},
		{{sdl.K_DELETE, {}, false}, "Del"},
		{{sdl.K_KP_1, {.Ctrl}, false}, "Ctrl+Num 1"},
		{{sdl.K_0, {}, false}, "0"},
		{{sdl.K_LEFTBRACKET, {.Shift}, true}, "Shift+["},
		{{sdl.K_TAB, {}, false}, "Tab"},
	}
	for c in cases do testing.expect_value(t, chord_text(c.chord), c.text)
	free_all(context.temp_allocator)
}

// The shortcut texts the menus, the tool bar and the brush tiles showed before the
// registry, which now come from the bindings.
@(test)
menus_show_the_same_shortcuts :: proc(t: ^testing.T) {
	cases := [?]struct {
		id:   Command_Id,
		arg:  int,
		keys: string,
	} {
		{.Open_Scene, 0, "Ctrl+O"},
		{.Save_Scene, 0, "Ctrl+S"},
		{.Save_Scene_As, 0, "Ctrl+Shift+S"},
		{.Screenshot, 0, "F12"},
		{.Stats, 0, "F11"},
		{.Wireframe, 0, "Shift+F"},
		{.Flat_Shading, 0, "Shift+G"},
		{.Polygroups, 0, "Shift+W"},
		{.Studio_Render, 0, "Shift+R"},
		{.Ortho_Toggle, 0, "P"},
		{.Focus_Selected, 0, "F"},
		{.Duplicate_Object, 0, "Ctrl+Shift+D"},
		{.Delete_Object, 0, "Del"},
		{.Undo, 0, "Ctrl+Z"},
		{.Redo, 0, "Ctrl+Shift+Z"},
		{.Inspector, 0, "Tab"},
		{.Symmetry_X, 0, "X"},
		{.Brush, int(sculpt.Brush_Kind.Draw), "1"},
		{.Brush, int(sculpt.Brush_Kind.Layer), "0"},
		{.Brush, int(sculpt.Brush_Kind.Paint), ""},
		{.Import_Mesh, 0, ""},
	}
	for c in cases do testing.expectf(t, command_keys(c.id, c.arg) == c.keys, "%v %d shows %q, not %q", c.id, c.arg, command_keys(c.id, c.arg), c.keys)
	testing.expect_value(t, command_label(.Brush, int(sculpt.Brush_Kind.Clay)), "Clay brush")
	testing.expect_value(t, command_label(.View_Axis, int(camera.Axis_View.Front)), "Front view")
	free_all(context.temp_allocator)
}

// Modifiers match exactly: Ctrl+Shift+Z is Redo's chord and not Undo's, and a key held
// down repeats only the chords that repeat.
@(test)
chords_match_exact_modifiers :: proc(t: ^testing.T) {
	d: Device
	append(&d.keys, Key_Press{key = sdl.K_Z, mods = {.Ctrl, .Shift}})
	undo := Chord{sdl.K_Z, {.Ctrl}, true}
	redo := Chord{sdl.K_Z, {.Ctrl, .Shift}, true}
	testing.expect(t, !chord_down(&d, undo))
	testing.expect(t, chord_down(&d, redo))

	// A repeat of a held key, and "B, then Ctrl+S" within one frame.
	d = {}
	append(&d.keys, Key_Press{key = sdl.K_B})
	append(&d.keys, Key_Press{key = sdl.K_S, mods = {.Ctrl}, repeat = true})
	append(&d.keys, Key_Press{key = sdl.K_RIGHTBRACKET, repeat = true})
	testing.expect(t, chord_down(&d, Chord{sdl.K_B, {}, false}))
	testing.expect(t, !chord_down(&d, Chord{sdl.K_S, {.Ctrl}, false}))
	testing.expect(t, chord_down(&d, Chord{sdl.K_RIGHTBRACKET, {}, true}))
	testing.expect(t, !chord_down(&d, Chord{sdl.K_B, {.Ctrl}, false}))
	testing.expect_value(t, key_mods(sdl.KMOD_LCTRL | sdl.KMOD_NUM | sdl.KMOD_CAPS), bit_set[Key_Mod;u8]{.Ctrl})
}
