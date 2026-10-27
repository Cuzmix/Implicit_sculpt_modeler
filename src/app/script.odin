package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import "../camera"
import "../geom"
import "../render"
import "../sculpt"

// Command scripts (README "Command scripts"): plain text, one statement a line or `;`
// between them, `#` to the end of a line a comment. A statement is a command of the
// registry by name (`remesh`, `brush clay`, `wireframe on`), a setting (`set
// orbit_style turntable`, `set rebuild_even 500000`), `wait N` and `select N`, or one of
// the verbs for what has no command (SCRIPT_VERBS: `move 0.9 0 0`, `hide -x`).
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
	Verb,
}

// What a script can do that no command does with no more than a choice: an object's
// place, a plane through its middle, a shape at a spot on screen. Each is a short
// procedure calling what the tool or panel it stands for calls (script_verb).
Script_Verb :: enum u8 {
	Move,
	Rotate,
	Boolean,
	Slice,
	Hide,
	Mask_Rect,
	Project,
	Draw_Curve,
	Insert_Middle,
	Falloff,
	Focal,
	Alpha,
	Layer,
	Install_Pack,
	Matcap,
	Preset,
	Pack_Mesh,
	Make_Pack,
	Group_Material,
	Texture,
	Knife,
	Environment,
	Render_Focus,
}

// Each verb's name and what it takes, for errors and the README.
@(rodata)
SCRIPT_VERBS := [Script_Verb]struct {
	name:  string,
	takes: string,
} {
	.Move          = {"move", "three numbers: where the selected object's middle goes, x y z"},
	.Rotate        = {"rotate", "three numbers: the selected object's turn in degrees about x, y and z"},
	.Boolean       = {"boolean", "none, union, subtract or intersect"},
	.Slice         = {"slice", "x, y or z: the axis the cut through the middle goes across"},
	.Hide          = {"hide", "x, y or z to hide the + side of the middle, -x, -y or -z the - side"},
	.Mask_Rect     = {"mask_rect", "four numbers from 0 to 1: the left, top, right and bottom of the view to mask"},
	.Project       = {"project", "the number of the object to project from, counting from 1"},
	.Draw_Curve    = {"draw_curve", "tube, stitches or zipper"},
	.Insert_Middle = {"insert_middle", "sphere, cube, cylinder, cone or torus"},
	.Falloff       = {"falloff", "smooth, linear, sharp, firm or flat"},
	.Focal         = {"focal", "a number from -100 to 100: every brush's focal shift"},
	.Alpha         = {"alpha", "an alpha's name (a built-in's, or mine/NAME or PACK/NAME from the library) or an image file"},
	.Layer         = {"layer", "the layer's number counting from 1 at the bottom, its strength from -1 to 2, and hidden to hide it"},
	.Install_Pack  = {"install_pack", "a content pack file (.sculptpack), which replaces an installed pack of its name and author"},
	.Matcap        = {"matcap", "an image file of a lit sphere"},
	.Preset        = {"preset", "a brush preset's name (yours, or PACK/NAME for a content pack's), or none for the plain brush"},
	.Pack_Mesh     = {"pack_mesh", "a content pack's mesh as PACK/NAME, added as a new object"},
	.Make_Pack     = {"make_pack", "a .sculptpack file to write your own alphas and presets to, named after the file"},
	.Group_Material = {"group_material", "a polygroup's number from 1, given the material `set material` chose, and off to give it the object's again"},
	.Texture       = {"texture", "base_color, orm or normal, then an image file to load as that map of the selected object"},
	.Knife         = {"knife", "x, y or z to cut away the + side of the middle, -x, -y or -z the - side"},
	.Environment   = {"environment", "a panorama file (Radiance .hdr, PNG or JPEG, twice as wide as tall) to light with, picking Image"},
	.Render_Focus  = {"render_focus", "three numbers, the point x y z for depth of field to focus on, or pivot to focus on what the view turns about"},
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
	count:   int, // .Wait: frames; .Select and .Verb's project: the object, from 1; layer's layer, from 1
	verb:    Script_Verb,
	numbers: [4]f32, // .Verb: move and rotate's x y z, mask_rect's edges, layer's strength
	flip:    bool, // .Verb: hide's - side, a hidden layer
	text:    string, // .Verb: alpha's name or file, matcap's file; .Line: a pack's material, `<id>/<name>`; heap
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
	{"boolean_vertices", U + offset_of(Ui_State, boolean) + offset_of(Boolean_State, vertices), i32, 10_000, 20_000_000},
	{"extract_thickness", U + offset_of(Ui_State, boolean) + offset_of(Boolean_State, thickness), f32, 0.002, 0.2},
	{"hd_window", offset_of(App, hd_window_vertices), int, 10_000, 16_000_000},
	{"studio_samples", offset_of(App, studio_samples), i32, 1, STUDIO_SAMPLES_MAX},
	{"live_ao_reach", offset_of(App, live_ao_reach), f32, LIVE_AO_REACH_MIN, LIVE_AO_REACH_MAX},
	{"cloth_mode", offset_of(App, brush) + offset_of(Brush_Settings, cloth_mode), sculpt.Cloth_Mode, 0, 0},
}

