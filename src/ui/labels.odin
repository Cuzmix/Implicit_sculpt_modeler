package ui

import "core:slice"
import "core:strings"

// Labels: every control on screen named at once (the app's Help overlay, held on a key or
// turned on from Help), each a tag beside it with its name and its key or gesture, so a
// new user reads the whole screen at a glance and can tap anything to try it while the
// tags stay. A control is labelled where it gives itself a tooltip (tip), so the names are
// the tooltips' and never drift from them; the app adds what is no control (the gestures
// on the view) with label_add. The tags are drawn over everything at the frame's end and
// take no input. They come in one after another from the top left, LABEL_STAGGER apart,
// so the eye can follow them; with motion Reduced they fade in together, with Off they
// appear.

// The most tags a frame keeps; a screen with more drops the rest, as one too crowded
// to read would.
LABELS :: 160
// Seconds between one tag coming in and the next, how long each takes, and the longest
// the stagger may spread over.
LABEL_STAGGER :: 0.06
LABEL_FADE :: 0.18
LABEL_SPREAD :: 0.6

Label :: struct {
	id:       Id,
	rect:     Rect, // the control's visible part, in points
	text:     [48]u8,
	text_len: int,
	keys:     [48]u8,
	keys_len: int,
}

// The labels' state in the Context: whether they show, since when (for the stagger),
// what this frame laid out, a rectangle the app keeps clear (its own note about them),
// and what the last frame drew, for the exit stats.
Labels :: struct {
	on:      bool,
	since:   f64,
	list:    [LABELS]Label,
	count:   int,
	clear:   Rect,
	over:    int, // controls past LABELS this frame
	drawn:   int,
	dropped: int,
}

// Turns the labels on or off; turning them on starts their stagger again.
labels_show :: proc(ctx: ^Context, on: bool) {
	if on && !ctx.labels.on do ctx.labels.since = ctx.time
	ctx.labels.on = on
}

// Names the control `id` at `r` with `text` and its key or gesture `keys` while the labels
// show; the part of `r` the clip hides is left out, and a control hidden whole gets none
// (with `clip` false, for what is no control, `r` is taken as it is).
label_add :: proc(ctx: ^Context, id: Id, r: Rect, text: string, keys := "", clip := true) {
	l := &ctx.labels
	if !l.on || text == "" || ctx.popup_measuring do return
	shown := clipped(ctx, r) if clip else r
	if shown.w < 1 || shown.h < 1 do return
	for k in 0 ..< l.count do if l.list[k].id == id do return
	if l.count == LABELS {
		l.over += 1
		return
	}
	// A tooltip that explains as well as names keeps its first clause: a tag names.
	name := text
	if cut := strings.index_any(name, ";,("); cut > 0 do name = strings.trim_right_space(name[:cut])
	n := &l.list[l.count]
	n^ = {id = id, rect = shown}
	n.text_len = copy_text(n.text[:], name)
	// Keys too long for a tag keep their first ways, whole, as "S, [ ] · Three fingers".
	short := keys
	for len(short) > len(n.keys) {
		cut := strings.last_index(short, " · ")
		if cut <= 0 {
			short = ""
			break
		}
		short = short[:cut]
	}
	n.keys_len = copy_text(n.keys[:], short)
	l.count += 1
}

