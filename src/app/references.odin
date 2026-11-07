package main

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:image"
import "core:math"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "../geom"
import "../png_write"
import "../render"

// Reference images (the References card, kit_references.odin): photos and drawings kept
// with the scene, as PureRef keeps a board of them. Each picture is stored once as the
// file's own bytes (a JPEG stays a JPEG), so a scene sent to the tablet carries it
// unchanged; the board places it any number of times. Decoding runs on a thread and the
// GPU copy is made at the start of a frame, so adding or opening a picture never stalls a
// stroke, and the board is drawn by the interface after the viewport, so the sculpt passes
// and the idle cache never see it.

// One picture: its name, its file's bytes as added (owned), its size in pixels once
// decoded, and its GPU copy, at most REF_GPU_SIDE on its long side, with mips.
Ref_Image :: struct {
	id:      u32,
	name:    string,
	bytes:   []u8,
	width:   int,
	height:  int,
	texture: render.Texture,
	shown:   [2]int, // the GPU copy's size in pixels
	// Its grey copy, made only once a place shows it grey (Ref.grey), so the colour copy
	// alone costs memory until then; grey_failed keeps a refused one from being tried again.
	grey:        render.Texture,
	grey_shown:  [2]int,
	grey_failed: bool,
	// A small copy on the CPU, REF_SAMPLE_SIDE on its long side at most, for the
	// Eyedropper's picks on the board and over the view.
	sample:      []u8,
	sample_size: [2]int,
	// When the interface last drew it (its context's time), and whether its GPU copy is
	// only the small one the memory limit leaves (refs_memory).
	seen:        f64,
	small:       bool,
	decode:  ^Ref_Decode,
	failed:  string, // why it cannot be shown, owned; "" while it can
	used:    bool, // refs_collect's mark
}

// A place of a picture on the board: its top left and size in board points (a point at
// zoom 1), drawn in the list's order, the last on top (a picked one is moved there). `sized` is false until the
// picture's own shape is known, when the place takes it at the same height. What it shows
// is the picture's part between crop_lo and crop_hi (its texture coordinates, 0 to 1),
// mirrored left to right when flipped, then turned a quarter clockwise `turn` times, in
// grey when `grey`; none of it changes the picture's file. A locked place stays where it
// is: it is picked but neither moved, sized, cropped nor turned. A place of image 0 is a
// note, its text NUL-ended in `text`, drawn in its box at a size its height sets. A
// picture's place can also stand over the view (`view`): its top left at `view_at` and
// its width `view_w`, as parts of the main view's width (its height from its shape), at
// `opacity`, turned `view_angle` radians clockwise about its middle, and kept there by
// `view_locked` (two fingers then turn the view, not the picture), and drawn behind the
// model rather than over it when `view_behind`, a backdrop the model covers. On the board it is
// turned `angle` radians clockwise about its middle (a note never is), shown upright
// while it is cropped. And it can stand on a plane in the scene (`plane`, refs_planes.odin), facing
// that axis view: its middle at `plane_at` in the world, `plane_h` tall (its width from
// its shape), drawn over the model when `through`, shown from any side when `plane_any`
// and hidden while `plane_off`; it shares the opacity with the view's. Its `marks` are
// where the face's brow and chin are on the picture, as parts of its height from its top
// (refs_planes.odin's Line up), {0, 0} until first put on a plane.
Ref :: struct {
	id:      u32,
	image:   u32,
	at:      [2]f32,
	size:    [2]f32,
	crop_lo: [2]f32,
	crop_hi: [2]f32,
	turn:    u8,
	angle:   f32,
	flip:    bool,
	grey:    bool,
	locked:  bool,
	sized:   bool,
	view:    bool,
	view_at: [2]f32,
	view_w:  f32,
	opacity: f32,
	view_angle:  f32,
	view_locked: bool,
	view_behind: bool,
	plane:     Ref_Plane,
	plane_at:  [3]f32,
	plane_h:   f32,
	through:   bool,
	plane_any: bool,
	plane_off: bool,
	marks:     [2]f32,
	text:    [REF_NOTE_MAX]u8,
}

// How a picture first stands over the view: under a third of its width, by its top left (the
// cards open on the pen side, at the right), at
// half its strength, so the model still shows through it.
REF_VIEW_W :: 0.3
REF_VIEW_AT :: [2]f32{0.08, 0.16}
REF_OPACITY :: 0.5
// The least opacity a place over the view takes: below it, it is better hidden.
REF_OPACITY_MIN :: 0.05
// The longest side of a picture's copy kept for the Eyedropper.
REF_SAMPLE_SIDE :: 512
// The memory limit's choices for the GPU copies, in MB; 0 is Automatic: a fourth of a
// desktop's on a tablet, which shares its memory with the sculpt.
REFS_MEMORY := [?]i32{0, 128, 256, 512, 1024, 2048}
REFS_MEMORY_NAMES := [?]string{"Automatic", "128 MB", "256 MB", "512 MB", "1 GB", "2 GB"}
#assert(len(REFS_MEMORY) == len(REFS_MEMORY_NAMES))
REFS_MEMORY_AUTOMATIC_MB :: 256 when MOBILE else 1024
// The long side of the copy a picture keeps past the limit, and how long a picture unseen
// is before it is made small.
REF_SMALL_SIDE :: 256
REF_UNSEEN_SECONDS :: 2

// The longest note, in bytes with its ending NUL: a label, not a document.
REF_NOTE_MAX :: 96
// A note's box when added, in board points: one line of text at a readable size.
REF_NOTE_SIZE :: [2]f32{220, 40}

// The scene's references: its pictures and their places on the board.
References :: struct {
	images:     [dynamic]^Ref_Image,
	refs:       [dynamic]Ref,
	next_image: u32,
	next_ref:   u32,
	view_off:   bool, // the places over the view are hidden (Show refs)
}

// The longest side of a picture's GPU copy: a tablet keeps a fourth of the texels a
// desktop does, which still fills its screen.
REF_GPU_SIDE :: 2048 when MOBILE else 4096
// A file over this many pixels on its long side is kept shrunk to REF_SHRUNK_SIDE as a
// PNG instead: nothing shows that many, and a scene file should not carry it.
REF_KEEP_SIDE :: 8192
REF_SHRUNK_SIDE :: 4096
// The most pictures a scene holds: each is an image of the interface's own
// (KIT_REF_IMAGE), and a board of more than this is no longer a board.
REF_IMAGES_MAX :: 256
// The most decodes at once: a scene opened with many pictures decodes them a few at a
// time, so the frame loop's own threads keep their cores.
REF_DECODES_MAX :: 2
// How tall a picture first sits on the board, in board points.
REF_ADD_HEIGHT :: 240

