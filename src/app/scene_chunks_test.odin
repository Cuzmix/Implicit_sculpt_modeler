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

// The scene's own fields read back from the header's chunk; bytes a newer app added at
// the chunk's end are left unread, and the same fields as version 35 wrote them, with no
// chunk, read the same.
@(test)
scene_fields_read_back_chunked_and_from_35 :: proc(t: ^testing.T) {
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
	// A field from a newer version, at the chunk's end.
	geom.byte_put(&head, u32(0xfeed))
	// The chunk's size takes it in, as the newer app's scene_chunk_end would have.
	r := geom.byte_reader(head[len(SCENE_MAGIC):])
	testing.expect_value(t, geom.byte_get(&r, u32), SCENE_VERSION)
	testing.expect(t, preview_block_skip(&r))
	size_at := r.at + 4
	size := transmute([8]u8)u64(len(head) - len(SCENE_MAGIC) - size_at - 8)
	copy(head[len(SCENE_MAGIC) + size_at:][:8], size[:])
	tag, chunk, ok := scene_chunk_next(&r)
	testing.expect(t, ok && tag == CHUNK_SCENE)
	f, fields_ok := scene_fields_get(&app, &chunk, SCENE_VERSION)
	defer scene_fields_destroy(&f)
	testing.expect(t, fields_ok)
	testing.expect_value(t, f.count, 3)
	testing.expect_value(t, f.selected, 2)
	testing.expect_value(t, f.next_id, 9)
	testing.expect_value(t, f.print_mm, 40)
	testing.expect(t, f.lights_own)
	testing.expect_value(t, len(chunk.data) - chunk.at, 4)

	// Version 35: the same fields straight after the preview block.
	r = geom.byte_reader(head[len(SCENE_MAGIC):])
	_ = geom.byte_get(&r, u32)
	_ = preview_block_skip(&r)
	r.at += 4 + 8
	old, old_ok := scene_fields_get(&app, &r, 35)
	defer scene_fields_destroy(&old)
	testing.expect(t, old_ok && old.count == 3 && old.selected == 2 && old.next_id == 9 && old.print_mm == 40)

	// A selection past the objects is damage.
	app.scene.selected = 5
	bad: [dynamic]u8
	defer delete(bad)
	scene_header_put(&app, &bad)
	rb := geom.byte_reader(bad[len(SCENE_MAGIC):])
	_ = geom.byte_get(&rb, u32)
	_ = preview_block_skip(&rb)
	_, bad_chunk, _ := scene_chunk_next(&rb)
	_, bad_ok := scene_fields_get(&app, &bad_chunk, SCENE_VERSION)
	testing.expect(t, !bad_ok)
}
