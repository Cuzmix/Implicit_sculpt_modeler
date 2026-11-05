package main

import "core:os"
import "core:testing"

import "../sculpt"

// A command given a key has only that one; the key leaves the command that had it, which
// keeps its other keys; Remove and Reset undo it; a zero App has the defaults.
@(test)
keys_change_where_the_user_says :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	testing.expect_value(t, command_chords(&app, .Redo), "Ctrl+Shift+Z, Ctrl+Y")
	ctrl_y := Chord{KEY_Y, {.Ctrl}, false}
	testing.expect(t, bind_assign(&app, .Wireframe, 0, ctrl_y))
	testing.expect_value(t, command_chords(&app, .Wireframe), "Ctrl+Y")
	testing.expect_value(t, command_chords(&app, .Redo), "Ctrl+Shift+Z")
	owner, ok := chord_owner(&app, {KEY_F, {.Shift}, false})
	testing.expect(t, !ok, "Shift+F left Wireframe")
	_ = owner

	// Ctrl+Z steps as Undo did, on its new command too.
	testing.expect(t, bind_assign(&app, .Redo, 0, {KEY_Z, {.Ctrl}, false}))
	testing.expect_value(t, command_chords(&app, .Redo), "Ctrl+Z")
	testing.expect_value(t, command_chords(&app, .Undo), "")
	b, _ := chord_owner(&app, {KEY_Z, {.Ctrl}, false})
	testing.expect(t, b.chord.repeat)

	// Taking a key the user gave another command leaves that one with none.
	testing.expect(t, bind_assign(&app, .Brush, int(sculpt.Brush_Kind.Clay), ctrl_y))
	testing.expect_value(t, command_chords(&app, .Wireframe), "")
	testing.expect_value(t, command_keys(&app, .Brush, int(sculpt.Brush_Kind.Clay)), "Ctrl+Y")

	_, reserved := chord_reserved({KEY_SPACE, {.Ctrl}, false})
	testing.expect(t, reserved)
	testing.expect(t, !bind_assign(&app, .Undo, 0, {KEY_S, {}, false}))
	_, reserved = chord_reserved({KEY_S, {.Ctrl}, false})
	testing.expect(t, !reserved)

	testing.expect(t, bind_remove(&app, .Focus_Selected, 0))
	testing.expect_value(t, command_keys(&app, .Focus_Selected), "")
	bind_reset(&app, .Focus_Selected, 0)
	testing.expect_value(t, command_keys(&app, .Focus_Selected), "F")
	// However the keys were moved, no chord runs two commands and none is reserved.
	keys := keymap(&app)
	for a, i in keys {
		_, held := chord_reserved(a.chord)
		testing.expectf(t, !held, "%s is reserved", chord_text(a.chord))
		for c in keys[i + 1:] do testing.expectf(t, !chord_same(a.chord, c.chord), "%s runs %v and %v", chord_text(a.chord), a.command, c.command)
	}
	bind_reset_all(&app)
	testing.expect_value(t, command_chords(&app, .Redo), "Ctrl+Shift+Z, Ctrl+Y")
	testing.expect_value(t, app.binding_count, len(DEFAULT_BINDINGS))
}

// Every default chord reads back from its text, and so do keys SDL names.
@(test)
chords_read_back_from_their_text :: proc(t: ^testing.T) {
	for b in DEFAULT_BINDINGS {
		c, ok := chord_parse(chord_text(b.chord))
		testing.expectf(t, ok && chord_same(c, b.chord), "%s reads back as %v", chord_text(b.chord), c)
	}
	for c in ([?]Chord{{KEY_PLUS, {.Ctrl}, false}, {KEY_HOME, {.Alt}, false}, {KEY_F10, {}, false}, {KEY_KP_0, {.Shift}, false}}) {
		back, ok := chord_parse(chord_text(c))
		testing.expectf(t, ok && chord_same(back, c), "%s reads back as %v", chord_text(c), back)
	}
	for bad in ([?]string{"", "Ctrl+", "F13", "Num 12", "Nokey"}) {
		_, ok := chord_parse(bad)
		testing.expectf(t, !ok, "%q reads as a chord", bad)
	}
	for id in Command_Id {
		if id == .None do continue
		for arg in 0 ..< max(COMMANDS[id].args, 1) {
			back, back_arg, ok := command_from_name(command_name(id, arg))
			testing.expectf(t, ok && back == id && back_arg == arg, "%s reads back as %v %d", command_name(id, arg), back, back_arg)
		}
	}
	free_all(context.temp_allocator)
}

// settings.txt keeps the changes, in order; a damaged line or one whose chord an earlier
// line took is skipped.
@(test)
keys_are_remembered :: proc(t: ^testing.T) {
	path := "build/keymap_test.txt"
	defer os.remove(path)
	a: App
	defer results_destroy(&a)
	testing.expect(t, bind_assign(&a, .Brush, int(sculpt.Brush_Kind.Clay), {KEY_PLUS, {.Ctrl}, false}))
	testing.expect(t, bind_assign(&a, .Wireframe, 0, {KEY_K, {}, false}))
	testing.expect(t, bind_remove(&a, .Undo, 0))
	testing.expect(t, bind_assign(&a, .Stats, 0, {KEY_KP_1, {.Ctrl}, false}))
	testing.expect(t, settings_save(&a, path))

	data, _ := os.read_entire_file(path, context.allocator)
	defer delete(data)
	extra := "key Nothing Ctrl+Q\nkey Stats Bogus+\nkey Tool_Move K\nkey Help:Keys\nkey Stats Space\n"
	full := make([]u8, len(data) + len(extra))
	defer delete(full)
	copy(full, data)
	copy(full[len(data):], extra)
	testing.expect(t, os.write_entire_file(path, full) == nil)

	b: App
	defer results_destroy(&b)
	settings_load(&b, path)
	testing.expect_value(t, b.key_override_count, 4)
	testing.expect_value(t, command_keys(&b, .Stats), "Ctrl+Num 1")
	testing.expect_value(t, command_keys(&b, .Brush, int(sculpt.Brush_Kind.Clay)), "Ctrl++")
	testing.expect_value(t, command_keys(&b, .Wireframe), "K")
	testing.expect_value(t, command_keys(&b, .Undo), "")
	testing.expect_value(t, command_keys(&b, .Tool_Move), "W")
}
