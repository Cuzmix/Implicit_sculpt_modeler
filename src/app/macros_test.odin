package main

import "core:os"
import "core:strings"
import "core:testing"

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
