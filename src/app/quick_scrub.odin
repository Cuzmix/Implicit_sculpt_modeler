package main

import "core:fmt"
import "core:math"

import "../ui"

// The quick scrub (History revamp H5): holding Undo or Redo and sliding sideways moves
// through the History a step for every QUICK_SCRUB_STEP points, as dragging the strip's
// bar does, without opening the panel, and two fingers held until their hold undid once
// and then slid do the same anywhere on the view (Procreate's rapid undo, which only
// repeats, made a scrub one can take back). Right goes forward, as on the strip; held at
// the window's edge it keeps stepping that way, since Undo and Redo stand in a corner.
// Lifting leaves the History where it is; a hold on the button that never slid opens the
// History panel, as the long press always did. A strip under the top bar shows the step,
// its place and the steps round it while the scrub lasts. It moves the History only
// through timeline_seek_to, so it is undo and redo pressed that many times.

// Points the pointer slides for each step.
QUICK_SCRUB_STEP :: 16
// Points from the window's side where a held scrub keeps stepping, once every HOLD_REPEAT.
QUICK_SCRUB_EDGE :: 28
// The strip's width, in points.
QUICK_SCRUB_WIDTH :: 440

// What holds the scrub.
Quick_Scrub_By :: enum u8 {
	Off,
	Undo, // a press held on Undo...
	Redo, // ...or on Redo
	Fingers, // two or three fingers whose hold fired, then slid
}

Quick_Scrub :: struct {
	by:      Quick_Scrub_By,
	origin:  f32, // the pointer's x as it began, in points
	at:      f32, // the pointer's x now
	base:    int, // the step the scrub stood at as it began, moved on by the edge
	moved:   bool, // the pointer slid further than the slop: lifting is no tap
	edge_at: f64, // when the edge last took a step
	began:   int, // the done steps as it began, for the stats
	scrubs:  int, // scrubs that slid, for the exit stats...
	last:    int, // ...and how many steps the last one moved, back below zero
}

// The places the History can stand, as counts of done entries: before every step, and
// after the last. A chain undoes as one, so its inner places are left out.
history_places :: proc(app: ^App) -> [dynamic]int {
	total := history_total(app)
	places := make([dynamic]int, 0, total + 1, context.temp_allocator)
	for b in 0 ..= total do if b == 0 || b == total || !history_entry_at(app, b).chain do append(&places, b)
	return places
}

// The step the History stands at among `places`: the last place at or before it.
history_place_of :: proc(places: []int, done: int) -> int {
	at := 0
	for p, i in places do if p <= done do at = i
	return at
}

// Called right after Undo or Redo (`by`): a long press of a finger or the pen, or a mouse
// dragged sideways off it, starts a scrub; a right click, the pen's side button too, opens
// the History panel.
quick_scrub_button :: proc(app: ^App, by: Quick_Scrub_By) {
	ctx := &app.kit.ctx
	id := ctx.last_id
	in_ := ctx.input
	begin := false
	if in_.pointer == .Mouse {
		// A mouse has no long press on the left button: a held click stays a click, and a
		// drag past the slop scrubs.
		if id != 0 && ctx.active == id && .Left in in_.down && abs(in_.mouse.x - ctx.press_mouse.x) > ctx.theme.slop {
			ui.press_used(ctx)
			begin = true
		}
	} else {
		begin = ui.held_long(ctx)
	}
	if ui.secondary(ctx) do app.kit.history = true
	if begin && app.timeline.quick.by == .Off do quick_scrub_begin(app, by, ctx.press_mouse.x)
}

// Starts a scrub held by `by` from `x`, in points, unless the History cannot move now.
quick_scrub_begin :: proc(app: ^App, by: Quick_Scrub_By, x: f32) {
	tl := &app.timeline
	if app.stroke.active || tl.lapse.state != .Off do return
	stroke_finish(app)
	tl.playing = false
	places := history_places(app)
	done := tl.target if tl.seeking else len(app.history.done)
	tl.quick = {by = by, origin = x, at = x, base = history_place_of(places[:], done), began = len(app.history.done), scrubs = tl.quick.scrubs, last = tl.quick.last}
}

// The fingers holding a scrub are at `x`, in points.
quick_scrub_fingers :: proc(app: ^App, x: f32) {
	if app.timeline.quick.by == .Fingers do app.timeline.quick.at = x
}

