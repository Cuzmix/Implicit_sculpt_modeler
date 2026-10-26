package main

import "core:os"
import "core:strings"
import "core:testing"

import "../sculpt"

@(private = "file")
preset_app :: proc(app: ^App) {
	app.brush.kind = .Clay
	app.brush.alpha = -1
	for &s, kind in app.brush.strengths do s = BRUSHES[kind].strength
}

// A preset holds its own values while the brush is on it, Revert puts them back, and
// leaving it, for its own plain brush or another, gives the plain brush its own back.
@(test)
presets_keep_the_plain_brushes_own :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	preset_app(&app)
	app.brush.strengths[.Clay] = 0.3
	testing.expect(t, preset_save_new(&app))
	testing.expect_value(t, app.brush.preset, 1)
	testing.expect_value(t, preset_name(&app.presets[0]), "Clay 1")
	testing.expect(t, !preset_changed(&app))

	app.brush.strengths[.Clay] = 0.9
	app.brush.lazy_px = 20
	testing.expect(t, preset_changed(&app))
	preset_revert(&app)
	testing.expect(t, !preset_changed(&app))
	testing.expect_value(t, app.brush.lazy_px, 0)

	// The colour is no part of a Clay preset, so it is never a change.
	app.brush.color = {1, 0, 0}
	testing.expect(t, !preset_changed(&app))

	app.brush.strengths[.Clay] = 0.8
	preset_save(&app)
	testing.expect_value(t, app.presets[0].values.strength, 0.8)
	testing.expect(t, command_run(&app, .Brush, int(sculpt.Brush_Kind.Draw)))
	testing.expect_value(t, app.brush.preset, 0)
	testing.expect_value(t, app.brush.strengths[.Clay], 0.3)
	testing.expect_value(t, app.brush.kind, sculpt.Brush_Kind.Draw)
	testing.expect(t, !command_checked(&app, .Brush, int(sculpt.Brush_Kind.Clay)))

	preset_pick(&app, 0)
	testing.expect(t, app.brush.kind == .Clay && app.brush.strengths[.Clay] == 0.8)
	testing.expect(t, !command_checked(&app, .Brush, int(sculpt.Brush_Kind.Clay)))
	plain := brush_plain(&app)
	testing.expect_value(t, plain.strengths[.Clay], 0.3)
	testing.expect_value(t, plain.preset, 0)

	// A copy goes on the new preset, keeping the plain values to go back to.
	testing.expect(t, preset_save_new(&app))
	testing.expect_value(t, app.brush.preset, 2)
	testing.expect_value(t, preset_name(&app.presets[1]), "Clay 2")
	preset_leave(&app)
	testing.expect_value(t, app.brush.strengths[.Clay], 0.3)
}

// Deleting a preset takes the brush off it, and keeps the brush on a later one.
@(test)
presets_delete_and_keep_the_brush_on_its_own :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	preset_app(&app)
	for _ in 0 ..< 3 do testing.expect(t, preset_save_new(&app))
	testing.expect_value(t, app.brush.preset, 3)
	preset_delete(&app, 0)
	testing.expect(t, app.preset_count == 2 && app.brush.preset == 2)
	testing.expect_value(t, preset_name(&app.presets[1]), "Clay 3")
	preset_delete(&app, 1)
	testing.expect(t, app.preset_count == 1 && app.brush.preset == 0)
	for _ in 0 ..< MAX_PRESETS - 1 do testing.expect(t, preset_save_new(&app))
	testing.expect(t, !preset_save_new(&app))
	testing.expect(t, !command_enabled(&app, .Preset_Save_New))
}

