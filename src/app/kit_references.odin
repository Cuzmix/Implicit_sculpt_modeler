package main

import "core:fmt"
import "core:math"
import "core:slice"

import "../render"
import "../ui"

// The References card (Card.References): a board of the scene's reference pictures, as
// PureRef's, inside a card, so it floats, pins and sits in a column as every card does
// and the model stays in view beside it. A drag on a picture moves the picked ones, its
// corner sizes it, a drag on the board's ground pans, the wheel or a pinch zooms about the
// pointer, and a double tap on the ground fits everything. The top row adds (a file, the
// clipboard, the view itself, a note) and tidies (Arrange, Same height, Fit all); the row
// under it edits the picked places (Flip, Grey, Turn, Crop, Lock, Delete), or a picked
// note's text. The pictures are drawn by the interface from their GPU copies
// (references.odin), only where the board shows them.

// The board as the card shows it: the board point at its top left and the screen points a
// board point takes (0 until it is first fitted), the picked places by id, and the drag
// under way with the places as they were when it began (owned, for its undo step).
Ref_Board :: struct {
	pan:      [2]f32,
	zoom:     f32,
	selected: [dynamic]u32,
	drag:     Ref_Drag,
	last:     [2]f32,
	before:   []Ref,
	// Two fingers on it: their spread and middle last frame (0 spread: none yet).
	spread:   f32,
	middle:   [2]f32,
	tap:      Handle_Tap,
	room:     ui.Rect, // where the board was last drawn, in points
	moves:    int, // drags that moved or sized pictures, for the exit stats
	snap:     bool, // Snap view waits for the next frame's start (refs_poll)
	// The place whose crop is shown whole with its edges to drag (0: none), and the edges
	// a crop drag moves (CROP_LEFT and the others).
	cropping: u32,
	edges:    u8,
	// The picked note's text as its field edits it, which note that is, and the board
	// before the edit began (owned), for one undo step when the field lets go.
	note:     [REF_NOTE_MAX]u8,
	note_id:  u32,
	note_before: []Ref,
	// The board before the Opacity slider began to move (owned), for its one undo step.
	opacity_before: []Ref,
	// Over the view (refs_view.odin): each place's fade under the pointer, the drag under
	// way on one and which, and where the pointer was.
	fades:     map[u32]f32,
	view_drag: Ref_Drag,
	view_id:   u32,
	view_last: [2]f32,
}

CROP_LEFT :: 1
CROP_RIGHT :: 2
CROP_TOP :: 4
CROP_BOTTOM :: 8

Ref_Drag :: enum u8 {
	None,
	Pan,
	Move,
	Size,
	Crop,
}

// How wide the card is: room for a board two pictures across beside the model.
REFS_CARD_W :: 420
// The board's zoom range, in screen points a board point.
BOARD_ZOOM_MIN :: 0.05
BOARD_ZOOM_MAX :: 8
// The gap Arrange leaves between places, in board points.
BOARD_ARRANGE_GAP :: 12
// How far a wheel notch zooms.
BOARD_WHEEL_STEP :: 1.2
// The least height the board takes, so a short card still shows something to work on.
BOARD_MIN_H :: 160
// The gap between a picture added and the one before it, in board points.
BOARD_ADD_STEP :: 32

// GPU copy of picture `slot` (KIT_REF_IMAGE + slot), or its grey copy past
// REF_IMAGES_MAX, for kit_draws; nil while it decodes.
refs_texture :: proc(app: ^App, slot: int) -> render.Texture {
	images := app.scene.refs.images[:]
	grey := slot >= REF_IMAGES_MAX
	at := slot - REF_IMAGES_MAX if grey else slot
	if at < 0 || at >= len(images) do return 0
	return images[at].grey if grey else images[at].texture
}

// The board point at screen point `p` of the board drawn at `room`.
@(private = "file")
board_point :: proc(b: ^Ref_Board, room: ui.Rect, p: [2]f32) -> [2]f32 {
	return b.pan + (p - {room.x, room.y}) / board_zoom(b)
}

// Place `r` on screen, in points.
@(private = "file")
board_rect :: proc(b: ^Ref_Board, room: ui.Rect, r: Ref) -> ui.Rect {
	z := board_zoom(b)
	return {room.x + (r.at.x - b.pan.x) * z, room.y + (r.at.y - b.pan.y) * z, r.size.x * z, r.size.y * z}
}

@(private = "file")
board_zoom :: proc(b: ^Ref_Board) -> f32 {
	return b.zoom if b.zoom > 0 else 1
}

