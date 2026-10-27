package main

import "core:fmt"
import "core:hash"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:thread"

import "../geom"
import "../jobs"
import "../png_write"
import "../sculpt"

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
		{"materials/clay.txt", "base 0.8\n"}, {"macros/evil.cmd", "remesh\n"},
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
	testing.expect(t, !os.exists(LIBRARY + "/rock-set/materials") && !os.exists(LIBRARY + "/rock-set/macros"))
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

// A pack's brushes.txt brings presets named after it, read-only, whose alphas are the
// pack's own or built-ins; lines it cannot use are skipped and counted. The brush and the
// dock keep a pack preset across a restart; a replace keeps them on a preset of the same
// name and Remove sends them back to the plain brush.
@(test)
pack_presets_join_the_brush_and_dock :: proc(t: ^testing.T) {
	FOLDER :: "build/pack_preset_test/"
	_ = os.remove_all(FOLDER)
	defer os.remove_all(FOLDER)
	testing.expect(t, os.make_directory_all(FOLDER) == nil)
	settings := FOLDER + "run.txt"
	LIBRARY :: FOLDER + "run-library"
	lines :: proc(presets: ..struct {
			name, alpha: string,
			kind:        sculpt.Brush_Kind,
			strength:    f32,
		}) -> string {
		out := strings.builder_make(context.temp_allocator)
		for p in presets {
			v := Preset_Values{kind = p.kind, strength = p.strength, alpha = -1, falloff = {curve = FALLOFF_SMOOTH_CURVE}}
			preset_line(&out, p.name, v, p.alpha)
		}
		return strings.to_string(out)
	}
	v1, v2 := FOLDER + "set.sculptpack", FOLDER + "set-2.sculptpack"
	brushes := strings.concatenate({
		lines({"Stone Clay", "stone", .Clay, 0.6}, {"Noisy Draw", "noise", .Draw, 0.3}, {"Draw", "-", .Draw, 0.5}, {"stone clay", "-", .Clay, 0.5}, {"Lost", "missing", .Clay, 0.5}),
		"hello there\npreset Broken Clay\n",
	}, context.temp_allocator)
	pack_write(t, v1, {{"pack.txt", "name Brush Set\nauthor Bolt\n"}, {"alphas/Stone.png", pack_png(0)}, {"brushes.txt", brushes}})
	pack_write(t, v2, {{"pack.txt", "name Brush Set\nauthor Bolt\nversion 2\n"}, {"brushes.txt", lines({"Stone Clay", "-", .Clay, 0.9})}})

	a: App
	defer pack_app_free(&a)
	pack_app(&a, settings)
	testing.expect_value(t, pack_install_finish(&a, pack_unpack(v1, a.library.folder), replace = false), "")
	testing.expect(t, strings.contains(a.result.text, "Installed Brush Set: 1 alpha and 2 presets; skipped 5 lines of brushes.txt"), a.result.text)
	stone := pack_preset_find(&a, "brush-set", "STONE CLAY")
	noisy := preset_by_ref(&a, "brush-set/Noisy Draw")
	testing.expect(t, preset_of_pack(stone) && preset_of_pack(noisy))
	p, _ := preset_at(&a, stone)
	testing.expect_value(t, alpha_ref(&a, p.values.alpha), "brush-set/Stone")
	q, _ := preset_at(&a, noisy)
	testing.expect_value(t, alpha_ref(&a, q.values.alpha), "Noise")

	// Read-only: Save changes and Delete are not offered; Revert and Save as new are.
	preset_use(&a, stone)
	testing.expect_value(t, a.brush.preset, stone)
	testing.expect_value(t, a.brush.strengths[.Clay], f32(0.6))
	a.brush.strengths[.Clay] = 0.2
	testing.expect(t, preset_changed(&a))
	testing.expect(t, !command_enabled(&a, .Preset_Save) && !command_enabled(&a, .Preset_Delete))
	preset_save(&a)
	testing.expect_value(t, p.values.strength, f32(0.6))
	preset_revert(&a)
	testing.expect(t, !preset_changed(&a))
	dock_put(&a, 2, .Draw, stone)
	dock_put(&a, 3, .Clay, noisy)
	testing.expect_value(t, a.kit.dock[2], Dock_Slot{kind = .Clay, preset = stone})
	testing.expect_value(t, dock_slot_label(&a, a.kit.dock[3]), "Noisy Draw")
	testing.expect(t, settings_save(&a, settings))

	b: App
	defer pack_app_free(&b)
	pack_app(&b, settings)
	settings_load(&b, settings)
	testing.expect_value(t, b.library.packs[0].presets, 2)
	testing.expect_value(t, b.library.skipped, 0)
	testing.expect_value(t, preset_ref(&b, b.brush.preset), "brush-set/Stone Clay")
	testing.expect_value(t, preset_ref(&b, b.kit.dock[2].preset), "brush-set/Stone Clay")
	testing.expect_value(t, preset_ref(&b, b.kit.dock[3].preset), "brush-set/Noisy Draw")
	written, _ := os.read_entire_file(LIBRARY + "/brush-set/brushes.txt", context.temp_allocator)
	testing.expect_value(t, strings.count(string(written), "\n"), 2)

	// Save as new makes one of the person's own, named after it.
	testing.expect(t, preset_save_new(&b))
	testing.expect_value(t, preset_name(&b.presets[0]), "Stone Clay 1")
	testing.expect_value(t, b.brush.preset, 1)
	preset_use(&b, b.kit.dock[2].preset)

	// Version 2 has Stone Clay still and no Noisy Draw.
	testing.expect_value(t, pack_install_finish(&b, pack_unpack(v2, b.library.folder), replace = true), "")
	testing.expect_value(t, preset_ref(&b, b.brush.preset), "brush-set/Stone Clay")
	testing.expect(t, preset_changed(&b))
	preset_revert(&b)
	testing.expect_value(t, b.brush.strengths[.Clay], f32(0.9))
	testing.expect_value(t, preset_ref(&b, b.kit.dock[2].preset), "brush-set/Stone Clay")
	testing.expect_value(t, b.kit.dock[3], Dock_Slot{kind = .Draw})

	// Remove sends the brush back to plain Clay, with its own strength, and the slot to Clay.
	testing.expect(t, pack_remove(&b, 0))
	testing.expect_value(t, b.brush.preset, 0)
	testing.expect_value(t, b.brush.kind, sculpt.Brush_Kind.Clay)
	testing.expect_value(t, b.kit.dock[2], Dock_Slot{kind = .Clay})
	testing.expect_value(t, preset_by_ref(&b, "brush-set/Stone Clay"), 0)
	testing.expect_value(t, preset_name(&b.presets[0]), "Stone Clay 1")
	free_all(context.temp_allocator)
}

