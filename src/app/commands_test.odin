package main

import "core:strings"
import "core:testing"

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
		{{KEY_Z, {.Ctrl, .Shift}, true}, "Ctrl+Shift+Z"},
		{{KEY_F, {.Shift}, false}, "Shift+F"},
		{{KEY_M, {.Alt}, false}, "Alt+M"},
		{{KEY_F12, {}, false}, "F12"},
		{{KEY_F1, {}, false}, "F1"},
		{{KEY_DELETE, {}, false}, "Del"},
		{{KEY_KP_1, {.Ctrl}, false}, "Ctrl+Num 1"},
		{{KEY_0, {}, false}, "0"},
		{{KEY_LEFTBRACKET, {.Shift}, true}, "Shift+["},
		{{KEY_TAB, {}, false}, "Tab"},
		{{KEY_SLASH, {}, false}, "/"},
		{{KEY_K, {.Ctrl}, false}, "Ctrl+K"},
	}
	for c in cases do testing.expect_value(t, chord_text(c.chord), c.text)
	free_all(context.temp_allocator)
}

// The shortcut texts the menus, the tool bar and the brush tiles showed before the
// registry, which now come from the bindings; Tab is clean view and B the brush picker,
// as Lens has them.
@(test)
menus_show_the_same_shortcuts :: proc(t: ^testing.T) {
	app: App
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
		{.Clean_View, 0, "Tab"},
		{.Brush_Picker, 0, "B"},
		{.Inspector, 0, ""},
		{.Symmetry_X, 0, "X"},
		{.Brush, int(sculpt.Brush_Kind.Draw), "1"},
		{.Brush, int(sculpt.Brush_Kind.Layer), "0"},
		{.Brush, int(sculpt.Brush_Kind.Paint), ""},
		{.Import_Mesh, 0, ""},
	}
	for c in cases do testing.expectf(t, command_keys(&app, c.id, c.arg) == c.keys, "%v %d shows %q, not %q", c.id, c.arg, command_keys(&app, c.id, c.arg), c.keys)
	testing.expect_value(t, command_label(.Brush, int(sculpt.Brush_Kind.Clay)), "Clay brush")
	testing.expect_value(t, command_label(.View_Axis, int(camera.Axis_View.Front)), "Front view")
	free_all(context.temp_allocator)
}

// Modifiers match exactly: Ctrl+Shift+Z is Redo's chord and not Undo's, and a key held
// down repeats only the chords that repeat.
@(test)
chords_match_exact_modifiers :: proc(t: ^testing.T) {
	d: Device
	append(&d.keys, Key_Press{key = KEY_Z, mods = {.Ctrl, .Shift}})
	undo := Chord{KEY_Z, {.Ctrl}, true}
	redo := Chord{KEY_Z, {.Ctrl, .Shift}, true}
	testing.expect(t, !chord_down(&d, undo))
	testing.expect(t, chord_down(&d, redo))

	// A repeat of a held key, and "B, then Ctrl+S" within one frame.
	d = {}
	append(&d.keys, Key_Press{key = KEY_B})
	append(&d.keys, Key_Press{key = KEY_S, mods = {.Ctrl}, repeat = true})
	append(&d.keys, Key_Press{key = KEY_RIGHTBRACKET, repeat = true})
	testing.expect(t, chord_down(&d, Chord{KEY_B, {}, false}))
	testing.expect(t, !chord_down(&d, Chord{KEY_S, {.Ctrl}, false}))
	testing.expect(t, chord_down(&d, Chord{KEY_RIGHTBRACKET, {}, true}))
	testing.expect(t, !chord_down(&d, Chord{KEY_B, {.Ctrl}, false}))
	testing.expect_value(t, key_mods({.LCTRL, .NUM, .CAPS}), bit_set[Key_Mod;u8]{.Ctrl})
}

// A command that takes an argument names each choice, so search can list them apart.
@(test)
every_choice_has_its_own_label :: proc(t: ^testing.T) {
	app: App
	for c, id in COMMANDS {
		for a in 0 ..< c.args {
			label := command_label(id, a)
			testing.expectf(t, label != "" && label != c.label, "%v %d has no label of its own", id, a)
			for b in a + 1 ..< c.args do testing.expectf(t, label != command_label(id, b), "%v %d and %d are both %q", id, a, b, label)
		}
	}
	testing.expect_value(t, command_label(.Mask, int(sculpt.Mask_Command.Clear)), "Clear mask")
	testing.expect_value(t, command_label(.Remesh_To, 2), "Remesh to 1M vertices")
	testing.expect_value(t, command_keys(&app, .Mask, int(sculpt.Mask_Command.Clear)), "Alt+M")
	testing.expect_value(t, command_keys(&app, .Mask, int(sculpt.Mask_Command.Invert)), "Ctrl+I")
	free_all(context.temp_allocator)
}