// Where a picture added now goes on the board: beside the newest place, its top level
// with it, as pictures dropped one after another line up in a row; the first in the
// middle of what the board shows.
board_drop_point :: proc(app: ^App) -> [2]f32 {
	b := &app.kit.board
	list := app.scene.refs.refs[:]
	if len(list) > 0 {
		last := list[len(list) - 1]
		return {last.at.x + last.size.x + BOARD_ADD_STEP, last.at.y}
	}
	room := b.room
	if room.w <= 0 do room = {0, 0, REFS_CARD_W, 2 * REF_ADD_HEIGHT}
	return b.pan + [2]f32{room.w, room.h} * 0.5 / board_zoom(b) - REF_ADD_HEIGHT * 0.5
}

// Brings the place of id `id` into what the board shows, fitting everything when it lies
// outside.
board_show :: proc(app: ^App, id: u32) {
	b := &app.kit.board
	i := ref_index(&app.scene.refs, id)
	if i < 0 || b.room.w <= 0 do return
	at := board_rect(b, b.room, app.scene.refs.refs[i])
	inside := at.x >= b.room.x && at.y >= b.room.y && at.x + at.w <= b.room.x + b.room.w && at.y + at.h <= b.room.y + b.room.h
	if !inside do board_fit(app, b.room)
}

// Zooms the board by `by` about screen point `at`, so what lies under it stays.
@(private = "file")
board_zoom_about :: proc(b: ^Ref_Board, room: ui.Rect, at: [2]f32, by: f32) {
	under := board_point(b, room, at)
	b.zoom = clamp(board_zoom(b) * by, BOARD_ZOOM_MIN, BOARD_ZOOM_MAX)
	b.pan = under - (at - {room.x, room.y}) / b.zoom
}

// Fits every picture on the board into `room`, or the place it starts at when there is
// none.
board_fit :: proc(app: ^App, room: ui.Rect) {
	b := &app.kit.board
	refs := app.scene.refs.refs[:]
	if len(refs) == 0 || room.w <= 0 || room.h <= 0 {
		b.pan, b.zoom = {}, 1
		return
	}
	lo, hi := refs[0].at, refs[0].at + refs[0].size
	for r in refs {
		lo = {min(lo.x, r.at.x), min(lo.y, r.at.y)}
		hi = {max(hi.x, r.at.x + r.size.x), max(hi.y, r.at.y + r.size.y)}
	}
	// A margin of a twentieth on each side, so the outer pictures do not touch the edge.
	size := (hi - lo) * 1.1
	b.zoom = clamp(min(room.w / max(size.x, 1), room.h / max(size.y, 1)), BOARD_ZOOM_MIN, BOARD_ZOOM_MAX)
	b.pan = (lo + hi) * 0.5 - [2]f32{room.w, room.h} * 0.5 / b.zoom
}

// Whether place `id` is picked.
board_picked :: proc(b: ^Ref_Board, id: u32) -> bool {
	for s in b.selected do if s == id do return true
	return false
}

// Takes the picked places off the board as one undo step.
refs_delete_selected :: proc(app: ^App) {
	b := &app.kit.board
	if len(b.selected) == 0 do return
	before := refs_clone(app.scene.refs.refs[:])
	list := &app.scene.refs.refs
	for i := len(list) - 1; i >= 0; i -= 1 do if board_picked(b, list[i].id) do ordered_remove(list, i)
	n := len(b.selected)
	clear(&b.selected)
	history_record_refs(app, before, "Delete reference" if n == 1 else "Delete references")
}

// Adds the picture on the system clipboard to the board, or says there is none.
refs_paste :: proc(app: ^App) -> bool {
	data := platform_clipboard_image()
	if data == nil {
		// The browser reads its clipboard later and drops the picture it finds (web/sdl_web.js).
		when ODIN_OS == .JS do file_note(app, false, "Looking for a picture on the clipboard")
		else do file_note(app, true, "The clipboard holds no picture to add to References")
		return false
	}
	return refs_add_bytes(app, "Pasted picture", data)
}

// Adds a note where the next picture would go, picked, with its text ready to type.
refs_add_note :: proc(app: ^App) {
	refs := &app.scene.refs
	before := refs_clone(refs.refs[:])
	refs.next_ref += 1
	n := Ref{id = refs.next_ref, at = board_drop_point(app), size = REF_NOTE_SIZE, crop_hi = 1, sized = true, view_at = REF_VIEW_AT, view_w = REF_VIEW_W, opacity = 1}
	copy(n.text[:REF_NOTE_MAX - 1], "Note")
	append(&refs.refs, n)
	history_record_refs(app, before, "Add note")
	b := &app.kit.board
	clear(&b.selected)
	append(&b.selected, n.id)
	board_show(app, n.id)
}

