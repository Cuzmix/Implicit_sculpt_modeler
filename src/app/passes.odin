package main

import "core:fmt"
import "core:math"
import "core:time"
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
	menu_side:  ui.Side, // under the chip, or beside the view rail's Passes button
	switches:   int, // for the exit stats
	// Wipe compare: the main view shows the pass picked left of a line and the last other
	// pass right of it, the line at `wipe_at` of the pane's width. Never kept, never undone.
	wipe:       bool,
	wipe_at:    f32,
	wipe_drags: int, // frames the line moved, for the exit stats
}

// How far the wipe's line keeps from the pane's sides, as a share of its width.
WIPE_EDGE :: 0.05

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

// The pass the viewport shows now (left of the line while wiping): the peeked one while a
// peek is held, except while wiping, whose right side already shows the other pass.
viewport_pass :: proc(k: ^Kit_State) -> render.View_Pass {
	ps := &k.passes
	// The pane worked in shows its own pass (grid_work).
	if g := &k.grid; g.work != 0 do return second_view_pass(g.views[g.work - 1].pass)
	if (ps.chip_held || ps.key_held) && !ps.recording && !wipe_shown(k) do return pass_peeked(k)
	return ps.pass
}

// Whether the wipe shows: on, and not while a time-lapse or turntable records, so every
// frame those take is in the one pass picked.
wipe_shown :: proc(k: ^Kit_State) -> bool {
	return k.passes.wipe && !k.passes.recording && k.grid.work == 0
}

// The pass right of the wipe's line: the last other one, as a peek would show.
wipe_right :: proc(k: ^Kit_State) -> render.View_Pass {
	return pass_peeked(k)
}

// Turns the wipe on (its line in the middle the first time) or off.
wipe_toggle :: proc(k: ^Kit_State) {
	ps := &k.passes
	ps.wipe = !ps.wipe
	if ps.wipe_at <= 0 do ps.wipe_at = 0.5
}

// The wipe's line in the viewport target's pixels, from its share of the main pane: the
// target keeps its size, stretched, while a divider drags, so pane points would be wrong.
wipe_line_px :: proc(at: f32, width: u32) -> f32 {
	return math.round(clamp(at, WIPE_EDGE, 1 - WIPE_EDGE) * f32(width))
}

// Whether the viewport shows the shaded picture whole, which the studio render, render
// mode and the scene's preview picture need.
pass_shaded :: proc(app: ^App) -> bool {
	return viewport_pass(&app.kit) == .Shaded && !wipe_shown(&app.kit) && app.kit.grid.work == 0
}

// What the studio render's and render mode's sections say while a pass pauses them.
pass_paused_note :: proc(app: ^App) -> string {
	return fmt.tprintf("Paused while the viewport shows %s; it starts again on Shaded.", PASS_LABELS[viewport_pass(&app.kit)])
}

// Live occlusion runs while it is on and the viewport is shaded, and always in the AO pass
// where the device can run it, which is all that pass shows; while wiping, when either
// side wants it.
live_ao_wanted :: proc(app: ^App) -> bool {
	left, right := live_ao_strengths(app)
	return left > 0 || right > 0
}

// How strongly live occlusion darkens each side of the wipe's line (the left side alone
// when not wiping): fully in the AO pass, at the studio's strength in Shaded while it is
// on, not at all in the other passes or where the device cannot run it.
live_ao_strengths :: proc(app: ^App) -> (left, right: f32) {
	side :: proc(app: ^App, p: render.View_Pass) -> f32 {
		if !render.live_ao_supported(&app.renderer, &app.live_ao) do return 0
		if p == .AO do return 1
		// A view pane worked in shows occlusion only as its AO only pass (grid_work).
		if app.kit.grid.work != 0 do return 0
		if p == .Shaded && app.live_ao_on do return max(app.studio_ao, 1e-3)
		return 0
	}
	left = side(app, viewport_pass(&app.kit))
	if wipe_shown(&app.kit) do right = side(app, wipe_right(&app.kit))
	return
}

