package main

import "core:os"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

import "../geom"
import "../sculpt"

@(private = "file")
macro_object :: proc(app: ^App) -> ^Object {
	obj := new(Object)
	obj.id, obj.transform = 1, {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(3), nil, 64)
	append(&app.scene.objects, obj)
	app.scene.selected = 0
	return obj
}

@(private = "file")
macro_scene_free :: proc(app: ^App) {
	for obj in app.scene.objects {
		sculpt.levels_destroy(&obj.levels)
		free(obj)
	}
	delete(app.scene.objects)
	history_destroy(&app.history)
	results_destroy(app)
	macros_destroy(app)
}

// A recording keeps each command run as the statement that does it again: a choice by
// name, a switch as the state it left, the panel values a command read as `set` lines
// (only when they changed), and nothing of the interface. What a script cannot hold is
// counted, and an undo of a recorded command's step takes it out again.
@(test)
macro_records_commands_as_a_script :: proc(t: ^testing.T) {
	app: App
	defer macro_scene_free(&app)
	_ = macro_object(&app)
	testing.expect(t, command_run(&app, .Macro_Record))
	testing.expect(t, command_checked(&app, .Macro_Record))
	testing.expect(t, command_run(&app, .Brush, int(sculpt.Brush_Kind.Clay)))
	testing.expect(t, command_run(&app, .Wireframe))
	app.ui.smooth_steps, app.ui.smooth_strength = 2, 0.5
	testing.expect(t, command_run(&app, .Smooth_All))
	testing.expect(t, command_run(&app, .Smooth_All))
	app.ui.smooth_steps = 3
	testing.expect(t, command_run(&app, .Smooth_All))
	testing.expect(t, command_run(&app, .Stats))
	testing.expect(t, command_run(&app, .Rename_Object))
	testing.expect_value(t, app.macro.left_out, 1)
	want := `# Macro: Test
brush clay
wireframe on
set smooth_steps 2
set smooth_strength 0.5
smooth_all
smooth_all
set smooth_steps 3
smooth_all
`
	testing.expect_value(t, macro_text(&app.macro, "Test", context.temp_allocator), want)

	// The last Smooth all goes with its undo, and so does its `set`: a Smooth all
	// recorded next writes it again.
	testing.expect(t, command_run(&app, .Undo))
	testing.expect_value(t, len(app.macro.entries), 4)
	testing.expect(t, command_run(&app, .Smooth_All))
	text := macro_text(&app.macro, "Test", context.temp_allocator)
	testing.expect(t, strings.has_suffix(text, "smooth_all\nset smooth_steps 3\nsmooth_all\n"), text)

	// Every line reads back as a script.
	s := script_parse(text, "macro")
	defer script_destroy(&s)
	testing.expect_value(t, script_report(&s), "")
	testing.expect_value(t, len(s.statements), 8)
}

// Stop asks for a name; Save keeps the macro in the first free slot and its file, which
// a later run reads back by slot, with its name; the palette then lists it by name.
@(test)
macro_saves_to_a_slot_and_reads_back :: proc(t: ^testing.T) {
	folder := "build/macros_test/"
	_ = os.remove_all(folder)
	defer os.remove_all(folder)
	app: App
	defer macro_scene_free(&app)
	_ = macro_object(&app)
	macros_load(&app, folder)
	testing.expect(t, command_run(&app, .Macro_Record))
	testing.expect(t, command_run(&app, .Wireframe))
	testing.expect(t, command_run(&app, .Macro_Record))
	testing.expect(t, !app.macro.recording)
	testing.expect(t, app.kit.macro_save.open, "Stop did not ask for a name")
	testing.expect(t, !command_enabled(&app, .Run_Macro, 0))
	testing.expect(t, macro_save(&app, "Wire on"))
	testing.expect_value(t, len(app.macro.entries), 0)
	testing.expect_value(t, app.macro.slots[0].name, "Wire on")
	testing.expect(t, command_enabled(&app, .Run_Macro, 0))
	testing.expect(t, !command_enabled(&app, .Run_Macro, 1))
	data, err := os.read_entire_file(macro_path(&app.macro, 0), context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, string(data), "# Macro: Wire on\nwireframe on\n")

	shown := 0
	for e in palette_entries_shown(&app) {
		if e.id != .Run_Macro do continue
		shown += 1
		testing.expect_value(t, entry_title(&app, e), "Macro: Wire on")
	}
	testing.expect_value(t, shown, 1)

	again: App
	defer macro_scene_free(&again)
	macros_load(&again, folder)
	testing.expect_value(t, again.macro.slots[0].name, "Wire on")
	testing.expect_value(t, again.macro.slots[0].text, string(data))
	testing.expect_value(t, macro_free_slot(&again.macro), 1)

	// Run macro starts it as the person's work: a statement that turns wireframe on.
	app.wireframe = false
	testing.expect(t, command_run(&app, .Run_Macro, 0))
	testing.expect(t, app.script.running && !app.script.setup)
	testing.expect_value(t, app.macro.runs, 1)
	script_unload(&app)
}

// No script records or runs a macro, so none can start itself.
@(test)
macros_are_not_for_scripts :: proc(t: ^testing.T) {
	for name in ([]string{"macro_record", "run_macro 1"}) {
		s := script_parse(name, "x")
		defer script_destroy(&s)
		testing.expectf(t, len(s.errors) == 1, "%s was taken", name)
	}
}