// The places Arrange and Same height work on: the picked ones when two or more are, else
// all, as indices into the board's list, leaving out locked ones (and notes when `notes`
// is off). Temporary.
@(private = "file")
refs_tidy_list :: proc(app: ^App, notes: bool) -> [dynamic]int {
	b := &app.kit.board
	list := make([dynamic]int, context.temp_allocator)
	for r, i in app.scene.refs.refs {
		if r.locked || (!notes && r.image == 0) do continue
		if len(b.selected) >= 2 && !board_picked(b, r.id) do continue
		append(&list, i)
	}
	return list
}

// Packs the places in rows, tallest first, from where the first of them lies, about as
// wide as the board shows for their area, so they take its shape without gaps; then fits
// the board to them. One undo step.
refs_arrange :: proc(app: ^App) {
	refs := &app.scene.refs
	list := refs_tidy_list(app, true)
	if len(list) < 2 do return
	before := refs_clone(refs.refs[:])
	start := refs.refs[list[0]].at
	area: f32
	for i in list {
		r := refs.refs[i]
		start = {min(start.x, r.at.x), min(start.y, r.at.y)}
		area += (r.size.x + BOARD_ARRANGE_GAP) * (r.size.y + BOARD_ARRANGE_GAP)
	}
	room := app.kit.board.room
	aspect := room.w / room.h if room.w > 0 && room.h > 0 else 1
	width := math.sqrt(area * aspect)
	// Tallest first, and by the board's order among equals, so the same board always arranges the same way.
	Item :: struct {
		i: int,
		h: f32,
	}
	items := make([]Item, len(list), context.temp_allocator)
	for i, k in list do items[k] = {i, refs.refs[i].size.y}
	slice.stable_sort_by(items, proc(a, b: Item) -> bool {return a.h > b.h})
	x, y, row := start.x, start.y, f32(0)
	for it in items {
		r := &refs.refs[it.i]
		// A place starts a new row unless its middle still falls inside the width, so rows
		// come out about as wide as asked rather than always narrower.
		if x > start.x && x + r.size.x * 0.5 > start.x + width {
			x, y, row = start.x, y + row + BOARD_ARRANGE_GAP, 0
		}
		r.at = {x, y}
		x += r.size.x + BOARD_ARRANGE_GAP
		row = max(row, r.size.y)
	}
	history_record_refs(app, before, "Arrange references")
	board_fit(app, app.kit.board.room)
}

// Gives the pictures one height, each keeping its shape and its top left: the first
// picked one's when two or more are picked, else the middle one of all their heights.
// One undo step.
refs_same_height :: proc(app: ^App) {
	refs := &app.scene.refs
	b := &app.kit.board
	list := refs_tidy_list(app, false)
	if len(list) < 2 do return
	height: f32
	if len(b.selected) >= 2 {
		height = refs.refs[list[0]].size.y
		for i in list do if refs.refs[i].id == b.selected[0] do height = refs.refs[i].size.y
	} else {
		heights := make([]f32, len(list), context.temp_allocator)
		for i, k in list do heights[k] = refs.refs[i].size.y
		slice.sort(heights)
		height = heights[len(heights) / 2]
	}
	before := refs_clone(refs.refs[:])
	for i in list {
		r := &refs.refs[i]
		r.size = {r.size.x * height / r.size.y, height}
	}
	if slice.equal(before, refs.refs[:]) {
		delete(before)
		return
	}
	history_record_refs(app, before, "Same height")
}

// The edits of the picked places' row, each one undo step on the picked pictures (notes
// pass them by): Flip, Grey and On view set every one as the first is not, Turn turns
// the unlocked ones a quarter clockwise about their middles, Lock sets every picked
// place (notes too) as the first is not.
Ref_Edit :: enum u8 {
	Flip,
	Grey,
	Turn,
	Lock,
	View,
}

refs_edit :: proc(app: ^App, edit: Ref_Edit) {
	refs := &app.scene.refs
	b := &app.kit.board
	first: Maybe(Ref)
	for r in refs.refs do if board_picked(b, r.id) && (r.image != 0 || edit == .Lock) {
		first = r
		break
	}
	f, ok := first.?
	if !ok do return
	before := refs_clone(refs.refs[:])
	for &r in refs.refs {
		if !board_picked(b, r.id) || (r.image == 0 && edit != .Lock) do continue
		switch edit {
		case .Flip:
			r.flip = !f.flip
		case .Grey:
			r.grey = !f.grey
		case .Lock:
			r.locked = !f.locked
		case .View:
			r.view = !f.view
		case .Turn:
			if r.locked do continue
			middle := r.at + r.size * 0.5
			r.turn = (r.turn + 1) % 4
			r.size = r.size.yx
			r.at = middle - r.size * 0.5
		}
	}
	if slice.equal(before, refs.refs[:]) {
		delete(before)
		return
	}
	names := [Ref_Edit]string{.Flip = "Flip reference", .Grey = "Grey reference", .Turn = "Turn reference", .Lock = "Lock reference", .View = "Reference on view"}
	history_record_refs(app, before, names[edit])
	if edit == .Turn || edit == .Lock do b.cropping = 0
}

