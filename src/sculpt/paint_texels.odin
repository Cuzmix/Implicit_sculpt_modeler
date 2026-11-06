package sculpt

import "base:runtime"

import "../jobs"
import "../uv"

// Texture paint layers (notes/paint/texture-layers-design.md): a paint layer that lives in
// a texture laid through the object's UVs instead of on its vertices, so paint is as fine
// as the texture rather than the mesh. The texture is kept as sparse tiles of
// TEXEL_TILE x TEXEL_TILE texels, made only where something is painted, so an unpainted
// 4096 layer costs a table of pointers.
//
// The layers belong to the object (Levels.texels), not to a level, since a texture follows
// the UV layout, which every level takes from the base. Each layer has a row in the paint
// stack (Paint_Layer.texels names it), so its name, eye, opacity, channels, order and the
// stack's undo are the vertex layers' own. Texture layers always stand above the vertex
// layers (paint_first_texture), so what shows is the vertex composite with the texture
// composite laid over it, and neither is ever mixed into the other.
//
// Where each texel is on the surface comes from the texel map (Texel_Map): per texel the
// triangle of the current level it lies in and its barycentric place there. A position
// read through it follows the live vertices, so sculpting never makes it stale; only a
// change of the level shown, its triangles or the UVs builds it again.
//
// Every allocation here uses the heap allocator, made and freed alike, since tiles are
// made inside jobs.

TEXEL_TILE :: 128
TILE_TEXELS :: TEXEL_TILE * TEXEL_TILE
// The sizes a texture may have a side, the bake's own.
TEXEL_SIDE_MIN :: 512
TEXEL_SIDE_MAX :: 4096
// A texel of the map no triangle covers.
TEXEL_NONE :: max(u32)
// How far, in texels, the map reaches past an island's edge (its gutter), so sampling
// with filtering at a seam reads the island's own paint rather than the empty texture.
TEXEL_GUTTER :: 2

// A tile's channels, each TILE_TEXELS long in rows from the top, nil when not painted:
// colour and its coverage, and roughness and metal with theirs (Material_Paint).
Texel_Tile :: struct {
	color:    []Color,
	material: []Material_Paint,
}

Texel_Layer :: struct {
	id:    u32,
	tiles: []^Texel_Tile, // (side / TEXEL_TILE)² from the top left, row by row; nil: unpainted
}

// One tile of the texel map: per texel its triangle (TEXEL_NONE for none) and its second
// and third barycentric coordinates as fractions of 65535.
Texel_Map_Tile :: struct {
	tri:  []u32,
	bary: [][2]u16,
}

// The texel map and what it was made from, so a change of any rebuilds it.
Texel_Map :: struct {
	tiles:     []^Texel_Map_Tile, // nil where no triangle reaches
	built:     bool,
	side:      int,
	level:     int,
	levels:    int,
	triangles: int,
	indices:   rawptr, // the level's index array: a new one means new triangles
	uv_stamp:  u32,
}

Texels :: struct {
	side:    int, // the size of every texture layer, fixed while any exists
	layers:  [dynamic]Texel_Layer,
	next_id: u32,
	// The composite of the visible texture layers per tile, premultiplied by coverage (so
	// filtering and laying it over the surface need no division); nil where none paints.
	shown:   []^Texel_Tile,
	marked:  []bool, // per tile: listed in `dirty`
	dirty:   [dynamic]u32,
	whole:   bool, // every tile's composite is out of date
	// What the stack looked like at the last composite, so a change of an eye, an opacity
	// or the order composites everything again.
	stack:   [MAX_PAINT_LAYERS][2]u32,
	opacity: [MAX_PAINT_LAYERS]f32,
	rows:    int,
	// Tiles whose composite changed since the GPU last took them (levels_texels_take).
	sent:    []bool,
	changed: [dynamic]u32,
	all:     bool, // every tile changed
	tex_map: Texel_Map,
}

// Whether `side` is a size a texture layer may have.
texel_side_ok :: proc(side: int) -> bool {
	return side >= TEXEL_SIDE_MIN && side <= TEXEL_SIDE_MAX && side & (side - 1) == 0
}

