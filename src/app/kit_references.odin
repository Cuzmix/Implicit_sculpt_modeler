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
// pointer, and a double tap on the ground fits everything; a mouse's left drag on the
// ground boxes places, its middle button pans and its right (or a finger's long press)
// opens the board's menu, as PureRef's. The board fills the card: the head's Add asks for
// pictures and its ⋯ adds the rest (the clipboard, the view itself, a note) and tidies
// (Arrange, Same height, Fit all, the ground), the edits float over the picked places
// (Flip, Grey, Turn, Crop, In scene, and More with Lock, Send to back and Delete), and
// under the board, only while something is picked, are
// where the pictures show (On view, In scene, Behind or Through, Opacity) or a note's text. The pictures are drawn by the interface from their GPU copies
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
	// In the scene (refs_planes.odin): the drag under way on a picked plane, which, and
	// where the pointer was; and the In scene menu, open beside its button.
	plane_drag:    Ref_Drag,
	plane_id:      u32,
	plane_last:    [2]f32,
	plane_menu:    bool,
	plane_menu_at: ui.Rect,
	// Line up (refs_planes.odin): which of a picked plane's marks a drag moves (1 its brow,
	// 2 its chin, 0 none) and whose, and how many line ups changed a plane, for the exit stats.
	mark:          int,
	mark_id:       u32,
	lined_up:      int,
	// The head's Add and Tidy menus, the floating edits' More, and the board's menu at the
	// pointer (a right click), with where the open one hangs from.
	add_menu:      bool,
	board_more:    bool,
	more_menu:     bool,
	board_menu:    bool,
	menu_at:       ui.Rect,
	// The board as laid out this frame for what is laid out after the cards: the frame it
	// was (k.frame), the part of it in sight and where the picked places stand, in points.
	board_frame:   int,
	shown:         ui.Rect,
	picked_at:     ui.Rect,
	// A middle drag panning the board, and a box drag's corner where it began and the
	// places picked before it (shift adds the box's to them).
	middle_pan:    bool,
	box_from:      [2]f32,
	box_base:      [dynamic]u32,
	// The press under way raised the picked places (its `before` is the order it found)
	// and its drag moved them; a raise over the view waits for the view's loop to end.
	raised:        bool,
	moved:         bool,
	view_raise:    u32,
	// Asks for pictures from files and from Photos, for the exit stats.
	asked_files:   int,
	asked_photos:  int,
	// Two fingers on the board: the angle between them last frame. Over the view
	// (refs_touch_gesture): the place two fingers turn, whether this touch was already
	// decided, the places before it began (owned), and how many changed one.
	twist:          f32,
	gesture_id:     u32,
	gesture_tried:  bool,
	gesture_before: []Ref,
	turns:          int,
}

CROP_LEFT :: 1
CROP_RIGHT :: 2
CROP_TOP :: 4
CROP_BOTTOM :: 8

// What the board's ground shows under the pictures, as a canvas in React Flow or Figma
// does: a dot at each grid point, the grid's lines, or nothing. The grid moves and scales
// with the board, so it tells a pan and a zoom at a glance.
Ref_Ground :: enum u8 {
	Dots,
	Lines,
	Plain,
}

// The grid's step in board points, and the least gap on screen its dots or lines keep: a
// board zoomed out far enough doubles the step until they are that far apart.
BOARD_GRID_STEP :: 24
BOARD_GRID_MIN :: 12

Ref_Drag :: enum u8 {
	None,
	Pan,
	Move,
	Size,
	Crop,
	Box, // a mouse's left drag from the ground, picking what its box touches
	Turn, // two fingers on a picked place, pinching and twisting the picked ones
}

// How wide the card is: a board two pictures across beside the model, as every card is
// wide; the edits float over the board, so no row of them sets the width.
REFS_CARD_W :: CARD_W
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
// place (notes too) as the first is not. The In scene menu's: Behind and Through draw
// the picked planes behind or through the model, Plane_Any shows them from any side, or
// only in their view, as the first is not.
Ref_Edit :: enum u8 {
	Flip,
	Grey,
	Turn,
	Lock,
	View,
	Behind,
	Through,
	Plane_Any,
	Straighten,
	View_Lock,
}

