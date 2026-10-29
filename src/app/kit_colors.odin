package main

import "core:fmt"
import "core:math"
import "core:strings"

import "../sculpt"
import "../ui"

// The Colors card: the Colors command opens it beside the off-hand island, where ZBrush
// for iPad puts its Color card, laid out and named as Procreate's Colors panel. On top, the
// main and secondary colours (a tap picks the one the pickers edit, a long press swaps
// them), Swap, Fill object, Fill gradient (ZBrush's FillObject and FillObject Grad), the
// Eyedropper and Close; then one of Procreate's five ways to pick, chosen by the tabs along
// the bottom: Disc, Classic, Harmony, Value and Palettes. Under the first four, the last
// colours picked and the default palette. It stays open while you paint, as both apps'
// cards do; the dots drag it, and holding them puts it back in the tray's Colour section.
// The design and which app each part comes from: notes/colors/colors-card-design.md.

// The card's width: seven touch-sized swatches across inside its padding.
COLORS_CARD_W :: 2 * COLORS_PADDING + SWATCH_COLUMNS * SWATCH_SIDE
COLORS_PADDING :: 12
COLORS_GAP :: 6
// Swatches stay a whole touch target each (sm-store), so a row holds seven.
SWATCH_SIDE :: 48
SWATCH_COLUMNS :: 7
// The history is one row of the last colours picked (Procreate keeps ten in a narrower cell).
COLOR_HISTORY :: SWATCH_COLUMNS
// Palettes of your own and the swatches each holds: four rows.
USER_PALETTES :: 8
PALETTE_SWATCHES :: 4 * SWATCH_COLUMNS
PALETTE_NAME :: 24

// Procreate's tabs, in its order.
Colors_Tab :: enum u8 {
	Disc,
	Classic,
	Harmony,
	Value,
	Palettes,
}

@(rodata)
COLORS_TAB_NAMES := [Colors_Tab]string {
	.Disc     = "Disc",
	.Classic  = "Classic",
	.Harmony  = "Harmony",
	.Value    = "Value",
	.Palettes = "Palettes",
}

// Lucide's circle, square, split, sliders-horizontal and grid-3x3, as Procreate's tab icons.
@(rodata)
COLORS_TAB_ICONS := [Colors_Tab]rune {
	.Disc     = 0xe07a,
	.Classic  = 0xe16b,
	.Harmony  = 0xe445,
	.Value    = 0xe29a,
	.Palettes = 0xe0ec,
}

// Procreate's colour schemes on the Harmony tab.
Harmony :: enum u8 {
	Complementary,
	Split_Complementary,
	Analogous,
	Triadic,
	Tetradic,
}

@(rodata)
HARMONY_NAMES := [Harmony]string {
	.Complementary       = "Complementary",
	.Split_Complementary = "Split Complementary",
	.Analogous           = "Analogous",
	.Triadic             = "Triadic",
	.Tetradic            = "Tetradic",
}

// A palette of your own: its name (a zero-ended buffer, a text field's) and its swatches.
Swatch_Palette :: struct {
	name:   [PALETTE_NAME]u8,
	count:  int,
	colors: [PALETTE_SWATCHES][3]f32,
}

// A palette that comes with the app: a name and its swatches as 0xRRGGBB.
Built_In_Palette :: struct {
	name:   string,
	colors: [2 * SWATCH_COLUMNS]u32,
}

// Two rows each, for sculptors: skin from pale to deep with blush and lips; a creature's
// greens, bone, gums and eyes; clays, stones and metals; a grey ramp; and vivid colours far
// apart, for marking parts.
@(rodata)
BUILT_IN_PALETTES := [?]Built_In_Palette {
	{"Skin", {0xF8E1D4, 0xF3D0BE, 0xEBC0A8, 0xE2AD92, 0xD49A7E, 0xC58468, 0xB06F55, 0x9A5C45, 0x82493A, 0x6B3A2F, 0x553026, 0xE7A49B, 0xC97A72, 0x8E4B57}},
	{"Creature", {0xC7CC8A, 0xA7B46A, 0x869A55, 0x667F45, 0x4A5E36, 0x8C8A4E, 0xB59E5A, 0xD6C08A, 0xE9DDBE, 0xF2EBD9, 0xC9A26B, 0x9B3B3B, 0xD9C24A, 0x3B2A20}},
	{"Clay and stone", {0xC4AA99, 0xB07B5E, 0x9C5B43, 0x8A6B5A, 0xD9CFC4, 0xBDB6AD, 0x9C978F, 0x77736E, 0x55524F, 0x3A3836, 0xCDB27A, 0xA9773F, 0x7D8A80, 0xE8E4DC}},
	{"Greys", {0x000000, 0x141414, 0x262626, 0x3A3A3A, 0x4F4F4F, 0x636363, 0x787878, 0x8E8E8E, 0xA3A3A3, 0xB8B8B8, 0xCDCDCD, 0xE1E1E1, 0xF0F0F0, 0xFFFFFF}},
	{"Vivid", {0xE6194B, 0xF58231, 0xFFE119, 0xBFEF45, 0x3CB44B, 0x42D4F4, 0x4363D8, 0x911EB4, 0xF032E6, 0xFABED4, 0xFFD8B1, 0xAAFFC3, 0xDCBEFF, 0x800000}},
}

// The card's state between frames, and what it remembers (settings.odin).
Colors_Card :: struct {
	tab:       Colors_Tab,
	harmony:   Harmony,
	value_rgb: bool, // the Value tab shows Red, Green and Blue rather than Hue, Saturation and Brightness
	editing:   int, // 0 the main colour, 1 the secondary: the one the pickers set
	// The edited colour as hue, saturation and brightness (0 to 1), kept so the hue
	// survives a grey and the saturation a black; re-read when the colour changed
	// elsewhere (`seen` is what it was when last set or read here).
	hsv:       [3]f32,
	seen:      [3]f32,
	seen_of:   int,
	changed:   bool, // the colour changed since the history last took it
	drag:      int, // what a press on the Disc took: 1 the hue ring, 2 the inner disc
	harmony_drag: int, // the Harmony reticle held: 0 the main one, 1 and up the others
	scroll:    f32,
	history:       [COLOR_HISTORY][3]f32, // most recent first
	history_count: int,
	palettes:      [USER_PALETTES]Swatch_Palette,
	palette_count: int,
	// The palette shown under the pickers: a built-in's place, or len(BUILT_IN_PALETTES)
	// plus one of yours.
	default_palette: int,
	// A palette's menu and a swatch's (your palettes only): open, where, on which.
	palette_menu:    bool,
	palette_menu_at: ui.Rect,
	palette_menu_of: int,
	swatch_menu:     bool,
	swatch_menu_at:  ui.Rect,
	swatch_menu_of:  [2]int, // the palette (yours) and the swatch
	tray_was:        bool,
	// The colour popover (kit_color_popover), which a tap on any colour field's well
	// opens: open, which field (its well's id) and where; the field's colour as it last
	// showed it, what the popover set and whether the field is still to take that (next
	// frame, so the field reports the change as its own), whether the field was drawn this
	// frame (a popover whose panel closed goes with it), and a pick waiting for the history.
	pop:         bool,
	pop_of:      ui.Id,
	pop_at:      ui.Rect,
	pop_value:   [3]f32,
	pop_set:     [3]f32,
	pop_dirty:   bool,
	pop_alive:   bool,
	pop_changed: bool,
	pop_scroll:  f32,
	// Set only while the popover draws: the colour its pickers set instead of the brush's.
	override:    ^[3]f32,
}