// Tiles a side of a texture `side` texels square.
texel_tiles_across :: proc(side: int) -> int {return side / TEXEL_TILE}

@(private = "file")
tile_new :: proc(color, material: bool) -> ^Texel_Tile {
	h := runtime.heap_allocator()
	t := new(Texel_Tile, h)
	if color do t.color = make([]Color, TILE_TEXELS, h)
	if material do t.material = make([]Material_Paint, TILE_TEXELS, h)
	return t
}

@(private = "file")
tile_free :: proc(t: ^Texel_Tile) {
	if t == nil do return
	h := runtime.heap_allocator()
	delete(t.color, h)
	delete(t.material, h)
	free(t, h)
}

@(private = "file")
tile_clone :: proc(t: ^Texel_Tile) -> ^Texel_Tile {
	if t == nil do return nil
	c := tile_new(t.color != nil, t.material != nil)
	copy(c.color, t.color)
	copy(c.material, t.material)
	return c
}

@(private = "file")
tile_bytes :: proc(t: ^Texel_Tile) -> int {
	return 0 if t == nil else (len(t.color) + len(t.material)) * size_of(Color)
}

@(private = "file")
layer_free :: proc(l: ^Texel_Layer) {
	for t in l.tiles do tile_free(t)
	delete(l.tiles, runtime.heap_allocator())
	l^ = {}
}

@(private = "file")
map_free :: proc(m: ^Texel_Map) {
	h := runtime.heap_allocator()
	for t in m.tiles {
		if t == nil do continue
		delete(t.tri, h)
		delete(t.bary, h)
		free(t, h)
	}
	delete(m.tiles, h)
	m^ = {}
}

@(private = "file")
shown_free :: proc(t: ^Texels) {
	h := runtime.heap_allocator()
	for tile in t.shown do tile_free(tile)
	delete(t.shown, h)
	delete(t.marked, h)
	delete(t.sent, h)
	t.shown, t.marked, t.sent = nil, nil, nil
	clear(&t.dirty)
	clear(&t.changed)
}

// Frees every texture layer, the composite and the map (levels_destroy).
texels_destroy :: proc(t: ^Texels) {
	for &l in t.layers do layer_free(&l)
	delete(t.layers)
	shown_free(t)
	delete(t.dirty)
	delete(t.changed)
	map_free(&t.tex_map)
	t^ = {}
}

// The texture layer with id `id`, or nil.
texels_layer :: proc(t: ^Texels, id: u32) -> ^Texel_Layer {
	if id == 0 do return nil
	for &l in t.layers do if l.id == id do return &l
	return nil
}

// Bytes the texture layers, their composite and the texel map hold, for the memory count.
texels_bytes :: proc(t: ^Texels) -> (n: int) {
	for l in t.layers {
		n += len(l.tiles) * size_of(rawptr)
		for tile in l.tiles do n += tile_bytes(tile)
	}
	for tile in t.shown do n += tile_bytes(tile)
	for m in t.tex_map.tiles do if m != nil do n += TILE_TEXELS * (size_of(u32) + size_of([2]u16))
	return
}

// Adds an empty texture layer `side` texels square above the picked layer (and above every
// vertex layer) and picks it, as an undo step of the stack. Returns its index in the stack,
// or -1: dynamic topology on, no UVs, a full stack, a size that is not one of the bake's,
// or a size other than the one the object's texture layers already have (counting the ones
// an undo step holds).
levels_texel_layer_add :: proc(l: ^Levels, side: int) -> int {
	s := &levels_current(l).sculptor
	_ = sculptor_stroke_end(s)
	if s.dyn != nil || !levels_has_uvs(l) || len(s.paint.list) >= MAX_PAINT_LAYERS || !texel_side_ok(side) do return -1
	t := &l.texels
	if len(t.layers) > 0 && t.side != side do return -1
	if t.side != side {
		shown_free(t)
		map_free(&t.tex_map)
		t.side = side
	}
	t.next_id += 1
	across := texel_tiles_across(side)
	append(&t.layers, Texel_Layer{id = t.next_id, tiles = make([]^Texel_Tile, across * across, runtime.heap_allocator())})
	index := sculptor_paint_picked(s) + 1 if s.paint.picked != 0 else len(s.paint.list)
	// Above every vertex layer.
	top := 0
	for row, i in s.paint.list do if row.texels == 0 do top = i + 1
	index = max(index, top)
	row := paint_layer_make(s, "Texture ")
	row.texels = t.next_id
	sculptor_stroke_begin(s)
	s.history.current.paint_op = {active = true, toggle = true, index = index, held = true, layer = row, picked = row.id}
	paint_op_swap(s, &s.history.current.paint_op)
	_ = sculptor_stroke_end(s)
	t.whole = true
	return index
}

