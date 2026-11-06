package main

import "core:testing"

import "../sculpt"

// The channel strip's change is one undo step, a Fill with Roughness on lays the brush's
// roughness and leaves colour alone when Colour is off, and the island offers the chips
// only while the picked layer holds roughness or metal.
@(test)
paint_channels_fill_roughness_alone :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	app.brush = brush_defaults()
	objs := tree_scene(&app)
	obj := objs[0]
	s := object_sculptor(obj)
	paint_layer_add(&app, obj)
	testing.expect(t, !island_material(&app))
	picked := sculpt.sculptor_paint_picked(s)
	if !testing.expect(t, picked >= 0) do return
	testing.expect(t, sculpt.sculptor_paint_set_channels(s, picked, {.Roughness}))
	testing.expect(t, island_material(&app))
	value_set(&app, .Roughness, 0.2)
	paint_command(&app, .Fill)
	m := sculpt.sculptor_paint_shown_material(s)
	if !testing.expect(t, m != nil) do return
	testing.expect_value(t, m[0][0], u8(51))
	testing.expect_value(t, m[0][1], u8(255))
	testing.expect_value(t, m[0][3], u8(0))
	c := sculpt.sculptor_paint_shown(s)
	testing.expect(t, c == nil || c[0].a == 0, "a Fill with Colour off painted colour")
	free_all(context.temp_allocator)
}
