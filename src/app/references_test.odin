package main

import "core:slice"
import "core:testing"

import "../camera"
import "../geom"
import "../png_write"
import "../render"
import "../ui"

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
	app.scene.refs.refs[0].view, app.scene.refs.refs[0].view_at, app.scene.refs.refs[0].view_w, app.scene.refs.refs[0].opacity = true, {0.5, -0.25}, 0.4, 0.75
	app.scene.refs.refs[1].plane, app.scene.refs.refs[1].plane_at, app.scene.refs.refs[1].plane_h = .Right, {0.5, 1, -2}, 1.75
	app.scene.refs.refs[1].through, app.scene.refs.refs[1].plane_off = true, true
	app.scene.refs.refs[1].marks = {0.2, 0.7}
	app.scene.refs.view_off = true
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
	testing.expect(t, back.view_off)
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
		proc(refs: ^References) {refs.refs[0].opacity = 0},
		proc(refs: ^References) {refs.refs[0].view_w = -1},
		proc(refs: ^References) {refs.refs[0].plane = .Top; refs.refs[0].plane_h = 0},
		proc(refs: ^References) {refs.refs[0].plane_at = {2e6, 0, 0}},
		proc(refs: ^References) {refs.refs[0].marks = {0.6, 0.5}},
		proc(refs: ^References) {refs.refs[0].marks = {0.5, 1.5}},
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
	defer delete(d.sample)
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

// The Eyedropper on a picture reads its small copy where the place shows it: flipped,
// the left of the place is the picture's right.
@(test)
references_pick_colour_where_shown :: proc(t: ^testing.T) {
	app: App
	defer test_refs_free(&app)
	_, _ = refs_add(&app, "a.png", test_png(2, 1, 0), {})
	img := app.scene.refs.images[0]
	img.sample = make([]u8, 8)
	copy(img.sample, []u8{255, 0, 0, 255, 0, 0, 255, 255})
	img.sample_size = {2, 1}
	p := app.scene.refs.refs[0]
	r := ui.Rect{0, 0, 100, 50}
	rgb, ok := refs_color_at(&app, p, r, {10, 25})
	testing.expect(t, ok && rgb == {1, 0, 0})
	p.flip = true
	rgb, ok = refs_color_at(&app, p, r, {10, 25})
	testing.expect(t, ok && rgb == {0, 0, 1})
}

// Each plane's right, up and facing are the screen's right and up and the way toward the
// eye in the axis view it is for, so its picture shows upright and unmirrored there.
@(test)
reference_planes_face_their_views :: proc(t: ^testing.T) {
	views := [Ref_Plane]camera.Axis_View{.None = .Front, .Front = .Front, .Back = .Back, .Right = .Right, .Left = .Left, .Top = .Top, .Bottom = .Bottom}
	for plane in Ref_Plane.Front ..= Ref_Plane.Bottom {
		c := camera.Orbit{distance = 5}
		camera.orbit_axis_view(&c, views[plane])
		v := camera.orbit_view(c)
		right, up, facing := refs_plane_axes(plane)
		for i in 0 ..< 3 {
			testing.expectf(t, abs(v[0, i] - right[i]) < 1e-5, "%v right %v", plane, right)
			testing.expectf(t, abs(v[1, i] - up[i]) < 1e-5, "%v up %v", plane, up)
			testing.expectf(t, abs(v[2, i] - facing[i]) < 1e-5, "%v facing %v", plane, facing)
		}
		testing.expect(t, render.ref_plane_shown({texture = 1, facing = facing, opacity = 1}, render.view_forward(v)), "shown in its own view")
		// Twenty degrees off its axis, it no longer shows, unless shown from any side.
		switch plane {
		case .Top:    c.pitch -= 0.35
		case .Bottom: c.pitch += 0.35
		case .None, .Front, .Back, .Right, .Left: c.yaw += 0.35
		}
		off := render.view_forward(camera.orbit_view(c))
		testing.expect(t, !render.ref_plane_shown({texture = 1, facing = facing, opacity = 1}, off), "hidden off its axis")
		testing.expect(t, render.ref_plane_shown({texture = 1, facing = facing, opacity = 1, always = true}, off), "shown from any side")
	}
}

