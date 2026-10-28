package ui

import "core:hash/xxhash"
import "core:math"
import "core:slice"

import fs "vendor:fontstash"

// Laying out text is most of the interface's time: fontstash finds every glyph in its
// table and asks stb_truetype for the kerning of every pair, each frame, for text that
// rarely changes. The kit keeps each line it laid out (the font, the size and the bytes
// as the key) as the glyphs fontstash placed for it, and lays a line out again only when
// it is new, the way Clay keeps measured text between frames. The immediate API stays:
// callers still pass strings every frame; the cache sits under text, text_width and icon.

// The most lines kept. Text that changes every frame (a timing, a slider's value) adds a
// line a frame, so the cache fills; when it does, lines unused for TEXT_CACHE_KEEP frames
// go, which leaves what the panels on screen show.
TEXT_CACHE_RUNS :: 4096

// A line unused this many frames may go when the cache is full: a second at 60 frames a
// second, longer than any panel's open or close animation, so text that fades out and
// back is kept.
TEXT_CACHE_KEEP :: 60

// One glyph as fontstash placed it, in the integers it rounds every step to, so the pen
// can be walked from any start exactly as fontstash walks it.
@(private)
Text_Glyph :: struct {
	kern:       f32, // added to the pen before the glyph (fontstash's rounded kerning; 0 first)
	advance:    f32, // added after it
	offset:     [2]f32, // the glyph's offset from the pen (fontstash's xoff + 1, yoff + 1)
	atlas:      [4]f32, // where it is in the atlas, in atlas pixels (x0, y0, x1, y1)
	byte_index: i32, // where its codepoint starts in the line
}

// A line laid out once: where its bytes and glyphs are in the cache's pools, its advance
// from a pen at 0 (fontstash's TextBounds), its ink's bounds there, and the last frame
// that used it.
@(private)
Text_Run :: struct {
	bytes_from:  i32,
	glyphs_from: i32,
	byte_count:  i32,
	glyph_count: i32,
	width:       f32,
	bounds:      [4]f32,
	used:        u64,
}

@(private)
Text_Key :: struct {
	hash:  u64,
	size:  i16, // fontstash's size in tenths of a pixel, which decides every glyph
	font:  Font,
	count: i32,
}

Text_Cache :: struct {
	runs:   map[Text_Key]Text_Run,
	bytes:  [dynamic]u8,
	glyphs: [dynamic]Text_Glyph,
	frame:  u64,
	// For tests and the exit stats: lines laid out by fontstash, and lines found.
	misses: int,
	hits:   int,
}

@(private)
text_cache_destroy :: proc(c: ^Text_Cache) {
	delete(c.runs)
	delete(c.bytes)
	delete(c.glyphs)
	c^ = {}
}

// The line `s` in the font and size set by text_state, laid out by fontstash the first
// time and kept. Returns nil for a line fontstash cannot place every glyph of (a size
// under a fifth of a pixel), which the caller lays out as fontstash would.
@(private)
text_run :: proc(ctx: ^Context, s: string, font: Font) -> (run: ^Text_Run, glyphs: []Text_Glyph) {
	c := &ctx.fonts.cache
	stash := &ctx.fonts.stash
	state := fs.__getState(stash)
	key := Text_Key {
		// xxhash refuses the empty line's nil bytes; its key needs no hash.
		hash  = xxhash.XXH3_64_default(transmute([]u8)s) if len(s) > 0 else 0,
		size  = i16(state.size * 10),
		font  = font,
		count = i32(len(s)),
	}
	if r, ok := &c.runs[key]; ok && string(c.bytes[r.bytes_from:][:r.byte_count]) == s {
		r.used = c.frame
		c.hits += 1
		return r, c.glyphs[r.glyphs_from:][:r.glyph_count]
	}
	if len(c.runs) >= TEXT_CACHE_RUNS do text_cache_trim(c)
	built, ok := text_run_build(ctx, s)
	if !ok do return nil, nil
	c.misses += 1
	// A key that collided with another line's hash takes its place.
	c.runs[key] = built
	r := &c.runs[key]
	return r, c.glyphs[r.glyphs_from:][:r.glyph_count]
}

// Lays `s` out with fontstash from a pen at 0, as TextBounds and TextIterNext would, and
// appends its bytes and glyphs to the pools.
@(private = "file")
text_run_build :: proc(ctx: ^Context, s: string) -> (run: Text_Run, ok: bool) {
	c := &ctx.fonts.cache
	stash := &ctx.fonts.stash
	fs.SetAlignHorizontal(stash, .LEFT)
	fs.SetAlignVertical(stash, .BASELINE)
	run = {
		bytes_from  = i32(len(c.bytes)),
		glyphs_from = i32(len(c.glyphs)),
		byte_count  = i32(len(s)),
		used        = c.frame,
	}
	iter := fs.TextIterInit(stash, 0, 0, s)
	q: fs.Quad
	for fs.TextIterNext(stash, &iter, &q) {
		glyph, found := fs.__getGlyph(stash, iter.font, iter.codepoint, iter.isize, iter.iblur)
		if !found || iter.previousGlyphIndex == -1 {
			// fontstash draws the quad before this one again for a glyph it could not
			// place; keeping that as it does is not worth it at a size nothing can read.
			resize(&c.glyphs, int(run.glyphs_from))
			return {}, false
		}
		advance := f32(int(f32(glyph.xadvance) / 10 + 0.5))
		g := Text_Glyph {
			kern       = iter.nextx - iter.x - advance,
			advance    = advance,
			offset     = {f32(glyph.xoff + 1), f32(glyph.yoff + 1)},
			atlas      = {f32(glyph.x0 + 1), f32(glyph.y0 + 1), f32(glyph.x1 - 1), f32(glyph.y1 - 1)},
			byte_index = i32(iter.str),
		}
		// TextBounds starts its box at the pen (0, 0) and widens it by each quad.
		run.bounds = {min(run.bounds[0], q.x0), min(run.bounds[1], q.y0), max(run.bounds[2], q.x1), max(run.bounds[3], q.y1)}
		append(&c.glyphs, g)
	}
	run.width = iter.nextx
	run.glyph_count = i32(len(c.glyphs)) - run.glyphs_from
	append(&c.bytes, s)
	return run, true
}