// Values with more to them that only scripts set, as SETTING_LINES are set: the scene's
// lights' colours, and the whole set fixed to the scene or not, as `lights_fixed` did
// before each light had its own space (lights_fixed_set).
@(rodata)
SCRIPT_LINES := [?]Setting_Line {
	{
		"light1_color",
		rgb_parse,
		proc(app: ^App, v: Setting_Line_Value) {app.scene.lights.lights[0].color = v.([3]f32)},
		proc(app: ^App) -> string {return rgb_text(app.scene.lights.lights[0].color)},
	},
	{
		"light2_color",
		rgb_parse,
		proc(app: ^App, v: Setting_Line_Value) {app.scene.lights.lights[1].color = v.([3]f32)},
		proc(app: ^App) -> string {return rgb_text(app.scene.lights.lights[1].color)},
	},
	{
		"light3_color",
		rgb_parse,
		proc(app: ^App, v: Setting_Line_Value) {app.scene.lights.lights[2].color = v.([3]f32)},
		proc(app: ^App) -> string {return rgb_text(app.scene.lights.lights[2].color)},
	},
	{
		"light4_color",
		rgb_parse,
		proc(app: ^App, v: Setting_Line_Value) {app.scene.lights.lights[3].color = v.([3]f32)},
		proc(app: ^App) -> string {return rgb_text(app.scene.lights.lights[3].color)},
	},
	{
		"light5_color",
		rgb_parse,
		proc(app: ^App, v: Setting_Line_Value) {app.scene.lights.lights[4].color = v.([3]f32)},
		proc(app: ^App) -> string {return rgb_text(app.scene.lights.lights[4].color)},
	},
	{
		"light6_color",
		rgb_parse,
		proc(app: ^App, v: Setting_Line_Value) {app.scene.lights.lights[5].color = v.([3]f32)},
		proc(app: ^App) -> string {return rgb_text(app.scene.lights.lights[5].color)},
	},
	{
		"light7_color",
		rgb_parse,
		proc(app: ^App, v: Setting_Line_Value) {app.scene.lights.lights[6].color = v.([3]f32)},
		proc(app: ^App) -> string {return rgb_text(app.scene.lights.lights[6].color)},
	},
	{
		"light8_color",
		rgb_parse,
		proc(app: ^App, v: Setting_Line_Value) {app.scene.lights.lights[7].color = v.([3]f32)},
		proc(app: ^App) -> string {return rgb_text(app.scene.lights.lights[7].color)},
	},
	{
		"lights_fixed",
		proc(f: []string) -> (Setting_Line_Value, bool) {
			if len(f) != 1 do return nil, false
			v, ok := setting_parse({type = bool}, f[0], strict = true)
			return int(v), ok
		},
		proc(app: ^App, v: Setting_Line_Value) {lights_fixed_set(app, &app.scene.lights, v.(int) == 1)},
		proc(app: ^App) -> string {return "1" if lights_fixed(app) else "0"},
	},
}