// A decode on its thread: it reads its picture's bytes (which stay put until it is
// joined) and leaves the pixels for the GPU copy, the picture's size, a shrunk file when
// the picture is too big to keep, and why it failed, all in the heap allocator.
Ref_Decode :: struct {
	bytes:     []u8,
	side:      int,
	pixels:    []u8,
	width:     int,
	height:    int,
	shown:     [2]int,
	kept:      []u8,
	sample:    []u8,
	sample_size: [2]int,
	why:       string,
	ms:        f64,
	grey:      bool, // the grey copy, in place of the colour one
	done:      bool, // atomic
	thread:    ^thread.Thread,
}

// The image of the interface that draws picture `slot` (its place in References.images).
KIT_REF_IMAGE :: KIT_TAB_IMAGE_END
KIT_REF_IMAGE_END :: KIT_REF_IMAGE + 2 * REF_IMAGES_MAX // the grey copies after the colour ones

// The picture of id `id`, or nil.
ref_image :: proc(refs: ^References, id: u32) -> ^Ref_Image {
	for img in refs.images do if img.id == id do return img
	return nil
}

// Picture `id`'s place in the list, or -1.
ref_image_slot :: proc(refs: ^References, id: u32) -> int {
	for img, i in refs.images do if img.id == id do return i
	return -1
}

// The place of id `id` on the board, or -1.
ref_index :: proc(refs: ^References, id: u32) -> int {
	for r, i in refs.refs do if r.id == id do return i
	return -1
}

// Adds a picture of file `name` holding `bytes` (taken over), and a place for it at `at`
// on the board, which is returned. A picture of the same bytes already kept is placed
// again rather than kept twice. False with the reason when the scene is full.
refs_add :: proc(app: ^App, name: string, bytes: []u8, at: [2]f32) -> (ref: Ref, why: string) {
	refs := &app.scene.refs
	img: ^Ref_Image
	img, why = ref_image_keep(refs, name, bytes)
	if img == nil do return
	refs.next_ref += 1
	ref = {id = refs.next_ref, image = img.id, at = at, size = REF_ADD_HEIGHT, crop_hi = 1, view_at = REF_VIEW_AT, view_w = REF_VIEW_W, opacity = REF_OPACITY}
	if img.width > 0 do ref = ref_sized(ref, img)
	append(&refs.refs, ref)
	return ref, ""
}

// The picture of file `name` holding `bytes` (taken over): one already kept of the same
// bytes, or a new one. Nil with the reason when the scene is full.
ref_image_keep :: proc(refs: ^References, name: string, bytes: []u8) -> (img: ^Ref_Image, why: string) {
	sum := hash.crc32(bytes)
	for other in refs.images {
		if len(other.bytes) == len(bytes) && hash.crc32(other.bytes) == sum && string(other.bytes) == string(bytes) {
			delete(bytes)
			return other, ""
		}
	}
	if len(refs.images) >= REF_IMAGES_MAX {
		delete(bytes)
		return nil, fmt.tprintf("the scene already holds %d pictures", REF_IMAGES_MAX)
	}
	refs.next_image += 1
	img = new(Ref_Image)
	img^ = {id = refs.next_image, name = strings.clone(name), bytes = bytes}
	append(&refs.images, img)
	// Its shape from the file's header, so it takes its place at once, not when decoded.
	if w, h, ok := image_size_peek(img.bytes); ok do img.width, img.height = w, h
	return img, ""
}

// Place `r` given the shape of its picture (as cropped and turned) at its height.
ref_sized :: proc(r: Ref, img: ^Ref_Image) -> Ref {
	r := r
	if img.width > 0 && img.height > 0 {
		part := (r.crop_hi - r.crop_lo) * [2]f32{f32(img.width), f32(img.height)}
		if r.turn % 2 == 1 do part = part.yx
		r.size.x = r.size.y * part.x / max(part.y, 1e-6)
		r.sized = true
	}
	return r
}

// The picture's texture coordinates shown at place `r`'s top left, top right, bottom
// right and bottom left: its crop, mirrored, then turned clockwise. Turned once, the top
// left shows what was the bottom left.
ref_corners :: proc(r: Ref) -> [4][2]f32 {
	lo, hi := r.crop_lo, r.crop_hi
	c := [4][2]f32{{lo.x, lo.y}, {hi.x, lo.y}, {hi.x, hi.y}, {lo.x, hi.y}}
	if r.flip do c = {c[1], c[0], c[3], c[2]}
	out: [4][2]f32
	for i in 0 ..< 4 do out[i] = c[(i + 4 - int(r.turn % 4)) % 4]
	return out
}

// Where the picture's texture coordinate `p` shows across a place of the whole picture of
// `r`'s flip and turn, 0 to 1 from its top left; ref_from_shown goes back.
ref_to_shown :: proc(r: Ref, p: [2]f32) -> [2]f32 {
	q := p
	if r.flip do q.x = 1 - q.x
	for _ in 0 ..< r.turn % 4 do q = {1 - q.y, q.x}
	return q
}

ref_from_shown :: proc(r: Ref, q: [2]f32) -> [2]f32 {
	p := q
	for _ in 0 ..< r.turn % 4 do p = {p.y, 1 - p.x}
	if r.flip do p.x = 1 - p.x
	return p
}

// Place `r`'s crop as shown (after its flip and turn), as its least and greatest corner.
ref_crop_shown :: proc(r: Ref) -> (lo, hi: [2]f32) {
	a, b := ref_to_shown(r, r.crop_lo), ref_to_shown(r, r.crop_hi)
	return {min(a.x, b.x), min(a.y, b.y)}, {max(a.x, b.x), max(a.y, b.y)}
}

// Sets place `r`'s crop from its shown corners `lo` and `hi`.
ref_crop_set :: proc(r: ^Ref, lo, hi: [2]f32) {
	a, b := ref_from_shown(r^, lo), ref_from_shown(r^, hi)
	r.crop_lo, r.crop_hi = {min(a.x, b.x), min(a.y, b.y)}, {max(a.x, b.x), max(a.y, b.y)}
}

// Where the whole picture of place `r` would lie, at the scale its crop shows it: the
// frame its crop's edges move in.
ref_full :: proc(r: Ref) -> (at, size: [2]f32) {
	lo, hi := ref_crop_shown(r)
	size = r.size / [2]f32{max(hi.x - lo.x, 1e-6), max(hi.y - lo.y, 1e-6)}
	return r.at - lo * size, size
}

