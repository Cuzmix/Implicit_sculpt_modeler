package main

import "core:strings"
import "core:testing"

// The stack's width and the docked cards' heights go in a workspace's layout and come back
// on the grid, within their limits; a fresh stack writes no line, and putting a layout in
// place puts its sizes back, a fresh one's included.
@(test)
stack_sizes_round_trip_in_a_layout :: proc(t: ^testing.T) {
	k: Kit_State
	stack_default(&k)
	out := strings.builder_make(context.temp_allocator)
	stack_sizes_save(&k, &out)
	testing.expect_value(t, strings.to_string(out), "")
	testing.expect_value(t, stack_width(&k), f32(STACK_W))

	k.stack.width, k.stack.heights[.Brush], k.stack.heights[.Layers] = 344, 320, 96
	stack_sizes_save(&k, &out)
	text := strings.to_string(out)
	testing.expect_value(t, text, "stack_size 344 Brush=320 Layers=96\n")

	b: Kit_State
	stack_default(&b)
	stack_sizes_read(&b, strings.fields(strings.trim_space(text), context.temp_allocator))
	testing.expect_value(t, stack_width(&b), f32(344))
	testing.expect_value(t, b.stack.heights[.Brush], f32(320))
	testing.expect_value(t, b.stack.heights[.Layers], f32(96))

	// Out of range or off the grid, a size is brought within the limits and onto the grid;
	// a word it cannot read is passed over.
	stack_sizes_read(&b, {"stack_size", "900", "Scene=13", "Nothing=40", "Brush=x"})
	testing.expect_value(t, stack_width(&b), f32(STACK_W_MAX))
	testing.expect_value(t, b.stack.heights[.Scene], f32(STACK_BODY_MIN))
	testing.expect_value(t, b.stack.heights[.Brush], f32(320))
	stack_sizes_read(&b, {"stack_size", "default"})
	testing.expect_value(t, stack_width(&b), f32(STACK_W))

	// A workspace's layout carries them, and putting it in place puts them back.
	a: App
	defer results_destroy(&a)
	bars_reset(&a.kit)
	stack_default(&a.kit)
	a.kit.stack.width, a.kit.stack.heights[.Scene] = 360, 200
	layout := kit_layout_text(&a.kit)
	testing.expect(t, strings.contains(layout, "stack_size 360 Scene=200\n"))
	c: App
	defer results_destroy(&c)
	bars_reset(&c.kit)
	kit_layout_put(&c.kit, layout)
	testing.expect_value(t, stack_width(&c.kit), f32(360))
	testing.expect_value(t, c.kit.stack.heights[.Scene], f32(200))
	kit_layout_put(&c.kit, "bars\n")
	testing.expect_value(t, stack_width(&c.kit), f32(STACK_W))

	testing.expect_value(t, stack_snap(341), f32(344))
	testing.expect_value(t, stack_snap(339), f32(336))
}