// Frees the texture layers nothing names any more: no level's stack has a row for them and
// no undo step holds one (a layer taken out stays while its step could put it back). Call
// it after a layer is taken out and after undo steps are dropped. With no layer left, the
// composite and the map go too.
levels_texels_sweep :: proc(l: ^Levels) {
	t := &l.texels
	if len(t.layers) == 0 do return
	named := make(map[u32]bool, 16, context.temp_allocator)
	note :: proc(named: ^map[u32]bool, op: Paint_Op) {
		if op.active && op.held && op.layer.texels != 0 do named[op.layer.texels] = true
	}
	for lv in l.levels {
		s := &lv.sculptor
		for row in s.paint.list do if row.texels != 0 do named[row.texels] = true
		for step in s.history.done do note(&named, step.paint_op)
		for step in s.history.undone do note(&named, step.paint_op)
		note(&named, s.history.current.paint_op)
	}
	// In id order, which is the order they were made, so what is kept keeps its order.
	kept := 0
	for i in 0 ..< len(t.layers) {
		if t.layers[i].id in named {
			t.layers[kept] = t.layers[i]
			kept += 1
		} else do layer_free(&t.layers[i])
	}
	resize(&t.layers, kept)
	if kept == 0 {
		shown_free(t)
		map_free(&t.tex_map)
	}
	t.whole = true
}

// The rows of the current stack that are texture layers, bottom up, with what each shows.
@(private = "file")
Texel_Row :: struct {
	layer:  ^Texel_Layer,
	weight: f32,
}

@(private = "file")
texel_rows :: proc(l: ^Levels, rows: ^[MAX_PAINT_LAYERS]Texel_Row) -> (count: int) {
	s := &levels_current(l).sculptor
	for row in s.paint.list {
		if row.texels == 0 || !row.visible || row.opacity <= 0 do continue
		layer := texels_layer(&l.texels, row.texels)
		if layer == nil do continue
		rows[count] = {layer, row.opacity}
		count += 1
	}
	return
}

// Marks tile `index`'s composite out of date.
@(private)
texels_touch :: proc(t: ^Texels, index: u32) {
	if t.marked == nil || t.marked[index] do return
	t.marked[index] = true
	append(&t.dirty, index)
}

// Brings the composite up to date: every tile after a change of the stack's texture rows
// (an eye, an opacity, the order, a layer in or out), else the tiles painted since. The
// tiles it composited are listed for the GPU (levels_texels_take). Runs on the frame
// thread, before the textured draw reads `shown`.
levels_texels_flush :: proc(l: ^Levels) {
	t := &l.texels
	if t.side == 0 do return
	rows: [MAX_PAINT_LAYERS]Texel_Row
	count := texel_rows(l, &rows)
	// The stack as it shows now, to tell a change of it.
	stack: [MAX_PAINT_LAYERS][2]u32
	opacity: [MAX_PAINT_LAYERS]f32
	for r, i in rows[:count] do stack[i], opacity[i] = {r.layer.id, 1}, r.weight
	if count != t.rows || stack != t.stack || opacity != t.opacity {
		t.stack, t.opacity, t.rows = stack, opacity, count
		t.whole = true
	}
	across := texel_tiles_across(t.side)
	tiles := across * across
	h := runtime.heap_allocator()
	if t.shown == nil {
		t.shown = make([]^Texel_Tile, tiles, h)
		t.marked = make([]bool, tiles, h)
		t.sent = make([]bool, tiles, h)
		t.whole = true
	}
	if t.whole {
		clear(&t.dirty)
		for i in 0 ..< tiles {
			t.marked[i] = true
			append(&t.dirty, u32(i))
		}
		t.whole = false
		t.all = true
	}
	if len(t.dirty) == 0 do return
	Job :: struct {
		t:     ^Texels,
		rows:  []Texel_Row,
		out:   []^Texel_Tile,
	}
	job := Job{t, rows[:count], make([]^Texel_Tile, len(t.dirty), context.temp_allocator)}
	jobs.parallel_for(l.pool, len(t.dirty), &job, proc(data: rawptr, i: int) {
		job := cast(^Job)data
		job.out[i] = texel_composite(job.rows, int(job.t.dirty[i]), job.t.side)
	})
	for index, i in t.dirty {
		tile_free(t.shown[index])
		t.shown[index] = job.out[i]
		t.marked[index] = false
		if !t.sent[index] {
			t.sent[index] = true
			append(&t.changed, index)
		}
	}
	clear(&t.dirty)
}