// The value with more to it a script names `key`, from SETTING_LINES or SCRIPT_LINES;
// none (no parse) for none.
script_line :: proc(key: string) -> Setting_Line {
	if line := setting_line(key); line.parse != nil do return line
	for line in SCRIPT_LINES do if line.key == key do return line
	return {}
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

// The setting row a script names `name`: the scene's lights first, whose names the
// settings file gives the starting lights, then either table.
script_setting :: proc(name: string) -> (Setting, bool) {
	// The first two lights' strengths by the names they had when there were only a key
	// and a fill, so older scripts still run.
	name := name
	switch name {
	case "light_key":  name = "light1_strength"
	case "light_fill": name = "light2_strength"
	}
	if s, ok := light_setting(offset_of(App, scene) + offset_of(Scene, lights), name); ok do return s, true
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
	for st in s.statements do delete(st.text)
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
		} else if set := script_line(key); key == "material" && strings.contains_rune(strings.join(args[1:], " ", context.temp_allocator), '/') {
			// A content pack's material, looked up when the line runs, since a pack an
			// earlier line installs is not there yet.
			st.kind, st.set, st.text = .Line, set, strings.clone(preset_unescape(strings.join(args[1:], " ", context.temp_allocator)))
		} else if set.parse != nil {
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
		if verb, is_verb := script_verb_named(name); is_verb {
			st.kind, st.verb = .Verb, verb
			if !script_verb_read(&st, args) {
				script_error(s, line, "%s takes %s", name, SCRIPT_VERBS[verb].takes)
				return
			}
			break
		}
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

// The verb a script names `name`.
script_verb_named :: proc(name: string) -> (Script_Verb, bool) {
	for v in Script_Verb do if SCRIPT_VERBS[v].name == name do return v, true
	return {}, false
}

// Reads a verb's arguments into `st`; false when they are not what it takes.
@(private = "file")
script_verb_read :: proc(st: ^Script_Statement, args: []string) -> bool {
	// The place of `word` among `names`, as scripts write them; -1 for none.
	choice :: proc(word: string, names: []string) -> int {
		for n, i in names do if script_name(n) == script_name(word) do return i
		return -1
	}
	numbers :: proc(st: ^Script_Statement, args: []string, n: int, lo, hi: f32) -> bool {
		if len(args) != n do return false
		for a, i in args {
			v, ok := strconv.parse_f32(a)
			if !ok || !(v >= lo && v <= hi) do return false
			st.numbers[i] = v
		}
		return true
	}
	AXES :: []string{"x", "y", "z"}
	#partial switch st.verb {
	case .Move:
		return numbers(st, args, 3, -1e4, 1e4)
	case .Rotate:
		return numbers(st, args, 3, -1e6, 1e6)
	case .Mask_Rect:
		return numbers(st, args, 4, 0, 1) && st.numbers[0] != st.numbers[2] && st.numbers[1] != st.numbers[3]
	case .Render_Focus:
		st.flip = len(args) == 1 && script_name(args[0]) == "pivot"
		return st.flip || numbers(st, args, 3, -1e4, 1e4)
	case .Focal:
		return numbers(st, args, 1, sculpt.FOCAL_MIN, sculpt.FOCAL_MAX)
	case .Project:
		if len(args) != 1 do return false
		n, ok := strconv.parse_int(args[0])
		st.count = n
		return ok && n >= 1
	case .Alpha, .Install_Pack, .Matcap, .Preset, .Pack_Mesh, .Make_Pack, .Environment:
		// A name or path may have spaces: it is the rest of the line.
		if len(args) == 0 do return false
		st.text = strings.join(args, " ")
		return true
	case .Texture:
		// The file may have spaces: it is the rest of the line.
		if len(args) < 2 do return false
		st.arg = choice(args[0], reflect.enum_field_names(render.Texture_Map))
		if st.arg < 0 do return false
		st.text = strings.join(args[1:], " ")
		return true
	case .Group_Material:
		if len(args) < 1 || len(args) > 2 do return false
		n, ok := strconv.parse_int(args[0])
		st.count = n
		st.flip = len(args) == 2
		return ok && n >= 1 && n <= int(max(u16)) && (len(args) == 1 || script_name(args[1]) == "off")
	case .Layer:
		if len(args) < 2 || len(args) > 3 do return false
		n, ok := strconv.parse_int(args[0])
		st.count = n
		st.flip = len(args) == 3
		return ok && n >= 1 && numbers(st, args[1:2], 1, -1, 2) && (len(args) == 2 || script_name(args[2]) == "hidden")
	}
	if len(args) != 1 do return false
	word := args[0]
	#partial switch st.verb {
	case .Slice:
		st.arg = choice(word, AXES)
	case .Hide, .Knife:
		st.flip = strings.has_prefix(word, "-")
		st.arg = choice(strings.trim_prefix(word, "-"), AXES)
	case .Boolean:
		st.arg = choice(word, reflect.enum_field_names(Boolean_Mode))
	case .Draw_Curve:
		st.arg = choice(word, reflect.enum_field_names(Curve_Kind))
	case .Insert_Middle:
		st.arg = choice(word, reflect.enum_field_names(geom.Primitive))
	case .Falloff:
		st.arg = -1
		for preset, i in FALLOFF_PRESETS do if script_name(string(preset.label)) == script_name(word) do st.arg = i
	}
	return st.arg >= 0
}

