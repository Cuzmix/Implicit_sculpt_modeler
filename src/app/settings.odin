package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:reflect"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

import "../camera"
import "../geom"
import "../sculpt"
import "../ui"

// What the app remembers between interactive runs: the brush settings, how the
// viewport looks, the Scene tab's choices and the Settings panel's, in a text file of `key values...`
// lines in SDL's per-user folder. Runs with --frames, a benchmark or --no-settings
// neither read nor write it, so scripted runs stay reproducible. Flags given on the
// command line win over what it holds. Unknown or malformed lines are skipped, so an
// older or newer file never stops the app.

SETTINGS_FILE :: "settings.txt"

// The furthest a remembered window may sit from its edges, in points: more than any
// screen, so a damaged line cannot put a window at an absurd place.
WINDOW_OFFSET_MAX :: 10000

// Where the settings live, or "" when SDL has no folder for them (temp memory).
settings_path :: proc() -> string {
	dir := sdl.GetPrefPath("Implicit", "Sculpt")
	if dir == nil do return ""
	defer sdl.free(dir)
	return strings.concatenate({string(cstring(dir)), SETTINGS_FILE}, context.temp_allocator)
}

// The version settings_save writes on the first line. A file from a newer version is
// read as far as this one knows its lines.
SETTINGS_VERSION :: 1

// One remembered value that is a plain field of App: its key in the file, where it is,
// what type it is (bool, f32, i32 or an enum) and, for numbers, the range a value read
// back is clamped to (lo == hi: any). Read and written by the same row, so the two
// directions cannot drift. Values with more to them (a brush's own strength, a curve,
// the panel windows) are the hand-written lines in settings_load and settings_save.
Setting :: struct {
	key:    string,
	offset: uintptr,
	type:   typeid,
	lo, hi: f32,
}

@(private = "file")
B :: offset_of(App, brush)
@(private = "file")
N :: offset_of(App, nav)
@(private = "file")
K :: offset_of(App, kit)
@(private = "file")
U :: offset_of(App, ui)