// Opens the card, or puts it away.
colors_card_toggle :: proc(app: ^App) {
	k := &app.kit
	k.colors_card = !k.colors_card
	if k.colors_card do k.bar_pop.open = false
}

// The colour the pickers set: the colour popover's while it draws, else the brush's main
// or secondary one.
colors_target :: proc(app: ^App) -> ^[3]f32 {
	c := &app.kit.colors
	if c.override != nil do return c.override
	return &app.brush.color2 if c.editing == 1 else &app.brush.color
}

// Which colour the pickers set, as colors_sync compares it: 0 and 1 the brush's, 2 the
// popover's.
@(private = "file")
colors_editing :: proc(c: ^Colors_Card) -> int {
	return 2 if c.override != nil else c.editing
}

// Re-reads the edited colour as hue, saturation and brightness when it changed elsewhere
// (Swap, a preset, a script) or the other colour was picked to edit.
@(private = "file")
colors_sync :: proc(app: ^App) {
	c := &app.kit.colors
	rgb := colors_target(app)^
	if rgb == c.seen && c.seen_of == colors_editing(c) do return
	c.hsv = rgb_to_hsv(rgb, c.hsv)
	c.seen, c.seen_of = rgb, colors_editing(c)
}

// Sets the edited colour from hue, saturation and brightness.
colors_set_hsv :: proc(app: ^App, hsv: [3]f32) {
	c := &app.kit.colors
	c.hsv = hsv
	colors_target(app)^ = hsv_to_rgb(hsv)
	c.seen, c.seen_of, c.changed = colors_target(app)^, colors_editing(c), true
}

// Sets the edited colour from display red, green and blue.
colors_set_rgb :: proc(app: ^App, rgb: [3]f32) {
	c := &app.kit.colors
	colors_target(app)^ = rgb
	c.hsv = rgb_to_hsv(rgb, c.hsv)
	c.seen, c.seen_of, c.changed = rgb, colors_editing(c), true
}

// Makes `rgb` the edited colour at once and puts it in the history: a swatch tapped, the
// eyedropper's pick, a harmony colour.
colors_pick :: proc(app: ^App, rgb: [3]f32) {
	colors_set_rgb(app, rgb)
	color_history_push(&app.kit.colors, rgb)
	app.kit.colors.changed = false
}

// Puts `rgb` first in the history, taking out the same colour further down (compared as
// the bytes a screen shows) and the oldest once it is full.
color_history_push :: proc(c: ^Colors_Card, rgb: [3]f32) {
	at := c.history_count
	for h, i in c.history[:c.history_count] do if color_bytes(h) == color_bytes(rgb) do at = i
	if at == c.history_count && c.history_count < COLOR_HISTORY do c.history_count += 1
	last := min(at, COLOR_HISTORY - 1)
	for i := last; i > 0; i -= 1 do c.history[i] = c.history[i - 1]
	c.history[0] = rgb
}

// A display colour as the bytes a screen shows.
color_bytes :: proc(rgb: [3]f32) -> [3]u8 {
	return {u8(clamp(rgb.r, 0, 1) * 255 + 0.5), u8(clamp(rgb.g, 0, 1) * 255 + 0.5), u8(clamp(rgb.b, 0, 1) * 255 + 0.5)}
}

// A display colour as the kit draws it.
shade :: proc(rgb: [3]f32) -> ui.Color {
	b := color_bytes(rgb)
	return {b.r, b.g, b.b, 255}
}

// A 0xRRGGBB colour as display values.
color_of_u32 :: proc(x: u32) -> [3]f32 {
	return {f32((x >> 16) & 255) / 255, f32((x >> 8) & 255) / 255, f32(x & 255) / 255}
}

// Display red, green and blue as hue, saturation and brightness, all 0 to 1. A grey has
// no hue and a black no saturation, so they keep `keep`'s.
rgb_to_hsv :: proc(rgb: [3]f32, keep: [3]f32 = {}) -> (hsv: [3]f32) {
	r, g, b := clamp(rgb.r, 0, 1), clamp(rgb.g, 0, 1), clamp(rgb.b, 0, 1)
	hi := max(r, g, b)
	lo := min(r, g, b)
	d := hi - lo
	hsv.z = hi
	hsv.y = d / hi if hi > 0 else keep.y
	if d <= 0 {
		hsv.x = keep.x
		return
	}
	h: f32
	switch hi {
	case r: h = (g - b) / d
	case g: h = 2 + (b - r) / d
	case:   h = 4 + (r - g) / d
	}
	h /= 6
	if h < 0 do h += 1
	hsv.x = h
	return
}

// Hue, saturation and brightness (0 to 1; the hue wraps) as display red, green and blue.
hsv_to_rgb :: proc(hsv: [3]f32) -> [3]f32 {
	h := hsv.x - math.floor(hsv.x)
	s, v := clamp(hsv.y, 0, 1), clamp(hsv.z, 0, 1)
	k := [3]f32{5, 3, 1}
	out: [3]f32
	for &c, i in out {
		x := math.mod(k[i] + h * 6, 6)
		c = v - v * s * max(min(x, 4 - x, 1), 0)
	}
	return out
}

// The hues of a scheme, as turns from the main colour's: the first is always 0. Split
// Complementary and Analogous sit 30 degrees either side of the complement and of the
// colour; Triadic splits the wheel in three, Tetradic in four (a square).
harmony_offsets :: proc(h: Harmony) -> []f32 {
	@(static, rodata) COMPLEMENTARY := []f32{0, 0.5}
	@(static, rodata) SPLIT := []f32{0, 0.5 - 1.0 / 12, 0.5 + 1.0 / 12}
	@(static, rodata) ANALOGOUS := []f32{0, -1.0 / 12, 1.0 / 12}
	@(static, rodata) TRIADIC := []f32{0, 1.0 / 3, 2.0 / 3}
	@(static, rodata) TETRADIC := []f32{0, 0.25, 0.5, 0.75}
	switch h {
	case .Complementary:       return COMPLEMENTARY
	case .Split_Complementary: return SPLIT
	case .Analogous:           return ANALOGOUS
	case .Triadic:             return TRIADIC
	case .Tetradic:            return TETRADIC
	}
	return COMPLEMENTARY
}

// The Disc's inner circle holds every saturation (across, left to right) and brightness
// (up, bottom to top) as a square stretched into a circle (the elliptical grid mapping),
// so its rim reaches every edge of the square. These map a point of the square
// (-1 to 1 each way) into the unit circle and back.
disc_from_square :: proc(p: [2]f32) -> [2]f32 {
	u, v := clamp(p.x, -1, 1), clamp(p.y, -1, 1)
	return {u * math.sqrt(1 - v * v * 0.5), v * math.sqrt(1 - u * u * 0.5)}
}

