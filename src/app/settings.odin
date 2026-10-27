package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:reflect"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

import "../camera"
import "../geom"
import "../gizmo"
import "../sculpt"
import "../ui"

// What the app remembers between interactive runs: the brush settings, how the
// viewport looks, the Scene palette's choices and the Settings panel's, in a text file of `key values...`
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
// what type it is (bool, f32, i32, int or an enum) and, for numbers, the range a value read
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
	{"lock_plane", B + offset_of(Brush_Settings, lock_plane), bool, 0, 0},
	{"connected", B + offset_of(Brush_Settings, connected), bool, 0, 0},
	{"symmetry_local", B + offset_of(Brush_Settings, sym_local), bool, 0, 0},
	{"radial", B + offset_of(Brush_Settings, radial_on), bool, 0, 0},
	{"radial_count", B + offset_of(Brush_Settings, radial_count), i32, RADIAL_MIN, sculpt.RADIAL_MAX},
	{"radial_axis", B + offset_of(Brush_Settings, radial_axis), sculpt.Axis, 0, 0},
	{"stroke", B + offset_of(Brush_Settings, stroke), Stroke_Mode, 0, 0},
	{"stroke_spread", B + offset_of(Brush_Settings, spray_spread), f32, 0, SPRAY_MAX_SPREAD},
	{"stroke_line", B + offset_of(Brush_Settings, line), bool, 0, 0},
	{"stroke_join", B + offset_of(Brush_Settings, join), bool, 0, 0},
	{"detail_px", B + offset_of(Brush_Settings, detail_px), f32, 2, 40},
	{"collapse", B + offset_of(Brush_Settings, collapse), bool, 0, 0},
	{"alpha_mode", B + offset_of(Brush_Settings, alpha_mode), Alpha_Mode, 0, 0},
	{"alpha_angle", B + offset_of(Brush_Settings, alpha_angle), f32, 0, 0},
	{"show_groups", offset_of(App, show_groups), bool, 0, 0},
	{"gizmo_mode", offset_of(App, move) + offset_of(Move_Tool, mode), gizmo.Mode, 0, 0},
	{"gizmo_snap", offset_of(App, move) + offset_of(Move_Tool, snap), bool, 0, 0},
	{"crease_degrees", U + offset_of(Ui_State, crease_degrees), f32, 1, 90},
	{"rebuild_goal", U + offset_of(Ui_State, rebuild_goal), Rebuild_Goal, 0, 0},
	{"rebuild_even", U + offset_of(Ui_State, rebuild_even), i32, REBUILD_MIN_VERTICES, REBUILD_MAX_VERTICES},
	{"rebuild_fewer", U + offset_of(Ui_State, rebuild_fewer), i32, REBUILD_MIN_VERTICES, REBUILD_MAX_VERTICES},
	{"retopo_quads", U + offset_of(Ui_State, retopo_quads), i32, 100, 1_000_000},
	{"wireframe", offset_of(App, wireframe), bool, 0, 0},
	{"polyframe_lines", offset_of(App, polyframe_lines), bool, 0, 0},
	{"polyframe_fill", offset_of(App, polyframe_fill), bool, 0, 0},
	{"floor_grid", offset_of(App, floor) + offset_of(Floor_Settings, on), bool, 0, 0},
	{"floor_x", offset_of(App, floor) + offset_of(Floor_Settings, planes) + 0 * size_of(bool), bool, 0, 0},
	{"floor_y", offset_of(App, floor) + offset_of(Floor_Settings, planes) + 1 * size_of(bool), bool, 0, 0},
	{"floor_z", offset_of(App, floor) + offset_of(Floor_Settings, planes) + 2 * size_of(bool), bool, 0, 0},
	{"floor_axes", offset_of(App, floor) + offset_of(Floor_Settings, axes), bool, 0, 0},
	{"floor_fit", offset_of(App, floor) + offset_of(Floor_Settings, fit), bool, 0, 0},
	{"floor_cell", offset_of(App, floor) + offset_of(Floor_Settings, cell), f32, FLOOR_CELL_MIN, FLOOR_CELL_MAX},
	{"background_gradient", offset_of(App, background) + offset_of(Background_Settings, gradient), bool, 0, 0},
	{"transparent", offset_of(App, see_through), bool, 0, 0},
	{"flat", offset_of(App, flat), bool, 0, 0},
	{"exposure", offset_of(App, exposure), f32, -EXPOSURE_RANGE, EXPOSURE_RANGE},
	{"cavity", offset_of(App, cavity), f32, 0, 1},
	{"light_turn", offset_of(App, light_turn), f32, -180, 180},
	{"light_height", offset_of(App, light_height), f32, -90, 90},
	{"light_key", offset_of(App, light_key), f32, 0, LIGHT_STRENGTH_MAX},
	{"light_fill", offset_of(App, light_fill), f32, 0, LIGHT_STRENGTH_MAX},
	{"lights_fixed", offset_of(App, lights_fixed), bool, 0, 0},
	{"dim_others", offset_of(App, dim_others), bool, 0, 0},
	{"ridge", offset_of(App, ridge), f32, 0, 1},
	{"reduce_motion", K + offset_of(Kit_State, ctx) + offset_of(ui.Context, reduced_motion), bool, 0, 0},
	{"ortho", offset_of(App, camera) + offset_of(camera.Orbit, ortho), bool, 0, 0},
	{"fov", offset_of(App, camera) + offset_of(camera.Orbit, fov_y), f32, camera.FOV_MIN, camera.FOV_MAX},
	// Settings > Interface, Camera, Touch and Performance.
	{"surface_ring", K + offset_of(Kit_State, surface_ring), bool, 0, 0},
	{"action_bar", K + offset_of(Kit_State, action_bar), bool, 0, 0},
	{"modifier_rail", K + offset_of(Kit_State, rail_side), Rail_Side, 0, 0},
	{"wheel_size", K + offset_of(Kit_State, wheel_size), Wheel_Size, 0, 0},
	{"wheel_labels", K + offset_of(Kit_State, wheel_labels), Wheel_Labels, 0, 0},
	{"wheel_turn", K + offset_of(Kit_State, wheel_turn), f32, -180, 180},
	{"wheel_x", K + offset_of(Kit_State, wheel_offset) + 0 * size_of(f32), f32, 0, 0},
	{"wheel_y", K + offset_of(Kit_State, wheel_offset) + 1 * size_of(f32), f32, 0, 0},
	{"look", K + offset_of(Kit_State, look), Look, 0, 0},
	{"all_options", K + offset_of(Kit_State, all_options), bool, 0, 0},
	{"coach", K + offset_of(Kit_State, coach), i32, 0, f32(COACH_DONE)},
	{"stats", K + offset_of(Kit_State, stats), bool, 0, 0},
	{"stats_advanced", K + offset_of(Kit_State, stats_advanced), bool, 0, 0},
	{"vsync", offset_of(App, vsync), bool, 0, 0},
	{"msaa", offset_of(App, msaa), Msaa, 0, 0},
	{"autosave_minutes", offset_of(App, autosave) + offset_of(Autosave, minutes), i32, 0, 10},
	{"versions_kept", offset_of(App, versions_kept), i32, 0, 10},
	{"orbit_style", N + offset_of(Nav_Prefs, orbit_style), camera.Orbit_Style, 0, 0},
	{"mouse_scheme", N + offset_of(Nav_Prefs, mouse_scheme), Mouse_Scheme, 0, 0},
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
	{"touch_strength", N + offset_of(Nav_Prefs, touch_strength), f32, TOUCH_STRENGTH_MIN, 1},
	{"palm_rejection", N + offset_of(Nav_Prefs, palm_rejection), bool, 0, 0},
	{"double_tap", N + offset_of(Nav_Prefs, double_tap), bool, 0, 0},
	{"lift_one_orbit", N + offset_of(Nav_Prefs, lift_one_orbit), bool, 0, 0},
	{"orbit_pivot", N + offset_of(Nav_Prefs, pivot), Orbit_Pivot, 0, 0},
	{"edge_orbit", N + offset_of(Nav_Prefs, edge_orbit), bool, 0, 0},
	{"edge_size", N + offset_of(Nav_Prefs, edge_size), f32, EDGE_MIN, EDGE_MAX},
	{"edge_show", N + offset_of(Nav_Prefs, edge_show), bool, 0, 0},
	{"shape_apply", N + offset_of(Nav_Prefs, shape_apply), Shape_Apply, 0, 0},
	{"pen_tips", N + offset_of(Nav_Prefs, pen_tips), Pen_Tips, 0, 0},
	// The Scene and Object palettes' choices, and the tools'.
	{"new_shape", K + offset_of(Kit_State, add_shape), geom.Primitive, 0, 0},
	{"new_voxels", K + offset_of(Kit_State, add_voxel), bool, 0, 0},
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

