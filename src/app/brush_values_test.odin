package main

import "core:os"
import "core:testing"

// Each value reads back what it was set to, within its range and in its section's steps,
// through the same fields the Pen, Stroke and Falloff sections change.
@(test)
brush_values_set_and_read :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	app.brush.radius_px = 60
	for v in Brush_Value {
		if v == .Pressure do continue
		lo, hi, _ := value_range(v)
		value_set(&app, v, hi + 1000)
		testing.expectf(t, value_get(&app, v) == hi, "%v above its range reads %v", v, value_get(&app, v))
		value_set(&app, v, lo - 1000)
		testing.expectf(t, value_get(&app, v) == lo, "%v below its range reads %v", v, value_get(&app, v))
	}
	value_set(&app, .Focal_Shift, 12.4)
	testing.expect_value(t, focal_shift(&app)^, 12)
	value_set(&app, .Size, 96)
	testing.expect_value(t, app.brush.radius_px, 96)
	value_set(&app, .Strength, 0.75)
	testing.expect_value(t, brush_strength(&app)^, 0.75)
	testing.expect_value(t, value_short(&app, .Strength), ".75")
	app.brush.lazy_px = 0
	testing.expect_value(t, value_short(&app, .Lazy), "off")
	// Spacing unset is the default spacing, and only a stroke of dabs uses it.
	app.brush.spacing = 0
	testing.expect_value(t, value_get(&app, .Spacing), DAB_SPACING)
	app.brush.stroke = .Spray
	testing.expect(t, !value_enabled(&app, .Spacing))
	app.brush.pressure_size, app.brush.pressure_strength = false, false
	testing.expect_value(t, value_text(&app, .Pressure), "off")
}

// A value item is a command with one argument per value: Search lists each once with its
// own icon, and its name round-trips as a key's or a bar's does.
@(test)
brush_values_are_commands :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	n := 0
	for e in palette_entries() do if e.kind == .Command && e.id == .Brush_Value {
		n += 1
		testing.expect_value(t, palette_icon(e), BRUSH_VALUE_ICONS[Brush_Value(e.arg)])
	}
	testing.expect_value(t, n, len(Brush_Value))
	for v in Brush_Value {
		s := value_slot(v)
		id, arg, ok := command_from_name(command_name(s.id, s.arg))
		testing.expect(t, ok && id == .Brush_Value && arg == int(v))
		got, is_value := value_of(s)
		testing.expect(t, is_value && got == v)
		testing.expect_value(t, bar_label(s), BRUSH_VALUE_NAMES[v])
	}
	_, is_value := value_of({.Brush, int(Brush_Value.Size)})
	testing.expect(t, !is_value)
	testing.expect(t, !script_allows(.Brush_Value))
}

// The island starts as Size and Strength sliders; values and commands put on it and each
// value's look are kept in settings.txt, an older file without the island's lines gets the
// fresh island, and a look line an older build passes over leaves the value in place.
@(test)
the_island_is_a_bar_of_values :: proc(t: ^testing.T) {
	path := "build/island_test.txt"
	defer os.remove(path)
	defer free_all(context.temp_allocator)
	a: App
	defer results_destroy(&a)
	bars_reset(&a.kit)
	testing.expect_value(t, bar_names(&a, .Offhand), "Brush_Value:Size,Brush_Value:Strength")
	testing.expect_value(t, bar_looks(&a, .Offhand), "Slider,Slider")
	testing.expect(t, !bar_changed(&a, .Offhand))

	// Put from Search, a value takes the bar's look: a slider on the island, a chip
	// elsewhere; a Slider never shows where the bar has no room for one.
	bar_put(&a, {which = .Offhand, slot = 2, add = true}, value_slot(.Focal_Shift))
	bar_put(&a, {which = .Offhand, slot = 3, add = true}, {.Wireframe, 0})
	bar_put(&a, {which = .Tools, slot = 0, add = true}, value_slot(.Strength))
	a.kit.offhand.looks[0] = .Chip
	testing.expect_value(t, bar_looks(&a, .Offhand), "Chip,Slider,Slider,command")
	testing.expect_value(t, bar_look(&a.kit, .Tools, 0), Value_Look.Chip)
	a.kit.tools.looks[0] = .Slider
	testing.expect_value(t, bar_look(&a.kit, .Tools, 0), Value_Look.Chip)
	a.kit.tools.looks[0] = .Icon
	// A look moves with its value.
	testing.expect_value(t, bar_move(&a, .Offhand, 0, 1), 1)
	testing.expect_value(t, bar_looks(&a, .Offhand), "Slider,Chip,Slider,command")
	testing.expect(t, bar_changed(&a, .Offhand))
	testing.expect(t, settings_save(&a, path))

	b: App
	defer results_destroy(&b)
	bars_reset(&b.kit)
	settings_load(&b, path)
	testing.expect_value(t, bar_names(&b, .Offhand), bar_names(&a, .Offhand))
	testing.expect_value(t, bar_looks(&b, .Offhand), bar_looks(&a, .Offhand))
	testing.expect_value(t, bar_look(&b.kit, .Tools, 0), Value_Look.Icon)
	// The island's three, the strip's Strength, and the Render page's Exposure.
	testing.expect_value(t, values_on_bars(&b), 5)

	// The island is the person's, as the brush pie is: a workspace's layout leaves it be.
	text := kit_layout_text(&a.kit)
	c: App
	defer results_destroy(&c)
	bars_reset(&c.kit)
	kit_layout_put(&c.kit, text)
	testing.expect(t, !bar_changed(&c, .Offhand))

	old := "version 5\nbar_count bottom_tools 1\nbar bottom_tools 0 Brush_Value:Lazy\nbar_look bottom_tools 0 No_Such_Look\n"
	testing.expect(t, os.write_entire_file(path, transmute([]u8)old) == nil)
	d: App
	defer results_destroy(&d)
	bars_reset(&d.kit)
	settings_load(&d, path)
	testing.expect(t, !bar_changed(&d, .Offhand))
	testing.expect_value(t, bar_names(&d, .Tools), "Brush_Value:Lazy")
	testing.expect_value(t, bar_look(&d.kit, .Tools, 0), Value_Look.Chip)
}
