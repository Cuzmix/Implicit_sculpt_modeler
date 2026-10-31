package ui

import "core:math"

// Themes made from a few choices. A Theme_Seed holds what a person picks in Settings >
// Interface > Look (dark or light, a tint, a contrast, an accent and so on) and
// theme_derive turns it into every colour of a Theme, so one slider moves a whole family
// of colours together instead of each one being set by hand. Sizes and timings never
// come from a seed: a theme changes how the interface looks, never where anything sits.

Theme_Mode :: enum u8 {
	Dark,
	Light,
}

// How round the corners are: Normal is Lens's and Graphite's, Round is Studio's.
Theme_Corners :: enum u8 {
	Square,
	Normal,
	Round,
}

// How a chosen brush tile shows: Soft is the accent's faint wash with the icon and name
// in the accent (Lens), Solid the accent itself (Studio, Graphite).
Theme_Chosen :: enum u8 {
	Soft,
	Solid,
}

Theme_Seed :: struct {
	mode:     Theme_Mode,
	hue:      f32, // the tint's hue, in degrees
	tint:     f32, // how much of it the greys take, 0 (neutral) to 1
	contrast: f32, // how far the surfaces and text step apart, 0 to 1 (0.5 is normal)
	opacity:  f32, // the panels' opacity over the view, THEME_OPACITY_MIN to 1
	corners:  Theme_Corners,
	accent:   Color,
	chosen:   Theme_Chosen,
	black:    bool, // a pure black ground, for OLED screens (dark only)
	shadow:   bool, // a shadow under the panels
}

// Below this the panels' text would fight the model behind them.
THEME_OPACITY_MIN :: 0.6

// The greys' lightness (HSL, in percent) at normal contrast, taken from Lens so a Lens
// seed comes out close to Lens. Each is moved toward or away from the surface by the
// contrast. Light themes have their own steps, the surfaces near white.
@(private = "file")
Levels :: struct {
	frame, frame_line, pane, surface, raised, fill, cursor, cursor_line, track, border, border_strong: f32,
	text, text_secondary, text_tertiary: f32,
}

@(private = "file", rodata)
LEVELS_DARK := Levels {
	frame          = 6.1,
	frame_line     = 12.9,
	pane           = 11.6,
	surface        = 10.4,
	raised         = 14.3,
	fill           = 17.6,
	cursor         = 14.3,
	cursor_line    = 26.9,
	track          = 25.9,
	border         = 19.4,
	border_strong  = 26.9,
	text           = 92.5,
	text_secondary = 68.8,
	text_tertiary  = 46.3,
}

@(private = "file", rodata)
LEVELS_LIGHT := Levels {
	frame          = 87,
	frame_line     = 80,
	pane           = 91,
	surface        = 97,
	raised         = 100,
	fill           = 91.5,
	cursor         = 100,
	cursor_line    = 77,
	track          = 80,
	border         = 85,
	border_strong  = 75,
	text           = 12,
	text_secondary = 34,
	text_tertiary  = 47,
}

// How far below the dark steps a pure black ground puts every grey.
@(private = "file")
BLACK_DROP :: 5.5

// The most saturation a full tint gives the greys, in percent; Lens's tint of 0.5 is its
// surface's 17 percent.
@(private = "file")
TINT_SATURATION :: 34

// The corner radii (small, medium, large) of each Theme_Corners.
@(private = "file", rodata)
CORNER_RADII := [Theme_Corners][3]f32 {
	.Square = {3, 4, 6},
	.Normal = {6, 8, 12},
	.Round  = {6, 10, 14},
}

// From this contrast on the hairlines take the text's greys, so every panel edge is
// plainly drawn (High contrast).
@(private = "file")
STRONG_LINES :: 0.9

// A colour from hue (degrees), saturation and lightness (both percent), opaque.
color_hsl :: proc(hue, saturation, lightness: f32) -> Color {
	s := clamp(saturation, 0, 100) / 100
	l := clamp(lightness, 0, 100) / 100
	h := math.mod(math.mod(hue, 360) + 360, 360)
	a := s * min(l, 1 - l)
	channel :: proc(n, h, l, a: f32) -> u8 {
		k := math.mod(n + h / 30, 12)
		v := l - a * max(-1, min(k - 3, 9 - k, 1))
		return u8(clamp(v, 0, 1) * 255 + 0.5)
	}
	return {channel(0, h, l, a), channel(8, h, l, a), channel(4, h, l, a), 255}
}

