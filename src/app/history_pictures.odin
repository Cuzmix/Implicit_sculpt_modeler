package main

import "core:time"

import "../render"
import "../ui"

// Pictures of steps (History revamp H6), as Photoshop's and Krita's history thumbnails:
// each step that changed the model gets a small picture of it as the main view saw it then,
// a square round what the step changed (History_Entry.area, as the tint finds it). The
// strip shows it in the card over the step the pointer rests on, the step menu at its head,
// and with Step pictures in the list on (History > Settings), each row of the list.
//
// A picture is drawn when the step becomes the newest done one and has none: in the frame
// its stroke ended (the view drawn that frame shows what the step left), and after an
// undo for a step whose picture was given to a newer one, since what the view shows then
// is again what that step left. Never while the timeline seeks, plays or records, nor
// while a view pane is worked in; one picture a frame at most, drawn from the frame's own
// draws. Cells go in turn, so the newest render.STEP_PICTURE_SLOTS steps keep theirs.

Step_Picture_Slots :: struct {
	at:    [render.STEP_PICTURE_SLOTS]time.Tick, // the step each cell shows, by its first entry's time
	next:  int, // the cell the next picture takes
	seen:  time.Tick, // the newest done step when last looked at
	drawn: int, // pictures drawn, for the exit stats
}

// The image id the interface draws the pictures with.
KIT_STEP_PICTURES_IMAGE :: KIT_FADE_STILL_IMAGE + 1

// The cell showing the step whose first entry was made at `at`, as texture coordinates;
// ok is false when it has none.
step_picture_of :: proc(app: ^App, at: time.Tick) -> (lo, hi: [2]f32, ok: bool) {
	if at == {} || app.step_pictures.atlas == nil do return
	for s, i in app.step_picture_slots.at do if s == at {
		lo, hi = render.step_picture_uv(i)
		return lo, hi, true
	}
	return
}

// Draws the step's picture in `r` when it has one, outlined, faded by `fade` as an undone
// step's row is; false when it has none, for the caller to draw something else.
step_picture_draw :: proc(app: ^App, at: time.Tick, r: ui.Rect, fade: f32 = 1) -> bool {
	lo, hi, ok := step_picture_of(app, at)
	if !ok do return false
	ctx := &app.kit.ctx
	ui.image_part(ctx, r, KIT_STEP_PICTURES_IMAGE, lo, hi, {255, 255, 255, u8(255 * clamp(fade, 0, 1))})
	ui.stroke_rect(ctx, r, 4, ui.color_fade(ctx.theme.border, fade), 1)
	return true
}

// After the frame's views are drawn on `cmd`, from its `draws` seen through the main view's
// `view` and `proj`: the picture of the newest done step, when it is due.
step_pictures_frame :: proc(app: ^App, cmd: render.Cmd, view, proj: render.Mat4, draws: []render.Draw_Item) {
	sp := &app.step_picture_slots
	tl := &app.timeline
	done := len(app.history.done)
	if done == 0 || tl.seeking || tl.playing || tl.lapse.state != .Off || app.kit.grid.work != 0 || app.kit.home || len(draws) == 0 do return
	head := done - 1
	for head > 0 && app.history.done[head].chain do head -= 1
	at := app.history.done[head].at
	if at == sp.seen do return
	sp.seen = at
	if _, _, has := step_picture_of(app, at); has do return
	id, box, whole, ok := history_tint_box(app, head, done - 1)
	if !ok do return
	size := [2]f32{f32(app.target.width), f32(app.target.height)}
	lo, hi, seen := flash_screen_box(app, {id = id, box = box}, size, whole)
	if !seen do return
	// A square round what changed with room about it, never smaller than a brush ring, in
	// the view's pixels; the view's projection is narrowed to it, so even the part of it
	// past the view's edge is drawn.
	center := (lo + hi) * 0.5
	side := max(max(hi.x - lo.x, hi.y - lo.y) * 1.3, 96)
	ndc := [2]f32{2 * center.x / size.x - 1, 1 - 2 * center.y / size.y}
	sx, sy := size.x / side, size.y / side
	narrow := render.Mat4{
		sx, 0, 0, -sx * ndc.x,
		0, sy, 0, -sy * ndc.y,
		0, 0, 1, 0,
		0, 0, 0, 1,
	}
	pane := color_f32(theme_current(&app.kit).pane)
	if !render.step_pictures_draw(&app.renderer, &app.step_pictures, cmd, sp.next, view, narrow * proj, draws, pane) do return
	sp.at[sp.next] = at
	sp.next = (sp.next + 1) % render.STEP_PICTURE_SLOTS
	sp.drawn += 1
}

// Whether the newest done step has a picture, for the exit stats.
newest_step_pictured :: proc(app: ^App) -> bool {
	done := len(app.history.done)
	if done == 0 do return false
	head := done - 1
	for head > 0 && app.history.done[head].chain do head -= 1
	_, _, ok := step_picture_of(app, app.history.done[head].at)
	return ok
}