// A note's text, up to its NUL.
ref_note_text :: proc(r: ^Ref) -> string {
	return string(cstring(raw_data(r.text[:])))
}

// Reads an image file and adds it to the board, at the middle of what the board shows,
// as one undo step. The outcome becomes the file note.
refs_add_file :: proc(app: ^App, path: string) -> bool {
	name := filepath.base(path)
	if strings.equal_fold(filepath.ext(path), ".sculpt") do return refs_copy_board(app, path)
	data, err := file_read_any(path, context.allocator)
	if err != nil {
		file_note(app, true, "Cannot add %s to References: %v", name, err)
		return false
	}
	return refs_add_bytes(app, name, data)
}

// Adds `data` (taken over), an image file's bytes, to the board as one undo step and
// selects it; `name` names it.
refs_add_bytes :: proc(app: ^App, name: string, data: []u8) -> bool {
	if !image_bytes_known(data) {
		delete(data)
		file_note(app, true, "Cannot add %s to References: it is not a PNG, JPEG, BMP, TGA or QOI image", name)
		return false
	}
	before := refs_clone(app.scene.refs.refs[:])
	ref, why := refs_add(app, name, data, board_drop_point(app))
	if why != "" {
		delete(before)
		file_note(app, true, "Cannot add %s to References: %s", name, why)
		return false
	}
	history_record_refs(app, before, "Add reference")
	b := &app.kit.board
	clear(&b.selected)
	append(&b.selected, ref.id)
	// A picture dropped or pasted from elsewhere shows where it went.
	if !card_shown(app, .References) do card_open(app, .References)
	board_show(app, ref.id)
	file_note(app, false, "Added %s to References", name)
	return true
}

// Copies the References board of scene file `path` onto this one, to the right of what is
// there, picked, as one undo step: its pictures (one already here is not kept twice), its
// places and notes as they stand there.
refs_copy_board :: proc(app: ^App, path: string) -> bool {
	name := filepath.base(path)
	src, why := refs_scene_read(path)
	defer refs_free(&src)
	if why == "" && len(src.refs) == 0 do why = "its References board is empty"
	if why != "" {
		file_note(app, true, "Cannot copy the references of %s: %s", name, why)
		return false
	}
	refs := &app.scene.refs
	before := refs_clone(refs.refs[:])
	ids := make(map[u32]u32, context.temp_allocator)
	for img in src.images {
		kept, full := ref_image_keep(refs, img.name, img.bytes)
		img.bytes = nil
		if kept == nil {
			refs_set(app, before)
			delete(before)
			file_note(app, true, "Cannot copy the references of %s: %s", name, full)
			refs_collect(app)
			return false
		}
		ids[img.id] = kept.id
	}
	lo := src.refs[0].at
	for r in src.refs do lo = {min(lo.x, r.at.x), min(lo.y, r.at.y)}
	shift := board_drop_point(app) - lo if len(refs.refs) > 0 else -lo
	b := &app.kit.board
	clear(&b.selected)
	for r in src.refs {
		r := r
		refs.next_ref += 1
		r.id = refs.next_ref
		if r.image != 0 do r.image = ids[r.image]
		r.at += shift
		append(&refs.refs, r)
		append(&b.selected, r.id)
	}
	history_record_refs(app, before, "Copy board")
	board_fit(app, b.room)
	file_note(app, false, "Copied %d references of %s", len(src.refs), name)
	return true
}

// The References of scene file `path` alone, read without its objects; why it cannot be
// read when it cannot.
refs_scene_read :: proc(path: string) -> (refs: References, why: string) {
	data, err := file_read_any(path, context.allocator)
	if err != nil do return {}, fmt.tprint(err)
	defer delete(data)
	r := geom.byte_reader(data)
	if !scene_head_read(&r) do return {}, "it is not a scene this version of the app reads"
	if !preview_block_skip(&r) do return {}, "it is damaged"
	for {
		tag, chunk, more := scene_chunk_next(&r)
		if !more do return {}, "it is damaged"
		if tag != CHUNK_REFS do continue
		ok: bool
		refs, ok = refs_get(&chunk)
		if !ok do return {}, "its reference pictures are damaged"
		return refs, ""
	}
}

// Whether `data` starts as an image file the decoder reads.
image_bytes_known :: proc(data: []u8) -> bool {
	#partial switch image.which_bytes(data) {
	case .PNG, .JPEG, .BMP, .TGA, .QOI:
		return true
	}
	return false
}

// Whether `path` names an image file the decoder reads, by its extension.
image_path_known :: proc(path: string) -> bool {
	ext := filepath.ext(path)
	for known in ([?]string{".png", ".jpg", ".jpeg", ".bmp", ".tga", ".qoi"}) do if strings.equal_fold(ext, known) do return true
	return false
}

// A picture's size in pixels from its file's header alone (PNG, JPEG, BMP, TGA, QOI),
// without decoding it; ok is false when the header does not say.
image_size_peek :: proc(b: []u8) -> (w, h: int, ok: bool) {
	be32 :: proc(b: []u8, at: int) -> int {return int(b[at]) << 24 | int(b[at + 1]) << 16 | int(b[at + 2]) << 8 | int(b[at + 3])}
	le16 :: proc(b: []u8, at: int) -> int {return int(b[at]) | int(b[at + 1]) << 8}
	#partial switch image.which_bytes(b) {
	case .PNG:
		if len(b) < 24 do return
		w, h = be32(b, 16), be32(b, 20)
	case .QOI:
		if len(b) < 12 do return
		w, h = be32(b, 4), be32(b, 8)
	case .BMP:
		if len(b) < 26 do return
		w, h = le16(b, 18) | le16(b, 20) << 16, le16(b, 22) | le16(b, 24) << 16
		// A negative height (as 32 bits) is a picture stored top row first.
		h = abs(int(i32(u32(h))))
	case .TGA:
		if len(b) < 16 do return
		w, h = le16(b, 12), le16(b, 14)
	case .JPEG:
		// The size is in the first start-of-frame segment, after the others.
		at := 2
		for at + 9 < len(b) {
			if b[at] != 0xff do return
			marker := b[at + 1]
			if marker == 0xff {
				at += 1
				continue
			}
			length := int(b[at + 2]) << 8 | int(b[at + 3])
			if marker >= 0xc0 && marker <= 0xcf && marker != 0xc4 && marker != 0xc8 && marker != 0xcc {
				h, w = int(b[at + 5]) << 8 | int(b[at + 6]), int(b[at + 7]) << 8 | int(b[at + 8])
				break
			}
			at += 2 + length
		}
	}
	ok = w > 0 && h > 0
	return
}