refs_edit :: proc(app: ^App, edit: Ref_Edit) {
	refs := &app.scene.refs
	b := &app.kit.board
	first: Maybe(Ref)
	planes := edit == .Behind || edit == .Through || edit == .Plane_Any
	for r in refs.refs do if board_picked(b, r.id) && (r.image != 0 || edit == .Lock) && (!planes || r.plane != .None) {
		first = r
		break
	}
	f, ok := first.?
	if !ok do return
	before := refs_clone(refs.refs[:])
	for &r in refs.refs {
		if !board_picked(b, r.id) || (r.image == 0 && edit != .Lock) || (planes && r.plane == .None) do continue
		switch edit {
		case .Flip:
			r.flip = !f.flip
		case .Grey:
			r.grey = !f.grey
		case .Lock:
			r.locked = !f.locked
		case .View:
			r.view = !f.view
		case .Behind:
			r.through = false
		case .Through:
			r.through = true
		case .Plane_Any:
			r.plane_any = !f.plane_any
		case .Straighten:
			r.angle, r.view_angle = 0, 0
		case .View_Lock:
			r.view_locked = !f.view_locked
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
	names := [Ref_Edit]string{.Flip = "Flip reference", .Grey = "Grey reference", .Turn = "Turn reference", .Lock = "Lock reference", .View = "Reference on view", .Behind = "Reference behind the model", .Through = "Reference through the model", .Plane_Any = "Reference shown from any side", .Straighten = "Straighten reference", .View_Lock = "Lock reference on view"}
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

// The References card's body, `inner` wide and at most `room` tall: the board, filling
// the card, and under it, only while something is picked, where the picked pictures show
// (On view, In scene with its view, Behind or Through) and their Opacity, or a picked
// note's text. Adding and tidying are the head's menus (refs_head_buttons) and the edits
// float over the picked places (refs_float_bar).
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
	one := board_one(app)
	note := one != nil && one.image == 0
	pictures := false
	for r in refs.refs do if board_picked(b, r.id) && r.image != 0 do pictures = true
	// The picked places over the view or in the scene: their opacity, the first one's
	// shown, set on all.
	viewed: ^Ref
	for &r in refs.refs do if board_picked(b, r.id) && (r.view || r.plane != .None) && r.image != 0 {
		viewed = &r
		break
	}
	rows: f32 = 0
	if note || pictures do rows += 1
	if !note && viewed != nil do rows += 1
	board_h := max(room - rows * (t.target + t.gap), BOARD_MIN_H)
	// Drawn inside its container, whose clip keeps a picture or note zoomed past the
	// board's edge from spilling over the card and the view.
	ui.begin(ctx, "refs board", {width = inner, height = board_h, clip = true, radius = t.radius_medium})
	a := ui.area(ctx, "board", {inner, board_h})
	r := a.rect
	// The first time it is shown with pictures on it, the board fits them.
	if b.zoom <= 0 && filled do board_fit(app, r)
	b.room = r
	board_input(app, a)
	board_draw(app, r)
	// Where the floating edits go (refs_float_bar, after the cards): over the picked
	// places as the board shows them, inside the part of the board in sight.
	d := ctx.input.pixel_density
	b.shown = ui.rect_intersect(r, {ctx.clip.x / d, ctx.clip.y / d, ctx.clip.w / d, ctx.clip.h / d})
	b.picked_at = {}
	for p in refs.refs do if board_picked(b, p.id) {
		at := board_rect(b, r, p)
		b.picked_at = at if b.picked_at.w <= 0 else ui.rect_union(b.picked_at, at)
	}
	b.board_frame = k.frame
	ui.end(ctx)
	if note {
		// A note's text, typed in its own buffer and put on the note as it changes, one undo step a typing.
		if b.note_id != one.id do refs_note_commit(app)
		// Unless typing is under way, the field shows the note as it is, an undo's too.
		if b.note_id != one.id || b.note_before == nil do b.note = one.text
		b.note_id = one.id
		ui.begin(ctx, "refs note", {direction = .Row, width = inner, gap = t.gap, center = true})
		if ui.text_field(ctx, "note text##refs", b.note[:REF_NOTE_MAX - 1], inner, hint = "Note") {
			if b.note_before == nil do b.note_before = refs_clone(refs.refs[:])
			one.text = b.note
			app.scene_edits += 1
		}
		ui.end(ctx)
		if ctx.text_focus != ui.id_of(ctx, "note text##refs") do refs_note_commit(app)
	} else {
		refs_note_commit(app)
		b.note_id = 0
	}
	if !note && pictures {
		ui.begin(ctx, "refs places", {direction = .Row, width = inner, gap = t.gap, center = true})
		on_view := refs_picked_all(app, proc(r: Ref) -> bool {return r.image == 0 || r.view})
		if refs_chip(ctx, "On view##refs", ICON_ON_VIEW, "On view", on_view, false) do refs_edit(app, .View)
		plane, in_scene := refs_picked_plane(app)
		words := "In scene"
		if in_scene do words = REF_PLANE_NAMES[plane] if plane != .None else "Mixed"
		if refs_chip(ctx, "In scene##refs view", ICON_REF_PLANE, words, in_scene || b.plane_menu, true) {
			b.plane_menu, b.plane_menu_at = !b.plane_menu, ctx.last_rect
		}
		if in_scene {
			through := refs_picked_all(app, proc(r: Ref) -> bool {return r.image == 0 || r.plane == .None || r.through})
			if refs_chip(ctx, "Behind or through##refs", 0, "Through" if through else "Behind", through, false) do refs_edit(app, .Behind if through else .Through)
		}
		ui.end(ctx)
	}
	if !note && viewed != nil {
		value := viewed.opacity * 100
		ui.begin(ctx, "refs view", {direction = .Row, width = inner, gap = t.gap, center = true})
		if ui.slider(ctx, "Opacity##refs", &value, REF_OPACITY_MIN * 100, 100, .Linear, fmt.tprintf("%.0f%%", value)) {
			if b.opacity_before == nil do b.opacity_before = refs_clone(refs.refs[:])
			for &p in refs.refs do if board_picked(b, p.id) && (p.view || p.plane != .None) && p.image != 0 do p.opacity = value / 100
			app.scene_edits += 1
		}
		ui.end(ctx)
	}
	if b.opacity_before != nil && .Left not_in ctx.input.down {
		if slice.equal(b.opacity_before, refs.refs[:]) do delete(b.opacity_before)
		else do history_record_refs(app, b.opacity_before, "Reference opacity")
		b.opacity_before = nil
	}
}

// A chip under the board: `glyph` (none for 0) and `words`, lit while `on`, with a
// chevron after them when it opens a menu. `name` is its id and tooltip. Returns true
// when tapped.
@(private = "file")
refs_chip :: proc(ctx: ^ui.Context, name: string, glyph: rune, words: string, on, menu: bool) -> bool {
	t := ctx.theme
	w := ui.text_width(ctx, words, t.small_size, .Semibold) + 2 * ui.SPACE_L
	if glyph != 0 do w += t.icon_small + ui.SPACE_S
	if menu do w += ui.SPACE_L
	a := ui.area(ctx, name, {w, t.target}, drag = false)
	vis := ui.Rect{a.rect.x, a.rect.y + (a.rect.h - t.control) * 0.5, a.rect.w, t.control}
	ui.fill_rect(ctx, vis, t.radius_large, t.accent_soft if on else (t.fill_hover if a.hovered else t.fill))
	ink := t.accent if on else t.text_secondary
	x := vis.x + ui.SPACE_L
	y := vis.y + vis.h * 0.5
	if glyph != 0 {
		ui.icon(ctx, glyph, {x + t.icon_small * 0.5, y}, t.icon_small, ink)
		x += t.icon_small + ui.SPACE_S
	}
	ui.text(ctx, words, x, y, t.small_size, ink, .Semibold)
	if menu do ui.more_chevron(ctx, {vis.x + vis.w - ui.SPACE_L, y}, ink)
	ui.tip(ctx, a.id, vis, ui.label_text(name))
	return a.clicked
}

// The References card's head buttons, before Pin and Close: Add, which opens the file
// dialog (on the iPad, a choice of Photos and Files: refs_add_ask), and ⋯, the board's
// menu of what else adds (a pasted picture, the view itself, a note) and what tidies.
refs_head_buttons :: proc(app: ^App) {
	ctx := &app.kit.ctx
	b := &app.kit.board
	if ui.icon_button(ctx, "Add##refs", ui.ICON_PLUS, selected = b.add_menu, size = REFS_HEAD_BUTTON) do refs_add_ask(app, ctx.last_rect)
	if ui.icon_button(ctx, "More##refs head", ui.ICON_MORE, selected = b.board_more, size = REFS_HEAD_BUTTON) do b.board_more, b.menu_at = !b.board_more, ctx.last_rect
}

// The head buttons' width, for the head to leave room for them.
refs_head_width :: proc(ctx: ^ui.Context) -> f32 {
	return 2 * REFS_HEAD_BUTTON
}

// How big each head button is: a touch target a little under the panels', so the title
// still fits beside them, Pin and Close on a card of the usual width.
REFS_HEAD_BUTTON :: 40

// How big each of the floating edits' buttons is: a touch target, a little smaller than
// the panels' so the row fits over a picture on the narrow card.
REFS_FLOAT_BUTTON :: 44

// The edits floating over the picked places, as a board in PureRef or a canvas in Figma
// keeps them by what they act on: Flip, Grey, Turn, Crop and In scene for pictures, and
// More, which holds Lock and Delete, for any place. Above the picked places where the
// board has room, else under them, else at the board's top; hidden while a drag moves,
// sizes or crops them, or two fingers zoom. Laid out after the cards, as its own panel
// over the card, so a press on it is its own and never the board's.
@(private = "file")
refs_float_bar :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	b := &k.board
	if b.board_frame != k.frame || len(b.selected) == 0 || b.picked_at.w <= 0 || b.shown.w <= 0 do return
	if b.drag == .Move || b.drag == .Size || b.drag == .Crop || b.spread > 0 do return
	if ui.rect_intersect(b.picked_at, b.shown).w <= 0 do return
	one := board_one(app)
	pictures := false
	for r in app.scene.refs.refs do if board_picked(b, r.id) && r.image != 0 do pictures = true
	count: f32 = 6 if pictures else 1
	size := [2]f32{count * REFS_FLOAT_BUTTON + 2 * ui.SPACE_2XS, REFS_FLOAT_BUTTON + 2 * ui.SPACE_2XS}
	s, p := b.shown, b.picked_at
	pos := [2]f32{p.x, p.y - size.y - ui.SPACE_S}
	if pos.y < s.y + ui.SPACE_XS do pos.y = p.y + p.h + ui.SPACE_S
	if pos.y + size.y > s.y + s.h - ui.SPACE_XS do pos.y = s.y + ui.SPACE_XS
	pos.x = clamp(pos.x, s.x + ui.SPACE_XS, max(s.x + s.w - size.x - ui.SPACE_XS, s.x + ui.SPACE_XS))
	ui.begin_at(ctx, "refs edits", pos, {direction = .Row, gap = 0, padding = ui.SPACE_2XS, radius = t.radius_large, background = .Raised, center = true})
	if pictures {
		if ui.icon_button(ctx, "Flip##refs", ICON_FLIP_PICTURE, selected = refs_picked_all(app, proc(r: Ref) -> bool {return r.image == 0 || r.flip}), size = REFS_FLOAT_BUTTON) do refs_edit(app, .Flip)
		if ui.icon_button(ctx, "Grey##refs", ICON_GREY, selected = refs_picked_all(app, proc(r: Ref) -> bool {return r.image == 0 || r.grey}), size = REFS_FLOAT_BUTTON) do refs_edit(app, .Grey)
		if ui.icon_button(ctx, "Turn##refs", ICON_TURN, size = REFS_FLOAT_BUTTON) do refs_edit(app, .Turn)
		crop_ok := one != nil && one.image != 0 && !one.locked
		if ui.icon_button(ctx, "Crop##refs", ICON_CROP, selected = b.cropping != 0, enabled = crop_ok, size = REFS_FLOAT_BUTTON) do b.cropping = 0 if b.cropping != 0 else one.id
		_, in_scene := refs_picked_plane(app)
		if ui.icon_button(ctx, "In scene##refs", ICON_REF_PLANE, selected = in_scene, size = REFS_FLOAT_BUTTON) {
			refs_plane_put(app, .None if in_scene else refs_plane_facing(app))
		}
	}
	if ui.icon_button(ctx, "More##refs", ui.ICON_MORE, selected = b.more_menu, size = REFS_FLOAT_BUTTON) do b.more_menu, b.menu_at = !b.more_menu, ctx.last_rect
	ui.end(ctx)
}

// The empty board's Add image, in its middle: it asks for pictures as the head's Add
// does. Laid out after the cards, as the floating
// edits are, so a press on it is its own and never the board's.
@(private = "file")
refs_empty_add :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	b := &k.board
	if b.board_frame != k.frame || len(app.scene.refs.refs) > 0 || b.shown.w <= 0 do return
	label := "Add image"
	w := ui.text_width(ctx, label, t.text_size, .Semibold) + t.icon_small + 6 + 28
	r := b.room
	pos := [2]f32{r.x + (r.w - w) * 0.5, r.y + (r.h - t.target) * 0.5}
	if pos.y < b.shown.y || pos.y + t.target > b.shown.y + b.shown.h do return
	ui.begin_at(ctx, "refs empty", pos, {direction = .Row})
	if ui.button(ctx, "Add image##refs empty", .Solid, .Accent, width = w, glyph = ui.ICON_PLUS) do refs_add_ask(app, ctx.last_rect)
	ui.end(ctx)
}

