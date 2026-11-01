package main

import "core:fmt"
import "core:reflect"
import "core:strconv"
import "core:strings"

import "../geom"
import "../sculpt"

// Brush presets: named brushes the user makes, as Nomad's presets and Blender's brush
// assets are. A preset is a base brush with its own strength, falloff, alpha, stroke kind
// (with Spray's spread), lazy mouse and smoothing, Lock plane and Connected, paint colour and cloth
// mode; size, the pen settings and symmetry stay global, so switching brushes never
// changes how big the brush is.
// While the brush is on a preset, the brush's own slots hold the preset's values and the
// plain brush's are kept in Brush_Settings.plain, which leaving the preset puts back: a
// plain brush keeps its own strength, and what settings.txt remembers for it, whatever
// presets were used.
// Content packs bring presets too (Library.presets): they are picked as the person's own
// are, but are read-only; Save as new makes one of the person's own from one.

MAX_PRESETS :: 24
PRESET_NAME_MAX :: 32

// How Brush_Settings.preset and Dock_Slot.preset number presets: 0 is the plain brush, 1
// to preset_count the person's own (from 1), BUILT_IN_PRESET + j the built-in preset j
// (builtin_presets.odin), and PACK_PRESET + j the library's preset j, whose index never
// changes during a run (a removed pack's are marked gone).
PACK_PRESET :: 1 << 16

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
	// Brush_Settings.smoothing and pressure_smoothing: 1 (or 0, from a line written
	// before them) is off.
	smoothing:          f32,
	pressure_smoothing: f32,
	color:       [3]f32,
	cloth_mode:  sculpt.Cloth_Mode,
	lock_plane:  bool,
	connected:   bool,
	grab_depth:  bool,
	smooth_only: sculpt.Smooth_Only,
	// Grab's mode, Normal weight, Same side and Silhouette (Brush_Settings).
	grab_mode:       Grab_Mode,
	grab_normal:     f32,
	grab_same_side:  bool,
	grab_silhouette: bool,
	grab_topological: bool,
	elastic_volume:   f32, // Elastic's Volume (Brush_Settings.elastic_volume)
	// Snake hook's Pinch, Rake and Elastic tip (Brush_Settings.hook_*).
	hook_pinch:       f32,
	hook_rake:        f32,
	hook_elastic:     bool,
	smooth_stable:    bool, // Smooth's Stable (Brush_Settings.smooth_stable)
	smooth_mode:      sculpt.Smooth_Mode, // Smooth, Relax or Polish
	// The Samples section's (Brush_Settings.stabilize, sample_radius and the kind's
	// no_accumulate); sample_radius 0 (a line from before) is all of it.
	stabilize:        f32,
	sample_radius:    f32,
	no_accumulate:    bool,
	// The stroke's No back and forth and Directional (Brush_Settings.one_way, directional).
	one_way:          bool,
	directional:      bool,
	// Clay strips' tip, Trim dynamic's angle (degrees) and its switch, Flatten's plane
	// height and depth (Brush_Settings); preset_parse starts them as a fresh brush has them.
	tip_roundness:    f32,
	tip_scale:        f32,
	trim_angle:       f32,
	trim_dynamic:     bool,
	plane_height:     f32,
	plane_depth:      f32,
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
		smoothing = b.smoothing, pressure_smoothing = b.pressure_smoothing,
		cloth_mode = b.cloth_mode, lock_plane = b.lock_plane, connected = b.connected, grab_depth = b.grab_depth,
		smooth_only = b.smooth_only, grab_mode = b.grab_mode, grab_normal = b.grab_normal, grab_same_side = b.grab_same_side,
		grab_silhouette = b.grab_silhouette, grab_topological = b.grab_topological, elastic_volume = b.elastic_volume,
		hook_pinch = b.hook_pinch, hook_rake = b.hook_rake, hook_elastic = b.hook_elastic,
		smooth_stable = b.smooth_stable, smooth_mode = b.smooth_mode,
		stabilize = b.stabilize, sample_radius = b.sample_radius, no_accumulate = b.no_accumulate[kind],
		one_way = b.one_way, directional = b.directional,
		tip_roundness = b.tip_roundness, tip_scale = b.tip_scale, trim_angle = b.trim_angle, trim_dynamic = b.trim_dynamic,
		plane_height = b.plane_height, plane_depth = b.plane_depth,
	}
}