square_from_disc :: proc(q: [2]f32) -> [2]f32 {
	p := q
	if l := math.sqrt(p.x * p.x + p.y * p.y); l > 1 do p /= l
	x2, y2 := p.x * p.x, p.y * p.y
	r2 := f32(2 * math.SQRT_TWO)
	root :: proc(x: f32) -> f32 {return math.sqrt(max(x, 0))}
	u := 0.5 * root(2 + x2 - y2 + r2 * p.x) - 0.5 * root(2 + x2 - y2 - r2 * p.x)
	v := 0.5 * root(2 - x2 + y2 + r2 * p.y) - 0.5 * root(2 - x2 + y2 - r2 * p.y)
	return {clamp(u, -1, 1), clamp(v, -1, 1)}
}

// The palette `n` (default_palette's numbering): its name and swatches, in temp memory
// for a built-in's.
palette_swatches :: proc(app: ^App, n: int) -> (name: string, colors: [][3]f32, mine: bool) {
	c := &app.kit.colors
	if n < len(BUILT_IN_PALETTES) {
		p := BUILT_IN_PALETTES[max(n, 0)]
		out := make([][3]f32, len(p.colors), context.temp_allocator)
		for x, i in p.colors do out[i] = color_of_u32(x)
		return p.name, out, false
	}
	p := &c.palettes[n - len(BUILT_IN_PALETTES)]
	return string(p.name[:name_len(p.name[:])]), p.colors[:p.count], true
}

// The bytes before the zero that ends `buf`, or all of them.
@(private = "file")
name_len :: proc(buf: []u8) -> int {
	for b, i in buf do if b == 0 do return i
	return len(buf)
}

// Makes a palette of your own, empty and named "Palette N", and the default, as
// Procreate's +; returns its place among yours, or -1 when all USER_PALETTES are made.
palette_new :: proc(c: ^Colors_Card) -> int {
	if c.palette_count == USER_PALETTES do return -1
	i := c.palette_count
	c.palettes[i] = {}
	palette_name_set(&c.palettes[i], fmt.tprintf("Palette %d", i + 1))
	c.palette_count += 1
	c.default_palette = len(BUILT_IN_PALETTES) + i
	return i
}

// Names palette `p` `name`, cut to fit and ended by a zero.
palette_name_set :: proc(p: ^Swatch_Palette, name: string) {
	p.name = {}
	_ = copy(p.name[:PALETTE_NAME - 1], name)
}

// Takes out your palette `i`, the default moving with the ones after it.
palette_delete :: proc(c: ^Colors_Card, i: int) {
	if i < 0 || i >= c.palette_count do return
	for j in i ..< c.palette_count - 1 do c.palettes[j] = c.palettes[j + 1]
	c.palette_count -= 1
	n := len(BUILT_IN_PALETTES) + i
	if c.default_palette == n {
		c.default_palette = 0
	} else if c.default_palette > n {
		c.default_palette -= 1
	}
}

// Takes swatch `j` out of your palette `i`.
palette_swatch_delete :: proc(c: ^Colors_Card, i, j: int) {
	if i < 0 || i >= c.palette_count do return
	p := &c.palettes[i]
	if j < 0 || j >= p.count do return
	for k in j ..< p.count - 1 do p.colors[k] = p.colors[k + 1]
	p.count -= 1
}

// Draws the card; returns true when a press landed on it, to bring it to the front.
kit_colors_card :: proc(app: ^App) -> (raised: bool) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	c := &k.colors
	if !k.colors_card do c.palette_menu, c.swatch_menu = false, false
	shown := ui.presence(ctx, panel_id(Kit_Window.Colors), k.colors_card, t.panel_time)
	if shown <= 0 do return
	// A default left by a palette deleted, or read before your palettes were.
	if c.default_palette >= len(BUILT_IN_PALETTES) + c.palette_count do c.default_palette = 0
	colors_sync(app)
	win := &k.windows[.Colors]
	inner := f32(SWATCH_COLUMNS * SWATCH_SIDE)
	top := kit_top()
	mark := ui.vertex_mark(ctx)
	p := panel_begin(app, Kit_Window.Colors, "Colors", .Start, .Start, {kit_left(app), top}, {direction = .Column, gap = COLORS_GAP, padding = COLORS_PADDING, width = COLORS_CARD_W, radius = t.radius_large, background = .Panel, inert = !k.colors_card}, card = true)
	raised = p.raised
	id := p.owner
	if p.closed do k.colors_card = false
	if p.dock && k.colors_card {
		k.colors_card = false
		tray_open(app, .Paint_Color)
	}
	if !p.body {
		panel_end(app, &p)
		ui.transform_since(ctx, mark, shown, 1, {}, {window_slide(ctx, win^, .Start) * (1 - shown) * 16, 0})
		kit_colors_menus(app)
		return
	}
	colors_header(app, p.docked)

	// The body scrolls when the window, or the card's share of its column, is too short
	// for it, between the header and the tabs. Once its content has been measured, and from
	// its first frame in a column (at the room it has there), it is as tall as it decides
	// here while the content changes under it, a tab picked or the card docked, so the
	// tabs never drop past the window's foot for a frame.
	fixed := t.target + BRUSH_TILE_H + 2 * COLORS_GAP
	room := max(p.room - fixed, 120)
	_, natural := ui.prev_layout(ctx, "colors body")
	want := colors_body_want(app, natural.y, inner)
	body := kit_scroll_begin(ctx, "colors body", &c.scroll, id, inner, min(want, room) if want > 0 else room, COLORS_GAP, fixed = want > 0 || p.docked)
	switch c.tab {
	case .Disc:     colors_disc(app, inner)
	case .Classic:  colors_classic(app, inner)
	case .Harmony:  colors_harmony(app, inner)
	case .Value:    colors_value(app, inner)
	case .Palettes: colors_palettes(app, inner)
	}
	if c.tab != .Palettes do colors_history_and_default(app, inner)
	kit_scroll_end(ctx, body)

	// Procreate's tabs along the bottom: an icon over each name.
	ui.begin(ctx, "colors tabs", {direction = .Row, width = inner, gap = (inner - 5 * ui.BRUSH_TILE.x) / 4})
	for tab in Colors_Tab {
		if ui.brush_tile(ctx, fmt.tprintf("%s##colors tab", COLORS_TAB_NAMES[tab]), COLORS_TAB_ICONS[tab], c.tab == tab) {
			c.tab = tab
			c.scroll = 0
		}
	}
	ui.end(ctx)
	// Docked, the card asks its column for its content's height, which no share of the
	// column changes. Asking for the share it was given would hand that share back a frame
	// late, so odd and even frames would each keep a height of their own and the card would
	// flicker between them. Until its body has been laid out in the column, it asks for all
	// the room it has.
	if p.docked do p.want = (fixed + want) if want > 0 else p.room
	panel_end(app, &p)
	ui.transform_since(ctx, mark, shown, 1, {}, {window_slide(ctx, win^, .Start) * (1 - shown) * 16, 0})

	// A pick joins the history once the finger or the pen lets go, or the hex field is done.
	if c.changed && .Left not_in ctx.input.down && !ui.typing(ctx) {
		color_history_push(c, colors_target(app)^)
		c.changed = false
	}
	kit_colors_menus(app)
	return
}