// The References card's floating edits and menus, laid out after the cards so they are
// over them: the edits over the picked places, Add's choice and the board's ⋯ menu from the
// head, More from the edits and the In scene menu from its chip. All shut with the card.
refs_card_menus :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	b := &k.board
	if !card_shown(app, .References) {
		b.add_menu, b.board_more, b.more_menu, b.board_menu, b.plane_menu = false, false, false, false, false
		return
	}
	refs_float_bar(app)
	refs_empty_add(app)
	refs := &app.scene.refs
	box := ui.Box{direction = .Column, gap = 0, padding = ui.MENU_PAD, width = ui.MENU_W}
	// The iPad's choice of where pictures come from: two big tiles, as Nomad's.
	if ui.popover_begin(ctx, "refs add choice", &b.add_menu, b.menu_at, .Below_End, {direction = .Row, gap = ui.SPACE_S, padding = ui.SPACE_S}) {
		if refs_choice_tile(ctx, "Photos##refs add", ICON_IMAGES, "Photos from your library, several at once") {
			refs_ask_photos(app)
			b.add_menu = false
		}
		if refs_choice_tile(ctx, "Files##refs add", ui.ICON_FOLDER, "Pictures from your files") {
			refs_ask_files(app)
			b.add_menu = false
		}
		ui.popover_end(ctx)
	}
	if ui.popover_begin(ctx, "refs board more", &b.board_more, b.menu_at, .Below_End, box) {
		if ui.menu_item(ctx, "Paste picture##refs more", glyph = ICON_CLIPBOARD_PASTE, hint = "The picture on the clipboard") {
			_ = refs_paste(app)
			b.board_more = false
		}
		if ui.menu_item(ctx, "Snap view##refs more", glyph = ICON_IMAGE_DOWN, hint = "The view as it is now, as a picture") {
			b.snap = true
			b.board_more = false
		}
		if ui.menu_item(ctx, "Add note##refs more", glyph = ICON_STICKY_NOTE) {
			refs_add_note(app)
			b.board_more = false
		}
		ui.divider(ctx, across = true)
		if ui.menu_item(ctx, "Arrange##refs tidy", glyph = ICON_LAYOUT_DASHBOARD, enabled = len(refs.refs) > 1, hint = "Packed into rows, tallest first") {
			refs_arrange(app)
			b.board_more = false
		}
		if ui.menu_item(ctx, "Same height##refs tidy", glyph = ICON_STRETCH_VERTICAL, enabled = len(refs.refs) > 1) {
			refs_same_height(app)
			b.board_more = false
		}
		if ui.menu_item(ctx, "Fit all##refs tidy", glyph = ICON_SCAN, enabled = len(refs.refs) > 0) {
			board_fit(app, b.room)
			b.board_more = false
		}
		ui.divider(ctx, across = true)
		// The ground stays a choice of this device, as a canvas app's is, not the scene's.
		grounds := [Ref_Ground]string{.Dots = "Dots##refs ground", .Lines = "Lines##refs ground", .Plain = "Plain##refs ground"}
		for name, g in grounds {
			if ui.menu_item(ctx, name, checked = k.refs_ground == g, hint = "The board's background" if g == .Dots else "") {
				k.refs_ground = g
				b.board_more = false
			}
		}
		ui.popover_end(ctx)
	}
	if ui.popover_begin(ctx, "refs more menu", &b.more_menu, b.menu_at, .Below_End, box) {
		locked := refs_picked_all(app, proc(r: Ref) -> bool {return r.locked})
		if ui.menu_item(ctx, "Unlock##refs more" if locked else "Lock##refs more", glyph = ICON_LOCK if locked else ICON_LOCK_OPEN, enabled = len(b.selected) > 0, hint = "" if locked else "Kept where it is: a drag on it pans") {
			refs_edit(app, .Lock)
			b.more_menu = false
		}
		if ui.menu_item(ctx, "Send to back##refs more", glyph = ICON_SEND_TO_BACK, enabled = len(b.selected) > 0, hint = "Under the others; picking one brings it to the front") {
			refs_send_back_selected(app)
			b.more_menu = false
		}
		refs_turn_items(app, &b.more_menu)
		if ui.menu_item(ctx, "Delete##refs more", glyph = ICON_TRASH_2, tone = .Danger, enabled = len(b.selected) > 0) {
			refs_delete_selected(app)
			b.more_menu = false
		}
		ui.popover_end(ctx)
	}
	refs_board_menu(app)
	refs_plane_menu(app)
}

