package main

import "core:fmt"
import "core:reflect"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

import "../camera"
import "../gizmo"
import "../sculpt"

// The keys in use: DEFAULT_BINDINGS with the user's changes over them. A command the user
// gives a key has exactly that one chord, and the chord leaves whatever had it; a command
// the user takes every key from has none. settings.txt keeps the changes (`key` lines),
// never the whole map, so a later default for a command the user never touched still
// arrives.

MAX_KEY_OVERRIDES :: 64
MAX_BINDINGS :: len(DEFAULT_BINDINGS) + MAX_KEY_OVERRIDES

Key_Override :: struct {
	command: Command_Id,
	arg:     int,
	chord:   Chord,
	none:    bool, // the command has no key at all
}

// The bindings in effect: the defaults while nothing is changed (a zero App too), else
// as keymap_rebuild built them after the last change. A chord the user gave runs after
// the defaults in a frame where several keys went down.
keymap :: proc(app: ^App) -> []Binding {
	if app.key_override_count == 0 do return DEFAULT_BINDINGS[:]
	return app.bindings[:app.binding_count]
}

keymap_rebuild :: proc(app: ^App) {
	app.binding_count = 0
	push :: proc(app: ^App, b: Binding) {
		app.bindings[app.binding_count] = b
		app.binding_count += 1
	}
	for b in DEFAULT_BINDINGS {
		// A command the user changed keeps only its change; a chord the user gave to
		// another command leaves this one.
		if key_override_find(app, b.command, b.arg) >= 0 do continue
		taken := false
		for o in app.key_overrides[:app.key_override_count] do taken ||= !o.none && chord_same(o.chord, b.chord)
		if !taken do push(app, b)
	}
	for o in app.key_overrides[:app.key_override_count] do if !o.none do push(app, {o.chord, o.command, o.arg})
}

// Whether two chords are the same key with the same modifiers (auto-repeat aside).
chord_same :: proc(a, b: Chord) -> bool {
	return a.key == b.key && a.mods == b.mods
}

// The user's change to the command, or -1.
key_override_find :: proc(app: ^App, id: Command_Id, arg: int) -> int {
	for o, i in app.key_overrides[:app.key_override_count] do if o.command == id && o.arg == arg do return i
	return -1
}

// The command `chord` runs now, if any.
chord_owner :: proc(app: ^App, chord: Chord) -> (Binding, bool) {
	for b in keymap(app) do if chord_same(b.chord, chord) do return b, true
	return {}, false
}

// Why `chord` cannot be bound, if it cannot: the keys read outside the registry, and the
// ones that end typing or close what floats.
chord_reserved :: proc(chord: Chord) -> (reason: string, reserved: bool) {
	switch chord.key {
	case sdl.K_ESCAPE, sdl.K_AC_BACK:
		return "Escape closes menus, stops a replay and puts back a gizmo drag", true
	case sdl.K_RETURN, sdl.K_KP_ENTER, sdl.K_BACKSPACE:
		return "Enter and Backspace are for typing", true
	case sdl.K_SPACE:
		return "Space opens the brush pie", true
	case sdl.K_S, sdl.K_U:
		if chord.mods == {} do return "S and U held over the model size the brush and set its strength", true
	case sdl.K_LCTRL, sdl.K_RCTRL, sdl.K_LSHIFT, sdl.K_RSHIFT, sdl.K_LALT, sdl.K_RALT, sdl.K_LGUI, sdl.K_RGUI, sdl.K_MODE:
		return "Ctrl, Shift and Alt go with a key", true
	case sdl.K_CAPSLOCK, sdl.K_NUMLOCKCLEAR, sdl.K_SCROLLLOCK, sdl.K_UNKNOWN:
		return "a lock key changes how other keys type", true
	}
	return "", false
}