// The colour popover, as Procreate's: a tap on a colour field's well (the brush's
// colours, the material's, a group's, a light's, the background's) opens it under the
// field, with the Colors card's tabs, pickers, history and default palette setting that
// field's colour. It is drawn with what floats over the panels, after the field; the
// field takes what it set on the next frame (kit_color), so a field that acts on a change
// (a light's colour, the material on the selected objects) acts on this one too, and no
// pointer into a panel is kept. It goes when its field is no longer drawn.
kit_color_popover :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	c := &k.colors
	if !c.pop_alive do c.pop = false
	c.pop_alive = false
	shown := c.pop_set if c.pop_dirty else c.pop_value
	was := shown
	inner := f32(SWATCH_COLUMNS * SWATCH_SIDE)
	owner := ui.id_of(ctx, "colour popover")
	// Beside the field, toward the middle of the window, so the field and its panel stay
	// in view: left of a field in the tray, right of one in a card at the left.
	side := ui.Side.Left if c.pop_at.x + c.pop_at.w * 0.5 > ctx.input.window.x * 0.5 else ui.Side.Right
	if !ui.popover_begin(ctx, "colour popover", &c.pop, c.pop_at, side, {direction = .Column, gap = COLORS_GAP, padding = COLORS_PADDING, width = COLORS_CARD_W}) do return
	// The pickers set `shown`; the card's pending history pick is kept apart from this one.
	card_changed := c.changed
	c.changed = false
	c.override = &shown
	colors_sync(app)
	ui.begin(ctx, "colour popover tabs", {direction = .Row, width = inner, gap = (inner - 5 * ui.BRUSH_TILE.x) / 4})
	for tab in Colors_Tab {
		if ui.brush_tile(ctx, fmt.tprintf("%s##colour popover tab", COLORS_TAB_NAMES[tab]), COLORS_TAB_ICONS[tab], c.tab == tab) {
			c.tab = tab
			c.pop_scroll = 0
		}
	}
	ui.end(ctx)
	// The body scrolls where the window is too short for it.
	room := max(ctx.input.window.y - BRUSH_TILE_H - 2 * COLORS_PADDING - COLORS_GAP - 24, 160)
	_, natural := ui.prev_layout(ctx, "colour popover body")
	want := colors_body_want(app, natural.y, inner)
	body := kit_scroll_begin(ctx, "colour popover body", &c.pop_scroll, owner, inner, min(want, room) if want > 0 else room, COLORS_GAP)
	switch c.tab {
	case .Disc:     colors_disc(app, inner)
	case .Classic:  colors_classic(app, inner)
	case .Harmony:  colors_harmony(app, inner)
	case .Value:    colors_value(app, inner)
	case .Palettes: colors_palettes(app, inner)
	}
	if c.tab != .Palettes do colors_history_and_default(app, inner)
	kit_scroll_end(ctx, body)
	ui.popover_end(ctx)
	if !k.colors_card do kit_colors_menus(app)
	c.override = nil
	if shown != was do c.pop_set, c.pop_dirty = shown, true
	c.pop_changed ||= c.changed
	c.changed = card_changed
	if c.pop_changed && .Left not_in ctx.input.down && !ui.typing(ctx) {
		color_history_push(c, shown)
		c.pop_changed = false
	}
}

// The brush tile's height, which the tabs take.
@(private = "file")
BRUSH_TILE_H :: ui.BRUSH_TILE.y

// The row under the title: the main and secondary colours (a tap edits that one, a long
// press swaps them), Swap, Fill object, Fill gradient, Eyedropper and Close; `docked`, the
// column's header over it has Close already.
@(private = "file")
colors_header :: proc(app: ^App, docked: bool) {
	k := &app.kit
	ctx := &k.ctx
	c := &k.colors
	ui.begin(ctx, "colors header", {direction = .Row, gap = 0, center = true})
	for which in 0 ..< 2 {
		rgb := app.brush.color if which == 0 else app.brush.color2
		name := fmt.tprintf("%s colour %s##colors swatch %d", "Main" if which == 0 else "Secondary", hex_text(rgb), which)
		s := ui.swatch(ctx, name, shade(rgb), SWATCH_SIDE, selected = c.editing == which)
		if s.clicked do c.editing = which
		if s.long do command_run(app, .Swap_Colors)
	}
	_ = colors_command(app, .Swap_Colors, ICON_SWAP_COLORS)
	_ = colors_command(app, .Paint, ICON_FILL, int(sculpt.Paint_Command.Fill))
	_ = colors_command(app, .Paint, ICON_FILL_GRADIENT, int(sculpt.Paint_Command.Gradient))
	_ = colors_command(app, .Eyedropper, ICON_EYEDROPPER)
	if !docked do _ = colors_command(app, .Colors_Card, ui.ICON_CLOSE, name = "Close")
	ui.end(ctx)
}

// How tall the card's or the colour popover's body would like to be, from its content as
// last laid out (`natural`, 0 until it has been): all of it, but on Palettes, whose list
// grows with every palette, no taller than the Disc, so the card keeps its size and its
// tabs their place when Palettes is picked, and the list scrolls inside, as Procreate's
// does, rather than taking every point down to the window's foot and the tabs with it.
@(private = "file")
colors_body_want :: proc(app: ^App, natural, inner: f32) -> f32 {
	if app.kit.colors.tab != .Palettes || natural <= 0 do return natural
	return min(natural, colors_disc_height(app, inner))
}

// The Disc's height in the body (colors_disc, then colors_history_and_default): the disc,
// the history's head and row, and the default palette's name and rows, a gap between each.
@(private = "file")
colors_disc_height :: proc(app: ^App, inner: f32) -> f32 {
	t := app.kit.ctx.theme
	_, swatches, mine := palette_swatches(app, app.kit.colors.default_palette)
	rows := (palette_slots(len(swatches), mine) + SWATCH_COLUMNS - 1) / SWATCH_COLUMNS
	return inner * DISC_SHARE + t.target + SWATCH_SIDE + ui.CAPTION_H + f32(rows) * SWATCH_SIDE + f32(3 + rows) * COLORS_GAP
}

// The Disc's area is this share of the body's width tall, the ring touching its top and
// bottom, which leaves the reticles room at the sides.
@(private = "file")
DISC_SHARE :: 0.82

// An icon button in the card that runs command `id`, its label, shortcut and gesture in
// its tooltip and lit while the command is on.
@(private = "file")
colors_command :: proc(app: ^App, id: Command_Id, glyph: rune, arg := 0, name := "") -> bool {
	ctx := &app.kit.ctx
	label := fmt.tprintf("%s##colors", name if name != "" else command_label(id, arg))
	if ui.icon_button(ctx, label, glyph, command_checked(app, id, arg) && id != .Colors_Card, command_enabled(app, id, arg), command_hint(app, id, arg)) {
		command_run(app, id, arg)
		return true
	}
	return false
}