// Every control in the app's own sources that runs a command shows that command's
// shortcut and gesture: a widget call that runs one on its line passes command_hint (or,
// for tabs, a `hints` slice built from it), and
// no plain button pair runs one (kit_command_pair and command_button do it themselves).
// A source scan, since what a tooltip says is decided where the widget is called.
@(test)
controls_that_run_commands_show_their_hints :: proc(t: ^testing.T) {
	WIDGETS :: [?]string{"ui.button(", "ui.icon_button(", "ui.switch_row(", "ui.tabs(", "ui.brush_tile(", "ui.toggle_button(", "ui.menu_item("}
	files := #load_directory(".")
	checked := 0
	for f in files {
		if !strings.has_suffix(f.name, ".odin") || strings.has_suffix(f.name, "_test.odin") do continue
		lines := strings.split_lines(string(f.data), context.temp_allocator)
		for line, i in lines {
			widget := false
			for w in WIDGETS do widget ||= strings.contains(line, w)
			// The command may run on the widget's line or, after a `{`, on the next two.
			runs := strings.contains(line, "command_run(")
			if widget && strings.has_suffix(strings.trim_space(line), "{") {
				for next in lines[i + 1:][:min(2, len(lines) - i - 1)] do runs ||= strings.contains(next, "command_run(")
			}
			if widget && runs {
				checked += 1
				testing.expectf(t, strings.contains(line, "command_hint(") || strings.contains(line, "hints[:]"), "%s:%d runs a command without its hint: %s", f.name, i + 1, strings.trim_space(line))
			}
			if strings.contains(line, "kit_button_pair(") && !strings.contains(line, "::") {
				for next in lines[i + 1:][:min(2, len(lines) - i - 1)] {
					testing.expectf(t, !strings.contains(next, "command_run("), "%s:%d runs a command from kit_button_pair: use kit_command_pair", f.name, i + 1)
				}
			}
		}
	}
	// The scan saw the sources: the top bar's Undo, Redo and Inspector at least.
	testing.expect(t, checked >= 3)
	free_all(context.temp_allocator)
}

// The hint joins the shortcut and the gesture, follows the Settings, and is either alone.
@(test)
hints_join_keys_and_gestures :: proc(t: ^testing.T) {
	app: App
	app.nav, app.tool, app.kit.rail_side = NAV_DEFAULT, .Brush, .Left
	testing.expect_value(t, command_hint(&app, .Undo), "Ctrl+Z · Two-finger tap, hold to repeat")
	testing.expect_value(t, command_hint(&app, .Wireframe), "Shift+F")
	testing.expect_value(t, command_hint(&app, .Mask, int(sculpt.Mask_Command.Blur)), "With Mask on, tap the mask")
	app.nav.gestures[.Two_Tap] = {}
	testing.expect_value(t, command_hint(&app, .Undo), "Ctrl+Z · Hold two fingers still")
	app.nav.gestures[.Two_Tap], app.nav.gestures[.Three_Hold] = {.Undo, 0}, {}
	testing.expect_value(t, command_hint(&app, .Redo), "Ctrl+Shift+Z · Three-finger tap")
	app.nav.gestures[.Three_Tap] = {}
	testing.expect_value(t, command_hint(&app, .Redo), "Ctrl+Shift+Z")
	// A gesture the map gives a command comes before the command's own.
	app.nav.gestures[.Three_Tap] = {.Frame_All, 0}
	testing.expect_value(t, command_gesture(&app, .Frame_All), "Three-finger tap; Double tap empty space, nothing selected")
	// The double tap on empty space is the Move and Sculpt tools', the mask taps Sculpt's.
	app.tool = .Curve
	testing.expect_value(t, command_gesture(&app, .Focus_Selected), "")
	testing.expect_value(t, command_gesture(&app, .Mask, int(sculpt.Mask_Command.Blur)), "")
	app.tool = .Move
	testing.expect_value(t, command_gesture(&app, .Focus_Selected), "Double tap empty space")
	app.nav.double_tap = false
	testing.expect_value(t, command_gesture(&app, .Focus_Selected), "")
	testing.expect_value(t, command_hint(&app, .Smooth_All), "")
	free_all(context.temp_allocator)
}
