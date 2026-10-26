package main

import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "core:time"

import "../sculpt"

// Command scripts (README "Command scripts"): plain text, one statement a line or `;`
// between them, `#` to the end of a line a comment. A statement is a command of the
// registry by name (`remesh`, `brush clay`, `wireframe on`), a setting (`set
// orbit_style turntable`, `set rebuild_even 500000`), or `wait N` and `select N`.
// Everything a statement does goes through what the interface calls, so a script drives
// exactly the path a user does. A script is read and checked whole before any of it runs:
// a script with an error in it runs none of it.

// Errors listed at most, so a file that is not a script at all does not fill the screen.
SCRIPT_ERRORS_MAX :: 20
// The longest a `wait` lasts: ten minutes at 60 frames a second, longer than any run.
SCRIPT_WAIT_MAX :: 36_000

Script_Kind :: enum u8 {
	Command,
	Set,
	Line, // a setting with more to it than one field (SETTING_LINES)
	Wait,
	Select,
}

// A command that is on or off (one with `checked`) can be told which: it then runs only
// when that changes it.
Script_Toggle :: enum u8 {
	Flip,
	On,
	Off,
}

Script_Statement :: struct {
	kind:    Script_Kind,
	line:    int, // in the text, from 1
	command: Command_Id,
	arg:     int,
	toggle:  Script_Toggle,
	setting: Setting, // .Set: the row, from SETTINGS or SCRIPT_VALUES
	value:   f64, // ...and its value, as setting_parse gives it
	set:     Setting_Line, // .Line: the line row
	line_value: Setting_Line_Value, // ...and its value
	count:   int, // .Wait: frames; .Select: the object, from 1
}

Script_Error :: struct {
	line:    int,
	message: string, // heap
}

// A script as read: its statements, in heap memory since what they run may free the
// temp allocator, or what is wrong with it.
Script :: struct {
	source:      string, // a file's path, or "--script"; heap
	statements: [dynamic]Script_Statement,
	errors:     [dynamic]Script_Error,
	more:       int, // errors past SCRIPT_ERRORS_MAX, counted only
}

// Values a script sets that are not remembered between runs: what a panel holds for the
// command that reads it (Smooth all's steps, Mirror and weld's side, Extract's thickness),
// and switches that were start-up flags. The same rows as SETTINGS, read the same way,
// never written to the settings file.
@(private = "file")
U :: offset_of(App, ui)

@(rodata)
SCRIPT_VALUES := [?]Setting {
	{"smooth_steps", U + offset_of(Ui_State, smooth_steps), i32, 1, 100},
	{"smooth_strength", U + offset_of(Ui_State, smooth_strength), f32, 0, 1},
	{"mirror_axis", U + offset_of(Ui_State, mirror_axis), i32, 0, 2},
	{"mirror_negative", U + offset_of(Ui_State, mirror_negative), bool, 0, 0},
	{"extract_thickness", U + offset_of(Ui_State, boolean) + offset_of(Boolean_State, thickness), f32, 0.002, 0.2},
	{"live_boolean", U + offset_of(Ui_State, boolean) + offset_of(Boolean_State, live), bool, 0, 0},
	{"hd_window", offset_of(App, hd_window_vertices), int, 10_000, 16_000_000},
	{"studio_samples", offset_of(App, studio_samples), i32, 1, STUDIO_SAMPLES_MAX},
	{"cloth_mode", offset_of(App, brush) + offset_of(Brush_Settings, cloth_mode), sculpt.Cloth_Mode, 0, 0},
}

// A name as scripts write it: lower case, `-` and `_` alike.
script_name :: proc(name: string) -> string {
	lower := strings.to_lower(name, context.temp_allocator)
	out, _ := strings.replace_all(lower, "-", "_", context.temp_allocator)
	return out
}

// The command a script names `name`; .None for none.
script_command :: proc(name: string) -> Command_Id {
	want := script_name(name)
	for id in Command_Id do if id != .None && script_name(fmt.tprint(id)) == want do return id
	return .None
}

// The setting row a script names `name`, from either table.
script_setting :: proc(name: string) -> (Setting, bool) {
	for s in SETTINGS do if s.key == name do return s, true
	for s in SCRIPT_VALUES do if s.key == name do return s, true
	return {}, false
}

// Reads and checks `text` whole. The script's memory is the heap's (script_destroy).
script_parse :: proc(text, source: string) -> (s: Script) {
	s.source = strings.clone(source)
	line := 1
	rest := text
	for len(rest) > 0 {
		words, next, newlines, quote_ok := script_statement_words(rest)
		if !quote_ok {
			script_error(&s, line, "a quote is not closed")
		} else if len(words) > 0 {
			script_statement(&s, line, words)
		}
		line += newlines
		rest = next
	}
	return
}

