package main

import "core:bytes"
import "core:image"
import "core:testing"

// The built-in matcaps are painted the same every time, lit from the upper left: each
// picture's upper-left half is brighter than its lower right, its middle is not black,
// and the pixels outside the sphere repeat its edge, so filtering finds no background.
@(test)
matcaps_paint_lit_spheres :: proc(t: ^testing.T) {
	N :: 32
	a, b: [N * N * 4]u8
	for recipe in MATCAP_RECIPES {
		matcap_paint(recipe, N, a[:])
		matcap_paint(recipe, N, b[:])
		testing.expectf(t, a == b, "%s: two paintings differ", recipe.label)
		brightness :: proc(p: []u8, x, y: int) -> int {
			at := (y * N + x) * 4
			return int(p[at]) + int(p[at + 1]) + int(p[at + 2])
		}
		lit, shade := 0, 0
		for y in 0 ..< N do for x in 0 ..< N {
			if x + y < N - 1 do lit += brightness(a[:], x, y)
			if x + y > N - 1 do shade += brightness(a[:], x, y)
		}
		testing.expectf(t, lit > shade, "%s: the lit half (%d) is no brighter than the shaded one (%d)", recipe.label, lit, shade)
		testing.expectf(t, brightness(a[:], N / 2, N / 2) > 60, "%s: the middle is dark", recipe.label)
		for y in 0 ..< N do for x in 0 ..< N do testing.expect_value(t, a[(y * N + x) * 4 + 3], 255)
		// Two pixels outside the sphere on one ray from the middle take the same edge colour.
		at := (N + 1) * 4
		testing.expectf(t, a[0] == a[at] && a[1] == a[at + 1] && a[2] == a[at + 2], "%s: the corner is not the edge's colour", recipe.label)
	}
}

// The matcap presets follow the others in order, each naming its own picture, and are
// found by name as a script or the settings file writes them.
@(test)
matcap_presets_name_their_pictures :: proc(t: ^testing.T) {
	testing.expect_value(t, MATERIALS[FIRST_MATCAP - 1].matcap, 0)
	testing.expect_value(t, len(MATERIALS) - FIRST_MATCAP, len(MATCAP_RECIPES))
	for i in FIRST_MATCAP ..< len(MATERIALS) {
		testing.expect_value(t, MATERIALS[i].matcap, i - FIRST_MATCAP + 1)
		testing.expect_value(t, MATERIALS[i].idle, MATCAP_IDLE)
	}
	index, ok := material_by_name("red wax matcap")
	testing.expect(t, ok)
	testing.expect_value(t, MATERIALS[index].matcap, 1)
	app: App
	testing.expect(t, material_matcap(&app, MATERIALS[0]) == nil)
	testing.expect_value(t, matcap_label(&app, 6), "Toon")
	testing.expect_value(t, matcap_label(&app, MATCAP_IMAGE), "image")
}

// Grey, grey with alpha, RGB and 16-bit pictures all come out as RGBA8, and other
// depths are refused.
@(test)
matcap_images_become_rgba8 :: proc(t: ^testing.T) {
	out: [8]u8
	grey := image.Image{width = 2, height = 1, channels = 1, depth = 8}
	bytes.buffer_init(&grey.pixels, {10, 200})
	defer bytes.buffer_destroy(&grey.pixels)
	testing.expect(t, image_rgba8(&grey, out[:]))
	testing.expect_value(t, out, [8]u8{10, 10, 10, 255, 200, 200, 200, 255})

	grey_alpha := image.Image{width = 2, height = 1, channels = 2, depth = 8}
	bytes.buffer_init(&grey_alpha.pixels, {10, 20, 30, 40})
	defer bytes.buffer_destroy(&grey_alpha.pixels)
	testing.expect(t, image_rgba8(&grey_alpha, out[:]))
	testing.expect_value(t, out, [8]u8{10, 10, 10, 20, 30, 30, 30, 40})

	wide := image.Image{width = 1, height = 1, channels = 3, depth = 16}
	values := [3]u16{0, 65535, 32896}
	raw := transmute([6]u8)values
	bytes.buffer_init(&wide.pixels, raw[:])
	defer bytes.buffer_destroy(&wide.pixels)
	testing.expect(t, image_rgba8(&wide, out[:4]))
	testing.expect_value(t, [4]u8{out[0], out[1], out[2], out[3]}, [4]u8{0, 255, 128, 255})

	odd := image.Image{width = 1, height = 1, channels = 3, depth = 1}
	testing.expect(t, !image_rgba8(&odd, out[:4]))
}