// Whether every picked place `pick` says of, for the row's lit buttons: flipped, grey or
// locked.
@(private = "file")
refs_picked_all :: proc(app: ^App, pick: proc(r: Ref) -> bool) -> bool {
	b := &app.kit.board
	found := false
	for r in app.scene.refs.refs do if board_picked(b, r.id) {
		if !pick(r) do return false
		found = true
	}
	return found
}

// Lists a note's typing as one undo step once its field lets go of the keys.
@(private = "file")
refs_note_commit :: proc(app: ^App) {
	b := &app.kit.board
	if b.note_before == nil do return
	if slice.equal(b.note_before, app.scene.refs.refs[:]) do delete(b.note_before)
	else do history_record_refs(app, b.note_before, "Edit note")
	b.note_before = nil
}

// The one picked place when exactly one is, or nil.
@(private = "file")
board_one :: proc(app: ^App) -> ^Ref {
	b := &app.kit.board
	if len(b.selected) != 1 do return nil
	i := ref_index(&app.scene.refs, b.selected[0])
	return &app.scene.refs.refs[i] if i >= 0 else nil
}

// The References card's body, `inner` wide and at most `room` tall: the row that adds and
// tidies, the row that edits the picked places, then the board.
refs_card_body :: proc(app: ^App, inner, room: f32, owner: ui.Id) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	b := &k.board
	refs := &app.scene.refs
	// What a picked place no longer on the board (undone, deleted) leaves behind.
	for i := len(b.selected) - 1; i >= 0; i -= 1 do if ref_index(refs, b.selected[i]) < 0 do ordered_remove(&b.selected, i)
	if b.cropping != 0 && (len(b.selected) != 1 || b.selected[0] != b.cropping) do b.cropping = 0
	filled := len(refs.refs) > 0
	ui.begin(ctx, "refs actions", {direction = .Row, width = inner, gap = t.gap, center = true})
	if ui.icon_button(ctx, "Add pictures##refs", ICON_IMAGE_PLUS) do file_dialog(app, .Reference)
	if ui.icon_button(ctx, "Paste picture##refs", ICON_CLIPBOARD_PASTE) do _ = refs_paste(app)
	if ui.icon_button(ctx, "Snap view##refs", ICON_IMAGE_DOWN) do b.snap = true
	if ui.icon_button(ctx, "Add note##refs", ICON_STICKY_NOTE) do refs_add_note(app)
	if ui.icon_button(ctx, "Arrange##refs", ICON_LAYOUT_DASHBOARD, enabled = len(refs.refs) > 1) do refs_arrange(app)
	if ui.icon_button(ctx, "Same height##refs", ICON_STRETCH_VERTICAL, enabled = len(refs.refs) > 1) do refs_same_height(app)
	if ui.icon_button(ctx, "Fit all##refs", ICON_SCAN, enabled = filled) do board_fit(app, b.room)
	ui.end(ctx)
	one := board_one(app)
	picked := len(b.selected) > 0
	ui.begin(ctx, "refs edits", {direction = .Row, width = inner, gap = t.gap, center = true})
	if one != nil && one.image == 0 {
		// A note's text, typed in its own buffer and put on the note as it changes, one undo step a typing.
		if b.note_id != one.id do refs_note_commit(app)
		// Unless typing is under way, the field shows the note as it is, an undo's too.
		if b.note_id != one.id || b.note_before == nil do b.note = one.text
		b.note_id = one.id
		field := inner - 2 * t.target - 2 * t.gap
		if ui.text_field(ctx, "note text##refs", b.note[:REF_NOTE_MAX - 1], field, hint = "Note") {
			if b.note_before == nil do b.note_before = refs_clone(refs.refs[:])
			one.text = b.note
			app.scene_edits += 1
		}
		if ctx.text_focus != ui.id_of(ctx, "note text##refs") do refs_note_commit(app)
	} else {
		refs_note_commit(app)
		b.note_id = 0
		pictures := false
		for r in refs.refs do if board_picked(b, r.id) && r.image != 0 do pictures = true
		if ui.icon_button(ctx, "Flip##refs", ICON_FLIP_PICTURE, selected = refs_picked_all(app, proc(r: Ref) -> bool {return r.image == 0 || r.flip}), enabled = pictures) do refs_edit(app, .Flip)
		if ui.icon_button(ctx, "Grey##refs", ICON_GREY, selected = refs_picked_all(app, proc(r: Ref) -> bool {return r.image == 0 || r.grey}), enabled = pictures) do refs_edit(app, .Grey)
		if ui.icon_button(ctx, "Turn##refs", ICON_TURN, enabled = pictures) do refs_edit(app, .Turn)
		crop_ok := one != nil && one.image != 0 && !one.locked
		if ui.icon_button(ctx, "Crop##refs", ICON_CROP, selected = b.cropping != 0, enabled = crop_ok) do b.cropping = 0 if b.cropping != 0 else one.id
		if ui.icon_button(ctx, "On view##refs", ICON_ON_VIEW, selected = refs_picked_all(app, proc(r: Ref) -> bool {return r.image == 0 || r.view}), enabled = pictures) do refs_edit(app, .View)
	}
	locked := refs_picked_all(app, proc(r: Ref) -> bool {return r.locked})
	if ui.icon_button(ctx, "Unlock##refs" if locked else "Lock##refs", ICON_LOCK if locked else ICON_LOCK_OPEN, selected = locked, enabled = picked) do refs_edit(app, .Lock)
	if ui.icon_button(ctx, "Delete##refs", ICON_TRASH_2, enabled = picked) do refs_delete_selected(app)
	ui.end(ctx)
	rows: f32 = 2
	// The picked places over the view: their opacity, the first one's shown, set on all.
	viewed: ^Ref
	for &r in refs.refs do if board_picked(b, r.id) && r.view && r.image != 0 {
		viewed = &r
		break
	}
	if viewed != nil {
		rows += 1
		value := viewed.opacity * 100
		ui.begin(ctx, "refs view", {direction = .Row, width = inner, gap = t.gap, center = true})
		if ui.slider(ctx, "Opacity##refs", &value, REF_OPACITY_MIN * 100, 100, .Linear, fmt.tprintf("%.0f%%", value)) {
			if b.opacity_before == nil do b.opacity_before = refs_clone(refs.refs[:])
			for &r in refs.refs do if board_picked(b, r.id) && r.view && r.image != 0 do r.opacity = value / 100
			app.scene_edits += 1
		}
		ui.end(ctx)
	}
	if b.opacity_before != nil && .Left not_in ctx.input.down {
		if slice.equal(b.opacity_before, refs.refs[:]) do delete(b.opacity_before)
		else do history_record_refs(app, b.opacity_before, "Reference opacity")
		b.opacity_before = nil
	}
	board_h := max(room - rows * t.target - rows * t.gap, BOARD_MIN_H)
	ui.begin(ctx, "refs board", {width = inner, height = board_h, clip = true, radius = t.radius_medium})
	a := ui.area(ctx, "board", {inner, board_h})
	ui.end(ctx)
	r := a.rect
	// The first time it is shown with pictures on it, the board fits them.
	if b.zoom <= 0 && filled do board_fit(app, r)
	b.room = r
	board_input(app, a)
	board_draw(app, r)
}