// Does what a verb says, as the tool or panel it stands for would: what went wrong when
// it did nothing, "" when it did; false only on a GPU failure.
@(private = "file")
script_verb :: proc(app: ^App, st: Script_Statement) -> (failure: string, ok: bool) {
	obj := selected_object(app)
	size := app.ui.viewport_size
	before := script_scene_state(app)
	switch st.verb {
	case .Falloff:
		preset := FALLOFF_PRESETS[st.arg]
		for &f in app.brush.falloffs do f.drawn, f.curve = preset.drawn, preset.curve
		return "", true
	case .Focal:
		for &f in app.brush.falloffs do f.focal = st.numbers[0]
		return "", true
	case .Alpha:
		if !alpha_select(app, st.text) do return fmt.tprintf("no alpha is named %q and no image could be read there", st.text), true
		return "", true
	case .Matcap:
		if !matcap_load(app, st.text) do return fmt.tprintf("no image could be read as a MatCap at %q", st.text), true
		return "", true
	case .Render_Focus:
		// As Pick focus and Focus on the pivot do.
		if st.flip do app.focus = nil
		else do app.focus = st.numbers.xyz
		return "", true
	case .Environment:
		// Waited for, so the next line (a dump, say) sees it.
		if why := environment_load(app, st.text, wait = true); why != "" do return why, true
		app.env.kind = .Image
		return "", true
	case .Texture:
		// As the Textures section's Load button does, in place so the next line sees it.
		if why := texture_load(app, obj, render.Texture_Map(st.arg), st.text); why != "" do return why, true
		return "", true
	case .Install_Pack:
		// In place, not on the install thread, so the next line sees the pack.
		if app.library.folder == "" do return "this run keeps no library: give it --settings-file", true
		if pack_busy(app) do return "another pack is being installed", true
		if failed := pack_install_finish(app, pack_unpack(st.text, app.library.folder), replace = true); failed != "" do return failed, true
		return "", true
	case .Preset:
		// As picking it in the Preset section does.
		if script_name(st.text) == "none" {
			command_run(app, .Brush, int(app.brush.kind))
			return "", true
		}
		n := preset_by_ref(app, st.text)
		if n == 0 do return fmt.tprintf("no preset is named %q", st.text), true
		preset_use(app, n)
		return "", true
	case .Make_Pack:
		if failed := pack_make(app, st.text); failed != "" do return failed, true
		return "", true
	case .Pack_Mesh:
		// As Add object does with the mesh picked, in place so the next line sees it.
		j := pack_mesh_by_ref(app, st.text)
		if j < 0 do return fmt.tprintf("no content pack has a mesh named %q", st.text), true
		if !scene_run(app, {kind = .Add, mesh = j + 1}) do return "", false
	case .Project:
		if st.count > len(app.scene.objects) do return fmt.tprintf("the scene has %d object%s", len(app.scene.objects), "" if len(app.scene.objects) == 1 else "s"), true
		from := app.scene.objects[st.count - 1]
		if from == obj do return "it is the selected object", true
		project_detail(app, obj, from)
	case .Draw_Curve:
		// A gentle wave across the middle of the view, from 30% to 70% of its width.
		app.curve.kind = Curve_Kind(st.arg)
		for i in 0 ..= 40 do curve_add_point(app, {size.x * (0.3 + 0.01 * f32(i)), size.y * (0.5 + 0.08 * math.sin(f32(i) / 6))}, size)
		if !curve_make(app) do return "", false
	case .Insert_Middle:
		app.insert.shape = geom.Primitive(st.arg)
		origin, dir := mouse_ray(app.camera, 0.5 * size, size)
		_, hit, n, on := scene_raycast_surface(app, origin, dir)
		if !on do return "no surface is under the middle of the view", true
		if !insert_make(app, hit, n, app.brush.radius_px * camera.orbit_world_per_px(app.camera, hit, size.y)) do return "", false
	case .Move, .Rotate, .Boolean, .Slice, .Knife, .Hide, .Mask_Rect, .Layer, .Group_Material:
		if obj == nil do return "nothing is selected", true
		switch st.verb {
		case .Move, .Rotate:
			// As the Transform values do: one change, one undo step.
			from := obj.transform
			if st.verb == .Move do obj.transform.position = st.numbers.xyz
			else do for i in 0 ..< 3 do obj.transform.rotation[i] = math.mod(st.numbers[i] + 540, 360) - 180
			if obj.transform == from do return "", true
			transform_drag_changed(app, obj, from)
			transform_drag_end(app, force = true)
		case .Boolean:
			// As the Booleans section's tabs do; the same mode again is no change to make.
			obj.boolean = Boolean_Mode(st.arg)
			return "", true
		case .Slice:
			if !scene_slice_axis(app, obj, st.arg) do return "", false
		case .Knife:
			if !scene_knife_axis(app, obj, st.arg, !st.flip) do return "", false
		case .Hide:
			hide_axis(app, obj, st.arg, !st.flip)
		case .Mask_Rect:
			corners := [2][2]f32{st.numbers.xy * size, st.numbers.zw * size}
			mask_shape_command(app, shape_polygon(corners[:], true, size), size, false)
		case .Layer:
			// As the layer's slider and eye do, in one undo step.
			s := object_sculptor(obj)
			if count := len(sculpt.sculptor_layers(s)); st.count > count do return fmt.tprintf("the object has %d layer%s", count, "" if count == 1 else "s"), true
			if !layers_allowed(obj) do return "layers are not available in HD or with dynamic topology", true
			stroke_finish(app)
			l := sculpt.sculptor_layers(s)[st.count - 1]
			if l.strength == st.numbers[0] && l.visible == !st.flip do return "", true
			_ = sculpt.sculptor_layer_set(s, st.count - 1, st.numbers[0], !st.flip)
			if sculpt.sculptor_stroke_end(s) do history_record(app, obj, .Layer, "Layer strength")
			return "", true
		case .Group_Material:
			// As the Material section's Group target does, in place so the next line sees it.
			if obj.voxel != nil do return "a voxel object has no polygroups", true
			autosave_settle(app)
			if why := group_material_set(obj, u16(st.count), current_material(app), st.flip); why != "" do return why, true
			app.scene_edits += 1
			return "", true
		case .Falloff, .Focal, .Alpha, .Matcap, .Project, .Draw_Curve, .Insert_Middle, .Install_Pack, .Preset, .Pack_Mesh, .Make_Pack, .Texture, .Environment, .Render_Focus:
		}
	}
	if script_scene_state(app) == before do return "it left the scene as it was (the log says why)", true
	return "", true
}