// A tetrahedron as OBJ text, and as a binary PLY.
@(private = "file")
TETRA_OBJ :: "v 0 0 0\nv 1 0 0\nv 0 1 0\nv 0 0 1\nf 1 3 2\nf 1 2 4\nf 1 4 3\nf 2 3 4\n"

@(private = "file")
tetra_ply :: proc() -> string {
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, "ply\nformat binary_little_endian 1.0\nelement vertex 4\nproperty float x\nproperty float y\nproperty float z\nelement face 4\nproperty list uchar int vertex_indices\nend_header\n")
	corners := [4][3]f32{{0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}}
	for c in corners do for x in c {
		b := transmute([4]u8)x
		append(&out, ..b[:])
	}
	faces := [4][3]i32{{0, 2, 1}, {0, 1, 3}, {0, 3, 2}, {1, 2, 3}}
	for f in faces {
		append(&out, 3)
		for i in f {
			b := transmute([4]u8)i
			append(&out, ..b[:])
		}
	}
	return string(out[:])
}

// A pack's meshes install with their counts (a second mesh of one name and a mesh in a
// folder below left out), come back at the next start from meshes.txt, and a mesh that does not
// read refuses the pack, naming its line. Add object and the New scene rows point at
// a mesh by its index, which a replace moves to the new copy and a removal lets go of;
// the arming of New scene works as for a shape. Parsing with no pool, as the install
// thread does, gives the same mesh as with the frame's pool.
@(test)
pack_meshes_install_and_list :: proc(t: ^testing.T) {
	FOLDER :: "build/pack_mesh_test/"
	_ = os.remove_all(FOLDER)
	defer os.remove_all(FOLDER)
	testing.expect(t, os.make_directory_all(FOLDER) == nil)
	settings := FOLDER + "run.txt"
	LIBRARY :: FOLDER + "run-library"
	v1, v2, bad := FOLDER + "rocks.sculptpack", FOLDER + "rocks-2.sculptpack", FOLDER + "bad.sculptpack"
	pack_write(t, v1, {
		{"pack.txt", "name Rock Set\nauthor Bolt\n"}, {"meshes/Boulder.obj", TETRA_OBJ}, {"meshes/Boulder.ply", tetra_ply()},
		{"meshes/Pebble.ply", tetra_ply()}, {"meshes/sub/deep.obj", TETRA_OBJ},
	})
	pack_write(t, v2, {{"pack.txt", "name Rock Set\nauthor Bolt\nversion 2\n"}, {"meshes/Pebble.ply", tetra_ply()}})
	pack_write(t, bad, {{"pack.txt", "name Bad Rocks\n"}, {"meshes/broken.obj", "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 x\n"}})

	a: App
	defer pack_app_free(&a)
	pack_app(&a, settings)
	testing.expect_value(t, pack_install_finish(&a, pack_unpack(v1, a.library.folder), replace = false), "")
	testing.expect(t, strings.contains(a.result.text, "Installed Rock Set: 2 meshes; left out 2 files"), a.result.text)
	boulder := pack_mesh_by_ref(&a, "rock-set/BOULDER")
	pebble := pack_mesh_find(&a, "rock-set", "pebble")
	testing.expect(t, boulder >= 0 && pebble >= 0)
	testing.expect_value(t, a.library.meshes[pebble].vertices, 4)
	testing.expect_value(t, a.library.meshes[pebble].triangles, 4)
	testing.expect(t, os.exists(LIBRARY + "/rock-set/meshes/Boulder.obj") && os.exists(LIBRARY + "/rock-set/meshes.txt"))
	testing.expect(t, !os.exists(LIBRARY + "/rock-set/meshes/sub"))

	failed := pack_install_finish(&a, pack_unpack(bad, a.library.folder), replace = false)
	testing.expect(t, strings.contains(failed, "meshes/broken.obj is not a mesh the app reads: line 4"), failed)
	testing.expect_value(t, len(a.library.packs), 1)

	// Add object's pick and an armed New scene follow a replace, and let go on removal.
	a.kit.add_mesh = pebble + 1
	append(&a.history.done, History_Entry{})
	defer delete(a.history.done)
	a.kit.ctx.time = 10
	new_mesh_run(&a, pebble)
	testing.expect(t, a.ui.scene_command.kind == .None && new_mesh_armed(&a, pebble) && !new_scene_armed(&a, 0))
	testing.expect_value(t, pack_install_finish(&a, pack_unpack(v2, a.library.folder), replace = true), "")
	moved := pack_mesh_find(&a, "rock-set", "Pebble")
	testing.expect(t, moved != pebble && moved >= 0)
	testing.expect_value(t, a.kit.add_mesh, moved + 1)
	testing.expect(t, new_mesh_armed(&a, moved))
	new_mesh_run(&a, moved)
	testing.expect_value(t, a.ui.scene_command, Scene_Command{kind = .New, mesh = moved + 1})
	testing.expect_value(t, pack_mesh_by_ref(&a, "rock-set/boulder"), -1)

	b: App
	defer pack_app_free(&b)
	pack_app(&b, settings)
	testing.expect_value(t, len(b.library.meshes), 1)
	testing.expect_value(t, b.library.packs[0].meshes, 1)
	testing.expect_value(t, b.library.meshes[0].triangles, 4)
	b.kit.add_mesh = 1
	testing.expect(t, pack_remove(&b, 0))
	testing.expect_value(t, b.kit.add_mesh, 0)
	testing.expect_value(t, len(b.library.meshes), 1)
	testing.expect(t, b.library.meshes[0].gone)

	// The install thread's serial parse is the frame's parallel one, bit for bit.
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	big := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 3000 do fmt.sbprintf(&big, "v %d %d %d\n", i % 17, i % 23, i % 31)
	for i in 0 ..< 2990 do fmt.sbprintf(&big, "f %d %d %d\n", i + 1, i + 2, i + 3)
	serial, _, s_err, _ := mesh_file_parse(transmute([]u8)strings.to_string(big), false, nil)
	parallel, _, p_err, _ := mesh_file_parse(transmute([]u8)strings.to_string(big), false, &pool)
	defer geom.mesh_destroy(&serial)
	defer geom.mesh_destroy(&parallel)
	testing.expect(t, s_err == p_err)
	testing.expect(t, slice.equal(serial.positions[:], parallel.positions[:]) && slice.equal(serial.indices[:], parallel.indices[:]))
	free_all(context.temp_allocator)
}