// Draws picture place `p` at screen rect `at`, at opacity `alpha`: its GPU copy cropped,
// flipped and turned (the grey copy once made, when grey), or a box saying it loads or
// why it cannot be shown.
refs_picture_draw :: proc(app: ^App, at: ui.Rect, p: Ref, alpha: u8) {
	ctx := &app.kit.ctx
	t := ctx.theme
	refs := &app.scene.refs
	slot := ref_image_slot(refs, p.image)
	img := refs.images[slot]
	img.seen = ctx.time
	if img.texture != 0 {
		id := KIT_REF_IMAGE + u64(slot)
		if p.grey && img.grey != 0 do id += REF_IMAGES_MAX
		ui.image_corners(ctx, at, id, ref_corners(p), {255, 255, 255, alpha})
		return
	}
	ui.fill_rect(ctx, at, 0, {t.fill.r, t.fill.g, t.fill.b, u8(u32(t.fill.a) * u32(alpha) / 255)})
	note := "Loading" if img.failed == "" else fmt.tprintf("Cannot show %s: %s", img.name, img.failed)
	ui.text(ctx, ui.text_fit(ctx, note, t.small_size, at.w - t.gap), at.x + at.w * 0.5, at.y + at.h * 0.5, t.small_size, t.text_tertiary, .Regular, .Center)
}

