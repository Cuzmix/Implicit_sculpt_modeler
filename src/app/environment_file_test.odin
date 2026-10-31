package main

import "core:fmt"
import "core:math"
import "core:testing"

import "../camera"
import "../png_write"

// A Radiance file of `width` by `height` pixels, each `value(x, y)`, its rows run-length
// encoded per channel when `rle` (as most writers do) or flat. Temp memory.
@(private = "file")
hdr_file :: proc(width, height: int, rle: bool, value: proc(x, y: int) -> [3]f32) -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, fmt.tprintf("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\nEXPOSURE=1.0\n\n-Y %d +X %d\n", height, width))
	rgbe := make([]u8, width * 4, context.temp_allocator)
	for y in 0 ..< height {
		for x in 0 ..< width {
			c := value(x, y)
			m := max(c.x, c.y, c.z)
			if m < 1e-32 {
				rgbe[x * 4], rgbe[x * 4 + 1], rgbe[x * 4 + 2], rgbe[x * 4 + 3] = 0, 0, 0, 0
				continue
			}
			mant, e := math.frexp(m)
			scale := mant * 256 / m
			rgbe[x * 4], rgbe[x * 4 + 1], rgbe[x * 4 + 2], rgbe[x * 4 + 3] = u8(c.x * scale), u8(c.y * scale), u8(c.z * scale), u8(e + 128)
		}
		if !rle {
			append(&out, ..rgbe)
			continue
		}
		append(&out, 2, 2, u8(width >> 8), u8(width & 0xff))
		for ch in 0 ..< 4 {
			// Runs of equal bytes as runs, the rest as literals of at most 128.
			x := 0
			for x < width {
				run := 1
				for x + run < width && run < 127 && rgbe[(x + run) * 4 + ch] == rgbe[x * 4 + ch] do run += 1
				if run >= 3 {
					append(&out, u8(128 + run), rgbe[x * 4 + ch])
					x += run
					continue
				}
				n := min(width - x, 128)
				append(&out, u8(n))
				for k in 0 ..< n do append(&out, rgbe[(x + k) * 4 + ch])
				x += n
			}
		}
	}
	return out[:]
}

// Both row forms read back to the values written (to RGBE's 8-bit mantissa), and a
// panorama wider than asked comes back halved, each pixel the mean of its square.
@(test)
hdr_files_read_back :: proc(t: ^testing.T) {
	sky :: proc(x, y: int) -> [3]f32 {return {f32(x) * 0.25, f32(y) * 2 + 0.5, 3}}
	for rle in ([2]bool{false, true}) {
		img, why := environment_decode(hdr_file(64, 32, rle, sky), 64)
		defer environment_image_destroy(&img)
		testing.expect_value(t, why, "")
		if !testing.expect(t, img.width == 64 && img.height == 32) do continue
		for p, i in img.pixels {
			want := sky(i % 64, i / 64)
			for c in 0 ..< 3 do testing.expectf(t, abs(p[c] - want[c]) <= want[c] / 128 + 1e-6, "rle %v pixel %d: %v, wanted %v", rle, i, p, want)
		}
	}
	half, why := environment_decode(hdr_file(64, 32, true, sky), 32)
	defer environment_image_destroy(&half)
	testing.expect_value(t, why, "")
	testing.expect(t, half.width == 32 && half.height == 16)
	// The first output pixel averages x 0..1 and y 0..1.
	want := (sky(0, 0) + sky(1, 0) + sky(0, 1) + sky(1, 1)) / 4
	testing.expectf(t, abs(half.pixels[0].y - want.y) < 0.02 && abs(half.pixels[0].x - want.x) < 0.02, "%v, wanted %v", half.pixels[0], want)
	free_all(context.temp_allocator)
}

// A flat file whose pixels happen to start (1, 1, 1, e) is read, not taken for the old run
// form; the brightest RGBE values are clamped to a half float's largest, so nothing sums to
// infinity.
@(test)
hdr_edge_values_read :: proc(t: ^testing.T) {
	dim :: proc(x, y: int) -> [3]f32 {return {1, 1, 1}}
	flat := hdr_file(64, 32, false, dim)
	header := len("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\nEXPOSURE=1.0\n\n-Y 32 +X 64\n")
	for y in 0 ..< 32 do for x in 0 ..< 64 {
		at := header + (y * 64 + x) * 4
		flat[at], flat[at + 1], flat[at + 2], flat[at + 3] = 1, 1, 1, 255 if x == 5 && y == 3 else 129
	}
	img, why := environment_decode(flat, 64)
	defer environment_image_destroy(&img)
	testing.expect_value(t, why, "")
	if !testing.expect(t, len(img.pixels) == 64 * 32) do return
	testing.expectf(t, abs(img.pixels[0].x - 1.0 / 128) < 1e-6, "%v", img.pixels[0])
	testing.expectf(t, img.pixels[3 * 64 + 5].x == HDR_MAX_VALUE, "%v", img.pixels[3 * 64 + 5])
	sh := environment_sh9(img)
	for k in sh do for c in k do testing.expect(t, !math.is_inf(c) && !math.is_nan(c))
	free_all(context.temp_allocator)
}