// Gives the command `chord` as its only key, taking it from whatever had it (which keeps
// its other keys, or has none if this was its only one the user gave it).
bind_assign :: proc(app: ^App, id: Command_Id, arg: int, chord: Chord) -> bool {
	if _, reserved := chord_reserved(chord); reserved do return false
	for &o in app.key_overrides[:app.key_override_count] {
		if !o.none && chord_same(o.chord, chord) && (o.command != id || o.arg != arg) do o = {command = o.command, arg = o.arg, none = true}
	}
	c := chord
	// A key that steps (Undo, the size) repeats as its default did.
	c.repeat = false
	for b in DEFAULT_BINDINGS do if b.command == id && b.arg == arg do c.repeat = b.chord.repeat
	return key_override_put(app, {command = id, arg = arg, chord = c})
}

// Takes every key from the command.
bind_remove :: proc(app: ^App, id: Command_Id, arg: int) -> bool {
	return key_override_put(app, {command = id, arg = arg, none = true})
}

// Gives the command its default keys back, less any the user gave another command.
bind_reset :: proc(app: ^App, id: Command_Id, arg: int) {
	i := key_override_find(app, id, arg)
	if i < 0 do return
	copy(app.key_overrides[i:app.key_override_count], app.key_overrides[i + 1:app.key_override_count])
	app.key_override_count -= 1
	app.key_overrides[app.key_override_count] = {}
	keymap_rebuild(app)
}

// Gives every command its default keys back.
bind_reset_all :: proc(app: ^App) {
	app.key_overrides, app.key_override_count = {}, 0
	keymap_rebuild(app)
}

@(private = "file")
key_override_put :: proc(app: ^App, o: Key_Override) -> bool {
	i := key_override_find(app, o.command, o.arg)
	if i < 0 {
		if app.key_override_count == MAX_KEY_OVERRIDES {
			report(app, nil, {.Warning}, "%d keys are changed already: reset one first", MAX_KEY_OVERRIDES)
			return false
		}
		i = app.key_override_count
		app.key_override_count += 1
	}
	app.key_overrides[i] = o
	keymap_rebuild(app)
	return true
}

// Reads what chord_text writes ("Ctrl+Shift+Z", "Num 1", "Ctrl++"): the modifiers first,
// then the key by its name.
chord_parse :: proc(text: string) -> (c: Chord, ok: bool) {
	rest := text
	for {
		switch {
		case strings.has_prefix(rest, "Ctrl+") && len(rest) > 5:  c.mods += {.Ctrl}; rest = rest[5:]; continue
		case strings.has_prefix(rest, "Shift+") && len(rest) > 6: c.mods += {.Shift}; rest = rest[6:]; continue
		case strings.has_prefix(rest, "Alt+") && len(rest) > 4:   c.mods += {.Alt}; rest = rest[4:]; continue
		}
		break
	}
	switch {
	case rest == "":
		return
	case len(rest) == 1 && rest[0] >= 'A' && rest[0] <= 'Z':
		c.key = sdl.Keycode(rest[0] - 'A' + 'a')
	case len(rest) == 1 && rest[0] >= '0' && rest[0] <= '9':
		c.key = sdl.Keycode(rest[0])
	case strings.has_prefix(rest, "Num ") && len(rest) == 5 && rest[4] >= '0' && rest[4] <= '9':
		c.key = sdl.K_KP_0 if rest[4] == '0' else sdl.K_KP_1 + sdl.Keycode(rest[4] - '1')
	case len(rest) >= 2 && rest[0] == 'F' && rest[1] >= '1' && rest[1] <= '9':
		n, n_ok := strconv.parse_int(rest[1:])
		if !n_ok || n < 1 || n > 12 do return
		c.key = sdl.K_F1 + sdl.Keycode(n - 1)
	case:
		switch rest {
		case "[":     c.key = sdl.K_LEFTBRACKET
		case "]":     c.key = sdl.K_RIGHTBRACKET
		case "Del":   c.key = sdl.K_DELETE
		case "Tab":   c.key = sdl.K_TAB
		case "Esc":   c.key = sdl.K_ESCAPE
		case "Space": c.key = sdl.K_SPACE
		case "/":     c.key = sdl.K_SLASH
		case:
			// A printable key is its own character: SDL's name lookup goes by the keyboard's
			// layout and reads "+" as the = key it shares.
			if len(rest) == 1 && rest[0] > ' ' && rest[0] < 0x7f {
				c.key = sdl.Keycode(rest[0])
				break
			}
			c.key = sdl.GetKeyFromName(strings.clone_to_cstring(rest, context.temp_allocator))
			if c.key == sdl.K_UNKNOWN do return
		}
	}
	return c, true
}