// Sets the row's field from the text `value`, as the settings file holds it: any bool
// that is not "1" is off and a number out of range is brought into it. False, and the
// field as it was, when the text is not a value of its type.
setting_read :: proc(app: ^App, s: Setting, value: string) -> bool {
	v := setting_parse(s, value, strict = false) or_return
	setting_write(app, s, v)
	return true
}

// The value of the text `value` for the row, as a number: a bool is 0 or 1, an enum its
// value. Nothing is written, so a script can be checked whole before it runs. `strict`,
// for scripts, takes only on/off, true/false, yes/no or 1/0 for a bool, refuses a number
// out of the row's range rather than bringing it in, and reads `-` in an enum's name as
// `_`; the file reader is lenient, as it always was.
setting_parse :: proc(s: Setting, value: string, strict: bool) -> (v: f64, ok: bool) {
	switch s.type {
	case bool:
		if !strict do return 1 if value == "1" else 0, true
		switch strings.to_lower(value, context.temp_allocator) {
		case "1", "on", "true", "yes":  return 1, true
		case "0", "off", "false", "no": return 0, true
		}
		return
	case f32, i32, int:
		n := strconv.parse_f64(value) or_return
		if n != n do return
		// A count takes a whole number from a script; the file never held anything else.
		if strict && s.type != f32 && n != math.floor(n) do return
		if s.lo < s.hi {
			if strict && (n < f64(s.lo) || n > f64(s.hi)) do return
			n = clamp(n, f64(s.lo), f64(s.hi))
		}
		return n if s.type != f32 else f64(f32(n)), true
	}
	// An enum, by the name of one of its values, in any case.
	want := value
	if strict do want, _ = strings.replace_all(value, "-", "_", context.temp_allocator)
	names, values := reflect.enum_field_names(s.type), reflect.enum_field_values(s.type)
	for name, i in names do if strings.equal_fold(name, want) do return f64(values[i]), true
	return
}

