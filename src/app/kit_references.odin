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
// pointer, and a double tap on the ground fits everything. The pictures are drawn by the
// interface from their GPU copies (references.odin), only where the board shows them.

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
}

Ref_Drag :: enum u8 {
	None,
	Pan,
	Move,
	Size,
}

// How wide the card is: room for a board two pictures across beside the model.
REFS_CARD_W :: 420
// The board's zoom range, in screen points a board point.
BOARD_ZOOM_MIN :: 0.05
BOARD_ZOOM_MAX :: 8
// How far a wheel notch zooms.
BOARD_WHEEL_STEP :: 1.2
// The least height the board takes, so a short card still shows something to work on.
BOARD_MIN_H :: 160
// The gap between a picture added and the one before it, in board points.
BOARD_ADD_STEP :: 32

// GPU copy of picture `slot` (KIT_REF_IMAGE + slot), for kit_draws; nil while it decodes.
refs_texture :: proc(app: ^App, slot: int) -> render.Texture {
	images := app.scene.refs.images[:]
	if slot < 0 || slot >= len(images) do return 0
	return images[slot].texture
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
@(private = "file")
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
		file_note(app, true, "The clipboard holds no picture to add to References")
		return false
	}
	return refs_add_bytes(app, "Pasted picture", data)
}

// The References card's body, `inner` wide and at most `room` tall: Add, Paste, Fit and
// Delete over the board.
refs_card_body :: proc(app: ^App, inner, room: f32, owner: ui.Id) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	b := &k.board
	ui.begin(ctx, "refs actions", {direction = .Row, width = inner, gap = t.gap, center = true})
	// Add and Paste share what the two icon buttons leave.
	wide := (inner - 2 * t.target - 3 * t.gap) * 0.5
	if ui.button(ctx, "Add##refs", .Bordered, width = wide, glyph = ICON_IMAGE_PLUS) do file_dialog(app, .Reference)
	if ui.button(ctx, "Paste##refs", .Bordered, width = wide, glyph = ICON_CLIPBOARD_PASTE) do _ = refs_paste(app)
	if ui.icon_button(ctx, "Fit all##refs", ICON_SCAN, enabled = len(app.scene.refs.refs) > 0) do board_fit(app, b.room)
	if ui.icon_button(ctx, "Delete##refs", ICON_TRASH_2, enabled = len(b.selected) > 0) do refs_delete_selected(app)
	ui.end(ctx)
	board_h := max(room - t.target - t.gap, BOARD_MIN_H)
	ui.begin(ctx, "refs board", {width = inner, height = board_h, clip = true, radius = t.radius_medium})
	a := ui.area(ctx, "board", {inner, board_h})
	ui.end(ctx)
	r := a.rect
	// The first time it is shown with pictures on it, the board fits them.
	if b.zoom <= 0 && len(app.scene.refs.refs) > 0 do board_fit(app, r)
	b.room = r
	board_input(app, a)
	board_draw(app, r)
}

// The board's ground, its pictures and the picked ones' outlines and corner, clipped to
// `r` by the container it is drawn in.
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
	for p in refs.refs {
		at := board_rect(b, r, p)
		if ui.rect_intersect(at, r).w <= 0 || ui.rect_intersect(at, r).h <= 0 do continue
		slot := ref_image_slot(refs, p.image)
		img := refs.images[slot]
		if img.texture != 0 {
			ui.image(ctx, at, KIT_REF_IMAGE + u64(slot))
		} else {
			ui.fill_rect(ctx, at, 0, t.fill)
			note := "Loading" if img.failed == "" else fmt.tprintf("Cannot show %s: %s", img.name, img.failed)
			ui.text(ctx, ui.text_fit(ctx, note, t.small_size, at.w - t.gap), at.x + at.w * 0.5, at.y + at.h * 0.5, t.small_size, t.text_tertiary, .Regular, .Center)
		}
	}
	for p in refs.refs {
		if !board_picked(b, p.id) do continue
		at := board_rect(b, r, p)
		ui.stroke_rect(ctx, at, 0, t.accent, 2)
		if len(b.selected) == 1 do ui.fill_circle(ctx, {at.x + at.w, at.y + at.h}, board_corner(ctx) * 0.4, t.accent)
	}
	z := int(math.round(board_zoom(b) * 100))
	ui.text(ctx, fmt.tprintf("%d%%", z), r.x + r.w - t.gap, r.y + r.h - t.gap, t.small_size, t.text_tertiary, .Regular, .Right)
}

// The reach of a picked picture's corner, which sizes it: a finger's target.
@(private = "file")
board_corner :: proc(ctx: ^ui.Context) -> f32 {
	return ctx.theme.target * 0.5
}

// The board's input on area `a`: two fingers pan and pinch, the wheel zooms about the
// pointer, a press on a picture picks it (Shift adds or takes it from the picked ones)
// and drags the picked ones, a press on the picked one's corner sizes it, a press on the
// ground clears the picks and pans, a double tap on the ground fits everything. A drag
// that moved or sized pictures is one undo step when it lets go.
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
		if b.drag == .Move || b.drag == .Size do board_drag_cancel(app)
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
		if len(b.selected) == 1 {
			if i := ref_index(refs, b.selected[0]); i >= 0 {
				at := board_rect(b, room, refs.refs[i])
				d := a.mouse - [2]f32{at.x + at.w, at.y + at.h}
				corner = d.x * d.x + d.y * d.y <= board_corner(ctx) * board_corner(ctx)
			}
		}
		switch {
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
			b.drag = .Move if board_picked(b, id) else .None
		case:
			if !ctx.input.shift do clear(&b.selected)
			b.drag = .Pan
		}
		if b.drag == .Move || b.drag == .Size {
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
			for &p in refs.refs do if board_picked(b, p.id) do p.at += d / z
		case .Size:
			if i := ref_index(refs, b.selected[0]); i >= 0 {
				p := &refs.refs[i]
				// The corner follows the pointer along the picture's diagonal, so it keeps its shape.
				grow := (d.x * p.size.x + d.y * p.size.y) / max(p.size.x * p.size.x + p.size.y * p.size.y, 1e-6) / z
				f := max(1 + grow, REF_MIN_SIDE / max(min(p.size.x, p.size.y), 1e-6))
				p.size *= f
			}
		}
		b.last = a.mouse
	}
	if !a.held && b.drag != .None {
		if (b.drag == .Move || b.drag == .Size) && b.before != nil {
			if !slice.equal(b.before, refs.refs[:]) {
				history_record_refs(app, b.before, "Move reference" if b.drag == .Move else "Size reference")
				b.moves += 1
			} else do delete(b.before)
			b.before = nil
		}
		b.drag = .None
	}
	if a.clicked && b.drag == .None && len(b.selected) == 0 && handle_double_tap(ctx, &b.tap, a.id) do board_fit(app, room)
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

// Lucide's image-plus, clipboard-paste, scan and trash-2, for the card's actions.
ICON_IMAGE_PLUS :: rune(0xe1f7)
ICON_CLIPBOARD_PASTE :: rune(0xe3ec)
ICON_SCAN :: rune(0xe257)
ICON_TRASH_2 :: rune(0xe18e)
