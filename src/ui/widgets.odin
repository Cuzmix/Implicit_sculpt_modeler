package ui

import "core:math"
import "core:strings"

// Icons in the Lucide font, by what they stand for here.
ICON_MENU :: rune(0xe119)
ICON_UNDO :: rune(0xe2a1)
ICON_REDO :: rune(0xe2a0)
ICON_GRID :: rune(0xe105)
ICON_CLOSE :: rune(0xe1b2)
ICON_CHEVRON_DOWN :: rune(0xe071)
ICON_CHECK :: rune(0xe070)
ICON_PANEL :: rune(0xe436)
ICON_MOVE :: rune(0xe125)
ICON_BRUSH :: rune(0xe1d3)
ICON_PLUS :: rune(0xe141)
ICON_COPY :: rune(0xe0a2)
ICON_TRASH :: rune(0xe18e)
ICON_FOCUS :: rune(0xe29e)
ICON_EYE :: rune(0xe0be)
ICON_SAVE :: rune(0xe151)
ICON_OPEN :: rune(0xe247)
ICON_IMPORT :: rune(0xe0c9)
ICON_EXPORT :: rune(0xe0cc)
ICON_IMAGE :: rune(0xe0f9)
ICON_ACTIVITY :: rune(0xe038)
ICON_SETTINGS :: rune(0xe158)
ICON_WAND :: rune(0xe35b)
ICON_FRAME :: rune(0xe291)
ICON_SUN :: rune(0xe17c)
ICON_SIZE :: rune(0xe07a) // circle
ICON_STRENGTH :: rune(0xe1bf) // gauge

// Every pressable control shares this: the wash under the pointer fades in, deepens
// while held, and the control dips to 97% while held. Returns the scale to draw at.
@(private)
feedback :: proc(ctx: ^Context, id: Id, r: Rect, radius: f32, hovered, held: bool) -> f32 {
	t := ctx.theme
	h := tween(ctx, salt(id, 11), 1 if hovered || held else 0, t.hover_time)
	p := tween(ctx, salt(id, 12), 1 if held else 0, t.press_time)
	a := f32(t.fill_hover.a) * h + (f32(t.fill_pressed.a) - f32(t.fill_hover.a)) * p
	if a > 0.5 do fill_rect(ctx, r, radius, {t.fill_hover.r, t.fill_hover.g, t.fill_hover.b, u8(clamp(a, 0, 255))})
	return 1 - 0.03 * p
}

// Scales what a control drew since `mark` about its middle (the press dip).
@(private)
press_scale :: proc(ctx: ^Context, mark: int, r: Rect, scale: f32) {
	if scale != 1 do transform_since(ctx, mark, 1, scale, {r.x + r.w * 0.5, r.y + r.h * 0.5})
}

// `r` grown about its middle to at least the touch target on each side: what the
// pointer may press, larger than what is drawn.
hit_area :: proc(ctx: ^Context, r: Rect) -> Rect {
	m := ctx.theme.target
	out := r
	if out.w < m {
		out.x -= (m - out.w) * 0.5
		out.w = m
	}
	if out.h < m {
		out.y -= (m - out.h) * 0.5
		out.h = m
	}
	return out
}

// `r` shrunk to `size` about its middle.
@(private)
centered :: proc(r: Rect, size: [2]f32) -> Rect {
	return {r.x + (r.w - size.x) * 0.5, r.y + (r.h - size.y) * 0.5, size.x, size.y}
}

// A line of text taking its own width.
label :: proc(ctx: ^Context, s: string, size: f32 = 0, color: Color = {}, font := Font.Regular) {
	t := ctx.theme
	size := size if size > 0 else t.text_size
	color := color if color.a > 0 else t.text_secondary
	r := place(ctx, {text_width(ctx, s, size, font), math.ceil(size * 1.4)})
	text(ctx, s, r.x, r.y + r.h * 0.5, size, color, font)
}

