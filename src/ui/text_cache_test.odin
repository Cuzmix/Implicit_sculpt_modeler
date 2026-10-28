package ui

import "core:fmt"
import "core:math"
import "core:testing"
import "core:unicode/utf8"

import fs "vendor:fontstash"

// Lines with kerning pairs, accents, digits and spaces at either end, which every path
// must place exactly as fontstash does.
@(private = "file")
LINES := [?]string{"AVATAR Yo, To WAVE", "Draw size 128.5", "  Café über naïve  ", "Wy", "x", "", "1.234 ms p99"}

// The vertices one call adds to a fresh draw list.
@(private = "file")
drawn :: proc(ctx: ^Context, f: proc(ctx: ^Context, i: int), i: int) -> []Vertex {
	draw_list_clear(&ctx.draw)
	draw_set_state(&ctx.draw, .Atlas, 0, ctx.clip)
	f(ctx, i)
	return ctx.draw.vertices[:]
}

@(private = "file")
same_vertices :: proc(t: ^testing.T, a, b: []Vertex, what: string, loc := #caller_location) {
	if !testing.expectf(t, len(a) == len(b), "%s: %d vertices against fontstash's %d", what, len(a), len(b), loc = loc) do return
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			testing.expectf(t, false, "%s: vertex %d is %v, fontstash's %v", what, i, a[i], b[i], loc = loc)
			return
		}
	}
}

@(private = "file")
Case :: struct {
	s:     string,
	x, y:  f32,
	size:  f32,
	font:  Font,
	align: Align,
}

@(private = "file")
cases: [dynamic]Case

@(private = "file")
case_cached :: proc(ctx: ^Context, i: int) {
	c := cases[i]
	text(ctx, c.s, c.x, c.y, c.size, {255, 255, 255, 255}, c.font, c.align)
}

// What text drew before the cache: fontstash aligning and placing every glyph.
@(private = "file")
case_fontstash :: proc(ctx: ^Context, i: int) {
	c := cases[i]
	d := px(ctx)
	stash := &ctx.fonts.stash
	text_state(ctx, c.size, c.font)
	fs.SetAlignHorizontal(stash, fs.AlignHorizontal(c.align))
	fs.SetAlignVertical(stash, .BASELINE)
	baseline := f32(int(c.y * d + CAP_HEIGHT * c.size * d * 0.5 + 0.5))
	glyphs(ctx, c.s, c.x * d, baseline, {255, 255, 255, 255})
}

@(test)
cached_text_draws_what_fontstash_draws :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	defer delete(cases)
	for density in ([]f32{1, 1.25, 2}) {
		frame_begin(&ctx, {window = {800, 600}, pixel_density = density})
		clear(&cases)
		for s in LINES {
			for font in ([]Font{.Regular, .Semibold}) {
				for align in Align {
					for x in ([]f32{10, 10.3, 251.77}) {
						append(&cases, Case{s, x, 33.4, 13, font, align})
						append(&cases, Case{s, x, 80, 17.5, font, align})
					}
				}
			}
		}
		for c, i in cases {
			want := make([]Vertex, len(drawn(&ctx, case_fontstash, i)), context.temp_allocator)
			copy(want, ctx.draw.vertices[:])
			// Twice: the first lays the line out, the second reads the cache.
			for pass in 0 ..< 2 {
				what := fmt.tprintf("%q %v %v at %v x%v, pass %d", c.s, c.font, c.align, c.x, density, pass)
				same_vertices(t, drawn(&ctx, case_cached, i), want, what)
			}
			got := text_width(&ctx, c.s, c.size, c.font)
			text_state(&ctx, c.size, c.font)
			testing.expect_value(t, got, fs.TextBounds(&ctx.fonts.stash, c.s) / density)
		}
		frame_end(&ctx)
	}
	testing.expect(t, ctx.fonts.cache.hits > ctx.fonts.cache.misses)
}

@(private = "file")
ICONS := [?]rune{ICON_UNDO, ICON_REDO}

@(private = "file")
icon_cached :: proc(ctx: ^Context, i: int) {
	icon(ctx, ICONS[i % len(ICONS)], {40.3 + f32(i), 20.6}, 20 + f32(i), {255, 255, 255, 255})
}