// The composite of tile `index` over `rows` (bottom up), premultiplied, or nil where none
// of them painted it. Made with the heap allocator, inside a job.
@(private = "file")
texel_composite :: proc(rows: []Texel_Row, index, side: int) -> ^Texel_Tile {
	color, material := false, false
	for r in rows {
		tile := r.layer.tiles[index]
		if tile == nil do continue
		color ||= tile.color != nil
		material ||= tile.material != nil
	}
	if !color && !material do return nil
	out := tile_new(color, material)
	across := texel_tiles_across(side)
	x0, y0 := (index % across) * TEXEL_TILE, (index / across) * TEXEL_TILE
	for k in 0 ..< TILE_TEXELS {
		dither := texel_dither(x0 + k % TEXEL_TILE, y0 + k / TEXEL_TILE)
		if color {
			rgb: [3]f32
			a: f32
			for j := len(rows) - 1; j >= 0; j -= 1 {
				tile := rows[j].layer.tiles[index]
				if tile == nil || tile.color == nil do continue
				c := tile.color[k]
				if c.a == 0 do continue
				x := f32(c.a) * (1.0 / 255) * rows[j].weight * (1 - a)
				rgb += {f32(c.r), f32(c.g), f32(c.b)} * x
				a += x
				if a >= 1 do break
			}
			for c in 0 ..< 3 do out.color[k][c] = texel_byte(rgb[c], dither)
			out.color[k].a = texel_byte(a * 255, dither)
		}
		if material {
			value, cover: [2]f32
			for j := len(rows) - 1; j >= 0; j -= 1 {
				tile := rows[j].layer.tiles[index]
				if tile == nil || tile.material == nil do continue
				m := tile.material[k]
				for c in 0 ..< 2 {
					x := f32(m[2 * c + 1]) * (1.0 / 255) * rows[j].weight * (1 - cover[c])
					value[c] += f32(m[2 * c]) * x
					cover[c] += x
				}
				if cover[0] >= 1 && cover[1] >= 1 do break
			}
			for c in 0 ..< 2 {
				out.material[k][2 * c] = texel_byte(value[c], dither)
				out.material[k][2 * c + 1] = texel_byte(cover[c] * 255, dither)
			}
		}
	}
	return out
}

// An ordered dither for texel (x, y) within ±0.47 of a step, so soft layers over each other
// do not band in 8 bits and a whole step (one layer at full opacity) comes out exactly.
@(private = "file")
texel_dither :: #force_inline proc(x, y: int) -> f32 {
	@(static, rodata)
	BAYER := [16]f32{0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5}
	return ((BAYER[(y & 3) * 4 + (x & 3)] + 0.5) * (1.0 / 16) - 0.5) * 0.94
}

@(private = "file")
texel_byte :: #force_inline proc(v, dither: f32) -> u8 {return u8(clamp(v + dither + 0.5, 0, 255))}

// The tiles whose composite changed since the last call, for the GPU to take, or `all`
// when every tile did (the composite was made again). Clears the list; the slice is the
// texels' own until the next flush.
levels_texels_take :: proc(l: ^Levels) -> (changed: []u32, all: bool) {
	t := &l.texels
	changed, all = t.changed[:], t.all
	for index in t.changed do t.sent[index] = false
	clear(&t.changed)
	t.all = false
	return
}