// Makes `v` the brush: its kind, that kind's slots and the global settings.
preset_values_put :: proc(b: ^Brush_Settings, v: Preset_Values) {
	b.kind = v.kind
	b.strengths[v.kind], b.falloffs[v.kind] = v.strength, v.falloff
	b.alpha, b.alpha_mode, b.alpha_angle = v.alpha, v.alpha_mode, v.alpha_angle
	b.stroke, b.spray_spread, b.lazy_px, b.color, b.cloth_mode = v.stroke, v.spread, v.lazy_px, v.color, v.cloth_mode
	b.smoothing, b.pressure_smoothing = f32(steady_count(v.smoothing)), f32(steady_count(v.pressure_smoothing))
	b.lock_plane, b.connected = v.lock_plane, v.connected
	b.grab_depth, b.smooth_only = v.grab_depth, v.smooth_only
	b.grab_mode, b.grab_normal, b.grab_same_side, b.grab_silhouette = v.grab_mode, v.grab_normal, v.grab_same_side, v.grab_silhouette
	b.grab_topological = v.grab_topological
	if v.kind == .Elastic do b.elastic_volume = v.elastic_volume
	if v.kind == .Snake_Hook do b.hook_pinch, b.hook_rake, b.hook_elastic = v.hook_pinch, v.hook_rake, v.hook_elastic
	if v.kind == .Smooth do b.smooth_stable, b.smooth_mode = v.smooth_stable, v.smooth_mode
	b.stabilize, b.sample_radius = v.stabilize, v.sample_radius if v.sample_radius > 0 else 1
	if accumulate_applies(v.kind) do b.no_accumulate[v.kind] = v.no_accumulate
	b.one_way, b.directional = v.one_way, v.directional
	// Each brush's own values only, so a Flatten preset leaves Clay strips' tip as set.
	#partial switch v.kind {
	case .Clay_Strips:  b.tip_roundness, b.tip_scale = v.tip_roundness, v.tip_scale
	case .Trim_Dynamic: b.trim_angle, b.trim_dynamic = v.trim_angle, v.trim_dynamic
	case .Flatten:      b.plane_height, b.plane_depth = v.plane_height, v.plane_depth
	}
}

// The preset numbered `n` (PACK_PRESET), if there is one.
preset_at :: proc(app: ^App, n: int) -> (^Brush_Preset, bool) {
	if preset_built_in(n) {
		// Made on first use, so an App of zeroes (tests, scripts) has them too.
		j := n - BUILT_IN_PRESET
		if app.built_in[j].name[0] == 0 do app.built_in[j] = built_in_preset(j)
		return &app.built_in[j], true
	}
	if n >= PACK_PRESET {
		j := n - PACK_PRESET
		if j >= len(app.library.presets) || app.library.presets[j].gone do return nil, false
		return &app.library.presets[j].preset, true
	}
	if n < 1 || n > app.preset_count do return nil, false
	return &app.presets[n - 1], true
}

// Whether `n` numbers a content pack's preset, which is read-only.
preset_of_pack :: proc(n: int) -> bool {
	return n >= PACK_PRESET
}

// The preset the brush is on, if any.
brush_preset :: proc(app: ^App) -> (^Brush_Preset, bool) {
	return preset_at(app, app.brush.preset)
}

// Puts the brush on preset `i` (from 0) of the person's own, and picks the Sculpt tool.
preset_pick :: proc(app: ^App, i: int) {
	preset_use(app, i + 1)
}

