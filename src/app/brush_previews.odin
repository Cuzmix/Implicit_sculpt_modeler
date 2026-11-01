package main

import "base:runtime"
import "core:hash"
import "core:math"
import "core:mem"
import "core:sync"
import "core:strings"
import "core:thread"
import "core:time"

import "../render"
import "../sculpt"
import "../ui"

// The brushes' pictures made by the brushes themselves (the UI review's U6): every brush and
// preset the browser lists draws one stroke across a strip of clay through the sculpting
// engine (sculpt.preview_render), on a thread of its own at low priority, into one atlas of
// cells that is uploaded once when the batch is done. The cards draw a brush's cell where
// lens_stroke_preview drew its hand-made sketch, which stays for what has no cell yet (the
// first moments after launch), for Cloth and History, which the preview cannot show, and for
// tools and mask shapes. The batch is made again whenever what the browser lists changes (a
// preset saved, a pack imported), in the background, the cards keeping the old pictures
// until the new atlas is ready. A picture shows the brush's own values (strength, plane,
// tip, smoothing) as it comes or as its preset keeps them, not the slider as it stands, so it
// stays the same picture between strokes; Paint shows a fixed red.

// The image id the interface draws the brushes' pictures with.
KIT_BRUSH_PREVIEWS_IMAGE :: KIT_MATCAP_IMAGE_END

// Cells across the atlas.
@(private = "file")
PREVIEW_COLUMNS :: 10

// What one cell shows: the browser's key for the brush and the brush to stroke with.
@(private = "file")
Preview_Want :: struct {
	key:   string, // owned by the batch (heap)
	brush: sculpt.Brush,
}

// A batch on its thread: what it was asked for, the atlas it fills, and whether it is done.
@(private = "file")
Preview_Batch :: struct {
	want:    []Preview_Want,
	pixels:  []u8, // the atlas, PREVIEW_COLUMNS cells across
	rows:    int,
	made:    []bool, // per cell: whether the brush could be drawn
	sign:    u64,
	thread:  ^thread.Thread,
	done:    bool,
	took_ms: f64,
}

Brush_Previews :: struct {
	batch:   ^Preview_Batch, // the one running, if any
	atlas:   render.Texture,
	size:    [2]int, // the atlas, in pixels
	cells:   map[string]int, // key (heap) to cell, for the brushes the atlas has
	sign:    u64, // what the atlas (or the batch running) was made for
	checked: int, // the frame the browser's list was last compared, so once a frame
	batches: int, // atlases made, for the exit stats
	drawn:   int, // pictures in the atlas
	took_ms: f64, // how long the last batch took on its thread
}

// The brush a picture strokes with: `v`'s kind and the values that change what a stroke
// does; the preview sets the radius and leaves symmetry and the view's fields off.
@(private = "file")
preview_brush :: proc(v: Preset_Values) -> sculpt.Brush {
	k := v.kind
	return sculpt.Brush {
		kind = k,
		strength = v.strength,
		color = {214, 64, 48},
		smooth_mode = v.smooth_mode if k == .Smooth else .Smooth,
		smooth_stable = k == .Smooth && v.smooth_stable,
		no_accumulate = v.no_accumulate && accumulate_applies(k),
		lock_plane = v.lock_plane,
		volume = v.elastic_volume,
		hook_pinch = v.hook_pinch if k == .Snake_Hook else 0,
		hook_rake = v.hook_rake if k == .Snake_Hook else 0,
		hook_elastic = k == .Snake_Hook && v.hook_elastic,
		tip_roundness = v.tip_roundness,
		tip_scale = v.tip_scale,
		trim_angle = math.to_radians(v.trim_angle),
		trim_fixed = !v.trim_dynamic,
		plane_short = {1 - v.plane_height, 1 - v.plane_depth},
	}
}

// What the browser lists as brushes and presets, each with the brush its picture strokes
// with (temp memory).
@(private = "file")
preview_wants :: proc(app: ^App) -> []Preview_Want {
	defaults := brush_defaults()
	out := make([dynamic]Preview_Want, 0, 64, context.temp_allocator)
	for l in brush_items_all(app) {
		if l.item.what != .Slot || l.item.slot.command.id != .None do continue
		s := l.item.slot
		v := preset_values_of(&defaults, s.kind)
		v.strength = BRUSHES[s.kind].strength
		if s.preset > 0 {
			p, ok := preset_at(app, s.preset)
			if !ok do continue
			v = p.values
		}
		if !sculpt.preview_offered(v.kind) do continue
		append(&out, Preview_Want{key = l.key, brush = preview_brush(v)})
	}
	return out[:]
}

// A hash of what `wants` asks for, which decides whether the atlas is out of date.
@(private = "file")
preview_sign :: proc(wants: []Preview_Want) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for w in wants {
		h = hash.fnv64a(transmute([]u8)w.key, h)
		b := w.brush
		h = hash.fnv64a(mem.ptr_to_bytes(&b), h)
	}
	return max(h, 1)
}

