package main

import "core:fmt"
import "core:math"
import "../render"
import "../ui"

// Passes (Lens): how the viewport shows the meshes, shaded or as one of the diagnostic
// passes that check form (render.View_Pass), after Blender's viewport passes and ZBrush's
// normal and depth views. The pass chip in the top bar names the pass; a tap opens the
// list, and a hold peeks at the last other pass for as long as it is held, as Marmoset's
// and Substance's hold-to-compare do; a held backquote peeks too. The pass is part of the
// workspace's layout. Only the viewport shows it: the thumbnail window, the navigation
// head and object pictures stay shaded, and the studio render and render mode wait,
// since what they build is the shaded picture.

Passes :: struct {
	pass:       render.View_Pass, // the one picked
	last:       render.View_Pass, // the one before it, which a peek shows
	chip_held:  bool, // the chip is held past a long press this frame
	key_held:   bool, // backquote is held (main.odin's event loop)
	// A time-lapse or turntable is recording: a peek shows nothing, so every frame it
	// takes is in the pass picked. Set by the frame loop.
	recording:  bool,
	menu:       bool,
	menu_at:    ui.Rect,
	switches:   int, // for the exit stats
}

// The passes as the chip and menus name them.
@(rodata)
PASS_LABELS := [render.View_Pass]string {
	.Shaded     = "Shaded",
	.Normals    = "Normals",
	.Depth      = "Depth",
	.Curvature  = "Curvature",
	.AO         = "AO only",
	.Silhouette = "Silhouette",
}

// Picks pass `p`, keeping the one it replaces for a peek.
pass_set :: proc(k: ^Kit_State, p: render.View_Pass) {
	ps := &k.passes
	if p == ps.pass do return
	ps.last, ps.pass = ps.pass, p
	ps.switches += 1
}

// Back to the pass before this one.
pass_back :: proc(k: ^Kit_State) {
	pass_set(k, k.passes.last)
}

// What a peek shows: the last other pass, or with none yet, Normals from Shaded and
// Shaded from any other.
pass_peeked :: proc(k: ^Kit_State) -> render.View_Pass {
	ps := &k.passes
	if ps.last != ps.pass do return ps.last
	return .Normals if ps.pass == .Shaded else .Shaded
}

// The pass the viewport shows now: the peeked one while a peek is held.
viewport_pass :: proc(k: ^Kit_State) -> render.View_Pass {
	ps := &k.passes
	if (ps.chip_held || ps.key_held) && !ps.recording do return pass_peeked(k)
	return ps.pass
}

// Whether the viewport shows the shaded picture, which the studio render, render mode
// and the scene's preview picture need.
pass_shaded :: proc(app: ^App) -> bool {
	return viewport_pass(&app.kit) == .Shaded
}

// What the studio render's and render mode's sections say while a pass pauses them.
pass_paused_note :: proc(app: ^App) -> string {
	return fmt.tprintf("Paused while the viewport shows %s; it starts again on Shaded.", PASS_LABELS[viewport_pass(&app.kit)])
}

// Live occlusion runs while it is on and the viewport is shaded, and always in the AO pass
// where the device can run it, which is all that pass shows.
live_ao_wanted :: proc(app: ^App) -> bool {
	p := viewport_pass(&app.kit)
	if p == .AO do return render.live_ao_supported(&app.renderer, &app.live_ao)
	return app.live_ao_on && p == .Shaded
}

