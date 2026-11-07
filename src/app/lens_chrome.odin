package main

import "core:math"

import "../ui"

// The Lens layout's floating chrome round the full-window view (round 2 of the mockups):
// the off-hand island of tall Size and Strength sliders above the dial, the readout at
// the top corner on the same side and the view rail of one-tap view tools down the pen
// side. Each is laid out under the names the bars before them
// had ("brush bar", "points", "view bar"), so whatever keeps clear of those keeps clear of
// these. Left-handed, the kit's mirror swaps every side.

// The island's tall sliders' track, in points: short enough that both stand between the
// chips and the dial on a laptop's window.
OFFHAND_TRACK :: 96

// How far the island, the chips and the rail stand in from the window's edges, in points.
LENS_EDGE :: 12

// A chip's pill, in points: drawn this tall inside a touch target.
LENS_CHIP_H :: 32

// A size or strength slider's tooltip: its keys, and the three-finger drag when that is on.
slider_hint :: proc(app: ^App, keys: string, step: Command_Id) -> string {
	return hint_join(keys, command_gesture(app, step))
}

// Points of drag a degree of the pen's roll stands for, and the points of drag that double
// the size and take the strength across its range: a quarter turn clockwise doubles the
// size and half a turn takes the strength from 0 to 1, as Windows Ink and some Android pens
// report the roll.
ROLL_POINTS :: f32(ROLL_STRENGTH_FULL) / 180
ROLL_SIZE_DOUBLE :: 150
ROLL_STRENGTH_FULL :: 300

// A chip over the view: a see-through pill a touch target tall holding an optional
// camera dot and icon, `text`, a dimmer `sub` and a chevron when it opens a menu. Lit
// (accent text) while what it opens shows. Its tooltip is `name` with `keys`.
lens_chip :: proc(ctx: ^ui.Context, name, text: string, sub := "", glyph: rune = 0, dot: Maybe(ui.Color) = nil, chevron := false, lit := false, keys := "") -> ui.Area {
	t := ctx.theme
	a := ui.area(ctx, name, {lens_chip_width(ctx, text, sub, glyph, dot != nil, chevron), t.target})
	pill := ui.Rect{a.rect.x, a.rect.y + (a.rect.h - LENS_CHIP_H) * 0.5, a.rect.w, LENS_CHIP_H}
	lens_chip_draw(ctx, pill, text, sub, glyph, dot, chevron, lit, a.held, a.hovered)
	ui.tip(ctx, a.id, a.rect, ui.label_text(name), keys)
	return a
}

// A chip's width for what it holds, in points.
lens_chip_width :: proc(ctx: ^ui.Context, text: string, sub := "", glyph: rune = 0, dot := false, chevron := false) -> f32 {
	t := ctx.theme
	w: f32 = 2 * LENS_CHIP_PAD
	if dot do w += 14
	if glyph != 0 do w += t.icon_small + 6
	if text != "" do w += ui.text_width(ctx, text, t.small_size, .Semibold)
	if sub != "" do w += 6 + ui.text_width(ctx, sub, t.small_size)
	if chevron do w += 18
	return w
}

LENS_CHIP_PAD :: 10