// A picture put in the scene stands through the scene's middle, as tall as the box
// measured, its width from its place's shape; In scene again with another view turns
// it, Not in scene takes it out, each one undo step.
@(test)
reference_planes_stand_behind_the_scene :: proc(t: ^testing.T) {
	app: App
	defer test_refs_free(&app)
	_, _ = refs_add(&app, "a.png", test_png(4, 2, 1), {})
	_, _ = refs_add(&app, "b.png", test_png(4, 2, 2), {})
	refs := &app.scene.refs
	refs.refs[0].size, refs.refs[1].size = {200, 100}, {100, 100}
	b := &app.kit.board
	append(&b.selected, refs.refs[0].id, refs.refs[1].id)
	refs_plane_put(&app, .Front)
	p, q := refs.refs[0], refs.refs[1]
	testing.expect_value(t, p.plane, Ref_Plane.Front)
	testing.expect_value(t, p.plane_h, REF_PLANE_DEFAULT_H)
	testing.expect_value(t, refs_plane_size(p), [2]f32{2 * REF_PLANE_DEFAULT_H, REF_PLANE_DEFAULT_H})
	// Through the default box's middle, side by side across it.
	testing.expect(t, p.plane_at.z == 0 && q.plane_at.z == 0 && p.plane_at.y == 0)
	testing.expect_value(t, p.plane_at.x + refs_plane_size(p).x * 0.5, q.plane_at.x - refs_plane_size(q).x * 0.5)
	testing.expect_value(t, p.plane_at.x - refs_plane_size(p).x * 0.5, -(q.plane_at.x + refs_plane_size(q).x * 0.5))
	got, any := refs_picked_plane(&app)
	testing.expect(t, any && got == .Front)
	refs_edit(&app, .Through)
	testing.expect(t, refs.refs[0].through && refs.refs[1].through)
	refs_plane_put(&app, .Right)
	testing.expect(t, refs.refs[0].plane == .Right && refs.refs[0].plane_at.x == 0)
	refs_plane_put(&app, .None)
	testing.expect(t, refs.refs[0].plane == .None && refs.refs[1].plane == .None)
	testing.expect_value(t, len(app.history.done), 4)
}

// A progressive JPEG (16 x 8, red rising across and green down), as most pictures saved
// from the web are: Odin's own reader refuses its frame type, so stb_image reads it.
@(private = "file")
PROGRESSIVE_JPEG := [?]u8{
	0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01,
	0x00, 0x01, 0x00, 0x00, 0xff, 0xdb, 0x00, 0x43, 0x00, 0x03, 0x02, 0x02, 0x03, 0x02, 0x02, 0x03,
	0x03, 0x03, 0x03, 0x04, 0x03, 0x03, 0x04, 0x05, 0x08, 0x05, 0x05, 0x04, 0x04, 0x05, 0x0a, 0x07,
	0x07, 0x06, 0x08, 0x0c, 0x0a, 0x0c, 0x0c, 0x0b, 0x0a, 0x0b, 0x0b, 0x0d, 0x0e, 0x12, 0x10, 0x0d,
	0x0e, 0x11, 0x0e, 0x0b, 0x0b, 0x10, 0x16, 0x10, 0x11, 0x13, 0x14, 0x15, 0x15, 0x15, 0x0c, 0x0f,
	0x17, 0x18, 0x16, 0x14, 0x18, 0x12, 0x14, 0x15, 0x14, 0xff, 0xdb, 0x00, 0x43, 0x01, 0x03, 0x04,
	0x04, 0x05, 0x04, 0x05, 0x09, 0x05, 0x05, 0x09, 0x14, 0x0d, 0x0b, 0x0d, 0x14, 0x14, 0x14, 0x14,
	0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14,
	0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14,
	0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0xff, 0xc2,
	0x00, 0x11, 0x08, 0x00, 0x08, 0x00, 0x10, 0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11,
	0x01, 0xff, 0xc4, 0x00, 0x15, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x06, 0xff, 0xc4, 0x00, 0x15, 0x01, 0x01, 0x01, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x05, 0xff,
	0xda, 0x00, 0x0c, 0x03, 0x01, 0x00, 0x02, 0x10, 0x03, 0x10, 0x00, 0x00, 0x01, 0x96, 0xb3, 0x05,
	0x23, 0xff, 0xc4, 0x00, 0x16, 0x10, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x06, 0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00,
	0x01, 0x05, 0x02, 0x52, 0x54, 0x52, 0x54, 0xff, 0xc4, 0x00, 0x19, 0x11, 0x00, 0x01, 0x05, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x05, 0x06,
	0x21, 0x22, 0xff, 0xda, 0x00, 0x08, 0x01, 0x03, 0x01, 0x01, 0x3f, 0x01, 0x8d, 0xbc, 0x2c, 0xad,
	0x1f, 0xff, 0xc4, 0x00, 0x17, 0x11, 0x01, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x05, 0x52, 0xff, 0xda, 0x00, 0x08, 0x01, 0x02,
	0x01, 0x01, 0x3f, 0x01, 0x65, 0x9a, 0x75, 0x3f, 0xff, 0xc4, 0x00, 0x15, 0x10, 0x01, 0x01, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x32, 0xff,
	0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x06, 0x3f, 0x02, 0x84, 0x3f, 0xff, 0xc4, 0x00, 0x16, 0x10,
	0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x31, 0xc1, 0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x01, 0x3f, 0x21, 0x4c, 0x09, 0x83,
	0xff, 0xda, 0x00, 0x0c, 0x03, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x00, 0x00, 0x10, 0x0b, 0xff,
	0xc4, 0x00, 0x17, 0x11, 0x00, 0x03, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x31, 0x91, 0xf0, 0xff, 0xda, 0x00, 0x08, 0x01, 0x03, 0x01, 0x01,
	0x3f, 0x10, 0x9b, 0xcc, 0xff, 0xc4, 0x00, 0x15, 0x11, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21, 0xff, 0xda, 0x00, 0x08, 0x01,
	0x02, 0x01, 0x01, 0x3f, 0x10, 0xbc, 0xff, 0xc4, 0x00, 0x14, 0x10, 0x01, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0xff, 0xda, 0x00, 0x08,
	0x01, 0x01, 0x00, 0x01, 0x3f, 0x10, 0x18, 0xcf, 0xff, 0xd9,
}