// Sets the row's field to `v`, as setting_parse gives it.
setting_write :: proc(app: ^App, s: Setting, v: f64) {
	at := rawptr(uintptr(app) + s.offset)
	switch s.type {
	case bool: (^bool)(at)^ = v != 0
	case f32:  (^f32)(at)^ = f32(v)
	case i32:  (^i32)(at)^ = i32(v)
	case int:  (^int)(at)^ = int(v)
	case:
		switch reflect.size_of_typeid(s.type) {
		case 1: (^u8)(at)^ = u8(i64(v))
		case 2: (^u16)(at)^ = u16(i64(v))
		case 4: (^u32)(at)^ = u32(i64(v))
		case 8: (^u64)(at)^ = u64(i64(v))
		}
	}
}

// The row's field as the file holds it.
setting_text :: proc(app: ^App, s: Setting) -> string {
	at := rawptr(uintptr(app) + s.offset)
	switch s.type {
	case bool: return "1" if (^bool)(at)^ else "0"
	case f32:  return fmt.tprintf("%g", (^f32)(at)^)
	case i32:  return fmt.tprintf("%d", (^i32)(at)^)
	case int:  return fmt.tprintf("%d", (^int)(at)^)
	}
	return fmt.tprintf("%v", any{at, s.type})
}

// A remembered value with more to it than one field, which scripts set too (`set
// symmetry xz`): read and checked by `parse`, which writes nothing, and then applied, so
// the settings file and a script read it the same way; `text` writes what parse reads,
// for the settings file and a recorded macro.
Setting_Line :: struct {
	key:   string,
	parse: proc(f: []string) -> (Setting_Line_Value, bool),
	apply: proc(app: ^App, v: Setting_Line_Value),
	text:  proc(app: ^App) -> string,
}

Setting_Line_Value :: union {
	sculpt.Symmetry,
	[3]f32,
	int,
}