// Once a frame while something shows the pictures: compares what the browser lists with
// what the atlas was made for and starts a batch when they differ and none is running.
brush_previews_want :: proc(app: ^App) {
	bp := &app.brush_previews
	if bp.checked == app.kit.frame do return
	bp.checked = app.kit.frame
	if bp.batch != nil do return
	wants := preview_wants(app)
	sign := preview_sign(wants)
	if sign == bp.sign do return
	bp.sign = sign
	heap := runtime.heap_allocator()
	b := new(Preview_Batch, heap)
	b.sign = sign
	b.want = make([]Preview_Want, len(wants), heap)
	for w, i in wants do b.want[i] = {key = strings.clone(w.key, heap), brush = w.brush}
	b.rows = max((len(wants) + PREVIEW_COLUMNS - 1) / PREVIEW_COLUMNS, 1)
	b.pixels = make([]u8, PREVIEW_COLUMNS * sculpt.PREVIEW_W * b.rows * sculpt.PREVIEW_H * 4, heap)
	b.made = make([]bool, len(wants), heap)
	bp.batch = b
	b.thread = thread.create_and_start_with_data(b, proc(data: rawptr) {
		b := (^Preview_Batch)(data)
		// Everything it makes is freed with the same heap allocator; it uses no temp memory.
		context.allocator = runtime.heap_allocator()
		start := time.tick_now()
		cell := make([]u8, sculpt.PREVIEW_W * sculpt.PREVIEW_H * 4)
		defer delete(cell)
		stride := PREVIEW_COLUMNS * sculpt.PREVIEW_W * 4
		for w, i in b.want {
			if !sculpt.preview_render(w.brush, cell) do continue
			x0, y0 := (i % PREVIEW_COLUMNS) * sculpt.PREVIEW_W, (i / PREVIEW_COLUMNS) * sculpt.PREVIEW_H
			for row in 0 ..< sculpt.PREVIEW_H {
				copy(b.pixels[(y0 + row) * stride + x0 * 4:][:sculpt.PREVIEW_W * 4], cell[row * sculpt.PREVIEW_W * 4:][:sculpt.PREVIEW_W * 4])
			}
			b.made[i] = true
		}
		b.took_ms = time.duration_milliseconds(time.tick_since(start))
		sync.atomic_store(&b.done, true)
	}, context, .Low, name = "brush previews")
}

// Takes a finished batch: uploads its atlas and puts it in place of the one there was. Once
// a frame, before the interface is laid out.
brush_previews_poll :: proc(app: ^App) {
	bp := &app.brush_previews
	b := bp.batch
	if b == nil || !sync.atomic_load(&b.done) do return
	thread.join(b.thread)
	thread.destroy(b.thread)
	bp.batch = nil
	defer preview_batch_free(b)
	w, h := PREVIEW_COLUMNS * sculpt.PREVIEW_W, b.rows * sculpt.PREVIEW_H
	tex := render.picture_create(&app.renderer, b.pixels, w, h)
	if tex == nil do return
	render.matcap_destroy(&app.renderer, &bp.atlas)
	bp.atlas, bp.size = tex, {w, h}
	preview_cells_clear(bp)
	heap := runtime.heap_allocator()
	if bp.cells == nil do bp.cells = make(map[string]int, 64, heap)
	for want, i in b.want do if b.made[i] {
		bp.cells[strings.clone(want.key, heap)] = i
		bp.drawn += 1
	}
	bp.batches += 1
	bp.took_ms = b.took_ms
}

// Draws the picture of the brush the browser keys `key` in `r`, cut to its shape as a
// picture tile is; false when it has none (yet), for the caller to draw the sketch.
brush_preview_draw :: proc(app: ^App, key: string, r: ui.Rect) -> bool {
	brush_previews_want(app)
	bp := &app.brush_previews
	cell, ok := bp.cells[key]
	if !ok || bp.atlas == nil do return false
	cw, ch := f32(sculpt.PREVIEW_W) / f32(bp.size.x), f32(sculpt.PREVIEW_H) / f32(bp.size.y)
	lo := [2]f32{f32(cell % PREVIEW_COLUMNS) * cw, f32(cell / PREVIEW_COLUMNS) * ch}
	ui.picture_cover(&app.kit.ctx, r, {image = KIT_BRUSH_PREVIEWS_IMAGE, lo = lo, hi = lo + {cw, ch}, aspect = f32(sculpt.PREVIEW_W) / f32(sculpt.PREVIEW_H)})
	return true
}

// Waits for a batch still running and releases the atlas (the app is closing).
brush_previews_destroy :: proc(app: ^App) {
	bp := &app.brush_previews
	if b := bp.batch; b != nil {
		thread.join(b.thread)
		thread.destroy(b.thread)
		preview_batch_free(b)
		bp.batch = nil
	}
	render.matcap_destroy(&app.renderer, &bp.atlas)
	preview_cells_clear(bp)
	delete(bp.cells)
	bp.cells = nil
}

@(private = "file")
preview_cells_clear :: proc(bp: ^Brush_Previews) {
	heap := runtime.heap_allocator()
	for key in bp.cells do delete(key, heap)
	clear(&bp.cells)
	bp.drawn = 0
}

@(private = "file")
preview_batch_free :: proc(b: ^Preview_Batch) {
	heap := runtime.heap_allocator()
	for w in b.want do delete(w.key, heap)
	delete(b.want, heap)
	delete(b.pixels, heap)
	delete(b.made, heap)
	free(b, heap)
}