// An icon-only button in a touch-target cell (`size` points square, the target by
// default), drawn as a smaller rounded square. `name` is its tooltip, with `keys`, its
// shortcut, beside it. Returns true when clicked.
icon_button :: proc(ctx: ^Context, name: string, glyph: rune, selected := false, enabled := true, keys := "", size: f32 = 0) -> bool {
	t := ctx.theme
	size := size if size > 0 else t.target
	cell := place(ctx, {size, size})
	vis := centered(cell, {t.control, t.control})
	mid := [2]f32{vis.x + vis.w * 0.5, vis.y + vis.h * 0.5}
	if !enabled {
		icon(ctx, glyph, mid, t.icon_size, color_fade(t.text_secondary, 0.35))
		return false
	}
	id := id_of(ctx, name)
	hovered, held, clicked, _ := interact(ctx, id, cell)
	mark := vertex_mark(ctx)
	sel := tween(ctx, salt(id, 1), 1 if selected else 0, t.hover_time)
	if sel > 0 do fill_rect(ctx, vis, t.radius_medium, color_fade(t.accent_soft, sel))
	scale := feedback(ctx, id, vis, t.radius_medium, hovered, held)
	h := tween(ctx, salt(id, 2), 1 if hovered else 0, t.hover_time)
	color := color_mix(color_mix(t.text_secondary, t.text, h), t.accent, sel)
	icon(ctx, glyph, mid, t.icon_size, color)
	press_scale(ctx, mark, vis, scale)
	tip(ctx, id, vis, label_text(name), keys)
	return clicked
}

// How a button is filled.
Variant :: enum u8 {
	Solid, // the tone's colour: the one primary action in view
	Flat, // the tone, faint: secondary actions
	Light, // nothing until hovered: actions in a row of many
	Bordered, // a hairline: an action beside a solid one
}

// Which colour a button takes.
Tone :: enum u8 {
	Neutral,
	Accent,
	Danger,
}

// A button with a label and an optional icon before it. `width` 0 takes the column's
// fill width, or fits the label when the column has none. Returns true when clicked.
button :: proc(ctx: ^Context, s: string, variant := Variant.Flat, tone := Tone.Neutral, width: f32 = 0, glyph: rune = 0, enabled := true) -> bool {
	t := ctx.theme
	shown := label_text(s)
	content := text_width(ctx, shown, t.text_size, .Semibold) + (t.icon_small + 6 if glyph != 0 else 0)
	w := width
	if w <= 0 do w = fill_width(ctx)
	if w <= 0 do w = content + 28
	cell := place(ctx, {w, t.target})
	vis := centered(cell, {w, t.control})
	tone_color: Color
	switch tone {
	case .Neutral: tone_color = t.text
	case .Accent:  tone_color = t.accent
	case .Danger:  tone_color = t.danger
	}
	bg, fg: Color
	switch variant {
	case .Solid:
		bg = t.fill if tone == .Neutral else tone_color
		fg = t.text if tone == .Neutral else t.on_accent
	case .Flat:
		bg = t.fill if tone == .Neutral else color_fade(tone_color, 0.16)
		fg = tone_color
	case .Light, .Bordered:
		fg = tone_color
	}
	if !enabled {
		bg = color_fade(bg, 0.4)
		fg = color_fade(t.text_secondary, 0.4)
	}
	id := id_of(ctx, s)
	hovered, held, clicked := false, false, false
	if enabled do hovered, held, clicked, _ = interact(ctx, id, cell)
	mark := vertex_mark(ctx)
	if bg.a > 0 do fill_rect(ctx, vis, t.radius_medium, bg)
	if variant == .Bordered do stroke_rect(ctx, vis, t.radius_medium, t.border_strong, 1)
	scale := feedback(ctx, id, vis, t.radius_medium, hovered, held)
	x := vis.x + (vis.w - content) * 0.5
	if glyph != 0 {
		icon(ctx, glyph, {x + t.icon_small * 0.5, vis.y + vis.h * 0.5}, t.icon_small, fg)
		x += t.icon_small + 6
	}
	text(ctx, shown, x, vis.y + vis.h * 0.5, t.text_size, fg, .Semibold)
	press_scale(ctx, mark, vis, scale)
	return clicked
}