// Sets what a .Set or .Line statement sets.
script_set :: proc(app: ^App, st: Script_Statement) {
	#partial switch st.kind {
	case .Set:  setting_write(app, st.setting, st.value)
	case .Line:
		if st.text != "" {
			// A content pack's material (script_statement).
			if j := pack_material_by_ref(app, st.text); j >= 0 do app.material = PACK_MATERIAL + j
		} else {
			st.set.apply(app, st.line_value)
		}
		// A script's material is the selection's too, as picking one in the Material
		// section is; the settings file only sets the default new objects take.
		if st.set.key == "material" {
			// The autosave thread may be reading the objects' materials.
			autosave_settle(app)
			material_set(app, current_material(app))
		}
	}
}

// Whether a script may run the command: not one that opens a file dialog, a text field or
// a menu to pick from, which would wait on a person a script does not have.
script_allows :: proc(id: Command_Id) -> bool {
	#partial switch id {
	case .Open_Scene, .Save_Scene, .Save_Scene_As, .Save_Scene_Copy, .Scene_Versions, .Import_Mesh, .Export_Mesh, .Export_Print, .Screenshot, .Record_Turntable:
		return false
	case .Rename_Object, .Command_Palette, .Pie, .Pie_Editor, .Brush_Pie:
		return false
	// No script records or runs a macro, a script file or a plugin, so none starts
	// another, records itself or runs the plugin that runs it.
	case .Macro_Record, .Run_Macro, .Run_Script, .Run_Plugin, .Reload_Plugins, .Pick_Pack, .Save_Pack:
		return false
	// The last stroke replays where the pointer is, and the last autosave is whatever an
	// earlier run left: neither is something a script can say beforehand.
	case .Replay_Stroke, .Open_Last_Autosave:
		return false
	}
	return true
}

