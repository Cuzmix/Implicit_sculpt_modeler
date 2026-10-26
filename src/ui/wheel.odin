package ui

import "core:math"
import "core:math/linalg"

// The modifier wheel: a ring of four sectors (top, right, bottom, left) round a grip, as
// a sculpting tablet app's modifier wheel. Each sector is a button whose hit area is its
// own quarter of the ring, so the four meet without overlapping; the grip in the middle
// drags the wheel about.

// One sector of a wheel: its tooltip and shortcut, its icon, and how it shows its state.
Wheel_Sector :: struct {
	name:  string,
	glyph: rune,
	look:  Modifier_Look,
	keys:  string,
}

// What the pointer did to a wheel this frame.
Wheel_Result :: struct {
	clicked:  int, // the sector tapped or clicked (0 top, 1 right, 2 bottom, 3 left), or -1
	grabbed:  bool, // a press went down on the grip this frame
	dragging: bool, // the grip is held and has gone past the slop...
	drag:     [2]f32, // ...this far from where it was pressed, in points
	sectors:  [4]Rect, // where each sector's icon sits, for the app to know where they are
}

// Which sector of a ring `outer` points across round a hole `hole` across, centred at
// `c`, the point `p` is on, or -1 for the hole and outside the ring. The sectors are a
// quarter turn each, the first centred straight up, going clockwise.
wheel_sector_at :: proc(c, p: [2]f32, outer, hole: f32) -> int {
	d := p - c
	r := linalg.length(d)
	if r < hole * 0.5 || r > outer * 0.5 do return -1
	a := math.atan2(d.y, d.x) + math.PI * 0.5 // 0 straight up, clockwise on screen
	return int(math.floor(a / (math.PI * 0.5) + 0.5)) %% 4
}

// A wheel `outer` points across with a grip `hole` across in the middle, laid out in the
// current container. Returns what the pointer did; a long press on a sector shows its
// tooltip, as on any other button.
wheel :: proc(ctx: ^Context, name: string, outer, hole: f32, sectors: [4]Wheel_Sector) -> (res: Wheel_Result) {
	ctx.controls += 1
	t := ctx.theme
	cell := place(ctx, {outer, outer})
	c := [2]f32{cell.x + outer * 0.5, cell.y + outer * 0.5}
	base := id_of(ctx, name)
	res.clicked = -1
	// The whole square is the wheel's to the pointer, so its container is found under it.
	hit_extend(ctx, cell)
	fill_circle(ctx, c, outer * 0.5, t.surface)
	under := wheel_sector_at(c, ctx.input.mouse, outer, hole) if ctx.input.mouse_valid else -1
	GAP :: 0.035 // radians cut from each end of a sector, so they read as four
	STEPS :: 10
	mid_r := (outer * 0.5 - 3 + hole * 0.5 + 2) * 0.5
	for s, i in sectors {
		id := salt(base, u64(10 + i))
		// Its hit area is the square while the pointer is over its quarter, and nothing
		// otherwise; a sector held keeps its press wherever the pointer goes.
		r := cell if under == i || ctx.active == id else Rect{}
		hovered, held, clicked, _ := interact(ctx, id, r)
		if clicked do res.clicked = i
		lit := tween(ctx, salt(id, 1), 1 if s.look != .Off else 0, t.hover_time)
		full := tween(ctx, salt(id, 2), 1 if s.look == .Latched else 0, t.indicator_time)
		h := tween(ctx, salt(id, 3), 1 if hovered || held else 0, t.hover_time)
		fill := color_mix(color_mix(color_mix(t.fill, t.fill_pressed if held else t.fill_hover, h * 0.6), t.accent_soft, lit * (1 - full)), t.accent, full)
		mid := f32(i) * math.PI * 0.5 - math.PI * 0.5
		a0, a1 := mid - math.PI * 0.25 + GAP, mid + math.PI * 0.25 - GAP
		ro, ri := outer * 0.5 - 3, hole * 0.5 + 2
		for k in 0 ..< STEPS {
			b0 := a0 + (a1 - a0) * f32(k) / STEPS
			b1 := a0 + (a1 - a0) * f32(k + 1) / STEPS
			e0, e1 := [2]f32{math.cos(b0), math.sin(b0)}, [2]f32{math.cos(b1), math.sin(b1)}
			fill_convex(ctx, [][2]f32{c + e0 * ro, c + e1 * ro, c + e1 * ri, c + e0 * ri}, fill)
		}
		at := c + [2]f32{math.cos(mid), math.sin(mid)} * mid_r
		color := color_mix(color_mix(t.text_secondary, t.accent, lit), t.on_accent, full)
		icon(ctx, s.glyph, at, t.icon_size, color)
		box := Rect{at.x - 20, at.y - 20, 40, 40}
		res.sectors[i] = box
		tip(ctx, id, box, label_text(s.name), s.keys)
	}
	// The grip: a press there drags the wheel by its middle.
	grip := salt(base, 20)
	g := Rect{c.x - hole * 0.5, c.y - hole * 0.5, hole, hole}
	hovered, held, _, pressed := interact(ctx, grip, g if under < 0 && linalg.length(ctx.input.mouse - c) < hole * 0.5 || ctx.active == grip else Rect{})
	if pressed {
		_ = claim_drag(ctx, -1)
		res.grabbed = true
	}
	if held {
		res.drag = ctx.input.mouse - ctx.press_mouse
		res.dragging = linalg.length(res.drag) > t.slop
	}
	gh := tween(ctx, salt(grip, 1), 1 if hovered || held else 0, t.hover_time)
	fill_circle(ctx, c, hole * 0.5 - 2, color_mix(t.surface, t.fill_hover, gh))
	icon(ctx, ICON_GRIP, c, t.icon_small, t.text_tertiary)
	tip(ctx, grip, g, "Move the wheel")
	return
}
