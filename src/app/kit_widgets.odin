package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strings"

import "../geom"
import "../ui"

// Controls the interface's panels share that are made of the kit's parts.

// A response curve as a graph to drag (a falloff, the pen's pressure): the two round
// handles are its control points, and a press within half a touch target of one takes
// it. `mirrored` draws it right to left, as a falloff reads from the centre out; `dot`
// marks a point on it; `shown`, when given, is drawn in place of the curve (a built-in
// shape that is no curve, whose handles still show, to drag from). `handle` remembers
// which handle is held. Returns whether a handle moved.
kit_curve_editor :: proc(ctx: ^ui.Context, name: string, curve: ^geom.Curve, handle: ^int, mirrored: bool, dot: Maybe([2]f32) = nil, shown: proc(x: f32) -> f32 = nil) -> (moved: bool) {
	t := ctx.theme
	a := ui.area(ctx, name, {0, 150})
	// The graph sits inside the area, so the handles at its corners show whole.
	g := ui.Rect{a.rect.x + 12, a.rect.y + 12, a.rect.w - 24, a.rect.h - 24}
	at :: proc(g: ui.Rect, p: [2]f32, mirrored: bool) -> [2]f32 {
		x := 1 - p.x if mirrored else p.x
		return {g.x + x * g.w, g.y + (1 - p.y) * g.h}
	}
	if a.pressed {
		handle^ = 0
		best := t.target * 0.5
		for c, i in ([2][2]f32{curve.c1, curve.c2}) {
			if d := linalg.length(a.mouse - at(g, c, mirrored)); d < best do handle^, best = i + 1, d
		}
	}
	if a.held && handle^ > 0 {
		x := clamp((a.mouse.x - g.x) / g.w, 0, 1)
		p := [2]f32{1 - x if mirrored else x, clamp(1 - (a.mouse.y - g.y) / g.h, 0, 1)}
		if handle^ == 1 {
			curve.c1 = p
		} else {
			curve.c2 = p
		}
		moved = true
	} else if !a.held {
		handle^ = 0
	}

	ui.fill_rect(ctx, a.rect, t.radius_medium, t.fill)
	grid := ui.color_fade(t.text, 0.07)
	for k in 1 ..< 4 {
		f := f32(k) / 4
		ui.line(ctx, at(g, {f, 0}, false), at(g, {f, 1}, false), grid, 1)
		ui.line(ctx, at(g, {0, f}, false), at(g, {1, f}, false), grid, 1)
	}
	ui.line(ctx, at(g, {0, 0}, mirrored), at(g, {1, 1}, mirrored), ui.color_fade(t.text, 0.15), 1)
	STEPS :: 48
	points: [STEPS + 1][2]f32
	for &q, i in points {
		x := f32(i) / STEPS
		q = at(g, {x, shown(x) if shown != nil else geom.curve_at(curve^, x)}, mirrored)
	}
	ui.polyline(ctx, points[:], t.accent, 2)
	ui.line(ctx, at(g, {0, 0}, mirrored), at(g, curve.c1, mirrored), t.text_tertiary, 1)
	ui.line(ctx, at(g, {1, 1}, mirrored), at(g, curve.c2, mirrored), t.text_tertiary, 1)
	for c, i in ([2][2]f32{curve.c1, curve.c2}) {
		ui.fill_circle(ctx, at(g, c, mirrored), 8 if handle^ == i + 1 else 6, t.knob)
	}
	if p, ok := dot.?; ok do ui.fill_circle(ctx, at(g, p, mirrored), 4, t.warning)
	return
}

// A colour as a swatch beside its hex code, over Red, Green and Blue sliders, all in the
// values a screen shows (sRGB, as image editors give them). `linear` says the colour is
// stored as linear light (a material's, which the shader lights as is), so it is shown
// through the sRGB curve and only the channel moved is converted back; paint is stored as
// shown. Returns true when it changed.
kit_color :: proc(app: ^App, name: string, rgb: ^[3]f32, linear := false) -> (changed: bool) {
	ctx := &app.kit.ctx
	t := ctx.theme
	shown := rgb^
	if linear do for &c in shown do c = srgb_encode(c)
	hex_w: f32 = 104
	swatch_w := max(ui.fill_width(ctx) - hex_w - 8, 28)
	ui.begin(ctx, fmt.tprintf("swatch##%s", name), {direction = .Row, gap = 8})
	// The swatch stands as tall as the field beside it.
	r := ui.place(ctx, {swatch_w, t.target})
	r.y += (t.target - t.control) * 0.5
	r.h = t.control
	ui.fill_rect(ctx, r, t.radius_medium, overlay_color({shown.r, shown.g, shown.b, 1}))
	ui.stroke_rect(ctx, r, t.radius_medium, t.border_strong, 1)
	if typed, ok := kit_hex_field(app, name, shown, hex_w); ok {
		shown = typed
		rgb^ = typed
		if linear do for &c in rgb do c = srgb_decode(c)
		changed = true
	}
	ui.end(ctx)
	for channel, i in ([3]string{"Red", "Green", "Blue"}) {
		if ui.slider(ctx, fmt.tprintf("%s##%s", channel, name), &shown[i], 0, 1, .Linear, fmt.tprintf("%d", int(math.round(shown[i] * 255)))) {
			rgb[i] = srgb_decode(shown[i]) if linear else shown[i]
			changed = true
		}
	}
	return
}