// Moves the places of `ids` to the top of `list` (its end, drawn last), keeping their order
// among themselves with `top` last of all, as picking a picture in PureRef brings it
// forward; locked places stay where they are in the order, so a backdrop locked behind the
// rest is never raised over them by a tap that only pans. True when the order changed.
refs_bring_front :: proc(list: ^[dynamic]Ref, ids: []u32, top: u32) -> bool {
	raised :: proc(r: Ref, ids: []u32) -> bool {
		if r.locked do return false
		for id in ids do if id == r.id do return true
		return false
	}
	out := make([dynamic]Ref, 0, len(list), context.temp_allocator)
	for r in list do if !raised(r, ids) do append(&out, r)
	for r in list do if raised(r, ids) && r.id != top do append(&out, r)
	for r in list do if raised(r, ids) && r.id == top do append(&out, r)
	return refs_order_take(list, out[:])
}

// Moves the places of `ids` to the bottom of `list` (its start, drawn first), keeping
// their order among themselves; locked ones too, since it is asked for by name. True when
// the order changed.
refs_send_back :: proc(list: ^[dynamic]Ref, ids: []u32) -> bool {
	picked :: proc(r: Ref, ids: []u32) -> bool {
		for id in ids do if id == r.id do return true
		return false
	}
	out := make([dynamic]Ref, 0, len(list), context.temp_allocator)
	for r in list do if picked(r, ids) do append(&out, r)
	for r in list do if !picked(r, ids) do append(&out, r)
	return refs_order_take(list, out[:])
}

// Puts `order` (the same places as `list`) in its place; true when it differs.
@(private = "file")
refs_order_take :: proc(list: ^[dynamic]Ref, order: []Ref) -> bool {
	same := true
	for r, i in order do if r.id != list[i].id do same = false
	if same do return false
	copy(list[:], order)
	return true
}

// Sends the picked places to the bottom of the board and the view, as one undo step.
refs_send_back_selected :: proc(app: ^App) {
	b := &app.kit.board
	before := refs_clone(app.scene.refs.refs[:])
	if !refs_send_back(&app.scene.refs.refs, b.selected[:]) {
		delete(before)
		return
	}
	history_record_refs(app, before, "Send reference to back" if len(b.selected) == 1 else "Send references to back")
}

// A copy of places `list`, owned by the caller.
refs_clone :: proc(list: []Ref, allocator := context.allocator) -> []Ref {
	out := make([]Ref, len(list), allocator)
	copy(out, list)
	return out
}

// Puts places `list` on the board in place of those there.
refs_set :: proc(app: ^App, list: []Ref) {
	clear(&app.scene.refs.refs)
	append(&app.scene.refs.refs, ..list)
	app.scene_edits += 1
}

// Frees picture `img` and its GPU copy, waiting for a decode still running.
@(private = "file")
ref_image_free :: proc(app: ^App, img: ^Ref_Image) {
	if d := img.decode; d != nil {
		thread.join(d.thread)
		thread.destroy(d.thread)
		ref_decode_free(d)
	}
	render.matcap_destroy(&app.renderer, &img.texture)
	render.matcap_destroy(&app.renderer, &img.grey)
	delete(img.sample)
	delete(img.name)
	delete(img.bytes)
	delete(img.failed)
	free(img)
}

@(private = "file")
ref_decode_free :: proc(d: ^Ref_Decode) {
	heap := runtime.heap_allocator()
	delete(d.pixels, heap)
	delete(d.kept, heap)
	delete(d.sample, heap)
	delete(d.why, heap)
	free(d, heap)
}

// Drops every picture and place, as a new or opened scene does.
refs_clear :: proc(app: ^App) {
	refs := &app.scene.refs
	for img in refs.images do ref_image_free(app, img)
	clear(&refs.images)
	clear(&refs.refs)
	refs.next_image, refs.next_ref, refs.view_off = 0, 0, false
	clear(&app.kit.board.selected)
}

// Frees everything, as the app closes.
refs_destroy :: proc(app: ^App) {
	refs_clear(app)
	delete(app.scene.refs.images)
	delete(app.scene.refs.refs)
	app.scene.refs = {}
	delete(app.kit.board.selected)
	delete(app.kit.board.box_base)
	app.kit.board.box_base = nil
	app.kit.board.selected = nil
	delete(app.kit.board.before)
	app.kit.board.before = nil
	delete(app.kit.board.note_before)
	app.kit.board.note_before = nil
	delete(app.kit.board.opacity_before)
	app.kit.board.opacity_before = nil
	delete(app.kit.board.fades)
	app.kit.board.fades = nil
	delete(app.kit.board.gesture_before)
	app.kit.board.gesture_before = nil
}

// Frees the pictures neither the board nor any step of the History places, once the
// History has let go of some (History.refs_dropped) or the board changed.
refs_collect :: proc(app: ^App) {
	refs := &app.scene.refs
	for img in refs.images do img.used = false
	mark :: proc(refs: ^References, list: []Ref) {
		for r in list do if img := ref_image(refs, r.image); img != nil do img.used = true
	}
	mark(refs, refs.refs[:])
	for e in app.history.done do if e.refs != nil {
		mark(refs, e.refs.before)
		mark(refs, e.refs.after)
	}
	for e in app.history.undone do if e.refs != nil {
		mark(refs, e.refs.before)
		mark(refs, e.refs.after)
	}
	for i := len(refs.images) - 1; i >= 0; i -= 1 {
		if refs.images[i].used do continue
		ref_image_free(app, refs.images[i])
		ordered_remove(&refs.images, i)
	}
	app.history.refs_dropped = false
}

// A .References entry's places before the change and after it, owned by the entry. The
// pictures they name stay in the scene while any entry names them (refs_collect).
Refs_Step :: struct {
	before, after: []Ref,
}

// Lists the change of the board from `before` (taken over) to what it is now as the
// newest undo step.
history_record_refs :: proc(app: ^App, before: []Ref, what: string) {
	step := new(Refs_Step)
	step^ = {before, refs_clone(app.scene.refs.refs[:])}
	history_push(app, History_Entry{kind = .References, what = what, at = time.tick_now(), refs = step})
	app.scene_edits += 1
}