// The board's ground, its pictures and notes, and the picked ones' outlines and corner (or
// the cropped one whole, faint, with its crop's edges), clipped to `r` by the container it
// is drawn in.
@(private = "file")
board_draw :: proc(app: ^App, r: ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	b := &k.board
	ui.fill_rect(ctx, r, t.radius_medium, t.pane)
	refs := &app.scene.refs
	if len(refs.refs) == 0 {
		ui.icon(ctx, ICON_REFERENCES, {r.x + r.w * 0.5, r.y + r.h * 0.5 - t.target * 0.5}, t.icon_small * 2, t.text_tertiary)
		line := "Add pictures, paste one, or drop image files here"
		ui.text(ctx, ui.text_fit(ctx, line, t.small_size, r.w - 2 * t.gap), r.x + r.w * 0.5, r.y + r.h * 0.5 + t.gap, t.small_size, t.text_secondary, .Regular, .Center)
		return
	}
	for &p in refs.refs {
		at := board_rect(b, r, p)
		if p.id == b.cropping {
			// The whole picture faint under its crop, so the edges have somewhere to go.
			full_at, full_size := ref_full(p)
			whole := p
			whole.at, whole.size, whole.crop_lo, whole.crop_hi = full_at, full_size, 0, 1
			board_picture(app, r, whole, 70)
		}
		if ui.rect_intersect(at, r).w <= 0 || ui.rect_intersect(at, r).h <= 0 do continue
		if p.image == 0 {
			ui.fill_rect(ctx, at, t.radius_small * board_zoom(b), t.surface_raised)
			size := p.size.y * 0.45 * board_zoom(b)
			if size >= 4 {
				text := ui.text_fit(ctx, ref_note_text(&p), size, at.w - size)
				ui.text(ctx, text, at.x + size * 0.5, at.y + at.h * 0.5, size, t.text, .Regular, .Left)
			}
		} else do board_picture(app, r, p, 255)
		if p.locked && at.w > t.icon_small * 2 && at.h > t.icon_small * 2 {
			ui.icon(ctx, ICON_LOCK, {at.x + at.w - t.icon_small, at.y + t.icon_small}, t.icon_small, t.text_secondary)
		}
	}
	for p in refs.refs {
		if !board_picked(b, p.id) do continue
		at := board_rect(b, r, p)
		ui.stroke_rect(ctx, at, 0, t.accent, 2)
		if p.id == b.cropping {
			// Each edge's middle and each corner, where a finger takes it.
			for e in ([?][2]f32{{0, 0}, {0.5, 0}, {1, 0}, {1, 0.5}, {1, 1}, {0.5, 1}, {0, 1}, {0, 0.5}}) {
				ui.fill_circle(ctx, {at.x + at.w * e.x, at.y + at.h * e.y}, board_corner(ctx) * 0.3, t.accent)
			}
		} else if len(b.selected) == 1 && !p.locked {
			ui.fill_circle(ctx, {at.x + at.w, at.y + at.h}, board_corner(ctx) * 0.4, t.accent)
		}
	}
	z := int(math.round(board_zoom(b) * 100))
	ui.text(ctx, fmt.tprintf("%d%%", z), r.x + r.w - t.gap, r.y + r.h - t.gap, t.small_size, t.text_tertiary, .Regular, .Right)
}

// Picture place `p` on the board drawn at `r`, at opacity `alpha`.
@(private = "file")
board_picture :: proc(app: ^App, r: ui.Rect, p: Ref, alpha: u8) {
	refs_picture_draw(app, board_rect(&app.kit.board, r, p), p, alpha)
}

// The reach of a picked picture's corner, which sizes it: a finger's target.
board_corner :: proc(ctx: ^ui.Context) -> f32 {
	return ctx.theme.target * 0.5
}

// The crop edges of the place drawn at `at` within reach of screen point `p`
// (CROP_LEFT and the others; two at a corner), or 0.
@(private = "file")
crop_edges_at :: proc(ctx: ^ui.Context, at: ui.Rect, p: [2]f32) -> u8 {
	reach := board_corner(ctx)
	if p.x < at.x - reach || p.x > at.x + at.w + reach || p.y < at.y - reach || p.y > at.y + at.h + reach do return 0
	edges: u8
	if abs(p.x - at.x) <= reach do edges |= CROP_LEFT
	else if abs(p.x - at.x - at.w) <= reach do edges |= CROP_RIGHT
	if abs(p.y - at.y) <= reach do edges |= CROP_TOP
	else if abs(p.y - at.y - at.h) <= reach do edges |= CROP_BOTTOM
	return edges
}

