package main

import "core:os"
import "core:testing"

import "../sculpt"

// Paint turns the channel it last painted with back on (Both at first), off keeps it, and
// the settings file remembers which.
@(test)
paint_toggle_remembers_its_channel :: proc(t: ^testing.T) {
	path := "build/paint_toggle_test.txt"
	defer os.remove(path)
	a: App
	defer results_destroy(&a)
	a.brush = brush_defaults()
	testing.expect_value(t, a.brush.channel, sculpt.Channel.Sculpt)
	paint_toggle(&a)
	testing.expect_value(t, a.brush.channel, sculpt.Channel.Both)
	a.brush.channel = .Color
	paint_toggle(&a)
	testing.expect_value(t, a.brush.channel, sculpt.Channel.Sculpt)
	testing.expect_value(t, a.brush.paint_on, sculpt.Channel.Color)
	testing.expect(t, settings_save(&a, path))
	b: App
	defer results_destroy(&b)
	b.brush = brush_defaults()
	settings_load(&b, path)
	paint_toggle(&b)
	testing.expect_value(t, b.brush.channel, sculpt.Channel.Color)
	free_all(context.temp_allocator)
}