// The composite's tile `index` (premultiplied colour and material, either nil), for the GPU.
levels_texels_shown :: proc(l: ^Levels, index: int) -> ^Texel_Tile {
	t := &l.texels
	return t.shown[index] if t.shown != nil else nil
}

// Whether any texture layer shows: a visible row with a painted tile.
levels_texels_show :: proc(l: ^Levels) -> bool {
	for tile in l.texels.shown do if tile != nil do return true
	return false
}

// Brings the texel map up to date for the current level and the UVs, building it when
// either changed. False without UVs (or with UVs that do not fit the level).
levels_texel_map :: proc(l: ^Levels) -> bool {
	t := &l.texels
	m := &t.tex_map
	if t.side == 0 || !levels_has_uvs(l) do return false
	lv := levels_current(l)
	indices := lv.mesh.indices[:]
	if m.built && m.side == t.side && m.level == l.current && m.levels == len(l.levels) && m.triangles == len(indices) / 3 && m.indices == raw_data(indices) && m.uv_stamp == l.uv_stamp do return true
	map_free(m)
	u, ok := levels_uvs_at(l, l.current, context.temp_allocator)
	if !ok || len(u.corner) != len(indices) / 3 do return false
	m.tiles = texel_map_build(u, len(indices) / 3, t.side, l.pool)
	m.built, m.side, m.level, m.levels, m.triangles, m.indices, m.uv_stamp = true, t.side, l.current, len(l.levels), len(indices) / 3, raw_data(indices), l.uv_stamp
	return true
}