// A button that stays on or off (one symmetry axis), `width` points wide. Returns true
// when clicked.
toggle_button :: proc(ctx: ^Context, s: string, on: bool, width: f32, keys := "", tooltip := "") -> bool {
	t := ctx.theme
	cell := place(ctx, {width, t.target})
	vis := centered(cell, {width, t.control})
	id := id_of(ctx, s)
	hovered, held, clicked, _ := interact(ctx, id, cell)
	mark := vertex_mark(ctx)
	o := tween(ctx, salt(id, 1), 1 if on else 0, t.hover_time)
	if o > 0 do fill_rect(ctx, vis, t.radius_medium, color_fade(t.accent_soft, o))
	scale := feedback(ctx, id, vis, t.radius_medium, hovered && !on, held)
	color := color_mix(t.text_secondary, t.accent, o)
	text(ctx, label_text(s), vis.x + vis.w * 0.5, vis.y + vis.h * 0.5, t.text_size, color, .Semibold, .Center)
	press_scale(ctx, mark, vis, scale)
	tip(ctx, id, vis, tooltip, keys)
	return clicked
}

// One choice of several, in a well with a marker that slides to the chosen option:
// tabs and segmented controls alike. `item_width` 0 shares the column's fill width out
// evenly, or fits each label. `accent` fills the marker with the accent (the tool in
// use). Returns the option chosen this frame, or -1.
tabs :: proc(ctx: ^Context, name: string, options: []string, chosen: int, item_width: f32 = 0, accent := false, glyphs: []rune = nil) -> int {
	t := ctx.theme
	n := len(options)
	if n == 0 do return -1
	pad: f32 = 3
	item_h := t.control - 2 * pad
	fill := fill_width(ctx)
	picked := -1
	// A row as tall as the touch target, the well centred in it, so the options' hit
	// areas are full targets while the well stays slim.
	begin(ctx, name, {direction = .Row, padding = pad, radius = t.radius_medium + pad * 0.5, background = .Track, width = fill if item_width <= 0 && fill > 0 else 0})
	for option, i in options {
		shown := label_text(option)
		w := item_width
		has_glyph := glyphs != nil && i < len(glyphs) && glyphs[i] != 0
		if w <= 0 && fill > 0 do w = (fill - 2 * pad) / f32(n)
		if w <= 0 do w = text_width(ctx, shown, t.text_size, .Semibold) + 28 + (t.icon_small + 6 if has_glyph else 0)
		r := place(ctx, {w, item_h})
		id := id_of(ctx, option)
		hovered, held, clicked, _ := interact(ctx, id, hit_area(ctx, r))
		if clicked do picked = i
		on := i == chosen
		if on {
			indicator(ctx, r, t.radius_small + 1, t.accent if accent else t.cursor)
		}
		o := tween(ctx, salt(id, 1), 1 if on else 0, t.indicator_time)
		_ = feedback(ctx, id, r, t.radius_small + 1, hovered && !on, held && !on)
		color := color_mix(color_mix(t.text_secondary, t.text, f32(int(hovered)) * 0.6), t.on_accent if accent else t.text, o)
		x := r.x + r.w * 0.5
		if has_glyph {
			cw := text_width(ctx, shown, t.text_size, .Semibold) + t.icon_small + 6
			left := x - cw * 0.5
			icon(ctx, glyphs[i], {left + t.icon_small * 0.5, r.y + r.h * 0.5}, t.icon_small, color)
			text(ctx, shown, left + t.icon_small + 6, r.y + r.h * 0.5, t.text_size, color, .Semibold)
		} else {
			text(ctx, shown, x, r.y + r.h * 0.5, t.text_size, color, .Semibold if on else .Regular, .Center)
		}
	}
	end(ctx)
	return picked
}

