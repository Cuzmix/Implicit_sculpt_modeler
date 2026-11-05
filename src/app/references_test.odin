package main

import "core:testing"

import "../geom"
import "../png_write"

// A small picture's file, as a PNG of `w` by `h` grey pixels of `shade`.
@(private = "file")
test_png :: proc(w, h: int, shade: u8) -> []u8 {
	pixels := make([]u8, w * h * 4, context.temp_allocator)
	for &p, i in pixels do p = 255 if i % 4 == 3 else shade
	return png_write.encode(pixels, w, h, alpha = true)
}

// How long the scene header's references chunk is, which follows the scene's own chunk,
// for the tests that find the scene's fields from the header's end.
test_refs_chunk_len :: proc(app: ^App) -> int {
	out: [dynamic]u8
	defer delete(out)
	refs_put(&out, &app.scene.refs)
	return len(out)
}

@(private = "file")
test_refs_free :: proc(app: ^App) {
	history_destroy(&app.history)
	refs_destroy(app)
	results_destroy(app)
}

// The pictures and their places read back as written, the pictures' bytes unchanged.
@(test)
references_read_back_as_written :: proc(t: ^testing.T) {
	app: App
	defer test_refs_free(&app)
	a, _ := refs_add(&app, "a.png", test_png(4, 2, 10), {1, 2})
	_, _ = refs_add(&app, "b.png", test_png(3, 3, 200), {-5, 7})
	app.scene.refs.refs[0].size = {40, 20}
	out: [dynamic]u8
	defer delete(out)
	refs_put(&out, &app.scene.refs)
	r := geom.byte_reader(out[:])
	tag, chunk, ok := scene_chunk_next(&r)
	testing.expect(t, ok && tag == CHUNK_REFS)
	back, back_ok := refs_get(&chunk)
	defer refs_free(&back)
	testing.expect(t, back_ok)
	testing.expect_value(t, len(back.images), 2)
	testing.expect_value(t, len(back.refs), 2)
	testing.expect_value(t, back.refs[0], app.scene.refs.refs[0])
	testing.expect_value(t, back.refs[1], app.scene.refs.refs[1])
	testing.expect_value(t, back.refs[0].id, a.id)
	testing.expect(t, string(back.images[1].bytes) == string(app.scene.refs.images[1].bytes))
	testing.expect_value(t, back.images[0].name, "a.png")
	testing.expect_value(t, back.next_image, 2)
}

// A chunk cut short, a place of a picture the chunk does not hold, or a size that is not
// a positive number is refused.
@(test)
references_refuse_damage :: proc(t: ^testing.T) {
	app: App
	defer test_refs_free(&app)
	_, _ = refs_add(&app, "a.png", test_png(2, 2, 10), {})
	cases := [?]proc(refs: ^References){
		proc(refs: ^References) {refs.refs[0].image = 9},
		proc(refs: ^References) {refs.refs[0].size = {0, 5}},
		proc(refs: ^References) {refs.refs[0].id = 50},
	}
	for spoil in cases {
		saved := app.scene.refs.refs[0]
		spoil(&app.scene.refs)
		out: [dynamic]u8
		refs_put(&out, &app.scene.refs)
		r := geom.byte_reader(out[8 + 4:])
		_, ok := refs_get(&r)
		testing.expect(t, !ok)
		delete(out)
		app.scene.refs.refs[0] = saved
	}
	out: [dynamic]u8
	defer delete(out)
	refs_put(&out, &app.scene.refs)
	r := geom.byte_reader(out[8 + 4:len(out) - 3])
	_, ok := refs_get(&r)
	testing.expect(t, !ok, "a chunk cut short is damage")
}

// The same file added twice is kept once and placed twice.
@(test)
references_keep_a_picture_once :: proc(t: ^testing.T) {
	app: App
	defer test_refs_free(&app)
	_, _ = refs_add(&app, "a.png", test_png(2, 2, 10), {})
	_, _ = refs_add(&app, "again.png", test_png(2, 2, 10), {50, 0})
	_, _ = refs_add(&app, "b.png", test_png(2, 2, 90), {})
	testing.expect_value(t, len(app.scene.refs.images), 2)
	testing.expect_value(t, len(app.scene.refs.refs), 3)
	testing.expect_value(t, app.scene.refs.refs[1].image, app.scene.refs.refs[0].image)
}

