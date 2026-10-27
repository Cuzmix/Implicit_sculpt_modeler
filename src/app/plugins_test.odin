package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "../geom"
import "../sculpt"

// Script plugins (plugins.odin): the sandbox, the budgets, commands registered and run
// through sculpt.run, and slots kept by name.

@(private = "file")
plugin_test_app :: proc(app: ^App, folder: string, files: [][2]string) {
	_ = os.remove_all(folder)
	if os.make_directory_all(folder) != nil do panic("cannot make the test's plugins folder")
	for f in files {
		path := fmt.tprintf("%s/%s", folder, f[0])
		if os.write_entire_file(path, transmute([]u8)f[1]) != nil do panic("cannot write a test plugin")
	}
	obj := new(Object)
	obj.id, obj.transform = 1, {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(3), nil, 64)
	append(&app.scene.objects, obj)
	app.scene.selected = 0
	plugins_load(app, folder)
}

@(private = "file")
plugin_test_free :: proc(app: ^App, folder: string) {
	plugins_destroy(app)
	for obj in app.scene.objects {
		sculpt.levels_destroy(&obj.levels)
		free(obj)
	}
	delete(app.scene.objects)
	history_destroy(&app.history)
	results_destroy(app)
	macros_destroy(app)
	_ = os.remove_all(folder)
}

@(private = "file")
plugin_named :: proc(app: ^App, file: string) -> ^Plugin {
	for p in app.plugins.plugins do if p.file == file do return p
	return nil
}

@(private = "file")
plugin_slot_of :: proc(app: ^App, key: string) -> int {
	for s, i in app.plugins.slots do if s.key == key do return i
	return -1
}

// Runs the command `key` as a person does: the command asks, the next frame runs it.
@(private = "file")
plugin_test_run :: proc(t: ^testing.T, app: ^App, key: string) {
	slot := plugin_slot_of(app, key)
	testing.expectf(t, slot >= 0 && command_enabled(app, .Run_Plugin, slot), "%s is not a command that can run", key)
	testing.expect(t, command_run(app, .Run_Plugin, slot))
	testing.expect(t, !command_enabled(app, .Run_Plugin, slot), "a second run can start before the first ran")
	testing.expect(t, plugins_frame(app))
	testing.expect_value(t, app.plugins.pending, 0)
}

// What a plugin cannot reach: files, processes, the environment of other code, the
// debug library, bytecode, and the built-ins and `sculpt` to change; its own globals it
// may set. The checks run in the plugin's top level, which fails to load if one fails.
@(test)
plugin_sandbox_holds :: proc(t: ^testing.T) {
	when !PLUGINS_AVAILABLE do return
	FOLDER :: "build/plugin_sandbox_test"
	app: App
	plugin_test_app(&app, FOLDER, {{"sandbox.luau", `
assert(io == nil and os == nil and getfenv == nil and setfenv == nil and debug == nil, "a library is there")
assert(loadstring == nil and load == nil and dofile == nil and loadfile == nil and require == nil, "a loader is there")
assert(not pcall(function() string.upper = nil end), "string is writable")
assert(not pcall(function() sculpt.run = nil end), "sculpt is writable")
assert(not pcall(function() setmetatable(_G, {}) end), "the globals' metatable is writable")
assert(not pcall(sculpt.run, "wireframe on"), "sculpt.run ran at the top level")
mine = 1
print("loaded", mine, 2.5, true, {})
sculpt.command{name = "Wires", help = "Shows the wireframe.", run = function() sculpt.run("wireframe on") end}
`}, {"r1.luau", "print(math.random(1000000))"}, {"r2.luau", "print(math.random(1000000))"}})
	defer plugin_test_free(&app, FOLDER)
	p := plugin_named(&app, "sandbox.luau")
	testing.expect(t, p != nil && p.state != nil, p.error if p != nil else "no plugin")
	testing.expect_value(t, p.output, "loaded\t1\t2.5\ttrue\ttable")
	testing.expect(t, plugin_slot_of(&app, "sandbox.luau/Wires") >= 0)
	testing.expect(t, app.plugins.errors == 0)
	// Random numbers are the same in every VM and on every run: the seed is fixed.
	r1, r2 := plugin_named(&app, "r1.luau"), plugin_named(&app, "r2.luau")
	testing.expect(t, r1 != nil && r2 != nil && r1.output != "" && r1.output == r2.output)
}