@(rodata)
SETTINGS := [?]Setting {
	{"radius_px", B + offset_of(Brush_Settings, radius_px), f32, MIN_RADIUS_PX, MAX_RADIUS_PX},
	{"pressure_strength", B + offset_of(Brush_Settings, pressure_strength), bool, 0, 0},
	{"pressure_size", B + offset_of(Brush_Settings, pressure_size), bool, 0, 0},
	{"tilt_strength", B + offset_of(Brush_Settings, tilt_strength), f32, 0, 1},
	{"lazy_px", B + offset_of(Brush_Settings, lazy_px), f32, 0, 150},
	{"front_only", B + offset_of(Brush_Settings, front_only), bool, 0, 0},
	{"stroke", B + offset_of(Brush_Settings, stroke), Stroke_Mode, 0, 0},
	{"detail_px", B + offset_of(Brush_Settings, detail_px), f32, 2, 40},
	{"collapse", B + offset_of(Brush_Settings, collapse), bool, 0, 0},
	{"alpha_mode", B + offset_of(Brush_Settings, alpha_mode), Alpha_Mode, 0, 0},
	{"alpha_angle", B + offset_of(Brush_Settings, alpha_angle), f32, 0, 0},
	{"show_groups", offset_of(App, show_groups), bool, 0, 0},
	{"crease_degrees", U + offset_of(Ui_State, crease_degrees), f32, 1, 90},
	{"wireframe", offset_of(App, wireframe), bool, 0, 0},
	{"flat", offset_of(App, flat), bool, 0, 0},
	{"reduce_motion", K + offset_of(Kit_State, ctx) + offset_of(ui.Context, reduced_motion), bool, 0, 0},
	{"ortho", offset_of(App, camera) + offset_of(camera.Orbit, ortho), bool, 0, 0},
	// Settings > Interface, Camera, Touch and Performance.
	{"surface_ring", K + offset_of(Kit_State, surface_ring), bool, 0, 0},
	{"action_bar", K + offset_of(Kit_State, action_bar), bool, 0, 0},
	{"modifier_rail", K + offset_of(Kit_State, rail_side), Rail_Side, 0, 0},
	{"all_options", K + offset_of(Kit_State, all_options), bool, 0, 0},
	{"coach", K + offset_of(Kit_State, coach), i32, 0, f32(COACH_DONE)},
	{"stats", K + offset_of(Kit_State, stats), bool, 0, 0},
	{"stats_advanced", K + offset_of(Kit_State, stats_advanced), bool, 0, 0},
	{"vsync", offset_of(App, vsync), bool, 0, 0},
	{"orbit_style", N + offset_of(Nav_Prefs, orbit_style), camera.Orbit_Style, 0, 0},
	{"limit_pitch", N + offset_of(Nav_Prefs, limit_pitch), bool, 0, 0},
	{"orbit_speed", N + offset_of(Nav_Prefs, orbit_speed), f32, 0.25, 4},
	{"pan_speed", N + offset_of(Nav_Prefs, pan_speed), f32, 0.25, 4},
	{"zoom_speed", N + offset_of(Nav_Prefs, zoom_speed), f32, 0.25, 4},
	{"invert_x", N + offset_of(Nav_Prefs, invert_x), bool, 0, 0},
	{"invert_y", N + offset_of(Nav_Prefs, invert_y), bool, 0, 0},
	{"invert_wheel", N + offset_of(Nav_Prefs, invert_wheel), bool, 0, 0},
	{"finger_model", N + offset_of(Nav_Prefs, finger_model), Finger_Model, 0, 0},
	{"pen_empty", N + offset_of(Nav_Prefs, empty_drag) + uintptr(ui.Pointer_Kind.Pen) * size_of(Empty_Drag), Empty_Drag, 0, 0},
	{"mouse_empty", N + offset_of(Nav_Prefs, empty_drag) + uintptr(ui.Pointer_Kind.Mouse) * size_of(Empty_Drag), Empty_Drag, 0, 0},
	{"pinch_zoom", N + offset_of(Nav_Prefs, pinch_zoom), bool, 0, 0},
	{"zoom_toward", N + offset_of(Nav_Prefs, zoom_toward), bool, 0, 0},
	{"two_finger_pan", N + offset_of(Nav_Prefs, two_finger_pan), bool, 0, 0},
	{"twist_roll", N + offset_of(Nav_Prefs, twist_roll), bool, 0, 0},
	{"three_finger", N + offset_of(Nav_Prefs, three_finger), bool, 0, 0},
	{"tap_history", N + offset_of(Nav_Prefs, tap_history), bool, 0, 0},
	{"palm_rejection", N + offset_of(Nav_Prefs, palm_rejection), bool, 0, 0},
	{"double_tap", N + offset_of(Nav_Prefs, double_tap), bool, 0, 0},
	{"lift_one_orbit", N + offset_of(Nav_Prefs, lift_one_orbit), bool, 0, 0},
	{"hold_history", N + offset_of(Nav_Prefs, hold_history), bool, 0, 0},
	{"orbit_pivot", N + offset_of(Nav_Prefs, pivot), Orbit_Pivot, 0, 0},
	{"edge_orbit", N + offset_of(Nav_Prefs, edge_orbit), bool, 0, 0},
	{"edge_size", N + offset_of(Nav_Prefs, edge_size), f32, EDGE_MIN, EDGE_MAX},
	{"edge_show", N + offset_of(Nav_Prefs, edge_show), bool, 0, 0},
	// The Scene and Object tabs' choices, and the tools'.
	{"new_shape", K + offset_of(Kit_State, add_shape), geom.Primitive, 0, 0},
	{"mask_steps", U + offset_of(Ui_State, mask_steps), i32, 1, 50},
	{"mask_shape", U + offset_of(Ui_State, mask_shape_kind), Mask_Shape_Kind, 0, 0},
	{"gesture", offset_of(App, gesture), Gesture_Tool, 0, 0},
	{"curve", offset_of(App, curve) + offset_of(Curve_Tool, kind), Curve_Kind, 0, 0},
	{"curve_width", offset_of(App, curve) + offset_of(Curve_Tool, size), f32, 0.05, 2},
	{"curve_lift", offset_of(App, curve) + offset_of(Curve_Tool, lift), f32, -1, 2},
	{"curve_sides", offset_of(App, curve) + offset_of(Curve_Tool, sides), i32, 3, 64},
	{"insert", offset_of(App, insert) + offset_of(Insert_Tool, shape), geom.Primitive, 0, 0},
	{"insert_sink", offset_of(App, insert) + offset_of(Insert_Tool, sink), f32, -1, 1},
}