// The relative luminance of `c` (WCAG 2), ignoring its alpha.
color_luminance :: proc(c: Color) -> f32 {
	lin :: proc(v: u8) -> f32 {
		x := f32(v) / 255
		return x / 12.92 if x <= 0.04045 else math.pow((x + 0.055) / 1.055, 2.4)
	}
	return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
}

// The WCAG 2 contrast ratio of two opaque colours, 1 to 21: 4.5 is the least for text
// people read, 3 for large text and for marks such as the accent.
color_contrast :: proc(a, b: Color) -> f32 {
	x, y := color_luminance(a), color_luminance(b)
	return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}

// Every colour of a theme from its seed; sizes, timings and the cameras' other colours
// come from `base`.
theme_derive :: proc(seed: Theme_Seed, base := THEME_LENS) -> Theme {
	t := base
	light := seed.mode == .Light
	lv := LEVELS_LIGHT if light else LEVELS_DARK
	if seed.black && !light {
		lv.frame, lv.pane = 0, 0
		for p in ([]^f32{&lv.frame_line, &lv.surface, &lv.raised, &lv.fill, &lv.cursor, &lv.cursor_line, &lv.track, &lv.border, &lv.border_strong}) do p^ = max(p^ - BLACK_DROP, 0)
	}
	k := 0.55 + clamp(seed.contrast, 0, 1) * 0.9
	sat := clamp(seed.tint, 0, 1) * TINT_SATURATION
	h := seed.hue
	step :: proc(level, surface, k: f32) -> f32 {
		return surface + (level - surface) * k
	}
	grey := proc(h, sat, level, surface, k: f32) -> Color {
		return color_hsl(h, sat, step(level, surface, k))
	}
	s := lv.surface
	t.frame = color_hsl(h, sat, lv.frame) if !(seed.black && !light) else {0, 0, 0, 255}
	t.pane = color_hsl(h, sat, lv.pane) if !(seed.black && !light) else {0, 0, 0, 255}
	t.frame_line = grey(h, sat, lv.frame_line, s, k)
	solid := color_hsl(h, sat, s)
	t.surface = {solid.r, solid.g, solid.b, u8(clamp(seed.opacity, THEME_OPACITY_MIN, 1) * 255 + 0.5)}
	t.surface_raised = grey(h, sat, lv.raised, s, k)
	t.fill = grey(h, sat, lv.fill, s, k)
	t.cursor = grey(h, sat, lv.cursor, s, k)
	t.cursor_line = grey(h, sat, lv.cursor_line, s, k)
	t.track = grey(h, sat, lv.track, s, k)
	t.border = grey(h, sat, lv.border, s, k)
	t.border_strong = grey(h, sat, lv.border_strong, s, k)
	t.text = grey(h, sat * 0.4, lv.text, s, min(k, 1.1))
	t.text_secondary = grey(h, sat * 0.6, lv.text_secondary, s, k)
	t.text_tertiary = grey(h, sat * 0.6, lv.text_tertiary, s, k)
	if seed.contrast >= STRONG_LINES {
		t.border, t.border_strong = t.text_tertiary, t.text_secondary
	}
	if light {
		t.fill_hover = {0, 0, 0, 0x0d}
		t.fill_pressed = {0, 0, 0, 0x17}
		t.shadow = {20, 24, 30, 0x55}
		t.panel_shadow = {20, 24, 30, 0x24} if seed.shadow else {}
	} else {
		t.fill_hover = {0xff, 0xff, 0xff, 0x0f}
		t.fill_pressed = {0xff, 0xff, 0xff, 0x1a}
		t.shadow = {0, 0, 0, 0x80}
		t.panel_shadow = {0, 0, 0, 0x66} if seed.shadow else {}
	}

	a := seed.accent
	a.a = 255
	t.accent = a
	t.accent_soft = color_mix(solid, a, 0.15 if light else 0.17)
	// The ink on the accent is white or the accent's own near-black, whichever reads better.
	ink := color_mix(a, {0, 0, 0, 255}, 0.88)
	white := Color{0xff, 0xff, 0xff, 0xff}
	t.on_accent = ink if color_contrast(ink, a) > color_contrast(white, a) else white
	switch seed.chosen {
	case .Soft:
		t.chosen = t.accent_soft
		t.on_chosen = color_mix(a, {0, 0, 0, 255}, 0.35) if light else a
	case .Solid:
		t.chosen = a
		t.on_chosen = t.on_accent
	}
	if light {
		t.knob, t.knob_off = {0xff, 0xff, 0xff, 0xff}, {0xff, 0xff, 0xff, 0xff}
		t.success = {0x1f, 0x92, 0x54, 0xff}
		t.warning = {0xb2, 0x6a, 0x00, 0xff}
		t.danger = {0xc8, 0x35, 0x2c, 0xff}
	} else {
		t.knob, t.knob_off = t.text, t.text_secondary
		t.success = {0x74, 0xcc, 0x7c, 0xff}
		t.warning = {0xf3, 0xb5, 0x4a, 0xff}
		t.danger = {0xf0, 0x6a, 0x5e, 0xff}
	}
	t.knob_on = t.on_accent
	t.camera[0] = a
	// The space tints read on the frame: darker on a light one, with soft fills mixed
	// toward the surface either way.
	for i in 0 ..< len(t.tints) {
		tint := base.tints[i]
		if light do tint = color_mix(tint, {0, 0, 0, 255}, 0.3)
		t.tints[i] = tint
		t.tints_soft[i] = color_mix(solid, tint, 0.16 if light else 0.2)
	}
	r := CORNER_RADII[seed.corners]
	t.radius_small, t.radius_medium, t.radius_large = r[0], r[1], r[2]
	return t
}