// A plugin that runs too long or holds too much stops with an error, its own pcall
// cannot keep it going, and the other plugins load as if it were not there.
@(test)
plugin_budgets_stop_a_plugin :: proc(t: ^testing.T) {
	when !PLUGINS_AVAILABLE do return
	FOLDER :: "build/plugin_budget_test"
	app: App
	plugin_test_app(&app, FOLDER, {
		{"a_loop.luau", "while true do end"},
		{"b_caught.luau", "pcall(function() while true do end end)\nsculpt.command{name = \"After\", run = function() end}"},
		{"c_memory.luau", "local t = {}\nfor i = 1, 1e9 do t[i] = string.rep(\"x\", 1000) .. i end"},
		{"d_fine.luau", "sculpt.command{name = \"Fine\", run = function() end}"},
		{"e_compile.luau", "local x = = 1"},
		{"notes.txt", "not a plugin"},
	})
	defer plugin_test_free(&app, FOLDER)
	testing.expect_value(t, len(app.plugins.plugins), 5)
	want := [?][2]string{{"a_loop.luau", "ran too long"}, {"b_caught.luau", "ran too long"}, {"c_memory.luau", "not enough memory"}, {"e_compile.luau", "e_compile.luau:1:"}}
	for w in want {
		p := plugin_named(&app, w[0])
		testing.expectf(t, p != nil && p.state == nil && strings.contains(p.error, w[1]), "%s: %q", w[0], p.error if p != nil else "missing")
		testing.expectf(t, p == nil || p.memory == 0, "%s keeps %d bytes", w[0], p.memory if p != nil else 0)
	}
	testing.expect_value(t, app.plugins.errors, 4)
	testing.expect(t, plugin_slot_of(&app, "b_caught.luau/After") < 0)
	testing.expect(t, plugin_slot_loaded(&app, plugin_slot_of(&app, "d_fine.luau/Fine")))
}

// A command runs at the next frame's start, its sculpt.run statements each an undo
// step; a statement that does nothing stops it with its line, keeping the steps before.
// The queries read the scene and the settings, and a note says what it did.
@(test)
plugin_commands_run_through_scripts :: proc(t: ^testing.T) {
	when !PLUGINS_AVAILABLE do return
	FOLDER :: "build/plugin_run_test"
	app: App
	plugin_test_app(&app, FOLDER, {{"tools.luau", `
sculpt.command{name = "Wires", run = function() sculpt.run("wireframe on") end}
sculpt.command{name = "Smooth twice", help = "Smooths the selected object twice.", run = function()
	sculpt.run("set smooth_steps 1; set smooth_strength 0.5; smooth_all")
	sculpt.run("smooth_all")
end}
sculpt.command{name = "Broken", run = function() sculpt.run("wireframe off\ndelete_higher_levels") end}
sculpt.command{name = "Bad script", run = function() sculpt.run("frobnicate") end}
sculpt.command{name = "Nested", run = function() sculpt.command{name = "Later", run = function() end} end}
sculpt.command{name = "Ask", run = function()
	local objects = sculpt.objects()
	sculpt.note(string.format("%d %s %d %s %s", #objects, objects[1].name, objects[1].vertices, tostring(sculpt.selected()), sculpt.get("smooth_steps")))
end}
sculpt.command{name = "Spin", run = function() while true do end end}
`}})
	defer plugin_test_free(&app, FOLDER)
	testing.expect_value(t, app.plugins.errors, 0)

	plugin_test_run(t, &app, "tools.luau/Wires")
	testing.expect(t, command_checked(&app, .Wireframe))
	testing.expect(t, strings.has_prefix(app.result.text, "Ran plugin Wires: 1 step"), app.result.text)

	done := len(app.history.done)
	plugin_test_run(t, &app, "tools.luau/Smooth twice")
	testing.expect_value(t, len(app.history.done), done + 2)
	testing.expect_value(t, app.plugins.steps, 5)

	plugin_test_run(t, &app, "tools.luau/Broken")
	testing.expect(t, !command_checked(&app, .Wireframe), "the step before the failing one was not kept")
	testing.expect(t, .Warning in app.result.flags && strings.contains(app.result.text, "line 2: delete_higher_levels did nothing"), app.result.text)

	plugin_test_run(t, &app, "tools.luau/Bad script")
	testing.expect(t, .Warning in app.result.flags && strings.contains(app.result.text, "frobnicate"), app.result.text)
	plugin_test_run(t, &app, "tools.luau/Nested")
	testing.expect(t, strings.contains(app.result.text, "only for a plugin's top level"), app.result.text)

	plugin_test_run(t, &app, "tools.luau/Ask")
	testing.expectf(t, app.result.text == "1 Sphere 1 642 1 1", "the note is %q", app.result.text)

	plugin_test_run(t, &app, "tools.luau/Spin")
	testing.expect(t, strings.contains(app.result.text, "ran too long"), app.result.text)
	// It ran too long once; the next run has its whole budget again.
	plugin_test_run(t, &app, "tools.luau/Wires")
	testing.expect(t, .Warning not_in app.result.flags, app.result.text)
	testing.expect_value(t, app.plugins.runs, 8)
	testing.expect_value(t, app.plugins.errors, 4)

	// Nothing starts while a recording is on, and a run asked for blocks other work.
	app.plugins.pending = 1
	testing.expect(t, !script_can_start(&app))
	app.plugins.pending = 0
}

