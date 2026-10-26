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
		case "new_vertices":
			// The size an object is added and remeshed at: the nearest of the presets.
			want := number(f[1], -1)
			best := f32(-1)
			for p, i in SPHERE_PRESETS {
				if d := abs(f32(p.vertices) - want); want > 0 && (best < 0 || d < best) do app.kit.add_size, best = i, d
			}
		}
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
	if err := os.write_entire_file(path, transmute([]u8)strings.to_string(out)); err != nil {
		log.warnf("settings: could not write %s: %v", path, err)
		return false
	}
	return true
}
