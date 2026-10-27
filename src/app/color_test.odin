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

// A tap on a colour field's well opens the colour popover on that field and a second one
// puts it away; what the popover set reaches the field on its next frame as the field's
// own change, through the sRGB curve for a colour stored as linear light.
@(test)
a_colour_well_opens_the_popover :: proc(t: ^testing.T) {
	app: App
	kit_init(&app)
	defer ui.destroy(&app.kit.ctx)
	c := &app.kit.colors
	rgb := [3]f32{0.5, 0.5, 0.5}
	_ = color_frame(&app, &rgb, true, {})
	_ = color_frame(&app, &rgb, true, {})
	at := [2]f32{1600 - KIT_INSPECTOR_W + 40, 22}
	_ = color_frame(&app, &rgb, true, {mouse = at, mouse_valid = true, pressed = {.Left}, down = {.Left}})
	_ = color_frame(&app, &rgb, true, {mouse = at, mouse_valid = true, released = {.Left}})
	testing.expect(t, c.pop)
	testing.expect(t, c.pop_alive)
	testing.expect(t, abs(c.pop_value.r - srgb_encode(0.5)) < 1e-6)
	c.pop_set, c.pop_dirty = {1, 0, 0.5}, true
	testing.expect(t, color_frame(&app, &rgb, true, {mouse = at, mouse_valid = true}))
	testing.expect(t, !c.pop_dirty)
	testing.expect_value(t, rgb, [3]f32{1, 0, srgb_decode(0.5)})
	_ = color_frame(&app, &rgb, true, {mouse = at, mouse_valid = true, pressed = {.Left}, down = {.Left}})
	_ = color_frame(&app, &rgb, true, {mouse = at, mouse_valid = true, released = {.Left}})
	testing.expect(t, !c.pop)
}

// Hue, saturation and brightness turn into red, green and blue and back to within a
// byte, the primaries land where the wheels show them, and a grey or a black keeps the
// hue (and a black the saturation) it was given, so a picker never jumps back to red.
@(test)
colors_hsv_round_trips :: proc(t: ^testing.T) {
	near :: proc(a, b: [3]f32) -> bool {return abs(a.x - b.x) < 0.004 && abs(a.y - b.y) < 0.004 && abs(a.z - b.z) < 0.004}
	testing.expect(t, near(hsv_to_rgb({0, 1, 1}), {1, 0, 0}))
	testing.expect(t, near(hsv_to_rgb({1.0 / 3, 1, 1}), {0, 1, 0}))
	testing.expect(t, near(hsv_to_rgb({2.0 / 3, 1, 1}), {0, 0, 1}))
	testing.expect(t, near(hsv_to_rgb({1, 1, 1}), {1, 0, 0}))
	for h in 0 ..< 24 {
		for s in 1 ..= 4 {
			for v in 1 ..= 4 {
				hsv := [3]f32{f32(h) / 24, f32(s) / 4, f32(v) / 4}
				back := rgb_to_hsv(hsv_to_rgb(hsv))
				testing.expectf(t, near(back, hsv), "%v came back as %v", hsv, back)
			}
		}
	}
	grey := rgb_to_hsv({0.5, 0.5, 0.5}, {0.3, 0.8, 1})
	testing.expectf(t, grey.x == 0.3 && grey.y == 0 && abs(grey.z - 0.5) < 1e-6, "grey reads %v", grey)
	black := rgb_to_hsv({0, 0, 0}, {0.3, 0.8, 1})
	testing.expectf(t, black == {0.3, 0.8, 0}, "black reads %v", black)
}

// The Disc's inner circle maps the square into the circle and back: the corners reach
// the rim, the middle stays put, and every point comes back where it was.
@(test)
colors_disc_maps_the_square_both_ways :: proc(t: ^testing.T) {
	for corner in ([4][2]f32{{1, 1}, {-1, 1}, {-1, -1}, {1, -1}}) {
		q := disc_from_square(corner)
		testing.expectf(t, abs(math.sqrt(q.x * q.x + q.y * q.y) - 1) < 1e-4, "corner %v lands at %v", corner, q)
	}
	for i in 0 ..= 10 {
		for j in 0 ..= 10 {
			p := [2]f32{f32(i) / 5 - 1, f32(j) / 5 - 1}
			back := square_from_disc(disc_from_square(p))
			testing.expectf(t, abs(back.x - p.x) < 2e-3 && abs(back.y - p.y) < 2e-3, "%v came back as %v", p, back)
		}
	}
	// A point past the rim reads as the rim.
	far := square_from_disc({3, 0})
	testing.expectf(t, abs(far.x - 1) < 1e-4 && abs(far.y) < 1e-4, "far right reads %v", far)
}

// Each scheme has Procreate's count of colours, the first the colour itself, spaced as
// its name says.
@(test)
colors_harmonies_space_their_hues :: proc(t: ^testing.T) {
	counts := [Harmony]int{.Complementary = 2, .Split_Complementary = 3, .Analogous = 3, .Triadic = 3, .Tetradic = 4}
	for h in Harmony {
		o := harmony_offsets(h)
		testing.expectf(t, len(o) == counts[h] && o[0] == 0, "%v: %v", h, o)
	}
	testing.expect_value(t, harmony_offsets(.Complementary)[1], 0.5)
	testing.expect(t, abs(harmony_offsets(.Triadic)[2] - 2.0 / 3) < 1e-6)
	testing.expect(t, abs(harmony_offsets(.Split_Complementary)[1] - 5.0 / 12) < 1e-6)
}

// The history keeps the last COLOR_HISTORY colours, newest first, and a colour picked
// again moves to the front rather than showing twice.
@(test)
colors_history_moves_a_repeat_to_the_front :: proc(t: ^testing.T) {
	c: Colors_Card
	for i in 0 ..< COLOR_HISTORY + 3 do color_history_push(&c, {f32(i) / 20, 0, 0})
	testing.expect_value(t, c.history_count, COLOR_HISTORY)
	testing.expect_value(t, color_bytes(c.history[0]), color_bytes({f32(COLOR_HISTORY + 2) / 20, 0, 0}))
	again := c.history[3]
	color_history_push(&c, again)
	testing.expect_value(t, c.history_count, COLOR_HISTORY)
	testing.expect_value(t, c.history[0], again)
	seen := 0
	for h in c.history do if color_bytes(h) == color_bytes(again) do seen += 1
	testing.expect_value(t, seen, 1)
}

// Your palettes: + makes one the default, deleting it gives the default back to the
// first built-in, and the swatches after a deleted one move up.
@(test)
colors_palettes_add_and_delete :: proc(t: ^testing.T) {
	c: Colors_Card
	i := palette_new(&c)
	j := palette_new(&c)
	testing.expect_value(t, c.default_palette, len(BUILT_IN_PALETTES) + j)
	p := &c.palettes[i]
	for k in 0 ..< 3 do p.colors[k] = {f32(k) / 4, 0, 0}
	p.count = 3
	palette_swatch_delete(&c, i, 1)
	testing.expect_value(t, p.count, 2)
	testing.expect_value(t, p.colors[1], [3]f32{0.5, 0, 0})
	palette_delete(&c, j)
	testing.expect_value(t, c.palette_count, 1)
	testing.expect_value(t, c.default_palette, 0)
	for _ in 0 ..< USER_PALETTES do _ = palette_new(&c)
	testing.expect_value(t, c.palette_count, USER_PALETTES)
	testing.expect_value(t, palette_new(&c), -1)
}
