package main

import "core:fmt"
import "core:strings"

import "../sculpt"

// Brush presets: named brushes the user makes, as Nomad's presets and Blender's brush
// assets are. A preset is a base brush with its own strength, falloff, alpha, stroke kind
// (with Spray's spread), lazy mouse, Lock plane and Connected, paint colour and cloth
// mode; size, the pen settings and symmetry stay global, so switching brushes never
// changes how big the brush is.
// While the brush is on a preset, the brush's own slots hold the preset's values and the
// plain brush's are kept in Brush_Settings.plain, which leaving the preset puts back: a
// plain brush keeps its own strength, and what settings.txt remembers for it, whatever
// presets were used.

MAX_PRESETS :: 24
PRESET_NAME_MAX :: 32

// What a preset sets, besides its name.
Preset_Values :: struct {
	kind:        sculpt.Brush_Kind,
	strength:    f32,
	falloff:     Falloff_Setting,
	alpha:       int, // into App.alphas, or -1 (or any other outside it) for round
	alpha_mode:  Alpha_Mode,
	alpha_angle: f32,
	stroke:      Stroke_Mode,
	spread:      f32, // Spray's spread (Brush_Settings.spray_spread)
	lazy_px:     f32,
	color:       [3]f32,
	cloth_mode:  sculpt.Cloth_Mode,
	lock_plane:  bool,
	connected:   bool,
}

Brush_Preset :: struct {
	name:   [PRESET_NAME_MAX]u8, // up to the first zero byte, never empty
	values: Preset_Values,
}

preset_name :: proc(p: ^Brush_Preset) -> string {
	n := 0
	for n < PRESET_NAME_MAX && p.name[n] != 0 do n += 1
	return string(p.name[:n])
}

// The brush's values for `kind` as they stand: its own slots and the global settings.
preset_values_of :: proc(b: ^Brush_Settings, kind: sculpt.Brush_Kind) -> Preset_Values {
	return {
		kind = kind, strength = b.strengths[kind], falloff = b.falloffs[kind], alpha = b.alpha, alpha_mode = b.alpha_mode,
		alpha_angle = b.alpha_angle, stroke = b.stroke, spread = b.spray_spread, lazy_px = b.lazy_px, color = b.color,
		cloth_mode = b.cloth_mode, lock_plane = b.lock_plane, connected = b.connected,
	}
}

// Makes `v` the brush: its kind, that kind's slots and the global settings.
preset_values_put :: proc(b: ^Brush_Settings, v: Preset_Values) {
	b.kind = v.kind
	b.strengths[v.kind], b.falloffs[v.kind] = v.strength, v.falloff
	b.alpha, b.alpha_mode, b.alpha_angle = v.alpha, v.alpha_mode, v.alpha_angle
	b.stroke, b.spray_spread, b.lazy_px, b.color, b.cloth_mode = v.stroke, v.spread, v.lazy_px, v.color, v.cloth_mode
	b.lock_plane, b.connected = v.lock_plane, v.connected
}

// The preset the brush is on, if any.
brush_preset :: proc(app: ^App) -> (^Brush_Preset, bool) {
	i := app.brush.preset - 1
	if i < 0 || i >= app.preset_count do return nil, false
	return &app.presets[i], true
}

// Puts the brush on preset `i` (from 0), and picks the Sculpt tool.
preset_pick :: proc(app: ^App, i: int) {
	if i < 0 || i >= app.preset_count do return
	b := &app.brush
	preset_leave(app)
	v := app.presets[i].values
	b.plain = preset_values_of(b, v.kind)
	preset_values_put(b, v)
	b.preset = i + 1
	app.tool = .Brush
}

// Takes the brush off its preset, if it is on one, giving the plain brush its own values
// back.
preset_leave :: proc(app: ^App) {
	b := &app.brush
	if b.preset == 0 do return
	preset_values_put(b, b.plain)
	b.preset = 0
}

// The brush as settings.txt remembers it: off any preset, with the plain brush's values.
brush_plain :: proc(app: ^App) -> Brush_Settings {
	b := app.brush
	if b.preset != 0 {
		preset_values_put(&b, b.plain)
		b.preset = 0
	}
	return b
}

// Whether the brush's values differ from its preset's, in what the base brush uses: the
// colour only for painting, the cloth mode only for the Cloth brush, the alpha not for
// Grab, which takes none, and Lock plane and Connected not for Grab or Cloth, which
// leave both.
preset_changed :: proc(app: ^App) -> bool {
	p, ok := brush_preset(app)
	if !ok do return false
	return !preset_same(app, p.values, preset_values_of(&app.brush, p.values.kind))
}

preset_same :: proc(app: ^App, a, b: Preset_Values) -> bool {
	flags := BRUSHES[a.kind].flags
	round := proc(app: ^App, i: int) -> int {return i if i >= 0 && i < len(app.alphas) else -1}
	if a.kind != b.kind || a.strength != b.strength || a.falloff.drawn != b.falloff.drawn do return false
	if a.falloff.drawn && a.falloff.curve != b.falloff.curve do return false
	if a.falloff.focal != b.falloff.focal do return false
	if a.stroke != b.stroke || a.lazy_px != b.lazy_px || (a.stroke == .Spray && a.spread != b.spread) do return false
	if flags & {.Grab, .Cloth} == {} && (a.lock_plane != b.lock_plane || a.connected != b.connected) do return false
	if .Grab not_in flags && (round(app, a.alpha) != round(app, b.alpha) || a.alpha_mode != b.alpha_mode || a.alpha_angle != b.alpha_angle) do return false
	if .Paint in flags && a.color != b.color do return false
	if .Cloth in flags && a.cloth_mode != b.cloth_mode do return false
	return true
}

