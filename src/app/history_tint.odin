package main

import "core:fmt"
import "core:math"
import "core:time"

import "../geom"
import "../ui"

// What a step changed (History revamp H3): resting the mouse or the pen on a row of the
// History list or a block of the strip, or pressing one, tints the part of the model that
// step touched with a soft glow in its kind's colour, with its name, object and size beside
// it, as Photoshop's history and Nomad's list cannot show; the step menu's Show what it
// changed keeps the tint up until the next press, for a finger, which has no hover. A
// stroke's part is the box it recorded (History_Entry.area); a step that changed the whole
// object (a rebuild, a move) tints the object; the lights and the scene tree tint nothing.
// It is drawn over the viewport like the undo flash, and never moves the History.

// How long the tint takes to come up, in seconds of the interface's clock.
HISTORY_TINT_RISE :: 0.15

// Before the History panel lays out its rows: what they rested on last frame is forgotten,
// and a press anywhere ends the menu's kept tint, as it ends a popover.
history_tint_frame :: proc(app: ^App) {
	tl := &app.timeline
	ctx := &app.kit.ctx
	tl.tint_hover = {}
	if tl.tint_kept != {} && (ctx.input.pressed != {} && ctx.time > tl.tint_kept_at || !app.kit.history) do tl.tint_kept = {}
}

// A row or block of the step whose first entry was made at `at` is rested on or pressed.
history_tint_rest :: proc(app: ^App, at: time.Tick) {
	app.timeline.tint_hover = at
}

// The step tinted now: the one rested on, else the one the menu keeps.
history_tint_step :: proc(app: ^App) -> time.Tick {
	tl := &app.timeline
	return tl.tint_hover if tl.tint_hover != {} else tl.tint_kept
}

// The object the step at timeline positions `head` to `last` changed and the box round
// what it changed, in the scene's space, with `whole` true when that is the whole object;
// ok false for a step with no part of the model (the lights, the scene tree) or whose object
// is gone.
history_tint_box :: proc(app: ^App, head, last: int) -> (id: int, box: geom.Aabb, whole, ok: bool) {
	e := history_entry_at(app, head)
	if e.kind == .Lights || e.kind == .Arrange do return
	obj := object_by_id(app, e.id)
	if obj == nil do return
	local := geom.AABB_EMPTY
	for i in head ..= last {
		f := history_entry_at(app, i)
		if f.id != e.id || f.area == {} || f.area.lo.x > f.area.hi.x do continue
		local = geom.aabb_union(local, f.area)
	}
	if local.lo.x > local.hi.x {
		box = flash_object_box(obj)
		return obj.id, box, true, box.lo.x <= box.hi.x
	}
	return obj.id, box_to_world(obj, local), false, true
}

// The tint over the viewport of `size`: a soft glow over what the step changed, brightest
// in its middle, breathing slowly while motion is full, with the step's name beside it.
draw_history_tint :: proc(app: ^App, o: Overlay, size: [2]f32) {
	tl := &app.timeline
	ctx := o.ctx
	at := history_tint_step(app)
	if at != tl.tint_shown {
		tl.tint_shown, tl.tint_since = at, ctx.time
		if at != {} do tl.tints += 1
	}
	if at == {} do return
	head, last, found := history_step_of(app, at)
	if !found do return
	id, box, whole, ok := history_tint_box(app, head, last)
	if !ok do return
	lo, hi, seen := flash_screen_box(app, {id = id, box = box}, size, whole)
	if !seen do return
	e := history_entry_at(app, head)
	rise := clamp(f32(ctx.time - tl.tint_since) / HISTORY_TINT_RISE, 0, 1) if ctx.motion != .Off else 1
	breathe: f32 = 1
	if ctx.motion == .Full do breathe = 0.8 + 0.2 * math.sin(f32(ctx.time) * 2.6)
	alpha := rise * breathe * (0.6 if head >= len(app.history.done) else 1)
	colour := KIND_COLORS[e.kind]
	// Rings from the outside in, each a little brighter, so the glow fades to nothing at
	// its edge as a radial gradient would; a step too small to see still gets a glow a
	// brush ring across.
	pad := 14 * o.scale
	center := (lo + hi) * 0.5
	radius := [2]f32{max((hi.x - lo.x) * 0.5 + pad, 22 * o.scale), max((hi.y - lo.y) * 0.5 + pad, 22 * o.scale)}
	RINGS :: 14
	for ring in 0 ..< RINGS {
		k := 1 - 0.8 * f32(ring) / RINGS
		draw_tint_ellipse(o, center, radius * k, overlay_color({colour.r, colour.g, colour.b, 0.055 * alpha}))
	}
	obj := object_by_id(app, e.id)
	bytes := 0
	for i in head ..= last do bytes += history_entry_at(app, i).bytes
	size_text := fmt.tprintf(" · %s", bytes_label(bytes)) if bytes > 0 else ""
	label := fmt.tprintf("%s · %s%s", entry_label(e), object_label(obj), size_text)
	overlay_label(o, label, {center.x, max(center.y - radius.y - 16 * o.scale, 16 * o.scale)})
}

// A filled ellipse round `center` of `radius`.
@(private = "file")
draw_tint_ellipse :: proc(o: Overlay, center, radius: [2]f32, color: ui.Color) {
	STEPS :: 40
	points: [STEPS][2]f32
	for i in 0 ..< STEPS {
		a := f32(i) / STEPS * 2 * math.PI
		points[i] = center + radius * [2]f32{math.cos(a), math.sin(a)}
	}
	overlay_fill(o, points[:], color)
}