// Each frame once the interface is laid out: follows the pointer holding the scrub, and
// ends it once that lifts.
quick_scrub_frame :: proc(app: ^App) {
	tl := &app.timeline
	q := &tl.quick
	if q.by == .Off do return
	ctx := &app.kit.ctx
	in_ := ctx.input
	lifted := false
	switch q.by {
	case .Off:
	case .Undo, .Redo:
		q.at = in_.mouse.x
		lifted = .Left not_in in_.down || in_.cancel
	case .Fingers:
		lifted = app.touch.fingers.count < 2
	}
	if lifted || app.stroke.active || tl.lapse.state != .Off {
		quick_scrub_end(app, opened = lifted && !in_.cancel)
		return
	}
	slop := ctx.theme.slop
	dx := q.at - q.origin
	if !q.moved && abs(dx) <= slop do return
	q.moved = true
	places := history_places(app)
	n := len(places)
	shift := int(math.round(dx / QUICK_SCRUB_STEP))
	// Held at the window's side, a step every HOLD_REPEAT that way, past what the slide
	// alone reaches.
	toward := 0
	if q.at < QUICK_SCRUB_EDGE && dx < 0 do toward = -1
	if q.at > in_.window.x - QUICK_SCRUB_EDGE && dx > 0 do toward = 1
	if toward != 0 && ctx.time - q.edge_at >= HOLD_REPEAT {
		q.edge_at = ctx.time
		q.base = clamp(q.base + toward, -shift, n - 1 - shift)
	}
	want := places[clamp(q.base + shift, 0, n - 1)]
	current := tl.target if tl.seeking else len(app.history.done)
	if want != current {
		timeline_seek_to(tl, want)
		haptic(app, .Alignment)
	}
}

// Ends the scrub where the History stands; a press on Undo or Redo that never slid
// opens the History panel when `opened`, as the long press does.
quick_scrub_end :: proc(app: ^App, opened: bool) {
	tl := &app.timeline
	q := &tl.quick
	if q.moved {
		q.scrubs += 1
		places := history_places(app)
		done := tl.target if tl.seeking else len(app.history.done)
		q.last = history_place_of(places[:], done) - history_place_of(places[:], q.began)
	} else if opened && q.by != .Fingers {
		app.kit.history = true
	}
	q.by = .Off
}

// The strip under the top bar while a scrub slides: the step the History stands at and
// its object, its place, then a block for each step round it, coloured by its kind and lit
// when done, with the bookmarks' flags and the History brush's pin over theirs.
kit_quick_scrub :: proc(app: ^App) {
	tl := &app.timeline
	q := tl.quick
	if q.by == .Off || !q.moved do return
	ctx := &app.kit.ctx
	t := ctx.theme
	places := history_places(app)
	n := len(places)
	done := tl.target if tl.seeking else len(app.history.done)
	at := history_place_of(places[:], done)
	safe := ui.safe_area(ctx)
	width := min(f32(QUICK_SCRUB_WIDTH), safe.w - 2 * LENS_EDGE)
	ui.begin_at(ctx, "quick scrub", {safe.x + (safe.w - width) * 0.5, safe.y + TOP_BAR_H + 6}, {direction = .Column, gap = 4, padding = 12, width = width, radius = t.radius_large, background = .Panel, inert = true})
	defer ui.end(ctx)

	title := "The start: nothing done yet"
	if at > 0 {
		head := places[at - 1]
		e := history_entry_at(app, head)
		// Repeats of one stroke on one object read as one, as the list groups them.
		same := 1
		for i := at - 2; i >= 0; i -= 1 {
			f := history_entry_at(app, places[i])
			if f.kind != e.kind || f.id != e.id || f.what != e.what || e.kind != .Stroke do break
			same += 1
		}
		label := entry_label(e) if same == 1 else fmt.tprintf("%s × %d", e.what, same)
		title = fmt.tprintf("%s · %s", label, object_label(object_by_id(app, e.id))) if object_by_id(app, e.id) != nil else label
	}
	ui.label(ctx, title, t.text_size, t.text, .Semibold)
	ui.label(ctx, fmt.tprintf("step %d of %d · slide to scrub, lift to stay", at, n - 1), t.small_size, t.text_secondary)

	inner := width - 24
	row := ui.place(ctx, {inner, 34})
	mid := row.x + row.w * 0.5
	block := f32(QUICK_SCRUB_STEP)
	recall := recall_marker(app)
	for i in 0 ..< n - 1 {
		// Step i sits left of place i + 1, the place its being done leaves the History at.
		x := mid + f32(i - at) * block
		if x + block < row.x || x > row.x + row.w do continue
		e := history_entry_at(app, places[i])
		colour := overlay_color(KIND_COLORS[e.kind])
		if i >= at do colour = ui.color_fade(colour, 0.35)
		ui.fill_rect(ctx, {x + 1, row.y + 14, block - 2, 16}, 3, colour)
		if e.bookmark != "" do ui.icon(ctx, ICON_FLAG, {x + block * 0.5, row.y + 6}, t.icon_small - 6, t.warning)
		else if recall >= places[i] && (i + 1 >= n || recall < places[i + 1]) do ui.icon(ctx, ui.ICON_BRUSH, {x + block * 0.5, row.y + 6}, t.icon_small - 6, t.accent)
	}
	// Where the History stands: between the last done step and the first undone one.
	ui.fill_rect(ctx, {mid - 1.5, row.y + 10, 3, 24}, 1.5, t.text)
	if q.by != .Fingers && !app.history_no_finger_scrub && gesture_repeats(app.nav.gestures[.Two_Hold]) {
		ui.label(ctx, "Or hold two fingers anywhere and slide", t.small_size, t.text_tertiary)
	}
}
