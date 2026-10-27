package main

import "core:os"
import "core:slice"
import "core:testing"

import "../geom"

// Shrinking averages every source pixel a result pixel covers, and leaves an image no
// larger than the long side as it is.
@(test)
preview_shrink_averages_what_each_pixel_covers :: proc(t: ^testing.T) {
	// Four by two: a black and a white column pair, then two greys.
	pixels := []u8{
		0, 0, 0, 255, 255, 255, 255, 255, 10, 10, 10, 255, 30, 30, 30, 255,
		0, 0, 0, 255, 255, 255, 255, 255, 50, 50, 50, 255, 70, 70, 70, 255,
	}
	out, w, h := preview_shrink(pixels, 4, 2, 2)
	defer delete(out)
	testing.expect(t, w == 2 && h == 1)
	testing.expect_value(t, out[0], 128) // (0 + 255 + 0 + 255) / 4, rounded
	testing.expect_value(t, out[4], 40) // (10 + 30 + 50 + 70) / 4
	testing.expect_value(t, out[7], 255)
	same, sw, sh := preview_shrink(pixels, 4, 2, 320)
	defer delete(same)
	testing.expect(t, sw == 4 && sh == 2 && slice.equal(same, pixels))
	none, _, _ := preview_shrink(nil, 0, 0, 320)
	testing.expect(t, none == nil)
}

// A scene's start carries its preview block, which the Home screen reads alone: the
// numbers and the picture's bytes as written; opening steps over it; a length past the
// file or the limit is damage; a file from before version 22 has none.
@(test)
preview_block_reads_from_the_start_of_the_file :: proc(t: ^testing.T) {
	path := "build/preview_test.sculpt"
	defer os.remove(path)
	app: App
	defer delete(app.preview.png)
	append(&app.preview.png, ..[]u8{1, 2, 3, 4, 5})
	app.preview.w, app.preview.h = 32, 18
	out: [dynamic]u8
	defer delete(out)
	append(&out, SCENE_MAGIC)
	geom.byte_put(&out, SCENE_VERSION)
	preview_block_put(&app, &out)
	block_end := len(out)
	append(&out, ..[]u8{9, 9, 9})
	testing.expect(t, os.write_entire_file(path, out[:]) == nil)

	info, png, ok := scene_preview_read(path)
	testing.expect(t, ok && info.version == SCENE_VERSION && info.saved > 0 && info.objects == 0 && info.w == 32 && info.h == 18)
	testing.expect(t, slice.equal(png, []u8{1, 2, 3, 4, 5}))
	delete(png)
	r := geom.byte_reader(out[len(SCENE_MAGIC) + 4:])
	testing.expect(t, preview_block_skip(&r) && r.at + len(SCENE_MAGIC) + 4 == block_end)

	// The length run past the file, or past the limit.
	at := len(SCENE_MAGIC) + 4
	for bad in ([]u32{u32(len(out)), PREVIEW_BLOCK_MAX + 1, 3}) {
		damaged := make([]u8, len(out))
		defer delete(damaged)
		copy(damaged, out[:])
		(^u32le)(&damaged[at])^ = u32le(bad)
		r = geom.byte_reader(damaged[at:])
		testing.expectf(t, !preview_block_skip(&r), "a length of %d was stepped over", bad)
		testing.expect(t, os.write_entire_file(path, damaged) == nil)
		_, none, read := scene_preview_read(path)
		testing.expectf(t, !read && none == nil, "a length of %d was read", bad)
	}

	// No picture yet: the numbers alone.
	clear(&app.preview.png)
	clear(&out)
	append(&out, SCENE_MAGIC)
	geom.byte_put(&out, SCENE_VERSION)
	preview_block_put(&app, &out)
	testing.expect(t, os.write_entire_file(path, out[:]) == nil)
	info, png, ok = scene_preview_read(path)
	testing.expect(t, ok && png == nil && info.w == 0 && info.saved > 0)

	// Version 21: no block, read as no picture and no numbers.
	clear(&out)
	append(&out, SCENE_MAGIC)
	geom.byte_put(&out, u32(21))
	geom.byte_put(&out, u32(1))
	testing.expect(t, os.write_entire_file(path, out[:]) == nil)
	info, png, ok = scene_preview_read(path)
	testing.expect(t, ok && png == nil && info.version == 21 && info.saved == 0)
	// Not a scene.
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string("hello there, not a scene")) == nil)
	_, _, ok = scene_preview_read(path)
	testing.expect(t, !ok)
}