// A picture panorama is read as sRGB: 255 is 1, 188 about half, and grey spreads to all
// three channels.
@(test)
picture_panoramas_read_as_srgb :: proc(t: ^testing.T) {
	pixels := make([]u8, 64 * 32 * 4, context.temp_allocator)
	for i in 0 ..< 64 * 32 do copy(pixels[i * 4:], []u8{255, 188, 0, 255})
	png := png_write.encode(pixels, 64, 32, false, context.temp_allocator)
	img, why := environment_decode(png, 64)
	defer environment_image_destroy(&img)
	testing.expect_value(t, why, "")
	if !testing.expect(t, len(img.pixels) == 64 * 32) do return
	p := img.pixels[100]
	testing.expectf(t, abs(p.x - 1) < 1e-5 && abs(p.y - 0.5) < 0.01 && p.z == 0, "%v", p)
	free_all(context.temp_allocator)
}

// Damage is refused without reading past the file: a cut file, a run past the row, the
// old run form, the wrong format, a header with no end, a panorama of the wrong shape or
// too small to prefilter, and a file that is no picture at all.
@(test)
hdr_damage_is_refused :: proc(t: ^testing.T) {
	grey :: proc(x, y: int) -> [3]f32 {return {0.5, 0.5, 0.5}}
	good := hdr_file(64, 32, true, grey)
	cases := [?][]u8 {
		good[:len(good) - 7],
		transmute([]u8)string("#?RADIANCE\nFORMAT=32-bit_rle_xyze\n\n-Y 32 +X 64\n"),
		transmute([]u8)string("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n"),
		transmute([]u8)string("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n+Y 32 +X 64\n"),
		hdr_file(60, 60, false, grey),
		hdr_file(32, 16, false, grey),
		hdr_file(0, 0, false, grey),
		hdr_file(64, 32, false, grey)[:200],
		transmute([]u8)string("not a picture"),
	}
	for c, i in cases {
		img, why := environment_decode(c, 64)
		testing.expectf(t, why != "" && img.pixels == nil, "case %d was read", i)
		delete(why)
	}
	// A run longer than what is left of the row: the first channel's first byte.
	over := make([]u8, len(good), context.temp_allocator)
	copy(over, good)
	header := len("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\nEXPOSURE=1.0\n\n-Y 32 +X 64\n")
	over[header + 4] = 128 + 80
	img, why := environment_decode(over, 64)
	testing.expect(t, why != "" && img.pixels == nil, "a run past the row was read")
	delete(why)
	// The old 1 1 1 n run form (shorter than a flat file would be).
	old := make([]u8, len(good), context.temp_allocator)
	copy(old, good)
	old[header], old[header + 1], old[header + 2] = 1, 1, 1
	img, why = environment_decode(old, 64)
	testing.expect(t, why != "" && img.pixels == nil, "the old run form was read")
	delete(why)
	free_all(context.temp_allocator)
}

// The diffuse light of a constant panorama is that constant in every direction; a bright
// band overhead lights a face turned up more than one turned down or sideways.
@(test)
sh9_irradiance_is_right :: proc(t: ^testing.T) {
	flat := Environment_Image{width = 64, height = 32}
	flat.pixels = make([][3]f32, 64 * 32, context.temp_allocator)
	for &p in flat.pixels do p = {1, 1, 1}
	sh := environment_sh9(flat)
	irradiance :: proc(sh: [9][3]f32, n: [3]f32) -> (e: [3]f32) {
		b := sh9_basis(n)
		for k in 0 ..< 9 do e += sh[k] * b[k]
		return
	}
	for n in ([?][3]f32{{0, 1, 0}, {0, -1, 0}, {1, 0, 0}, {0, 0, -1}, {0.6, 0.0, 0.8}}) {
		e := irradiance(sh, n)
		testing.expectf(t, abs(e.x - 1) < 2e-3, "constant 1 gives %v facing %v", e, n)
	}
	top := Environment_Image{width = 64, height = 32}
	top.pixels = make([][3]f32, 64 * 32, context.temp_allocator)
	for &p, i in top.pixels do p = {4, 4, 4} if i / 64 < 4 else {0.1, 0.1, 0.1}
	sh = environment_sh9(top)
	up, down, side := irradiance(sh, {0, 1, 0}).x, irradiance(sh, {0, -1, 0}).x, irradiance(sh, {1, 0, 0}).x
	testing.expectf(t, up > side && side > down && down > 0, "up %v, side %v, down %v", up, side, down)
	free_all(context.temp_allocator)
}

