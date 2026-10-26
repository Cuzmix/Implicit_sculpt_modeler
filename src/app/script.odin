package main

import "core:fmt"
import "core:reflect"
import "core:strconv"
import "core:strings"

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