// A row the width of its column: a label on the left and a switch on the right, the
// whole row pressable. Returns true when it flipped `value`.
switch_row :: proc(ctx: ^Context, s: string, value: ^bool, enabled := true) -> bool {
	t := ctx.theme
	shown := label_text(s)
	w := fill_width(ctx)
	if w <= 0 do w = text_width(ctx, shown, t.text_size) + 16 + 44
	r := place(ctx, {w, t.target})
	id := id_of(ctx, s)
	clicked, held := false, false
	if enabled do _, held, clicked, _ = interact(ctx, id, r)
	if clicked do value^ = !value^
	on := tween(ctx, salt(id, 1), 1 if value^ else 0, t.indicator_time, .Out_Back)
	tint := tween(ctx, salt(id, 2), 1 if value^ else 0, t.hover_time)
	grip := tween(ctx, salt(id, 3), 1 if held else 0, t.press_time)
	fade: f32 = 1 if enabled else 0.4
	text(ctx, shown, r.x, r.y + r.h * 0.5, t.text_size, color_fade(t.text_secondary, fade))
	track := Rect{r.x + r.w - 44, r.y + (r.h - 26) * 0.5, 44, 26}
	fill_rect(ctx, track, 13, color_fade(color_mix(t.fill, t.accent, tint), fade))
	// The knob widens while held, the way a finger presses it flat, and slides over with
	// a little weight.
	kw: f32 = 20 + 4 * grip
	kx := track.x + 3 + (track.w - 6 - kw) * on
	knob := Rect{kx, track.y + 3, kw, 20}
	fill_rect(ctx, {knob.x, knob.y + 1, knob.w, knob.h}, 10, color_fade(t.shadow, 0.5 * fade))
	fill_rect(ctx, knob, 10, color_fade(t.knob, fade))
	return clicked
}

// How a slider maps its track to its value.
Scale :: enum u8 {
	Linear,
	Logarithmic, // equal steps multiply the value: for sizes spanning decades
}

// Where `v` sits between `lo` and `hi`, from 0 to 1.
slider_fraction :: proc(v, lo, hi: f32, scale: Scale) -> f32 {
	if hi <= lo do return 0
	switch scale {
	case .Logarithmic:
		if lo <= 0 do return clamp((v - lo) / (hi - lo), 0, 1)
		return clamp(math.ln(max(v, lo) / lo) / math.ln(hi / lo), 0, 1)
	case .Linear:
	}
	return clamp((v - lo) / (hi - lo), 0, 1)
}

// The value at fraction `f` (0 to 1) of the way from `lo` to `hi`.
slider_value :: proc(fraction, lo, hi: f32, scale: Scale) -> f32 {
	f := clamp(fraction, 0, 1)
	if scale == .Logarithmic && lo > 0 do return lo * math.pow(hi / lo, f)
	return lo + (hi - lo) * f
}

// A slider the width of its column: the label and `shown` (the value as text) above a
// thin track. Pressing on the track puts the value there; dragging follows the pointer
// exactly, so nothing about it is animated but the knob's size. Returns true when the
// value changed.
slider :: proc(ctx: ^Context, s: string, value: ^f32, lo, hi: f32, scale: Scale, shown: string, enabled := true) -> bool {
	t := ctx.theme
	w := fill_width(ctx)
	if w <= 0 do w = 220
	r := place(ctx, {w, t.target + 4})
	id := id_of(ctx, s)
	fade: f32 = 1 if enabled else 0.4
	text(ctx, label_text(s), r.x, r.y + 13, t.text_size, color_fade(t.text_secondary, fade))
	text(ctx, shown, r.x + r.w, r.y + 13, t.text_size, color_fade(t.text, fade), .Semibold, .Right)
	track := Rect{r.x + 8, r.y + 34, r.w - 16, 4}
	changed := false
	held, hovered := false, false
	if enabled {
		hovered, held, _, _ = interact(ctx, id, r)
		if held {
			nf := clamp((ctx.input.mouse.x - track.x) / max(track.w, 1), 0, 1)
			v := slider_value(nf, lo, hi, scale)
			if v != value^ {
				value^ = v
				changed = true
			}
		}
	}
	f := slider_fraction(value^, lo, hi, scale)
	fill_rect(ctx, track, 2, t.fill)
	fill_rect(ctx, {track.x, track.y, track.w * f, track.h}, 2, color_fade(t.accent, fade))
	grow := tween(ctx, salt(id, 1), 1 if held else (0.5 if hovered else 0), t.press_time)
	kr: f32 = 7 + 2 * grow
	knob := [2]f32{track.x + track.w * f, track.y + track.h * 0.5}
	if grow > 0 do fill_circle(ctx, knob, kr + 5 * grow, color_fade(t.accent_soft, grow))
	fill_circle(ctx, knob + {0, 1}, kr, color_fade(t.shadow, 0.5 * fade))
	fill_circle(ctx, knob, kr, color_fade(t.knob, fade))
	return changed
}

