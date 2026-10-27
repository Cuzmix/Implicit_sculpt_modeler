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
		case:
			names := reflect.enum_field_names(s.type)
			testing.expect(t, setting_read(&a, s, names[len(names) - 1]))
		}
	}
	a.brush.kind = .Clay
	a.brush.strengths[.Pinch] = 0.25
	a.brush.symmetry = {.X, .Z}
	a.brush.color = {0.25, 0.5, 0.75}
	a.kit.add_size = 1
	a.custom = MATERIALS[FIRST_MATCAP + 2]
	a.custom.selected = {0.25, 0.75, 1, 1}
	a.kit.windows[.Stats] = {moved = true, offset = {40, -20}, minimized = true}
	palette_remember(&a.kit.palette_recent, &a.kit.palette_recent_count, {.Command, .Wireframe, 0})
	palette_remember(&a.kit.palette_recent, &a.kit.palette_recent_count, {.Command, .View_Axis, int(camera.Axis_View.Top)})
	testing.expect(t, settings_save(&a, path))

	b: App
	settings_load(&b, path)
	for s in SETTINGS do testing.expectf(t, setting_text(&a, s) == setting_text(&b, s), "%s: wrote %s, read %s", s.key, setting_text(&a, s), setting_text(&b, s))
	testing.expect_value(t, b.brush.kind, sculpt.Brush_Kind.Clay)
	testing.expect_value(t, b.brush.strengths[.Pinch], 0.25)
	testing.expect_value(t, b.brush.symmetry, a.brush.symmetry)
	testing.expect_value(t, b.brush.color, a.brush.color)
	testing.expect_value(t, b.kit.ui_scale, a.kit.ui_scale)
	testing.expect_value(t, b.kit.add_size, 1)
	testing.expect_value(t, b.custom.matcap, 3)
	testing.expect_value(t, b.custom.selected.rgb, a.custom.selected.rgb)
	testing.expect_value(t, b.custom.idle, MATCAP_IDLE)
	testing.expect_value(t, b.kit.windows[.Stats], a.kit.windows[.Stats])
	testing.expect_value(t, b.kit.palette_recent_count, 2)
	testing.expect(t, b.kit.palette_recent == a.kit.palette_recent)
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
