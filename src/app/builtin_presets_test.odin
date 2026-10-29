package main

import "core:os"
import "core:strings"
import "core:testing"

import "../sculpt"

// The built-in presets put the brush on their values, are read-only (no Save or Delete),
// Save as new makes one of the person's own named after them, their names stay theirs,
// and leaving one gives the plain brush its own values back.
@(test)
built_in_presets_are_read_only :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	app.brush.kind, app.brush.alpha = .Draw, -1
	for &s, kind in app.brush.strengths do s = BRUSHES[kind].strength
	n := built_in_preset_find("smooth VALLEYS")
	testing.expect(t, preset_built_in(n))
	testing.expect_value(t, preset_by_ref(&app, "Smooth valleys"), n)
	preset_use(&app, n)
	testing.expect_value(t, app.brush.kind, sculpt.Brush_Kind.Smooth)
	testing.expect_value(t, app.brush.smooth_only, sculpt.Smooth_Only.Valleys)
	testing.expect_value(t, app.brush.strengths[.Smooth], 0.8)
	testing.expect(t, !preset_changed(&app))
	app.brush.strengths[.Smooth] = 0.3
	testing.expect(t, preset_changed(&app))
	testing.expect(t, !command_enabled(&app, .Preset_Save), "a built-in offered to save over")
	testing.expect(t, !command_enabled(&app, .Preset_Delete), "a built-in offered to delete")
	preset_save(&app)
	p, _ := preset_at(&app, n)
	testing.expect_value(t, p.values.strength, 0.8)
	testing.expect(t, preset_save_new(&app))
	testing.expect_value(t, preset_name(&app.presets[0]), "Smooth valleys 1")
	testing.expect(t, !preset_rename(&app, 0, "move connected"), "took a built-in's name")
	preset_use(&app, built_in_preset_find("Move all depth"))
	testing.expect(t, app.brush.kind == .Grab && app.brush.grab_depth)
	command_run(&app, .Brush, int(sculpt.Brush_Kind.Draw))
	testing.expect(t, !app.brush.grab_depth && app.brush.smooth_only == .All)
	testing.expect_value(t, app.brush.strengths[.Smooth], 0.5)
	// Every built-in names its own brush and a value its brush uses.
	for r in BUILT_IN_PRESETS {
		testing.expect(t, built_in_preset_find(r.name) > 0)
		_, clash := brush_by_name(r.name)
		testing.expectf(t, !clash, "%s is a brush's name", r.name)
	}
}

// settings.txt puts the brush back on a built-in by name; a
// preset of the person's own keeps All depth and Smooth only, and its line reads in a
// build that knows them.
@(test)
built_in_presets_are_remembered :: proc(t: ^testing.T) {
	path := "build/builtin_presets_test.txt"
	defer os.remove(path)
	a: App
	defer results_destroy(&a)
	alphas_init(&a)
	defer alphas_destroy(&a)
	a.brush.kind, a.brush.alpha = .Draw, -1
	for &s, kind in a.brush.strengths do s = BRUSHES[kind].strength
	preset_use(&a, built_in_preset_find("Move all depth"))
	testing.expect(t, preset_save_new(&a))
	preset_use(&a, built_in_preset_find("Smooth peaks"))
	testing.expect(t, settings_save(&a, path))
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, strings.contains(string(data), "brush_preset Smooth%20peaks"))

	b: App
	defer results_destroy(&b)
	alphas_init(&b)
	defer alphas_destroy(&b)
	settings_load(&b, path)
	testing.expect_value(t, b.brush.preset, built_in_preset_find("Smooth peaks"))
	testing.expect_value(t, b.brush.smooth_only, sculpt.Smooth_Only.Peaks)
	testing.expect_value(t, b.preset_count, 1)
	testing.expect(t, b.presets[0].values.grab_depth)
	p, _ := preset_at(&b, built_in_preset_find("Clay buildup"))
	testing.expect_value(t, p.values.alpha, int(sculpt.Alpha_Shape.Square))
}

// A settings file from before the built-ins with a preset of the person's own named as one
// now is keeps it as "<name> 1", the brush following it there, and its old dock line
// is passed over.
@(test)
own_presets_named_as_a_built_in_are_kept :: proc(t: ^testing.T) {
	path := "build/builtin_clash_test.txt"
	defer os.remove(path)
	text := "preset Trim Flatten 0.3 0 0 0 0 0 - Stroke 0 Dots 0 0 0 0 Drag\nbrush Flatten\nbrush_preset Trim\ndock 0 preset Trim\n"
	testing.expect(t, os.write_entire_file(path, transmute([]u8)text) == nil)
	a: App
	defer results_destroy(&a)
	settings_load(&a, path)
	testing.expect_value(t, a.preset_count, 1)
	testing.expect_value(t, preset_name(&a.presets[0]), "Trim 1")
	testing.expect_value(t, a.brush.preset, 1)
	testing.expect_value(t, a.brush.strengths[.Flatten], 0.3)
}