// A script being run: the start-up one (--run, --script), which sets the run up, or one a
// person starts (a macro), which is their work like any other. Where it has got to, and
// how long it has taken.
Script_Run :: struct {
	script:   Script,
	next:     int, // the statement to run next
	waiting:  int, // frames a `wait` has still to let pass
	running:  bool,
	setup:    bool, // the start-up script: what it did is where the run starts
	scripted: bool, // a start-up script in a run without a person: a failure ends it with code 2
	started:  bool, // the viewport had its size, and the first statement ran
	failed:   bool,
	frames:   int, // frames from the first to the one it finished on
	fp:       u64, // the scene's fingerprint as the script began
}

// How the start-up script went, for the exit stats and the exit files, kept apart from
// the runner, which a macro run later reuses.
Script_Outcome :: struct {
	statements, ran, frames: int,
	failed, scripted:        bool,
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
	if report := script_start(app, text, source, setup = true, scripted = scripted); report != "" {
		fmt.eprint(report)
		return false
	}
	return true
}

// Reads `text` and starts running it at the next frame's start, in place of any script
// loaded before: as the run's set-up, or as a person's work (a macro), which may not start
// a new scene, which would empty the History, nor `wait`, so it is done within the frame
// it starts in, before an autosave could start or the person do anything else. What is
// wrong with the text, one error a line, in the temp allocator; "" when it started.
script_start :: proc(app: ^App, text, source: string, setup, scripted: bool) -> string {
	script_unload(app)
	r := &app.script
	r.script = script_parse(text, source)
	if !setup do script_check_work(&r.script)
	if len(r.script.errors) > 0 {
		report := script_report(&r.script)
		script_unload(app)
		return report
	}
	r.running, r.setup, r.scripted = true, setup, scripted && setup
	return ""
}