// The tall slider for brush size and strength, for a thumb or a pen at the window's
// edge: a slim pill with its label on top, the track in the middle and `shown` below.
// Dragging anywhere on the pill moves the value by how far the pointer moves, so a
// finger never hides the knob it moves and a press never jumps the value. Returns true
// when the value changed.
vslider :: proc(ctx: ^Context, s: string, value: ^f32, lo, hi: f32, scale: Scale, shown: string, glyph: rune = 0, keys := "", track: f32 = 260) -> bool {
	t := ctx.theme
	W :: 44
	cell := place(ctx, {t.target, track + 80})
	r := centered(cell, {W, cell.h})
	id := id_of(ctx, s)
	hovered, held, _, pressed := interact(ctx, id, cell)
	f := slider_fraction(value^, lo, hi, scale)
	changed := false
	if pressed do ctx.press_value = f
	if held {
		nf := clamp(ctx.press_value + (ctx.press_mouse.y - ctx.input.mouse.y) / track, 0, 1)
		if nf != f {
			v := slider_value(nf, lo, hi, scale)
			if v != value^ {
				value^ = v
				changed = true
			}
			f = nf
		}
	}
	fill_rect(ctx, r, W * 0.5, t.surface)
	stroke_rect(ctx, r, W * 0.5, t.border, 1)
	cx := r.x + W * 0.5
	// An icon names it when the label would not fit the pill; the tooltip says it in full.
	if glyph != 0 {
		icon(ctx, glyph, {cx, r.y + 20}, t.icon_small, t.text_tertiary)
		tip(ctx, id, r, label_text(s), keys)
	} else {
		text(ctx, label_text(s), cx, r.y + 20, t.caption_size, t.text_tertiary, .Semibold, .Center)
	}
	top := r.y + 40
	fill_rect(ctx, {cx - 2, top, 4, track}, 2, t.fill)
	knob_y := top + track * (1 - f)
	fill_rect(ctx, {cx - 2, knob_y, 4, top + track - knob_y}, 2, t.accent)
	grow := tween(ctx, salt(id, 1), 1 if held else (0.5 if hovered else 0), t.press_time)
	kr: f32 = 8 + 3 * grow
	if grow > 0 do fill_circle(ctx, {cx, knob_y}, kr + 6 * grow, color_fade(t.accent_soft, grow))
	fill_circle(ctx, {cx, knob_y + 1}, kr, color_fade(t.shadow, 0.5))
	fill_circle(ctx, {cx, knob_y}, kr, t.knob)
	text(ctx, shown, cx, r.y + r.h - 20, t.small_size, t.text, .Semibold, .Center)
	return changed
}

// What happened to a list row.
Row_Result :: struct {
	clicked: bool, // pressed and let go on it with the main button
	menu:    bool, // let go of the other button on it: open its context menu
	rect:    Rect,
}