// The board's menu at the pointer, a right click's or a finger's or the pen's long press,
// as PureRef's and an iPad app's: the picked places' edits when some are picked, then what
// adds and what tidies.
@(private = "file")
refs_board_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	b := &k.board
	refs := &app.scene.refs
	if !ui.popover_begin(ctx, "refs board menu", &b.board_menu, b.menu_at, .Pointer, {direction = .Column, gap = 0, padding = ui.MENU_PAD, width = ui.MENU_W}) do return
	defer ui.popover_end(ctx)
	one := board_one(app)
	pictures := false
	for r in refs.refs do if board_picked(b, r.id) && r.image != 0 do pictures = true
	if pictures {
		if ui.menu_item(ctx, "Flip##refs board", glyph = ICON_FLIP_PICTURE, checked = refs_picked_all(app, proc(r: Ref) -> bool {return r.image == 0 || r.flip})) {
			refs_edit(app, .Flip)
			b.board_menu = false
		}
		if ui.menu_item(ctx, "Grey##refs board", glyph = ICON_GREY, checked = refs_picked_all(app, proc(r: Ref) -> bool {return r.image == 0 || r.grey})) {
			refs_edit(app, .Grey)
			b.board_menu = false
		}
		if ui.menu_item(ctx, "Turn##refs board", glyph = ICON_TURN) {
			refs_edit(app, .Turn)
			b.board_menu = false
		}
		if ui.menu_item(ctx, "Crop##refs board", glyph = ICON_CROP, checked = b.cropping != 0, enabled = one != nil && one.image != 0 && !one.locked) {
			b.cropping = 0 if b.cropping != 0 else one.id
			b.board_menu = false
		}
		if ui.menu_item(ctx, "On view##refs board", glyph = ICON_ON_VIEW, checked = refs_picked_all(app, proc(r: Ref) -> bool {return r.image == 0 || r.view})) {
			refs_edit(app, .View)
			b.board_menu = false
		}
		_, in_scene := refs_picked_plane(app)
		if ui.menu_item(ctx, "In scene##refs board", glyph = ICON_REF_PLANE, checked = in_scene, hint = "On a plane facing the view") {
			refs_plane_put(app, .None if in_scene else refs_plane_facing(app))
			b.board_menu = false
		}
	}
	if len(b.selected) > 0 {
		locked := refs_picked_all(app, proc(r: Ref) -> bool {return r.locked})
		if ui.menu_item(ctx, "Unlock##refs board" if locked else "Lock##refs board", glyph = ICON_LOCK if locked else ICON_LOCK_OPEN) {
			refs_edit(app, .Lock)
			b.board_menu = false
		}
		if ui.menu_item(ctx, "Send to back##refs board", glyph = ICON_SEND_TO_BACK) {
			refs_send_back_selected(app)
			b.board_menu = false
		}
		refs_turn_items(app, &b.board_menu)
		if ui.menu_item(ctx, "Delete##refs board", glyph = ICON_TRASH_2, tone = .Danger) {
			refs_delete_selected(app)
			b.board_menu = false
		}
		ui.divider(ctx, across = true)
	}
	if ui.menu_item(ctx, "Add pictures##refs board", glyph = ICON_IMAGE_PLUS) {
		refs_ask_files(app)
		b.board_menu = false
	}
	if app.photos_picker && ui.menu_item(ctx, "Add from Photos##refs board", glyph = ICON_IMAGES) {
		refs_ask_photos(app)
		b.board_menu = false
	}
	if ui.menu_item(ctx, "Paste picture##refs board", glyph = ICON_CLIPBOARD_PASTE) {
		_ = refs_paste(app)
		b.board_menu = false
	}
	if ui.menu_item(ctx, "Snap view##refs board", glyph = ICON_IMAGE_DOWN) {
		b.snap = true
		b.board_menu = false
	}
	if ui.menu_item(ctx, "Add note##refs board", glyph = ICON_STICKY_NOTE) {
		refs_add_note(app)
		b.board_menu = false
	}
	ui.divider(ctx, across = true)
	if ui.menu_item(ctx, "Arrange##refs board", glyph = ICON_LAYOUT_DASHBOARD, enabled = len(refs.refs) > 1) {
		refs_arrange(app)
		b.board_menu = false
	}
	if ui.menu_item(ctx, "Fit all##refs board", glyph = ICON_SCAN, enabled = len(refs.refs) > 0) {
		board_fit(app, b.room)
		b.board_menu = false
	}
}

