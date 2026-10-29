package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"
// Used only where plugins are (PLUGINS_AVAILABLE), which the Android build leaves out.
@(require) import "core:c/libc"
@(require) import "core:os"
@(require) import "core:slice"

import "../luau"

// Script plugins (README "Script plugins"): `.luau` files in the `plugins` folder beside
// the settings, each run in a Luau VM of its own. A plugin's top level registers
// commands (sculpt.command), which join the registry as Run plugin slots; a command's
// `run` changes the scene only through sculpt.run, which runs command-script text as a
// macro does, each statement its own undo step. The VM is sandboxed: Luau's restricted
// libraries less getfenv, setfenv, debug and os, read-only built-ins, source compiled
// here (never bytecode from a file), a memory budget and a step budget. Desktop builds
// only (luau.AVAILABLE): elsewhere nothing here loads and Run plugin is never enabled.
// Design and review: notes/phase7/script-plugins-design.md.

PLUGINS_AVAILABLE :: luau.AVAILABLE
PLUGIN_FOLDER :: "plugins"
PLUGIN_EXTENSION :: ".luau"
// Commands all plugins together register, as Run plugin's slots.
PLUGIN_COMMANDS_MAX :: 64
// Files read from the folder, in name order; the rest are counted and skipped.
PLUGIN_FILES_MAX :: 64
// A plugin's source, at most: larger is not a script a person wrote.
PLUGIN_SOURCE_MAX :: 1 << 20
// What a plugin's VM may hold. Past it an allocation fails, which Luau raises as "not
// enough memory" in the plugin, never in the app.
PLUGIN_MEMORY :: 64 << 20
// Safepoints (calls and loop back edges) a plugin's top level, and one run of a
// command, may pass: steps rather than time, so a plugin stops at the same place on
// every machine. Time in sculpt.run is the app's own work and is not counted.
PLUGIN_LOAD_STEPS :: 5_000_000
PLUGIN_RUN_STEPS :: 50_000_000
PLUGIN_NAME_MAX :: 48
PLUGIN_HELP_MAX :: 200
PLUGIN_NOTE_MAX :: 200

// One `.luau` file: its VM while it loaded, or why it did not.
Plugin :: struct {
	file:    string, // its name in the folder; heap
	state:   ^luau.State, // the VM; nil when it failed to load
	thread:  ^luau.State, // the sandboxed thread its code runs on, kept by `thread_ref`
	thread_ref: c.int,
	error:   string, // why it failed to load, or its last run stopped; heap, "" for none
	output:  string, // the last line it printed; heap
	memory:  int, // bytes its VM holds
	limited: bool, // in one of its calls, where the memory budget holds
}

// A Run plugin slot: the command it holds, by `<file>/<name>`, which the settings keep
// (`plugin_slot`), so its key, pie slot and star stay on that command across runs.
Plugin_Slot :: struct {
	key:    string, // heap; "" for a free slot
	name:   string, // as registered; heap, "" while missing
	help:   string, // heap
	plugin: int, // the Plugin, or -1 while its command is missing (kept until Forget)
	ref:    c.int, // its run function, in the plugin's registry
}

Plugins :: struct {
	folder:  string, // heap; "" when this run keeps none
	plugins: [dynamic]^Plugin, // by address: each VM's allocator holds its Plugin
	slots:   [PLUGIN_COMMANDS_MAX]Plugin_Slot,
	pending: int, // the slot to run at the next frame's start, plus one; 0 for none
	reload:  bool, // Reload plugins, at the next frame's start
	skipped: int, // files past PLUGIN_FILES_MAX or PLUGIN_SOURCE_MAX
	runs, errors, steps: int, // for the exit stats: commands run, loads and runs that failed, statements run
}

// One entry into a plugin's VM, on the stack of whoever enters it and found by the
// callbacks through lua_callbacks(L).userdata.
@(private = "file")
Plugin_Call :: struct {
	app:     ^App,
	plugin:  int,
	ctx:     runtime.Context,
	steps:   int,
	budget:  int,
	running: bool, // a command's run (sculpt.run allowed), not the top level (sculpt.command allowed)
	ran:     int, // statements sculpt.run ran
	noted:   bool, // sculpt.note said what it did, which the run's own note leaves in place
	gpu_failed: bool,
}