script_destroy :: proc(s: ^Script) {
	delete(s.source)
	delete(s.statements)
	for e in s.errors do delete(e.message)
	delete(s.errors)
	s^ = {}
}

// What is wrong with the script, one error a line ("source:line: message"), in the temp
// allocator; "" when nothing is.
script_report :: proc(s: ^Script) -> string {
	b := strings.builder_make(context.temp_allocator)
	for e in s.errors do fmt.sbprintfln(&b, "script: %s:%d: %s", s.source, e.line, e.message)
	if s.more > 0 do fmt.sbprintfln(&b, "script: %s: %d more errors", s.source, s.more)
	return strings.to_string(b)
}

@(private = "file")
script_error :: proc(s: ^Script, line: int, format: string, args: ..any) {
	if len(s.errors) == SCRIPT_ERRORS_MAX {
		s.more += 1
		return
	}
	append(&s.errors, Script_Error{line, fmt.aprintf(format, ..args)})
}

// The words of the statement at the start of `text`, up to a `;` or the end of a line
// (neither inside quotes), with a comment cut off; the text after it, and how many
// lines that statement's end moved on (1 at a line's end, 0 at a `;`). Quoted text is
// one word, without its quotes. False when a quote is not closed by the line's end.
@(private = "file")
script_statement_words :: proc(text: string) -> (words: []string, rest: string, newlines: int, ok: bool) {
	out := make([dynamic]string, 0, 4, context.temp_allocator)
	i := 0
	ok = true
	for i < len(text) {
		c := text[i]
		switch c {
		case '\n':
			return out[:], text[i + 1:], 1, ok
		case ';':
			return out[:], text[i + 1:], 0, ok
		case '#':
			// The comment runs to the line's end, which then ends the statement.
			for i < len(text) && text[i] != '\n' do i += 1
			continue
		case ' ', '\t', '\r':
			i += 1
		case '"':
			end := i + 1
			for end < len(text) && text[end] != '"' && text[end] != '\n' do end += 1
			if end == len(text) || text[end] != '"' {
				ok = false
				i = end
				continue
			}
			append(&out, text[i + 1:end])
			i = end + 1
		case:
			start := i
			for i < len(text) && !strings.contains_rune(" \t\r\n;#\"", rune(text[i])) do i += 1
			append(&out, text[start:i])
		}
	}
	return out[:], "", 0, ok
}

// Reads one statement's words into the script, or says what is wrong with them.
@(private = "file")
script_statement :: proc(s: ^Script, line: int, words: []string) {
	name := script_name(words[0])
	args := words[1:]
	st := Script_Statement {
		line = line,
	}
	switch name {
	case "set":
		if len(args) < 2 {
			script_error(s, line, "set takes a setting and its value")
			return
		}
		key := script_name(args[0])
		if row, ok := script_setting(key); ok {
			if len(args) != 2 {
				script_error(s, line, "%s takes one value", key)
				return
			}
			v, v_ok := setting_parse(row, args[1], strict = true)
			if !v_ok {
				script_error(s, line, "%q is not a value of %s (%s)", args[1], key, script_setting_kind(row))
				return
			}
			st.kind, st.setting, st.value = .Set, row, v
		} else if set := setting_line(key); set.parse != nil {
			v, v_ok := set.parse(args[1:])
			if !v_ok {
				script_error(s, line, "%q is not a value of %s", strings.join(args[1:], " ", context.temp_allocator), key)
				return
			}
			st.kind, st.set, st.line_value = .Line, set, v
		} else {
			script_error(s, line, "no setting is named %q", args[0])
			return
		}
	case "wait", "select":
		n, n_ok := 0, false
		if len(args) == 1 do n, n_ok = strconv.parse_int(args[0])
		top := SCRIPT_WAIT_MAX if name == "wait" else max(int)
		if !n_ok || n < 1 || n > top {
			script_error(s, line, "%s takes a whole number from 1%s", name, " to 36000" if name == "wait" else "")
			return
		}
		st.kind, st.count = .Wait if name == "wait" else .Select, n
	case:
		id := script_command(name)
		if id == .None {
			script_error(s, line, "no command is named %q", words[0])
			return
		}
		if !script_allows(id) {
			script_error(s, line, "%s asks for a file, a typed answer or a pick on screen, which a script cannot give", name)
			return
		}
		c := COMMANDS[id]
		st.kind, st.command = .Command, id
		switch {
		case c.args > 0:
			if len(args) != 1 {
				script_error(s, line, "%s takes one of: %s", name, script_choices(id))
				return
			}
			want := script_name(args[0])
			st.arg = -1
			for a in 0 ..< c.args do if script_name(command_arg_name(id, a)) == want do st.arg = a
			if st.arg < 0 {
				script_error(s, line, "%s takes one of: %s; not %q", name, script_choices(id), args[0])
				return
			}
		case c.checked != nil && len(args) == 1:
			switch script_name(args[0]) {
			case "on":  st.toggle = .On
			case "off": st.toggle = .Off
			case:
				script_error(s, line, "%s takes on or off, or nothing to turn it over", name)
				return
			}
		case len(args) > 0:
			script_error(s, line, "%s takes nothing", name)
			return
		}
	}
	append(&s.statements, st)
}

