package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

import "../geom"
import "../sculpt"

// What the app remembers between interactive runs: the brush settings, how the
// viewport looks and the Scene panel's choices, in a text file of `key values...`
// lines in SDL's per-user folder. Runs with --frames, a benchmark or --no-settings
// neither read nor write it, so scripted runs stay reproducible. Flags given on the
// command line win over what it holds. Unknown or malformed lines are skipped, so an
// older or newer file never stops the app.

SETTINGS_FILE :: "settings.txt"

// Where the settings live, or "" when SDL has no folder for them (temp memory).
settings_path :: proc() -> string {
	dir := sdl.GetPrefPath("Implicit", "Sculpt")
	if dir == nil do return ""
	defer sdl.free(dir)
	return strings.concatenate({string(cstring(dir)), SETTINGS_FILE}, context.temp_allocator)
}

// Applies what the file at `path` holds to the app. A missing file is no error.
settings_load :: proc(app: ^App, path: string) {
	if path == "" do return
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	b := &app.brush
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) < 2 do continue
		switch f[0] {
		case "brush":
			if kind, ok := brush_by_name(f[1]); ok do b.kind = kind
		case "radius_px":
			b.radius_px = clamp(number(f[1], b.radius_px), MIN_RADIUS_PX, MAX_RADIUS_PX)
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
		case "pressure_strength": b.pressure_strength = f[1] == "1"
		case "pressure_size":     b.pressure_size = f[1] == "1"
		case "pressure_curve":    if len(f) == 5 do b.pressure_curve = curve(f[1:], b.pressure_curve)
		case "tilt_strength":     b.tilt_strength = clamp(number(f[1], b.tilt_strength), 0, 1)
		case "lazy_px":           b.lazy_px = clamp(number(f[1], b.lazy_px), 0, 150)
		case "front_only":        b.front_only = f[1] == "1"
		case "symmetry":
			b.symmetry = {}
			for c in f[1] {
				switch c {
				case 'x': b.symmetry += {.X}
				case 'y': b.symmetry += {.Y}
				case 'z': b.symmetry += {.Z}
				}
			}
		case "detail_px":  b.detail_px = clamp(number(f[1], b.detail_px), 2, 40)
		case "collapse":   b.collapse = f[1] == "1"
		case "alpha_mode":
			for mode in Alpha_Mode do if strings.equal_fold(f[1], fmt.tprint(mode)) do b.alpha_mode = mode
		case "alpha_angle": b.alpha_angle = number(f[1], b.alpha_angle)
		case "material":
			if i, ok := material_by_name(strings.join(f[1:], " ", context.temp_allocator)); ok do app.material = i
		case "wireframe":  app.wireframe = f[1] == "1"
		case "ortho":      app.camera.ortho = f[1] == "1"
		case "new_vertices":
			app.ui.sphere_vertices = i32(clamp(int(number(f[1], f32(app.ui.sphere_vertices))), MIN_SPHERE_VERTICES, MAX_SPHERE_VERTICES))
		case "new_shape":
			for shape in geom.Primitive do if strings.equal_fold(f[1], fmt.tprint(shape)) do app.ui.add_shape = shape
		case "mask_steps":  app.ui.mask_steps = i32(clamp(number(f[1], f32(app.ui.mask_steps)), 1, 50))
		case "mask_shape":
			for kind in Mask_Shape_Kind do if strings.equal_fold(f[1], fmt.tprint(kind)) do app.ui.mask_shape_kind = kind
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
	fmt.sbprintfln(&out, "brush %s", fmt.tprint(b.kind))
	fmt.sbprintfln(&out, "radius_px %g", b.radius_px)
	for kind in sculpt.Brush_Kind {
		fmt.sbprintfln(&out, "strength %v %g", kind, b.strengths[kind])
		f := b.falloffs[kind]
		fmt.sbprintfln(&out, "falloff %v %d %g %g %g %g", kind, bit(f.drawn), f.curve.c1.x, f.curve.c1.y, f.curve.c2.x, f.curve.c2.y)
	}
	fmt.sbprintfln(&out, "pressure_strength %d", bit(b.pressure_strength))
	fmt.sbprintfln(&out, "pressure_size %d", bit(b.pressure_size))
	c := b.pressure_curve
	fmt.sbprintfln(&out, "pressure_curve %g %g %g %g", c.c1.x, c.c1.y, c.c2.x, c.c2.y)
	fmt.sbprintfln(&out, "tilt_strength %g", b.tilt_strength)
	fmt.sbprintfln(&out, "lazy_px %g", b.lazy_px)
	fmt.sbprintfln(&out, "front_only %d", bit(b.front_only))
	symmetry := strings.builder_make(context.temp_allocator)
	strings.write_string(&symmetry, "-") // a placeholder, so the line always has a value
	if .X in b.symmetry do strings.write_byte(&symmetry, 'x')
	if .Y in b.symmetry do strings.write_byte(&symmetry, 'y')
	if .Z in b.symmetry do strings.write_byte(&symmetry, 'z')
	fmt.sbprintfln(&out, "symmetry %s", strings.to_string(symmetry))
	fmt.sbprintfln(&out, "detail_px %g", b.detail_px)
	fmt.sbprintfln(&out, "collapse %d", bit(b.collapse))
	fmt.sbprintfln(&out, "alpha_mode %v", b.alpha_mode)
	fmt.sbprintfln(&out, "alpha_angle %g", b.alpha_angle)
	fmt.sbprintfln(&out, "material %s", MATERIALS[app.material].label)
	fmt.sbprintfln(&out, "wireframe %d", bit(app.wireframe))
	fmt.sbprintfln(&out, "ortho %d", bit(app.camera.ortho))
	fmt.sbprintfln(&out, "new_vertices %d", app.ui.sphere_vertices)
	fmt.sbprintfln(&out, "new_shape %v", app.ui.add_shape)
	fmt.sbprintfln(&out, "mask_steps %d", app.ui.mask_steps)
	fmt.sbprintfln(&out, "mask_shape %v", app.ui.mask_shape_kind)
	if err := os.write_entire_file(path, transmute([]u8)strings.to_string(out)); err != nil {
		log.warnf("settings: could not write %s: %v", path, err)
		return false
	}
	return true
}