refs_step_free :: proc(s: ^Refs_Step) {
	if s == nil do return
	delete(s.before)
	delete(s.after)
	free(s)
}

// Each frame's start: takes finished decodes (their GPU copies), starts waiting ones a
// few at a time, and frees the pictures nothing places any more.
refs_poll :: proc(app: ^App) {
	refs := &app.scene.refs
	if app.history.refs_dropped do refs_collect(app)
	running := 0
	for img in refs.images {
		d := img.decode
		if d == nil do continue
		if !sync.atomic_load(&d.done) {
			running += 1
			continue
		}
		ref_decode_take(app, img)
	}
	for img in refs.images {
		if running >= REF_DECODES_MAX do break
		if img.decode != nil || img.texture != 0 || img.failed != "" do continue
		ref_decode_start(img)
		running += 1
	}
	// Grey copies after every colour one, for the pictures a place shows grey.
	for img in refs.images {
		if running >= REF_DECODES_MAX do break
		if img.decode != nil || !ref_grey_wanted(app, img) do continue
		ref_decode_start(img, grey = true)
		running += 1
	}
	refs_memory(app, &running)
	if app.kit.board.snap {
		app.kit.board.snap = false
		refs_snap_view(app)
	}
}

// Holds the GPU copies to the memory limit: while they take more, the picture unseen the
// longest is shown from a small copy made from its Eyedropper copy on the spot (no
// decode), its grey copy dropped; a small one drawn again is decoded whole once it fits.
@(private = "file")
refs_memory :: proc(app: ^App, running: ^int) {
	refs := &app.scene.refs
	most := f64(app.refs_memory_mb if app.refs_memory_mb > 0 else REFS_MEMORY_AUTOMATIC_MB)
	now := app.kit.ctx.time
	for refs_gpu_mb(app) > most {
		oldest: ^Ref_Image
		for img in refs.images {
			if img.texture == 0 || img.small || img.sample == nil || img.decode != nil || now - img.seen < REF_UNSEEN_SECONDS do continue
			if oldest == nil || img.seen < oldest.seen do oldest = img
		}
		if oldest == nil do break
		small, w, h := rgba_shrink(oldest.sample, oldest.sample_size.x, oldest.sample_size.y, REF_SMALL_SIDE, context.temp_allocator)
		texture := render.picture_create(&app.renderer, small, w, h)
		if texture == 0 do break
		render.matcap_destroy(&app.renderer, &oldest.texture)
		render.matcap_destroy(&app.renderer, &oldest.grey)
		oldest.texture, oldest.shown, oldest.small, oldest.grey_failed = texture, {w, h}, true, false
		app.refs_shrunk += 1
	}
	for img in refs.images {
		if running^ >= REF_DECODES_MAX do break
		if !img.small || img.decode != nil || now - img.seen > 0.5 do continue
		if refs_gpu_mb(app) - texture_mb(img.shown) + texture_mb(ref_gpu_side(img)) > most do continue
		ref_decode_start(img)
		running^ += 1
	}
}

// The size of picture `img`'s whole GPU copy: its size halved until it fits REF_GPU_SIDE.
@(private = "file")
ref_gpu_side :: proc(img: ^Ref_Image) -> [2]int {
	w, h := max(img.width, 1), max(img.height, 1)
	for max(w, h) > REF_GPU_SIDE && w > 1 && h > 1 do w, h = w / 2, h / 2
	return {w, h}
}

// What an RGBA8 texture of `size` with its mips takes, in MB.
@(private = "file")
texture_mb :: proc(size: [2]int) -> f64 {
	return f64(size.x * size.y * 4 * 4 / 3) / f64(1 << 20)
}

// Puts a picture of the viewport as the last frame drew it on the board, as one undo
// step: the sculpt beside its references, or a before beside an after.
refs_snap_view :: proc(app: ^App) {
	w, h := int(app.target.width), int(app.target.height)
	pixels := render.viewport_download(&app.renderer, &app.target, context.temp_allocator, viewport_shown(app))
	if pixels == nil {
		file_note(app, true, "Could not read the viewport back for References")
		return
	}
	_ = refs_add_bytes(app, "View", png_write.encode(pixels, w, h, alpha = false))
}

// Whether picture `img` needs its grey copy made: a place shows it grey, its colour copy is
// up and neither a grey one nor its failure is there yet.
@(private = "file")
ref_grey_wanted :: proc(app: ^App, img: ^Ref_Image) -> bool {
	if img.texture == 0 || img.small || img.grey != 0 || img.grey_failed do return false
	for r in app.scene.refs.refs do if r.image == img.id && r.grey do return true
	return false
}

// Waits for every decode, the grey copies the places want included, and takes it, for a
// script, a test or the exit stats that must see the pictures however fast frames came.
refs_finish :: proc(app: ^App) {
	for {
		pending := false
		for img in app.scene.refs.images {
			if img.decode == nil {
				if img.texture == 0 && img.failed == "" {
					ref_decode_start(img)
				} else if ref_grey_wanted(app, img) {
					ref_decode_start(img, grey = true)
				} else {
					continue
				}
			}
			pending = true
			thread.join(img.decode.thread)
			ref_decode_take(app, img)
		}
		if !pending do return
	}
}

@(private = "file")
ref_decode_start :: proc(img: ^Ref_Image, grey := false) {
	d := new(Ref_Decode, runtime.heap_allocator())
	d.bytes, d.side, d.grey = img.bytes, REF_GPU_SIDE, grey
	img.decode = d
	d.thread = thread.create_and_start_with_data(d, proc(data: rawptr) {
		d := (^Ref_Decode)(data)
		context.allocator = runtime.heap_allocator()
		arena: runtime.Arena
		context.temp_allocator = runtime.arena_allocator(&arena)
		defer runtime.arena_destroy(&arena)
		defer sync.atomic_store(&d.done, true)
		start := time.tick_now()
		defer d.ms = time.duration_milliseconds(time.tick_since(start))
		ref_decode(d)
	}, context, .Low, name = "reference decode")
}

