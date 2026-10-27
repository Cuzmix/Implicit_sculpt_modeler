package main

import "core:hash"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"

import "../png_write"

// A ZIP archive of stored entries, as a zip tool writes one: (name, bytes) pairs.
@(private = "file")
test_zip :: proc(files: [][2]string) -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	u16le :: proc(out: ^[dynamic]u8, v: int) {append(out, u8(v), u8(v >> 8))}
	u32le :: proc(out: ^[dynamic]u8, v: int) {append(out, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))}
	offsets := make([]int, len(files), context.temp_allocator)
	for f, i in files {
		offsets[i] = len(out)
		u32le(&out, 0x04034b50)
		u16le(&out, 20)
		u16le(&out, 0)
		u16le(&out, 0)
		u32le(&out, 0)
		u32le(&out, int(hash.crc32(transmute([]u8)f[1])))
		u32le(&out, len(f[1]))
		u32le(&out, len(f[1]))
		u16le(&out, len(f[0]))
		u16le(&out, 0)
		append(&out, f[0])
		append(&out, f[1])
	}
	dir := len(out)
	for f, i in files {
		u32le(&out, 0x02014b50)
		u16le(&out, 20)
		u16le(&out, 20)
		u16le(&out, 0)
		u16le(&out, 0)
		u32le(&out, 0)
		u32le(&out, int(hash.crc32(transmute([]u8)f[1])))
		u32le(&out, len(f[1]))
		u32le(&out, len(f[1]))
		u16le(&out, len(f[0]))
		for _ in 0 ..< 4 do u16le(&out, 0)
		u32le(&out, 0)
		u32le(&out, offsets[i])
		append(&out, f[0])
	}
	u32le(&out, 0x06054b50)
	u16le(&out, 0)
	u16le(&out, 0)
	u16le(&out, len(files))
	u16le(&out, len(files))
	u32le(&out, len(out) - 12 - dir)
	u32le(&out, dir)
	u16le(&out, 0)
	return out[:]
}

// A small grey PNG, as a string for test_zip; `seed` varies the pixels.
@(private = "file")
pack_png :: proc(seed: u8) -> string {
	pixels: [8 * 8 * 4]u8
	for i in 0 ..< 64 {
		v := u8(i * 4) + seed
		pixels[4 * i], pixels[4 * i + 1], pixels[4 * i + 2], pixels[4 * i + 3] = v, v, v, 0xff
	}
	return string(png_write.encode(pixels[:], 8, 8, false, context.temp_allocator))
}

@(private = "file")
pack_app :: proc(app: ^App, settings: string) {
	alphas_init(app)
	library_load(app, library_folder(settings))
	app.brush.kind = .Clay
	app.brush.alpha = -1
	for &s, kind in app.brush.strengths do s = BRUSHES[kind].strength
}

@(private = "file")
pack_app_free :: proc(app: ^App) {
	results_destroy(app)
	alphas_destroy(app)
	library_destroy(app)
}

@(private = "file")
pack_write :: proc(t: ^testing.T, path: string, files: [][2]string) {
	testing.expect(t, os.write_entire_file(path, test_zip(files)) == nil)
}