// Draws a chip's pill at `pill`, pressed or hovered as `held` and `hovered` say.
lens_chip_draw :: proc(ctx: ^ui.Context, pill: ui.Rect, text: string, sub := "", glyph: rune = 0, dot: Maybe(ui.Color) = nil, chevron := false, lit := false, held := false, hovered := false, glass := true) {
	t := ctx.theme
	// Without its glass, the content alone, on a pill its caller drew (a tab strip's).
	if glass {
		fill := ui.Color{t.frame.r, t.frame.g, t.frame.b, TOP_GLASS_ALPHA}
		ui.fill_rect(ctx, pill, t.radius_medium, fill)
		if held do ui.fill_rect(ctx, pill, t.radius_medium, t.fill_pressed)
		else if hovered do ui.fill_rect(ctx, pill, t.radius_medium, t.fill_hover)
		ui.stroke_rect(ctx, pill, t.radius_medium, t.border, 1)
	}
	x := pill.x + LENS_CHIP_PAD
	cy := pill.y + pill.h * 0.5
	if c, ok := dot.?; ok {
		ui.fill_circle(ctx, {x + 4, cy}, 4, c)
		x += 14
	}
	if glyph != 0 {
		ui.icon(ctx, glyph, {x + t.icon_small * 0.5, cy}, t.icon_small, t.text_secondary)
		x += t.icon_small + 6
	}
	if text != "" {
		ui.text(ctx, text, x, cy, t.small_size, t.accent if lit else t.text, .Semibold)
		x += ui.text_width(ctx, text, t.small_size, .Semibold)
	}
	if sub != "" {
		ui.text(ctx, sub, x + 6, cy, t.small_size, t.text_tertiary)
		x += 6 + ui.text_width(ctx, sub, t.small_size)
	}
	if chevron do ui.icon(ctx, ui.ICON_CHEVRON_DOWN, {x + 10, cy}, t.icon_small - 2, t.text_tertiary)
}

// The main camera's lens as a full-frame camera's would be, in millimetres: the focal
// length that gives its vertical field of view on a 24 mm tall frame.
lens_focal_mm :: proc(fov_y: f32) -> f32 {
	return 12 / math.tan(fov_y * 0.5)
}

// A dock button's name beside its icon: one short word where the command's name is long.
rail_label :: proc(app: ^App, s: Bar_Slot) -> string {
	#partial switch s.id {
	case .View_Layout_Menu: return "Layout"
	case .Focus_Selected:   return "Frame"
	case .Symmetry_X:       return "Symmetry"
	case .Second_View:      return "Second"
	}
	return bar_label(app, s)
}

// How far in from the pen side's edge the navigation head stands in Lens: left of whatever
// stands at that side's top (the rail, the panels' column, a panel shown there last frame),
// as the mockups have it, so it never sits on the panels.
lens_nav_offset :: proc(app: ^App) -> f32 {
	k := &app.kit
	ctx := &k.ctx
	area := ui.safe_area(ctx)
	mid := area.x + area.w * 0.5
	reach: f32 = LENS_EDGE
	near_top := area.y + kit_top() + 40
	take :: proc(r: ui.Rect, area: ui.Rect, mid, near_top: f32, mirror: bool, reach: ^f32) {
		if r.w <= 0 || r.y > near_top do return
		pen_side := (r.x + r.w * 0.5 > mid) != mirror
		if !pen_side do return
		from := area.x + area.w - r.x if !mirror else r.x + r.w - area.x
		reach^ = max(reach^, from + 8)
	}
	take(ui.prev_rect(ctx, "view bar"), area, mid, near_top, ctx.mirror, &reach)
	// The island too, and the person's docks, where Arrange put them at the top of the pen
	// side.
	if k.docks[.Offhand].edge != .Default do take(ui.prev_rect(ctx, "brush bar"), area, mid, near_top, ctx.mirror, &reach)
	for i in 0 ..< USER_DOCKS do if user_dock_shown(k, i) do take(ui.prev_rect(ctx, DOCK_ROOTS[user_dock_id(i)]), area, mid, near_top, ctx.mirror, &reach)
	for s in Column_Side do take(column_rest_rect(app, s), area, mid, near_top, ctx.mirror, &reach)
	for s in k.panels.seen do if s.frame >= k.frame - 1 do take(s.rect, area, mid, near_top, ctx.mirror, &reach)
	// A card a rail button opened is no panel, but it covers the head just the same.
	for c in Card do if card_shown(app, c) do take(ui.prev_rect(ctx, card_root_name(c)), area, mid, near_top, ctx.mirror, &reach)
	return reach
}

// How tall a band at the pen side's bottom is kept clear for the pen hand's palm, in
// points: a fifth of the window on a tablet-shaped one (no wider than 1.5 times its
// height), where the hand rests on the glass, else none.
lens_palm :: proc(app: ^App) -> f32 {
	area := ui.safe_area(&app.kit.ctx)
	if area.w > area.h * 1.5 do return 0
	return area.h * 0.2
}