// The decode's work, on its thread: the pixels as RGBA8, halved until they fit the GPU
// copy's side, and a PNG of them at REF_SHRUNK_SIDE when the file is too big to keep.
ref_decode :: proc(d: ^Ref_Decode) {
	rgba, w, h, failed := matcap_pixels(d.bytes, context.temp_allocator)
	if failed != "" {
		d.why = strings.clone(failed)
		return
	}
	d.width, d.height = w, h
	if max(w, h) > REF_KEEP_SIDE {
		small, sw, sh := rgba_shrink(rgba, w, h, REF_SHRUNK_SIDE, context.temp_allocator)
		d.kept = png_write.encode(small, sw, sh, alpha = true)
		d.width, d.height = sw, sh
	}
	if !d.grey {
		small, sw, sh := rgba_shrink(rgba, w, h, REF_SAMPLE_SIDE, context.temp_allocator)
		d.sample = make([]u8, len(small))
		copy(d.sample, small)
		d.sample_size = {sw, sh}
	}
	shown, gw, gh := rgba_shrink(rgba, w, h, d.side, context.temp_allocator)
	d.pixels = make([]u8, len(shown))
	copy(d.pixels, shown)
	d.shown = {gw, gh}
	if d.grey {
		// Rec. 709's weights on the stored values: the brightness the eye sees, alpha kept.
		for i := 0; i < len(d.pixels); i += 4 {
			y := (2126 * u32(d.pixels[i]) + 7152 * u32(d.pixels[i + 1]) + 722 * u32(d.pixels[i + 2]) + 5000) / 10000
			d.pixels[i], d.pixels[i + 1], d.pixels[i + 2] = u8(y), u8(y), u8(y)
		}
	}
}

// Halves RGBA8 `pixels` (w by h) by averaging each 2 by 2 until its long side is at most
// `side`; the pixels themselves when they fit already.
rgba_shrink :: proc(pixels: []u8, w, h, side: int, allocator := context.allocator) -> (out: []u8, ow, oh: int) {
	out, ow, oh = pixels, w, h
	for max(ow, oh) > side && ow > 1 && oh > 1 {
		nw, nh := ow / 2, oh / 2
		next := make([]u8, nw * nh * 4, allocator)
		for y in 0 ..< nh {
			for x in 0 ..< nw {
				for c in 0 ..< 4 {
					a := int(out[((2 * y) * ow + 2 * x) * 4 + c]) + int(out[((2 * y) * ow + 2 * x + 1) * 4 + c])
					b := int(out[((2 * y + 1) * ow + 2 * x) * 4 + c]) + int(out[((2 * y + 1) * ow + 2 * x + 1) * 4 + c])
					next[(y * nw + x) * 4 + c] = u8((a + b + 2) / 4)
				}
			}
		}
		out, ow, oh = next, nw, nh
	}
	return
}

// Takes picture `img`'s finished decode: its GPU copy, its size (and the places that
// waited for its shape), the shrunk file in place of one too big, or why it failed.
@(private = "file")
ref_decode_take :: proc(app: ^App, img: ^Ref_Image) {
	d := img.decode
	thread.join(d.thread)
	thread.destroy(d.thread)
	img.decode = nil
	defer ref_decode_free(d)
	app.refs_decode_ms = max(app.refs_decode_ms, d.ms)
	if d.grey {
		if d.why == "" do img.grey = render.picture_create(&app.renderer, d.pixels, d.shown.x, d.shown.y)
		img.grey_shown = d.shown
		img.grey_failed = img.grey == 0
		return
	}
	if d.why != "" {
		img.failed = strings.clone(d.why)
		return
	}
	if d.kept != nil {
		delete(img.bytes)
		img.bytes = make([]u8, len(d.kept))
		copy(img.bytes, d.kept)
		app.scene_edits += 1
	}
	img.width, img.height = d.width, d.height
	// Just made, it counts as seen, so the memory limit does not take it back at once.
	img.seen = app.kit.ctx.time
	delete(img.sample)
	img.sample = make([]u8, len(d.sample))
	copy(img.sample, d.sample)
	img.sample_size = d.sample_size
	// A whole copy in place of the small one the memory limit left.
	render.matcap_destroy(&app.renderer, &img.texture)
	img.small = false
	img.texture = render.picture_create(&app.renderer, d.pixels, d.shown.x, d.shown.y)
	img.shown = d.shown
	if img.texture == 0 do img.failed = strings.clone(fmt.tprintf("the GPU refused a %d x %d picture", d.shown.x, d.shown.y))
	for &r in app.scene.refs.refs do if r.image == img.id && !r.sized do r = ref_sized(r, img)
}

// The places' ids in the board's order, bottom first, comma-separated ("none" for none),
// for the exit stats.
refs_order_text :: proc(app: ^App) -> string {
	if len(app.scene.refs.refs) == 0 do return "none"
	sb := strings.builder_make(context.temp_allocator)
	for r, i in app.scene.refs.refs do fmt.sbprintf(&sb, "%s%d", "," if i > 0 else "", r.id)
	return strings.to_string(sb)
}

// Each place's angle on the board, its angle over the view (both in whole degrees) or its
// width over the view (thousandths of the view's), in the board's order, comma-separated
// ("none" for none), and how many are locked on the view, for the exit stats.
Refs_Stat :: enum u8 {
	Angle,
	View_Angle,
	View_Width,
}

refs_stat_text :: proc(app: ^App, what: Refs_Stat) -> string {
	if len(app.scene.refs.refs) == 0 do return "none"
	sb := strings.builder_make(context.temp_allocator)
	for r, i in app.scene.refs.refs {
		v: f32
		switch what {
		case .Angle:      v = r.angle * 180 / math.PI
		case .View_Angle: v = r.view_angle * 180 / math.PI
		case .View_Width: v = r.view_w * 1000
		}
		fmt.sbprintf(&sb, "%s%d", "," if i > 0 else "", int(math.round(v)))
	}
	return strings.to_string(sb)
}

refs_view_locked_count :: proc(app: ^App) -> int {
	n := 0
	for r in app.scene.refs.refs do if r.view_locked do n += 1
	return n
}

// How many pictures over the view are drawn behind the model, for the exit stats.
refs_view_behind_count :: proc(app: ^App) -> int {
	n := 0
	for r in app.scene.refs.refs do if r.view && r.view_behind && r.image != 0 do n += 1
	return n
}

// How many pictures have their GPU copy, for the exit stats.
refs_shown_count :: proc(app: ^App) -> int {
	n := 0
	for img in app.scene.refs.images do if img.texture != 0 do n += 1
	return n
}

// How many places are notes, and how many pictures have their grey copy, for the exit stats.
refs_note_count :: proc(app: ^App) -> int {
	n := 0
	for r in app.scene.refs.refs do if r.image == 0 do n += 1
	return n
}

refs_small_count :: proc(app: ^App) -> int {
	n := 0
	for img in app.scene.refs.images do if img.small do n += 1
	return n
}