// A pack installs into library/<id> with its alphas named <id>/<stem> and what this
// version does not read left out and counted; the next start reads it back, with the
// preset that used one of its alphas. Installing it again (same name and author) waits
// on Replace; replacing keeps the alphas that are still there under the same names
// and drops presets on one that went to round; Remove takes the folder and alphas away.
@(test)
pack_installs_replaces_and_removes :: proc(t: ^testing.T) {
	FOLDER :: "build/pack_test/"
	_ = os.remove_all(FOLDER)
	defer os.remove_all(FOLDER)
	testing.expect(t, os.make_directory_all(FOLDER) == nil)
	settings := FOLDER + "run.txt"
	LIBRARY :: FOLDER + "run-library"
	v1, v2 := FOLDER + "rocks.sculptpack", FOLDER + "rocks-2.sculptpack"
	pack_write(t, v1, {
		{"pack.txt", "# Made by hand\nname Rock Set\nauthor Bolt\nversion 1.0\nlicense CC0\ndescription Pebbles and cracks\n"},
		{"alphas/", ""}, {"alphas/Pebble.png", pack_png(0)}, {"alphas/crack.png", pack_png(9)},
		{"meshes/boulder.obj", "v 0 0 0\n"}, {"macros/evil.cmd", "remesh\n"},
	})
	pack_write(t, v2, {{"pack.txt", "name Rock Set\nauthor bolt\nversion 2.0\n"}, {"alphas/Pebble.png", pack_png(5)}})

	a: App
	defer pack_app_free(&a)
	pack_app(&a, settings)
	builtins := len(a.alphas)
	testing.expect_value(t, pack_install_finish(&a, pack_unpack(v1, a.library.folder), replace = false), "")
	testing.expect(t, strings.contains(a.result.text, "Installed Rock Set 1.0: 2 alphas; left out 2 files"), a.result.text)
	testing.expect_value(t, len(a.library.packs), 1)
	testing.expect_value(t, a.library.packs[0].id, "rock-set")
	testing.expect_value(t, a.library.packs[0].license, "CC0")
	testing.expect_value(t, alpha_ref(&a, builtins), "rock-set/Pebble")
	testing.expect(t, os.exists(LIBRARY + "/rock-set/alphas/Pebble.png"))
	testing.expect(t, !os.exists(LIBRARY + "/rock-set/meshes") && !os.exists(LIBRARY + "/rock-set/macros"))
	testing.expect(t, !os.exists(LIBRARY + "/" + PACK_INCOMING))
	testing.expect(t, alpha_select(&a, "rock-set/crack"))
	testing.expect(t, preset_save_new(&a))
	preset_leave(&a)
	testing.expect(t, alpha_select(&a, "ROCK-SET/pebble"))
	testing.expect(t, settings_save(&a, settings))

	b: App
	defer pack_app_free(&b)
	pack_app(&b, settings)
	settings_load(&b, settings)
	testing.expect_value(t, len(b.library.packs), 1)
	testing.expect_value(t, b.library.packs[0].alphas, 2)
	testing.expect_value(t, b.library.packs[0].description, "Pebbles and cracks")
	testing.expect_value(t, alpha_ref(&b, b.presets[0].values.alpha), "rock-set/crack")
	testing.expect_value(t, alpha_ref(&b, b.brush.alpha), "rock-set/Pebble")

	// Version 2 waits on Replace, then keeps Pebble and drops crack.
	testing.expect_value(t, pack_install_finish(&b, pack_unpack(v2, b.library.folder), replace = false), "")
	testing.expect(t, b.library.pending != nil && b.kit.library)
	testing.expect(t, !command_enabled(&b, .Pick_Pack))
	pack_pending_answer(&b, true)
	testing.expect(t, b.library.pending == nil)
	testing.expect_value(t, len(b.library.packs), 1)
	testing.expect_value(t, b.library.packs[0].version, "2.0")
	testing.expect_value(t, b.library.packs[0].id, "rock-set")
	testing.expect_value(t, alpha_ref(&b, b.brush.alpha), "rock-set/Pebble")
	testing.expect_value(t, b.presets[0].values.alpha, -1)
	testing.expect(t, strings.contains(b.result.text, "Replaced Rock Set 2.0: 1 alpha; 1 preset used alphas it no longer has and is round now"), b.result.text)
	testing.expect(t, !os.exists(LIBRARY + "/rock-set/alphas/crack.png"))
	testing.expect(t, !os.exists(LIBRARY + "/" + PACK_ASIDE))

	// Keep the old one leaves it as it was.
	testing.expect_value(t, pack_install_finish(&b, pack_unpack(v1, b.library.folder), replace = false), "")
	pack_pending_answer(&b, false)
	testing.expect_value(t, b.library.packs[0].version, "2.0")
	testing.expect(t, !os.exists(LIBRARY + "/" + PACK_INCOMING))

	testing.expect(t, pack_remove(&b, 0))
	testing.expect_value(t, len(b.library.packs), 0)
	testing.expect(t, !os.exists(LIBRARY + "/rock-set"))
	testing.expect_value(t, b.brush.alpha, -1)
	testing.expect_value(t, alpha_find(&b, "rock-set/Pebble"), -1)
	free_all(context.temp_allocator)
}