// Draws this frame's tags and empties the list for the next. Each goes under its control,
// centred, else above, right or left of it, else a row further under or over, wherever it
// overlaps no tag already placed, the app's clear rectangle or the window's edge; one with
// nowhere to go is dropped. The
// controls are taken from the top left, row by row, which is also the order they come in.
@(private)
labels_draw :: proc(ctx: ^Context) {
	l := &ctx.labels
	defer l.count = 0
	l.drawn = 0
	dropped := l.over
	l.over = 0
	l.dropped = 0
	if !l.on do return
	list := l.list[:l.count]
	slice.sort_by(list, proc(a, b: Label) -> bool {
		// Rows of 40 points, so a row of buttons a point or two apart reads left to right.
		ra, rb := int(a.rect.y / 40), int(b.rect.y / 40)
		if ra != rb do return ra < rb
		return a.rect.x < b.rect.x
	})
	t := ctx.theme
	window := ctx.input.window
	size := t.small_size
	H :: f32(22)
	PAD :: f32(8)
	placed := make([dynamic]Rect, 0, len(list), context.temp_allocator)
	// A place is free of the tags placed, the clear rectangle and the window's edge, and
	// in the first pass of every named control too, so a tag sits in a gap when one is
	// near rather than over a control.
	free_of := proc(placed: []Rect, list: []Label, clear: Rect, window: [2]f32, r: Rect, controls: bool) -> bool {
		if r.x < 4 || r.y < 4 || r.x + r.w > window.x - 4 || r.y + r.h > window.y - 4 do return false
		if clear.w > 0 && rect_overlaps(r, clear) do return false
		for p in placed do if rect_overlaps(r, p) do return false
		if controls do for c in list do if rect_overlaps(r, c.rect) do return false
		return true
	}
	// A crowded screen's tags come in faster, so the last is in by LABEL_SPREAD.
	stagger := min(f32(LABEL_STAGGER), LABEL_SPREAD / f32(max(len(list), 1))) if motion_moves(ctx, MOTION_TOOLTIPS) else 0
	fade := motion_duration(ctx, MOTION_TOOLTIPS, LABEL_FADE)
	age := f32(ctx.time - l.since)
	draw_set_state(&ctx.draw, .Atlas, 0, full_clip(ctx))
	for &n in list {
		name := string(n.text[:n.text_len])
		keys := string(n.keys[:n.keys_len])
		name_w := text_width(ctx, name, size, .Semibold)
		keys_w := text_width(ctx, keys, size) + 6 if keys != "" else 0
		w := name_w + keys_w + 2 * PAD
		c := n.rect
		// Under the control, over it, beside it, then a row further under or over; each
		// slid along to stay on the window.
		mid := clamp(c.x + c.w * 0.5 - w * 0.5, 4, window.x - 4 - w)
		side := c.y + c.h * 0.5 - H * 0.5
		tries := [6]Rect{{mid, c.y + c.h + 4, w, H}, {mid, c.y - 4 - H, w, H}, {c.x + c.w + 4, side, w, H}, {c.x - 4 - w, side, w, H}, {mid, c.y + c.h + 6 + H, w, H}, {mid, c.y - 6 - 2 * H, w, H}}
		at := Rect{}
		search: for controls in ([2]bool{true, false}) {
			for r in tries {
				if free_of(placed[:], list, l.clear, window, r, controls) {
					at = r
					break search
				}
			}
		}
		if at.w == 0 {
			dropped += 1
			continue
		}
		append(&placed, at)
		shown := f32(1)
		if fade > 0 do shown = clamp((age - f32(len(placed) - 1) * stagger) / fade, 0, 1)
		if shown <= 0 do continue
		mark := vertex_mark(ctx)
		shadow_rect(ctx, at, t.radius_small, color_fade(t.shadow, 0.5))
		fill_rect(ctx, at, t.radius_small, LABEL_FILL)
		text(ctx, name, at.x + PAD, at.y + H * 0.5, size, LABEL_INK, .Semibold)
		if keys != "" do text(ctx, keys, at.x + PAD + name_w + 6, at.y + H * 0.5, size, color_fade(LABEL_INK, 0.72))
		transform_since(ctx, mark, shown, 1, {}, {})
		l.drawn += 1
	}
	l.dropped = dropped
}

// The tags' yellow and the ink on it, the same in either theme: a sticky note over the
// interface, which no control's colour is.
LABEL_FILL :: Color{255, 216, 77, 255}
LABEL_INK :: Color{42, 34, 0, 255}

@(private = "file")
rect_overlaps :: proc(a, b: Rect) -> bool {
	return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
}
