package main

import "core:fmt"

import "../ui"

// The tour (after round 3's mTour screen): five steps, each lighting one part of the
// screen and asking for it to be tried there, for what the first-run tips (kit_coach.odin)
// leave out: the spaces, the dial, the palettes, History and Paint. A step moves on by
// itself a moment after it was done, or with Next; Skip ends the tour. It follows the tips
// on a first interactive run (or with --tour), and Take the tour (Help, Search) runs it
// again; how far it got is remembered. A step whose part is not on screen (a narrow window
// with the space tabs folded away, the dial turned off) is passed over. Nothing is blocked
// meanwhile: the screen round the lit part only dims.

Tour_Step :: enum u8 {
	Spaces,
	Dial,
	Palettes,
	History,
	Paint,
}

// What Kit_State.tour.step holds once the tour is done or skipped.
TOUR_DONE :: i32(len(Tour_Step))

// How long a done step stays, its tick showing, before the next comes.
TOUR_DONE_HOLD :: 0.9

Tour :: struct {
	step:     i32, // the next step to show; TOUR_DONE when over (remembered)
	run:      bool, // this run shows the tour: interactive, --tour, or Take the tour
	since:    i32, // the step `since_at` was taken for, -1 for none yet
	switches: int, // the space switches when the step came, to see one made
	paint:    bool, // whether painting was on when the step came
	done:     bool, // the step was done; it moves on TOUR_DONE_HOLD after done_at
	done_at:  f64,
	shown:    bool, // a step showed this frame, for the exit stats
	showing:  Tour_Step,
	finished: int, // tours that reached their end, for the exit stats
}

TOUR_TITLES := [Tour_Step]string {
	.Spaces   = "Three spaces, one model",
	.Dial     = "The dial is under your thumb",
	.Palettes = "Palettes down the side",
	.History  = "Every step, kept",
	.Paint    = "Paint with the same brushes",
}

TOUR_TEXT := [Tour_Step]string {
	.Spaces   = "Sculpt, Model and Render each keep their own tools and layout. Tap Model, then Sculpt to come back.",
	.Dial     = "Hold Smooth while you draw to smooth, Invert to dig, Mask to mask; tap one to keep it on. Try it now on the model.",
	.Palettes = "Each card is a palette: fold it to its header, drag it out to float it, or join it to the card above as a tab. Search finds any section by name. Tap one to try it.",
	.History  = "History lists what you did: tap a step to go back to it, or hold Undo to scrub. Open it now.",
	.Paint    = "The shelf's Paint page holds the painting brushes, and Also paint colour in any brush's quick settings (a long press on its tile) makes it paint too. Pick Paint and paint a stroke.",
}

// Starts the tour from its first step (Take the tour), closing what would cover it.
tour_restart :: proc(app: ^App) {
	k := &app.kit
	k.tour.step, k.tour.since, k.tour.done, k.tour.run = 0, -1, false, true
	k.help, k.menu = false, false
	if k.palette do palette_close(app)
}

// The part of the screen step `s` lights, from where last frame drew it; empty when it
// is not on screen.
tour_target :: proc(app: ^App, s: Tour_Step) -> ui.Rect {
	k := &app.kit
	switch s {
	case .Spaces:
		return k.chip_at[.Spaces]
	case .Dial:
		r := &app.rail
		if r.outer <= 0 do return {}
		return {r.center.x - r.outer * 0.5, r.center.y - r.outer * 0.5, r.outer, r.outer}
	case .Palettes:
		for c in k.panels.rect do if c.w > 0 do return c
		return ui.prev_rect(&k.ctx, "view bar")
	case .History:
		return k.history_at
	case .Paint:
		// The shelf with its page names, so the card stands clear of the tiles to tap.
		dock, pages := ui.prev_root_rect(&k.ctx, "dock"), ui.prev_root_rect(&k.ctx, "dock pages")
		if dock.w <= 0 do return pages
		return ui.rect_union(dock, pages) if pages.w > 0 else dock
	}
	return {}
}

// Whether the tour shows a step this frame: on a run that shows it, once the first-run
// tips are over (or not shown this run), with a step left, while nothing opens over it and the tags of Name every
// control are away.
tour_wanted :: proc(app: ^App) -> bool {
	k := &app.kit
	// The tips come first where this run shows them.
	tips_over := k.coach == COACH_DONE || !app.coach_run
	return k.tour.run && k.tour.step < TOUR_DONE && tips_over && !help_labels_on(k) && !k.palette && !k.menu
}

// Counts what was done for the step showing, and moves on: a step done goes on once its
// tick has shown and the gesture is over; a step with nothing on screen is passed over.
tour_update :: proc(app: ^App) {
	k := &app.kit
	tr := &k.tour
	if !tour_wanted(app) do return
	s := Tour_Step(tr.step)
	if tr.since != tr.step {
		tr.since, tr.done = tr.step, false
		tr.switches, tr.paint = k.spaces.switches, app.brush.channel != .Sculpt
	}
	target := tour_target(app, s)
	if target.w <= 0 || target.h <= 0 {
		tour_next(app)
		return
	}
	if !tr.done {
		ctx := &k.ctx
		pressed_in := .Left in ctx.input.pressed && ui.rect_contains(target, ctx.input.mouse)
		did := false
		switch s {
		case .Spaces:   did = k.spaces.switches > tr.switches
		case .Dial:     did = app.stroke.active && (app.rail.press.mods != {} || app.rail.latched != {})
		case .Palettes: did = pressed_in
		case .History:  did = k.history
		case .Paint:    did = (app.brush.channel != .Sculpt || .Paint in BRUSHES[app.brush.kind].flags) && (app.stroke.active || tr.paint)
		}
		if did do tr.done, tr.done_at = true, ctx.time
		return
	}
	busy := app.stroke.active || app.drag.owner != .None || app.touch.fingers.count > 0
	if !busy && k.ctx.time - tr.done_at >= TOUR_DONE_HOLD do tour_next(app)
}