// The checks a person's script (a macro, a script file, a plugin's sculpt.run) has on
// top of reading: no `wait` and no `new_scene`, since it is done within the frame it
// starts in and its steps are the History's. The errors end up listed by line.
script_check_work :: proc(s: ^Script) {
	for st in s.statements {
		if len(s.errors) >= SCRIPT_ERRORS_MAX do break
		if st.kind == .Wait do append(&s.errors, Script_Error{st.line, strings.clone("wait is only for start-up scripts")})
		if st.kind == .Command && st.command == .New_Scene do append(&s.errors, Script_Error{st.line, strings.clone("new_scene is only for start-up scripts: it empties the History")})
	}
	// Errors found after reading are on later lines than none, but listed by line.
	slice.sort_by(s.errors[:], proc(a, b: Script_Error) -> bool {return a.line < b.line})
}

// Runs a person's script text now, statement by statement as script_frame does, each
// its own undo step: for a plugin's sculpt.run, which runs at a frame's start. The
// script's first error, or what stopped it ("line 2: remesh did nothing (why)"), in the
// temp allocator, with how many statements ran first; ok false only on a GPU failure.
script_run_now :: proc(app: ^App, text, source: string) -> (failure: string, ran: int, ok: bool) {
	s := script_parse(text, source)
	defer script_destroy(&s)
	script_check_work(&s)
	if len(s.errors) > 0 do return fmt.tprintf("line %d: %s", s.errors[0].line, s.errors[0].message), 0, true
	for st in s.statements {
		why: string
		why, ok = script_step(app, st)
		if !ok do return "", ran, false
		if why != "" do return fmt.tprintf("line %d: %s did nothing (%s)", st.line, script_statement_name(st), why), ran, true
		ran += 1
	}
	return "", ran, true
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
		if st.text != "" && pack_material_by_ref(app, st.text) < 0 do return fmt.tprintf("no content pack has a material named %q", st.text), true
		script_set(app, st)
	case .Select:
		n := len(app.scene.objects)
		if st.count > n do return fmt.tprintf("the scene has %d object%s", n, "" if n == 1 else "s"), true
		select_only(app, st.count - 1)
	case .Verb:
		start := time.tick_now()
		failure, ok = script_verb(app, st)
		if failure != "" || !ok do return
		scene_folders_normalize(app)
		scene_selection_fix(app)
		if .Warning in app.result.flags && time.tick_diff(start, app.result.at) >= 0 do return app.result.text, true
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
	if !r.setup {
		// A person's run keeps what it did before the statement, each its own step.
		r.running = false
		app.macro.steps += r.next
		report(app, nil, {.Warning}, "%s stopped at line %d: %s did nothing (%s)", r.script.source, st.line, name, strings.clone(why, context.temp_allocator))
		return
	}
	script_outcome(app)
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

// Keeps how the start-up script went.
@(private = "file")
script_outcome :: proc(app: ^App) {
	r := &app.script
	app.startup_script = {len(r.script.statements), r.next, r.frames, r.failed, r.scripted}
}

@(private = "file")
script_statement_name :: proc(st: Script_Statement) -> string {
	switch st.kind {
	case .Command:   return script_name(fmt.tprint(st.command))
	case .Set:       return fmt.tprintf("set %s", st.setting.key)
	case .Line:      return fmt.tprintf("set %s", st.set.key)
	case .Wait:      return "wait"
	case .Select:    return "select"
	case .Verb:      return SCRIPT_VERBS[st.verb].name
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
	if !r.setup {
		n := len(r.script.statements)
		app.macro.steps += n
		report(app, nil, {}, "Ran %s: %d step%s", r.script.source, n, "" if n == 1 else "s")
		return
	}
	if !r.failed do script_outcome(app)
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