// A row the width of its column, a touch target tall: an optional icon and `s` on the
// left, `detail` dimmer on the right, tinted with the accent when selected.
list_row :: proc(ctx: ^Context, s: string, detail := "", selected := false, glyph: rune = 0) -> Row_Result {
	t := ctx.theme
	shown := label_text(s)
	w := fill_width(ctx)
	if w <= 0 do w = text_width(ctx, shown, t.text_size) + 24
	cell := place(ctx, {w, t.target})
	vis := centered(cell, {w, t.row})
	id := id_of(ctx, s)
	hovered, held, clicked, _ := interact(ctx, id, cell)
	menu := ctx.hot == id && .Right in ctx.input.released
	mark := vertex_mark(ctx)
	o := tween(ctx, salt(id, 1), 1 if selected else 0, t.hover_time)
	if o > 0 do fill_rect(ctx, vis, t.radius_medium, color_fade(t.accent_soft, o))
	scale := feedback(ctx, id, vis, t.radius_medium, hovered && !selected, held)
	x := vis.x + 12
	if glyph != 0 {
		icon(ctx, glyph, {x + t.icon_small * 0.5, vis.y + vis.h * 0.5}, t.icon_small, color_mix(t.text_secondary, t.accent, o))
		x += t.icon_small + 10
	}
	text(ctx, shown, x, vis.y + vis.h * 0.5, t.text_size, t.text, .Semibold if selected else .Regular)
	if detail != "" do text(ctx, detail, vis.x + vis.w - 12, vis.y + vis.h * 0.5, t.small_size, t.text_tertiary, .Regular, .Right)
	press_scale(ctx, mark, vis, scale)
	return {clicked, menu, cell}
}

// An item in a menu or a select's list: an optional icon, the label, and on the right
// the shortcut or a check when `checked`. Returns true when picked.
menu_item :: proc(ctx: ^Context, s: string, keys := "", glyph: rune = 0, checked := false, tone := Tone.Neutral, enabled := true) -> bool {
	t := ctx.theme
	shown := label_text(s)
	w := fill_width(ctx)
	if w <= 0 do w = text_width(ctx, shown, t.text_size) + 80
	cell := place(ctx, {w, t.target - 4})
	vis := centered(cell, {w, t.target - 10})
	id := id_of(ctx, s)
	hovered, held, clicked := false, false, false
	if enabled do hovered, held, clicked, _ = interact(ctx, id, hit_area(ctx, cell))
	_ = feedback(ctx, id, vis, t.radius_small + 2, hovered, held)
	fg := t.danger if tone == .Danger else t.text
	if !enabled do fg = color_fade(t.text_secondary, 0.4)
	x := vis.x + 10
	if glyph != 0 {
		icon(ctx, glyph, {x + t.icon_small * 0.5, vis.y + vis.h * 0.5}, t.icon_small, fg if tone == .Danger else t.text_secondary)
		x += t.icon_small + 10
	}
	text(ctx, shown, x, vis.y + vis.h * 0.5, t.text_size, fg)
	right := vis.x + vis.w - 10
	if checked {
		icon(ctx, ICON_CHECK, {right - t.icon_small * 0.5, vis.y + vis.h * 0.5}, t.icon_small, t.accent)
	} else if keys != "" {
		text(ctx, keys, right, vis.y + vis.h * 0.5, t.small_size, t.text_tertiary, .Regular, .Right)
	}
	return clicked
}

// A small heading over a group in a menu or panel.
caption :: proc(ctx: ^Context, s: string) {
	t := ctx.theme
	r := place(ctx, {max(fill_width(ctx), text_width(ctx, s, t.caption_size, .Semibold)), 22})
	text(ctx, s, r.x + 2, r.y + r.h * 0.5 + 2, t.caption_size, t.text_tertiary, .Semibold)
}