// A command keeps its slot by its file and name: a new file that sorts first takes a
// free slot rather than moving the others' keys, a command that is gone keeps its slot
// as missing until it is forgotten, and the settings file writes them all.
@(test)
plugin_slots_follow_names :: proc(t: ^testing.T) {
	when !PLUGINS_AVAILABLE do return
	FOLDER :: "build/plugin_slot_test"
	first: App
	plugin_test_app(&first, FOLDER, {{"a.luau", `sculpt.command{name = "A", run = function() end}`}, {"b.luau", `sculpt.command{name = "B", run = function() end}`}})
	testing.expect_value(t, plugin_slot_of(&first, "a.luau/A"), 0)
	testing.expect_value(t, plugin_slot_of(&first, "b.luau/B"), 1)
	remembered := [2]string{strings.clone(first.plugins.slots[0].key, context.temp_allocator), strings.clone(first.plugins.slots[1].key, context.temp_allocator)}
	plugin_test_free(&first, FOLDER)

	second: App
	plugin_slot_remember(&second, 0, remembered[0])
	plugin_slot_remember(&second, 1, remembered[1])
	plugin_slot_remember(&second, 2, remembered[0]) // one key, one slot
	plugin_test_app(&second, FOLDER, {{"0.luau", `sculpt.command{name = "Zero", run = function() end}`}, {"a.luau", `sculpt.command{name = "A", run = function() end}`}})
	defer plugin_test_free(&second, FOLDER)
	testing.expect_value(t, plugin_slot_of(&second, "a.luau/A"), 0)
	testing.expect_value(t, plugin_slot_of(&second, "0.luau/Zero"), 2)
	testing.expect(t, !plugin_slot_loaded(&second, 1) && second.plugins.slots[1].key == "b.luau/B")
	testing.expect(t, !command_enabled(&second, .Run_Plugin, 1))
	testing.expect_value(t, plugin_slot_title(&second, 1), "Plugin: b.luau/B (missing)")
	entries := palette_entries_shown(&second)
	shown := 0
	for e in entries do if e.kind == .Command && e.id == .Run_Plugin do shown += 1
	testing.expect_value(t, shown, 2)

	// A reload keeps every slot where it was.
	second.plugins.reload = true
	testing.expect(t, plugins_frame(&second))
	testing.expect_value(t, plugin_slot_of(&second, "a.luau/A"), 0)
	testing.expect_value(t, plugin_slot_of(&second, "0.luau/Zero"), 2)

	plugin_forget(&second, 1)
	testing.expect_value(t, plugin_slot_of(&second, "b.luau/B"), -1)
	plugin_forget(&second, 0) // loaded: not forgotten
	testing.expect_value(t, plugin_slot_of(&second, "a.luau/A"), 0)
}