// The Disc: the hue ring round a disc of every saturation and brightness of that hue.
@(private = "file")
colors_disc :: proc(app: ^App, inner: f32) {
	ctx := &app.kit.ctx
	t := ctx.theme
	c := &app.kit.colors
	a := ui.area(ctx, "colors disc", {inner, inner * DISC_SHARE})
	centre := [2]f32{a.rect.x + a.rect.w * 0.5, a.rect.y + a.rect.h * 0.5}
	outer := a.rect.h * 0.5 - 4
	RING :: 26
	disc := outer - RING - 8
	if a.pressed {
		d := a.mouse - centre
		c.drag = 1 if math.sqrt(d.x * d.x + d.y * d.y) > disc + 4 else 2
	}
	if a.held {
		d := a.mouse - centre
		hsv := c.hsv
		if c.drag == 1 {
			hsv.x = hue_at(d)
		} else if c.drag == 2 {
			sq := square_from_disc({d.x / disc, -d.y / disc})
			hsv.y, hsv.z = (sq.x + 1) * 0.5, (sq.y + 1) * 0.5
		}
		if hsv != c.hsv do colors_set_hsv(app, hsv)
	} else {
		c.drag = 0
	}
	// The pen's roll over the Disc turns the hue round the ring, as far as the pen turns:
	// clockwise moves the hue's mark clockwise.
	if roll := ui.hover_roll(ctx, a.id, a.hovered); roll != 0 {
		hsv := c.hsv
		hsv.x -= roll / 360
		hsv.x -= math.floor(hsv.x)
		colors_set_hsv(app, hsv)
		ui.roll_hint(ctx, fmt.tprintf("Hue %.0f°", hsv.x * 360))
	}
	pen_zone(app, a.rect, .Colors)
	hue_ring(ctx, centre, outer - RING, outer)
	// The disc as a grid of the square mapped into it, coloured at each point.
	N :: 16
	points: [(N + 1) * (N + 1)][2]f32
	shades: [(N + 1) * (N + 1)]ui.Color
	indices: [N * N * 6]u32
	for row in 0 ..= N {
		for col in 0 ..= N {
			sq := [2]f32{f32(col) / N * 2 - 1, f32(row) / N * 2 - 1}
			q := disc_from_square(sq)
			i := row * (N + 1) + col
			points[i] = centre + {q.x, -q.y} * disc
			shades[i] = shade(hsv_to_rgb({c.hsv.x, (sq.x + 1) * 0.5, (sq.y + 1) * 0.5}))
		}
	}
	grid_indices(indices[:], N)
	ui.fill_mesh(ctx, points[:], shades[:], indices[:])
	ui.stroke_circle(ctx, centre, disc, t.border_strong, 1)
	// The reticles: on the ring at the hue, and in the disc at the colour.
	angle := c.hsv.x * 2 * math.PI
	ring_at := centre + [2]f32{math.cos(angle), -math.sin(angle)} * (outer - RING * 0.5)
	reticle(ctx, ring_at, RING * 0.5 + 2, shade(hsv_to_rgb({c.hsv.x, 1, 1})))
	q := disc_from_square({c.hsv.y * 2 - 1, c.hsv.z * 2 - 1})
	reticle(ctx, centre + {q.x, -q.y} * disc, 14, shade(colors_target(app)^))
}

// Classic: a square of every saturation (across) and brightness (up) of the hue, then
// Hue, Saturation and Brightness sliders.
@(private = "file")
colors_classic :: proc(app: ^App, inner: f32) {
	ctx := &app.kit.ctx
	t := ctx.theme
	c := &app.kit.colors
	a := ui.area(ctx, "colors square", {inner, inner * 0.62})
	r := a.rect
	if a.held {
		hsv := c.hsv
		hsv.y = clamp((a.mouse.x - r.x) / r.w, 0, 1)
		hsv.z = clamp(1 - (a.mouse.y - r.y) / r.h, 0, 1)
		if hsv != c.hsv do colors_set_hsv(app, hsv)
	}
	N :: 12
	points: [(N + 1) * (N + 1)][2]f32
	shades: [(N + 1) * (N + 1)]ui.Color
	indices: [N * N * 6]u32
	for row in 0 ..= N {
		for col in 0 ..= N {
			u, v := f32(col) / N, f32(row) / N
			i := row * (N + 1) + col
			points[i] = {r.x + u * r.w, r.y + (1 - v) * r.h}
			shades[i] = shade(hsv_to_rgb({c.hsv.x, u, v}))
		}
	}
	grid_indices(indices[:], N)
	ui.fill_mesh(ctx, points[:], shades[:], indices[:])
	ui.stroke_rect(ctx, r, 0, t.border_strong, 1)
	reticle(ctx, {r.x + c.hsv.y * r.w, r.y + (1 - c.hsv.z) * r.h}, 14, shade(colors_target(app)^))
	colors_hsb_sliders(app)
}

// Harmony: the scheme's name (a tap lists the five), a disc of hue round it and
// saturation out from its middle at the chosen brightness with a reticle for each colour
// of the scheme, the Brightness slider under it, and the scheme's colours as swatches. A
// tap on another colour's reticle or swatch makes it the colour, as Procreate's.
@(private = "file")
colors_harmony :: proc(app: ^App, inner: f32) {
	ctx := &app.kit.ctx
	t := ctx.theme
	c := &app.kit.colors
	names: [len(Harmony)]string
	for h in Harmony do names[h] = HARMONY_NAMES[h]
	if picked := ui.select(ctx, "colors harmony", names[:], int(c.harmony), inner * 0.6); picked >= 0 do c.harmony = Harmony(picked)
	offsets := harmony_offsets(c.harmony)
	a := ui.area(ctx, "colors harmony disc", {inner, inner * 0.78})
	centre := [2]f32{a.rect.x + a.rect.w * 0.5, a.rect.y + a.rect.h * 0.5}
	radius := a.rect.h * 0.5 - 6
	at :: proc(centre: [2]f32, radius, h, s: f32) -> [2]f32 {
		angle := h * 2 * math.PI
		return centre + [2]f32{math.cos(angle), -math.sin(angle)} * (s * radius)
	}
	if a.pressed {
		// The reticle nearest the press within a touch target's reach, else the main one.
		c.harmony_drag = 0
		best := t.target * 0.5
		for o, i in offsets {
			if i == 0 do continue
			p := at(centre, radius, c.hsv.x + o, c.hsv.y)
			if d := a.mouse - p; math.sqrt(d.x * d.x + d.y * d.y) < best do c.harmony_drag, best = i, math.sqrt(d.x * d.x + d.y * d.y)
		}
	}
	if a.held && c.harmony_drag == 0 {
		d := a.mouse - centre
		hsv := c.hsv
		hsv.x = hue_at(d)
		hsv.y = clamp(math.sqrt(d.x * d.x + d.y * d.y) / radius, 0, 1)
		if hsv != c.hsv do colors_set_hsv(app, hsv)
	}
	if a.clicked && c.harmony_drag > 0 {
		o := offsets[min(c.harmony_drag, len(offsets) - 1)]
		colors_pick(app, hsv_to_rgb({c.hsv.x + o, c.hsv.y, c.hsv.z}))
	}
	// The disc: rings out from the middle, the hue round them.
	RINGS :: 8
	SEGMENTS :: 48
	points: [1 + RINGS * SEGMENTS][2]f32
	shades: [1 + RINGS * SEGMENTS]ui.Color
	indices: [(SEGMENTS + (RINGS - 1) * SEGMENTS * 2) * 3]u32
	points[0], shades[0] = centre, shade(hsv_to_rgb({0, 0, c.hsv.z}))
	for ring in 1 ..= RINGS {
		s := f32(ring) / RINGS
		for seg in 0 ..< SEGMENTS {
			h := f32(seg) / SEGMENTS
			i := 1 + (ring - 1) * SEGMENTS + seg
			points[i], shades[i] = at(centre, radius, h, s), shade(hsv_to_rgb({h, s, c.hsv.z}))
		}
	}
	polar_indices(indices[:], RINGS, SEGMENTS)
	ui.fill_mesh(ctx, points[:], shades[:], indices[:])
	ui.stroke_circle(ctx, centre, radius, t.border_strong, 1)
	#reverse for o, i in offsets {
		col := shade(hsv_to_rgb({c.hsv.x + o, c.hsv.y, c.hsv.z}))
		reticle(ctx, at(centre, radius, c.hsv.x + o, c.hsv.y), 16 if i == 0 else 10, col)
	}
	b := c.hsv.z
	if ui.gradient_slider(ctx, "B##harmony brightness", &b, slider_stops(c.hsv, 2, false), fmt.tprintf("%d%%", int(math.round(b * 100)))) do colors_set_hsv(app, {c.hsv.x, c.hsv.y, b})
	ui.begin(ctx, "colors harmony swatches", {direction = .Row, gap = 0})
	for o, i in offsets {
		rgb := hsv_to_rgb({c.hsv.x + o, c.hsv.y, c.hsv.z})
		if ui.swatch(ctx, fmt.tprintf("%s##harmony %d", hex_text(rgb), i), shade(rgb), SWATCH_SIDE, selected = i == 0).clicked do colors_pick(app, rgb)
	}
	ui.end(ctx)
}