plugins_folder :: proc(settings: string) -> string {
	if settings == "" || !PLUGINS_AVAILABLE do return ""
	dir, base := filepath.split(settings)
	name := PLUGIN_FOLDER if base == SETTINGS_FILE else fmt.tprintf("%s-%s", filepath.stem(base), PLUGIN_FOLDER)
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	return path
}

// Reads the plugins in `folder` (plugins_folder), in name order. The slots the settings
// remembered are already in place (settings_load's `plugin_slot` lines).
plugins_load :: proc(app: ^App, folder: string) {
	ps := &app.plugins
	ps.folder = strings.clone(folder)
	plugins_open_all(app)
}

plugins_destroy :: proc(app: ^App) {
	ps := &app.plugins
	plugins_close_all(app)
	for &s in ps.slots do plugin_slot_free(&s)
	delete(ps.plugins)
	delete(ps.folder)
	ps^ = {}
}

// Closes every plugin, keeping each slot's command by its key, as missing, for the
// next load to fill again.
@(private = "file")
plugins_close_all :: proc(app: ^App) {
	ps := &app.plugins
	for p in ps.plugins {
		when PLUGINS_AVAILABLE {
			if p.state != nil do luau.lua_close(p.state)
		}
		delete(p.file)
		delete(p.error)
		delete(p.output)
		free(p)
	}
	clear(&ps.plugins)
	ps.skipped = 0
	for &s in ps.slots {
		delete(s.name)
		delete(s.help)
		s.name, s.help, s.plugin, s.ref = "", "", -1, 0
	}
}

@(private = "file")
plugin_slot_free :: proc(s: ^Plugin_Slot) {
	delete(s.key)
	delete(s.name)
	delete(s.help)
	s^ = {plugin = -1}
}

// Keeps a slot the settings file remembers for `key` (`plugin_slot <n> <key>`); one
// already taken, or out of range, is skipped.
plugin_slot_remember :: proc(app: ^App, slot: int, key: string) {
	if slot < 0 || slot >= PLUGIN_COMMANDS_MAX || key == "" do return
	s := &app.plugins.slots[slot]
	if s.key != "" do return
	for other in app.plugins.slots do if other.key == key do return
	s.key, s.plugin = strings.clone(key), -1
}

plugin_slot_loaded :: proc(app: ^App, slot: int) -> bool {
	return slot >= 0 && slot < PLUGIN_COMMANDS_MAX && app.plugins.slots[slot].plugin >= 0 && app.plugins.slots[slot].key != ""
}

// Run plugin N: whether it can run now.
plugin_can_run :: proc(app: ^App, slot: int) -> bool {
	return PLUGINS_AVAILABLE && plugin_slot_loaded(app, slot) && script_can_start(app)
}

// Asks for the command in `slot` to run at the next frame's start.
plugin_run :: proc(app: ^App, slot: int) {
	if !plugin_can_run(app, slot) do return
	app.plugins.pending = slot + 1
}

plugins_reload_request :: proc(app: ^App) {
	if PLUGINS_AVAILABLE && app.plugins.folder != "" && script_can_start(app) do app.plugins.reload = true
}

// Forgets a missing command's slot: its key, pie slot, star and gesture go with it, and
// the settings file says so at once.
plugin_forget :: proc(app: ^App, slot: int) {
	s := &app.plugins.slots[slot]
	if s.key == "" || s.plugin >= 0 do return
	key := strings.clone(s.key, context.temp_allocator)
	_ = command_slot_forget(app, .Run_Plugin, slot)
	plugin_slot_free(s)
	if app.settings_file != "" do _ = settings_save(app, app.settings_file)
	report(app, nil, {}, "Forgot plugin command %s", key)
}

// What the palette and keys show for a slot: the command's name, or its key while missing.
plugin_slot_title :: proc(app: ^App, slot: int) -> string {
	s := app.plugins.slots[slot]
	if s.name != "" do return fmt.tprintf("Plugin: %s", s.name)
	return fmt.tprintf("Plugin: %s (missing)", s.key)
}

