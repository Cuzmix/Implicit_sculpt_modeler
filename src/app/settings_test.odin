package main

import "base:runtime"
import "core:os"
import "core:reflect"
import "core:testing"

import "../camera"
import "../sculpt"

// Each row's offset, the script-only values' too, lands on a field of App of exactly the row's type: a row that
// pointed half into another field, or named the wrong type, would write past it.
@(test)
every_setting_names_its_field :: proc(t: ^testing.T) {
	field_is :: proc(T: typeid, offset: uintptr, want: typeid) -> bool {
		if offset == 0 && T == want do return true
		#partial switch v in runtime.type_info_base(type_info_of(T)).variant {
		case runtime.Type_Info_Struct:
			for f in reflect.struct_fields_zipped(T) {
				if offset >= f.offset && offset < f.offset + uintptr(f.type.size) do return field_is(f.type.id, offset - f.offset, want)
			}
		case runtime.Type_Info_Enumerated_Array:
			size := uintptr(v.elem_size)
			return field_is(v.elem.id, offset % size, want)
		case runtime.Type_Info_Array:
			size := uintptr(v.elem_size)
			return field_is(v.elem.id, offset % size, want)
		}
		return false
	}
	// The script-only values (script.odin) are rows too, and a script names both tables
	// alike, so neither may share a key or a field with the other.
	rows := make([dynamic]Setting, 0, len(SETTINGS) + len(SCRIPT_VALUES), context.temp_allocator)
	append(&rows, ..SETTINGS[:])
	append(&rows, ..SCRIPT_VALUES[:])
	for s, i in rows {
		testing.expectf(t, field_is(App, s.offset, s.type), "%s: no %v field at offset %d of App", s.key, s.type, s.offset)
		testing.expectf(t, s.lo <= s.hi, "%s: range %v to %v", s.key, s.lo, s.hi)
		for other in rows[i + 1:] do testing.expectf(t, other.key != s.key && other.offset != s.offset, "%s and %s clash", s.key, other.key)
	}
}