// Value: Hue, Saturation and Brightness or Red, Green and Blue as sliders with their
// values, then the colour as a hexadecimal code to read or type.
@(private = "file")
colors_value :: proc(app: ^App, inner: f32) {
	ctx := &app.kit.ctx
	t := ctx.theme
	c := &app.kit.colors
	if picked := ui.tabs(ctx, "colors value", {"HSB", "RGB"}, int(c.value_rgb), accent = true); picked >= 0 do c.value_rgb = picked == 1
	if c.value_rgb {
		rgb := colors_target(app)^
		for name, i in ([3]string{"R", "G", "B"}) {
			v := rgb[i]
			if ui.gradient_slider(ctx, fmt.tprintf("%s##value rgb", name), &v, slider_stops(rgb, i, true), fmt.tprintf("%d", int(math.round(v * 255)))) {
				next := rgb
				next[i] = v
				colors_set_rgb(app, next)
			}
		}
	} else {
		colors_hsb_sliders(app)
	}
	ui.begin(ctx, "colors hex row", {direction = .Row, gap = 8, center = true})
	ui.begin(ctx, "colors hex label", {direction = .Column, width = inner - 128})
	ui.label(ctx, "Hexadecimal", t.text_size, t.text_secondary)
	ui.end(ctx)
	if typed, ok := kit_hex_field(app, "colors hex", colors_target(app)^, 120); ok do colors_set_rgb(app, typed)
	ui.end(ctx)
}

// Hue, Saturation and Brightness as gradient sliders: degrees and percentages, as Procreate.
@(private = "file")
colors_hsb_sliders :: proc(app: ^App) {
	ctx := &app.kit.ctx
	c := &app.kit.colors
	hsv := c.hsv
	shown := [3]string{fmt.tprintf("%d°", int(math.round(hsv.x * 360))), fmt.tprintf("%d%%", int(math.round(hsv.y * 100))), fmt.tprintf("%d%%", int(math.round(hsv.z * 100)))}
	for name, i in ([3]string{"H", "S", "B"}) {
		v := hsv[i]
		if ui.gradient_slider(ctx, fmt.tprintf("%s##hsb", name), &v, slider_stops(hsv, i, false), shown[i]) {
			next := c.hsv
			next[i] = v
			colors_set_hsv(app, next)
		}
	}
}

// What a channel's slider shows along it: the colour with only that channel moving, the
// hue at full saturation and brightness so the whole wheel reads.
@(private = "file")
slider_stops :: proc(base: [3]f32, channel: int, rgb: bool) -> []ui.Color {
	STOPS :: 13
	out := make([]ui.Color, STOPS, context.temp_allocator)
	for &s, i in out {
		f := f32(i) / (STOPS - 1)
		x := base
		x[channel] = f
		if rgb {
			s = shade(x)
		} else {
			if channel == 0 do x = {f, 1, 1}
			s = shade(hsv_to_rgb(x))
		}
	}
	return out
}

// The history and the default palette, under the pickers.
@(private = "file")
colors_history_and_default :: proc(app: ^App, inner: f32) {
	ctx := &app.kit.ctx
	t := ctx.theme
	c := &app.kit.colors
	ui.begin(ctx, "colors history head", {direction = .Row, center = true})
	ui.begin(ctx, "colors history title", {direction = .Column, width = inner - 96})
	ui.caption(ctx, "HISTORY")
	ui.end(ctx)
	if ui.button(ctx, "Clear##colors history", width = 96, enabled = c.history_count > 0) do c.history_count = 0
	ui.end(ctx)
	ui.begin(ctx, "colors history", {direction = .Row, gap = 0})
	for i in 0 ..< COLOR_HISTORY {
		if i >= c.history_count {
			_ = ui.swatch(ctx, fmt.tprintf("Colours you pick show here##history %d", i), {}, SWATCH_SIDE, empty = true)
			continue
		}
		rgb := c.history[i]
		if ui.swatch(ctx, fmt.tprintf("%s##history %d", hex_text(rgb), i), shade(rgb), SWATCH_SIDE).clicked do colors_pick(app, rgb)
	}
	ui.end(ctx)
	name, swatches, mine := palette_swatches(app, c.default_palette)
	ui.caption(ctx, strings.to_upper(name, context.temp_allocator))
	palette_grid(app, c.default_palette - len(BUILT_IN_PALETTES) if mine else -1, swatches, mine, "default")
	_ = t
}

// The Palettes tab: + New palette, then every palette, the default one checked.
@(private = "file")
colors_palettes :: proc(app: ^App, inner: f32) {
	ctx := &app.kit.ctx
	c := &app.kit.colors
	ui.begin(ctx, "colors palettes head", {direction = .Row, center = true})
	ui.begin(ctx, "colors palettes title", {direction = .Column, width = inner - ctx.theme.target})
	ui.caption(ctx, "PALETTES")
	ui.end(ctx)
	if ui.icon_button(ctx, "New palette", ui.ICON_PLUS, enabled = c.palette_count < USER_PALETTES) do _ = palette_new(c)
	ui.end(ctx)
	for n in 0 ..< len(BUILT_IN_PALETTES) + c.palette_count {
		name, swatches, mine := palette_swatches(app, n)
		mine_i := n - len(BUILT_IN_PALETTES)
		ui.begin(ctx, fmt.tprintf("palette head %d", n), {direction = .Row, center = true, gap = 0})
		if ui.icon_button(ctx, fmt.tprintf("Default palette##%d", n), ui.ICON_CHECK if c.default_palette == n else ICON_CIRCLE, selected = c.default_palette == n) do c.default_palette = n
		if mine {
			p := &c.palettes[mine_i]
			_ = ui.text_field(ctx, fmt.tprintf("palette name %d", mine_i), p.name[:PALETTE_NAME - 1], inner - 2 * ctx.theme.target, hint = "Name")
		} else {
			ui.begin(ctx, fmt.tprintf("palette name %d", n), {direction = .Column, width = inner - 2 * ctx.theme.target})
			ui.label(ctx, name, ctx.theme.text_size, ctx.theme.text)
			ui.end(ctx)
		}
		if ui.icon_button(ctx, fmt.tprintf("Palette menu##%d", n), ui.ICON_MORE, selected = c.palette_menu && c.palette_menu_of == n) {
			c.palette_menu, c.palette_menu_at, c.palette_menu_of = true, ctx.last_rect, n
			c.swatch_menu = false
		}
		ui.end(ctx)
		palette_grid(app, mine_i if mine else -1, swatches, mine, fmt.tprintf("%d", n))
	}
}