// Rasterises the triangles' UVs at `side` texels square: each texel whose centre a
// triangle covers takes it (the lowest numbered where islands overlap) and its barycentric
// place; then texels up to TEXEL_GUTTER away from every island take the nearest covered
// texel's (the lowest triangle, then the first texel, on a tie). The same map on any
// thread count: triangles are binned to tiles in order and each tile is one job's.
@(private = "file")
texel_map_build :: proc(u: uv.Uvs, triangles, side: int, pool: ^jobs.Pool) -> []^Texel_Map_Tile {
	across := texel_tiles_across(side)
	tiles := across * across
	fs := f32(side)
	// The triangles each tile's texels may lie in, by a counting sort over tiles.
	tile_box :: proc(c: [3][2]f32, fs: f32, across: int) -> (lo, hi: [2]int) {
		lo_f := [2]f32{max(f32), max(f32)}
		hi_f := [2]f32{min(f32), min(f32)}
		for p in c {
			q := [2]f32{p.x * fs, (1 - p.y) * fs}
			lo_f, hi_f = {min(lo_f.x, q.x), min(lo_f.y, q.y)}, {max(hi_f.x, q.x), max(hi_f.y, q.y)}
		}
		// Texel centres at k + 0.5: those inside [lo, hi] plus the gutter.
		g := f32(TEXEL_GUTTER)
		lo = {int(clamp((lo_f.x - g) / f32(TEXEL_TILE), 0, f32(across - 1))), int(clamp((lo_f.y - g) / f32(TEXEL_TILE), 0, f32(across - 1)))}
		hi = {int(clamp((hi_f.x + g) / f32(TEXEL_TILE), 0, f32(across - 1))), int(clamp((hi_f.y + g) / f32(TEXEL_TILE), 0, f32(across - 1)))}
		return
	}
	start := make([]int, tiles + 1, context.temp_allocator)
	for t in 0 ..< triangles {
		lo, hi := tile_box(u.corner[t], fs, across)
		for y in lo.y ..= hi.y do for x in lo.x ..= hi.x do start[y * across + x + 1] += 1
	}
	for i in 0 ..< tiles do start[i + 1] += start[i]
	listed := make([]u32, start[tiles], context.temp_allocator)
	fill := make([]int, tiles, context.temp_allocator)
	copy(fill, start[:tiles])
	for t in 0 ..< triangles {
		lo, hi := tile_box(u.corner[t], fs, across)
		for y in lo.y ..= hi.y do for x in lo.x ..= hi.x {
			i := y * across + x
			listed[fill[i]] = u32(t)
			fill[i] += 1
		}
	}
	h := runtime.heap_allocator()
	out := make([]^Texel_Map_Tile, tiles, h)
	Job :: struct {
		u:      uv.Uvs,
		fs:     f32,
		across: int,
		start:  []int,
		listed: []u32,
		out:    []^Texel_Map_Tile,
	}
	job := Job{u, fs, across, start, listed, out}
	jobs.parallel_for(pool, tiles, &job, proc(data: rawptr, i: int) {
		job := cast(^Job)data
		list := job.listed[job.start[i]:job.start[i + 1]]
		if len(list) == 0 do return
		h := runtime.heap_allocator()
		tri := make([]u32, TILE_TEXELS, h)
		bary := make([][2]u16, TILE_TEXELS, h)
		for &v in tri do v = TEXEL_NONE
		x0, y0 := f32((i % job.across) * TEXEL_TILE), f32((i / job.across) * TEXEL_TILE)
		covered := false
		for t in list {
			c := job.u.corner[t]
			p: [3][2]f32
			for k in 0 ..< 3 do p[k] = {c[k].x * job.fs - x0, (1 - c[k].y) * job.fs - y0}
			area := (p[1].x - p[0].x) * (p[2].y - p[0].y) - (p[2].x - p[0].x) * (p[1].y - p[0].y)
			if area == 0 do continue
			lo := [2]int{int(max(min(p[0].x, p[1].x, p[2].x) - 0.5, 0)), int(max(min(p[0].y, p[1].y, p[2].y) - 0.5, 0))}
			hi := [2]int{min(int(max(p[0].x, p[1].x, p[2].x) + 0.5), TEXEL_TILE - 1), min(int(max(p[0].y, p[1].y, p[2].y) + 0.5), TEXEL_TILE - 1)}
			for y in lo.y ..= hi.y do for x in lo.x ..= hi.x {
				k := y * TEXEL_TILE + x
				if tri[k] != TEXEL_NONE do continue
				q := [2]f32{f32(x) + 0.5, f32(y) + 0.5}
				b1 := ((q.x - p[0].x) * (p[2].y - p[0].y) - (p[2].x - p[0].x) * (q.y - p[0].y)) / area
				b2 := ((p[1].x - p[0].x) * (q.y - p[0].y) - (q.x - p[0].x) * (p[1].y - p[0].y)) / area
				if b1 < 0 || b2 < 0 || b1 + b2 > 1 do continue
				tri[k] = t
				bary[k] = {u16(b1 * 65535 + 0.5), u16(b2 * 65535 + 0.5)}
				covered = true
			}
		}
		if !covered {
			delete(tri, h)
			delete(bary, h)
			return
		}
		m := new(Texel_Map_Tile, h)
		m.tri, m.bary = tri, bary
		job.out[i] = m
	})
	texel_map_gutter(out, across, pool)
	return out
}

