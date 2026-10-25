package ui

import "core:math"

// Icons in the Lucide font, by what they stand for here.
ICON_MENU :: rune(0xe119)
ICON_UNDO :: rune(0xe2a1)
ICON_REDO :: rune(0xe2a0)
ICON_GRID :: rune(0xe105)
ICON_CLOSE :: rune(0xe1b2)

// The colour a pressable shape takes under the pointer and while held: a light wash over
// whatever it sits on.
@(private)
HOVER_WASH :: Color{0xff, 0xff, 0xff, 0x10}
@(private)
HELD_WASH :: Color{0xff, 0xff, 0xff, 0x1c}

@(private)
wash :: proc(ctx: ^Context, r: Rect, radius: f32, hovered, held: bool) {
	if held {
		fill_rect(ctx, r, radius, HELD_WASH)
	} else if hovered {
		fill_rect(ctx, r, radius, HOVER_WASH)
	}
}

// A line of text taking its own width.
label :: proc(ctx: ^Context, s: string, size: f32 = 0, color: Color = {}, font := Font.Regular) {
	t := ctx.theme
	size := size if size > 0 else t.text_size
	color := color if color.a > 0 else t.text_secondary
	r := place(ctx, {text_width(ctx, s, size, font), math.ceil(size * 1.3)})
	text(ctx, s, r.x, r.y + r.h * 0.5, size, color, font)
}

// An icon-only button, `size` points square (the touch target). `name` is its label for
// the id and, later, for screen readers; it is not shown. Returns true when clicked.
icon_button :: proc(ctx: ^Context, name: string, glyph: rune, size: f32 = 0, selected := false, enabled := true) -> bool {
	t := ctx.theme
	size := size if size > 0 else t.target
	r := place(ctx, {size, size})
	if !enabled {
		icon(ctx, glyph, {r.x + r.w * 0.5, r.y + r.h * 0.5}, 22, color_fade(t.text, 0.35))
		return false
	}
	hovered, held, clicked, _ := interact(ctx, id_of(ctx, name), r)
	if selected do fill_rect(ctx, r, t.control_radius, t.accent)
	wash(ctx, r, t.control_radius, hovered, held)
	icon(ctx, glyph, {r.x + r.w * 0.5, r.y + r.h * 0.5}, 22, t.on_accent if selected else t.text)
	return clicked
}

// `c` with its alpha scaled by `f`.
color_fade :: proc(c: Color, f: f32) -> Color {
	return {c.r, c.g, c.b, u8(f32(c.a) * clamp(f, 0, 1) + 0.5)}
}

// One option of a segmented control, `width` by `height` points, standing alone so
// several can be on at once (symmetry axes). Returns true when clicked.
segment_button :: proc(ctx: ^Context, s: string, on: bool, width: f32, height: f32 = 48) -> bool {
	t := ctx.theme
	r := place(ctx, {width, height})
	hovered, held, clicked, _ := interact(ctx, id_of(ctx, s), r)
	if on do fill_rect(ctx, r, t.control_radius, t.segment)
	wash(ctx, r, t.control_radius, hovered && !on, held)
	text(ctx, label_text(s), r.x + r.w * 0.5, r.y + r.h * 0.5, t.text_size, t.text if on else t.text_secondary, .Semibold if on else .Regular, .Center)
	return clicked
}

// A row the width of its column, 48 points tall: `s` on the left, `detail` dimmer on
// the right, tinted with the accent when selected. Returns true when clicked.
list_row :: proc(ctx: ^Context, s: string, detail := "", selected := false) -> bool {
	t := ctx.theme
	shown := label_text(s)
	w := fill_width(ctx)
	if w <= 0 do w = text_width(ctx, shown, t.text_size) + 24
	r := place(ctx, {w, t.target})
	hovered, held, clicked, _ := interact(ctx, id_of(ctx, s), r)
	if selected do fill_rect(ctx, r, 10, color_fade(t.accent, 0.3))
	wash(ctx, r, 10, hovered && !selected, held)
	text(ctx, shown, r.x + 12, r.y + r.h * 0.5, t.text_size, t.text, .Semibold if selected else .Regular)
	if detail != "" do text(ctx, detail, r.x + r.w - 12, r.y + r.h * 0.5, t.text_size, t.text_tertiary, .Regular, .Right)
	return clicked
}

// A button with a text label, `height` points tall, in its own frosted card.
text_button :: proc(ctx: ^Context, s: string, height: f32 = 0, selected := false) -> bool {
	t := ctx.theme
	height := height if height > 0 else t.target
	shown := label_text(s)
	w := text_width(ctx, shown, t.text_size, .Semibold) + 36
	r := place(ctx, {w, height})
	hovered, held, clicked, _ := interact(ctx, id_of(ctx, s), r)
	fill_rect(ctx, r, t.panel_radius, t.accent if selected else t.panel)
	stroke_rect(ctx, r, t.panel_radius, t.panel_border, 1)
	wash(ctx, r, t.panel_radius, hovered, held)
	text(ctx, shown, r.x + r.w * 0.5, r.y + r.h * 0.5, t.text_size, t.on_accent if selected else t.text, .Semibold, .Center)
	return clicked
}