@(test)
reference_reads_a_progressive_jpeg :: proc(t: ^testing.T) {
	rgba, w, h, failed := matcap_pixels(PROGRESSIVE_JPEG[:])
	defer delete(rgba)
	testing.expect_value(t, failed, "")
	testing.expect_value(t, w, 16)
	testing.expect_value(t, h, 8)
	if len(rgba) != 16 * 8 * 4 do return
	// The far corner keeps its colour within what JPEG's loss leaves of it.
	far := rgba[(7 * 16 + 15) * 4:][:4]
	testing.expect(t, abs(int(far[0]) - 240) < 24 && abs(int(far[1]) - 224) < 24 && abs(int(far[2]) - 128) < 24 && far[3] == 255, "the far corner's colour")
}

// Line up sizes and moves a side plane so its brow and chin marks stand at the guides'
// heights, keeping its middle across; it leaves a top plane, crossed guides and locked
// pictures alone, shows the guides when hidden, and is one undo step.
@(test)
reference_planes_line_up_with_the_guides :: proc(t: ^testing.T) {
	app: App
	defer test_refs_free(&app)
	_, _ = refs_add(&app, "a.png", test_png(4, 2, 1), {})
	refs := &app.scene.refs
	refs.refs[0].size = {100, 200}
	b := &app.kit.board
	append(&b.selected, refs.refs[0].id)
	refs_plane_put(&app, .Right)
	p := &refs.refs[0]
	p.plane_at = {0, 5, 0.25}
	app.scene.guides.heights = {.Brow = 1.5, .Nose_Base = 1, .Chin = 0.5}
	app.scene.guides.seeded = true
	refs_line_up_picked(&app)
	testing.expect(t, app.scene.guides.shown, "Line up shows the guides")
	m := ref_marks(p^)
	testing.expect_value(t, p.marks, REF_MARKS)
	top := p.plane_at.y + p.plane_h * 0.5
	testing.expect(t, abs(top - m.x * p.plane_h - 1.5) < 1e-5, "the brow mark at the Brow guide")
	testing.expect(t, abs(top - m.y * p.plane_h - 0.5) < 1e-5, "the chin mark at the Chin guide")
	testing.expect(t, p.plane_at.x == 0 && p.plane_at.z == 0.25, "its middle across kept")
	testing.expect_value(t, b.lined_up, 1)
	testing.expect_value(t, len(app.history.done), 2)
	// Again, nothing changes and no step is added.
	refs_line_up_picked(&app)
	testing.expect_value(t, len(app.history.done), 2)
	// Marks dragged elsewhere line up the same way.
	p.marks = {0.1, 0.5}
	testing.expect(t, refs_line_up(p, app.scene.guides))
	top = p.plane_at.y + p.plane_h * 0.5
	testing.expect(t, abs(top - 0.1 * p.plane_h - 1.5) < 1e-5 && abs(top - 0.5 * p.plane_h - 0.5) < 1e-5)
	// Crossed guides, a top plane and a locked picture are left as they are.
	crossed := app.scene.guides
	crossed.heights[.Chin] = 2
	testing.expect(t, !refs_line_up(p, crossed))
	p.plane = .Top
	testing.expect(t, !refs_line_up(p, app.scene.guides))
	p.plane, p.locked, p.plane_h = .Right, true, 3
	refs_line_up_picked(&app)
	testing.expect_value(t, p.plane_h, f32(3))
	testing.expect(t, refs_marks_ok({}) && refs_marks_ok(REF_MARKS) && !refs_marks_ok({0.5, 0.52}))
}

