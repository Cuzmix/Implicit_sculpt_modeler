package main

import "core:math"
import "core:testing"

import "../ui"

// Hex codes read as image editors write them, and every byte value comes back as the
// code it was shown as.
@(test)
hex_colours_read_and_write :: proc(t: ^testing.T) {
	Case :: struct {
		text: string,
		rgb:  [3]u8,
		ok:   bool,
	}
	cases := [?]Case {
		{"#FF8000", {255, 128, 0}, true},
		{"ff8000", {255, 128, 0}, true},
		{"  #3a7 ", {0x33, 0xaa, 0x77}, true},
		{"#3A", {}, false},
		{"#12345", {}, false},
		{"#1234567", {}, false},
		{"#GG0000", {}, false},
		{"", {}, false},
	}
	for c in cases {
		rgb, ok := color_hex_parse(c.text)
		testing.expectf(t, ok == c.ok, "%q: ok %v", c.text, ok)
		if !ok do continue
		for i in 0 ..< 3 do testing.expectf(t, u8(math.round(rgb[i] * 255)) == c.rgb[i], "%q: channel %d is %v", c.text, i, rgb[i])
	}
	buf: [8]u8
	color_hex_format({1, 128.0 / 255, 0}, buf[:])
	testing.expect_value(t, string(buf[:7]), "#FF8000")
	testing.expect_value(t, buf[7], 0)
	for b in 0 ..< 256 {
		v := f32(b) / 255
		color_hex_format({v, v, v}, buf[:])
		back, ok := color_hex_parse(string(buf[:7]))
		testing.expect(t, ok && back == {v, v, v})
	}
}

// The sRGB curve and its inverse agree, so a material colour moved through the shown
// values lands where its hex code says.
@(test)
srgb_round_trips :: proc(t: ^testing.T) {
	for b in 0 ..< 256 {
		v := f32(b) / 255
		testing.expectf(t, abs(srgb_encode(srgb_decode(v)) - v) < 1e-5, "byte %d", b)
	}
	// Mid grey on screen is about a fifth of the light.
	testing.expect(t, abs(srgb_decode(0.5) - 0.214) < 0.001)
}

// One frame of a colour field at the inspector's place, with `input`.
@(private = "file")
color_frame :: proc(app: ^App, rgb: ^[3]f32, linear: bool, input: ui.Input) -> (changed: bool) {
	ctx := &app.kit.ctx
	in_frame := input
	in_frame.window = {1600, 900}
	in_frame.pixel_density = 1
	in_frame.dt = 1.0 / 60
	ui.frame_begin(ctx, in_frame)
	ui.begin_anchored(ctx, "colour test", .End, .Start, {0, 0}, {direction = .Column, width = KIT_INSPECTOR_W})
	changed = kit_color(app, "test colour", rgb, linear)
	ui.end(ctx)
	ui.frame_end(ctx)
	free_all(context.temp_allocator)
	return
}

// Typing a hex code changes the colour once the code is whole, and keeps what is typed
// between keys; a material's colour, stored as linear light, takes the code's shown
// values through the sRGB curve.
@(test)
a_typed_hex_code_sets_the_colour :: proc(t: ^testing.T) {
	app: App
	kit_init(&app)
	defer ui.destroy(&app.kit.ctx)
	rgb := [3]f32{0.5, 0.5, 0.5}
	_ = color_frame(&app, &rgb, true, {})
	// The field's id, as kit_color names it inside its row.
	ctx := &app.kit.ctx
	ui.frame_begin(ctx, {window = {1600, 900}, pixel_density = 1, dt = 1.0 / 60})
	ui.begin_anchored(ctx, "colour test", .End, .Start, {0, 0}, {direction = .Column, width = KIT_INSPECTOR_W})
	ui.begin(ctx, "swatch##test colour", {direction = .Row})
	id := ui.id_of(ctx, "hex##test colour")
	ui.end(ctx)
	ui.end(ctx)
	ui.frame_end(ctx)
	ctx.text_focus = id
	steps := [?]string{"", "", "#3", "A7"}
	for s, i in steps {
		key: ui.Input
		key.text = s
		changed := color_frame(&app, &rgb, true, key)
		testing.expectf(t, changed == (i == len(steps) - 1), "step %d: changed %v", i, changed)
	}
	testing.expect_value(t, ctx.text_focus, id)
	want := [3]f32{srgb_decode(0x33 / 255.0), srgb_decode(0xaa / 255.0), srgb_decode(0x77 / 255.0)}
	for i in 0 ..< 3 do testing.expectf(t, abs(rgb[i] - want[i]) < 1e-6, "channel %d: %v, want %v", i, rgb[i], want[i])
	// Enter lets the field go, and it shows the colour again.
	_ = color_frame(&app, &rgb, true, {text_end = true})
	testing.expect(t, ctx.text_focus != id)
	testing.expect_value(t, app.kit.color_hex_of, ui.Id(0))
}