// The board's input on area `a`: two fingers pan and pinch, the wheel zooms about the
// pointer, a press on a picture picks it (Shift adds or takes it from the picked ones)
// and drags the picked ones, a press on the picked one's corner sizes it (on a cropped
// one's edges, crops it), a press on the ground clears the picks and pans, a double tap on
// the ground fits everything. A locked place is picked but a drag on it pans. A drag that
// moved, sized or cropped places is one undo step when it lets go.
@(private = "file")
board_input :: proc(app: ^App, a: ui.Area) {
	k := &app.kit
	ctx := &k.ctx
	b := &k.board
	room := a.rect
	refs := &app.scene.refs
	fingers := &app.touch.fingers
	if fingers.count >= 2 && (a.held || b.spread > 0) {
		// The fingers are in window coordinates; the board is in points.
		scale := max(k.scale, 1e-3)
		middle: [2]f32
		for d in fingers.down[:2] do middle += d.at / (2 * scale)
		spread := max(abs(fingers.down[0].at.x - fingers.down[1].at.x) + abs(fingers.down[0].at.y - fingers.down[1].at.y), 1) / scale
		if b.spread > 0 {
			b.pan -= (middle - b.middle) / board_zoom(b)
			board_zoom_about(b, room, middle, spread / b.spread)
		}
		b.spread, b.middle = spread, middle
		// A pinch ends any drag a finger began, putting the pictures back where it found them.
		if b.drag == .Move || b.drag == .Size || b.drag == .Crop do board_drag_cancel(app)
		b.drag = .None
		return
	}
	b.spread = 0
	if a.hovered && ctx.input.wheel != 0 do board_zoom_about(b, room, a.mouse, math.pow(f32(BOARD_WHEEL_STEP), ctx.input.wheel))
	if a.pressed {
		b.last = a.mouse
		hit := -1
		for i := len(refs.refs) - 1; i >= 0; i -= 1 {
			at := board_rect(b, room, refs.refs[i])
			if a.mouse.x >= at.x && a.mouse.x < at.x + at.w && a.mouse.y >= at.y && a.mouse.y < at.y + at.h {
				hit = i
				break
			}
		}
		corner := false
		b.edges = 0
		if one := board_one(app); one != nil && !one.locked {
			at := board_rect(b, room, one^)
			if one.id == b.cropping {
				b.edges = crop_edges_at(ctx, at, a.mouse)
			} else {
				d := a.mouse - [2]f32{at.x + at.w, at.y + at.h}
				corner = d.x * d.x + d.y * d.y <= board_corner(ctx) * board_corner(ctx)
			}
		}
		switch {
		case app.ui.eyedrop_armed && hit >= 0 && refs.refs[hit].image != 0:
			// The Eyedropper waiting for its press takes the picture's colour.
			app.ui.eyedrop_armed = false
			refs_pick_color(app, refs.refs[hit], board_rect(b, room, refs.refs[hit]), a.mouse)
			b.drag = .None
		case b.edges != 0:
			b.drag = .Crop
		case corner:
			b.drag = .Size
		case hit >= 0:
			id := refs.refs[hit].id
			if ctx.input.shift {
				if board_picked(b, id) {
					for s, j in b.selected do if s == id {
						ordered_remove(&b.selected, j)
						break
					}
				} else do append(&b.selected, id)
			} else if !board_picked(b, id) {
				clear(&b.selected)
				append(&b.selected, id)
			}
			b.drag = .Move if board_picked(b, id) && !refs.refs[hit].locked else .Pan
		case:
			if !ctx.input.shift do clear(&b.selected)
			b.drag = .Pan
		}
		if b.drag == .Move || b.drag == .Size || b.drag == .Crop {
			delete(b.before)
			b.before = refs_clone(refs.refs[:])
		}
	}
	if a.held && a.mouse != b.last {
		d := a.mouse - b.last
		z := board_zoom(b)
		switch b.drag {
		case .None:
		case .Pan:
			b.pan -= d / z
		case .Move:
			for &p in refs.refs do if board_picked(b, p.id) && !p.locked do p.at += d / z
		case .Size:
			if p := board_one(app); p != nil {
				// The corner follows the pointer along the picture's diagonal, so it keeps its shape.
				grow := (d.x * p.size.x + d.y * p.size.y) / max(p.size.x * p.size.x + p.size.y * p.size.y, 1e-6) / z
				f := max(1 + grow, REF_MIN_SIDE / max(min(p.size.x, p.size.y), 1e-6))
				p.size *= f
			}
		case .Crop:
			if p := board_one(app); p != nil do board_crop_drag(p, board_point(b, room, a.mouse), b.edges)
		}
		b.last = a.mouse
	}
	if !a.held && b.drag == .Move && b.before != nil && board_pin_drop(app, room, a.mouse) do b.drag = .None
	if !a.held && b.drag != .None {
		if (b.drag == .Move || b.drag == .Size || b.drag == .Crop) && b.before != nil {
			if !slice.equal(b.before, refs.refs[:]) {
				names := [Ref_Drag]string{.None = "", .Pan = "", .Move = "Move reference", .Size = "Size reference", .Crop = "Crop reference"}
				history_record_refs(app, b.before, names[b.drag])
				b.moves += 1
			} else do delete(b.before)
			b.before = nil
		}
		b.drag = .None
	}
	if a.clicked && b.drag == .None && len(b.selected) == 0 && handle_double_tap(ctx, &b.tap, a.id) do board_fit(app, room)
}