// What icon drew before the cache.
@(private = "file")
icon_fontstash :: proc(ctx: ^Context, i: int) {
	d := px(ctx)
	stash := &ctx.fonts.stash
	text_state(ctx, 20 + f32(i), .Icons)
	fs.SetAlignHorizontal(stash, .LEFT)
	fs.SetAlignVertical(stash, .BASELINE)
	buf, n := utf8.encode_rune(ICONS[i % len(ICONS)])
	s := string(buf[:n])
	bounds: [4]f32
	fs.TextBounds(stash, s, 0, 0, &bounds)
	c := [2]f32{40.3 + f32(i), 20.6} * d
	x := f32(int(c.x - (bounds[0] + bounds[2]) * 0.5 + 0.5))
	y := f32(int(c.y - (bounds[1] + bounds[3]) * 0.5 + 0.5))
	glyphs(ctx, s, x, y, {255, 255, 255, 255})
}

@(test)
cached_icons_sit_where_fontstash_put_them :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	frame_begin(&ctx, {window = {800, 600}, pixel_density = 1.5})
	for i in 0 ..< 6 {
		want := make([]Vertex, len(drawn(&ctx, icon_fontstash, i)), context.temp_allocator)
		copy(want, ctx.draw.vertices[:])
		for _ in 0 ..< 2 do same_vertices(t, drawn(&ctx, icon_cached, i), want, fmt.tprintf("icon %d", i))
	}
	frame_end(&ctx)
}

// The lines paragraph wrapped into before the cache: each candidate line measured by
// fontstash on its own.
@(private = "file")
wrapped_by_fontstash :: proc(ctx: ^Context, s: string, w, size: f32) -> [dynamic][2]int {
	lines := make([dynamic][2]int, context.temp_allocator)
	last_space, line_start := -1, 0
	for i := 0; i <= len(s); i += 1 {
		at_end := i == len(s)
		if !at_end && s[i] != ' ' && s[i] != '\n' do continue
		text_state(ctx, size, .Regular)
		if fs.TextBounds(&ctx.fonts.stash, s[line_start:i]) / px(ctx) > w && last_space > line_start {
			append(&lines, [2]int{line_start, last_space})
			line_start = last_space + 1
		}
		if at_end || s[i] == '\n' {
			append(&lines, [2]int{line_start, i})
			line_start = i + 1
		}
		last_space = i
	}
	return lines
}

@(test)
paragraphs_wrap_where_they_did :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	PARAGRAPH :: "Draws the surface out along its normals, as clay laid on. Hold Alt to carve instead; Shift smooths.\nWAVE AVATAR: kerning pairs wrap like any word."
	for w in ([]f32{90, 140, 233.5, 600}) {
		frame_begin(&ctx, input_at_rest())
		begin_anchored(&ctx, "p", .Start, .Start, {0, 0}, {})
		paragraph(&ctx, PARAGRAPH, w)
		end(&ctx)
		frame_end(&ctx)
		want := wrapped_by_fontstash(&ctx, PARAGRAPH, w, ctx.theme.small_size)
		line_h := math.ceil(ctx.theme.small_size * 1.45)
		box := ctx.placed[len(ctx.placed) - 1].rect
		testing.expectf(t, box.h == line_h * f32(len(want)), "width %v: %v high for %d lines", w, box.h, len(want))
	}
}

@(private = "file")
input_at_rest :: proc() -> Input {
	return {window = {800, 600}, pixel_density = 1, dt = 1.0 / 60}
}

@(test)
a_full_cache_keeps_the_lines_still_shown :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	c := &ctx.fonts.cache
	// A panel's label every frame, beside a value that changes every frame, until the
	// changing values fill the cache several times.
	for frame in 0 ..< TEXT_CACHE_RUNS * 3 {
		frame_begin(&ctx, input_at_rest())
		text(&ctx, "Strength", 10, 10, 13, {255, 255, 255, 255})
		text(&ctx, fmt.tprintf("%d", frame), 10, 30, 13, {255, 255, 255, 255})
		frame_end(&ctx)
		testing.expect(t, len(c.runs) <= TEXT_CACHE_RUNS)
	}
	// One miss for the label, the first time; one for each value.
	testing.expect_value(t, c.misses, 1 + TEXT_CACHE_RUNS * 3)
	misses := c.misses
	frame_begin(&ctx, input_at_rest())
	same := text_width(&ctx, "Strength", 13)
	frame_end(&ctx)
	testing.expect_value(t, c.misses, misses)
	text_state(&ctx, 13, .Regular)
	testing.expect_value(t, same, fs.TextBounds(&ctx.fonts.stash, "Strength"))
	// The pools hold only what the kept lines need.
	bytes: int
	for _, r in c.runs do bytes += int(r.byte_count)
	testing.expect_value(t, len(c.bytes), bytes)
}