// The board's order as ids, bottom first.
@(private = "file")
test_refs_order :: proc(app: ^App) -> [4]u32 {
	out: [4]u32
	for r, i in app.scene.refs.refs do if i < 4 do out[i] = r.id
	return out
}

// Bringing places to the front moves them to the list's end, the pressed one last, and
// passes locked ones by; sending to the back moves them to its start, locked ones too,
// keeping their order among themselves; neither changes anything already there.
@(test)
references_order_front_and_back :: proc(t: ^testing.T) {
	app: App
	defer test_refs_free(&app)
	for _ in 0 ..< 4 do refs_add_note(&app)
	list := &app.scene.refs.refs
	testing.expect_value(t, test_refs_order(&app), [4]u32{1, 2, 3, 4})
	testing.expect(t, refs_bring_front(list, {2}, 2))
	testing.expect_value(t, test_refs_order(&app), [4]u32{1, 3, 4, 2})
	testing.expect(t, !refs_bring_front(list, {2}, 2))
	testing.expect(t, refs_bring_front(list, {1, 3}, 1))
	testing.expect_value(t, test_refs_order(&app), [4]u32{4, 2, 3, 1})
	list[0].locked = true
	testing.expect(t, !refs_bring_front(list, {4}, 4))
	testing.expect(t, refs_send_back(list, {3, 1}))
	testing.expect_value(t, test_refs_order(&app), [4]u32{3, 1, 4, 2})
	testing.expect(t, !refs_send_back(list, {3, 1}))
	testing.expect(t, refs_send_back(list, {4}))
	testing.expect_value(t, test_refs_order(&app), [4]u32{4, 3, 1, 2})
}

// Send to back is one undo step, and undo puts the order back; with nothing to move it
// lists no step.
@(test)
references_send_back_is_one_undo_step :: proc(t: ^testing.T) {
	app: App
	defer test_refs_free(&app)
	for _ in 0 ..< 3 do refs_add_note(&app)
	steps := len(app.history.done)
	b := &app.kit.board
	clear(&b.selected)
	append(&b.selected, 3)
	refs_send_back_selected(&app)
	testing.expect_value(t, test_refs_order(&app), [4]u32{3, 1, 2, 0})
	testing.expect_value(t, len(app.history.done), steps + 1)
	refs_send_back_selected(&app)
	testing.expect_value(t, len(app.history.done), steps + 1)
	history_undo(&app)
	testing.expect_value(t, test_refs_order(&app), [4]u32{1, 2, 3, 0})
}

// Add asks for files at once on a desktop or Android; with the iPad's photo picker it opens
// the choice of Photos and Files instead, and each choice asks for its own.
@(test)
references_add_asks_files_or_offers_photos :: proc(t: ^testing.T) {
	app: App
	defer test_refs_free(&app)
	app.no_dialogs = true
	b := &app.kit.board
	refs_add_ask(&app, {})
	testing.expect_value(t, b.asked_files, 1)
	testing.expect_value(t, app.dialogs_asked, 1)
	testing.expect(t, !b.add_menu)
	app.photos_picker = true
	refs_add_ask(&app, {10, 20, 40, 40})
	testing.expect(t, b.add_menu)
	testing.expect_value(t, b.asked_files, 1)
	refs_ask_photos(&app)
	testing.expect_value(t, b.asked_photos, 1)
	testing.expect_value(t, app.dialogs_asked, 1)
}