// A colour of display values as "#RRGGBB" into `buf`, ended by a zero byte.
color_hex_format :: proc(rgb: [3]f32, buf: []u8) {
	digits := "0123456789ABCDEF"
	if len(buf) < 8 do return
	buf[0] = '#'
	for c, i in rgb {
		b := int(math.round(clamp(c, 0, 1) * 255))
		buf[1 + 2 * i] = digits[b >> 4]
		buf[2 + 2 * i] = digits[b & 15]
	}
	buf[7] = 0
}

// The same "#RRGGBB" as a temp string, for stats and messages.
hex_text :: proc(rgb: [3]f32) -> string {
	buf := make([]u8, 8, context.temp_allocator)
	color_hex_format(rgb, buf)
	return string(buf[:7])
}

// A hex colour code as display values: six digits, or three that each stand for two
// ("#3A7" is "#33AA77"), with or without the "#" and in either case, spaces around
// allowed. Anything else is not a colour.
color_hex_parse :: proc(text: string) -> (rgb: [3]f32, ok: bool) {
	s := strings.trim_prefix(strings.trim_space(text), "#")
	digit :: proc(c: u8) -> (int, bool) {
		switch c {
		case '0' ..= '9': return int(c - '0'), true
		case 'a' ..= 'f': return int(c - 'a') + 10, true
		case 'A' ..= 'F': return int(c - 'A') + 10, true
		}
		return 0, false
	}
	short := len(s) == 3
	if !short && len(s) != 6 do return
	for i in 0 ..< 3 {
		hi, lo: int
		ok_hi, ok_lo: bool
		if short {
			hi, ok_hi = digit(s[i])
			lo, ok_lo = hi, ok_hi
		} else {
			hi, ok_hi = digit(s[2 * i])
			lo, ok_lo = digit(s[2 * i + 1])
		}
		if !ok_hi || !ok_lo do return
		rgb[i] = f32(hi * 16 + lo) / 255
	}
	return rgb, true
}

// A count (vertices, quads) on a logarithmic slider, rounded to two significant
// figures, since a count picked off a slider is meant roughly. Returns true when it
// changed.
kit_count :: proc(ctx: ^ui.Context, s: string, value: ^i32, lo, hi: i32) -> bool {
	v := f32(value^)
	if !ui.slider(ctx, s, &v, f32(lo), f32(hi), .Logarithmic, count_label(int(value^))) do return false
	step := math.pow(10, math.floor(math.log10(max(v, 1))) - 1)
	value^ = clamp(i32(math.round(v / step) * step), lo, hi)
	return true
}

// Two command buttons side by side across the column (command_button): each with its
// label (or the table's), its shortcut and gesture in its tooltip, and enabled while its
// command can run (and `enabled_*`). Runs the one clicked.
kit_command_pair :: proc(app: ^App, a: Command_Id, b: Command_Id, arg_a := 0, arg_b := 0, label_a := "", label_b := "", enabled_a := true, enabled_b := true, tone_a := ui.Tone.Neutral, tone_b := ui.Tone.Neutral) {
	ctx := &app.kit.ctx
	half := (ui.fill_width(ctx) - 8) * 0.5
	text_a := label_a if label_a != "" else command_label(a, arg_a)
	text_b := label_b if label_b != "" else command_label(b, arg_b)
	ui.begin(ctx, fmt.tprintf("%s|%s", text_a, text_b), {direction = .Row, gap = 8})
	_ = command_button(app, a, arg_a, text_a, tone = tone_a, width = half, enabled = enabled_a)
	_ = command_button(app, b, arg_b, text_b, tone = tone_b, width = half, enabled = enabled_b)
	ui.end(ctx)
}

// Two buttons side by side across the column, the second greyed when `enabled_b` is
// false, for actions that are not commands (kit_command_pair for those that are).
// Returns which was clicked.
kit_button_pair :: proc(ctx: ^ui.Context, a, b: string, enabled_a := true, enabled_b := true, tone_a := ui.Tone.Neutral, tone_b := ui.Tone.Neutral) -> (clicked_a, clicked_b: bool) {
	half := (ui.fill_width(ctx) - 8) * 0.5
	ui.begin(ctx, fmt.tprintf("%s|%s", a, b), {direction = .Row, gap = 8})
	clicked_a = ui.button(ctx, a, .Flat, tone_a, width = half, enabled = enabled_a)
	clicked_b = ui.button(ctx, b, .Flat, tone_b, width = half, enabled = enabled_b)
	ui.end(ctx)
	return
}

// The rest of an inspector section after its basic controls (at most five), under a
// More options fold that `sec` remembers, or shown outright with Show every option
// (ui.more). Returns true when there is a body to fill, which kit_more_end closes.
kit_more :: proc(app: ^App, sec: Kit_Section) -> bool {
	k := &app.kit
	return ui.more(&k.ctx, fmt.tprintf("more##%v", sec), &k.more[sec], k.all_options)
}

kit_more_end :: proc(app: ^App) {
	ui.more_end(&app.kit.ctx)
}