// A command as settings.txt names it: "Duplicate_Object", or with its argument
// "Brush:Clay", "View_Axis:Front".
command_name :: proc(id: Command_Id, arg := 0) -> string {
	if COMMANDS[id].args == 0 do return fmt.tprint(id)
	return fmt.tprintf("%v:%s", id, command_arg_name(id, arg))
}

// Reads what command_name writes.
command_from_name :: proc(name: string) -> (id: Command_Id, arg: int, ok: bool) {
	head, _, tail := strings.partition(name, ":")
	id = reflect.enum_from_name(Command_Id, head) or_return
	if id == .None do return
	n := COMMANDS[id].args
	if n == 0 do return id, 0, tail == ""
	if id == .Remesh_To || id == .Decimate_To {
		want := strconv.parse_f64(tail) or_return
		best := -1.0
		for p, i in SPHERE_PRESETS {
			if d := abs(f64(p.vertices) - want); best < 0 || d < best do arg, best = i, d
		}
		return id, arg, best >= 0
	}
	for a in 0 ..< n do if command_arg_name(id, a) == tail do return id, a, true
	return
}

// An argument by name, so a saved name stays right when the order of brushes or views
// changes.
command_arg_name :: proc(id: Command_Id, arg: int) -> string {
	#partial switch id {
	case .Brush:     return fmt.tprint(sculpt.Brush_Kind(arg))
	case .View_Axis: return fmt.tprint(camera.Axis_View(arg))
	case .Viewport_Look: return fmt.tprint(Look_Preset(arg))
	case .Mask:      return fmt.tprint(sculpt.Mask_Command(arg))
	case .Mask_By:   return fmt.tprint(sculpt.Mask_By(arg))
	case .Layer_Edit: return fmt.tprint(Layer_Action(arg))
	case .Paint:     return fmt.tprint(sculpt.Paint_Command(arg))
	case .Group:     return fmt.tprint(sculpt.Group_Command(arg))
	case .Remesh_To, .Decimate_To: return fmt.tprint(SPHERE_PRESETS[arg].vertices)
	case .Help:      return fmt.tprint(Help_Tab(arg))
	case .Show_Section: return fmt.tprint(Kit_Section(arg))
	case .New_Scene: return fmt.tprint(NEW_SCENE_SHAPES[arg])
	case .Pie:       return fmt.tprint(arg + 1) // as the menus count them
	case .Run_Macro: return fmt.tprint(arg + 1)
	case .Run_Plugin: return fmt.tprint(arg + 1)
	case .Restore_Selection_Set: return fmt.tprint(arg + 1)
	case .Gizmo:     return fmt.tprint(gizmo.Mode(arg))
	case .Deformer:  return deformer_name(arg)
	case .Deformation: return fmt.tprint(Reshape_Choice(arg))
	case .Visibility_Slot: return fmt.tprintf("V%d", arg + 1)
	case .Split_Object: return fmt.tprint(Split_Mode(arg))
	case .Align_Objects, .Distribute_Objects: return fmt.tprintf("%s_%s", AXIS_NAMES[arg / 3], EDGE_NAMES[arg % 3])
	}
	return fmt.tprint(arg)
}