// A name must be one of its own: not empty, not another preset's, not a brush's; a long
// one is cut on a character boundary.
@(test)
presets_take_only_names_of_their_own :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	preset_app(&app)
	testing.expect(t, preset_save_new(&app) && preset_save_new(&app))
	testing.expect(t, preset_rename(&app, 0, "  Soft clay  "))
	testing.expect_value(t, preset_name(&app.presets[0]), "Soft clay")
	testing.expect(t, !preset_rename(&app, 1, "soft CLAY"))
	testing.expect(t, !preset_rename(&app, 1, "   "))
	testing.expect(t, !preset_rename(&app, 1, "snake hook"))
	testing.expect(t, preset_rename(&app, 1, "ééééééééééééééééééééé"))
	testing.expect_value(t, len(preset_name(&app.presets[1])), 30)
	testing.expect_value(t, preset_unescape(preset_escape("50% soft clay\t")), "50% soft clay\t")
	testing.expect_value(t, preset_escape("a b%"), "a%20b%25")
}

// settings.txt keeps the presets, names with spaces, their alpha, Lock plane and
// Connected included, and the preset the brush was on, whose plain brush keeps its own
// values; a line from before Lock plane and Connected reads with both off, and damaged
// lines are skipped.
@(test)
presets_are_remembered :: proc(t: ^testing.T) {
	path := "build/presets_test.txt"
	defer os.remove(path)
	a: App
	defer results_destroy(&a)
	alphas_init(&a)
	defer alphas_destroy(&a)
	preset_app(&a)
	a.brush.strengths[.Clay] = 0.3
	testing.expect(t, preset_save_new(&a))
	testing.expect(t, preset_rename(&a, 0, "Soft 50% clay"))
	testing.expect(t, command_run(&a, .Brush, int(sculpt.Brush_Kind.Draw)))
	a.brush.alpha, a.brush.stroke = 2, .Drag_Rect
	a.brush.falloffs[.Draw] = {drawn = true, curve = {{0.1, 0.2}, {0.7, 0.9}}}
	a.brush.lock_plane, a.brush.connected = true, true
	testing.expect(t, preset_save_new(&a))
	a.brush.strengths[.Draw] = 0.95 // a change not saved in the preset
	testing.expect(t, settings_save(&a, path))
	testing.expect_value(t, a.brush.strengths[.Draw], 0.95)

	data, _ := os.read_entire_file(path, context.allocator)
	defer delete(data)
	damaged := strings.concatenate({string(data), "preset Broken Draw 0.5\npreset Clay%201 Nobrush 0.5 0 0 0 1 1 - Stroke 0 Dots 0 0 0 0 0 Pull\n",
		"preset Old%20clay Clay 0.5 0 0.25 0.25 0.75 0.75 - Stroke 0 Dots 0 0.5 0.5 0.5 Drag 0.6\n"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, transmute([]u8)damaged) == nil)

	b: App
	defer results_destroy(&b)
	preset_app(&b)
	settings_load(&b, path)
	testing.expect_value(t, b.preset_count, 3)
	testing.expect(t, b.presets[1].values.lock_plane && b.presets[1].values.connected)
	testing.expect_value(t, preset_name(&b.presets[2]), "Old clay")
	testing.expect(t, !b.presets[2].values.lock_plane && !b.presets[2].values.connected)
	testing.expect_value(t, b.presets[2].values.spread, 0.6)
	testing.expect_value(t, preset_name(&b.presets[0]), "Soft 50% clay")
	testing.expect_value(t, b.presets[0].values.strength, 0.3)
	testing.expect(t, preset_same(&a, a.presets[1].values, b.presets[1].values))
	testing.expect_value(t, b.presets[1].values.alpha, 2)
	testing.expect_value(t, b.brush.preset, 2)
	testing.expect(t, !preset_changed(&b))
	testing.expect_value(t, b.brush.strengths[.Clay], 0.3)
	// The plain Draw brush is as it was when the preset was made from it, without the
	// change made on the preset since.
	preset_leave(&b)
	testing.expect_value(t, b.brush.strengths[.Draw], BRUSHES[.Draw].strength)
	testing.expect(t, b.brush.falloffs[.Draw].drawn)
}