// The theme a seed makes when it began as one of the app's exact themes: wherever the
// seed still holds what `exact_seed` held, those colours stay `exact`'s to the last bit,
// so changing only the accent of Lens leaves Lens's greys alone, and an untouched seed
// gives `exact` itself.
theme_from_seed :: proc(seed: Theme_Seed, exact: Theme, exact_seed: Theme_Seed) -> Theme {
	if seed == exact_seed do return exact
	t := theme_derive(seed, exact)
	greys_same := seed.mode == exact_seed.mode && seed.hue == exact_seed.hue && seed.tint == exact_seed.tint && seed.contrast == exact_seed.contrast && seed.black == exact_seed.black
	if greys_same {
		accent, accent_soft, on_accent, chosen, on_chosen := t.accent, t.accent_soft, t.on_accent, t.chosen, t.on_chosen
		knob_on, camera0 := t.knob_on, t.camera[0]
		corners := [3]f32{t.radius_small, t.radius_medium, t.radius_large}
		surface_alpha, panel_shadow := t.surface.a, t.panel_shadow
		t = exact
		if seed.accent != exact_seed.accent || seed.chosen != exact_seed.chosen {
			// The exact theme's own way with the accent carries over: a see-through wash
			// stays see-through, and knobs that were not drawn in the accent's ink stay as
			// they were.
			soft := accent_soft
			if exact.accent_soft.a < 255 do soft = {accent.r, accent.g, accent.b, exact.accent_soft.a}
			if seed.chosen == .Soft do chosen = soft
			if exact.knob_on == exact.on_accent do t.knob_on = knob_on
			t.accent, t.accent_soft, t.on_accent, t.chosen, t.on_chosen = accent, soft, on_accent, chosen, on_chosen
			t.camera[0] = camera0
		}
		if seed.corners != exact_seed.corners do t.radius_small, t.radius_medium, t.radius_large = corners[0], corners[1], corners[2]
		if seed.opacity != exact_seed.opacity do t.surface.a = surface_alpha
		if seed.shadow != exact_seed.shadow do t.panel_shadow = panel_shadow
	}
	return t
}