// The next step, or the end.
@(private = "file")
tour_next :: proc(app: ^App) {
	tr := &app.kit.tour
	tr.step += 1
	tr.done = false
	if tr.step >= TOUR_DONE {
		tr.step = TOUR_DONE
		tr.finished += 1
	}
}

// The lit part and the step's card beside it, over everything else.
kit_tour :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	tr := &k.tour
	tr.shown = false
	if !tour_wanted(app) do return
	s := Tour_Step(tr.step)
	target := tour_target(app, s)
	if target.w <= 0 || target.h <= 0 do return
	tr.shown, tr.showing = true, s
	t := ctx.theme
	win := ctx.input.window
	shown := ui.tween_from(ctx, ui.id_of(ctx, fmt.tprintf("tour step %d", int(s))), 0, 1, t.panel_time, class = motion_class(.Popovers))

	// Round the lit part the screen dims, in four bands about a hole a little larger than
	// it, ringed in the accent colour; it takes no input, so the screen works through it.
	hole := ui.Rect{target.x - 8, target.y - 8, target.w + 16, target.h + 16}
	dim := ui.color_fade({8, 9, 11, 255}, 0.62 * shown)
	ui.begin_at(ctx, "tour dim", {0, 0}, {width = win.x, height = win.y, inert = true})
	ui.fill_rect(ctx, {0, 0, win.x, max(hole.y, 0)}, 0, dim)
	ui.fill_rect(ctx, {0, hole.y + hole.h, win.x, max(win.y - hole.y - hole.h, 0)}, 0, dim)
	ui.fill_rect(ctx, {0, hole.y, max(hole.x, 0), hole.h}, 0, dim)
	ui.fill_rect(ctx, {hole.x + hole.w, hole.y, max(win.x - hole.x - hole.w, 0), hole.h}, 0, dim)
	// The dial's ring is round, as the dial is.
	ui.stroke_rect(ctx, hole, hole.w * 0.5 if s == .Dial else t.radius_large, ui.color_fade(t.accent, shown), 2)
	ui.end(ctx)

	// The card: under the lit part when it is in the top half, else over it, kept on the
	// window, or beside it where neither has room (the panels' column is tall).
	W :: f32(380)
	h := ui.prev_rect(ctx, "tour card").h
	if h <= 0 do h = 190
	x := clamp(hole.x + hole.w * 0.5 - W * 0.5, 8, win.x - W - 8)
	y := hole.y + hole.h + 12 if hole.y + hole.h * 0.5 < win.y * 0.5 else hole.y - 12 - h
	if y < 8 || y + h > win.y - 8 {
		y = clamp(hole.y + hole.h * 0.5 - h * 0.5, 8, win.y - h - 8)
		x = hole.x - 12 - W if hole.x - 12 - W >= 8 else hole.x + hole.w + 12
	}
	mark := ui.vertex_mark(ctx)
	ui.begin_at(ctx, "tour card", {x, y}, {direction = .Column, gap = 6, padding = 16, width = W, radius = t.radius_large, background = .Panel})
	ui.label(ctx, fmt.tprintf("%d of %d", int(s) + 1, len(Tour_Step)), t.small_size, t.text_secondary)
	ui.label(ctx, TOUR_TITLES[s], t.text_size + 2, t.text, .Semibold)
	ui.paragraph(ctx, TOUR_TEXT[s])
	if tr.done do ui.label(ctx, "That's it", t.small_size, t.accent, .Semibold)
	ui.spacer(ctx, 4)
	ui.begin(ctx, "tour card foot", {direction = .Row, gap = 8, center = true, width = W - 32})
	dots := ui.place(ctx, {len(Tour_Step) * 12, 12})
	for d in Tour_Step {
		at := [2]f32{dots.x + f32(d) * 12 + 4, dots.y + 6}
		ui.fill_rect(ctx, {at.x - 3.5, at.y - 3.5, 7, 7}, 3.5, t.accent if d == s else t.track)
	}
	last := s == max(Tour_Step)
	NEXT_W :: f32(84)
	SKIP_W :: f32(64)
	ui.spacer(ctx, max(W - 32 - f32(len(Tour_Step) * 12) - NEXT_W - SKIP_W - 3 * 8, 0))
	if !last && ui.button(ctx, "Skip##tour", .Light, width = SKIP_W) do tr.step = TOUR_DONE
	if last do ui.spacer(ctx, SKIP_W)
	if ui.button(ctx, "Finish##tour" if last else "Next##tour", .Solid, .Accent, width = NEXT_W) do tour_next(app)
	ui.end(ctx)
	ui.end(ctx)
	ui.transform_since(ctx, mark, shown, offset = {0, (shown - 1) * 8})
}