// Gives the texels around the islands (TEXEL_GUTTER deep, across tiles too) the nearest
// covered texel's place. Each tile finds its gutter from the covered texels alone, then
// every tile takes its own, so no job reads what another writes.
@(private = "file")
texel_map_gutter :: proc(tiles: []^Texel_Map_Tile, across: int, pool: ^jobs.Pool) {
	Found :: struct {
		at:   u16,
		tri:  u32,
		bary: [2]u16,
	}
	Job :: struct {
		tiles:  []^Texel_Map_Tile,
		across: int,
		found:  [][dynamic]Found,
	}
	job := Job{tiles, across, make([][dynamic]Found, len(tiles), context.temp_allocator)}
	jobs.parallel_for(pool, len(tiles), &job, proc(data: rawptr, i: int) {
		job := cast(^Job)data
		across := job.across
		tx, ty := i % across, i / across
		// A tile with nothing near it has no gutter.
		near := false
		for dy in -1 ..= 1 do for dx in -1 ..= 1 {
			x, y := tx + dx, ty + dy
			if x >= 0 && y >= 0 && x < across && y < across && job.tiles[y * across + x] != nil do near = true
		}
		if !near do return
		h := runtime.heap_allocator()
		own := job.tiles[i]
		for k in 0 ..< TILE_TEXELS {
			if own != nil && own.tri[k] != TEXEL_NONE do continue
			gx, gy := tx * TEXEL_TILE + k % TEXEL_TILE, ty * TEXEL_TILE + k / TEXEL_TILE
			best := Found{tri = TEXEL_NONE}
			best_d := max(int)
			for dy in -TEXEL_GUTTER ..= TEXEL_GUTTER do for dx in -TEXEL_GUTTER ..= TEXEL_GUTTER {
				x, y := gx + dx, gy + dy
				if x < 0 || y < 0 || x >= across * TEXEL_TILE || y >= across * TEXEL_TILE do continue
				m := job.tiles[(y / TEXEL_TILE) * across + x / TEXEL_TILE]
				if m == nil do continue
				j := (y % TEXEL_TILE) * TEXEL_TILE + x % TEXEL_TILE
				t := m.tri[j]
				if t == TEXEL_NONE do continue
				d := dx * dx + dy * dy
				if d < best_d || (d == best_d && t < best.tri) {
					best_d, best = d, Found{u16(k), t, m.bary[j]}
				}
			}
			if best.tri == TEXEL_NONE do continue
			if job.found[i] == nil do job.found[i] = make([dynamic]Found, h)
			append(&job.found[i], best)
		}
	})
	h := runtime.heap_allocator()
	for &found, i in job.found {
		if len(found) == 0 {
			delete(found)
			continue
		}
		m := tiles[i]
		if m == nil {
			m = new(Texel_Map_Tile, h)
			m.tri = make([]u32, TILE_TEXELS, h)
			m.bary = make([][2]u16, TILE_TEXELS, h)
			for &v in m.tri do v = TEXEL_NONE
			tiles[i] = m
		}
		for f in found do m.tri[f.at], m.bary[f.at] = f.tri, f.bary
		delete(found)
	}
}

// Where texel `k` of map tile `m` lies on the current level, or false outside every island.
levels_texel_position :: proc(l: ^Levels, m: ^Texel_Map_Tile, k: int) -> (p: Vec3, ok: bool) {
	t := m.tri[k]
	if t == TEXEL_NONE do return
	lv := levels_current(l)
	idx := lv.mesh.indices[3 * t:][:3]
	b := [2]f32{f32(m.bary[k].x), f32(m.bary[k].y)} * (1.0 / 65535)
	pos := lv.mesh.positions[:]
	return pos[idx[0]] * (1 - b.x - b.y) + pos[idx[1]] * b.x + pos[idx[2]] * b.y, true
}

// Tiles a texture stroke or command changed, as they were before it: undoing or redoing
// swaps them with the live ones, so the step is its own inverse. Kept by the app's History
// (a texture layer belongs to the object, not to a level's sculptor).
Texel_Saved :: struct {
	index: u32,
	tile:  ^Texel_Tile, // nil: the tile was unpainted
}

Texel_Step :: struct {
	layer: u32,
	saved: [dynamic]Texel_Saved,
	seen:  []bool, // per tile: saved already
}

// Saves tile `index` of `layer` into `step` the first time a step writes it (copy on
// write). Serial: called before the jobs that write the tiles.
@(private = "file")
texel_step_save :: proc(step: ^Texel_Step, layer: ^Texel_Layer, index: int) {
	if step == nil do return
	h := runtime.heap_allocator()
	if step.seen == nil {
		step.seen = make([]bool, len(layer.tiles), h)
		step.saved = make([dynamic]Texel_Saved, h)
		step.layer = layer.id
	}
	if step.seen[index] do return
	step.seen[index] = true
	append(&step.saved, Texel_Saved{u32(index), tile_clone(layer.tiles[index])})
}

// Swaps a step's tiles with the live ones: undo and redo alike. A step whose layer is gone
// changes nothing.
levels_texel_step_swap :: proc(l: ^Levels, step: ^Texel_Step) {
	t := &l.texels
	layer := texels_layer(t, step.layer)
	if layer == nil do return
	for &s in step.saved {
		layer.tiles[s.index], s.tile = s.tile, layer.tiles[s.index]
		texels_touch(t, s.index)
	}
}