// Make a pack writes the person's own alphas and presets, named after the file; installed
// into another library it brings them back: the same values, the preset on a kept alpha
// now on the pack's copy, a built-in kept by name, and one on another pack's alpha round.
@(test)
pack_make_round_trips :: proc(t: ^testing.T) {
	FOLDER :: "build/pack_make_test/"
	_ = os.remove_all(FOLDER)
	defer os.remove_all(FOLDER)
	testing.expect(t, os.make_directory_all(FOLDER) == nil)
	other, rock, made := FOLDER + "other.sculptpack", FOLDER + "Rock face.png", FOLDER + "Bolt clay.sculptpack"
	pack_write(t, other, {{"pack.txt", "name Other\n"}, {"alphas/Crack.png", pack_png(7)}})
	testing.expect(t, os.write_entire_file(rock, transmute([]u8)pack_png(3)) == nil)

	a: App
	defer pack_app_free(&a)
	pack_app(&a, FOLDER + "a.txt")
	testing.expect(t, !command_enabled(&a, .Save_Pack))
	testing.expect(t, strings.contains(pack_make(&a, made), "nothing of yours"))
	testing.expect_value(t, pack_install_finish(&a, pack_unpack(other, a.library.folder), replace = false), "")
	testing.expect(t, alpha_keep(&a, rock))
	saved := [3]string{"Rock face", "Noise", "other/Crack"}
	for ref, i in saved {
		testing.expect(t, alpha_select(&a, ref))
		a.brush.strengths[.Clay] = 0.1 * f32(i + 1)
		testing.expect(t, preset_save_new(&a))
		preset_leave(&a)
	}
	testing.expect_value(t, pack_make(&a, made), "")
	testing.expect(t, strings.contains(a.result.text, "Made Bolt clay.sculptpack: 1 alpha and 3 presets; 1 preset used another pack's alpha"), a.result.text)

	b: App
	defer pack_app_free(&b)
	pack_app(&b, FOLDER + "b.txt")
	testing.expect_value(t, pack_install_finish(&b, pack_unpack(made, b.library.folder), replace = false), "")
	testing.expect_value(t, b.library.packs[0].name, "Bolt clay")
	testing.expect_value(t, b.library.packs[0].presets, 3)
	want := [3]string{"bolt-clay/Rock face", "Noise", "-"}
	for i in 0 ..< 3 {
		n := pack_preset_find(&b, "bolt-clay", preset_name(&a.presets[i]))
		p, ok := preset_at(&b, n)
		if !testing.expect(t, ok) do continue
		testing.expect_value(t, p.values.strength, a.presets[i].values.strength)
		testing.expect_value(t, alpha_ref(&b, p.values.alpha), want[i])
	}
	free_all(context.temp_allocator)
}