// Runs what the plugins asked for last frame, at this frame's start where scene
// commands apply: a reload, then a command. False only on a GPU failure.
plugins_frame :: proc(app: ^App) -> bool {
	when !PLUGINS_AVAILABLE {
		return true
	} else {
		ps := &app.plugins
		if ps.reload {
			ps.reload = false
			if script_can_start(app) {
				plugins_close_all(app)
				plugins_open_all(app)
				loaded := 0
				for _, i in ps.slots do loaded += int(plugin_slot_loaded(app, i))
				flags := Report_Flags{.Warning} if plugins_failed(app) > 0 else {}
				report(app, nil, flags, "Reloaded %d plugin%s: %d command%s%s", len(ps.plugins), "" if len(ps.plugins) == 1 else "s", loaded, "" if loaded == 1 else "s", plugins_failed_text(app))
			}
		}
		if ps.pending == 0 do return true
		slot := ps.pending - 1
		ps.pending = 0
		s := &ps.slots[slot]
		// A save, a dialog or a recording may have started since it was asked for.
		if !plugin_slot_loaded(app, slot) || !script_can_start(app) {
			report(app, nil, {.Warning}, "Cannot run plugin %s now: a recording, a script, a stroke or a save is under way", s.name if s.name != "" else s.key)
			return true
		}
		p := ps.plugins[s.plugin]
		name := strings.clone(s.name, context.temp_allocator)
		call := Plugin_Call{app = app, plugin = s.plugin, ctx = context, budget = PLUGIN_RUN_STEPS, running = true}
		luau.lua_callbacks(p.state).userdata = &call
		T := p.thread
		_ = luau.lua_rawgeti(T, luau.REGISTRYINDEX, s.ref)
		p.limited = true
		status := luau.lua_pcall(T, 0, 0, 0)
		p.limited = false
		luau.lua_callbacks(p.state).userdata = nil
		why := plugin_error_text(T) if status != luau.OK else ""
		luau.lua_settop(T, 0)
		ps.runs += 1
		ps.steps += call.ran
		if call.gpu_failed do return false
		if status != luau.OK {
			ps.errors += 1
			delete(p.error)
			p.error = strings.clone(why)
			report(app, nil, {.Warning}, "Plugin %s stopped after %d step%s: %s", name, call.ran, "" if call.ran == 1 else "s", why)
			return true
		}
		delete(p.error)
		p.error = ""
		if !call.noted do report(app, nil, {}, "Ran plugin %s: %d step%s", name, call.ran, "" if call.ran == 1 else "s")
		return true
	}
}

plugins_failed :: proc(app: ^App) -> (n: int) {
	for p in app.plugins.plugins do n += int(p.state == nil)
	return
}

// ", 1 failed (bevel.luau:3: ...)" for a note, or "".
@(private = "file")
plugins_failed_text :: proc(app: ^App) -> string {
	n := plugins_failed(app)
	if n == 0 do return ""
	for p in app.plugins.plugins do if p.state == nil do return fmt.tprintf(", %d failed (%s)", n, p.error)
	return ""
}