// The seeds of the app's themes. Lens, Studio and Graphite each have an exact Theme
// beside them that their seed comes close to; the others are only seeds.
THEME_SEED_LENS :: Theme_Seed{.Dark, 213, 0.5, 0.5, 0.96, .Normal, {0x5e, 0xd6, 0xc4, 0xff}, .Soft, false, true}
THEME_SEED_STUDIO :: Theme_Seed{.Dark, 0, 0, 0.5, 0.957, .Round, {0xf2, 0xa3, 0x3a, 0xff}, .Solid, false, false}
THEME_SEED_GRAPHITE :: Theme_Seed{.Dark, 232, 0.3, 0.5, 0.941, .Normal, {0x5b, 0x8c, 0xff, 0xff}, .Solid, false, false}
// "Paper": a warm light theme for a bright room, its accent a deep sea green that reads on white.
THEME_SEED_PAPER :: Theme_Seed{.Light, 40, 0.3, 0.5, 0.97, .Normal, {0x1a, 0x7a, 0x6a, 0xff}, .Soft, false, true}
// "Midnight": a pure black ground for OLED screens, where black pixels are off.
THEME_SEED_MIDNIGHT :: Theme_Seed{.Dark, 225, 0.3, 0.5, 0.9, .Round, {0xa0, 0x8c, 0xff, 0xff}, .Soft, true, false}
// "High contrast": white text and plain hairlines on black, with a yellow accent.
THEME_SEED_HIGH_CONTRAST :: Theme_Seed{.Dark, 0, 0, 1, 1, .Normal, {0xff, 0xd6, 0x0a, 0xff}, .Solid, true, false}

// A theme's card in a gallery: a small picture of the theme (its frame, a bar, a panel
// with lines of its text, a clay ball and an accent dot) over `s`, with `tag` (Yours,
// New) faint at the right of the name. `selected` rings it with the accent of the theme
// the gallery is drawn in. A long press (or a right-click) asks for its menu.
THEME_CARD :: [2]f32{104, 92}

theme_card :: proc(ctx: ^Context, s: string, look: Theme, selected: bool, tag := "") -> (res: Tile_Result) {
	ctx.controls += 1
	t := ctx.theme
	cell := place(ctx, THEME_CARD)
	vis := Rect{cell.x + 3, cell.y + 3, cell.w - 6, cell.h - 6}
	id := id_of(ctx, s)
	hovered, held, clicked, _ := interact(ctx, id, cell)
	res.clicked = clicked
	fill_rect(ctx, vis, t.radius_medium, t.fill)
	_ = feedback(ctx, id, vis, t.radius_medium, hovered, held)
	pic := Rect{vis.x + 4, vis.y + 4, vis.w - 8, 50}
	res.picture = pic
	fill_rect(ctx, pic, max(t.radius_medium - 3, 2), {look.frame.r, look.frame.g, look.frame.b, 255})
	bar := Rect{pic.x + 5, pic.y + 4, pic.w - 10, 9}
	fill_rect(ctx, bar, 3, {look.surface.r, look.surface.g, look.surface.b, 255})
	stroke_rect(ctx, bar, 3, look.border, 1)
	panel := Rect{pic.x + 5, pic.y + 17, pic.w * 0.36, pic.h - 22}
	fill_rect(ctx, panel, 3, {look.surface.r, look.surface.g, look.surface.b, 255})
	stroke_rect(ctx, panel, 3, look.border, 1)
	lines := [3]Color{look.text, look.text_tertiary, look.accent}
	widths := [3]f32{0.7, 0.9, 0.5}
	for c, i in lines do fill_rect(ctx, {panel.x + 4, panel.y + 4 + f32(i) * 5, (panel.w - 8) * widths[i], 2.5}, 1, c)
	ball := [2]f32{pic.x + pic.w * 0.66, pic.y + pic.h * 0.58}
	fill_circle(ctx, ball, 10, {184, 148, 130, 255})
	fill_circle(ctx, ball - {3, 3}, 5, {222, 192, 174, 255})
	fill_circle(ctx, {pic.x + pic.w - 10, pic.y + pic.h - 10}, 6, look.accent)
	name := label_text(s)
	text(ctx, name, vis.x + 6, vis.y + vis.h - 12, t.small_size, t.text)
	// The tag gives way to a long name rather than running into it.
	if tag != "" && text_width(ctx, name, t.small_size) + text_width(ctx, tag, t.caption_size) + 18 <= vis.w {
		text(ctx, tag, vis.x + vis.w - 6, vis.y + vis.h - 12, t.caption_size, t.text_tertiary, .Semibold, .Right)
	}
	if selected do stroke_rect(ctx, vis, t.radius_medium, t.accent, 2)
	res.menu = secondary(ctx)
	tip(ctx, id, vis, name)
	return
}