// A group in a panel that opens and closes: a header row with the title and a chevron,
// and under it, while `open^` (and while it is closing), a body the caller fills and
// closes with section_end. The body grows and fades in as it opens. Returns true when
// there is a body to fill.
section :: proc(ctx: ^Context, title: string, open: ^bool) -> bool {
	t := ctx.theme
	w := fill_width(ctx)
	shown := label_text(title)
	if w <= 0 do w = text_width(ctx, shown, t.small_size, .Semibold) + 40
	cell := place(ctx, {w, t.target - 8})
	id := id_of(ctx, title)
	hovered, held, clicked, _ := interact(ctx, id, hit_area(ctx, cell))
	if clicked do open^ = !open^
	_ = feedback(ctx, id, cell, t.radius_small, hovered, held)
	p := tween(ctx, salt(id, 1), 1 if open^ else 0, t.panel_time, .Out_Cubic)
	text(ctx, shown, cell.x + 4, cell.y + cell.h * 0.5, t.small_size, t.text, .Semibold)
	mark := vertex_mark(ctx)
	chev := [2]f32{cell.x + cell.w - 14, cell.y + cell.h * 0.5}
	icon(ctx, ICON_CHEVRON_DOWN, chev, t.icon_small, t.text_tertiary)
	rotate_since(ctx, mark, (1 - p) * -math.PI * 0.5, chev)
	if p <= 0.001 do return false

	body := strings.concatenate({title, "##body"}, context.temp_allocator)
	_, natural := prev_layout(ctx, body)
	// Fully open, the body fits its content; on the way, it is cut to its share of the
	// height its content had last frame. The first frame open has no such height yet, so
	// it is laid out cut to nothing, which measures it without flashing it fully open.
	height: f32 = 0
	if p < 0.999 do height = max(natural.y * p, 0.5)
	n := ctx.section_depth
	assert(n < len(ctx.sections), "sections nest too deep")
	ctx.sections[n] = {vertex_mark(ctx), p}
	ctx.section_depth += 1
	begin(ctx, body, {direction = .Column, gap = 4, width = w, height = height, clip = true})
	return true
}

section_end :: proc(ctx: ^Context) {
	end(ctx)
	ctx.section_depth -= 1
	s := ctx.sections[ctx.section_depth]
	if s.shown < 1 do transform_since(ctx, s.mark, s.shown)
}

// A field showing the chosen option with a chevron; pressing it opens a list of every
// option under it, which frame_end draws over everything. `options` must stay valid for
// the frame. Returns the option picked, or -1.
select :: proc(ctx: ^Context, name: string, options: []string, chosen: int, width: f32 = 0) -> int {
	t := ctx.theme
	w := width
	if w <= 0 do w = fill_width(ctx)
	if w <= 0 do w = 180
	cell := place(ctx, {w, t.target})
	vis := centered(cell, {w, t.control})
	id := id_of(ctx, name)
	hovered, held, clicked, _ := interact(ctx, id, cell)
	if clicked {
		ctx.select_open = 0 if ctx.select_open == id else id
		if ctx.select_open == id do ctx.select_id = id
	}
	fill_rect(ctx, vis, t.radius_medium, t.fill)
	_ = feedback(ctx, id, vis, t.radius_medium, hovered, held)
	value := options[chosen] if chosen >= 0 && chosen < len(options) else ""
	text(ctx, label_text(value), vis.x + 12, vis.y + vis.h * 0.5, t.text_size, t.text)
	o := tween(ctx, salt(id, 1), 1 if ctx.select_open == id else 0, t.popover_time, .Out_Cubic)
	mark := vertex_mark(ctx)
	chev := [2]f32{vis.x + vis.w - 16, vis.y + vis.h * 0.5}
	icon(ctx, ICON_CHEVRON_DOWN, chev, t.icon_small, t.text_tertiary)
	rotate_since(ctx, mark, o * math.PI, chev)
	// The list belongs to the select drawn last with it open (or closing).
	if ctx.select_id == id {
		ctx.select_anchor = vis
		ctx.select_options = options
		ctx.select_chosen = chosen
		ctx.select_fresh = true
	}
	if ctx.select_pick_id == id {
		ctx.select_pick_id = 0
		return ctx.select_pick
	}
	return -1
}