// What a row's values are, for an error.
@(private = "file")
script_setting_kind :: proc(row: Setting) -> string {
	switch row.type {
	case bool: return "on or off"
	case f32:  return fmt.tprintf("a number from %g to %g", row.lo, row.hi) if row.lo < row.hi else "a number"
	case i32, int: return fmt.tprintf("a whole number from %g to %g", row.lo, row.hi) if row.lo < row.hi else "a whole number"
	}
	b := strings.builder_make(context.temp_allocator)
	for name, i in reflect.enum_field_names(row.type) {
		if i > 0 do strings.write_string(&b, ", ")
		strings.write_string(&b, script_name(name))
	}
	return strings.to_string(b)
}

// A command's choices as a script names them, for an error.
@(private = "file")
script_choices :: proc(id: Command_Id) -> string {
	b := strings.builder_make(context.temp_allocator)
	for a in 0 ..< COMMANDS[id].args {
		if a > 0 do strings.write_string(&b, ", ")
		strings.write_string(&b, script_name(command_arg_name(id, a)))
	}
	return strings.to_string(b)
}

// Sets what a .Set or .Line statement sets.
script_set :: proc(app: ^App, st: Script_Statement) {
	#partial switch st.kind {
	case .Set:  setting_write(app, st.setting, st.value)
	case .Line: st.set.apply(app, st.line_value)
	}
}

// Whether a script may run the command: not one that opens a file dialog, a text field or
// a menu to pick from, which would wait on a person a script does not have.
script_allows :: proc(id: Command_Id) -> bool {
	#partial switch id {
	case .Open_Scene, .Save_Scene, .Save_Scene_As, .Save_Scene_Copy, .Scene_Versions, .Import_Mesh, .Export_Mesh, .Screenshot:
		return false
	case .Rename_Object, .Command_Palette, .Pie, .Pie_Editor, .Brush_Pie:
		return false
	// The last stroke replays where the pointer is, and the last autosave is whatever an
	// earlier run left: neither is something a script can say beforehand.
	case .Replay_Stroke, .Open_Last_Autosave:
		return false
	}
	return true
}

// A script being run (--run, --script): where it has got to, and how long it has taken.
Script_Run :: struct {
	script:   Script,
	next:     int, // the statement to run next
	waiting:  int, // frames a `wait` has still to let pass
	running:  bool,
	scripted: bool, // a run without a person: a failure ends it with code 2
	started:  bool, // the viewport had its size, and the first statement ran
	failed:   bool,
	frames:   int, // frames from the first to the one it finished on
	fp:       u64, // the scene's fingerprint as the script began
}

// Reads the script `--run` names or `--script` gives, for the frame loop to run once the
// viewport has its size. False, with every error printed, when there is one: nothing of
// it runs then.
script_load :: proc(app: ^App, file, inline: string, scripted: bool) -> bool {
	if file == "" && inline == "" do return true
	if file != "" && inline != "" {
		fmt.eprintln("script: give --run or --script, not both")
		return false
	}
	text, source := inline, "--script"
	if file != "" {
		data, err := os.read_entire_file(file, context.temp_allocator)
		if err != nil {
			fmt.eprintfln("script: cannot read %s: %v", file, err)
			return false
		}
		text, source = string(data), file
	}
	r := &app.script
	r.script = script_parse(text, source)
	if len(r.script.errors) > 0 {
		fmt.eprint(script_report(&r.script))
		script_unload(app)
		return false
	}
	r.running, r.scripted = true, scripted
	return true
}

script_unload :: proc(app: ^App) {
	script_destroy(&app.script.script)
	app.script = {}
}

// Runs the script's statements at the start of a frame, where scene commands and file
// requests apply, applying what each queues at once: only `wait` lets frames pass. It
// starts once the viewport has its size, so statements that look at the view see the
// one the first frame laid out. False only on a GPU failure, which ends the run.
script_frame :: proc(app: ^App) -> bool {
	r := &app.script
	if !r.running do return true
	if !r.started {
		if app.ui.viewport_size.x <= 0 || app.ui.viewport_size.y <= 0 do return true
		r.started, r.fp = true, scene_fingerprint(app)
	}
	if r.waiting > 0 {
		r.waiting -= 1
		return true
	}
	for r.next < len(r.script.statements) {
		st := r.script.statements[r.next]
		r.next += 1
		if st.kind == .Wait {
			r.waiting = st.count - 1
			return true
		}
		failure, ok := script_step(app, st)
		if !ok do return false
		if failure != "" {
			script_fail(app, st, failure)
			return true
		}
	}
	script_finish(app)
	return true
}