// What is saved reads back as it was, every row and the hand-written lines alike.
@(test)
settings_read_back_what_they_wrote :: proc(t: ^testing.T) {
	path := "build/settings_test.txt"
	defer os.remove(path)
	a: App
	a.kit.ui_scale = UI_SCALES[len(UI_SCALES) - 1]
	for s in SETTINGS {
		at := rawptr(uintptr(&a) + s.offset)
		switch s.type {
		case bool: (^bool)(at)^ = true
		case f32:  (^f32)(at)^ = s.lo + (s.hi - s.lo) * 0.375 if s.lo < s.hi else 12.5
		case i32:  (^i32)(at)^ = i32(s.lo + (s.hi - s.lo) * 0.5)
		case int:  (^int)(at)^ = int(s.lo + (s.hi - s.lo) * 0.5)
		case:
			names := reflect.enum_field_names(s.type)
			testing.expect(t, setting_read(&a, s, names[len(names) - 1]))
		}
	}
	a.brush.kind = .Clay
	a.brush.strengths[.Pinch] = 0.25
	a.brush.symmetry = {.X, .Z}
	a.brush.color = {0.25, 0.5, 0.75}
	a.brush.dyns[.Grab] = {off = true, px = 10, radius = 0.1}
	a.brush.dyns[.Clay] = {own = true, by_radius = true, px = 12.5, radius = 0.25}
	a.kit.add_size = 1
	a.custom = MATERIALS[FIRST_MATCAP + 2]
	a.custom.selected = {0.25, 0.75, 1, 1}
	a.kit.windows[.Stats] = {moved = true, offset = {40, -20}, minimized = true}
	color_history_push(&a.kit.colors, {1, 0.5, 0})
	color_history_push(&a.kit.colors, {0, 0, 1})
	mine := palette_new(&a.kit.colors)
	palette_name_set(&a.kit.colors.palettes[mine], "Orc skin 2")
	a.kit.colors.palettes[mine].colors[0] = {0.2, 0.4, 0.6}
	a.kit.colors.palettes[mine].count = 1
	palette_remember(&a.kit.palette_recent, &a.kit.palette_recent_count, {.Command, .Wireframe, 0})
	palette_remember(&a.kit.palette_recent, &a.kit.palette_recent_count, {.Command, .View_Axis, int(camera.Axis_View.Top)})
	brush_recent_push(&a.kit.brushes, "brush/Clay")
	brush_recent_push(&a.kit.brushes, "preset/My clay 2")
	brush_favorite_toggle(&a.kit.brushes, "library/Move all depth")
	testing.expect(t, settings_save(&a, path))

	b: App
	settings_load(&b, path)
	for s in SETTINGS do testing.expectf(t, setting_text(&a, s) == setting_text(&b, s), "%s: wrote %s, read %s", s.key, setting_text(&a, s), setting_text(&b, s))
	testing.expect_value(t, b.brush.kind, sculpt.Brush_Kind.Clay)
	testing.expect_value(t, b.brush.strengths[.Pinch], 0.25)
	testing.expect_value(t, b.brush.symmetry, a.brush.symmetry)
	testing.expect_value(t, b.brush.color, a.brush.color)
	testing.expect(t, b.brush.dyns == a.brush.dyns, "each brush's dynamic topology")
	testing.expect_value(t, b.kit.ui_scale, a.kit.ui_scale)
	testing.expect_value(t, b.kit.add_size, 1)
	testing.expect_value(t, b.custom.matcap, 3)
	testing.expect_value(t, b.custom.selected.rgb, a.custom.selected.rgb)
	testing.expect_value(t, b.custom.idle, MATCAP_IDLE)
	testing.expect_value(t, b.kit.windows[.Stats], a.kit.windows[.Stats])
	testing.expect_value(t, b.kit.palette_recent_count, 2)
	testing.expect(t, b.kit.palette_recent == a.kit.palette_recent)
	testing.expect_value(t, b.kit.colors.history_count, 2)
	testing.expect_value(t, color_bytes(b.kit.colors.history[0]), [3]u8{0, 0, 255})
	testing.expect_value(t, color_bytes(b.kit.colors.history[1]), [3]u8{255, 128, 0})
	testing.expect_value(t, b.kit.colors.palette_count, 1)
	testing.expect_value(t, string(b.kit.colors.palettes[0].name[:10]), "Orc skin 2")
	testing.expect_value(t, b.kit.colors.palettes[0].count, 1)
	testing.expect_value(t, color_bytes(b.kit.colors.palettes[0].colors[0]), color_bytes({0.2, 0.4, 0.6}))
	testing.expect_value(t, b.kit.brushes.recent_count, 2)
	testing.expect_value(t, brush_key_text(&b.kit.brushes.recent[0]), "preset/My clay 2")
	testing.expect_value(t, brush_key_text(&b.kit.brushes.recent[1]), "brush/Clay")
	testing.expect_value(t, b.kit.brushes.favorite_count, 1)
	testing.expect_value(t, brush_key_text(&b.kit.brushes.favorites[0]), "library/Move all depth")
	free_all(context.temp_allocator)
}

// A file from before the turntable became the default orbit holds the trackball, the
// default then, so it reads as the turntable; a style picked since is kept.
@(test)
settings_move_the_old_default_orbit :: proc(t: ^testing.T) {
	path := "build/settings_orbit_test.txt"
	defer os.remove(path)
	for test in ([?]struct {
		text: string,
		want: camera.Orbit_Style,
	} {
		{"version 1\norbit_style Free\n", .Turntable},
		{"orbit_style Free\n", .Turntable},
		{"version 1\norbit_style Axis_X\n", .Axis_X},
		{"version 2\norbit_style Free\n", .Free},
	}) {
		testing.expect(t, os.write_entire_file(path, transmute([]u8)test.text) == nil)
		a: App
		a.nav = NAV_DEFAULT
		settings_load(&a, path)
		testing.expectf(t, a.nav.orbit_style == test.want, "%q: read %v", test.text, a.nav.orbit_style)
	}
	a: App
	a.nav = NAV_DEFAULT
	a.nav.orbit_style = .Free
	testing.expect(t, settings_save(&a, path))
	b: App
	settings_load(&b, path)
	testing.expect_value(t, b.nav.orbit_style, camera.Orbit_Style.Free)
	free_all(context.temp_allocator)
}