// board_crop_drag for the tests.
board_crop_test_drag :: proc(p: ^Ref, at: [2]f32, edges: u8) {
	board_crop_drag(p, at, edges)
}

// A picture dragged off the board and let go over the view stands there over the view,
// its place on the board as it was: one undo step. False when the drop is not over the
// view or more than one picture is dragged.
@(private = "file")
board_pin_drop :: proc(app: ^App, room: ui.Rect, at: [2]f32) -> bool {
	k := &app.kit
	main := k.grid.main
	if ui.rect_contains(room, at) || !ui.rect_contains(main, at) || main.w <= 0 do return false
	one := board_one(app)
	if one == nil || one.image == 0 do return false
	id := one.id
	board_drag_cancel(app)
	before := refs_clone(app.scene.refs.refs[:])
	p := &app.scene.refs.refs[ref_index(&app.scene.refs, id)]
	p.view = true
	r := refs_view_rect(main, p^)
	// Its middle where it was let go.
	p.view_at = {(at.x - r.w * 0.5 - main.x) / main.w, (at.y - r.h * 0.5 - main.y) / main.h}
	history_record_refs(app, before, "Reference on view")
	return true
}

// Moves crop edges `edges` of place `p` to board point `at`, within the whole picture
// and leaving at least REF_MIN_SIDE between them; what stays keeps its place on the board.
@(private = "file")
board_crop_drag :: proc(p: ^Ref, at: [2]f32, edges: u8) {
	full_at, full_size := ref_full(p^)
	lo, hi := ref_crop_shown(p^)
	f := (at - full_at) / full_size
	least := REF_MIN_SIDE / full_size
	if edges & CROP_LEFT != 0 do lo.x = clamp(f.x, 0, hi.x - least.x)
	if edges & CROP_RIGHT != 0 do hi.x = clamp(f.x, lo.x + least.x, 1)
	if edges & CROP_TOP != 0 do lo.y = clamp(f.y, 0, hi.y - least.y)
	if edges & CROP_BOTTOM != 0 do hi.y = clamp(f.y, lo.y + least.y, 1)
	ref_crop_set(p, lo, hi)
	p.at = full_at + lo * full_size
	p.size = (hi - lo) * full_size
}

// The least side a picture is sized down to, in board points.
REF_MIN_SIDE :: 16

// Puts the pictures a drag moved back where it found them.
@(private = "file")
board_drag_cancel :: proc(app: ^App) {
	b := &app.kit.board
	if b.before == nil do return
	clear(&app.scene.refs.refs)
	append(&app.scene.refs.refs, ..b.before)
	delete(b.before)
	b.before = nil
}

// Lucide's image-plus, clipboard-paste, scan and trash-2, image-down, sticky-note,
// layout-dashboard, stretch-vertical, flip-horizontal, sun-moon, rotate-cw-square and
// crop, for the card's actions.
ICON_IMAGE_PLUS :: rune(0xe1f7)
ICON_CLIPBOARD_PASTE :: rune(0xe3ec)
ICON_SCAN :: rune(0xe257)
ICON_TRASH_2 :: rune(0xe18e)
ICON_IMAGE_DOWN :: rune(0xe541)
ICON_STICKY_NOTE :: rune(0xe303)
ICON_LAYOUT_DASHBOARD :: rune(0xe1c1)
ICON_STRETCH_VERTICAL :: rune(0xe27d)
ICON_FLIP_PICTURE :: rune(0xe361)
ICON_GREY :: rune(0xe2b2)
ICON_TURN :: rune(0xe5d6)
ICON_CROP :: rune(0xe0af)
ICON_ON_VIEW :: rune(0xe3b3) // picture-in-picture-2