// A palette's swatches, SWATCH_COLUMNS to a row. A tap picks one; on your palette `mine`
// (its place among yours) the next empty slot saves the current colour, and a long press
// on a swatch opens its menu.
@(private = "file")
palette_grid :: proc(app: ^App, mine: int, swatches: [][3]f32, editable: bool, key: string) {
	ctx := &app.kit.ctx
	c := &app.kit.colors
	slots := palette_slots(len(swatches), editable)
	for i in 0 ..< slots {
		if i % SWATCH_COLUMNS == 0 do ui.begin(ctx, fmt.tprintf("palette %s row %d", key, i / SWATCH_COLUMNS), {direction = .Row, gap = 0})
		if i == len(swatches) {
			if ui.swatch(ctx, fmt.tprintf("Save the colour here##palette %s add", key), {}, SWATCH_SIDE, empty = true).clicked {
				p := &c.palettes[mine]
				p.colors[p.count] = colors_target(app)^
				p.count += 1
			}
		} else {
			rgb := swatches[i]
			s := ui.swatch(ctx, fmt.tprintf("%s##palette %s %d", hex_text(rgb), key, i), shade(rgb), SWATCH_SIDE)
			if s.clicked do colors_pick(app, rgb)
			if s.long && editable {
				c.swatch_menu, c.swatch_menu_at, c.swatch_menu_of = true, ctx.last_rect, {mine, i}
				c.palette_menu = false
			}
		}
		if i % SWATCH_COLUMNS == SWATCH_COLUMNS - 1 || i == slots - 1 do ui.end(ctx)
	}
}

// The cells a palette's grid lays out: its `count` swatches and, on your palette while it
// has room, the empty one that saves the colour there.
@(private = "file")
palette_slots :: proc(count: int, editable: bool) -> int {
	return count + (1 if editable && count < PALETTE_SWATCHES else 0)
}

// The palette menu (Duplicate; on yours, Delete) and a swatch's (Set to current colour,
// Delete swatch), drawn over the card.
@(private = "file")
kit_colors_menus :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	c := &k.colors
	if ui.popover_begin(ctx, "colors palette menu", &c.palette_menu, c.palette_menu_at, .Below_End, {direction = .Column, gap = 2, padding = 6}) {
		n := c.palette_menu_of
		name, swatches, mine := palette_swatches(app, n)
		if ui.menu_item(ctx, "Set as default", glyph = ui.ICON_CHECK) {
			c.default_palette = n
			c.palette_menu = false
		}
		if ui.menu_item(ctx, "Duplicate", glyph = ui.ICON_COPY, enabled = c.palette_count < USER_PALETTES) {
			// Copied first, as a new palette may take the place `swatches` points into.
			copied := make([][3]f32, len(swatches), context.temp_allocator)
			copy(copied, swatches)
			label := fmt.tprintf("%s copy", name)
			if i := palette_new(c); i >= 0 {
				p := &c.palettes[i]
				palette_name_set(p, label)
				p.count = min(len(copied), PALETTE_SWATCHES)
				copy(p.colors[:], copied[:p.count])
			}
			c.palette_menu = false
		}
		if mine && ui.menu_item(ctx, "Delete palette", glyph = ui.ICON_TRASH, tone = .Danger) {
			palette_delete(c, n - len(BUILT_IN_PALETTES))
			c.palette_menu = false
		}
		ui.popover_end(ctx)
	}
	if ui.popover_begin(ctx, "colors swatch menu", &c.swatch_menu, c.swatch_menu_at, .Below, {direction = .Column, gap = 2, padding = 6}) {
		i, j := c.swatch_menu_of[0], c.swatch_menu_of[1]
		if ui.menu_item(ctx, "Set to current colour", glyph = ICON_FILL) {
			if i >= 0 && i < c.palette_count && j < c.palettes[i].count do c.palettes[i].colors[j] = colors_target(app)^
			c.swatch_menu = false
		}
		if ui.menu_item(ctx, "Delete swatch", glyph = ui.ICON_TRASH, tone = .Danger) {
			palette_swatch_delete(c, i, j)
			c.swatch_menu = false
		}
		ui.popover_end(ctx)
	}
}

// The hue (0 to 1) a point `d` from a wheel's middle stands for: red to the right, then
// yellow, green and blue going round anticlockwise, as both apps' wheels have it.
@(private = "file")
hue_at :: proc(d: [2]f32) -> f32 {
	h := math.atan2(-d.y, d.x) / (2 * math.PI)
	return h + 1 if h < 0 else h
}

// The hue ring between radii `lo` and `hi`.
@(private = "file")
hue_ring :: proc(ctx: ^ui.Context, centre: [2]f32, lo, hi: f32) {
	SEGMENTS :: 72
	points: [2 * (SEGMENTS + 1)][2]f32
	shades: [2 * (SEGMENTS + 1)]ui.Color
	indices: [SEGMENTS * 6]u32
	for seg in 0 ..= SEGMENTS {
		h := f32(seg) / SEGMENTS
		angle := h * 2 * math.PI
		dir := [2]f32{math.cos(angle), -math.sin(angle)}
		col := shade(hsv_to_rgb({h, 1, 1}))
		points[2 * seg], points[2 * seg + 1] = centre + dir * lo, centre + dir * hi
		shades[2 * seg], shades[2 * seg + 1] = col, col
	}
	for seg in 0 ..< SEGMENTS {
		a := u32(2 * seg)
		indices[6 * seg + 0], indices[6 * seg + 1], indices[6 * seg + 2] = a, a + 1, a + 3
		indices[6 * seg + 3], indices[6 * seg + 4], indices[6 * seg + 5] = a, a + 3, a + 2
	}
	ui.fill_mesh(ctx, points[:], shades[:], indices[:])
	// Outlines smooth the edges the mesh leaves unfeathered.
	ui.stroke_circle(ctx, centre, lo, ctx.theme.border_strong, 1)
	ui.stroke_circle(ctx, centre, hi, ctx.theme.border_strong, 1)
}

// The triangles of an (n + 1) x (n + 1) grid of points, row by row.
@(private = "file")
grid_indices :: proc(out: []u32, n: int) {
	k := 0
	for row in 0 ..< n {
		for col in 0 ..< n {
			a := u32(row * (n + 1) + col)
			b := a + u32(n + 1)
			out[k + 0], out[k + 1], out[k + 2] = a, a + 1, b + 1
			out[k + 3], out[k + 4], out[k + 5] = a, b + 1, b
			k += 6
		}
	}
}