// The picture menus' Lock on view (while a picked picture is over the view) and
// Straighten (while one is turned on the board or the view), each closing menu `open`.
@(private = "file")
refs_turn_items :: proc(app: ^App, open: ^bool) {
	ctx := &app.kit.ctx
	b := &app.kit.board
	viewed, turned := false, false
	for r in app.scene.refs.refs do if board_picked(b, r.id) && r.image != 0 {
		viewed ||= r.view
		turned ||= r.angle != 0 || r.view_angle != 0
	}
	if viewed {
		locked := refs_picked_all(app, proc(r: Ref) -> bool {return r.image == 0 || !r.view || r.view_locked})
		if ui.menu_item(ctx, "Unlock on view##refs turn" if locked else "Lock on view##refs turn", glyph = ICON_LOCK if locked else ICON_LOCK_OPEN, hint = "" if locked else "Two fingers on it then turn the view") {
			refs_edit(app, .View_Lock)
			open^ = false
		}
	}
	if turned && ui.menu_item(ctx, "Straighten##refs turn", glyph = ICON_STRAIGHTEN, hint = "Upright again, on the board and the view") {
		refs_edit(app, .Straighten)
		open^ = false
	}
}

// Draws picture place `p` at screen rect `at`, at opacity `alpha`: its GPU copy cropped,
// flipped and turned (the grey copy once made, when grey), or a box saying it loads or
// why it cannot be shown.
refs_picture_draw :: proc(app: ^App, at: ui.Rect, p: Ref, alpha: u8, angle: f32 = 0) {
	ctx := &app.kit.ctx
	t := ctx.theme
	refs := &app.scene.refs
	slot := ref_image_slot(refs, p.image)
	img := refs.images[slot]
	img.seen = ctx.time
	if img.texture != 0 {
		id := KIT_REF_IMAGE + u64(slot)
		if p.grey && img.grey != 0 do id += REF_IMAGES_MAX
		if angle == 0 do ui.image_corners(ctx, at, id, ref_corners(p), {255, 255, 255, alpha})
		else do ui.image_quad(ctx, refs_turned(at, angle), id, ref_corners(p), {255, 255, 255, alpha})
		return
	}
	box := ui.Color{t.fill.r, t.fill.g, t.fill.b, u8(u32(t.fill.a) * u32(alpha) / 255)}
	if angle == 0 do ui.fill_rect(ctx, at, 0, box)
	else {
		corners := refs_turned(at, angle)
		ui.fill_convex(ctx, corners[:], box)
	}
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
	board_ground(app, r)
	refs := &app.scene.refs
	if len(refs.refs) == 0 {
		// Its middle holds Add image (refs_empty_add, laid out after the cards), the icon
		// over it and what else adds a picture under it.
		ui.icon(ctx, ICON_REFERENCES, {r.x + r.w * 0.5, r.y + r.h * 0.5 - 1.5 * t.target}, t.icon_small * 2, t.text_tertiary)
		line := "or paste one, or drop image files here"
		ui.text(ctx, ui.text_fit(ctx, line, t.small_size, r.w - 2 * t.gap), r.x + r.w * 0.5, r.y + r.h * 0.5 + t.target, t.small_size, t.text_secondary, .Regular, .Center)
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
		corners := refs_turned(at, board_angle(b, p))
		ui.polyline(ctx, corners[:], t.accent, 2, closed = true)
		if p.id == b.cropping {
			// Each edge's middle and each corner, where a finger takes it.
			for e in ([?][2]f32{{0, 0}, {0.5, 0}, {1, 0}, {1, 0.5}, {1, 1}, {0.5, 1}, {0, 1}, {0, 0.5}}) {
				ui.fill_circle(ctx, {at.x + at.w * e.x, at.y + at.h * e.y}, board_corner(ctx) * 0.3, t.accent)
			}
		} else if len(b.selected) == 1 && !p.locked {
			ui.fill_circle(ctx, corners[2], board_corner(ctx) * 0.4, t.accent)
		}
	}
	if b.drag == .Box {
		box := board_box(b)
		ui.fill_rect(ctx, box, 0, ui.color_fade(t.accent_soft, 0.5))
		ui.stroke_rect(ctx, box, 0, t.accent, 1)
	}
	z := int(math.round(board_zoom(b) * 100))
	ui.text(ctx, fmt.tprintf("%d%%", z), r.x + r.w - t.gap, r.y + r.h - t.gap, t.small_size, t.text_tertiary, .Regular, .Right)
}