// A file from before Lens became the default look holds Studio, the default then, so it
// reads as Lens; Graphite, and Studio picked since, are kept.
@(test)
settings_move_the_old_default_look :: proc(t: ^testing.T) {
	path := "build/settings_look_test.txt"
	defer os.remove(path)
	for test in ([?]struct {
		text: string,
		want: Look,
	} {
		{"version 2\nlook Studio\n", .Lens},
		{"look Studio\n", .Lens},
		{"version 2\nlook Graphite\n", .Graphite},
		{"version 3\nlook Studio\n", .Studio},
	}) {
		testing.expect(t, os.write_entire_file(path, transmute([]u8)test.text) == nil)
		a := new(App)
		defer free(a)
		a.nav = NAV_DEFAULT
		settings_load(a, path)
		testing.expectf(t, a.kit.look == test.want, "%q: read %v", test.text, a.kit.look)
	}
	a := new(App)
	defer free(a)
	a.nav = NAV_DEFAULT
	a.kit.look = .Studio
	testing.expect(t, settings_save(a, path))
	b := new(App)
	defer free(b)
	settings_load(b, path)
	testing.expect_value(t, b.kit.look, Look.Studio)
	free_all(context.temp_allocator)
}

// A value out of range is clamped; one that is not a value of its type leaves the field.
@(test)
settings_refuse_what_they_cannot_read :: proc(t: ^testing.T) {
	a: App
	a.nav.orbit_speed = 1.5
	a.nav.orbit_style = .Turntable
	for s in SETTINGS {
		switch s.key {
		case "orbit_speed":
			testing.expect(t, !setting_read(&a, s, "fast"))
			testing.expect_value(t, a.nav.orbit_speed, 1.5)
			testing.expect(t, setting_read(&a, s, "99"))
			testing.expect_value(t, a.nav.orbit_speed, 4)
		case "orbit_style":
			testing.expect(t, !setting_read(&a, s, "sideways"))
			testing.expect_value(t, a.nav.orbit_style, camera.Orbit_Style.Turntable)
			testing.expect(t, setting_read(&a, s, "FREE"))
			testing.expect_value(t, setting_text(&a, s), "Free")
		}
	}
	free_all(context.temp_allocator)
}

// A script's value for a real setting meets the range as the f32 it is stored as, so the
// Hold delay's floor of 0.1, which f32 holds only nearly, is a value of it and less is not.
@(test)
settings_take_a_real_bound_by_its_text :: proc(t: ^testing.T) {
	for s in SETTINGS {
		if s.key != "hold_delay" do continue
		v, ok := setting_parse(s, "0.1", strict = true)
		testing.expect(t, ok)
		testing.expect_value(t, f32(v), HOLD_DELAY_MIN)
		_, ok = setting_parse(s, "0.09", strict = true)
		testing.expect(t, !ok)
		v, ok = setting_parse(s, "1.5", strict = true)
		testing.expect(t, ok && f32(v) == HOLD_DELAY_MAX)
	}
}

// Render's Fast quality was once named Preview: a settings file or script naming it so still
// gets Fast, and the file now writes the new name.
@(test)
settings_read_preview_as_fast :: proc(t: ^testing.T) {
	a: App
	found := false
	for s in SETTINGS {
		if s.key != "render_quality" do continue
		found = true
		for text in ([]string{"preview", "Preview", "fast"}) {
			for strict in ([]bool{false, true}) {
				v, ok := setting_parse(s, text, strict)
				testing.expect(t, ok, text)
				testing.expect_value(t, Render_Quality(int(v)), Render_Quality.Fast)
			}
		}
		a.render_quality = .Fast
		testing.expect_value(t, setting_text(&a, s), "Fast")
	}
	testing.expect(t, found)
	free_all(context.temp_allocator)
}

// Remesh makes quads at first from settings version 9 on: a file from before, which holds
// Quads off whether or not anyone picked it, takes them on once, and a later file's off stays.
@(test)
remesh_quads_default_changes_once :: proc(t: ^testing.T) {
	path := "build/remesh_quads_test.txt"
	defer os.remove(path)
	load :: proc(t: ^testing.T, path, text: string) -> bool {
		testing.expect(t, os.write_entire_file(path, transmute([]u8)text) == nil)
		a: App
		defer results_destroy(&a)
		a.ui = ui_state_default()
		settings_load(&a, path)
		return a.ui.remesh_quads
	}
	testing.expect(t, ui_state_default().remesh_quads, "a fresh install remeshes to quads")
	testing.expect(t, load(t, path, "version 8\nremesh_quads 0\n"), "an old file's off becomes on")
	testing.expect(t, !load(t, path, "version 9\nremesh_quads 0\n"), "a picked off stays off")
	free_all(context.temp_allocator)
}