@(rodata)
SETTING_LINES := [?]Setting_Line {
	{
		// The axes, as letters after a "-" that keeps the line from being empty with
		// none: "-xz", "-"; scripts may leave the "-" out ("xz").
		"symmetry",
		proc(f: []string) -> (Setting_Line_Value, bool) {
			if len(f) != 1 do return nil, false
			axes: sculpt.Symmetry
			for c in strings.trim_prefix(f[0], "-") {
				switch c {
				case 'x', 'X': axes += {.X}
				case 'y', 'Y': axes += {.Y}
				case 'z', 'Z': axes += {.Z}
				case: return nil, false
				}
			}
			return axes, true
		},
		proc(app: ^App, v: Setting_Line_Value) {app.brush.symmetry = v.(sculpt.Symmetry)},
		proc(app: ^App) -> string {
			s := app.brush.symmetry
			// A placeholder "-", so the line always has a value.
			return fmt.tprintf("-%s%s%s", "x" if .X in s else "", "y" if .Y in s else "", "z" if .Z in s else "")
		},
	},
	{
		// The Paint brush's colour, red, green and blue from 0 to 1.
		"paint_color",
		rgb_parse,
		proc(app: ^App, v: Setting_Line_Value) {app.brush.color = v.([3]f32)},
		proc(app: ^App) -> string {return rgb_text(app.brush.color)},
	},
	{
		// The viewport background's colour along its top edge (the whole of it without
		// the gradient), as paint_color is written.
		"background_top",
		rgb_parse,
		proc(app: ^App, v: Setting_Line_Value) {app.background.top = v.([3]f32)},
		proc(app: ^App) -> string {return rgb_text(app.background.top)},
	},
	{
		// The gradient's colour along the bottom edge.
		"background_bottom",
		rgb_parse,
		proc(app: ^App, v: Setting_Line_Value) {app.background.bottom = v.([3]f32)},
		proc(app: ^App) -> string {return rgb_text(app.background.bottom)},
	},
	{
		// A material by its name, which may have spaces ("red wax").
		"material",
		proc(f: []string) -> (Setting_Line_Value, bool) {
			i, ok := material_by_name(strings.join(f, " ", context.temp_allocator))
			return i, ok
		},
		proc(app: ^App, v: Setting_Line_Value) {app.material = v.(int)},
		proc(app: ^App) -> string {return string(current_material(app).label)},
	},
	{
		// The size an object is added and remeshed at, in vertices: the nearest of the
		// presets.
		"new_vertices",
		proc(f: []string) -> (Setting_Line_Value, bool) {
			if len(f) != 1 do return nil, false
			want, ok := strconv.parse_f32(f[0])
			if !ok || !(want > 0) do return nil, false
			best, size := f32(-1), 0
			for p, i in SPHERE_PRESETS {
				if d := abs(f32(p.vertices) - want); best < 0 || d < best do size, best = i, d
			}
			return size, true
		},
		proc(app: ^App, v: Setting_Line_Value) {app.kit.add_size = v.(int)},
		proc(app: ^App) -> string {return fmt.tprint(SPHERE_PRESETS[app.kit.add_size].vertices)},
	},
}

// A colour's line: red, green and blue from 0 to 1.
@(private = "file")
rgb_parse :: proc(f: []string) -> (Setting_Line_Value, bool) {
	if len(f) != 3 do return nil, false
	c: [3]f32
	for k in 0 ..< 3 {
		v, ok := strconv.parse_f32(f[k])
		if !ok || !(v >= 0 && v <= 1) do return nil, false
		c[k] = v
	}
	return c, true
}

@(private = "file")
rgb_text :: proc(c: [3]f32) -> string {
	return fmt.tprintf("%g %g %g", c.r, c.g, c.b)
}