// Keeps the lines used in the last TEXT_CACHE_KEEP frames, packing their bytes and glyphs
// to the front of the pools; when those still fill half the cache, starts it empty.
@(private = "file")
text_cache_trim :: proc(c: ^Text_Cache) {
	kept := 0
	for _, r in c.runs {
		if c.frame - r.used < TEXT_CACHE_KEEP do kept += 1
	}
	if kept * 2 >= TEXT_CACHE_RUNS {
		clear(&c.runs)
		clear(&c.bytes)
		clear(&c.glyphs)
		return
	}
	// Packing in place moves runs only toward the front, so the pools are walked in the
	// order the runs were added (the bytes and glyphs offsets rise together).
	Kept :: struct {
		from: i32,
		key:  Text_Key,
	}
	order := make([dynamic]Kept, 0, kept, context.temp_allocator)
	for k, r in c.runs {
		if c.frame - r.used < TEXT_CACHE_KEEP do append(&order, Kept{r.glyphs_from, k})
	}
	slice.sort_by(order[:], proc(a, b: Kept) -> bool {return a.from < b.from})
	bytes_at, glyphs_at: i32
	for o in order {
		r := &c.runs[o.key]
		copy(c.bytes[bytes_at:], c.bytes[r.bytes_from:][:r.byte_count])
		copy(c.glyphs[glyphs_at:], c.glyphs[r.glyphs_from:][:r.glyph_count])
		r.bytes_from, r.glyphs_from = bytes_at, glyphs_at
		bytes_at += r.byte_count
		glyphs_at += r.glyph_count
	}
	for k, r in c.runs {
		if c.frame - r.used >= TEXT_CACHE_KEEP do delete_key(&c.runs, k)
	}
	resize(&c.bytes, int(bytes_at))
	resize(&c.glyphs, int(glyphs_at))
}

// The advance of a laid-out line from a pen at `x`, added up as fontstash's TextBounds
// does, so a centred or right-aligned line starts where it always did.
@(private)
text_run_width_from :: proc(glyphs: []Text_Glyph, x: f32) -> f32 {
	pen := x
	for g in glyphs {
		pen += g.kern
		pen += g.advance
	}
	return pen - x
}

// The advance of the part of a laid-out line from byte `from` up to byte `to`, as
// TextBounds gives for that part alone: its first glyph takes no kerning.
@(private)
text_run_part_width :: proc(glyphs: []Text_Glyph, from, to: int) -> f32 {
	pen: f32
	first := true
	for g in glyphs {
		if int(g.byte_index) < from do continue
		if int(g.byte_index) >= to do break
		if !first do pen += g.kern
		first = false
		pen += g.advance
	}
	return pen
}

// Emits a laid-out line's quads with the pen starting at `x` and the baseline at `y`
// (physical pixels), aligned as fontstash's TextIterInit aligns, and placed glyph by
// glyph as its __getQuad places them.
@(private)
text_run_draw :: proc(ctx: ^Context, glyphs: []Text_Glyph, x, y: f32, align: Align, color: Color) {
	stash := &ctx.fonts.stash
	draw_set_state(&ctx.draw, .Atlas, 0, ctx.clip)
	x := x
	switch align {
	case .Left:
	case .Center:
		x = math.round(x - text_run_width_from(glyphs, x) * 0.5)
	case .Right:
		x -= text_run_width_from(glyphs, x)
	}
	baseline := math.round(y)
	w, h := f32(stash.width), f32(stash.height)
	pen := x
	for g in glyphs {
		pen += g.kern
		rx := math.floor(pen + g.offset.x)
		ry := math.floor(baseline + g.offset.y)
		q := fs.Quad {
			x0 = rx,
			y0 = ry,
			x1 = rx + g.atlas[2] - g.atlas[0],
			y1 = ry + g.atlas[3] - g.atlas[1],
			s0 = g.atlas[0] * stash.itw,
			t0 = g.atlas[1] * stash.ith,
			s1 = g.atlas[2] * stash.itw,
			t1 = g.atlas[3] * stash.ith,
		}
		draw_quad(&ctx.draw, {q.x0, q.y0, q.x1 - q.x0, q.y1 - q.y0}, {q.s0 * w, q.t0 * h}, {q.s1 * w, q.t1 * h}, color)
		pen += g.advance
	}
}
