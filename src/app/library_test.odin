package main

import "core:os"
import "core:strings"
import "core:testing"

import "../png_write"

// A small grey PNG whose pixels `seed` varies, so two seeds are two different images.
@(private = "file")
test_png :: proc(seed: u8) -> []u8 {
	pixels: [8 * 8 * 4]u8
	for i in 0 ..< 64 {
		v := u8(i * 4) + seed
		pixels[4 * i], pixels[4 * i + 1], pixels[4 * i + 2], pixels[4 * i + 3] = v, v, v, 0xff
	}
	return png_write.encode(pixels[:], 8, 8, false, context.temp_allocator)
}

// The brush as preset tests start it (presets_test.odin's preset_app, which a run of
// only these tests does not build).
@(private = "file")
library_preset_app :: proc(app: ^App) {
	app.brush.kind = .Clay
	app.brush.alpha = -1
	for &s, kind in app.brush.strengths do s = BRUSHES[kind].strength
}

@(private = "file")
library_app_free :: proc(app: ^App) {
	results_destroy(app)
	alphas_destroy(app)
	library_destroy(app)
}

// Load image keeps a copy in the library: the same image again is found there, not kept
// twice; another image of the same name gets a name of its own. At the next start the
// library's alphas come back after the built-ins, and so do the preset and the brush
// that used one, by reference; Remove from library takes the file away and leaves them
// round.
@(test)
library_keeps_loaded_alphas :: proc(t: ^testing.T) {
	FOLDER :: "build/library_test/"
	_ = os.remove_all(FOLDER)
	defer os.remove_all(FOLDER)
	testing.expect(t, os.make_directory_all(FOLDER + "picked/other") == nil)
	settings := FOLDER + "run.txt"
	rock, other := FOLDER + "picked/Rock face!.png", FOLDER + "picked/other/Rock face!.png"
	testing.expect(t, os.write_entire_file(rock, test_png(0)) == nil)
	testing.expect(t, os.write_entire_file(other, test_png(1)) == nil)
	testing.expect_value(t, library_folder(settings), FOLDER + "run-library")
	testing.expect_value(t, library_folder("dir/settings.txt"), "dir/library")

	a: App
	defer library_app_free(&a)
	alphas_init(&a)
	library_load(&a, library_folder(settings))
	builtins := len(a.alphas)
	testing.expect(t, alpha_keep(&a, rock))
	testing.expect_value(t, alpha_ref(&a, a.brush.alpha), "mine/Rock face")
	testing.expect(t, strings.contains(a.result.text, "kept it in your library"), a.result.text)
	testing.expect(t, alpha_keep(&a, rock))
	testing.expect(t, strings.contains(a.result.text, "already"), a.result.text)
	testing.expect_value(t, len(a.alphas), builtins + 1)
	testing.expect(t, alpha_keep(&a, other))
	testing.expect_value(t, alpha_ref(&a, a.brush.alpha), "mine/Rock face-2")
	testing.expect(t, os.exists(FOLDER + "run-library/mine/alphas/Rock face.png"))
	testing.expect(t, os.exists(FOLDER + "run-library/mine/alphas/Rock face-2.png"))

	// A preset on the first, the plain brush on the second.
	library_preset_app(&a)
	testing.expect(t, alpha_select(&a, "mine/rock face"))
	testing.expect(t, preset_save_new(&a))
	testing.expect(t, preset_rename(&a, 0, "Rocky"))
	preset_leave(&a)
	testing.expect(t, alpha_select(&a, "Rock face-2"))
	testing.expect(t, settings_save(&a, settings))

	b: App
	defer library_app_free(&b)
	alphas_init(&b)
	library_load(&b, library_folder(settings))
	library_preset_app(&b)
	settings_load(&b, settings)
	testing.expect_value(t, b.library.alphas, 2)
	testing.expect_value(t, len(b.alphas), builtins + 2)
	testing.expect_value(t, alpha_ref(&b, builtins), "mine/Rock face")
	testing.expect_value(t, alpha_ref(&b, b.presets[0].values.alpha), "mine/Rock face")
	testing.expect_value(t, alpha_ref(&b, b.brush.alpha), "mine/Rock face-2")

	testing.expect(t, alpha_remove(&b, builtins))
	testing.expect(t, !os.exists(FOLDER + "run-library/mine/alphas/Rock face.png"))
	testing.expect_value(t, b.presets[0].values.alpha, -1)
	testing.expect(t, strings.contains(b.result.text, "1 preset that used it is round"), b.result.text)
	testing.expect(t, !alpha_remove(&b, 0), "a built-in was removed")
	testing.expect_value(t, alpha_find(&b, "mine/Rock face"), -1)
	testing.expect_value(t, b.library.alphas, 1)
	free_all(context.temp_allocator)
}

// A file in the library that is not an image is skipped with one note and left on disk;
// the images beside it load, sorted by name; a run with no library loads an image for
// itself only.
@(test)
library_skips_what_it_cannot_read :: proc(t: ^testing.T) {
	FOLDER :: "build/library_skip_test/"
	_ = os.remove_all(FOLDER)
	defer os.remove_all(FOLDER)
	ALPHAS :: FOLDER + "run-library/mine/alphas/"
	testing.expect(t, os.make_directory_all(ALPHAS) == nil)
	testing.expect(t, os.write_entire_file(ALPHAS + "b.png", test_png(2)) == nil)
	testing.expect(t, os.write_entire_file(ALPHAS + "a.png", test_png(3)) == nil)
	testing.expect(t, os.write_entire_file(ALPHAS + "broken.png", transmute([]u8)string("not a png")) == nil)
	testing.expect(t, os.write_entire_file(ALPHAS + "notes.txt", transmute([]u8)string("ignored")) == nil)

	a: App
	defer library_app_free(&a)
	alphas_init(&a)
	builtins := len(a.alphas)
	library_load(&a, library_folder(FOLDER + "run.txt"))
	testing.expect_value(t, a.library.alphas, 2)
	testing.expect_value(t, a.library.skipped, 1)
	testing.expect_value(t, a.alphas[builtins].ref, "mine/a")
	testing.expect_value(t, a.alphas[builtins + 1].ref, "mine/b")
	testing.expect(t, strings.contains(a.result.text, "broken.png"), a.result.text)
	testing.expect(t, os.exists(ALPHAS + "broken.png"))

	none: App
	defer library_app_free(&none)
	alphas_init(&none)
	library_load(&none, "")
	testing.expect(t, alpha_keep(&none, ALPHAS + "a.png"))
	testing.expect_value(t, alpha_ref(&none, none.brush.alpha), "a")
	testing.expect_value(t, none.alphas[none.brush.alpha].file, "")
	free_all(context.temp_allocator)
}