// Rename gives the macro its new name in its file's first line too, and a file that
// had no such line gets one in front of the person's own.
@(test)
macro_rename_rewrites_its_file :: proc(t: ^testing.T) {
	folder := "build/macros_rename_test/"
	_ = os.remove_all(folder)
	defer os.remove_all(folder)
	app: App
	defer macro_scene_free(&app)
	_ = macro_object(&app)
	macros_load(&app, folder)
	testing.expect(t, command_run(&app, .Macro_Record))
	testing.expect(t, command_run(&app, .Wireframe))
	testing.expect(t, command_run(&app, .Macro_Record))
	testing.expect(t, macro_save(&app, "Wire on"))
	testing.expect(t, macro_rename(&app, 0, "Wires"))
	testing.expect_value(t, app.macro.slots[0].name, "Wires")
	data, err := os.read_entire_file(macro_path(&app.macro, 0), context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, string(data), "# Macro: Wires\nwireframe on\n")

	app.macro.slots[1] = {strings.clone("Macro 2"), strings.clone("flat_shading on\n")}
	testing.expect(t, macro_rename(&app, 1, "Flat"))
	testing.expect_value(t, app.macro.slots[1].text, "# Macro: Flat\nflat_shading on\n")
	testing.expect(t, !macro_rename(&app, 2, "Nothing"), "renamed an empty slot")
}

// Delete takes the macro, its file, and every way there was to run it: its key, a pie
// slot, its star, a gesture and the palette's recents, so a macro saved in the slot later
// starts with none of them.
@(test)
macro_delete_takes_it_off_everything :: proc(t: ^testing.T) {
	folder := "build/macros_delete_test/"
	_ = os.remove_all(folder)
	defer os.remove_all(folder)
	app: App
	defer macro_scene_free(&app)
	_ = macro_object(&app)
	macros_load(&app, folder)
	testing.expect(t, command_run(&app, .Macro_Record))
	testing.expect(t, command_run(&app, .Wireframe))
	testing.expect(t, command_run(&app, .Macro_Record))
	testing.expect(t, macro_save(&app, "Wire on"))
	path := strings.clone(macro_path(&app.macro, 0), context.temp_allocator)
	testing.expect(t, os.exists(path))

	k := &app.kit
	testing.expect(t, bind_assign(&app, .Run_Macro, 0, {sdl.K_F7, {}, false}))
	k.pies[1][3] = {.Run_Macro, 0}
	k.pies[2][0] = {.Run_Macro, 1}
	testing.expect(t, favourite_toggle(&app, .Run_Macro, 0))
	app.nav.gestures[.Four_Tap] = {.Run_Macro, 0}
	palette_remember(&k.palette_recent, &k.palette_recent_count, {kind = .Command, id = .Wireframe})
	palette_remember(&k.palette_recent, &k.palette_recent_count, {kind = .Command, id = .Run_Macro, arg = 0})
	testing.expect_value(t, command_keys(&app, .Run_Macro, 0), "F7")

	testing.expect(t, macro_delete(&app, 0))
	testing.expect(t, !os.exists(path), "the file is still there")
	testing.expect_value(t, app.macro.slots[0].name, "")
	testing.expect_value(t, command_keys(&app, .Run_Macro, 0), "")
	testing.expect_value(t, key_override_find(&app, .Run_Macro, 0), -1)
	testing.expect(t, k.pies[1][3] == {}, "the pie slot still runs it")
	testing.expect(t, k.pies[2][0] == Pie_Slot{.Run_Macro, 1}, "another slot's macro lost its pie slot")
	testing.expect_value(t, favourite_find(&app, .Run_Macro, 0), -1)
	testing.expect(t, app.nav.gestures[.Four_Tap] == {}, "the gesture still runs it")
	testing.expect_value(t, k.palette_recent_count, 1)
	testing.expect_value(t, k.palette_recent[0].id, Command_Id.Wireframe)
	testing.expect(t, !macro_delete(&app, 0), "deleted an empty slot")
}

// Run script runs a file as a macro does, without keeping it: as the person's work, and
// not while a recording is on; a file with an error runs none of it and says why.
@(test)
run_script_runs_a_file_as_work :: proc(t: ^testing.T) {
	FOLDER :: "build/run_script_test/"
	folder := FOLDER
	_ = os.remove_all(folder)
	defer os.remove_all(folder)
	testing.expect(t, os.make_directory_all(folder) == nil)
	good, bad := FOLDER + "wire.cmd", FOLDER + "bad.cmd"
	testing.expect(t, os.write_entire_file(good, transmute([]u8)string("# Wires\nwireframe on\n")) == nil)
	testing.expect(t, os.write_entire_file(bad, transmute([]u8)string("wireframe on\nfrobnicate\n")) == nil)
	app: App
	defer macro_scene_free(&app)
	_ = macro_object(&app)

	testing.expect(t, command_run(&app, .Macro_Record))
	testing.expect(t, !command_enabled(&app, .Run_Script))
	testing.expect(t, command_run(&app, .Macro_Record))
	testing.expect(t, command_enabled(&app, .Run_Script))

	file_post(.Run_Script, bad)
	req, ok := file_take(&app)
	testing.expect(t, ok && req.kind == .Run_Script)
	testing.expect(t, file_apply(&app, req))
	file_request_free(req)
	testing.expect(t, !app.script.running)
	testing.expect(t, .Warning in app.result.flags && strings.contains(app.result.text, "bad.cmd:2"), app.result.text)

	file_post(.Run_Script, good)
	req, ok = file_take(&app)
	testing.expect(t, ok)
	testing.expect(t, file_apply(&app, req))
	file_request_free(req)
	testing.expect(t, app.script.running && !app.script.setup)
	testing.expect_value(t, app.macro.scripts, 1)
	testing.expect_value(t, app.macro.runs, 0)
	script_unload(&app)
}
