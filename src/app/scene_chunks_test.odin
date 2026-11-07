package main

import "core:testing"

import "../geom"

// Chunks read back as written, a tag the reader does not know is stepped over with the
// rest still read, and a size past the file's end is damage that stops the reading.
@(test)
scene_chunks_read_back_and_skip :: proc(t: ^testing.T) {
	out: [dynamic]u8
	defer delete(out)
	at := scene_chunk_begin(&out, CHUNK_SCENE)
	geom.byte_put(&out, u32(7))
	scene_chunk_end(&out, at)
	at = scene_chunk_begin(&out, "NEW!")
	geom.byte_put(&out, u64(99))
	geom.byte_put(&out, u64(98))
	scene_chunk_end(&out, at)
	at = scene_chunk_begin(&out, CHUNK_OBJECT)
	scene_chunk_end(&out, at)

	r := geom.byte_reader(out[:])
	tag, chunk, ok := scene_chunk_next(&r)
	testing.expect(t, ok && tag == CHUNK_SCENE && len(chunk.data) == 4)
	testing.expect_value(t, geom.byte_get(&chunk, u32), 7)
	tag, chunk, ok = scene_chunk_next(&r)
	testing.expect(t, ok && tag == "NEW!" && len(chunk.data) == 16)
	tag, chunk, ok = scene_chunk_next(&r)
	testing.expect(t, ok && tag == CHUNK_OBJECT && len(chunk.data) == 0)
	_, _, ok = scene_chunk_next(&r)
	testing.expect(t, !ok && r.ok, "the end of the file is no damage")

	// A size that runs past the end.
	cut := out[:len(out) - 1]
	r = geom.byte_reader(cut[:len(cut) - 12])
	_, _, ok = scene_chunk_next(&r)
	_, _, ok = scene_chunk_next(&r)
	testing.expect(t, !ok && !r.ok, "a chunk cut short is damage")
}


// The scene's own fields read back from the header's chunk; a field this build does not
// know is stepped over, and one it must understand refuses the scene.
@(test)
scene_fields_read_back_from_their_chunk :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	_ = tree_scene(&app)
	app.scene.selected = 2
	app.scene.next_id = 9
	app.scene.print_mm = 40
	app.camera.distance = 5
	app.scene.lights = app.start_lights
	head: [dynamic]u8
	defer delete(head)
	scene_header_put(&app, &head)
	rec := test_scene_record(head[:])
	// A field a later build added, after the ones this build writes.
	later: [dynamic]u8
	defer delete(later)
	append(&later, ..rec.data)
	geom.rec_put(&later, Later_Scene_Tag.Lens_Shift, [2]f32{0.1, 0})
	r := geom.byte_reader(later[:])
	f, fields_ok := scene_fields_get(&app, &r)
	defer scene_fields_destroy(&f)
	testing.expect(t, fields_ok)
	testing.expect_value(t, f.count, 3)
	testing.expect_value(t, f.selected, 2)
	testing.expect_value(t, f.next_id, 9)
	testing.expect_value(t, f.print_mm, 40)
	// One it must understand.
	critical: [dynamic]u8
	defer delete(critical)
	append(&critical, ..rec.data)
	geom.rec_put(&critical, Later_Scene_Tag.Units, f32(0.01))
	rc := geom.byte_reader(critical[:])
	_, critical_ok := scene_fields_get(&app, &rc)
	testing.expect(t, !critical_ok)

	// A selection past the objects is damage.
	app.scene.selected = 5
	bad: [dynamic]u8
	defer delete(bad)
	scene_header_put(&app, &bad)
	brec := test_scene_record(bad[:])
	rb := geom.byte_reader(brec.data)
	_, bad_ok := scene_fields_get(&app, &rb)
	testing.expect(t, !bad_ok)
}

// Tags a later build might add to the scene chunk: one to step over, one to refuse.
@(private = "file")
Later_Scene_Tag :: enum u16 {
	Lens_Shift = 900,
	Units      = geom.RECORD_TAG_CRITICAL | 900,
}