// The open select's list, drawn by frame_end over everything else.
@(private)
select_list_draw :: proc(ctx: ^Context) {
	if ctx.select_id == 0 do return
	// Its select was not drawn this frame (its panel closed): the list goes with it.
	if !ctx.select_fresh {
		ctx.select_id, ctx.select_open = 0, 0
		return
	}
	ctx.select_fresh = false
	id := ctx.select_id
	open := ctx.select_open == id
	clear(&ctx.stack)
	ctx.id_seed = id
	if popover_begin(ctx, "select list", &open, ctx.select_anchor, .Below, {direction = .Column, padding = 4, width = max(ctx.select_anchor.w, 160)}) {
		for option, j in ctx.select_options {
			if menu_item(ctx, option, checked = j == ctx.select_chosen) {
				ctx.select_pick_id = id
				ctx.select_pick = j
				open = false
			}
		}
		popover_end(ctx)
	}
	ctx.id_seed = 0
	if !open && ctx.select_open == id do ctx.select_open = 0
}

// A brush in the dock or the browser: its icon over its name. The chosen one sits on the
// accent, which slides from tile to tile. Returns true when clicked.
brush_tile :: proc(ctx: ^Context, s: string, glyph: rune, selected: bool, keys := "") -> bool {
	t := ctx.theme
	cell := place(ctx, {64, 58})
	vis := centered(cell, {60, 54})
	id := id_of(ctx, s)
	hovered, held, clicked, _ := interact(ctx, id, cell)
	if selected do indicator(ctx, vis, t.radius_medium + 2, t.accent)
	mark := vertex_mark(ctx)
	o := tween(ctx, salt(id, 1), 1 if selected else 0, t.indicator_time)
	scale := feedback(ctx, id, vis, t.radius_medium + 2, hovered && !selected, held)
	color := color_mix(color_mix(t.text_secondary, t.text, f32(int(hovered)) * 0.7), t.on_accent, o)
	icon(ctx, glyph, {vis.x + vis.w * 0.5, vis.y + 21}, t.icon_size + 2, color)
	text(ctx, label_text(s), vis.x + vis.w * 0.5, vis.y + 42, t.caption_size, color, .Semibold if selected else .Regular, .Center)
	press_scale(ctx, mark, vis, scale)
	if keys != "" do tip(ctx, id, vis, label_text(s), keys)
	return clicked
}

// A thin line between groups: upright in a row, across in a column.
divider :: proc(ctx: ^Context, length: f32 = 28, across := false) {
	if across {
		w := fill_width(ctx)
		r := place(ctx, {w if w > 0 else length, 1})
		fill_rect(ctx, r, 0, ctx.theme.border)
		return
	}
	cell := place(ctx, {9, ctx.theme.target})
	fill_rect(ctx, {cell.x + 4, cell.y + (cell.h - length) * 0.5, 1, length}, 0, ctx.theme.border_strong)
}

// Text wrapped at word boundaries to the column's fill width (or `width`), dimmer than a
// label: help under a heading.
paragraph :: proc(ctx: ^Context, s: string, width: f32 = 0, color: Color = {}) {
	t := ctx.theme
	w := width if width > 0 else fill_width(ctx)
	if w <= 0 do w = 260
	color := color if color.a > 0 else t.text_tertiary
	size := t.small_size
	line_h := math.ceil(size * 1.45)
	last_space := -1
	line_start := 0
	lines := 0
	// Two passes: count the lines to reserve the space, then draw them in it.
	for pass in 0 ..< 2 {
		r: Rect
		if pass == 1 do r = place(ctx, {w, line_h * f32(lines)})
		lines, line_start, last_space = 0, 0, -1
		emit :: proc(ctx: ^Context, s: string, r: Rect, line: int, line_h, size: f32, color: Color, draw: bool) {
			if draw do text(ctx, s, r.x, r.y + line_h * (f32(line) + 0.5), size, color)
		}
		i := 0
		for i <= len(s) {
			at_end := i == len(s)
			if at_end || s[i] == ' ' || s[i] == '\n' {
				if text_width(ctx, s[line_start:i], size) > w && last_space > line_start {
					emit(ctx, s[line_start:last_space], r, lines, line_h, size, color, pass == 1)
					lines += 1
					line_start = last_space + 1
				}
				if at_end || s[i] == '\n' {
					emit(ctx, s[line_start:i], r, lines, line_h, size, color, pass == 1)
					lines += 1
					line_start = i + 1
				}
				last_space = i
			}
			i += 1
		}
	}
}