// The line row of `key`; a row with no procedures when there is none.
setting_line :: proc(key: string) -> Setting_Line {
	for line in SETTING_LINES do if line.key == key do return line
	return {}
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
	// The plain brush's alpha, by reference, put on before the preset, which brings its own.
	plain_alpha := ""
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
					b.falloffs[kind].drawn, b.falloffs[kind].curve = f[2] == "1", curve(f[3:], b.falloffs[kind].curve)
				}
			}
		case "focal":
			// focal <brush> <shift>, for the brushes whose focal shift is not 0.
			if len(f) == 3 {
				if kind, ok := brush_by_name(f[1]); ok do b.falloffs[kind].focal = clamp(number(f[2], 0), sculpt.FOCAL_MIN, sculpt.FOCAL_MAX)
			}
		case "pressure_curve": if len(f) == 5 do b.pressure_curve = curve(f[1:], b.pressure_curve)
		case "symmetry", "paint_color", "background_top", "background_bottom", "material", "new_vertices":
			line := setting_line(f[0])
			if v, ok := line.parse(f[1:]); ok do line.apply(app, v)
		case "custom_material":
			// custom_material r g b metallic roughness [matcap]; the matcap, 0 for none,
			// 1 + a built-in's place or MATCAP_IMAGE, came with MatCaps.
			if len(f) >= 6 {
				c := &app.custom
				for k in 0 ..< 3 do c.selected[k] = clamp(number(f[1 + k], c.selected[k]), 0, 1)
				c.metallic = clamp(number(f[4], c.metallic), 0, 1)
				c.roughness = clamp(number(f[5], c.roughness), 0.04, 1)
				if len(f) >= 7 {
					c.matcap = clamp(int(number(f[6], 0)), 0, MATCAP_IMAGE)
					if c.matcap != 0 do c.idle = MATCAP_IDLE
				}
			}
		case "matcap_image":
			// matcap_image <path, escaped>: the image Load MatCap loaded last.
			_ = matcap_image_load(app, preset_unescape(f[1]), quiet = true)
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
			// The line preset_parse reads. A damaged line, or one whose name is taken, is
			// skipped.
			name, v, alpha, ok := preset_parse(f)
			if !ok || app.preset_count == MAX_PRESETS do continue
			// By reference: a built-in's name or a library alpha's `mine/<stem>`; one that is
			// not there (taken out of the library) leaves the preset round.
			v.alpha = alpha_find(app, alpha)
			app.presets[app.preset_count].values = v
			app.preset_count += 1
			if !preset_rename(app, app.preset_count - 1, name) {
				app.preset_count -= 1
				app.presets[app.preset_count] = {}
			}
		case "brush_preset":
			on_preset = strings.clone(preset_unescape(f[1]), context.temp_allocator)
		case "brush_pack_preset":
			// brush_pack_preset <pack id> <name, escaped>: the brush is on a content pack's preset.
			if len(f) == 3 do on_preset = fmt.tprintf("%s/%s", f[1], preset_unescape(f[2]))
		case "brush_alpha":
			plain_alpha = strings.clone(preset_unescape(f[1]), context.temp_allocator)
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
		case "dock_pack":
			// dock_pack <slot> <pack id> <name, escaped>: a slot holding a content pack's
			// preset, written after the slot's own dock line, which older versions read.
			slot, slot_ok := strconv.parse_int(f[1])
			if len(f) != 4 || !slot_ok || slot < 0 || slot >= DOCK_SLOTS do continue
			dock_presets[slot] = fmt.tprintf("%s/%s", f[2], preset_unescape(f[3]))
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
		case "gesture_map":
			// gesture_map <Slot> <command name|none>, for the slots that differ from the
			// defaults ("gesture" alone is the Ctrl+Shift drag's tool).
			slot, slot_ok := reflect.enum_from_name(Gesture_Slot, f[1])
			if len(f) != 3 || !slot_ok do continue
			if f[2] == "none" {
				app.nav.gestures[slot] = {}
			} else if id, arg, ok := command_from_name(f[2]); ok && gesture_lists(id) {
				app.nav.gestures[slot] = {id, arg}
			}
		case "tap_history", "hold_history":
			// Before the gesture map: the taps, or the holds, of two and three fingers were
			// turned off as a pair. A later gesture line wins.
			if f[1] != "0" do continue
			if f[0] == "tap_history" do app.nav.gestures[.Two_Tap], app.nav.gestures[.Three_Tap] = {}, {}
			else do app.nav.gestures[.Two_Hold], app.nav.gestures[.Three_Hold] = {}, {}
		case "favourite":
			// favourite <command name>, in the order they were starred.
			id, arg, ok := command_from_name(f[1])
			if ok && palette_lists(id) && favourite_find(app, id, arg) < 0 && app.kit.favourite_count < MAX_FAVOURITES {
				app.kit.favourites[app.kit.favourite_count] = {id, arg}
				app.kit.favourite_count += 1
			}
		}
	}
	// On a preset of the brush the file names, it is put back on it; its plain values are
	// the ones just read.
	if plain_alpha != "" do b.alpha = alpha_find(app, plain_alpha)
	if n := preset_by_ref(app, on_preset); n > 0 {
		if p, _ := preset_at(app, n); p.values.kind == b.kind do preset_use(app, n)
	}
	// A slot naming a preset the file (or the library) does not have keeps what it held.
	for name, slot in dock_presets {
		if n := preset_by_ref(app, name); name != "" && n > 0 do dock_put(app, slot, .Draw, n)
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
		if f.focal != 0 do fmt.sbprintfln(&out, "focal %v %g", kind, f.focal)
	}
	c := b.pressure_curve
	fmt.sbprintfln(&out, "pressure_curve %g %g %g %g", c.c1.x, c.c1.y, c.c2.x, c.c2.y)
	for line in SETTING_LINES do fmt.sbprintfln(&out, "%s %s", line.key, line.text(app))
	m := app.custom
	fmt.sbprintfln(&out, "custom_material %g %g %g %g %g %d", m.selected.r, m.selected.g, m.selected.b, m.metallic, m.roughness, m.matcap)
	if app.matcap_path != "" do fmt.sbprintfln(&out, "matcap_image %s", preset_escape(app.matcap_path))
	k := app.kit
	fmt.sbprintfln(&out, "ui_scale %g", k.ui_scale)
	for w, which in k.windows {
		fmt.sbprintfln(&out, "window %v %d %v %v %g %g %d", which, bit(w.moved), w.x, w.y, w.offset.x, w.offset.y, bit(w.minimized))
	}
	if app.kit.palette_recent_count > 0 {
		strings.write_string(&out, "palette_recent")
		for e in app.kit.palette_recent[:app.kit.palette_recent_count] do fmt.sbprintf(&out, " %s", palette_entry_name(e))
		strings.write_byte(&out, '\n')
	}
	for i in 0 ..< app.preset_count do preset_line(&out, preset_name(&app.presets[i]), app.presets[i].values, alpha_ref(app, app.presets[i].values.alpha))
	if p, ok := preset_at(app, on.preset); ok {
		if preset_of_pack(on.preset) do fmt.sbprintfln(&out, "brush_pack_preset %s %s", app.library.presets[on.preset - PACK_PRESET].pack, preset_escape(preset_name(p)))
		else do fmt.sbprintfln(&out, "brush_preset %s", preset_escape(preset_name(p)))
	}
	fmt.sbprintfln(&out, "brush_alpha %s", preset_escape(alpha_ref(app, app.brush.alpha)))
	for o in app.key_overrides[:app.key_override_count] {
		fmt.sbprintfln(&out, "key %s %s", command_name(o.command, o.arg), "none" if o.none else chord_text(o.chord))
	}
	for s, slot in app.kit.dock {
		if s.preset > 0 && s.preset <= app.preset_count {
			fmt.sbprintfln(&out, "dock %d preset %s", slot, preset_escape(preset_name(&app.presets[s.preset - 1])))
		} else {
			fmt.sbprintfln(&out, "dock %d brush %v", slot, s.kind)
			if p, ok := preset_at(app, s.preset); ok && preset_of_pack(s.preset) {
				fmt.sbprintfln(&out, "dock_pack %d %s %s", slot, app.library.presets[s.preset - PACK_PRESET].pack, preset_escape(preset_name(p)))
			}
		}
	}
	for n in 0 ..< USER_PIES {
		if !pie_changed(app, n) do continue
		for s, i in app.kit.pies[n] do fmt.sbprintfln(&out, "pie %d %d %s", n, i, command_name(s.id, s.arg) if s.id != .None else "empty")
	}
	for f in app.kit.favourites[:app.kit.favourite_count] do fmt.sbprintfln(&out, "favourite %s", command_name(f.id, f.arg))
	gestures := GESTURE_DEFAULTS
	for s, slot in app.nav.gestures {
		if s != gestures[slot] do fmt.sbprintfln(&out, "gesture_map %v %s", slot, command_name(s.id, s.arg) if s.id != .None else "none")
	}
	if err := os.write_entire_file(path, transmute([]u8)strings.to_string(out)); err != nil {
		log.warnf("settings: could not write %s: %v", path, err)
		return false
	}
	return true
}