refs_grey_count :: proc(app: ^App) -> int {
	n := 0
	for img in app.scene.refs.images do if img.grey != 0 do n += 1
	return n
}

// The GPU copies' size in megabytes, mips included, for the exit stats.
refs_gpu_mb :: proc(app: ^App) -> f64 {
	bytes := 0
	for img in app.scene.refs.images {
		if img.texture != 0 do bytes += img.shown.x * img.shown.y * 4 * 4 / 3
		if img.grey != 0 do bytes += img.grey_shown.x * img.grey_shown.y * 4 * 4 / 3
	}
	return f64(bytes) / f64(1 << 20)
}

// The references chunk of a scene file, its fields a record's (tags are never reused or
// retyped, geom/record.odin): the next ids, then a field a picture (its id, name, size and
// bytes) and a field a place.
CHUNK_REFS :: "REFS"

Refs_Tag :: enum u16 {
	Next_Image = 1, // u32
	Next_Ref   = 2, // u32
	View_Off   = 3, // u8: places on the view hidden
	Image      = 4, // Ref_Image_Tag record
	Ref        = 5, // Ref_Tag record
}

Ref_Image_Tag :: enum u16 {
	Id     = 1, // u32, required
	Name   = 2, // text
	Width  = 3, // i32
	Height = 4, // i32
	Bytes  = 5, // the picture's file as it was added
}

Ref_Tag :: enum u16 {
	Id          = 1,  // u32, required
	Image       = 2,  // u32: its picture, 0 for a note
	At          = 3,  // [2]f32
	Size        = 4,  // [2]f32
	Crop_Lo     = 5,  // [2]f32
	Crop_Hi     = 6,  // [2]f32
	Turn        = 7,  // u8 quarter turns
	Flip        = 8,  // u8
	Grey        = 9,  // u8
	Locked      = 10, // u8
	Sized       = 11, // u8
	View        = 12, // u8: shown on the view
	View_Locked = 13, // u8
	View_At     = 14, // [2]f32
	View_W      = 15, // f32
	Opacity     = 16, // f32
	Angle       = 17, // f32
	View_Angle  = 18, // f32
	Plane       = 19, // u8 Ref_Plane
	Through     = 20, // u8
	Plane_Any   = 21, // u8
	Plane_Off   = 22, // u8
	Plane_At    = 23, // [3]f32
	Plane_H     = 24, // f32
	Marks       = 25, // [2]f32: brow and chin
	Text        = 26, // text, a note's
	View_Behind = 27, // u8: drawn behind the model; an earlier build shows it in front
}

refs_put :: proc(out: ^[dynamic]u8, refs: ^References) {
	at := scene_chunk_begin(out, CHUNK_REFS)
	defer scene_chunk_end(out, at)
	geom.rec_put(out, Refs_Tag.Next_Image, refs.next_image)
	geom.rec_put(out, Refs_Tag.Next_Ref, refs.next_ref)
	geom.rec_put(out, Refs_Tag.View_Off, u8(refs.view_off))
	for img in refs.images {
		ia := geom.rec_begin(out, Refs_Tag.Image)
		geom.rec_put(out, Ref_Image_Tag.Id, img.id)
		geom.rec_put_string(out, Ref_Image_Tag.Name, img.name)
		geom.rec_put(out, Ref_Image_Tag.Width, i32(img.width))
		geom.rec_put(out, Ref_Image_Tag.Height, i32(img.height))
		geom.rec_put_slice(out, Ref_Image_Tag.Bytes, img.bytes)
		geom.rec_end(out, ia)
	}
	for &r in refs.refs {
		T :: Ref_Tag
		ra := geom.rec_begin(out, Refs_Tag.Ref)
		geom.rec_put(out, T.Id, r.id)
		geom.rec_put(out, T.Image, r.image)
		geom.rec_put(out, T.At, r.at)
		geom.rec_put(out, T.Size, r.size)
		geom.rec_put(out, T.Crop_Lo, r.crop_lo)
		geom.rec_put(out, T.Crop_Hi, r.crop_hi)
		geom.rec_put(out, T.Turn, r.turn)
		geom.rec_put(out, T.Flip, u8(r.flip))
		geom.rec_put(out, T.Grey, u8(r.grey))
		geom.rec_put(out, T.Locked, u8(r.locked))
		geom.rec_put(out, T.Sized, u8(r.sized))
		geom.rec_put(out, T.View, u8(r.view))
		geom.rec_put(out, T.View_Locked, u8(r.view_locked))
		geom.rec_put(out, T.View_Behind, u8(r.view_behind))
		geom.rec_put(out, T.View_At, r.view_at)
		geom.rec_put(out, T.View_W, r.view_w)
		geom.rec_put(out, T.Opacity, r.opacity)
		geom.rec_put(out, T.Angle, r.angle)
		geom.rec_put(out, T.View_Angle, r.view_angle)
		geom.rec_put(out, T.Plane, u8(r.plane))
		geom.rec_put(out, T.Through, u8(r.through))
		geom.rec_put(out, T.Plane_Any, u8(r.plane_any))
		geom.rec_put(out, T.Plane_Off, u8(r.plane_off))
		geom.rec_put(out, T.Plane_At, r.plane_at)
		geom.rec_put(out, T.Plane_H, r.plane_h)
		geom.rec_put(out, T.Marks, r.marks)
		if r.image == 0 do geom.rec_put_string(out, T.Text, ref_note_text(&r))
		geom.rec_end(out, ra)
	}
}