// A brush in the dock: its icon over its name, 72 by 64 points, filled with the accent
// when chosen. Returns true when clicked.
brush_tile :: proc(ctx: ^Context, s: string, glyph: rune, selected: bool) -> bool {
	t := ctx.theme
	r := place(ctx, {72, 64})
	hovered, held, clicked, _ := interact(ctx, id_of(ctx, s), r)
	if selected do fill_rect(ctx, r, 14, t.accent)
	wash(ctx, r, 14, hovered && !selected, held)
	color := t.on_accent if selected else t.text_secondary
	icon(ctx, glyph, {r.x + r.w * 0.5, r.y + 22}, 22, color)
	text(ctx, label_text(s), r.x + r.w * 0.5, r.y + 47, t.caption_size, color, .Semibold if selected else .Regular, .Center)
	return clicked
}

// A row of options of which one is chosen, in a darker well. `item_width` 0 shares the
// container's fill width out evenly. Returns the option chosen this frame, or -1.
segmented :: proc(ctx: ^Context, name: string, options: []string, chosen: int, item_width: f32 = 0, height: f32 = 48, well := true) -> int {
	t := ctx.theme
	n := len(options)
	if n == 0 do return -1
	pad: f32 = 4 if well else 0
	w := item_width
	if w <= 0 do w = max((fill_width(ctx) - 2 * pad) / f32(n), 1)
	picked := -1
	begin(ctx, name, {direction = .Row, padding = pad, radius = t.control_radius + pad * 0.5, background = .Track if well else .None})
	for option, i in options {
		if segment_button(ctx, option, i == chosen, w, height) do picked = i
	}
	end(ctx)
	return picked
}

// An on/off switch, 52 by 32 points, drawn in `r`'s middle.
@(private)
switch_shape :: proc(ctx: ^Context, r: Rect, on: bool) {
	t := ctx.theme
	s := Rect{r.x + (r.w - 52) * 0.5, r.y + (r.h - 32) * 0.5, 52, 32}
	fill_rect(ctx, s, 16, t.positive if on else t.track)
	center := [2]f32{s.x + (s.w - 16) if on else s.x + 16, s.y + 16}
	shadow_circle(ctx, center, 14, t.shadow)
	fill_circle(ctx, center, 14, t.knob)
}

// A row the width of its column: a label on the left and a switch on the right, the
// whole row 48 points tall and pressable. Returns true when it flipped `value`.
toggle_row :: proc(ctx: ^Context, s: string, value: ^bool) -> bool {
	t := ctx.theme
	w := fill_width(ctx)
	shown := label_text(s)
	if w <= 0 do w = text_width(ctx, shown, t.text_size) + 16 + 52
	r := place(ctx, {w, t.target})
	_, _, clicked, _ := interact(ctx, id_of(ctx, s), r)
	if clicked do value^ = !value^
	text(ctx, shown, r.x, r.y + r.h * 0.5, t.text_size, t.text_secondary)
	switch_shape(ctx, {r.x + r.w - 52, r.y, 52, r.h}, value^)
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

// The tall slider for brush size and strength: a 56 point pill with its label on top,
// the track in the middle and `shown` (the value as text) below. Dragging anywhere on
// the pill moves the value by how far the pointer moves, so a finger never hides the
// knob it is moving and a press never jumps the value. Returns true when it changed.
vslider :: proc(ctx: ^Context, s: string, value: ^f32, lo, hi: f32, scale: Scale, shown: string, track: f32 = 300) -> bool {
	t := ctx.theme
	W :: 56
	r := place(ctx, {W, track + 84})
	_, held, _, pressed := interact(ctx, id_of(ctx, s), r)
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
	fill_rect(ctx, r, W * 0.5, t.panel)
	stroke_rect(ctx, r, W * 0.5, t.panel_border, 1)
	cx := r.x + W * 0.5
	text(ctx, label_text(s), cx, r.y + 22, t.caption_size, t.text_secondary, .Regular, .Center)
	top := r.y + 42
	fill_rect(ctx, {cx - 4, top, 8, track}, 4, t.track)
	knob_y := top + track * (1 - f)
	fill_rect(ctx, {cx - 4, knob_y, 8, top + track - knob_y}, 4, t.accent)
	shadow_circle(ctx, {cx, knob_y}, 16, t.shadow)
	fill_circle(ctx, {cx, knob_y}, 16, t.knob)
	text(ctx, shown, cx, r.y + r.h - 22, 13, t.text, .Semibold, .Center)
	return changed
}

// A thin upright line between groups in a row.
divider :: proc(ctx: ^Context, height: f32 = 40) {
	r := place(ctx, {1, height})
	fill_rect(ctx, r, 0, ctx.theme.track)
}