// Sets the row's field from the text `value`. False, and the field as it was, when the
// text is not a value of its type.
setting_read :: proc(app: ^App, s: Setting, value: string) -> bool {
	at := rawptr(uintptr(app) + s.offset)
	switch s.type {
	case bool:
		(^bool)(at)^ = value == "1"
	case f32:
		v, ok := strconv.parse_f32(value)
		if !ok || v != v do return false
		(^f32)(at)^ = clamp(v, s.lo, s.hi) if s.lo < s.hi else v
	case i32:
		v, ok := strconv.parse_f32(value)
		if !ok || v != v do return false
		(^i32)(at)^ = i32(clamp(v, s.lo, s.hi) if s.lo < s.hi else v)
	case:
		// An enum, by the name of one of its values, in any case.
		names, values := reflect.enum_field_names(s.type), reflect.enum_field_values(s.type)
		for name, i in names {
			if !strings.equal_fold(name, value) do continue
			v := values[i]
			switch reflect.size_of_typeid(s.type) {
			case 1: (^u8)(at)^ = u8(v)
			case 2: (^u16)(at)^ = u16(v)
			case 4: (^u32)(at)^ = u32(v)
			case 8: (^u64)(at)^ = u64(v)
			case: return false
			}
			return true
		}
		return false
	}
	return true
}

// The row's field as the file holds it.
setting_text :: proc(app: ^App, s: Setting) -> string {
	at := rawptr(uintptr(app) + s.offset)
	switch s.type {
	case bool: return "1" if (^bool)(at)^ else "0"
	case f32:  return fmt.tprintf("%g", (^f32)(at)^)
	case i32:  return fmt.tprintf("%d", (^i32)(at)^)
	}
	return fmt.tprintf("%v", any{at, s.type})
}