// Runs one statement other than `wait`: what went wrong when it did nothing, "" when it
// did; false only on a GPU failure.
@(private = "file")
script_step :: proc(app: ^App, st: Script_Statement) -> (failure: string, ok: bool) {
	switch st.kind {
	case .Wait:
	case .Set, .Line:
		script_set(app, st)
	case .Select:
		n := len(app.scene.objects)
		if st.count > n do return fmt.tprintf("the scene has %d object%s", n, "" if n == 1 else "s"), true
		select_only(app, st.count - 1)
	case .Command:
		c := COMMANDS[st.command]
		if st.toggle != .Flip && c.checked != nil && c.checked(app, st.arg) == (st.toggle == .On) do return "", true
		if !command_enabled(app, st.command, st.arg) do return "it is not available now", true
		// New scene asks for a second run when there is work to lose; a script asking for
		// it is asking twice.
		if st.command == .New_Scene do app.kit.new_armed, app.kit.new_armed_at = st.arg + 1, max(app.kit.ctx.time, 1e-6)
		start := time.tick_now()
		_ = command_run(app, st.command, st.arg)
		// What the command queued for the next frame applies now, as the frame would. An
		// operation that refuses often only says so in the log: one that left the scene
		// as it was did nothing.
		if cmd := app.ui.scene_command; cmd.kind != .None {
			app.ui.scene_command = {}
			autosave_settle(app)
			before := script_scene_state(app)
			if !scene_run(app, cmd) do return "", false
			if script_scene_state(app) == before do return "it left the scene as it was (the log says why)", true
		}
		if req, taken := file_take(app); taken {
			autosave_settle(app)
			inspector_drags_end(app)
			applied := file_apply(app, req)
			file_request_free(req)
			if !applied do return "", false
		}
		scene_folders_normalize(app)
		scene_selection_fix(app)
		// A refusal says so in a warning note.
		if .Warning in app.result.flags && time.tick_diff(start, app.result.at) >= 0 do return app.result.text, true
	}
	return "", true
}

// What tells whether a scene command changed anything: the scene's fingerprint (its
// History, objects, levels and placements), and the selected object's HD window and
// dynamic topology, which opening and turning on leave out of it.
@(private = "file")
script_scene_state :: proc(app: ^App) -> [3]u64 {
	obj := selected_object(app)
	return {scene_fingerprint(app), u64(obj != nil && object_in_hd(obj)), u64(obj != nil && object_dynamic(obj))}
}

// Says the script stopped at `st` and why: on the console and with exit code 2 for a
// run without a person; in a warning note for an interactive one, which keeps what ran
// as its set-up.
@(private = "file")
script_fail :: proc(app: ^App, st: Script_Statement, why: string) {
	r := &app.script
	name := script_statement_name(st)
	r.failed = true
	r.next -= 1 // it did not run
	if r.scripted {
		fmt.eprintfln("script: %s:%d: %s did nothing: %s", r.script.source, st.line, name, why)
		r.running = false
		app.running = false
		return
	}
	// The reason may be the note script_finish lets go.
	reason := strings.clone(why, context.temp_allocator)
	script_finish(app)
	report(app, nil, {.Warning}, "Script stopped at line %d: %s did nothing (%s)", st.line, name, reason)
}

@(private = "file")
script_statement_name :: proc(st: Script_Statement) -> string {
	switch st.kind {
	case .Command:   return script_name(fmt.tprint(st.command))
	case .Set:       return fmt.tprintf("set %s", st.setting.key)
	case .Line:      return fmt.tprintf("set %s", st.set.key)
	case .Wait:      return "wait"
	case .Select:    return "select"
	}
	return ""
}

// The script is done, and was setting up the run: what it made is where the run starts.
// Nothing it did is in the History or counted in the stats, the scene stays as unsaved or
// as saved as it began, and the frames of `--ui-events` count from here (main.odin counts
// its own frames from here too).
@(private = "file")
script_finish :: proc(app: ^App) {
	r := &app.script
	r.running = false
	history_clear(&app.history)
	app.adjustable.op = .None
	results_destroy(app)
	camera_history_clear(app)
	fp := scene_fingerprint(app)
	if app.autosave.clean == r.fp do app.autosave.clean = fp
	if app.saved_fp == r.fp do app.saved_fp = fp
	stats_restart(&app.stats)
	app.kit.events_offset = r.frames
}
