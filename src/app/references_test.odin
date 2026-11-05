package main

import "core:slice"
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
	app.scene.refs.refs[1].turn, app.scene.refs.refs[1].flip, app.scene.refs.refs[1].locked = 3, true, true
	app.scene.refs.refs[1].crop_lo, app.scene.refs.refs[1].crop_hi = {0.25, 0}, {1, 0.5}
	refs_add_note(&app)
	app.scene.refs.refs[2].text = {}
	copy(app.scene.refs.refs[2].text[:], "Brow softer")
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
	testing.expect_value(t, len(back.refs), 3)
	testing.expect_value(t, back.refs[0], app.scene.refs.refs[0])
	testing.expect_value(t, back.refs[1], app.scene.refs.refs[1])
	testing.expect_value(t, back.refs[2], app.scene.refs.refs[2])
	testing.expect_value(t, ref_note_text(&back.refs[2]), "Brow softer")
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
		proc(refs: ^References) {refs.refs[0].turn = 4},
		proc(refs: ^References) {refs.refs[0].crop_lo = {0.5, 0}; refs.refs[0].crop_hi = {0.4, 1}},
		proc(refs: ^References) {refs.refs[0].crop_hi = {1.5, 1}},
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

// A turn shows the bottom left at the top left; a flip mirrors; going to the shown frame and
// back is the identity for every flip and turn.
@(test)
references_turn_and_flip_their_corners :: proc(t: ^testing.T) {
	r := Ref{crop_hi = 1}
	testing.expect_value(t, ref_corners(r)[0], [2]f32{0, 0})
	r.turn = 1
	testing.expect_value(t, ref_corners(r)[0], [2]f32{0, 1})
	r.turn, r.flip = 0, true
	testing.expect_value(t, ref_corners(r)[0], [2]f32{1, 0})
	p := [2]f32{0.25, 0.125}
	for turn in u8(0) ..< 4 {
		for flip in ([?]bool{false, true}) {
			r = {crop_hi = 1, turn = turn, flip = flip}
			testing.expect_value(t, ref_from_shown(r, ref_to_shown(r, p)), p)
			// The corner shown at the top left is where the shown frame's origin comes from.
			testing.expect_value(t, ref_corners(r)[0], ref_from_shown(r, {0, 0}))
			testing.expect_value(t, ref_corners(r)[2], ref_from_shown(r, {1, 1}))
		}
	}
}

// Arrange packs the places in rows without overlap, tallest first, as one undo step that
// puts them back; a locked place stays where it is.
@(test)
references_arrange_packs_without_overlap :: proc(t: ^testing.T) {
	app: App
	defer test_refs_free(&app)
	for k in 0 ..< 5 do _, _ = refs_add(&app, "p.png", test_png(2 + k, 2, u8(k)), {f32(k) * 7, f32(k) * 3})
	app.scene.refs.refs[4].locked = true
	app.scene.refs.refs[4].at = {900, 900}
	app.kit.board.room = {0, 0, 400, 300}
	before := refs_clone(app.scene.refs.refs[:], context.temp_allocator)
	refs_arrange(&app)
	list := app.scene.refs.refs[:]
	testing.expect_value(t, list[4].at, [2]f32{900, 900})
	for a in 0 ..< 4 {
		for b in a + 1 ..< 4 {
			ra, rb := list[a], list[b]
			apart := ra.at.x + ra.size.x <= rb.at.x || rb.at.x + rb.size.x <= ra.at.x || ra.at.y + ra.size.y <= rb.at.y || rb.at.y + rb.size.y <= ra.at.y
			testing.expectf(t, apart, "places %d and %d overlap", a, b)
		}
	}
	testing.expect_value(t, len(app.history.done), 1)
	history_undo(&app)
	testing.expect(t, slice.equal(before, app.scene.refs.refs[:]))
}

// Same height sets the pictures to the middle height of all, each keeping its shape.
@(test)
references_same_height_keeps_shapes :: proc(t: ^testing.T) {
	app: App
	defer test_refs_free(&app)
	for k in 0 ..< 3 do _, _ = refs_add(&app, "p.png", test_png(4, 2, u8(k)), {})
	heights := [3]f32{100, 300, 200}
	for &r, i in app.scene.refs.refs do r.size = {heights[i] * 2, heights[i]}
	refs_same_height(&app)
	for r in app.scene.refs.refs do testing.expect_value(t, r.size, [2]f32{400, 200})
}

// Flip, Grey and Lock set every picked picture as the first is not; Turn turns about the
// middle and swaps the sides, but not a locked one.
@(test)
references_edit_the_picked :: proc(t: ^testing.T) {
	app: App
	defer test_refs_free(&app)
	_, _ = refs_add(&app, "a.png", test_png(4, 2, 1), {})
	_, _ = refs_add(&app, "b.png", test_png(4, 2, 2), {})
	b := &app.kit.board
	append(&b.selected, app.scene.refs.refs[0].id, app.scene.refs.refs[1].id)
	app.scene.refs.refs[1].flip = true
	refs_edit(&app, .Flip)
	testing.expect(t, app.scene.refs.refs[0].flip && app.scene.refs.refs[1].flip)
	r := app.scene.refs.refs[0]
	app.scene.refs.refs[1].locked = true
	refs_edit(&app, .Turn)
	turned := app.scene.refs.refs[0]
	testing.expect_value(t, turned.turn, 1)
	testing.expect_value(t, turned.size, r.size.yx)
	testing.expect_value(t, turned.at + turned.size * 0.5, r.at + r.size * 0.5)
	testing.expect_value(t, app.scene.refs.refs[1].turn, 0)
	testing.expect_value(t, len(app.history.done), 2)
}

// Dragging a crop's left edge in keeps the rest of the picture where it was on the board
// and shows less of it; turned, the edge shown at the left cuts the picture's own bottom.
@(test)
references_crop_keeps_the_rest_in_place :: proc(t: ^testing.T) {
	r := Ref{at = {10, 20}, size = {200, 100}, crop_hi = 1}
	board_crop_test_drag(&r, {60, 50}, CROP_LEFT)
	testing.expect_value(t, r.at, [2]f32{60, 20})
	testing.expect_value(t, r.size, [2]f32{150, 100})
	testing.expect_value(t, r.crop_lo, [2]f32{0.25, 0})
	turned := Ref{at = {0, 0}, size = {100, 200}, crop_hi = 1, turn = 1}
	board_crop_test_drag(&turned, {50, 0}, CROP_LEFT)
	testing.expect_value(t, turned.crop_lo, [2]f32{0, 0})
	testing.expect_value(t, turned.crop_hi, [2]f32{1, 0.5})
}