// Makes a preset of the brush as it is ("Clay 1", "Clay 2", ...) and puts the brush on
// it. Returns false when there are MAX_PRESETS already.
preset_save_new :: proc(app: ^App) -> bool {
	if app.preset_count == MAX_PRESETS {
		report(app, nil, {.Warning}, "There are %d presets already: delete one first", MAX_PRESETS)
		return false
	}
	b := &app.brush
	p := Brush_Preset{values = preset_values_of(b, b.kind)}
	base := BRUSHES[b.kind].name
	for n := 1; ; n += 1 {
		name := fmt.tprintf("%s %d", base, n)
		if preset_find(app, name) < 0 {
			preset_name_set(&p, name)
			break
		}
	}
	// Off a plain brush, the brush's values are the plain ones it goes back to; off a
	// preset, the plain ones kept for it stay.
	if b.preset == 0 do b.plain = p.values
	app.presets[app.preset_count] = p
	app.preset_count += 1
	b.preset = app.preset_count
	report(app, nil, {.Quiet}, "Saved the brush as %s", preset_name(&app.presets[app.preset_count - 1]))
	return true
}

// Stores the brush's values in the preset it is on.
preset_save :: proc(app: ^App) {
	if p, ok := brush_preset(app); ok do p.values = preset_values_of(&app.brush, p.values.kind)
}

// Puts the brush back to the preset it is on.
preset_revert :: proc(app: ^App) {
	if p, ok := brush_preset(app); ok do preset_values_put(&app.brush, p.values)
}

// Deletes preset `i`, taking the brush off it first when it is on it, and the dock's
// slots holding it back to its brush.
preset_delete :: proc(app: ^App, i: int) {
	if i < 0 || i >= app.preset_count do return
	b := &app.brush
	if b.preset == i + 1 do preset_leave(app)
	copy(app.presets[i:app.preset_count], app.presets[i + 1:app.preset_count])
	app.preset_count -= 1
	app.presets[app.preset_count] = {}
	if b.preset > i + 1 do b.preset -= 1
	dock_preset_deleted(app, i)
}

// The preset named `name` (ignoring case), or -1.
preset_find :: proc(app: ^App, name: string) -> int {
	for i in 0 ..< app.preset_count do if strings.equal_fold(preset_name(&app.presets[i]), name) do return i
	return -1
}

// Renames preset `i`. The name is trimmed and cut to PRESET_NAME_MAX bytes on a character
// boundary; an empty one, one another preset has or a brush's own name is refused (false),
// so tiles and settings.txt can tell every preset and brush apart.
preset_rename :: proc(app: ^App, i: int, typed: string) -> bool {
	if i < 0 || i >= app.preset_count do return false
	name := preset_name_fit(strings.trim_space(typed))
	if name == "" do return false
	if other := preset_find(app, name); other >= 0 && other != i do return false
	if _, ok := brush_by_name(name); ok do return false
	preset_name_set(&app.presets[i], name)
	return true
}

// `name` cut to fit PRESET_NAME_MAX - 1 bytes without splitting a character.
preset_name_fit :: proc(name: string) -> string {
	if len(name) < PRESET_NAME_MAX do return name
	n := PRESET_NAME_MAX - 1
	for n > 0 && name[n] & 0xc0 == 0x80 do n -= 1
	return name[:n]
}

@(private = "file")
preset_name_set :: proc(p: ^Brush_Preset, name: string) {
	p.name = {}
	copy(p.name[:PRESET_NAME_MAX - 1], preset_name_fit(name))
}

// Whether the plain brush's strength, falloff or focal shift differ from a fresh install's.
brush_reset_needed :: proc(app: ^App) -> bool {
	b := &app.brush
	f := b.falloffs[b.kind]
	return b.preset == 0 && (b.strengths[b.kind] != BRUSHES[b.kind].strength || f.drawn || f.focal != 0)
}

// Puts the plain brush's strength, falloff and focal shift back to a fresh install's.
brush_reset :: proc(app: ^App) {
	b := &app.brush
	if b.preset != 0 do return
	b.strengths[b.kind] = BRUSHES[b.kind].strength
	b.falloffs[b.kind] = {}
}

// A name as one word of settings.txt: % and white space escaped as %25, %20, %09.
preset_escape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)s {
		switch c {
		case '%', ' ', '\t', '\n', '\r': fmt.sbprintf(&b, "%%%02X", c)
		case:                            strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

// Reads what preset_escape wrote; a stray % stays as it is.
preset_unescape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	hex :: proc(c: u8) -> int {
		switch c {
		case '0' ..= '9': return int(c - '0')
		case 'A' ..= 'F': return int(c - 'A' + 10)
		case 'a' ..= 'f': return int(c - 'a' + 10)
		}
		return -1
	}
	for i := 0; i < len(s); i += 1 {
		if s[i] == '%' && i + 2 < len(s) {
			hi, lo := hex(s[i + 1]), hex(s[i + 2])
			if hi >= 0 && lo >= 0 {
				strings.write_byte(&b, u8(hi * 16 + lo))
				i += 2
				continue
			}
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}