// The references as refs_put wrote them; ok is false when the chunk is damaged: a count
// past what it holds, a picture's id twice or past the next one, a place of a picture it
// does not hold, a size that is not a positive finite number, a crop outside the picture
// or turned inside out, a turn past three quarters, an angle past a half turn either way, a note's text too long, a plane of no
// view, out in the far distance or of a note, or brow and chin marks out of order.
refs_get :: proc(r: ^geom.Byte_Reader) -> (refs: References, ok: bool) {
	rec := geom.record_of(r.data[r.at:])
	r.at = len(r.data)
	known, _ := geom.record_known(&rec, Refs_Tag)
	refs.next_image = geom.rec_get(&rec, Refs_Tag.Next_Image, u32, 0)
	refs.next_ref = geom.rec_get(&rec, Refs_Tag.Next_Ref, u32, 0)
	view_off := geom.rec_get(&rec, Refs_Tag.View_Off, u8, 0)
	refs.view_off = view_off == 1
	images := geom.rec_count(&rec, Refs_Tag.Image)
	if !rec.ok || !known || images > REF_IMAGES_MAX || view_off > 1 do return {}, false
	defer if !ok do refs_free(&refs)
	at := 0
	for _ in 0 ..< images {
		payload, _ := geom.rec_next(&rec, Refs_Tag.Image, &at)
		ir := geom.record_of(payload)
		img := new(Ref_Image)
		append(&refs.images, img)
		img.id = geom.rec_need(&ir, Ref_Image_Tag.Id, u32)
		img.name = geom.rec_get_string(&ir, Ref_Image_Tag.Name)
		img.width = int(geom.rec_get(&ir, Ref_Image_Tag.Width, i32, 0))
		img.height = int(geom.rec_get(&ir, Ref_Image_Tag.Height, i32, 0))
		bytes, _ := geom.rec_find(&ir, Ref_Image_Tag.Bytes)
		img.bytes = make([]u8, len(bytes))
		copy(img.bytes, bytes)
		if !ir.ok || img.id == 0 || img.id > refs.next_image || img.width < 0 || img.height < 0 do return
		for other in refs.images[:len(refs.images) - 1] do if other.id == img.id do return
	}
	at = 0
	for _ in 0 ..< geom.rec_count(&rec, Refs_Tag.Ref) {
		T :: Ref_Tag
		payload, _ := geom.rec_next(&rec, Refs_Tag.Ref, &at)
		pr := geom.record_of(payload)
		p: Ref
		p.id = geom.rec_need(&pr, T.Id, u32)
		p.image = geom.rec_get(&pr, T.Image, u32, 0)
		p.at = geom.rec_get(&pr, T.At, [2]f32, [2]f32{})
		p.size = geom.rec_get(&pr, T.Size, [2]f32, REF_ADD_HEIGHT)
		p.crop_lo = geom.rec_get(&pr, T.Crop_Lo, [2]f32, [2]f32{})
		p.crop_hi = geom.rec_get(&pr, T.Crop_Hi, [2]f32, [2]f32{1, 1})
		p.turn = geom.rec_get(&pr, T.Turn, u8, 0)
		flags := [7]u8 {
			geom.rec_get(&pr, T.Flip, u8, 0),
			geom.rec_get(&pr, T.Grey, u8, 0),
			geom.rec_get(&pr, T.Locked, u8, 0),
			geom.rec_get(&pr, T.Sized, u8, 0),
			geom.rec_get(&pr, T.View, u8, 0),
			geom.rec_get(&pr, T.View_Locked, u8, 0),
			geom.rec_get(&pr, T.View_Behind, u8, 0),
		}
		p.view_at = geom.rec_get(&pr, T.View_At, [2]f32, REF_VIEW_AT)
		p.view_w = geom.rec_get(&pr, T.View_W, f32, REF_VIEW_W)
		p.opacity = geom.rec_get(&pr, T.Opacity, f32, REF_OPACITY)
		p.angle = geom.rec_get(&pr, T.Angle, f32, 0)
		p.view_angle = geom.rec_get(&pr, T.View_Angle, f32, 0)
		plane := geom.rec_get(&pr, T.Plane, u8, 0)
		plane_flags := [3]u8{geom.rec_get(&pr, T.Through, u8, 0), geom.rec_get(&pr, T.Plane_Any, u8, 0), geom.rec_get(&pr, T.Plane_Off, u8, 0)}
		p.plane_at = geom.rec_get(&pr, T.Plane_At, [3]f32, [3]f32{})
		p.plane_h = geom.rec_get(&pr, T.Plane_H, f32, 0)
		p.marks = geom.rec_get(&pr, T.Marks, [2]f32, [2]f32{})
		text, _ := geom.rec_find(&pr, T.Text)
		if !pr.ok do return
		for f in flags do if f > 1 do return
		for f in plane_flags do if f > 1 do return
		if !(abs(p.angle) <= math.PI + 1e-3 && abs(p.view_angle) <= math.PI + 1e-3) do return
		if !refs_marks_ok(p.marks) do return
		if plane > u8(max(Ref_Plane)) do return
		p.plane = Ref_Plane(plane)
		p.through, p.plane_any, p.plane_off = plane_flags[0] == 1, plane_flags[1] == 1, plane_flags[2] == 1
		if !(abs(p.plane_at.x) < REF_PLANE_FAR && abs(p.plane_at.y) < REF_PLANE_FAR && abs(p.plane_at.z) < REF_PLANE_FAR) do return
		if p.plane != .None && !(p.plane_h > 0 && p.plane_h < REF_PLANE_FAR) do return
		if p.plane != .None && p.image == 0 do return
		if !(abs(p.view_at.x) <= 4 && abs(p.view_at.y) <= 4 && p.view_w > 0 && p.view_w <= 4) do return
		if !(p.opacity >= REF_OPACITY_MIN && p.opacity <= 1) do return
		if p.turn > 3 || p.id == 0 || p.id > refs.next_ref do return
		if p.image != 0 && ref_image(&refs, p.image) == nil do return
		if !(p.size.x > 0 && p.size.y > 0 && p.size.x < math.F32_MAX && p.size.y < math.F32_MAX) do return
		if !(abs(p.at.x) < math.F32_MAX && abs(p.at.y) < math.F32_MAX) do return
		if !(p.crop_lo.x >= 0 && p.crop_lo.y >= 0 && p.crop_hi.x <= 1 && p.crop_hi.y <= 1) do return
		if !(p.crop_lo.x < p.crop_hi.x && p.crop_lo.y < p.crop_hi.y) do return
		p.flip, p.grey, p.locked, p.sized, p.view, p.view_locked, p.view_behind = flags[0] == 1, flags[1] == 1, flags[2] == 1, flags[3] == 1, flags[4] == 1, flags[5] == 1, flags[6] == 1
		if p.view && p.image == 0 do return
		if p.image == 0 {
			if len(text) >= REF_NOTE_MAX do return
			copy(p.text[:], text)
		}
		append(&refs.refs, p)
	}
	ok = true
	return
}

// Frees references read but not put in a scene (no GPU copies yet).
refs_free :: proc(refs: ^References) {
	for img in refs.images {
		delete(img.name)
		delete(img.sample)
		delete(img.bytes)
		delete(img.failed)
		free(img)
	}
	delete(refs.images)
	delete(refs.refs)
	refs^ = {}
}

// Puts references read from a file in place of the scene's.
refs_take :: proc(app: ^App, refs: ^References) {
	refs_destroy(app)
	app.scene.refs = refs^
	refs^ = {}
}