// Adding is an undo step: undo takes the place away and keeps the picture while the
// redo names it; once a new step drops the redo, the picture goes.
@(test)
references_undo_keeps_pictures_while_named :: proc(t: ^testing.T) {
	app: App
	defer test_refs_free(&app)
	testing.expect(t, refs_add_bytes(&app, "a.png", test_png(2, 2, 10)))
	testing.expect_value(t, len(app.scene.refs.refs), 1)
	testing.expect_value(t, len(app.kit.board.selected), 1)
	history_undo(&app)
	testing.expect_value(t, len(app.scene.refs.refs), 0)
	refs_poll(&app)
	testing.expect_value(t, len(app.scene.refs.images), 1)
	history_redo(&app)
	testing.expect_value(t, len(app.scene.refs.refs), 1)
	app.kit.board.selected[0] = app.scene.refs.refs[0].id
	refs_delete_selected(&app)
	testing.expect_value(t, len(app.scene.refs.refs), 0)
	history_undo(&app)
	testing.expect_value(t, len(app.scene.refs.refs), 1)
	history_undo(&app)
	// A new step drops both redo steps, and nothing names the picture any more.
	testing.expect(t, refs_add_bytes(&app, "b.png", test_png(2, 2, 90)))
	refs_poll(&app)
	testing.expect_value(t, len(app.scene.refs.images), 1)
	testing.expect_value(t, app.scene.refs.images[0].name, "b.png")
}

// A file that is not a picture is refused and leaves the board as it was.
@(test)
references_refuse_what_is_not_a_picture :: proc(t: ^testing.T) {
	app: App
	defer test_refs_free(&app)
	junk := make([]u8, 16)
	testing.expect(t, !refs_add_bytes(&app, "notes.txt", junk))
	testing.expect_value(t, len(app.scene.refs.refs), 0)
	testing.expect_value(t, len(app.history.done), 0)
	testing.expect(t, image_path_known("Face.JPG") && !image_path_known("face.obj"))
}

// Halving averages each 2 by 2 until the long side fits.
@(test)
references_shrink_by_halves :: proc(t: ^testing.T) {
	pixels := make([]u8, 8 * 4 * 4, context.temp_allocator)
	for &p, i in pixels do p = u8(i / 4 % 2 * 100)
	out, w, h := rgba_shrink(pixels, 8, 4, 3, context.temp_allocator)
	testing.expect_value(t, w, 2)
	testing.expect_value(t, h, 1)
	testing.expect_value(t, out[0], 50)
	same, sw, _ := rgba_shrink(pixels, 8, 4, 8, context.temp_allocator)
	testing.expect(t, sw == 8 && raw_data(same) == raw_data(pixels))
}

// A decode reads the picture's size and makes pixels no larger than the GPU copy's side.
@(test)
references_decode_on_its_own :: proc(t: ^testing.T) {
	bytes := test_png(10, 6, 77)
	defer delete(bytes)
	d := Ref_Decode{bytes = bytes, side = 4}
	ref_decode(&d)
	defer delete(d.pixels)
	testing.expect_value(t, d.why, "")
	testing.expect_value(t, d.width, 10)
	testing.expect_value(t, d.height, 6)
	testing.expect_value(t, d.shown, [2]int{2, 1})
	testing.expect_value(t, d.pixels[0], 77)
}

// A picture's size comes from its file's header, so its place has its shape at once.
@(test)
references_read_the_size_from_the_header :: proc(t: ^testing.T) {
	bytes := test_png(7, 3, 1)
	defer delete(bytes)
	w, h, ok := image_size_peek(bytes)
	testing.expect(t, ok && w == 7 && h == 3)
	// A JPEG's start, an APP0 segment, then its frame: 300 tall, 640 wide.
	jpeg := [?]u8{0xff, 0xd8, 0xff, 0xe0, 0, 4, 0, 0, 0xff, 0xc0, 0, 11, 8, 0x01, 0x2c, 0x02, 0x80, 3, 0, 0, 0}
	w, h, ok = image_size_peek(jpeg[:])
	testing.expect(t, ok && w == 640 && h == 300)
	app: App
	defer test_refs_free(&app)
	ref, _ := refs_add(&app, "a.png", test_png(8, 4, 1), {})
	testing.expect(t, ref.sized && ref.size == {2 * REF_ADD_HEIGHT, REF_ADD_HEIGHT})
}