// A file that is not a pack, or a pack with a bad part, is refused before anything
// reaches the library, and says why; a pack named like another of a different author
// gets an id of its own; a pack installs on its own thread, finished by the frame.
@(test)
pack_refuses_and_installs_off_the_frame :: proc(t: ^testing.T) {
	FOLDER :: "build/pack_refuse_test/"
	_ = os.remove_all(FOLDER)
	defer os.remove_all(FOLDER)
	testing.expect(t, os.make_directory_all(FOLDER) == nil)
	LIBRARY :: FOLDER + "run-library"
	a: App
	defer pack_app_free(&a)
	pack_app(&a, FOLDER + "run.txt")

	Case :: struct {
		files: [][2]string,
		why:   string,
	}
	cases := []Case {
		{{{"alphas/a.png", pack_png(0)}}, "has no pack.txt"},
		{{{"pack.txt", "author Nobody\n"}}, "has no name line"},
		{{{"pack.txt", "name Bad\n"}, {"alphas/a.png", "not a png"}}, "alphas/a.png is not an image"},
		{{{"pack.txt", "name Slip\n"}, {"../escape.png", pack_png(0)}}, "could write outside its folder"},
		{{{"pack.txt", "name Twice\n"}, {"alphas/A.png", pack_png(0)}, {"alphas/a.png", pack_png(1)}}, "same name"},
	}
	for c, i in cases {
		path := strings.concatenate({FOLDER, "case", string([]u8{'0' + u8(i)}), ".sculptpack"}, context.temp_allocator)
		pack_write(t, path, c.files)
		failed := pack_install_finish(&a, pack_unpack(path, a.library.folder), replace = false)
		testing.expectf(t, strings.contains(failed, c.why), "case %d: %q", i, failed)
	}
	not_zip := FOLDER + "notes.sculptpack"
	testing.expect(t, os.write_entire_file(not_zip, transmute([]u8)string("just some text")) == nil)
	testing.expect(t, strings.contains(pack_install_finish(&a, pack_unpack(not_zip, a.library.folder), replace = false), "not a ZIP"))
	testing.expect_value(t, a.library.refused, len(cases) + 1)
	testing.expect_value(t, len(a.library.packs), 0)
	testing.expect(t, !os.exists(LIBRARY + "/" + PACK_INCOMING))

	// Two packs of one name by different authors, the second through the install thread.
	first, second := FOLDER + "first.sculptpack", FOLDER + "second.sculptpack"
	pack_write(t, first, {{"pack.txt", "name Mine\nauthor One\n"}, {"alphas/x.png", pack_png(0)}})
	pack_write(t, second, {{"pack.txt", "name Mine\nauthor Two\n"}, {"alphas/x.png", pack_png(1)}})
	testing.expect_value(t, pack_install_finish(&a, pack_unpack(first, a.library.folder), replace = false), "")
	pack_install_start(&a, second)
	testing.expect(t, pack_busy(&a))
	thread.join(a.library.worker.thread)
	library_frame(&a)
	testing.expect(t, !pack_busy(&a))
	testing.expect_value(t, len(a.library.packs), 2)
	testing.expect_value(t, a.library.packs[0].id, "mine-pack")
	testing.expect_value(t, a.library.packs[1].id, "mine-pack-2")
	testing.expect_value(t, a.library.installed, 2)
	free_all(context.temp_allocator)
}

// pack.txt: key value lines, comments and unknown keys skipped, values cut to
// PACK_TEXT_MAX characters, a name needed, UTF-8 only.
@(test)
pack_text_reads_its_keys :: proc(t: ^testing.T) {
	p: Pack
	defer pack_free(&p)
	long := strings.repeat("é", PACK_TEXT_MAX + 5, context.temp_allocator)
	testing.expect(t, pack_text_parse(strings.concatenate({"# a comment\n  name   Stone  Age  \nfrobnicate yes\nauthor ", long, "\n"}, context.temp_allocator), &p))
	testing.expect_value(t, p.name, "Stone  Age")
	testing.expect_value(t, strings.rune_count(p.author), PACK_TEXT_MAX)
	q: Pack
	defer pack_free(&q)
	testing.expect(t, !pack_text_parse("author Someone\n", &q))
	testing.expect(t, !pack_text_parse("name \xff\n", &q))
	free_all(context.temp_allocator)
}