// Opens every `.luau` file in the folder, in name order, and gives each command it
// registers a slot.
@(private = "file")
plugins_open_all :: proc(app: ^App) {
	// Only the desktop builds have a Luau to open them with (plugins_folder is "" elsewhere).
	when PLUGINS_AVAILABLE {
		ps := &app.plugins
		if ps.folder == "" do return
		infos, err := folder_entries(ps.folder, context.temp_allocator)
		if err != nil do return
		slice.sort_by(infos, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
		for fi in infos {
			if fi.type != .Regular || !strings.has_suffix(fi.name, PLUGIN_EXTENSION) || strings.has_prefix(fi.name, ".") do continue
			if len(ps.plugins) == PLUGIN_FILES_MAX || fi.size > PLUGIN_SOURCE_MAX {
				ps.skipped += 1
				continue
			}
			source, read_err := os.read_entire_file(fi.fullpath, context.temp_allocator)
			p := new(Plugin)
			p.file = strings.clone(fi.name)
			append(&ps.plugins, p)
			if read_err != nil {
				p.error = fmt.aprintf("%s: cannot read it: %v", fi.name, read_err)
				ps.errors += 1
				continue
			}
			plugin_open(app, len(ps.plugins) - 1, string(source))
		}
	}
}

// Text a person reads in a panel: valid UTF-8 with no control bytes.
@(private = "file")
plugin_text_ok :: proc(s: string) -> bool {
	if !utf8.valid_string(s) do return false
	for r in s do if r < 0x20 || r == 0x7F do return false
	return true
}

when PLUGINS_AVAILABLE {
	// Makes the plugin's VM, runs its top level and keeps it, or closes it with the error
	// in `error`. Every step that can raise runs inside a protected call.
	@(private = "file")
	plugin_open :: proc(app: ^App, index: int, source: string) {
		ps := &app.plugins
		p := ps.plugins[index]
		L := luau.lua_newstate(plugin_alloc, p)
		if L == nil {
			p.error = fmt.aprintf("%s: no memory for its VM", p.file)
			ps.errors += 1
			return
		}
		p.state = L
		call := Plugin_Call{app = app, plugin = index, ctx = context, budget = PLUGIN_LOAD_STEPS}
		cb := luau.lua_callbacks(L)
		cb.userdata = &call
		cb.interrupt = plugin_interrupt
		failure := ""
		if luau.lua_cpcall(L, plugin_setup, nil) != luau.OK {
			failure = plugin_error_text(L)
		} else {
			// The bytecode, or a chunk that raises the compile error when run.
			size: c.size_t
			code := luau.luau_compile(raw_data(source), c.size_t(len(source)), nil, &size)
			// Outside the budget, so only the system running out of memory could fail them.
			p.thread = luau.lua_newthread(L)
			p.thread_ref = luau.lua_ref(L, -1)
			luau.drop(L, 1)
			luau.luaL_sandboxthread(p.thread)
			chunk := strings.clone_to_cstring(fmt.tprintf("=%s", p.file), context.temp_allocator)
			status := luau.luau_load(p.thread, chunk, code, size, 0)
			libc.free(code)
			if status == luau.OK {
				p.limited = true
				status = luau.lua_pcall(p.thread, 0, 0, 0)
				p.limited = false
			}
			if status != luau.OK do failure = plugin_error_text(p.thread)
		}
		cb.userdata = nil
		if failure == "" do return
		// Its commands go back to missing, kept by key for when it loads again.
		for &s in ps.slots do if s.plugin == index {
			delete(s.name)
			delete(s.help)
			s.name, s.help, s.plugin, s.ref = "", "", -1, 0
		}
		luau.lua_close(L)
		p.state, p.thread = nil, nil
		p.error = strings.clone(failure)
		ps.errors += 1
	}

	// The error on top of the stack as text, in the temp allocator. Only a string is
	// read: turning a number into text would allocate, outside any protected call.
	@(private = "file")
	plugin_error_text :: proc(L: ^luau.State) -> string {
		if luau.lua_type(L, -1) != .String do return "it raised an error that is not text"
		text, _ := luau.tostring(L, -1)
		return strings.clone(text, context.temp_allocator)
	}

	// Each VM's memory, counted against PLUGIN_MEMORY while one of its calls runs; a free
	// or a shrink never fails.
	@(private = "file")
	plugin_alloc :: proc "c" (ud: rawptr, ptr: rawptr, osize, nsize: c.size_t) -> rawptr {
		p := (^Plugin)(ud)
		if nsize == 0 {
			libc.free(ptr)
			p.memory -= int(osize)
			return nil
		}
		grow := int(nsize) - int(osize)
		if grow > 0 && p.limited && p.memory + grow > PLUGIN_MEMORY do return nil
		q := libc.realloc(ptr, nsize)
		if q != nil do p.memory += grow
		return q
	}

	// Counts safepoints against the call's budget. Past it, every safepoint raises again,
	// so a plugin's own pcall cannot swallow "ran too long". Never from the collector
	// (gc >= 0), where raising is not allowed.
	@(private = "file")
	plugin_interrupt :: proc "c" (L: ^luau.State, gc: c.int) {
		if gc >= 0 do return
		call := (^Plugin_Call)(luau.lua_callbacks(L).userdata)
		if call == nil do return
		call.steps += 1
		if call.steps > call.budget do luau.raise(L, "ran too long")
	}

	@(private = "file")
	plugin_call :: proc "contextless" (L: ^luau.State) -> ^Plugin_Call {
		return (^Plugin_Call)(luau.lua_callbacks(L).userdata)
	}

	// The VM's set-up, in a protected call: the libraries less what a plugin must not
	// have, a fixed random seed, the `sculpt` table and print, then the sandbox, which
	// makes them all read-only.
	@(private = "file")
	plugin_setup :: proc "c" (L: ^luau.State) -> c.int {
		luau.luaL_openlibs(L)
		for name in ([]cstring{"getfenv", "setfenv", "debug", "os"}) {
			luau.lua_pushnil(L)
			luau.setglobal(L, name)
		}
		_ = luau.getglobal(L, "math")
		_ = luau.lua_getfield(L, -1, "randomseed")
		luau.lua_pushnumber(L, 0)
		luau.lua_call(L, 1, 0)
		luau.drop(L, 1)
		luau.lua_createtable(L, 0, 6)
		Entry :: struct {
			name: cstring,
			fn:   luau.CFunction,
		}
		for e in ([]Entry{{"command", plugin_command}, {"run", plugin_script}, {"objects", plugin_objects}, {"selected", plugin_selected}, {"get", plugin_get}, {"note", plugin_note}}) {
			luau.pushcfunction(L, e.fn, e.name)
			luau.lua_setfield(L, -2, e.name)
		}
		luau.lua_setreadonly(L, -1, 1)
		luau.setglobal(L, "sculpt")
		luau.pushcfunction(L, plugin_print, "print")
		luau.setglobal(L, "print")
		luau.luaL_sandbox(L)
		return 0
	}

	// The string argument at `idx`, without turning a number into one; "" and false for
	// any other value.
	@(private = "file")
	plugin_arg_string :: proc "contextless" (L: ^luau.State, idx: c.int) -> (string, bool) {
		if luau.lua_type(L, idx) != .String do return "", false
		return luau.tostring(L, idx)
	}

	// sculpt.command{name = ..., help = ..., run = function() ... end}: at the top level
	// only. Checks everything, takes the run function's reference, and only then copies
	// the name and help to the app's heap, after which nothing raises.
	@(private = "file")
	plugin_command :: proc "c" (L: ^luau.State) -> c.int {
		call := plugin_call(L)
		context = call.ctx
		if call.running do luau.raise(L, "sculpt.command is only for a plugin's top level")
		if luau.lua_type(L, 1) != .Table do luau.raise(L, "sculpt.command takes a table: {name = ..., help = ..., run = function() ... end}")
		_ = luau.lua_getfield(L, 1, "name")
		_ = luau.lua_getfield(L, 1, "help")
		_ = luau.lua_getfield(L, 1, "run")
		name, name_ok := plugin_arg_string(L, -3)
		if !name_ok || len(name) == 0 || len(name) > PLUGIN_NAME_MAX || !plugin_text_ok(name) || strings.contains_rune(name, '/') {
			luau.raise(L, fmt.tprintf("a command's name is text of 1 to %d bytes, with no line breaks or /", PLUGIN_NAME_MAX))
		}
		help := ""
		if luau.lua_type(L, -2) != .Nil {
			ok: bool
			help, ok = plugin_arg_string(L, -2)
			if !ok || len(help) > PLUGIN_HELP_MAX || !plugin_text_ok(help) do luau.raise(L, fmt.tprintf("a command's help is text of at most %d bytes, with no line breaks", PLUGIN_HELP_MAX))
		}
		if luau.lua_type(L, -1) != .Function do luau.raise(L, "a command's run is a function")
		ps := &call.app.plugins
		file := ps.plugins[call.plugin].file
		key := fmt.tprintf("%s/%s", file, name)
		slot := -1
		for s, i in ps.slots {
			if s.key == key {
				if s.plugin >= 0 do luau.raise(L, fmt.tprintf("%s already has a command named %q", file, name))
				slot = i
			}
		}
		if slot < 0 do for s, i in ps.slots do if s.key == "" {
			slot = i
			break
		}
		if slot < 0 do luau.raise(L, fmt.tprintf("the plugins already have %d commands", PLUGIN_COMMANDS_MAX))
		ref := luau.lua_ref(L, -1)
		luau.lua_settop(L, 1)
		// Nothing below raises.
		s := &ps.slots[slot]
		if s.key == "" do s.key = strings.clone(key)
		s.name, s.help, s.plugin, s.ref = strings.clone(name), strings.clone(help), call.plugin, ref
		return 0
	}

	// sculpt.run(text): inside a command's run only. The script is read, run and let go
	// before anything is pushed or raised.
	@(private = "file")
	plugin_script :: proc "c" (L: ^luau.State) -> c.int {
		call := plugin_call(L)
		context = call.ctx
		if !call.running do luau.raise(L, "sculpt.run is only for a command's run, not a plugin's top level")
		text, ok := plugin_arg_string(L, 1)
		if !ok do luau.raise(L, "sculpt.run takes command-script text, such as \"remesh; subdivide\"")
		app := call.app
		failure, ran, gpu_ok := script_run_now(app, text, fmt.tprintf("plugin %s", app.plugins.plugins[call.plugin].file))
		call.ran += ran
		if !gpu_ok {
			call.gpu_failed = true
			luau.raise(L, "the GPU failed")
		}
		if failure != "" do luau.raise(L, failure)
		return 0
	}

	// sculpt.objects(): {name, vertices, triangles, selected, shown} for each object, in
	// the scene's order.
	@(private = "file")
	plugin_objects :: proc "c" (L: ^luau.State) -> c.int {
		call := plugin_call(L)
		context = call.ctx
		app := call.app
		luau.lua_createtable(L, c.int(len(app.scene.objects)), 0)
		for obj, i in app.scene.objects {
			luau.lua_createtable(L, 0, 5)
			luau.pushstring(L, object_label(obj))
			luau.lua_setfield(L, -2, "name")
			luau.lua_pushnumber(L, f64(object_vertex_count(obj)))
			luau.lua_setfield(L, -2, "vertices")
			luau.lua_pushnumber(L, f64(object_triangle_count(obj)))
			luau.lua_setfield(L, -2, "triangles")
			luau.lua_pushboolean(L, c.int(i == app.scene.selected))
			luau.lua_setfield(L, -2, "selected")
			luau.lua_pushboolean(L, c.int(object_shown(app, obj)))
			luau.lua_setfield(L, -2, "shown")
			luau.lua_rawseti(L, -2, c.int(i + 1))
		}
		return 1
	}

	// sculpt.selected(): the selected object's number from 1, or nil.
	@(private = "file")
	plugin_selected :: proc "c" (L: ^luau.State) -> c.int {
		call := plugin_call(L)
		at := call.app.scene.selected
		if at < 0 || at >= len(call.app.scene.objects) do luau.lua_pushnil(L)
		else do luau.lua_pushnumber(L, f64(at + 1))
		return 1
	}

	// sculpt.get(key): a setting as the settings file writes it, or a script value.
	@(private = "file")
	plugin_get :: proc "c" (L: ^luau.State) -> c.int {
		call := plugin_call(L)
		context = call.ctx
		key, ok := plugin_arg_string(L, 1)
		if !ok do luau.raise(L, "sculpt.get takes a setting's name, such as \"orbit_style\"")
		if row, found := script_setting(key); found {
			luau.pushstring(L, setting_text(call.app, row))
			return 1
		}
		for line in SETTING_LINES do if line.key == key {
			luau.pushstring(L, line.text(call.app))
			return 1
		}
		luau.raise(L, fmt.tprintf("no setting is named %q", key))
	}

	// sculpt.note(text): an information note, inside a command's run.
	@(private = "file")
	plugin_note :: proc "c" (L: ^luau.State) -> c.int {
		call := plugin_call(L)
		context = call.ctx
		if !call.running do luau.raise(L, "sculpt.note is only for a command's run")
		text, ok := plugin_arg_string(L, 1)
		if !ok || len(text) > PLUGIN_NOTE_MAX || !plugin_text_ok(text) do luau.raise(L, fmt.tprintf("sculpt.note takes text of at most %d bytes, with no line breaks", PLUGIN_NOTE_MAX))
		report(call.app, nil, {}, "%s", text)
		call.noted = true
		return 0
	}

	// print(...): one line on the console, after the plugin's file, and kept as its last
	// output for the Macros panel. Strings and numbers print as text, anything else as
	// its type's name.
	@(private = "file")
	plugin_print :: proc "c" (L: ^luau.State) -> c.int {
		call := plugin_call(L)
		context = call.ctx
		b := strings.builder_make(context.temp_allocator)
		for i in 1 ..= luau.lua_gettop(L) {
			if i > 1 do strings.write_byte(&b, '\t')
			#partial switch tp := luau.lua_type(L, i); tp {
			case .String:
				s, _ := luau.tostring(L, i)
				strings.write_string(&b, s)
			case .Number:
				fmt.sbprintf(&b, "%v", luau.lua_tonumberx(L, i, nil))
			case .Boolean:
				strings.write_string(&b, "true" if luau.lua_toboolean(L, i) != 0 else "false")
			case:
				strings.write_string(&b, string(luau.lua_typename(L, tp)))
			}
		}
		p := call.app.plugins.plugins[call.plugin]
		line := strings.to_string(b)
		fmt.printfln("plugin %s: %s", p.file, line)
		delete(p.output)
		p.output = strings.clone(line)
		return 0
	}
}