// The board's ground at `r`: its grid's dots or lines, as Ref_Ground says, from the board
// point at its top left, fainter than anything on it.
@(private = "file")
board_ground :: proc(app: ^App, r: ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	b := &k.board
	if k.refs_ground == .Plain do return
	z := board_zoom(b)
	step := f32(BOARD_GRID_STEP)
	for step * z < BOARD_GRID_MIN do step *= 2
	gap := step * z
	// The first grid line at or past each edge, in screen points.
	first := [2]f32{r.x + (math.ceil(b.pan.x / step) * step - b.pan.x) * z, r.y + (math.ceil(b.pan.y / step) * step - b.pan.y) * z}
	ink := ui.color_fade(t.text_tertiary, 0.35)
	switch k.refs_ground {
	case .Plain:
	case .Dots:
		for y := first.y; y < r.y + r.h; y += gap {
			for x := first.x; x < r.x + r.w; x += gap do ui.fill_rect(ctx, {x - 0.75, y - 0.75, 1.5, 1.5}, 0, ink)
		}
	case .Lines:
		ink = ui.color_fade(t.text_tertiary, 0.18)
		for x := first.x; x < r.x + r.w; x += gap do ui.fill_rect(ctx, {x - 0.5, r.y, 1, r.h}, 0, ink)
		for y := first.y; y < r.y + r.h; y += gap do ui.fill_rect(ctx, {r.x, y - 0.5, r.w, 1}, 0, ink)
	}
}

// Picture place `p` on the board drawn at `r`, at opacity `alpha`, turned by its angle
// unless it is being cropped, which shows it upright.
@(private = "file")
board_picture :: proc(app: ^App, r: ui.Rect, p: Ref, alpha: u8) {
	b := &app.kit.board
	refs_picture_draw(app, board_rect(b, r, p), p, alpha, board_angle(b, p))
}