// A pack's matcaps and materials.txt join the Material section: its lines with a matcap
// of the pack's, a built-in's or none, a material of its own for a matcap no line names,
// and the lines it cannot use counted. A scene keeps them by name and opens without the
// pack as Custom ones with the lights; the settings keep the default and Custom's
// matcap; a replace moves objects to the new version's material of the same name and a
// removal leaves Custom ones.
@(test)
pack_materials_install_and_follow :: proc(t: ^testing.T) {
	FOLDER :: "build/pack_material_test/"
	_ = os.remove_all(FOLDER)
	defer os.remove_all(FOLDER)
	testing.expect(t, os.make_directory_all(FOLDER) == nil)
	settings := FOLDER + "run.txt"
	LIBRARY :: FOLDER + "run-library"
	v1, v2, big := FOLDER + "rocks.sculptpack", FOLDER + "rocks-2.sculptpack", FOLDER + "big.sculptpack"
	lines := "# Rock Set's materials\n" +
		"material Wet%20stone 0.3 0.3 0.32 0 0.4 wet\n" +
		"material Gold 1 0.8 0.3 1 0.3 -\n" +
		"material Brass 0.9 0.7 0.3 1 0.35 -\n" +
		"material Pearly 1 1 1 0 0.5 pearl\n" +
		"material Broken 2 0 0 0 0.5 -\n" +
		"material Lost 1 1 1 0 0.5 nothere\n" +
		"material wet%20STONE 1 1 1 0 0.5 -\n"
	pack_write(t, v1, {{"pack.txt", "name Rock Set\nauthor Bolt\n"}, {"matcaps/wet.png", pack_png(3)}, {"matcaps/Glow.png", pack_png(90)}, {"matcaps/jade soft studio highlight v2 long.png", pack_png(40)}, {"materials.txt", lines}})
	pack_write(t, v2, {{"pack.txt", "name Rock Set\nauthor Bolt\nversion 2\n"}, {"materials.txt", "material Wet%20stone 0.5 0.5 0.5 0 0.6 clay\n"}})
	pixels := make([]u8, 1100 * 4 * 4, context.temp_allocator)
	pack_write(t, big, {{"pack.txt", "name Big\n"}, {"matcaps/huge.png", string(png_write.encode(pixels, 1100, 4, false, context.temp_allocator))}})

	a: App
	defer pack_app_free(&a)
	pack_app(&a, settings)
	failed := pack_install_finish(&a, pack_unpack(big, a.library.folder), replace = false)
	testing.expect(t, strings.contains(failed, "matcaps/huge.png is not a MatCap the app reads: it is 1100 x 4"), failed)
	testing.expect_value(t, pack_install_finish(&a, pack_unpack(v1, a.library.folder), replace = false), "")
	testing.expect(t, strings.contains(a.result.text, "Installed Rock Set: 5 materials; skipped 4 lines of materials.txt"), a.result.text)
	testing.expect(t, os.exists(LIBRARY + "/rock-set/matcaps/Glow.png") && os.exists(LIBRARY + "/rock-set/materials.txt"))
	wet := pack_material_by_ref(&a, "rock-set/WET STONE")
	brass := pack_material_find(&a, "rock-set", "brass")
	glow := pack_material_find(&a, "rock-set", "Glow")
	pearly := pack_material_find(&a, "rock-set", "pearly")
	testing.expect(t, wet >= 0 && brass >= 0 && glow >= 0 && pearly >= 0)
	l := &a.library
	testing.expect_value(t, l.materials[wet].material.matcap, PACK_MATCAP + pack_matcap_find(&a, "rock-set", "wet"))
	testing.expect_value(t, l.materials[glow].material.matcap, PACK_MATCAP + pack_matcap_find(&a, "rock-set", "glow"))
	testing.expect_value(t, l.materials[pearly].material.matcap, 5)
	testing.expect_value(t, l.materials[brass].material.matcap, 0)
	testing.expect_value(t, l.materials[brass].material.roughness, 0.35)
	testing.expect(t, string(l.materials[wet].material.label) == "Wet stone" && l.materials[wet].material.pack == wet + 1)
	testing.expect_value(t, material_index(l.materials[brass].material), PACK_MATERIAL + brass)
	testing.expect_value(t, matcap_label(&a, l.materials[glow].material.matcap), "Glow")

	// In the scene file by name: back as the pack's own, or without it as Custom.
	custom := Material{label = "Custom", selected = {0.2, 0.3, 0.4, 1}, idle = MATCAP_IDLE, matcap = l.materials[wet].material.matcap}
	for m in ([?]Material{l.materials[wet].material, l.materials[brass].material, custom}) {
		out: [dynamic]u8
		defer delete(out)
		material_put(&out, m, material_refs(&a, m))
		r := geom.byte_reader(out[:])
		missing := 0
		back := material_get(&r, &a, SCENE_VERSION, &missing)
		testing.expect(t, r.ok && r.at == len(out) && missing == 0)
		testing.expect_value(t, back, m)
		r = geom.byte_reader(out[:])
		alone := material_get(&r, nil, SCENE_VERSION, &missing)
		testing.expect(t, r.ok && missing == 1 && alone.label == "Custom" && alone.pack == 0 && alone.matcap == 0)
		testing.expect_value(t, alone.selected, m.selected)
	}
	// A reference without both parts, or beside a matcap number, is a damaged file.
	for refs in ([?]Material_Refs{{material = "rock-set"}, {matcap = "/wet"}}) {
		out: [dynamic]u8
		defer delete(out)
		material_put(&out, MATERIALS[0], refs)
		r := geom.byte_reader(out[:])
		_ = material_get(&r, &a)
		testing.expect(t, !r.ok)
	}
	{
		out: [dynamic]u8
		defer delete(out)
		material_put(&out, MATERIALS[FIRST_MATCAP], {matcap = "rock-set/wet"})
		r := geom.byte_reader(out[:])
		_ = material_get(&r, &a)
		testing.expect(t, !r.ok)
		// Version 14 had no references: its last field is the matcap.
		clear(&out)
		material_put(&out, MATERIALS[3])
		resize(&out, len(out) - 8)
		r = geom.byte_reader(out[:])
		back := material_get(&r, &a, 14)
		testing.expect(t, r.ok && r.at == len(out) && back == MATERIALS[3])
	}

	// The settings keep the default and Custom's matcap by name.
	a.material = PACK_MATERIAL + brass
	a.custom = custom
	testing.expect(t, settings_save(&a, settings))
	b: App
	defer pack_app_free(&b)
	pack_app(&b, settings)
	b.custom = {label = "Custom"}
	settings_load(&b, settings)
	testing.expect_value(t, b.material, PACK_MATERIAL + pack_material_find(&b, "rock-set", "brass"))
	testing.expect_value(t, b.custom.matcap, PACK_MATCAP + pack_matcap_find(&b, "rock-set", "wet"))
	testing.expect_value(t, b.custom.idle, MATCAP_IDLE)
	// A matcap's own material with a long name is cut to one a line can hold, so it
	// comes back; Wet stone's space survives the settings too.
	testing.expect_value(t, len(b.library.materials), 5)
	testing.expect_value(t, b.library.packs[0].materials, 5)
	testing.expect_value(t, b.library.skipped, 0)
	testing.expect(t, pack_material_find(&b, "rock-set", "jade soft studio highlight v") >= 0)
	b.material = PACK_MATERIAL + pack_material_find(&b, "rock-set", "wet stone")
	testing.expect(t, settings_save(&b, settings))
	b.material = 0
	settings_load(&b, settings)
	testing.expect_value(t, b.material, PACK_MATERIAL + pack_material_find(&b, "rock-set", "wet stone"))

	// A script names one by `<id>/<name>`, looked up as the line runs.
	s := script_parse("set material rock-set/pearly\nset material clay", "test")
	defer script_destroy(&s)
	testing.expect_value(t, len(s.errors), 0)
	script_set(&b, s.statements[0])
	testing.expect_value(t, b.material, PACK_MATERIAL + pack_material_find(&b, "rock-set", "pearly"))
	testing.expect_value(t, s.statements[0].text, "rock-set/pearly")

	// A replace moves the objects on to the new Wet stone and leaves Brass's a Custom one.
	on_wet, on_brass := new(Object), new(Object)
	defer free(on_wet)
	defer free(on_brass)
	on_wet.material, on_brass.material = l.materials[wet].material, l.materials[brass].material
	append(&a.scene.objects, on_wet, on_brass)
	defer delete(a.scene.objects)
	a.material = PACK_MATERIAL + wet
	edits := a.scene_edits
	testing.expect_value(t, pack_install_finish(&a, pack_unpack(v2, a.library.folder), replace = true), "")
	testing.expect(t, strings.contains(a.result.text, "1 object used materials it no longer has and has Custom ones now"), a.result.text)
	new_wet := pack_material_find(&a, "rock-set", "wet stone")
	testing.expect(t, new_wet >= 0 && new_wet != wet)
	testing.expect_value(t, on_wet.material.pack, new_wet + 1)
	testing.expect_value(t, on_wet.material.matcap, 2)
	testing.expect_value(t, a.material, PACK_MATERIAL + new_wet)
	testing.expect(t, on_brass.material.label == "Custom" && on_brass.material.pack == 0 && on_brass.material.metallic == 1)
	testing.expect_value(t, a.custom.matcap, 0)
	testing.expect(t, a.scene_edits > edits)

	// Removing it leaves the default on Clay and the object on a Custom one.
	testing.expect(t, pack_remove(&a, 0))
	testing.expect_value(t, a.material, 0)
	testing.expect(t, on_wet.material.label == "Custom" && on_wet.material.pack == 0 && on_wet.material.matcap == 2)
	testing.expect(t, strings.contains(a.result.text, "1 object that used its materials has Custom ones now"), a.result.text)
	testing.expect_value(t, current_material(&a), MATERIALS[0])
	// No GPU in a test, so nothing was made.
	pack_matcaps_settle(&a)
	testing.expect_value(t, a.library.textures_made, 0)
	free_all(context.temp_allocator)
}