texel_step_bytes :: proc(step: ^Texel_Step) -> (n: int) {
	for s in step.saved do n += tile_bytes(s.tile)
	return n + len(step.seen)
}

texel_step_free :: proc(step: ^Texel_Step) {
	h := runtime.heap_allocator()
	for s in step.saved do tile_free(s.tile)
	delete(step.saved)
	delete(step.seen, h)
	step^ = {}
}

// The picked stack row's texture layer and what its strokes write, or nil when the picked
// layer is on the vertices.
levels_texel_picked :: proc(l: ^Levels) -> (layer: ^Texel_Layer, writes: Paint_Channels) {
	s := &levels_current(l).sculptor
	i := sculptor_paint_picked(s)
	if i < 0 || s.paint.list[i].texels == 0 do return
	return texels_layer(&l.texels, s.paint.list[i].texels), s.paint.list[i].channels
}

// Fills every texel of the picked texture layer that lies on the surface (its islands and
// their gutter) with `color` and `material` (roughness, metal), in the channels the layer
// writes, or clears those channels; the tiles it changes are saved into `step` first.
// Returns true when it changed a tile. Gradient is the vertices' alone (false).
levels_texel_command :: proc(l: ^Levels, command: Paint_Command, color: [3]u8, material: [2]u8, step: ^Texel_Step) -> bool {
	layer, writes := levels_texel_picked(l)
	s := &levels_current(l).sculptor
	_ = sculptor_stroke_end(s)
	if layer == nil || s.dyn != nil || command == .Gradient || !levels_texel_map(l) do return false
	m := &l.texels.tex_map
	touched := make([dynamic]int, 0, len(layer.tiles), context.temp_allocator)
	for tile, i in m.tiles {
		if tile == nil do continue
		if command == .Clear && layer.tiles[i] == nil do continue
		texel_step_save(step, layer, i)
		append(&touched, i)
	}
	if len(touched) == 0 do return false
	Job :: struct {
		layer:    ^Texel_Layer,
		m:        ^Texel_Map,
		touched:  []int,
		clear:    bool,
		writes:   Paint_Channels,
		color:    Color,
		material: [2]u8,
	}
	job := Job{layer, m, touched[:], command == .Clear, writes, {color.r, color.g, color.b, 255}, material}
	jobs.parallel_for(l.pool, len(touched), &job, proc(data: rawptr, j: int) {
		job := cast(^Job)data
		i := job.touched[j]
		tile := job.layer.tiles[i]
		if job.clear {
			if .Color in job.writes {
				delete(tile.color, runtime.heap_allocator())
				tile.color = nil
			}
			if job.writes & {.Roughness, .Metal} == {.Roughness, .Metal} {
				delete(tile.material, runtime.heap_allocator())
				tile.material = nil
			} else if tile.material != nil {
				c := 0 if .Roughness in job.writes else 1
				if job.writes & {.Roughness, .Metal} != {} do for &v in tile.material do v[2 * c], v[2 * c + 1] = 0, 0
			}
			if tile.color == nil && tile.material == nil {
				tile_free(tile)
				job.layer.tiles[i] = nil
			}
			return
		}
		h := runtime.heap_allocator()
		if tile == nil {
			tile = tile_new(false, false)
			job.layer.tiles[i] = tile
		}
		if .Color in job.writes && tile.color == nil do tile.color = make([]Color, TILE_TEXELS, h)
		if job.writes & {.Roughness, .Metal} != {} && tile.material == nil do tile.material = make([]Material_Paint, TILE_TEXELS, h)
		on := job.m.tiles[i].tri
		for k in 0 ..< TILE_TEXELS {
			if on[k] == TEXEL_NONE do continue
			if .Color in job.writes do tile.color[k] = job.color
			if .Roughness in job.writes do tile.material[k][0], tile.material[k][1] = job.material[0], 255
			if .Metal in job.writes do tile.material[k][2], tile.material[k][3] = job.material[1], 255
		}
	})
	for i in touched do texels_touch(&l.texels, u32(i))
	return true
}