// Applies what the file at `path` holds to the app. A missing file is no error.
settings_load :: proc(app: ^App, path: string) {
	if path == "" do return
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	b := &app.brush
	text := string(data)
	// The preset the brush was on, by name, put back once every line is read: the presets
	// and the plain brushes' own values all come first.
	on_preset := ""
	// The dock's preset slots, by name, put in once the presets are read.
	dock_presets: [DOCK_SLOTS]string
	lines: for line in strings.split_lines_iterator(&text) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) < 2 do continue
		for s in SETTINGS {
			if s.key != f[0] do continue
			_ = setting_read(app, s, f[1])
			continue lines
		}
		switch f[0] {
		case "version":
			// Nothing to migrate yet: every version so far reads the same lines.
		case "brush":
			if kind, ok := brush_by_name(f[1]); ok do b.kind = kind
		case "strength":
			if len(f) == 3 {
				if kind, ok := brush_by_name(f[1]); ok do b.strengths[kind] = clamp(number(f[2], b.strengths[kind]), MIN_STRENGTH, 1)
			}
		case "falloff":
			// falloff <brush> <drawn 0|1> c1x c1y c2x c2y
			if len(f) == 7 {
				if kind, ok := brush_by_name(f[1]); ok {
					b.falloffs[kind] = {drawn = f[2] == "1", curve = curve(f[3:], b.falloffs[kind].curve)}
				}
			}
		case "pressure_curve": if len(f) == 5 do b.pressure_curve = curve(f[1:], b.pressure_curve)
		case "symmetry":
			b.symmetry = {}
			for c in f[1] {
				switch c {
				case 'x': b.symmetry += {.X}
				case 'y': b.symmetry += {.Y}
				case 'z': b.symmetry += {.Z}
				}
			}
		case "paint_color":
			if len(f) >= 4 do for k in 0 ..< 3 do b.color[k] = clamp(number(f[1 + k], b.color[k]), 0, 1)
		case "material":
			if i, ok := material_by_name(strings.join(f[1:], " ", context.temp_allocator)); ok do app.material = i
		case "custom_material":
			if len(f) >= 6 {
				c := &app.custom
				for k in 0 ..< 3 do c.selected[k] = clamp(number(f[1 + k], c.selected[k]), 0, 1)
				c.metallic = clamp(number(f[4], c.metallic), 0, 1)
				c.roughness = clamp(number(f[5], c.roughness), 0.04, 1)
			}
		case "ui_scale":
			want := number(f[1], 1)
			for s in UI_SCALES do if abs(s - want) < 0.01 do app.kit.ui_scale = s
		case "window":
			// window <name> <moved 0|1> <x anchor> <y anchor> <x offset> <y offset> <minimised 0|1>;
			// the kit keeps every window's title bar on screen whatever the offsets say.
			if len(f) == 8 {
				for which in Kit_Window {
					if !strings.equal_fold(f[1], fmt.tprint(which)) do continue
					w := &app.kit.windows[which]
					w.moved, w.minimized = f[2] == "1", f[7] == "1"
					for a in ui.Anchor {
						if strings.equal_fold(f[3], fmt.tprint(a)) do w.x = a
						if strings.equal_fold(f[4], fmt.tprint(a)) do w.y = a
					}
					w.offset = {clamp(number(f[5], 0), -WINDOW_OFFSET_MAX, WINDOW_OFFSET_MAX), clamp(number(f[6], 0), -WINDOW_OFFSET_MAX, WINDOW_OFFSET_MAX)}
				}
			}
		case "palette_recent":
			// The command palette's recents, most recent first, by name; names this version
			// does not know are skipped, and a name given twice counts once. Remembered
			// oldest first, so the first name ends up first.
			k := &app.kit
			k.palette_recent_count = 0
			names := f[1:][:min(len(f) - 1, PALETTE_RECENT)]
			#reverse for name in names {
				if e, ok := palette_entry_from_name(name); ok do palette_remember(&k.palette_recent, &k.palette_recent_count, e)
			}
		case "preset":
			// preset <name> <brush> <strength> <drawn 0|1> c1x c1y c2x c2y <alpha|-> <alpha mode>
			//        <alpha angle> <stroke> <lazy px> r g b <cloth mode>; names escaped
			// (preset_escape). A damaged line, or one whose name is taken, is skipped.
			if len(f) != 18 || app.preset_count == MAX_PRESETS do continue
			kind, kind_ok := brush_by_name(f[2])
			alpha_mode, mode_ok := reflect.enum_from_name(Alpha_Mode, f[10])
			stroke, stroke_ok := reflect.enum_from_name(Stroke_Mode, f[12])
			cloth, cloth_ok := reflect.enum_from_name(sculpt.Cloth_Mode, f[17])
			if !kind_ok || !mode_ok || !stroke_ok || !cloth_ok do continue
			v := Preset_Values {
				kind = kind, strength = clamp(number(f[3], BRUSHES[kind].strength), MIN_STRENGTH, 1),
				falloff = {drawn = f[4] == "1", curve = curve(f[5:9], FALLOFF_SMOOTH_CURVE)},
				alpha = -1, alpha_mode = alpha_mode, alpha_angle = number(f[11], 0), stroke = stroke,
				lazy_px = clamp(number(f[13], 0), 0, MAX_RADIUS_PX), cloth_mode = cloth,
			}
			for k in 0 ..< 3 do v.color[k] = clamp(number(f[14 + k], 0), 0, 1)
			// Only the built-in alphas are there at every start, in this order (alphas_init).
			alpha := preset_unescape(f[9])
			for name, shape in sculpt.ALPHA_SHAPE_NAMES do if strings.equal_fold(alpha, name) do v.alpha = int(shape)
			app.presets[app.preset_count].values = v
			app.preset_count += 1
			if !preset_rename(app, app.preset_count - 1, preset_unescape(f[1])) {
				app.preset_count -= 1
				app.presets[app.preset_count] = {}
			}
		case "brush_preset":
			on_preset = strings.clone(preset_unescape(f[1]), context.temp_allocator)
		case "key":
			// key <command name> <chord|none>, in the order they were made: a chord already
			// taken by an earlier line, or now reserved, is skipped.
			// A chord's key name may have spaces ("Num 1", "Page Up"): it is the rest of the line.
			id, arg, ok := command_from_name(f[1])
			if len(f) < 3 || !ok || key_override_find(app, id, arg) >= 0 do continue
			written := strings.join(f[2:], " ", context.temp_allocator)
			if written == "none" {
				_ = bind_remove(app, id, arg)
			} else if chord, chord_ok := chord_parse(written); chord_ok {
				if other, taken := chord_owner(app, chord); taken && key_override_find(app, other.command, other.arg) >= 0 do continue
				_ = bind_assign(app, id, arg, chord)
			}
		case "dock":
			// dock <slot> brush <brush> | dock <slot> preset <name, escaped>
			slot, slot_ok := strconv.parse_int(f[1])
			if len(f) != 4 || !slot_ok || slot < 0 || slot >= DOCK_SLOTS do continue
			switch f[2] {
			case "brush":
				if kind, ok := brush_by_name(f[3]); ok do app.kit.dock[slot], dock_presets[slot] = {kind = kind}, ""
			case "preset":
				dock_presets[slot] = strings.clone(preset_unescape(f[3]), context.temp_allocator)
			}
		case "pie":
			// pie <pie 0-3> <slot 0-7> <command name|empty>: a pie that differs from a fresh
			// install's is written whole, so every slot the file names is set.
			n, n_ok := strconv.parse_int(f[1])
			if len(f) != 4 || !n_ok || n < 0 || n >= USER_PIES do continue
			i, i_ok := strconv.parse_int(f[2])
			if !i_ok || i < 0 || i >= PIE_SLOTS do continue
			if f[3] == "empty" {
				app.kit.pies[n][i] = {}
			} else if id, arg, ok := command_from_name(f[3]); ok && pie_lists(id) {
				app.kit.pies[n][i] = {id, arg}
			}
		case "favourite":
			// favourite <command name>, in the order they were starred.
			id, arg, ok := command_from_name(f[1])
			if ok && palette_lists(id) && favourite_find(app, id, arg) < 0 && app.kit.favourite_count < MAX_FAVOURITES {
				app.kit.favourites[app.kit.favourite_count] = {id, arg}
				app.kit.favourite_count += 1
			}
		case "new_vertices":
			// The size an object is added and remeshed at: the nearest of the presets.
			want := number(f[1], -1)
			best := f32(-1)
			for p, i in SPHERE_PRESETS {
				if d := abs(f32(p.vertices) - want); want > 0 && (best < 0 || d < best) do app.kit.add_size, best = i, d
			}
		}
	}
	// On a preset of the brush the file names, it is put back on it; its plain values are
	// the ones just read.
	if i := preset_find(app, on_preset); on_preset != "" && i >= 0 && app.presets[i].values.kind == b.kind do preset_pick(app, i)
	// A slot naming a preset the file does not have keeps what it held.
	for name, slot in dock_presets {
		if i := preset_find(app, name); name != "" && i >= 0 do dock_put(app, slot, app.presets[i].values.kind, i + 1)
	}
	log.infof("settings: read %s", path)

	number :: proc(s: string, fallback: f32) -> f32 {
		v, ok := strconv.parse_f32(s)
		return v if ok && v == v else fallback
	}
	curve :: proc(f: []string, fallback: geom.Curve) -> geom.Curve {
		c := geom.Curve{{number(f[0], -1), number(f[1], -1)}, {number(f[2], -1), number(f[3], -1)}}
		for v in ([4]f32{c.c1.x, c.c1.y, c.c2.x, c.c2.y}) do if v < 0 || v > 1 do return fallback
		return c
	}
}