// The triangles of a disc of `rings` rings of `segments` points round a middle point 0.
@(private = "file")
polar_indices :: proc(out: []u32, rings, segments: int) {
	n := 0
	for s in 0 ..< segments {
		out[n], out[n + 1], out[n + 2] = 0, u32(1 + s), u32(1 + (s + 1) % segments)
		n += 3
	}
	for ring in 1 ..< rings {
		inner, outer := 1 + (ring - 1) * segments, 1 + ring * segments
		for s in 0 ..< segments {
			s1 := (s + 1) % segments
			a, b, c, d := u32(inner + s), u32(inner + s1), u32(outer + s), u32(outer + s1)
			out[n], out[n + 1], out[n + 2] = a, c, d
			out[n + 3], out[n + 4], out[n + 5] = a, d, b
			n += 6
		}
	}
}

// A reticle: a ring that reads on light and dark alike, filled with the colour it marks.
@(private = "file")
reticle :: proc(ctx: ^ui.Context, at: [2]f32, radius: f32, color: ui.Color) {
	ui.fill_circle(ctx, at, radius + 1.5, {0, 0, 0, 110})
	ui.fill_circle(ctx, at, radius, {255, 255, 255, 255})
	ui.fill_circle(ctx, at, radius - 3, color)
}

// The hex code of `shown` as a field to type over: while it is typed in it keeps what
// was typed, so "#3" on the way to "#3A7" is not replaced by the colour; otherwise it
// shows the colour. A tap empties it to type a new code over its hint, the code it had,
// as the field has no selection to type over. Returns the colour typed, when it is one.
kit_hex_field :: proc(app: ^App, name: string, shown: [3]f32, width: f32) -> (typed: [3]f32, ok: bool) {
	k := &app.kit
	ctx := &k.ctx
	field := fmt.tprintf("hex##%s", name)
	id := ui.id_of(ctx, field)
	editing := ctx.text_focus == id && k.color_hex_of == id
	code: [8]u8
	color_hex_format(shown, code[:])
	text := code
	buf := k.color_hex[:] if editing else text[:]
	if ui.text_field(ctx, field, buf, width, hint = fmt.tprint(string(code[:7]))) {
		typed, ok = color_hex_parse(string(buf[:hex_len(buf)]))
	}
	if ctx.text_focus == id && !editing {
		k.color_hex = {}
		k.color_hex_of = id
	} else if ctx.text_focus != id && k.color_hex_of == id {
		k.color_hex_of = 0
	}
	return
}

// The bytes before the zero that ends `buf`, or all of them.
@(private = "file")
hex_len :: proc(buf: []u8) -> int {
	for b, i in buf do if b == 0 do return i
	return len(buf)
}

// The colour the eyedropper finds at viewport point `at`: the polypaint over the
// material where the ray first meets an object, as the surface's own colour rather than
// as lit, which is the colour to paint with. False when the ray meets nothing.
color_sample :: proc(app: ^App, at, size: [2]f32) -> (rgb: [3]f32, ok: bool) {
	origin, dir := mouse_ray(app.camera, at, size)
	index, _, hit := scene_raycast(app, origin, dir)
	if !hit do return
	obj := app.scene.objects[index]
	base := object_material(app, obj).selected.rgb
	under: [3]u32
	for k in 0 ..< 3 do under[k] = u32(srgb_encode(base[k]) * 255 + 0.5)
	paint: sculpt.Color
	// Voxel clay and HD windows hold no polypaint of their own.
	if obj.voxel == nil && !object_in_hd(obj) {
		t := obj.transform
		paint, _ = sculpt.sculptor_color_at(object_sculptor(obj), to_local(t, origin), to_local_dir(t, dir))
	}
	b := paint_over(paint, under)
	return {f32(b.r) / 255, f32(b.g) / 255, f32(b.b) / 255}, true
}

// The Eyedropper command: over the viewport it picks the colour under the pointer at
// once, as ZBrush's C; from a button it waits for the next press on the model.
eyedropper_command :: proc(app: ^App) {
	u := &app.ui
	if u.viewport_hovered && !u.eyedrop_armed {
		if rgb, ok := color_sample(app, u.viewport_mouse, u.viewport_size); ok {
			colors_pick(app, rgb)
			report(app, Kit_Section.Paint_Color, {.Quiet}, "Picked %s", hex_text(rgb))
		}
		return
	}
	u.eyedrop_armed = !u.eyedrop_armed
}

// Follows an armed eyedropper with this frame's input: the press on the viewport and the
// drag after it show the colour under the pointer in the loupe, and letting go picks
// it; a release over nothing picks nothing. Returns true while the press is the
// eyedropper's, so no tool takes it.
eyedropper_frame :: proc(app: ^App, input: Viewport_Input) -> bool {
	u := &app.ui
	if !u.eyedrop_held {
		if !u.eyedrop_armed || !input.press do return false
		u.eyedrop_armed, u.eyedrop_held = false, true
	}
	u.eyedrop_at = input.mouse_pos
	u.eyedrop_color, u.eyedrop_hit = color_sample(app, input.mouse_pos, input.size)
	if input.primary do return true
	u.eyedrop_held = false
	if u.eyedrop_hit {
		colors_pick(app, u.eyedrop_color)
		report(app, Kit_Section.Paint_Color, {.Quiet}, "Picked %s", hex_text(u.eyedrop_color))
	} else {
		report(app, Kit_Section.Paint_Color, {.Warning}, "Eyedropper: the press missed every object")
	}
	return true
}

// The eyedropper's loupe while it is held, as Procreate's: a ring over the pointer, its
// top half the colour under it and its bottom half the colour now.
draw_eyedropper :: proc(app: ^App, o: Overlay) {
	u := &app.ui
	if !u.eyedrop_held do return
	R :: 46
	r := R * o.scale
	centre := u.eyedrop_at - {0, r + 30 * o.scale}
	half :: proc(o: Overlay, centre: [2]f32, r: f32, top: bool, color: ui.Color) {
		STEPS :: 24
		points: [STEPS + 1][2]f32
		for &p, i in points {
			a := math.PI * f32(i) / STEPS
			p = centre + [2]f32{math.cos(a), -math.sin(a) if top else math.sin(a)} * r
		}
		overlay_fill(o, points[:], color)
	}
	now := shade(colors_target(app)^)
	half(o, centre, r, true, shade(u.eyedrop_color) if u.eyedrop_hit else ui.Color{0, 0, 0, 0})
	half(o, centre, r, false, now)
	overlay_circle(o, centre, r, {255, 255, 255, 230}, 3 * o.scale)
	overlay_circle(o, centre, r + 2 * o.scale, {0, 0, 0, 120}, 1.5 * o.scale)
	overlay_circle(o, u.eyedrop_at, 4 * o.scale, {255, 255, 255, 230}, 1.5 * o.scale)
}

// Lucide's paint-bucket, paint-roller, pipette and circle.
ICON_FILL :: rune(0xe2e6)
ICON_FILL_GRADIENT :: rune(0xe5a3)
ICON_EYEDROPPER :: rune(0xe13f)
ICON_CIRCLE :: rune(0xe07a)