// Gives every viewport draw pass `p`, and with `line_px` 0 or more the wipe: pass `right`
// from that pixel column on, packed into the pass's w as 1 + right + 8 x line_px (exact in
// a float for any target width), so every copy that sets its own pass drops it. Depth
// spans the scene's sphere as the eye sees it, its radius snapped to sixteenths of an
// octave and its distance to sixty-fourths of that, as live occlusion snaps its reach, so
// a stroke that grows the scene seldom changes it (which would redraw everything rather
// than what the brush touched).
pass_items :: proc(items: []render.Draw_Item, view: render.Mat4, p: render.View_Pass, right := render.View_Pass.Shaded, line_px: f32 = -1) {
	wiping := line_px >= 0
	if p == .Shaded && !wiping {
		for &d in items do d.pass = {}
		return
	}
	near, far: f32 = 0, 1
	if p == .Depth || (wiping && right == .Depth) {
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
	wipe: f32 = 1 + f32(right) + 8 * line_px if wiping else 0
	for &d in items do d.pass = {f32(p), near, far, wipe}
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
	clicked := ui.chip(ctx, "Pass##chip", parts, command_hint(app, .View_Pass, int(ps.pass)))
	pass_chip_follow(k, ctx.last_rect, clicked)
}

// After a pass chip at `at` (the top bar's, or Lens's over the view): a tap opens the list
// under it or closes it, a hold peeks, and the list follows the chip unless a bar's
// Passes button opened it beside itself.
pass_chip_follow :: proc(k: ^Kit_State, at: ui.Rect, clicked: bool) {
	ps := &k.passes
	if clicked {
		was := ps.menu
		kit_floats_close(k)
		ps.menu = !was
		ps.menu_side = .Below
	}
	ps.chip_held = ui.held_long(&k.ctx)
	if ps.chip_held do ps.menu = false
	if ps.menu_side == .Below || ps.menu_at.w <= 0 do ps.menu_at, ps.menu_side = at, .Below
}

// The Pass_Menu command: opens the list beside the button that last showed it (the chip, or
// the view rail's Passes), or closes it. Run from Search or keys with neither laid out, it
// opens beside the top of the view rail.
pass_menu_toggle :: proc(app: ^App) {
	k := &app.kit
	ps := &k.passes
	if ps.menu {
		ps.menu = false
		return
	}
	kit_floats_close(k)
	if ps.menu_at.w <= 0 do ps.menu_at, ps.menu_side = ui.prev_rect(&k.ctx, "view bar"), .Left
	ps.menu = true
}

// The chip's list: every pass with its key, then Back to the last one.
kit_pass_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	ps := &k.passes
	if !ui.popover_begin(ctx, "pass menu", &ps.menu, ps.menu_at, ps.menu_side, {direction = .Column, gap = 0, padding = 6, width = 260}) do return
	defer ui.popover_end(ctx)
	ui.caption(ctx, "  PASSES")
	picked := false
	for p in render.View_Pass {
		if command_menu_item(app, .View_Pass, int(p), label = PASS_LABELS[p]) do picked = true
	}
	ui.divider(ctx, across = true)
	picked ||= command_menu_item(app, .View_Pass_Last)
	picked ||= command_menu_item(app, .View_Wipe)
	ui.paragraph(ctx, "Hold the chip, or the ` key, to peek at the last other pass; Wipe compare shows it beside this one, split by a line you drag.")
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

// Lucide's square-split-horizontal, on the wipe's knob.
ICON_WIPE :: rune(0xe3ba)

// The wipe's handle over the main pane `m`, under the view panes and every panel: a light
// line across it with a round knob in its middle, and each side's pass named beside the
// line's top. A drag on the knob or along the line moves it; the press is the interface's, so
// it never sculpts or turns the view. While it moves the view counts as moving, so the
// redraws it costs use the simplified copies as a turn of the view does.
kit_wipe :: proc(app: ^App, m: ui.Rect) {
	k := &app.kit
	ps := &k.passes
	if !wipe_shown(k) || m.w <= 0 || m.h <= 0 do return
	ctx := &k.ctx
	t := ctx.theme
	x := m.x + m.w * clamp(ps.wipe_at, WIPE_EDGE, 1 - WIPE_EDGE)
	cy := m.y + m.h * 0.5
	// The line and the knob sit on a faint dark edge, so they read on a light pass too.
	color_dim :: proc(c: ui.Color) -> ui.Color {return {c.r, c.g, c.b, 0x66}}
	drag :: proc(app: ^App, a: ui.Area, m: ui.Rect) {
		ps := &app.kit.passes
		if !a.held do return
		at := clamp((a.mouse.x - m.x) / m.w, WIPE_EDGE, 1 - WIPE_EDGE)
		if at != ps.wipe_at {
			ps.wipe_at = at
			ps.wipe_drags += 1
			app.view_moved = time.tick_now()
		}
	}

	// Each side's name, in a small plate beside the line under the top bar, so the names
	// travel with the line and never sit on the readouts in the pane's corners.
	label :: proc(ctx: ^ui.Context, name, text: string, at: [2]f32, right: bool) {
		t := ctx.theme
		w := ui.text_width(ctx, text, t.small_size, .Semibold) + 16
		pos := at - {w if right else 0, 0}
		ui.begin_at(ctx, name, pos, {width = w, height = 26, radius = t.radius_small, background = .Panel})
		r := ui.place(ctx, {w, 26})
		ui.text(ctx, text, r.x + 8, r.y + 13, t.small_size, t.text, .Semibold)
		ui.end(ctx)
	}
	top := max(m.y, kit_top() - 8) + 6
	label(ctx, "wipe left name", PASS_LABELS[viewport_pass(k)], {x - 10, top}, true)
	label(ctx, "wipe right name", PASS_LABELS[wipe_right(k)], {x + 10, top}, false)

	ui.begin_at(ctx, "wipe line", {x - WIPE_GRAB * 0.5, m.y}, {width = WIPE_GRAB, height = m.h})
	line := ui.area(ctx, "line", {WIPE_GRAB, m.h})
	ui.fill_rect(ctx, {x - 1.5, m.y, 3, m.h}, 0, color_dim(t.frame))
	ui.fill_rect(ctx, {x - 1, m.y, 2, m.h}, 0, t.text)
	drag(app, line, m)
	ui.end(ctx)

	knob := t.target
	ui.begin_at(ctx, "wipe knob", {x - knob * 0.5, cy - knob * 0.5}, {width = knob, height = knob})
	a := ui.area(ctx, "knob", {knob, knob})
	c := [2]f32{x, cy}
	ui.fill_circle(ctx, c + {0, 1}, 15, color_dim(t.frame))
	ui.fill_circle(ctx, c, 14, t.text)
	ui.icon(ctx, ICON_WIPE, c, t.icon_small - 2, t.frame)
	drag(app, a, m)
	ui.end(ctx)
}

// The width of the strip along the wipe's line that a press drags it by, in points.
WIPE_GRAB :: 16