// Writes the settings to `path`. Returns false, with a warning, when it cannot.
settings_save :: proc(app: ^App, path: string) -> bool {
	if path == "" do return false
	// The plain brushes' own values are what the rows and lines below remember; the preset
	// the brush is on is named at the end and put back on reading.
	on := app.brush
	app.brush = brush_plain(app)
	defer app.brush = on
	b := app.brush
	out := strings.builder_make(context.temp_allocator)
	bit :: proc(v: bool) -> int {return 1 if v else 0}
	fmt.sbprintfln(&out, "version %d", SETTINGS_VERSION)
	for s in SETTINGS do fmt.sbprintfln(&out, "%s %s", s.key, setting_text(app, s))
	fmt.sbprintfln(&out, "brush %s", fmt.tprint(b.kind))
	for kind in sculpt.Brush_Kind {
		fmt.sbprintfln(&out, "strength %v %g", kind, b.strengths[kind])
		f := b.falloffs[kind]
		fmt.sbprintfln(&out, "falloff %v %d %g %g %g %g", kind, bit(f.drawn), f.curve.c1.x, f.curve.c1.y, f.curve.c2.x, f.curve.c2.y)
	}
	c := b.pressure_curve
	fmt.sbprintfln(&out, "pressure_curve %g %g %g %g", c.c1.x, c.c1.y, c.c2.x, c.c2.y)
	symmetry := strings.builder_make(context.temp_allocator)
	strings.write_string(&symmetry, "-") // a placeholder, so the line always has a value
	if .X in b.symmetry do strings.write_byte(&symmetry, 'x')
	if .Y in b.symmetry do strings.write_byte(&symmetry, 'y')
	if .Z in b.symmetry do strings.write_byte(&symmetry, 'z')
	fmt.sbprintfln(&out, "symmetry %s", strings.to_string(symmetry))
	fmt.sbprintfln(&out, "paint_color %g %g %g", b.color.r, b.color.g, b.color.b)
	fmt.sbprintfln(&out, "material %s", current_material(app).label)
	m := app.custom
	fmt.sbprintfln(&out, "custom_material %g %g %g %g %g", m.selected.r, m.selected.g, m.selected.b, m.metallic, m.roughness)
	k := app.kit
	fmt.sbprintfln(&out, "ui_scale %g", k.ui_scale)
	for w, which in k.windows {
		fmt.sbprintfln(&out, "window %v %d %v %v %g %g %d", which, bit(w.moved), w.x, w.y, w.offset.x, w.offset.y, bit(w.minimized))
	}
	fmt.sbprintfln(&out, "new_vertices %d", SPHERE_PRESETS[app.kit.add_size].vertices)
	if app.kit.palette_recent_count > 0 {
		strings.write_string(&out, "palette_recent")
		for e in app.kit.palette_recent[:app.kit.palette_recent_count] do fmt.sbprintf(&out, " %s", palette_entry_name(e))
		strings.write_byte(&out, '\n')
	}
	for i in 0 ..< app.preset_count {
		p := &app.presets[i]
		v := p.values
		alpha := app.alphas[v.alpha].name if v.alpha >= 0 && v.alpha < len(app.alphas) else "-"
		fmt.sbprintfln(&out, "preset %s %v %g %d %g %g %g %g %s %v %g %v %g %g %g %g %v", preset_escape(preset_name(p)), v.kind, v.strength, bit(v.falloff.drawn),
			v.falloff.curve.c1.x, v.falloff.curve.c1.y, v.falloff.curve.c2.x, v.falloff.curve.c2.y, preset_escape(alpha), v.alpha_mode, v.alpha_angle, v.stroke, v.lazy_px,
			v.color.r, v.color.g, v.color.b, v.cloth_mode)
	}
	if on.preset > 0 && on.preset <= app.preset_count do fmt.sbprintfln(&out, "brush_preset %s", preset_escape(preset_name(&app.presets[on.preset - 1])))
	for o in app.key_overrides[:app.key_override_count] {
		fmt.sbprintfln(&out, "key %s %s", command_name(o.command, o.arg), "none" if o.none else chord_text(o.chord))
	}
	for s, slot in app.kit.dock {
		if s.preset > 0 && s.preset <= app.preset_count {
			fmt.sbprintfln(&out, "dock %d preset %s", slot, preset_escape(preset_name(&app.presets[s.preset - 1])))
		} else {
			fmt.sbprintfln(&out, "dock %d brush %v", slot, s.kind)
		}
	}
	for n in 0 ..< USER_PIES {
		if !pie_changed(app, n) do continue
		for s, i in app.kit.pies[n] do fmt.sbprintfln(&out, "pie %d %d %s", n, i, command_name(s.id, s.arg) if s.id != .None else "empty")
	}
	for f in app.kit.favourites[:app.kit.favourite_count] do fmt.sbprintfln(&out, "favourite %s", command_name(f.id, f.arg))
	if err := os.write_entire_file(path, transmute([]u8)strings.to_string(out)); err != nil {
		log.warnf("settings: could not write %s: %v", path, err)
		return false
	}
	return true
}