// The panorama's middle column looks straight ahead (-Z), its top row up, a quarter of
// the way round to the left (-X).
@(test)
panorama_directions_match_the_shader :: proc(t: ^testing.T) {
	ahead := environment_direction(64, 32, 128, 64)
	testing.expectf(t, ahead.z < -0.99, "%v", ahead)
	testing.expect(t, environment_direction(64, 0, 128, 64).y > 0.99)
	left := environment_direction(32, 32, 128, 64)
	testing.expectf(t, left.x < -0.99, "%v", left)
	// The shader's inverse: u = atan(d.x, -d.z) / 2pi + 0.5.
	u := math.atan2(left.x, -left.z) / (2 * math.PI) + 0.5
	testing.expectf(t, abs(u - (32.5 / 128)) < 1e-4, "u %v", u)
}

// The panorama turns with the lights' Turn but not their Height, and only shows while
// Image is picked and one is loaded.
@(test)
environment_turns_but_never_tilts :: proc(t: ^testing.T) {
	app: App
	lights_reset(&app)
	environment_settings_default(&app)
	app.camera = camera.orbit_default()
	flat := environment_rotation(&app)
	app.light_height = 40
	testing.expect_value(t, environment_rotation(&app), flat)
	app.light_turn = 90
	turned := environment_rotation(&app)
	// A quarter turn about the up axis: the panorama's x axis now points along -z or +z,
	// its up axis stays up.
	testing.expectf(t, abs(abs(turned[0].z) - 1) < 1e-5 && abs(turned[1].y - 1) < 1e-5, "%v", turned)
	environment_view(&app)
	testing.expect(t, app.renderer.environment == nil)
	app.env.kind = .Image
	environment_view(&app)
	testing.expect(t, app.renderer.environment == nil, "no panorama is loaded yet")
}

// Its own Turn adds to the lights' Turn all, Tilt leans the up axis, and the drag turn
// wraps round rather than stopping; the recent list keeps each file once, newest first,
// and no more than its length.
@(test)
environment_controls_turn_tilt_and_remember :: proc(t: ^testing.T) {
	app: App
	lights_reset(&app)
	environment_settings_default(&app)
	defer environment_destroy(&app)
	app.camera = camera.orbit_default()
	app.light_turn = 30
	app.env.turn = 60
	by_both := environment_rotation(&app)
	app.light_turn, app.env.turn = 90, 0
	testing.expect_value(t, environment_rotation(&app), by_both)
	app.env.tilt = 30
	leaned := environment_rotation(&app)
	testing.expectf(t, abs(leaned[1].y - math.cos(math.to_radians(f32(30)))) < 1e-5, "%v", leaned)
	testing.expect_value(t, wrap_degrees(190), f32(-170))
	testing.expect_value(t, wrap_degrees(-190), f32(170))
	testing.expect_value(t, wrap_degrees(540), f32(-180))
	app.env.turn = 170
	app.kit.scale = 1
	environment_drag(&app, {-80, 0})
	testing.expectf(t, abs(app.env.turn - (-170)) < 1e-4, "dragged left past 180 it comes round: %v", app.env.turn)
	for name in ([]string{"a.exr", "b.hdr", "a.exr", "c.png", "d.exr", "e.exr", "f.exr"}) do environment_recent_add(&app, name)
	testing.expect_value(t, len(app.env.recent), ENVIRONMENT_RECENT_MAX)
	testing.expect_value(t, app.env.recent[0], "f.exr")
	testing.expect_value(t, app.env.recent[ENVIRONMENT_RECENT_MAX - 1], "a.exr")
	environment_recent_append(&app, "g.exr")
	testing.expect_value(t, len(app.env.recent), ENVIRONMENT_RECENT_MAX)
	app.env.background, app.env.blur = false, 0.3
	testing.expect_value(t, environment_backdrop(&app.env), Environment_Backdrop.Plain)
	app.env.background = true
	testing.expect_value(t, environment_backdrop(&app.env), Environment_Backdrop.Blurred)
	app.env.blur = 0
	testing.expect_value(t, environment_backdrop(&app.env), Environment_Backdrop.Shown)
}
