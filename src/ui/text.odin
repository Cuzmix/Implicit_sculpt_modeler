package ui

import "core:unicode/utf8"

import fs "vendor:fontstash"
import stbtt "vendor:stb/truetype"

// The typefaces: Inter for text (SIL Open Font License), and for icons the app's own font,
// built from Phosphor (MIT), Tabler (MIT) and Lucide (ISC) drawings by scripts/icons_build.py
// (icons_gen.odin names them), all embedded so the app needs no files beside them. Their
// licences are in assets/fonts and assets/licenses.
// Loaded as strings and turned into bytes where used: Odin's wasm64p32 code generation
// stops on #load as bytes (README "Web").
INTER_REGULAR := #load("../../assets/fonts/Inter-Regular.ttf", string)
INTER_SEMIBOLD := #load("../../assets/fonts/Inter-SemiBold.ttf", string)
ICONS_REGULAR := #load("../../assets/fonts/Icons-Regular.ttf", string)
ICONS_BOLD := #load("../../assets/fonts/Icons-Bold.ttf", string)
ICONS_FILL := #load("../../assets/fonts/Icons-Fill.ttf", string)

Font :: enum u8 {
	Regular,
	Semibold,
	Icons,
	// The icons' lines drawn heavier (Settings > Interface > Icons, Bold), and the soft
	// shapes drawn under the lines in the Duotone and Colour styles: the same code points
	// in each, laid on the same grid, so one pen position lines them up.
	Icons_Bold,
	Icons_Fill,
}

// The glyph atlas starts this many pixels square and doubles when full.
ATLAS_START :: 512

// Inter's cap height as a share of its em, for centring a line on its capitals the way
// the eye reads a label's middle.
CAP_HEIGHT :: f32(0.727)

Fonts :: struct {
	stash:    fs.FontContext,
	ids:      [Font]int,
	// fontstash sizes a font by its ascender-to-descender height; this turns an em size
	// (what a design tool calls the font size) into that.
	em_scale: [Font]f32,
	// The part of the atlas (x0, y0, x1, y1) that changed since the last atlas_take.
	dirty:    [4]f32,
	has_dirty: bool,
	cache:    Text_Cache, // every line laid out, kept between frames (text_cache.odin)
}

fonts_init :: proc(f: ^Fonts) {
	fs.Init(&f.stash, ATLAS_START, ATLAS_START, .TOPLEFT)
	data := [Font][]u8 {
		.Regular    = transmute([]u8)INTER_REGULAR,
		.Semibold   = transmute([]u8)INTER_SEMIBOLD,
		.Icons      = transmute([]u8)ICONS_REGULAR,
		.Icons_Bold = transmute([]u8)ICONS_BOLD,
		.Icons_Fill = transmute([]u8)ICONS_FILL,
	}
	for font in Font {
		f.ids[font] = fs.AddFontMem(&f.stash, "", data[font], false)
		info := &f.stash.fonts[f.ids[font]].info
		f.em_scale[font] = stbtt.ScaleForMappingEmToPixels(info, 1) / stbtt.ScaleForPixelHeight(info, 1)
	}
}

fonts_destroy :: proc(f: ^Fonts) {
	text_cache_destroy(&f.cache)
	fs.Destroy(&f.stash)
	f^ = {}
}

// What the renderer needs to bring its copy of the glyph atlas up to date: the whole
// single-channel image, its size, and the rectangle (x0, y0, x1, y1) that changed since
// the last call; `changed` is false when nothing did.
atlas_take :: proc(ctx: ^Context) -> (pixels: []u8, width, height: int, dirty: [4]int, changed: bool) {
	f := &ctx.fonts
	rect: [4]f32
	if fs.ValidateTexture(&f.stash, &rect) {
		if f.has_dirty {
			f.dirty = {min(f.dirty[0], rect[0]), min(f.dirty[1], rect[1]), max(f.dirty[2], rect[2]), max(f.dirty[3], rect[3])}
		} else {
			f.dirty, f.has_dirty = rect, true
		}
	}
	pixels, width, height = f.stash.textureData, f.stash.width, f.stash.height
	if !f.has_dirty do return
	f.has_dirty = false
	return pixels, width, height, {int(f.dirty[0]), int(f.dirty[1]), int(f.dirty[2]), int(f.dirty[3])}, true
}

// The whole atlas as it is now, for a renderer that needs all of it at once.
atlas_pixels :: proc(ctx: ^Context) -> (pixels: []u8, width, height: int) {
	return ctx.fonts.stash.textureData, ctx.fonts.stash.width, ctx.fonts.stash.height
}

Align :: enum u8 {
	Left,
	Center,
	Right,
}

// How wide `s` is at `size` points, in points.
text_width :: proc(ctx: ^Context, s: string, size: f32, font := Font.Regular) -> f32 {
	d := px(ctx)
	text_state(ctx, size, font)
	if run, _ := text_run(ctx, s, font); run != nil do return run.width / d
	return fs.TextBounds(&ctx.fonts.stash, s) / d
}

