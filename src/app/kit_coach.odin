package main

import "core:fmt"

import "../ui"

// First-run tips: three cards at the top middle, one at a time, each going once it has
// been done (sculpt, turn the view, move or zoom it), so a new user finds the gestures
// with no manual. Doing a later one first counts too; Skip tips ends them, and Help or
// the palette starts them again. They show on interactive runs only (or with --coach),
// so scripted runs and their dumps never meet them.

Coach_Step :: enum u8 {
	Draw,
	Turn,
	Move,
}

// Every step done, or the tips skipped: what Kit_State.coach holds once they are over.
COACH_DONE :: i32(1 << len(Coach_Step) - 1)

// The step a card shows now: the first not yet done, if any.
coach_step :: proc(app: ^App) -> (step: Coach_Step, ok: bool) {
	for s in Coach_Step {
		if app.kit.coach & (1 << u8(s)) == 0 do return s, true
	}
	return
}

// The input the words are for: the pointer in use, except that a tablet starts on a
// finger before it is first touched (the device starts as a mouse), and a pen with no
// touch screen seen gets the mouse's words for moving the view.
coach_pointer :: proc(app: ^App) -> ui.Pointer_Kind {
	when MOBILE {
		if app.device.pointer == .Mouse do return .Finger
	}
	return app.device.pointer
}

// What a step says for the input in use and the settings that change it, with its icon,
// as the Help window's Gestures tab has them.
coach_text :: proc(app: ^App, step: Coach_Step) -> (glyph: rune, text: string) {
	nav := &app.nav
	pointer := coach_pointer(app)
	switch step {
	case .Draw:
		glyph = ui.ICON_BRUSH
		switch pointer {
		case .Mouse:  text = "Left drag on the model to sculpt it."
		case .Pen:    text = "Draw on the model with the pen to sculpt it."
		case .Finger:
			text = "Draw on the model with a finger to sculpt it." if finger_model_now(app) == .Sculpt else "Draw on the model with the pen to sculpt it; a finger on it turns the view."
		}
	case .Turn:
		glyph = ui.ICON_ROTATE_3D
		switch {
		case pointer == .Finger && finger_model_now(app) == .Orbit:
			text = "Drag one finger anywhere to turn the view."
		case pointer == .Finger:
			text = "Drag empty space with one finger to turn the view."
		case pointer == .Pen && nav.empty_drag[.Pen] == .Orbit:
			text = "Drag the pen on empty space to turn the view."
		case pointer == .Pen && nav.edge_orbit:
			text = "Drag the pen in from the window's edges to turn the view."
		case nav.empty_drag[.Mouse] == .Orbit:
			text = "Left drag on empty space, or right drag anywhere, to turn the view."
		case:
			text = "Right drag, or Alt + left drag, to turn the view."
		}
	case .Move:
		glyph = ui.ICON_ZOOM_IN
		switch {
		case pointer == .Mouse || (pointer == .Pen && !app.finger_seen):
			text = "Middle drag to move the view; the wheel zooms."
		case nav.two_finger_pan && nav.pinch_zoom:
			text = "Drag two fingers to move the view; pinch to zoom."
		case nav.two_finger_pan:
			text = "Drag two fingers to move the view."
		case:
			text = "Pinch two fingers to zoom."
		}
	}
	return
}

// Starts the tips over (Help, the palette): the card shows from the first step.
coach_restart :: proc(app: ^App) {
	app.kit.coach = 0
	app.coach_seen = {}
	app.coach_run = true
}

// Whether a card shows this frame: on a run that shows tips, with one left, and nothing
// that floats or takes the side open, since the card would sit under it or between.
coach_shown :: proc(app: ^App) -> bool {
	k := &app.kit
	// The tips are about sculpting and turning around the model, so only with Sculpt.
	if !app.coach_run || k.coach == COACH_DONE || app.tool != .Brush do return false
	// The recovery card and a macro recording's chip take the place first.
	if recover_shown(app) || app.macro.recording do return false
	return !side_panel_open(k) && !kit_floating(app)
}

// Counts what was done since the last frame. A step moves on only once its gesture is
// over, so the card stays put while the user is still doing it.
coach_update :: proc(app: ^App) {
	if app.stroke.active do app.coach_seen += {.Draw}
	if app.touch.fingers.count == 0 do app.coach_touch = 0
	// The gesture is over once nothing holds the view: no stroke, no drag, no finger
	// (one left down after a two-finger touch may still turn it) and no tap waiting.
	if app.stroke.active || app.drag.owner != .None || app.touch.fingers.count > 0 || app.dab_wait.active do return
	for s in app.coach_seen do app.kit.coach |= 1 << u8(s)
	// Without either two-finger gesture a touch user has no way to do the third step.
	if coach_pointer(app) == .Finger && !app.nav.two_finger_pan && !app.nav.pinch_zoom do app.kit.coach |= 1 << u8(Coach_Step.Move)
	app.coach_seen = {}
}

kit_coach :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	step, left := coach_step(app)
	if !left || !coach_shown(app) {
		k.coach_shown = false
		return
	}
	shift, w, top, fits := kit_card_place(app, 420, 260)
	if !fits {
		k.coach_shown = false
		return
	}
	k.coach_shown, k.coach_last = true, step
	glyph, text := coach_text(app, step)
	mark := ui.vertex_mark(ctx)
	ui.begin_anchored(ctx, "coach", .Center, .Start, {shift, top}, {direction = .Row, gap = 10, padding = 10, width = w, radius = t.radius_large + 4, background = .Panel, center = true})
	ui.begin(ctx, "coach badge", {width = 36, height = 36, radius = t.radius_medium, background = .Track})
	ui.end(ctx)
	r := ctx.last_rect
	ui.icon(ctx, glyph, {r.x + 18, r.y + 18}, t.icon_size, t.accent)
	skip_w := ui.text_width(ctx, "Skip tips", t.text_size, .Semibold) + 28
	ui.begin(ctx, "coach words", {direction = .Column, gap = 2, width = w - 2 * 10 - 36 - 2 * 10 - skip_w})
	ui.label(ctx, fmt.tprintf("TIP %d OF %d", int(step) + 1, len(Coach_Step)), t.caption_size, t.text_tertiary, .Semibold)
	ui.paragraph(ctx, text, color = t.text)
	ui.end(ctx)
	if ui.button(ctx, "Skip tips", .Light, width = skip_w) do k.coach = COACH_DONE
	ui.end(ctx)
	// Each tip fades in as it comes, and the card dims while a stroke or a turn of the
	// view is under way, so the model shows through it.
	busy := app.stroke.active || app.drag.owner != .None
	shown := ui.tween_from(ctx, ui.id_of(ctx, fmt.tprintf("coach tip %d", int(step))), 0, 1, t.panel_time)
	dim := ui.tween(ctx, ui.id_of(ctx, "coach dim"), 0.35 if busy else 1, t.indicator_time)
	ui.transform_since(ctx, mark, shown * dim, offset = {0, (shown - 1) * 8})
}