// Puts the brush on the preset numbered `n` (PACK_PRESET), and picks the Sculpt tool.
preset_use :: proc(app: ^App, n: int) {
	p, ok := preset_at(app, n)
	if !ok do return
	b := &app.brush
	preset_leave(app)
	v := p.values
	b.plain = preset_values_of(b, v.kind)
	preset_values_put(b, v)
	b.preset = n
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
// Grab, which takes none, Lock plane not for Grab or Cloth and Connected not for Cloth,
// which leave them, All depth only for Grab and Smooth only only for Smooth.
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
	if a.falloff.focal != b.falloff.focal || a.falloff.hardness != b.falloff.hardness do return false
	if a.kind != .Elastic && a.falloff.projected != b.falloff.projected do return false
	if a.stroke != b.stroke || a.lazy_px != b.lazy_px || (a.stroke == .Spray && a.spread != b.spread) do return false
	if steady_count(a.smoothing) != steady_count(b.smoothing) || steady_count(a.pressure_smoothing) != steady_count(b.pressure_smoothing) do return false
	if flags & {.Grab, .Cloth} == {} && a.lock_plane != b.lock_plane do return false
	if .Cloth not_in flags && a.connected != b.connected do return false
	if .Grab in flags && a.grab_depth != b.grab_depth do return false
	if a.kind == .Grab && (a.grab_mode != b.grab_mode || a.grab_normal != b.grab_normal || a.grab_same_side != b.grab_same_side || a.grab_silhouette != b.grab_silhouette || a.grab_topological != b.grab_topological) do return false
	if a.kind == .Elastic && (a.grab_mode != b.grab_mode || a.elastic_volume != b.elastic_volume) do return false
	if a.kind == .Snake_Hook && (a.hook_pinch != b.hook_pinch || a.hook_rake != b.hook_rake || a.hook_elastic != b.hook_elastic) do return false
	if a.kind == .Smooth && (a.smooth_only != b.smooth_only || a.smooth_stable != b.smooth_stable || a.smooth_mode != b.smooth_mode) do return false
	whole :: proc(x: f32) -> f32 {return x if x > 0 else 1}
	if a.stabilize != b.stabilize || whole(a.sample_radius) != whole(b.sample_radius) do return false
	if accumulate_applies(a.kind) && a.no_accumulate != b.no_accumulate do return false
	if a.one_way != b.one_way || a.directional != b.directional do return false
	if a.kind == .Clay_Strips && (a.tip_roundness != b.tip_roundness || a.tip_scale != b.tip_scale) do return false
	if a.kind == .Trim_Dynamic && (a.trim_dynamic != b.trim_dynamic || !a.trim_dynamic && a.trim_angle != b.trim_angle) do return false
	if a.kind == .Flatten && (a.plane_height != b.plane_height || a.plane_depth != b.plane_depth) do return false
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
	// A copy of a pack's or a built-in preset is named after it, so it reads as that one
	// made yours.
	base := BRUSHES[b.kind].name
	if from, on := brush_preset(app); on && preset_read_only(b.preset) do base = strings.clone(preset_name_fit_room(preset_name(from), 3), context.temp_allocator)
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

// Stores the brush's values in the preset it is on, when it is one of the person's own.
preset_save :: proc(app: ^App) {
	if preset_read_only(app.brush.preset) do return
	if p, ok := brush_preset(app); ok do p.values = preset_values_of(&app.brush, p.values.kind)
}

// Puts the brush back to the preset it is on.
preset_revert :: proc(app: ^App) {
	if p, ok := brush_preset(app); ok do preset_values_put(&app.brush, p.values)
}

// Deletes preset `i`, taking the brush off it first when it is on it.
preset_delete :: proc(app: ^App, i: int) {
	if i < 0 || i >= app.preset_count do return
	b := &app.brush
	if b.preset == i + 1 do preset_leave(app)
	copy(app.presets[i:app.preset_count], app.presets[i + 1:app.preset_count])
	app.preset_count -= 1
	app.presets[app.preset_count] = {}
	if b.preset > i + 1 && !preset_read_only(b.preset) do b.preset -= 1
	preset_slots_deleted(app, i)
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
	if built_in_preset_find(name) > 0 do return false
	preset_name_set(&app.presets[i], name)
	return true
}

// `name` cut to fit PRESET_NAME_MAX - 1 bytes without splitting a character.
preset_name_fit :: proc(name: string) -> string {
	return preset_name_fit_room(name, 0)
}

// `name` cut to leave `room` bytes more under PRESET_NAME_MAX - 1 (for a number after
// it), without splitting a character.
preset_name_fit_room :: proc(name: string, room: int) -> string {
	if len(name) + room < PRESET_NAME_MAX do return name
	n := PRESET_NAME_MAX - 1 - room
	for n > 0 && name[n] & 0xc0 == 0x80 do n -= 1
	return strings.trim_right_space(name[:n])
}

// The preset a name stands for in scripts: one of the person's own by its name, then a
// built-in by its name, or a pack's as `<pack id>/<name>` (ignoring case); 0 for none.
preset_by_ref :: proc(app: ^App, ref: string) -> int {
	if i := preset_find(app, ref); i >= 0 do return i + 1
	if n := built_in_preset_find(ref); n > 0 do return n
	slash := strings.index_byte(ref, '/')
	if slash < 0 do return 0
	return pack_preset_find(app, ref[:slash], ref[slash + 1:])
}

// How scripts and notes name the preset numbered `n`: its name (a built-in's too), or
// `<pack id>/<name>` for a pack's.
preset_ref :: proc(app: ^App, n: int) -> string {
	p, ok := preset_at(app, n)
	if !ok do return ""
	if preset_of_pack(n) do return fmt.tprintf("%s/%s", app.library.presets[n - PACK_PRESET].pack, preset_name(p))
	return preset_name(p)
}

// A `preset` line of settings.txt or a pack's brushes.txt, split into words: its name,
// values and alpha as written (a reference, a pack's own stem, or "-"); false for a
// damaged line.
// preset <name> <brush> <strength> <drawn 0|1> c1x c1y c2x c2y <alpha|-> <alpha mode>
//        <alpha angle> <stroke> <lazy px> r g b <cloth mode> [<spread> [<lock plane 0|1>
//        <connected 0|1> [<focal shift> [<all depth 0|1> <smooth only> [<smoothing>
//        <pressure smoothing> [<grab mode> <normal weight> <same side 0|1>
//        <silhouette 0|1> [<topological 0|1> [<elastic volume> [<hook pinch> <hook rake>
//        <hook elastic 0|1> [<key>=<value>...]]]]]]]]]]; names escaped
// (preset_escape). Lines from before Spray have no spread and take the default; lines
// from before Lock plane and Connected have both off; lines from before focal shift have
// none; lines from before All depth and Smooth only have Grab's round reach and Smooth
// on everything; lines from before the stabiliser have it off; lines from before Grab's
// modes grab freely on both sides; lines from before Topological weigh straight distance;
// lines from before Elastic's Volume take the default; lines from before Snake hook's
// Pinch, Rake and Elastic tip have none of them. After those come named values, each
// `key=value`, so a value added later needs no new length and a build that does not know a
// key skips just that value: smooth_stable=1 (Smooth's Stable), smooth_mode=Relax or Polish,
// stabilize=, sample_radius= and accumulate=0|1 (the Samples section), hardness= and
// shape=sphere|projected (the Falloff section's), one_way=1 and directional=1 (the
// stroke's), tip_roundness= and tip_scale= (Clay strips), trim_angle= and trim_dynamic=0
// (Trim dynamic) and plane_height= and plane_depth= (Flatten), each written only where it
// is not as a fresh brush has it. A line without accumulate= accumulates,
// and one without shape= takes its brush's default shape (projected_default).
preset_parse :: proc(f: []string) -> (name: string, v: Preset_Values, alpha: string, ok: bool) {
	if len(f) != 18 && len(f) != 19 && len(f) != 21 && len(f) != 22 && len(f) != 24 && len(f) != 26 && len(f) != 30 && len(f) != 31 && len(f) != 32 && len(f) < 35 do return
	kind, kind_ok := brush_by_name(f[2])
	alpha_mode, mode_ok := reflect.enum_from_name(Alpha_Mode, f[10])
	stroke, stroke_ok := reflect.enum_from_name(Stroke_Mode, f[12])
	cloth, cloth_ok := reflect.enum_from_name(sculpt.Cloth_Mode, f[17])
	if !kind_ok || !mode_ok || !stroke_ok || !cloth_ok do return
	number :: proc(s: string, fallback: f32) -> f32 {
		x, x_ok := strconv.parse_f32(s)
		return x if x_ok && x == x else fallback
	}
	// A falloff curve with a control point outside the unit square is the smooth one.
	curve := geom.Curve{{number(f[5], -1), number(f[6], -1)}, {number(f[7], -1), number(f[8], -1)}}
	for x in ([4]f32{curve.c1.x, curve.c1.y, curve.c2.x, curve.c2.y}) do if x < 0 || x > 1 do curve = FALLOFF_SMOOTH_CURVE
	v = {
		kind = kind, strength = clamp(number(f[3], BRUSHES[kind].strength), MIN_STRENGTH, 1),
		falloff = {drawn = f[4] == "1", curve = curve, projected = projected_default(kind)},
		alpha = -1, alpha_mode = alpha_mode, alpha_angle = number(f[11], 0), stroke = stroke,
		lazy_px = clamp(number(f[13], 0), 0, MAX_RADIUS_PX), cloth_mode = cloth,
		spread = clamp(number(f[18], SPRAY_DEFAULT_SPREAD), 0, SPRAY_MAX_SPREAD) if len(f) >= 19 else SPRAY_DEFAULT_SPREAD,
		lock_plane = len(f) >= 21 && f[19] == "1", connected = len(f) >= 21 && f[20] == "1",
	}
	if len(f) >= 22 do v.falloff.focal = clamp(number(f[21], 0), sculpt.FOCAL_MIN, sculpt.FOCAL_MAX)
	if len(f) >= 24 {
		only, only_ok := reflect.enum_from_name(sculpt.Smooth_Only, f[23])
		if !only_ok do return
		v.grab_depth, v.smooth_only = f[22] == "1", only
	}
	v.smoothing, v.pressure_smoothing = 1, 1
	if len(f) >= 26 {
		v.smoothing = f32(steady_count(number(f[24], 1)))
		v.pressure_smoothing = f32(steady_count(number(f[25], 1)))
	}
	if len(f) >= 30 {
		grab, grab_ok := reflect.enum_from_name(Grab_Mode, f[26])
		if !grab_ok do return
		v.grab_mode, v.grab_normal = grab, clamp(number(f[27], 0), 0, 1)
		v.grab_same_side, v.grab_silhouette = f[28] == "1", f[29] == "1"
	}
	v.elastic_volume = ELASTIC_VOLUME_DEFAULT
	if len(f) >= 31 do v.grab_topological = f[30] == "1"
	if len(f) >= 32 do v.elastic_volume = clamp(number(f[31], ELASTIC_VOLUME_DEFAULT), 0, 1)
	if len(f) >= 35 {
		v.hook_pinch, v.hook_rake = clamp(number(f[32], 0), -1, 1), clamp(number(f[33], 0), 0, 1)
		v.hook_elastic = f[34] == "1"
	}
	v.tip_roundness, v.tip_scale = sculpt.CLAY_TIP_ROUNDNESS, 1
	v.trim_angle, v.trim_dynamic = TRIM_ANGLE_DEFAULT_DEGREES, true
	v.plane_height, v.plane_depth = 1, 1
	for word in f[min(len(f), 35):] {
		key, _, value := strings.partition(word, "=")
		switch key {
		case "smooth_stable": v.smooth_stable = value == "1"
		case "stabilize": v.stabilize = clamp(number(value, 0), 0, sculpt.STABILIZE_MAX)
		case "sample_radius": v.sample_radius = clamp(number(value, 1), sculpt.SAMPLE_RADIUS_MIN, 1)
		case "accumulate": v.no_accumulate = value == "0"
		case "hardness": v.falloff.hardness = clamp(number(value, 0), 0, sculpt.HARDNESS_MAX)
		case "shape": if value == "sphere" || value == "projected" do v.falloff.projected = value == "projected"
		case "one_way": v.one_way = value == "1"
		case "tip_roundness": v.tip_roundness = clamp(number(value, sculpt.CLAY_TIP_ROUNDNESS), 0, 1)
		case "tip_scale": v.tip_scale = clamp(number(value, 1), sculpt.CLAY_TIP_SCALE_MIN, 1)
		case "trim_angle": v.trim_angle = clamp(number(value, TRIM_ANGLE_DEFAULT_DEGREES), 0, 160)
		case "trim_dynamic": v.trim_dynamic = value != "0"
		case "plane_height": v.plane_height = clamp(number(value, 1), 0, 1)
		case "plane_depth": v.plane_depth = clamp(number(value, 1), 0, 1)
		case "directional": v.directional = value == "1"
		case "smooth_mode":
			// A mode this build does not know smooths plainly.
			if mode, known := reflect.enum_from_name(sculpt.Smooth_Mode, value); known do v.smooth_mode = mode
		}
	}
	for k in 0 ..< 3 do v.color[k] = clamp(number(f[14 + k], 0), 0, 1)
	return preset_unescape(f[1]), v, preset_unescape(f[9]), true
}

// Writes the `preset` line preset_parse reads, with `alpha` as the alpha's word.
preset_line :: proc(out: ^strings.Builder, name: string, v: Preset_Values, alpha: string) {
	bit :: proc(b: bool) -> int {return 1 if b else 0}
	fmt.sbprintf(out, "preset %s %v %g %d %g %g %g %g %s %v %g %v %g %g %g %g %v %g %d %d", preset_escape(name), v.kind, v.strength, bit(v.falloff.drawn),
		v.falloff.curve.c1.x, v.falloff.curve.c1.y, v.falloff.curve.c2.x, v.falloff.curve.c2.y, preset_escape(alpha), v.alpha_mode, v.alpha_angle, v.stroke, v.lazy_px,
		v.color.r, v.color.g, v.color.b, v.cloth_mode, v.spread, bit(v.lock_plane), bit(v.connected))
	// Only a preset with a focal shift, All depth or Smooth only has the fields, so the
	// builds from before them, which skip a line of a length they do not know, keep every
	// other preset.
	stable := v.kind == .Smooth && v.smooth_stable
	smooth_mode := v.kind == .Smooth && v.smooth_mode != .Smooth
	sampled := v.stabilize > 0 || v.sample_radius > 0 && v.sample_radius < 1
	one_pass := accumulate_applies(v.kind) && v.no_accumulate
	shape := v.falloff.projected != projected_default(v.kind)
	tip := v.kind == .Clay_Strips && (v.tip_roundness != sculpt.CLAY_TIP_ROUNDNESS || v.tip_scale != 1)
	trim := v.kind == .Trim_Dynamic && (!v.trim_dynamic || v.trim_angle != TRIM_ANGLE_DEFAULT_DEGREES)
	plane := v.kind == .Flatten && (v.plane_height != 1 || v.plane_depth != 1)
	named := stable || smooth_mode || sampled || one_pass || v.falloff.hardness > 0 || shape || v.one_way || v.directional || tip || trim || plane
	hook := v.kind == .Snake_Hook && (v.hook_pinch != 0 || v.hook_rake != 0 || v.hook_elastic) || named
	volume := v.kind == .Elastic && v.elastic_volume != ELASTIC_VOLUME_DEFAULT || hook
	topological := v.grab_topological || volume
	grab := v.grab_mode != .Free || v.grab_normal != 0 || v.grab_same_side || v.grab_silhouette || topological
	steady := steady_count(v.smoothing) > 1 || steady_count(v.pressure_smoothing) > 1 || grab
	extra := v.grab_depth || v.smooth_only != .All || steady
	if v.falloff.focal != 0 || extra do fmt.sbprintf(out, " %g", v.falloff.focal)
	if extra do fmt.sbprintf(out, " %d %v", bit(v.grab_depth), v.smooth_only)
	if steady do fmt.sbprintf(out, " %d %d", steady_count(v.smoothing), steady_count(v.pressure_smoothing))
	if grab do fmt.sbprintf(out, " %v %g %d %d", v.grab_mode, v.grab_normal, bit(v.grab_same_side), bit(v.grab_silhouette))
	if topological do fmt.sbprintf(out, " %d", bit(v.grab_topological))
	if volume do fmt.sbprintf(out, " %g", v.elastic_volume)
	if hook do fmt.sbprintf(out, " %g %g %d", v.hook_pinch, v.hook_rake, bit(v.hook_elastic))
	if stable do fmt.sbprintf(out, " smooth_stable=1")
	if smooth_mode do fmt.sbprintf(out, " smooth_mode=%v", v.smooth_mode)
	if v.stabilize > 0 do fmt.sbprintf(out, " stabilize=%g", v.stabilize)
	if v.sample_radius > 0 && v.sample_radius < 1 do fmt.sbprintf(out, " sample_radius=%g", v.sample_radius)
	if one_pass do fmt.sbprintf(out, " accumulate=0")
	if v.falloff.hardness > 0 do fmt.sbprintf(out, " hardness=%g", v.falloff.hardness)
	if shape do fmt.sbprintf(out, " shape=%s", "projected" if v.falloff.projected else "sphere")
	if v.one_way do fmt.sbprintf(out, " one_way=1")
	if v.directional do fmt.sbprintf(out, " directional=1")
	if tip do fmt.sbprintf(out, " tip_roundness=%g tip_scale=%g", v.tip_roundness, v.tip_scale)
	if trim do fmt.sbprintf(out, " trim_angle=%g trim_dynamic=%d", v.trim_angle, bit(v.trim_dynamic))
	if plane do fmt.sbprintf(out, " plane_height=%g plane_depth=%g", v.plane_height, v.plane_depth)
	strings.write_byte(out, '\n')
}

preset_name_set :: proc(p: ^Brush_Preset, name: string) {
	p.name = {}
	copy(p.name[:PRESET_NAME_MAX - 1], preset_name_fit(name))
}

// Whether the plain brush's strength or falloff (its curve, focal shift, hardness and
// shape) differ from a fresh install's.
brush_reset_needed :: proc(app: ^App) -> bool {
	b := &app.brush
	f := b.falloffs[b.kind]
	return b.preset == 0 && (b.strengths[b.kind] != BRUSHES[b.kind].strength || f.drawn || f.focal != 0 || f.hardness != 0 || f.projected != projected_default(b.kind))
}

// Puts the plain brush's strength and falloff back to a fresh install's.
brush_reset :: proc(app: ^App) {
	b := &app.brush
	if b.preset != 0 do return
	b.strengths[b.kind] = BRUSHES[b.kind].strength
	b.falloffs[b.kind] = {projected = projected_default(b.kind)}
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