// Draws one line of text whose capitals are centred on `y`, starting at, centred on or
// ending at `x` (points).
text :: proc(ctx: ^Context, s: string, x, y: f32, size: f32, color: Color, font := Font.Regular, align := Align.Left) {
	d := px(ctx)
	stash := &ctx.fonts.stash
	text_state(ctx, size, font)
	baseline := f32(int(y * d + CAP_HEIGHT * size * d * 0.5 + 0.5))
	if run, glyphs := text_run(ctx, s, font); run != nil {
		text_run_draw(ctx, glyphs, x * d, baseline, align, color)
		return
	}
	fs.SetAlignHorizontal(stash, fs.AlignHorizontal(align))
	fs.SetAlignVertical(stash, .BASELINE)
	glyphs(ctx, s, x * d, baseline, color)
}

// How icons are drawn (Settings > Interface > Icons): Colour lays a soft shape in the
// colour of what the icon works on (its Icon_Group, the theme's `icons`) under its lines;
// Duotone lays the same shape in the lines' own colour, faint; Mono draws the lines alone.
// Colour comes first so a fresh Context has it.
Icon_Style :: enum u8 {
	Colour,
	Duotone,
	Mono,
}

// How heavy the icons' lines are.
Icon_Weight :: enum u8 {
	Regular,
	Bold,
}

// The soft shape's share of the lines' opacity: faint in Duotone, where it is the lines'
// own colour, and stronger in Colour, where its hue is what tells the kinds apart.
ICON_FILL_DUOTONE :: 0.2
ICON_FILL_COLOUR :: 0.6

// Draws an icon from the icon fonts, its lines' ink centred on `center` (points), `size`
// points across, in the style and weight the context holds. A code point outside the
// app's icons draws as its lines alone.
icon :: proc(ctx: ^Context, codepoint: rune, center: [2]f32, size: f32, color: Color) {
	d := px(ctx)
	stash := &ctx.fonts.stash
	line := Font.Icons_Bold if ctx.icon_weight == .Bold else Font.Icons
	buf, n := utf8.encode_rune(codepoint)
	s := string(buf[:n])
	c := center * d
	text_state(ctx, size, line)
	b: [4]f32
	if run, _ := text_run(ctx, s, line); run != nil {
		b = run.bounds
	} else {
		fs.SetAlignHorizontal(stash, .LEFT)
		fs.SetAlignVertical(stash, .BASELINE)
		fs.TextBounds(stash, s, 0, 0, &b)
	}
	x := f32(int(c.x - (b[0] + b[2]) * 0.5 + 0.5))
	y := f32(int(c.y - (b[1] + b[3]) * 0.5 + 0.5))
	index := int(codepoint - ICON_FIRST)
	if ctx.icon_style != .Mono && index >= 0 && index < ICON_COUNT {
		fill := color_fade(color, ICON_FILL_DUOTONE)
		if ctx.icon_style == .Colour {
			g := ctx.theme.icons[ICON_GROUP_TABLE[index]]
			fill = {g.r, g.g, g.b, u8(f32(color.a) * f32(g.a) / 255 * ICON_FILL_COLOUR + 0.5)}
		}
		icon_layer(ctx, s, .Icons_Fill, size, x, y, fill)
	}
	icon_layer(ctx, s, line, size, x, y, color)
}

// One of an icon's layers with its pen at `x` and its baseline at `y` (physical pixels).
// Each layer looks its line up again, since laying out another can move the cache's pools.
@(private = "file")
icon_layer :: proc(ctx: ^Context, s: string, font: Font, size, x, y: f32, color: Color) {
	stash := &ctx.fonts.stash
	text_state(ctx, size, font)
	if run, laid := text_run(ctx, s, font); run != nil {
		text_run_draw(ctx, laid, x, y, .Left, color)
		return
	}
	fs.SetAlignHorizontal(stash, .LEFT)
	fs.SetAlignVertical(stash, .BASELINE)
	glyphs(ctx, s, x, y, color)
}

@(private)
text_state :: proc(ctx: ^Context, size: f32, font: Font) {
	stash := &ctx.fonts.stash
	fs.SetFont(stash, ctx.fonts.ids[font])
	fs.SetSize(stash, size * px(ctx) * ctx.fonts.em_scale[font])
}

// Emits a quad per glyph, laid out by fontstash now: the path for a line the cache
// cannot keep (text_run returns nil). Texture coordinates go out in atlas pixels, read at the moment
// each glyph is placed, so a glyph that grows the atlas mid-frame cannot break the ones
// before it (the shader divides by the atlas size it is drawn with).
@(private)
glyphs :: proc(ctx: ^Context, s: string, x, y: f32, color: Color) {
	stash := &ctx.fonts.stash
	draw_set_state(&ctx.draw, .Atlas, 0, ctx.clip)
	iter := fs.TextIterInit(stash, x, y, s)
	q: fs.Quad
	for fs.TextIterNext(stash, &iter, &q) {
		w, h := f32(stash.width), f32(stash.height)
		draw_quad(&ctx.draw, {q.x0, q.y0, q.x1 - q.x0, q.y1 - q.y0}, {q.s0 * w, q.t0 * h}, {q.s1 * w, q.t1 * h}, color)
	}
}