// The angle place `p` shows at on the board: none while cropped, and a note never turns.
board_angle :: proc(b: ^Ref_Board, p: Ref) -> f32 {
	return 0 if p.id == b.cropping || p.image == 0 else p.angle
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
	// A finger's or the pen's long press opens the board's menu where it is held, as a
	// right click does; called first, while the board's area is still the last widget.
	long := ctx.input.pointer != .Mouse && .Right not_in ctx.input.released && ui.secondary(ctx)
	if fingers.count >= 2 && (a.held || b.spread > 0) {
		// The fingers are in window coordinates; the board is in points.
		scale := max(k.scale, 1e-3)
		middle: [2]f32
		for d in fingers.down[:2] do middle += d.at / (2 * scale)
		spread := max(abs(fingers.down[0].at.x - fingers.down[1].at.x) + abs(fingers.down[0].at.y - fingers.down[1].at.y), 1) / scale
		v := fingers.down[1].at - fingers.down[0].at
		angle := math.atan2(v.y, v.x)
		if b.spread == 0 {
			// Fingers that land on a picked place (the first having taken it as a drag, or
			// both coming at once) pinch and twist the picked ones; elsewhere they pan and
			// zoom the board, and a drag a finger began is put back where it found them.
			hit := board_hit(app, room, fingers.down[0].start / scale)
			on_picked := hit >= 0 && board_picked(b, refs.refs[hit].id) && !refs.refs[hit].locked
			if b.drag == .Move || (b.drag == .None && on_picked) {
				if b.before == nil do b.before = refs_clone(refs.refs[:])
				b.drag = .Turn
			} else if b.drag != .Turn {
				if b.drag == .Size || b.drag == .Crop do board_drag_cancel(app)
				b.drag = .None
			}
		} else if b.drag == .Turn {
			board_turn_picked(app, room, b.middle, middle, spread / b.spread, refs_wrap(angle - b.twist))
		} else {
			b.pan -= (middle - b.middle) / board_zoom(b)
			board_zoom_about(b, room, middle, spread / b.spread)
		}
		b.spread, b.middle, b.twist = spread, middle, angle
		return
	}
	b.spread = 0
	if a.hovered && ctx.input.wheel != 0 do board_zoom_about(b, room, a.mouse, math.pow(f32(BOARD_WHEEL_STEP), ctx.input.wheel))
	// The middle button pans wherever it goes down, on a picture too, as PureRef's does.
	if a.hovered && .Middle in ctx.input.pressed && b.drag == .None do b.middle_pan, b.last = true, a.mouse
	if b.middle_pan {
		if .Middle not_in ctx.input.down || ctx.input.cancel do b.middle_pan = false
		else {
			b.pan -= (a.mouse - b.last) / board_zoom(b)
			b.last = a.mouse
		}
		return
	}
	// A right click opens the board's menu at the pointer, picking the place under it
	// first when that is not picked yet.
	if ctx.right_on == a.id && a.hovered && .Right in ctx.input.released && b.drag == .None {
		if i := board_hit(app, room, a.mouse); i >= 0 && !board_picked(b, refs.refs[i].id) {
			clear(&b.selected)
			append(&b.selected, refs.refs[i].id)
		} else if i < 0 && !ctx.input.shift do clear(&b.selected)
		b.board_menu, b.menu_at = true, {a.mouse.x, a.mouse.y, 0, 0}
	}
	if long {
		// The press already picked what is under it; a drag it began ends where it is.
		board_drag_end(app)
		b.middle_pan = false
		b.board_menu, b.menu_at = true, {a.mouse.x, a.mouse.y, 0, 0}
		return
	}
	if a.pressed {
		b.last = a.mouse
		hit := board_hit(app, room, a.mouse)
		corner := false
		b.edges = 0
		if one := board_one(app); one != nil && !one.locked {
			at := board_rect(b, room, one^)
			if one.id == b.cropping {
				b.edges = crop_edges_at(ctx, at, a.mouse)
			} else {
				d := a.mouse - refs_turned(at, board_angle(b, one^))[2]
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
			// A picked place comes to the top and stays there; the drag that follows lists
			// the raise with its move as one undo step, a tap as one of its own.
			if b.drag == .Move {
				order := refs_clone(refs.refs[:])
				if refs_bring_front(&refs.refs, b.selected[:], id) {
					delete(b.before)
					b.before, b.raised = order, true
				} else do delete(order)
			}
		case ctx.input.pointer == .Mouse:
			// A mouse's drag from the ground picks what its box touches, as PureRef's
			// does; a finger's pans, as a finger expects.
			if !ctx.input.shift do clear(&b.selected)
			clear(&b.box_base)
			append(&b.box_base, ..b.selected[:])
			b.box_from = a.mouse
			b.drag = .Box
		case:
			if !ctx.input.shift do clear(&b.selected)
			b.drag = .Pan
		}
		if (b.drag == .Move || b.drag == .Size || b.drag == .Crop) && !b.raised {
			delete(b.before)
			b.before = refs_clone(refs.refs[:])
		}
	}
	if a.held && a.mouse != b.last {
		d := a.mouse - b.last
		z := board_zoom(b)
		switch b.drag {
		case .None, .Turn:
		// The finger left of two that turned the picked places moves nothing until it lifts.
		case .Pan:
			b.pan -= d / z
		case .Move:
			for &p in refs.refs do if board_picked(b, p.id) && !p.locked do p.at += d / z
			b.moved = true
		case .Size:
			if p := board_one(app); p != nil {
				// The corner follows the pointer along the picture's diagonal, so it keeps its shape.
				u := refs_rotate(d, -board_angle(b, p^))
				grow := (u.x * p.size.x + u.y * p.size.y) / max(p.size.x * p.size.x + p.size.y * p.size.y, 1e-6) / z
				f := max(1 + grow, REF_MIN_SIDE / max(min(p.size.x, p.size.y), 1e-6))
				p.size *= f
			}
		case .Crop:
			if p := board_one(app); p != nil do board_crop_drag(p, board_point(b, room, a.mouse), b.edges)
		case .Box:
			b.last = a.mouse
			box := board_box(b)
			clear(&b.selected)
			append(&b.selected, ..b.box_base[:])
			for p in refs.refs {
				at := board_rect(b, room, p)
				if !board_picked(b, p.id) && ui.rect_intersect(at, box).w > 0 && ui.rect_intersect(at, box).h > 0 do append(&b.selected, p.id)
			}
		}
		b.last = a.mouse
	}
	if !a.held && b.drag == .Move && b.before != nil && board_pin_drop(app, room, a.mouse) do b.drag = .None
	if !a.held && b.drag != .None do board_drag_end(app)
	if a.clicked && b.drag == .None && len(b.selected) == 0 && handle_double_tap(ctx, &b.tap, a.id) do board_fit(app, room)
}

// Ends the drag under way where it is: a drag that moved, sized or cropped places, or a
// press that raised them, is one undo step.
@(private = "file")
board_drag_end :: proc(app: ^App) {
	b := &app.kit.board
	refs := &app.scene.refs
	if (b.drag == .Move || b.drag == .Size || b.drag == .Crop || b.drag == .Turn) && b.before != nil {
		if !slice.equal(b.before, refs.refs[:]) {
			names := [Ref_Drag]string{.None = "", .Pan = "", .Box = "", .Move = "Move reference", .Size = "Size reference", .Crop = "Crop reference", .Turn = "Turn and size reference"}
			// A press that only raised the picked places is a step of its own name.
			if b.drag == .Move && !b.moved {
				history_record_refs(app, b.before, "Bring reference to front")
			} else {
				history_record_refs(app, b.before, names[b.drag])
				b.moves += 1
			}
		} else do delete(b.before)
		b.before = nil
	}
	b.drag = .None
	b.raised, b.moved = false, false
}

// Scales the picked unlocked places by `s`, turns them by `twist` and carries them from
// screen point `from` to `to`, all about `from`, as two fingers on the board do; a note
// is scaled and carried but never turned.
@(private = "file")
board_turn_picked :: proc(app: ^App, room: ui.Rect, from, to: [2]f32, s, twist: f32) {
	b := &app.kit.board
	m := board_point(b, room, from)
	pan := (to - from) / board_zoom(b)
	grow := clamp(s, 0.5, 2)
	for &p in app.scene.refs.refs {
		if !board_picked(b, p.id) || p.locked do continue
		f := max(grow, REF_MIN_SIDE / max(min(p.size.x, p.size.y), 1e-6))
		turn := twist if p.image != 0 else 0
		c := refs_turn_about(p.at + p.size * 0.5, m, f, turn, pan)
		p.size *= f
		p.angle = refs_wrap(p.angle + turn)
		p.at = c - p.size * 0.5
	}
	b.moved = true
}

// Asks for pictures to add: on the iPad (or with --photos-picker) a choice of Photos and
// Files beside `at`, elsewhere the file dialog at once, whose own list holds the gallery
// on Android and the photos the system keeps on a desktop.
refs_add_ask :: proc(app: ^App, at: ui.Rect) {
	b := &app.kit.board
	if app.photos_picker {
		b.add_menu, b.menu_at = !b.add_menu, at
		return
	}
	refs_ask_files(app)
}

// The file dialog for pictures, and the iPad's photo picker (the file dialog where there
// is none), each counted for the exit stats.
refs_ask_files :: proc(app: ^App) {
	app.kit.board.asked_files += 1
	file_dialog(app, .Reference)
}

refs_ask_photos :: proc(app: ^App) {
	app.kit.board.asked_photos += 1
	if app.no_dialogs do return
	if !file_dialog_photos(app) do file_dialog(app, .Reference)
}

// One of Add's two big choices: `glyph` over its name, a whole tile to aim at. `tip` says
// where its pictures come from. True when tapped.
@(private = "file")
refs_choice_tile :: proc(ctx: ^ui.Context, name: string, glyph: rune, tip: string) -> bool {
	t := ctx.theme
	a := ui.area(ctx, name, REFS_CHOICE_TILE, drag = false)
	r := a.rect
	ui.fill_rect(ctx, r, t.radius_large, t.fill_hover if a.hovered || a.held else t.fill)
	ui.icon(ctx, glyph, {r.x + r.w * 0.5, r.y + r.h * 0.42}, t.icon_size * 2, t.text)
	ui.text(ctx, ui.label_text(name), r.x + r.w * 0.5, r.y + r.h * 0.8, t.text_size, t.text, .Semibold, .Center)
	ui.tip(ctx, a.id, r, tip)
	return a.clicked
}

// The size of Add's choice tiles on the iPad: two big targets side by side, a popover's
// width together.
REFS_CHOICE_TILE :: [2]f32{120, 104}

// The index of the topmost place on the board drawn at `room` under `at`, or -1.
@(private = "file")
board_hit :: proc(app: ^App, room: ui.Rect, at: [2]f32) -> int {
	b := &app.kit.board
	refs := &app.scene.refs
	for i := len(refs.refs) - 1; i >= 0; i -= 1 {
		r := board_rect(b, room, refs.refs[i])
		q := refs_unturn(r, board_angle(b, refs.refs[i]), at)
		if q.x >= r.x && q.x < r.x + r.w && q.y >= r.y && q.y < r.y + r.h do return i
	}
	return -1
}

// The box a box drag spans, from where it began to the pointer, in points.
@(private = "file")
board_box :: proc(b: ^Ref_Board) -> ui.Rect {
	lo := [2]f32{min(b.box_from.x, b.last.x), min(b.box_from.y, b.last.y)}
	hi := [2]f32{max(b.box_from.x, b.last.x), max(b.box_from.y, b.last.y)}
	return {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}
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
	b.raised, b.moved = false, false
}

// Lucide's image-plus, clipboard-paste, scan and trash-2, image-down, sticky-note,
// layout-dashboard, stretch-vertical, flip-horizontal, sun-moon, rotate-cw-square and
// crop, for the card's actions.
ICON_IMAGE_PLUS :: rune(0xe1f7)
// Lucide's images, for Add from Photos.
ICON_IMAGES :: rune(0xe5c9)
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
// Lucide's rotate-ccw-square, for Straighten.
ICON_STRAIGHTEN :: rune(0xe5d5)
// Lucide's send-to-back, for Send to back.
ICON_SEND_TO_BACK :: rune(0xe4f8)