// Gives every viewport draw pass `p`. Depth spans the scene's sphere as the eye sees it,
// its radius snapped to sixteenths of an octave and its distance to sixty-fourths of that,
// as live occlusion snaps its reach, so a stroke that grows the scene seldom changes it
// (which would redraw everything rather than what the brush touched).
pass_items :: proc(items: []render.Draw_Item, view: render.Mat4, p: render.View_Pass) {
	if p == .Shaded {
		for &d in items do d.pass = {}
		return
	}
	near, far: f32 = 0, 1
	if p == .Depth {
		if center, radius, ok := render.items_sphere(items); ok && radius > 0 {
			radius = math.pow(2, math.round(math.log2(radius) * 16) / 16)
			eye := view * [4]f32{center.x, center.y, center.z, 1}
			step := radius / 64
			dist := math.round(-eye.z / step) * step
			// The sphere is round the scene's box, about 1.7 times a round scene's own
			// radius, and what is seen of a form lies in front of its middle: the ramp runs
			// from the nearest a round form reaches to a little past the middle, so it goes
			// from white at its nearest to dark grey at its outline.
			near, far = max(dist - radius * 0.58, 0), dist + radius * 0.1
		}
	}
	for &d in items do d.pass = {f32(p), near, far, 0}
}

// The ground behind pass `p`, when it has its own: the thumbnail's paper behind a
// Silhouette, and black behind Depth, so near reads white against far.
pass_ground :: proc(p: render.View_Pass) -> (ground: render.Background, ok: bool) {
	#partial switch p {
	case .Silhouette: return {render.THUMBNAIL_PAPER, render.THUMBNAIL_PAPER}, true
	case .Depth:      return {{0, 0, 0, 1}, {0, 0, 0, 1}}, true
	}
	return
}

// The chip's width: the widest name, so the bar does not shift as the pass changes.
pass_chip_width :: proc(ctx: ^ui.Context) -> f32 {
	w: f32 = 0
	for label in PASS_LABELS do w = max(w, ui.text_width(ctx, label, ctx.theme.small_size, .Semibold))
	return w + ui.text_width(ctx, "Pass", ctx.theme.small_size) + 34
}

// The top bar's pass chip: the pass shown, in the accent while it is not Shaded. A tap
// opens the list under it; a hold peeks.
kit_pass_chip :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	ps := &k.passes
	shown := viewport_pass(k)
	// In a cell as wide as the widest name, so nothing beside it moves as the pass changes.
	ui.begin(ctx, "pass chip cell", {direction = .Row, width = pass_chip_width(ctx)})
	defer ui.end(ctx)
	parts := []ui.Chip_Part{{text = "Pass"}, {text = PASS_LABELS[shown], strong = true, accent = shown != .Shaded}}
	if ui.chip(ctx, "Pass##chip", parts, command_hint(app, .View_Pass, int(ps.pass))) {
		was := ps.menu
		kit_floats_close(k)
		ps.menu = !was
	}
	ps.chip_held = ui.held_long(ctx)
	if ps.chip_held do ps.menu = false
	ps.menu_at = ctx.last_rect
}

// The chip's list: every pass with its key, then Back to the last one.
kit_pass_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	ps := &k.passes
	if !ui.popover_begin(ctx, "pass menu", &ps.menu, ps.menu_at, .Below, {direction = .Column, gap = 0, padding = 6, width = 260}) do return
	defer ui.popover_end(ctx)
	ui.caption(ctx, "  PASSES")
	picked := false
	for p in render.View_Pass {
		if command_menu_item(app, .View_Pass, int(p), label = PASS_LABELS[p]) do picked = true
	}
	ui.divider(ctx, across = true)
	picked ||= command_menu_item(app, .View_Pass_Last)
	ui.paragraph(ctx, "Hold the chip, or the ` key, to peek at the last other pass.")
	if picked do ps.menu = false
}

// The pass's line in a layout, written only when it is not Shaded.
pass_layout_line :: proc(k: ^Kit_State) -> string {
	if k.passes.pass == .Shaded do return ""
	return fmt.tprintf("pass %v\n", k.passes.pass)
}

// Reads a layout's pass line's words.
pass_layout_read :: proc(k: ^Kit_State, f: []string) {
	if len(f) < 2 do return
	for p in render.View_Pass do if fmt.tprint(p) == f[1] do k.passes.pass = p
}
