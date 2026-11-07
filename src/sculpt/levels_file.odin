package sculpt

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import "core:sync"

import "../geom"
import "../jobs"
import "../uv"

// Subdivision levels in and out of the native scene file (the app writes the rest of
// it). Every level is stored as positions, so each reads back exactly as it was shown,
// and the detail tying the levels together is encoded again from them, as a sync does.
// Vertex numbers change whenever a sculptor is built (sculptor_init renumbers), so the
// levels above the base store their vertices in an order only the topology decides:
// the vertices continuing the level below first, in that level's order, then the edge
// vertices ordered by their edge's ends (see level_canon). The base level's own order
// is the one it is written in. Positions go straight between the file's bytes and the
// meshes, without a copy in between, since at 10M vertices that copy is 120 MB. HD detail is not stored, since its storage follows node
// numbers, which differ in every build; the number of HD steps is.

// The levels are a tagged record (geom/record.odin): a reader finds each field by its tag,
// takes a default for one an earlier build did not write and steps over one a later build
// added. Tags are never reused or retyped. A field holding many values is a run of them,
// the count its size.
@(private = "file")
Levels_Tag :: enum u16 {
	Count     = 1,  // u32, required: how many levels
	Current   = 2,  // u32: the level shown
	Hd_Steps  = 3,  // u32: how far HD went (its detail is not stored)
	Dynamic   = 4,  // u8: dynamic topology is on, and the base is stored packed with only its mask
	Positions = 5,  // Vec3 per vertex of the base level, in its own order, required
	Indices   = 6,  // u32 three per triangle of the base level, required
	Layout    = 7,  // Node_Sizes per node (sculptor_layout), so opening skips the partition
	Cc        = 8,  // Cc_Tag record: the Catmull-Clark rule, the base's polygons and creases
	Level     = 9,  // one a level above the base, in order: its positions in file order
	Mask      = 10, // u8 per vertex of the current level, in file order
	Paint     = 11, // Paint_Tag record: the current level's paint layers
	Groups    = 12, // u16 per triangle of the current level, in tri_canon's order
	Layers    = 13, // one a level, in order: a Layers_Tag record
	Quads     = 14, // [4]u32 per quad of the base level
	Uvs       = 15, // Uvs_Tag record: the base level's UVs
	Set       = 16, // one a selection set: a Set_Tag record
	Texels    = 17, // Texels_Tag record: the texture layers the current stack names
}

// The Catmull-Clark rule and the base level's polygons (levels_cc.odin), in its own order.
@(private = "file")
Cc_Tag :: enum u16 {
	Rule        = 1, // u8 Subdivision_Rule, required
	First       = 2, // u32 per polygon plus one: where its corners start
	Corners     = 3, // u32 per corner
	Tri_Poly    = 4, // u32 per triangle: its polygon
	Sharp_Edges = 5, // u64 per creased edge: its ends (sharp_key)
	Sharp_Edge  = 6, // f32 per creased edge
	Sharp_Verts = 7, // u32 per creased vertex
	Sharp_Vert  = 8, // f32 per creased vertex
}

@(private = "file")
Paint_Tag :: enum u16 {
	Picked  = 1, // u32: the picked layer's index plus one, 0 for none
	Next_Id = 2, // u32
	Named   = 3, // u32: how many layers were named
	Layer   = 4, // one a layer, bottom first: a Paint_Layer_Tag record
}

@(private = "file")
Paint_Layer_Tag :: enum u16 {
	Name      = 1, // text, under 32 bytes
	Id        = 2, // u32, required
	Visible   = 3, // u8
	Opacity   = 4, // f32
	Channels  = 5, // u8 Paint_Channels
	Texels    = 6, // u32: its texture layer's id, 0 on the vertices
	Colors    = 7, // Color per vertex, in file order
	Materials = 8, // Color per vertex (roughness and metal), in file order
}

// A level's sculpt layers.
@(private = "file")
Layers_Tag :: enum u16 {
	Recording = 1, // u32: the recording layer's index plus one, 0 for none
	Layer     = 2, // one a layer, bottom first: a Layer_Tag record
}

@(private = "file")
Layer_Tag :: enum u16 {
	Name     = 1, // text, under 32 bytes
	Strength = 2, // f32
	Visible  = 3, // u8
	Delta    = 4, // Vec3 per vertex in file order, zero where it moved nothing; none moved nothing at all
	Mask     = 5, // u8 per vertex in file order (layer_masks.odin)
}

@(private = "file")
Uvs_Tag :: enum u16 {
	Corner  = 1, // [3][2]f32 per triangle of the base level
	Seam    = 2, // uv.Seams per triangle
	Island  = 3, // u32 per triangle
	Islands = 4, // u32: how many islands
	Filled  = 5, // f32: the share of the square filled
	Pins    = 6, // u32 per pinned vertex, ascending
}

@(private = "file")
Set_Tag :: enum u16 {
	Name   = 1, // text, under 32 bytes
	Level  = 2, // u32
	Masked = 3, // f32: the mean mask
	Runs   = 4, // u8: the data is runs (set_encode)
	Data   = 5, // the values in the level's file order, packed
}

@(private = "file")
Texels_Tag :: enum u16 {
	Side    = 1, // u32: the texture layers' size, 0 with none
	Next_Id = 2, // u32
	Layer   = 3, // one a layer: a Texel_Layer_Tag record
}

@(private = "file")
Texel_Layer_Tag :: enum u16 {
	Id   = 1, // u32, required
	Tile = 2, // one a painted tile: a Tile_Tag record
}

@(private = "file")
Tile_Tag :: enum u16 {
	Index    = 1, // u32, required
	Color    = 2, // TILE_TEXELS colours, in rows from the top
	Material = 3, // TILE_TEXELS Material_Paint
	Height   = 4, // TILE_TEXELS Height_Paint
}

// How levels_write runs. A save from the frame loop takes the defaults. The autosave
// thread writes serially, since the pool takes jobs from the frame loop alone, and
// stops between pieces once the frame loop needs the scene back.
Write_Options :: struct {
	serial:  bool,  // every loop on the calling thread, never through the levels' pool
	abort:   ^bool, // read atomically between pieces: once set, levels_write stops and returns false
	synced:  bool,  // the caller ran levels_sync and nothing changed since, so the levels are only read
	hd_open: bool,  // an HD window may be open: its detail is never stored, so the bytes are the ones leaving it gives
}

// What the autosave thread copies between two looks at its abort flag: about a
// millisecond on a desktop, longer while fresh pages fault in.
@(private = "file")
PIECE_BYTES :: 1 << 20

@(private = "file")
Writer :: struct {
	out:   ^[dynamic]u8,
	pool:  ^jobs.Pool, // nil: on this thread
	abort: ^bool,
}

@(private = "file")
stopped :: #force_inline proc(abort: ^bool) -> bool {return abort != nil && sync.atomic_load(abort)}

// Appends `bytes`, in pieces when it can be stopped. False once it was.
@(private = "file")
put_checked :: proc(w: ^Writer, bytes: []u8) -> bool {
	if w.abort == nil {
		append(w.out, ..bytes)
		return true
	}
	for at := 0; at < len(bytes); at += PIECE_BYTES {
		if stopped(w.abort) do return false
		append(w.out, ..bytes[at:min(at + PIECE_BYTES, len(bytes))])
	}
	return true
}

// Runs `fn` over 0 ..< count in ranges of `grain`: through `pool`, or on this thread
// looking at `abort` between ranges. False once it was set.
@(private)
ranges :: proc(pool: ^jobs.Pool, abort: ^bool, count: int, data: rawptr, fn: jobs.Range_Proc, grain: int) -> bool {
	if pool != nil {
		jobs.parallel_ranges(pool, count, data, fn, grain)
		return !stopped(abort)
	}
	for lo := 0; lo < count; lo += grain {
		if stopped(abort) do return false
		fn(data, lo, min(lo + grain, count))
	}
	return !stopped(abort)
}

// Appends a field of `bytes`, in pieces when it can be stopped. False once it was.
@(private = "file")
put_field :: proc(w: ^Writer, tag: $E, bytes: []u8) -> bool {
	at := geom.rec_begin(w.out, tag)
	ok := put_checked(w, bytes)
	geom.rec_end(w.out, at)
	return ok
}

// A zero-terminated name as a text field.
@(private = "file")
name_put :: proc(out: ^[dynamic]u8, tag: $E, name: [32]u8) {
	name := name
	n := 0
	for n < len(name) - 1 && name[n] != 0 do n += 1
	geom.rec_put_string(out, tag, string(name[:n]))
}

// Reads a name name_put wrote into `dst`, zero-terminated; a missing one is empty. A name
// too long for it, or holding a zero, is damage.
@(private = "file")
name_get :: proc(rec: ^geom.Record, tag: $E, dst: ^[32]u8) {
	payload, _ := geom.rec_find(rec, tag)
	if len(payload) >= len(dst) {
		rec.ok = false
		return
	}
	for b in payload do if b == 0 do rec.ok = false
	dst^ = {}
	copy(dst[:], payload)
}

// Appends the levels to `out` as a record (Levels_Tag): every level in sync with the
// current one, its mask, and whether dynamic topology is on (a dynamic mesh is stored
// packed). Leave any HD window first, unless `opts` says otherwise. False only when
// `opts.abort` stopped it, with `out` then holding part of it.
levels_write :: proc(l: ^Levels, out: ^[dynamic]u8, opts := Write_Options{}) -> bool {
	assert(opts.hd_open || l.hd.window == nil, "leave the HD window first")
	if !opts.synced do levels_sync(l)
	w := Writer{out, nil if opts.serial else l.pool, opts.abort}
	at := geom.record_begin(out)
	ok := write_fields(&w, l)
	geom.record_end(out, at)
	return ok
}

@(private = "file")
write_fields :: proc(w: ^Writer, l: ^Levels) -> bool {
	out := w.out
	geom.rec_put(out, Levels_Tag.Count, u32(len(l.levels)))
	geom.rec_put(out, Levels_Tag.Current, u32(l.current))
	geom.rec_put(out, Levels_Tag.Hd_Steps, u32(l.hd.steps))
	base := l.levels[0]
	if levels_dynamic(l) {
		geom.rec_put(out, Levels_Tag.Dynamic, u8(1))
		packed, mask := compact_mesh(&base.sculptor, w.pool, false, w.abort)
		defer geom.mesh_destroy(&packed)
		defer delete(mask)
		return !stopped(w.abort) && write_mesh(w, packed) && write_mask(w, Levels_Tag.Mask, mask, nil)
	}
	if !write_mesh(w, base.mesh) do return false
	layout := sculptor_layout(&base.sculptor, context.temp_allocator)
	if !put_field(w, Levels_Tag.Layout, slice.to_bytes(layout)) do return false
	if l.rule != .Loop && base.polys.first != nil {
		p, sh := &base.polys, &base.sharp
		at := geom.rec_begin(out, Levels_Tag.Cc)
		geom.rec_put(out, Cc_Tag.Rule, u8(l.rule))
		ok :=
			put_field(w, Cc_Tag.First, slice.to_bytes(p.first)) &&
			put_field(w, Cc_Tag.Corners, slice.to_bytes(p.corners)) &&
			put_field(w, Cc_Tag.Tri_Poly, slice.to_bytes(p.tri_poly)) &&
			put_field(w, Cc_Tag.Sharp_Edges, slice.to_bytes(sh.edges)) &&
			put_field(w, Cc_Tag.Sharp_Edge, slice.to_bytes(sh.edge)) &&
			put_field(w, Cc_Tag.Sharp_Verts, slice.to_bytes(sh.verts)) &&
			put_field(w, Cc_Tag.Sharp_Vert, slice.to_bytes(sh.vert))
		geom.rec_end(out, at)
		if !ok do return false
	}
	canon: [MAX_LEVELS][]u32 // level 0's is its own order
	for j in 1 ..< len(l.levels) {
		lv := l.levels[j]
		canon[j] = level_canon(l, j, canon[j - 1], w.pool, w.abort, context.temp_allocator)
		if canon[j] == nil do return false
		n := len(lv.mesh.positions)
		Scatter :: struct {
			from:  []Vec3,
			to:    []u8,
			canon: []u32,
		}
		at := geom.rec_begin(out, Levels_Tag.Level)
		sc := Scatter{lv.mesh.positions[:], geom.byte_put_bytes(out, n * size_of(Vec3)), canon[j]}
		geom.rec_end(out, at)
		ranged := ranges(w.pool, w.abort, n, &sc, proc(data: rawptr, lo, hi: int) {
			sc := cast(^Scatter)data
			for u in lo ..< hi do intrinsics.unaligned_store(cast(^Vec3)&sc.to[size_of(Vec3) * int(sc.canon[u])], sc.from[u])
		}, geom.RANGE_GRAIN)
		if !ranged do return false
	}
	s := &levels_current(l).sculptor
	if !write_mask(w, Levels_Tag.Mask, sculptor_sculpt_mask(s), canon[l.current]) do return false
	if !write_paint(w, s, canon[l.current]) do return false
	if s.groups.tris != nil {
		order := tri_canon(s, canon[l.current], w.abort)
		if order == nil do return false
		Groups :: struct {
			from:  []u16,
			to:    []u16,
			order: []u32,
		}
		at := geom.rec_begin(out, Levels_Tag.Groups)
		g := Groups{s.groups.tris, slice.reinterpret([]u16, geom.byte_put_bytes(out, len(s.groups.tris) * size_of(u16))), order}
		geom.rec_end(out, at)
		ranged := ranges(w.pool, w.abort, len(s.groups.tris), &g, proc(data: rawptr, lo, hi: int) {
			g := cast(^Groups)data
			for t in lo ..< hi do g.to[g.order[t]] = g.from[t]
		}, geom.RANGE_GRAIN)
		if !ranged do return false
	}
	for lv, j in l.levels do if !write_layers(w, &lv.sculptor, canon[j]) do return false
	// The base level's vertices are in the file in their own order.
	if len(l.faces.quads) > 0 && !put_field(w, Levels_Tag.Quads, slice.to_bytes(l.faces.quads)) do return false
	// So are its triangles, which the UVs follow.
	u := l.uvs
	if uv.has(u) {
		at := geom.rec_begin(out, Levels_Tag.Uvs)
		ok :=
			put_field(w, Uvs_Tag.Corner, slice.to_bytes(u.corner)) &&
			put_field(w, Uvs_Tag.Seam, slice.to_bytes(u.seam)) &&
			put_field(w, Uvs_Tag.Island, slice.to_bytes(u.island))
		geom.rec_put(out, Uvs_Tag.Islands, u32(u.islands))
		geom.rec_put(out, Uvs_Tag.Filled, u.filled)
		ok = ok && put_field(w, Uvs_Tag.Pins, slice.to_bytes(u.pins))
		geom.rec_end(out, at)
		if !ok do return false
	}
	return write_sets(w, l, canon[:]) && write_texels(w, l) && !stopped(w.abort)
}

// The texture layers the current stack has rows for: their size, the next id, then per
// layer its id and painted tiles, each its index and those of its channels it has (colour,
// roughness and metal, height) in rows from the top. Layers an undo step holds are not
// undo's to keep across a save.
@(private = "file")
write_texels :: proc(w: ^Writer, l: ^Levels) -> bool {
	out := w.out
	t := &l.texels
	s := &levels_current(l).sculptor
	named := make([dynamic]^Texel_Layer, 0, len(t.layers), context.temp_allocator)
	for row in s.paint.list do if layer := texels_layer(t, row.texels); layer != nil do append(&named, layer)
	at := geom.rec_begin(out, Levels_Tag.Texels)
	defer geom.rec_end(out, at)
	geom.rec_put(out, Texels_Tag.Side, u32(t.side if len(named) > 0 else 0))
	geom.rec_put(out, Texels_Tag.Next_Id, t.next_id)
	for layer in named {
		la := geom.rec_begin(out, Texels_Tag.Layer)
		defer geom.rec_end(out, la)
		geom.rec_put(out, Texel_Layer_Tag.Id, layer.id)
		for tile, i in layer.tiles {
			if tile == nil do continue
			ta := geom.rec_begin(out, Texel_Layer_Tag.Tile)
			defer geom.rec_end(out, ta)
			geom.rec_put(out, Tile_Tag.Index, u32(i))
			if tile.color != nil && !put_field(w, Tile_Tag.Color, slice.to_bytes(tile.color)) do return false
			if tile.material != nil && !put_field(w, Tile_Tag.Material, slice.to_bytes(tile.material)) do return false
			if tile.height != nil && !put_field(w, Tile_Tag.Height, slice.to_bytes(tile.height)) do return false
		}
	}
	return true
}

// The selection sets, a field each: its name, level, mean mask and its values in that
// level's file order, packed again (as runs when smaller). Serial, since a set is a byte a
// vertex at most, looking at the abort flag between ranges of the scatter. Two buffers of
// the largest level serve every set, and each packed copy is freed once written, so the
// autosave thread holds about three bytes a vertex for them, not more with each set.
@(private = "file")
write_sets :: proc(w: ^Writer, l: ^Levels, canon: []([]u32)) -> bool {
	out := w.out
	if len(l.sets) == 0 do return true
	largest := 0
	for set in l.sets do largest = max(largest, set.vertices)
	values := make([]u8, largest, context.temp_allocator)
	ordered := make([]u8, largest, context.temp_allocator)
	for &set in l.sets {
		if stopped(w.abort) do return false
		ok := set_decode(set.data, set.runs, values[:set.vertices])
		assert(ok, "a selection set is damaged")
		Scatter :: struct {
			from, to: []u8,
			canon:    []u32,
		}
		sc := Scatter{values[:set.vertices], ordered[:set.vertices], canon[set.level]}
		ranged := ranges(nil, w.abort, set.vertices, &sc, proc(data: rawptr, lo, hi: int) {
			sc := cast(^Scatter)data
			for u in lo ..< hi do sc.to[place(sc.canon, u32(u))] = sc.from[u]
		}, geom.RANGE_GRAIN)
		if !ranged do return false
		data, runs := set_encode(ordered[:set.vertices], runtime.heap_allocator())
		defer delete(data, runtime.heap_allocator())
		at := geom.rec_begin(out, Levels_Tag.Set)
		name_put(out, Set_Tag.Name, set.name)
		geom.rec_put(out, Set_Tag.Level, u32(set.level))
		geom.rec_put(out, Set_Tag.Masked, set.masked)
		geom.rec_put(out, Set_Tag.Runs, u8(runs))
		written := put_field(w, Set_Tag.Data, data)
		geom.rec_end(out, at)
		if !written do return false
	}
	return true
}

// A sculptor's paint layers (paint_layers.odin): the picked one, the next id and how many
// were named; then a field a layer with its name, id, eye, opacity and channel dots, its
// texture layer's id (0 on the vertices), and its colours and its roughness and metal per
// vertex in file order where it has them.
@(private = "file")
write_paint :: proc(w: ^Writer, s: ^Sculptor, canon: []u32) -> bool {
	out := w.out
	p := &s.paint
	at := geom.rec_begin(out, Levels_Tag.Paint)
	defer geom.rec_end(out, at)
	geom.rec_put(out, Paint_Tag.Picked, u32(sculptor_paint_picked(s) + 1))
	geom.rec_put(out, Paint_Tag.Next_Id, p.next_id)
	geom.rec_put(out, Paint_Tag.Named, u32(p.named))
	for l, i in p.list {
		la := geom.rec_begin(out, Paint_Tag.Layer)
		defer geom.rec_end(out, la)
		name_put(out, Paint_Layer_Tag.Name, l.name)
		geom.rec_put(out, Paint_Layer_Tag.Id, l.id)
		geom.rec_put(out, Paint_Layer_Tag.Visible, u8(l.visible))
		geom.rec_put(out, Paint_Layer_Tag.Opacity, l.opacity)
		geom.rec_put(out, Paint_Layer_Tag.Channels, transmute(u8)l.channels)
		geom.rec_put(out, Paint_Layer_Tag.Texels, l.texels)
		tags := [2]Paint_Layer_Tag{.Colors, .Materials}
		for values, k in ([2][]Color{sculptor_paint_layer_colors(s, i), sculptor_paint_layer_materials(s, i)}) {
			if values == nil do continue
			Values :: struct {
				from:  []Color,
				to:    []Color,
				canon: []u32,
			}
			va := geom.rec_begin(out, tags[k])
			c := Values{values, slice.reinterpret([]Color, geom.byte_put_bytes(out, len(values) * size_of(Color))), canon}
			geom.rec_end(out, va)
			ranged := ranges(w.pool, w.abort, len(values), &c, proc(data: rawptr, lo, hi: int) {
				c := cast(^Values)data
				for u in lo ..< hi do c.to[place(c.canon, u32(u))] = c.from[u]
			}, geom.RANGE_GRAIN)
			if !ranged do return false
		}
	}
	return true
}

// A sculptor's layers, a field a level: which records, then a field a layer with its name,
// strength, visibility, every vertex's displacement in file order (zero where the layer
// moved nothing) and its mask.
@(private = "file")
write_layers :: proc(w: ^Writer, s: ^Sculptor, canon: []u32) -> bool {
	out := w.out
	at := geom.rec_begin(out, Levels_Tag.Layers)
	defer geom.rec_end(out, at)
	geom.rec_put(out, Layers_Tag.Recording, u32(s.layers.recording))
	for l, k in s.layers.list {
		la := geom.rec_begin(out, Layers_Tag.Layer)
		defer geom.rec_end(out, la)
		name_put(out, Layer_Tag.Name, l.name)
		geom.rec_put(out, Layer_Tag.Strength, l.strength)
		geom.rec_put(out, Layer_Tag.Visible, u8(l.visible))
		Scatter :: struct {
			s:     ^Sculptor,
			delta: [][]Vec3,
			to:    []u8,
			canon: []u32,
		}
		da := geom.rec_begin(out, Layer_Tag.Delta)
		sc := Scatter{s, l.delta, geom.byte_put_bytes(out, len(s.mesh.positions) * size_of(Vec3)), canon}
		geom.rec_end(out, da)
		ranged := ranges(w.pool, w.abort, len(s.nodes), &sc, proc(data: rawptr, lo, hi: int) {
			sc := cast(^Scatter)data
			for id in lo ..< hi {
				n := sc.s.nodes[id]
				d := sc.delta[id]
				for v in n.vert_first ..< n.vert_first + n.vert_count {
					at := cast(^Vec3)&sc.to[size_of(Vec3) * int(place(sc.canon, v))]
					intrinsics.unaligned_store(at, d[v - n.vert_first] if d != nil else Vec3{})
				}
			}
		}, NODE_GRAIN)
		if !ranged do return false
		if !write_mask(w, Layer_Tag.Mask, layer_mask_of(s, k), canon) do return false
	}
	return true
}

@(private = "file")
write_mesh :: proc(w: ^Writer, m: geom.Mesh) -> bool {
	return put_field(w, Levels_Tag.Positions, slice.to_bytes(m.positions[:])) && put_field(w, Levels_Tag.Indices, slice.to_bytes(m.indices[:]))
}

// The mask as a field of `tag` in the file's vertex order (`canon`, or the mesh's own when
// nil); no field when there is none.
@(private = "file")
write_mask :: proc(w: ^Writer, tag: $E, mask: []u8, canon: []u32) -> bool {
	if mask == nil do return true
	if canon == nil do return put_field(w, tag, mask)
	Scatter :: struct {
		from, to: []u8,
		canon:    []u32,
	}
	at := geom.rec_begin(w.out, tag)
	sc := Scatter{mask, geom.byte_put_bytes(w.out, len(mask)), canon}
	geom.rec_end(w.out, at)
	return ranges(w.pool, w.abort, len(mask), &sc, proc(data: rawptr, lo, hi: int) {
		sc := cast(^Scatter)data
		for u in lo ..< hi do sc.to[sc.canon[u]] = sc.from[u]
	}, geom.RANGE_GRAIN)
}

// Reads what write_texels wrote into levels without texture layers. False on a damaged
// file: a size not one of the bake's, an id twice or past the next, a tile out of range or
// twice, a tile with no channel or one of the wrong size.
@(private = "file")
read_texels :: proc(rec: ^geom.Record, l: ^Levels) -> bool {
	t := &l.texels
	side := int(geom.rec_get(rec, Texels_Tag.Side, u32, 0))
	next_id := geom.rec_get(rec, Texels_Tag.Next_Id, u32, 0)
	count := geom.rec_count(rec, Texels_Tag.Layer)
	if !rec.ok || count > MAX_PAINT_LAYERS || (count > 0) != (side != 0) || (side != 0 && !texel_side_ok(side)) do return false
	t.side, t.next_id = side, next_id
	across := texel_tiles_across(side)
	h := runtime.heap_allocator()
	at := 0
	for _ in 0 ..< count {
		payload, _ := geom.rec_next(rec, Texels_Tag.Layer, &at)
		lr := geom.record_of(payload)
		id := geom.rec_need(&lr, Texel_Layer_Tag.Id, u32)
		painted := geom.rec_count(&lr, Texel_Layer_Tag.Tile)
		if !lr.ok || id == 0 || id > next_id || texels_layer(t, id) != nil || painted > across * across do return false
		// In the store before its tiles, so a damaged file frees what was read with it.
		append(&t.layers, Texel_Layer{id = id, tiles = make([]^Texel_Tile, across * across, h)})
		layer := &t.layers[len(t.layers) - 1]
		tile_at := 0
		for _ in 0 ..< painted {
			tile_bytes, _ := geom.rec_next(&lr, Texel_Layer_Tag.Tile, &tile_at)
			tr := geom.record_of(tile_bytes)
			index := int(geom.rec_need(&tr, Tile_Tag.Index, u32))
			if !tr.ok || index >= len(layer.tiles) || layer.tiles[index] != nil do return false
			tile := new(Texel_Tile, h)
			layer.tiles[index] = tile
			if geom.rec_has(&tr, Tile_Tag.Color) {
				tile.color = make([]Color, TILE_TEXELS, h)
				geom.rec_get_into(&tr, Tile_Tag.Color, tile.color)
			}
			if geom.rec_has(&tr, Tile_Tag.Material) {
				tile.material = make([]Material_Paint, TILE_TEXELS, h)
				geom.rec_get_into(&tr, Tile_Tag.Material, tile.material)
			}
			if geom.rec_has(&tr, Tile_Tag.Height) {
				tile.height = make([]Height_Paint, TILE_TEXELS, h)
				geom.rec_get_into(&tr, Tile_Tag.Height, tile.height)
			}
			if !tr.ok || (tile.color == nil && tile.material == nil && tile.height == nil) do return false
		}
	}
	// Every texture row of the stack names a layer read here, and no two rows the same.
	s := &levels_current(l).sculptor
	for row, i in s.paint.list {
		if row.texels == 0 do continue
		if texels_layer(t, row.texels) == nil do return false
		for other in s.paint.list[i + 1:] do if other.texels == row.texels do return false
	}
	t.whole = true
	return true
}

// Reads the selection sets write_sets wrote, once the levels are built and `canon` gives
// each vertex's place in the file. False on a damaged file: too many sets, a level out of
// range, or runs not adding up to the level's vertices.
@(private = "file")
read_sets :: proc(rec: ^geom.Record, l: ^Levels, canon: []([]u32)) -> bool {
	count := geom.rec_count(rec, Levels_Tag.Set)
	if count > MAX_SELECTION_SETS do return false
	// Buffers of the largest level, for every set.
	largest := 0
	for lv in l.levels do largest = max(largest, len(lv.mesh.positions))
	ordered_all := make([]u8, largest if count > 0 else 0, context.temp_allocator)
	values_all := make([]u8, largest if count > 0 else 0, context.temp_allocator)
	at := 0
	for _ in 0 ..< count {
		payload, _ := geom.rec_next(rec, Levels_Tag.Set, &at)
		sr := geom.record_of(payload)
		set: Selection_Set
		name_get(&sr, Set_Tag.Name, &set.name)
		level := int(geom.rec_get(&sr, Set_Tag.Level, u32, 0))
		masked := geom.rec_get(&sr, Set_Tag.Masked, f32, 0)
		runs := geom.rec_get(&sr, Set_Tag.Runs, u8, 0)
		data, has_data := geom.rec_find(&sr, Set_Tag.Data)
		if !sr.ok || !has_data || level >= len(l.levels) || runs > 1 do return false
		n := len(l.levels[level].mesh.positions)
		ordered := ordered_all[:n]
		if !set_decode(data, runs == 1, ordered) do return false
		values := values_all[:n]
		for u in 0 ..< n do values[u] = ordered[place(canon[level], u32(u))]
		l.set_serial += 1
		set.id, set.level, set.vertices = l.set_serial, level, n
		set.masked = masked if masked >= 0 && masked <= 1 else 0 // NaN too
		set.data, set.runs = set_encode(values, l.allocator)
		append(&l.sets, set)
	}
	return true
}

// Reads what write_paint wrote into a sculptor without paint. False on a damaged file.
@(private = "file")
read_paint :: proc(rec: ^geom.Record, s: ^Sculptor, canon: []u32) -> bool {
	picked := geom.rec_get(rec, Paint_Tag.Picked, u32, 0)
	next_id := geom.rec_get(rec, Paint_Tag.Next_Id, u32, 0)
	named := geom.rec_get(rec, Paint_Tag.Named, u32, 0)
	count := geom.rec_count(rec, Paint_Tag.Layer)
	if !rec.ok || count > MAX_PAINT_LAYERS || int(picked) > count do return false
	n := len(s.mesh.positions)
	a := s.history.allocator
	at := 0
	for _ in 0 ..< count {
		payload, _ := geom.rec_next(rec, Paint_Tag.Layer, &at)
		lr := geom.record_of(payload)
		l: Paint_Layer
		name_get(&lr, Paint_Layer_Tag.Name, &l.name)
		l.id = geom.rec_need(&lr, Paint_Layer_Tag.Id, u32)
		visible := geom.rec_get(&lr, Paint_Layer_Tag.Visible, u8, 1)
		l.opacity = geom.rec_get(&lr, Paint_Layer_Tag.Opacity, f32, 1)
		channels := geom.rec_get(&lr, Paint_Layer_Tag.Channels, u8, transmute(u8)Paint_Channels{.Color})
		l.texels = geom.rec_get(&lr, Paint_Layer_Tag.Texels, u32, 0)
		if !lr.ok || visible > 1 || channels & ~transmute(u8)PAINT_CHANNELS_ALL != 0 || (channels & transmute(u8)Paint_Channels{.Height} != 0 && l.texels == 0) || l.id == 0 || l.id > next_id || paint_index(s, l.id) >= 0 || !(l.opacity >= 0 && l.opacity <= 1) do return false
		l.visible = visible == 1
		l.channels = transmute(Paint_Channels)channels
		// In the stack before its arrays, so a damaged file frees what was read with it.
		append(&s.paint.list, l)
		layer := &s.paint.list[len(s.paint.list) - 1]
		for tag in ([2]Paint_Layer_Tag{.Colors, .Materials}) {
			saved, has := geom.rec_find(&lr, tag)
			if !has do continue
			// A texture layer has no colours on the vertices.
			if l.texels != 0 || len(saved) != n * size_of(Color) do return false
			values := make([]Color, n, a)
			for u in 0 ..< n do values[u] = intrinsics.unaligned_load(cast(^Color)&saved[size_of(Color) * int(canon[u])])
			if tag == .Colors do layer.color = values
			else do layer.material = values
		}
	}
	s.paint.next_id, s.paint.named = next_id, int(named)
	if picked > 0 do paint_pick_id(s, s.paint.list[picked - 1].id)
	s.paint.whole = true
	s.paint_stamp += 1
	return true
}

// Reads what write_layers wrote into a sculptor without layers. False on a damaged file.
@(private = "file")
read_layers :: proc(rec: ^geom.Record, s: ^Sculptor, canon: []u32) -> bool {
	recording := int(geom.rec_get(rec, Layers_Tag.Recording, u32, 0))
	count := geom.rec_count(rec, Layers_Tag.Layer)
	if !rec.ok || count > MAX_SCULPT_LAYERS || recording > count do return false
	n := len(s.mesh.positions)
	at := 0
	for _ in 0 ..< count {
		payload, _ := geom.rec_next(rec, Layers_Tag.Layer, &at)
		lr := geom.record_of(payload)
		append(&s.layers.list, Sculpt_Layer{delta = make([][]Vec3, len(s.nodes), s.history.allocator)})
		last := &s.layers.list[len(s.layers.list) - 1]
		name_get(&lr, Layer_Tag.Name, &last.name)
		last.strength = geom.rec_get(&lr, Layer_Tag.Strength, f32, 1)
		visible := geom.rec_get(&lr, Layer_Tag.Visible, u8, 1)
		saved, moved := geom.rec_find(&lr, Layer_Tag.Delta)
		mask, masked := geom.rec_find(&lr, Layer_Tag.Mask)
		if !lr.ok || visible > 1 || (moved && len(saved) != n * size_of(Vec3)) || (masked && len(mask) != n) do return false
		last.visible = visible == 1
		if moved {
			for node, id in s.nodes {
				d: []Vec3
				for v in node.vert_first ..< node.vert_first + node.vert_count {
					x := intrinsics.unaligned_load(cast(^Vec3)&saved[size_of(Vec3) * int(canon[v])])
					if x == {} && d == nil do continue
					if d == nil do d = make([]Vec3, node.vert_count, s.history.allocator)
					d[v - node.vert_first] = x
				}
				last.delta[id] = d
			}
		}
		if masked {
			last.mask = make([]u8, n, s.history.allocator)
			for &x, v in last.mask do x = mask[canon[v]]
		}
	}
	s.layers.recording = recording
	s.layers.named = count
	return true
}

// Reads levels written by levels_write into `l`, which must be empty: the base level,
// then each level above by subdividing and moving its vertices where they were, then
// the detail encoded again, the mask, the HD steps and dynamic topology. Every size is
// checked against what it must hold before anything is built from it, and the base mesh
// is checked sculptable, so a damaged file returns false (leaving `l` empty) rather
// than asserting; so does one holding a critical field (geom.RECORD_TAG_CRITICAL) this
// build does not know.
levels_read :: proc(l: ^Levels, r: ^geom.Byte_Reader, pool: ^jobs.Pool, node_triangles: u32 = NODE_TRIANGLES, allocator := context.allocator) -> bool {
	rec := geom.record_take(r)
	if !rec.ok do return false
	if known, _ := geom.record_known(&rec, Levels_Tag); !known do return false
	count := int(geom.rec_need(&rec, Levels_Tag.Count, u32))
	current := int(geom.rec_get(&rec, Levels_Tag.Current, u32, 0))
	hd_steps := int(geom.rec_get(&rec, Levels_Tag.Hd_Steps, u32, 0))
	packed := geom.rec_get(&rec, Levels_Tag.Dynamic, u8, 0)
	if !geom.rec_once(&rec, Levels_Tag.Count) || count < 1 || count > MAX_LEVELS || current >= count || hd_steps > HD_MAX_STEPS || packed > 1 do return false
	paged := packed == 1
	if paged && (count != 1 || hd_steps > 0) do return false
	if geom.rec_count(&rec, Levels_Tag.Level) != count - 1 do return false
	mesh, mesh_ok := read_mesh(&rec, pool, allocator)
	if !mesh_ok do return false
	// A layout that does not fit the mesh gets the full build.
	layout := geom.rec_get_slice(&rec, Levels_Tag.Layout, Node_Sizes, context.temp_allocator)
	if !rec.ok {
		geom.mesh_destroy(&mesh)
		return false
	}
	if len(layout) == 0 do layout = nil
	file_order := make([]u32, len(mesh.positions), context.temp_allocator)
	tri_from := make([]u32, len(mesh.indices) / 3, context.temp_allocator)
	levels_init(l, mesh, pool, node_triangles, file_order, tri_from, allocator = allocator, layout = layout)
	sculptor_recompute_all(&l.levels[0].sculptor)
	ok := false
	defer if !ok do levels_destroy(l)
	if cc, present := geom.rec_sub(&rec, Levels_Tag.Cc); present && !read_cc(&cc, l, file_order, tri_from) do return false
	if !rec.ok do return false
	// Per level: each vertex's place in the file. Kept outside the temp scratch of
	// each level, which is given back once the level is read.
	canon: [MAX_LEVELS][]u32
	defer for c in canon do delete(c, allocator)
	canon[0] = make([]u32, len(file_order), allocator)
	for internal, i in file_order do canon[0][internal] = u32(i)
	// Each level's scratch (building it and its sculptor) comes from an arena given back
	// after the level, so reading several levels costs the scratch of the largest rather
	// than of all of them.
	scratch: runtime.Arena
	defer runtime.arena_destroy(&scratch)
	level_at := 0
	for j in 1 ..< count {
		context.temp_allocator = runtime.arena_allocator(&scratch)
		defer runtime.arena_free_all(&scratch)
		saved, _ := geom.rec_next(&rec, Levels_Tag.Level, &level_at)
		vertices := len(saved) / size_of(Vec3)
		expected, _, _ := levels_subdivide_estimate(l)
		if len(saved) % size_of(Vec3) != 0 || vertices != expected do return false
		// Its edits are carried by the encoding at the end, not by a sync.
		sculptor_clear_edited(&l.levels[j - 1].sculptor)
		if !levels_subdivide(l) || len(l.levels[j].mesh.positions) != vertices do return false
		lv := l.levels[j]
		canon[j] = level_canon(l, j, canon[j - 1], pool, allocator = allocator)
		Gather :: struct {
			from:  []u8,
			to:    []Vec3,
			canon: []u32,
		}
		g := Gather{saved, lv.mesh.positions[:], canon[j]}
		jobs.parallel_ranges(pool, vertices, &g, proc(data: rawptr, lo, hi: int) {
			g := cast(^Gather)data
			for u in lo ..< hi do g.to[u] = intrinsics.unaligned_load(cast(^Vec3)&g.from[size_of(Vec3) * int(g.canon[u])])
		}, geom.RANGE_GRAIN)
	}
	for j in 1 ..< count {
		lv := l.levels[j]
		all := make([]u32, len(lv.sculptor.nodes), context.temp_allocator)
		for &id, i in all do id = u32(i)
		recode_level(l, j, all, encode = true)
		sculptor_nodes_moved(&lv.sculptor, all)
		_ = sculptor_flush(&lv.sculptor)
	}
	for lv in l.levels do sculptor_clear_edited(&lv.sculptor)
	l.current = current

	s := &levels_current(l).sculptor
	if saved, has_mask := geom.rec_find(&rec, Levels_Tag.Mask); has_mask {
		n := len(s.mesh.positions)
		if len(saved) != n do return false
		mask_ensure(s)
		for u in 0 ..< n do s.mask[u] = saved[canon[current][u]]
	}
	if pr, present := geom.rec_sub(&rec, Levels_Tag.Paint); present && !read_paint(&pr, s, canon[current]) do return false
	if saved, has_groups := geom.rec_find(&rec, Levels_Tag.Groups); has_groups {
		tcount := len(s.mesh.indices) / 3
		if len(saved) != tcount * size_of(u16) do return false
		order := tri_canon(s, canon[current])
		s.groups.tris = make([]u16, tcount, s.history.allocator)
		for t in 0 ..< tcount do s.groups.tris[t] = intrinsics.unaligned_load(cast(^u16)&saved[size_of(u16) * int(order[t])])
		groups_refresh(s)
	}
	// The other levels take them at the first level change.
	s.color_edited, s.groups.edited = len(s.paint.list) > 0, s.groups.tris != nil
	// A field a level, or none for a file with no layers at all.
	if layers := geom.rec_count(&rec, Levels_Tag.Layers); layers > 0 {
		if layers != count do return false
		at := 0
		for lv, j in l.levels {
			payload, _ := geom.rec_next(&rec, Levels_Tag.Layers, &at)
			lr := geom.record_of(payload)
			if !lr.ok || !read_layers(&lr, &lv.sculptor, canon[j]) do return false
		}
	}
	if quads, present := geom.rec_find(&rec, Levels_Tag.Quads); present && !read_quads(quads, l, file_order) do return false
	if ur, present := geom.rec_sub(&rec, Levels_Tag.Uvs); present && !read_uvs(&ur, l, file_order, tri_from) do return false
	if !read_sets(&rec, l, canon[:count]) do return false
	tr, _ := geom.rec_sub(&rec, Levels_Tag.Texels)
	if !rec.ok || !read_texels(&tr, l) do return false
	if hd_steps > 0 && !levels_hd_set_steps(l, hd_steps) do return false
	if paged && !levels_dyn_enable(l) do return false
	ok = rec.ok
	return ok
}

// Per vertex of level j, its place in the file: the vertex of the level below that it
// continues comes first, at that vertex's place (`below`, or the level's own order when
// nil); the vertices on edges follow, ordered by the lower place of their edge's ends,
// then the higher. Only the topology decides this, so the same level built from a
// differently numbered level below gets the same order. Rather than sorting the edges,
// each vertex below counts its neighbours placed after it, which by a running sum over
// the places gives where its edges start; an edge is then as far into those as its end
// vertex's neighbours placed between its two ends.
@(private)
level_canon :: proc(l: ^Levels, j: int, below: []u32, pool: ^jobs.Pool, abort: ^bool = nil, allocator := context.allocator) -> []u32 {
	Canon :: struct {
		lv, under: ^Level,
		below:     []u32,
		start:     []u32, // per place below, plus one: where its edges start
		canon:     []u32,
		// Under a Catmull-Clark rule, the polygons below: a vertex's neighbours are the
		// corners after it in its polygons, and the face points come last, in polygon
		// order, which only the topology decides too.
		polys:     ^Polys,
	}
	// Calls `fn` for each neighbour w of v below: the corner after v in each of its
	// triangles, or in each of its polygons. Each comes once on a closed mesh.
	neighbours :: #force_inline proc(k: ^Canon, v: u32, data: ^u32, pv, pb: u32, fn: proc(k: ^Canon, w: u32, data: ^u32, pv, pb: u32)) {
		tris := geom.vertex_faces_of(k.under.sculptor.faces, v)
		indices := k.under.mesh.indices[:]
		if k.polys == nil {
			for f in tris {
				w, _ := others(indices, f, v)
				fn(k, w, data, pv, pb)
			}
			return
		}
		for f, i in tris {
			g := k.polys.tri_poly[f]
			seen := false
			for e in tris[:i] do if k.polys.tri_poly[e] == g do seen = true
			if seen do continue
			corners := poly_corners(k.polys, g)
			at, _ := slice.linear_search(corners, v)
			fn(k, corners[(at + 1) % len(corners)], data, pv, pb)
		}
	}
	lv, under := l.levels[j], l.levels[j - 1]
	vb := len(under.mesh.positions)
	k := Canon{lv, under, below, make([]u32, vb + 1, context.temp_allocator), make([]u32, len(lv.mesh.positions), allocator), nil}
	if l.rule != .Loop && under.polys.first != nil do k.polys = &under.polys
	ranged := ranges(pool, abort, vb, &k, proc(data: rawptr, lo, hi: int) {
		k := cast(^Canon)data
		for v in u32(lo) ..< u32(hi) {
			pv := place(k.below, v)
			after: u32
			neighbours(k, v, &after, pv, 0, proc(k: ^Canon, w: u32, after: ^u32, pv, _: u32) {after^ += u32(place(k.below, w) > pv)})
			k.start[pv + 1] = after
		}
	}, geom.RANGE_GRAIN)
	if !ranged {
		delete(k.canon, allocator)
		return nil
	}
	for p in 0 ..< vb do k.start[p + 1] += k.start[p]
	ranged = ranges(pool, abort, len(k.canon), &k, proc(data: rawptr, lo, hi: int) {
		k := cast(^Canon)data
		vb := u32(len(k.under.mesh.positions))
		for u in lo ..< hi {
			par := k.lv.parents[u]
			if par[2] == EVEN {
				k.canon[u] = place(k.below, par[0])
				continue
			}
			if par[2] == FACE && k.polys != nil {
				k.canon[u] = vb + k.start[vb] + par[3]
				continue
			}
			a, b := par[0], par[1]
			pa, pb := place(k.below, a), place(k.below, b)
			if pb < pa do a, pa, pb = b, pb, pa
			before: u32
			neighbours(k, a, &before, pa, pb, proc(k: ^Canon, w: u32, before: ^u32, pa, pb: u32) {
				pw := place(k.below, w)
				before^ += u32(pw > pa && pw < pb)
			})
			k.canon[u] = vb + k.start[pa] + before
		}
	}, geom.RANGE_GRAIN)
	if !ranged {
		delete(k.canon, allocator)
		return nil
	}
	return k.canon
}

// Per triangle, its place in the file: triangles in order of their corner placed first
// (`canon` gives places, or the vertices' own numbers when nil), and of those sharing
// it, of the corner after it. On a mesh whose edges each have one triangle running
// them either way, no two triangles share both, so only the topology decides this.
// Temporary.
@(private)
tri_canon :: proc(s: ^Sculptor, canon: []u32, abort: ^bool = nil) -> []u32 {
	indices := s.mesh.indices[:]
	tcount, vcount := len(indices) / 3, len(s.mesh.positions)
	Key :: struct {
		first, next: u32,
	}
	key := make([]Key, tcount, context.temp_allocator)
	start := make([]u32, vcount + 1, context.temp_allocator)
	for t in 0 ..< tcount {
		if t & 0xffff == 0 && stopped(abort) do return nil
		c := [3]u32{place(canon, indices[3 * t]), place(canon, indices[3 * t + 1]), place(canon, indices[3 * t + 2])}
		k := 0
		if c[1] < c[k] do k = 1
		if c[2] < c[k] do k = 2
		key[t] = {c[k], c[(k + 1) % 3]}
		start[c[k] + 1] += 1
	}
	for v in 0 ..< vcount do start[v + 1] += start[v]
	// A counting sort by the first corner, then the few triangles of each first corner by
	// the next.
	sorted := make([]u32, tcount, context.temp_allocator)
	fill := slice.clone(start, context.temp_allocator)
	for k, t in key {
		if t & 0xffff == 0 && stopped(abort) do return nil
		sorted[fill[k.first]] = u32(t)
		fill[k.first] += 1
	}
	for v in 0 ..< vcount {
		if v & 0xffff == 0 && stopped(abort) do return nil
		run := sorted[start[v]:start[v + 1]]
		for i in 1 ..< len(run) {
			for j := i; j > 0 && key[run[j]].next < key[run[j - 1]].next; j -= 1 do run[j], run[j - 1] = run[j - 1], run[j]
		}
	}
	order := make([]u32, tcount, context.temp_allocator)
	for t, i in sorted do order[t] = u32(i)
	return order
}

// A vertex's place in the file: `below` gives it, or the vertex's own number when nil.
@(private = "file")
place :: #force_inline proc(below: []u32, v: u32) -> u32 {return below[v] if below != nil else v}

// The base mesh from its positions and indices; false when either is missing, of a size
// that is no whole number of values, or the mesh is not sculptable.
@(private = "file")
read_mesh :: proc(rec: ^geom.Record, pool: ^jobs.Pool, allocator: runtime.Allocator) -> (m: geom.Mesh, ok: bool) {
	positions, has_positions := geom.rec_find(rec, Levels_Tag.Positions)
	indices, has_indices := geom.rec_find(rec, Levels_Tag.Indices)
	if !has_positions || !has_indices || len(positions) % size_of(Vec3) != 0 || len(indices) % size_of([3]u32) != 0 do return {}, false
	vertices, triangles := len(positions) / size_of(Vec3), len(indices) / size_of([3]u32)
	if vertices < 3 || triangles < 1 do return {}, false
	m.positions = make([dynamic]Vec3, vertices, allocator)
	m.normals = make([dynamic]Vec3, vertices, allocator)
	m.indices = make([dynamic]u32, 3 * triangles, allocator)
	copy(slice.to_bytes(m.positions[:]), positions)
	copy(slice.to_bytes(m.indices[:]), indices)
	if geom.mesh_sculptable(m, pool) != .None {
		geom.mesh_destroy(&m)
		return {}, false
	}
	return m, true
}

// Reads the base level's quads, with its vertices renumbered by `file_order` (file place
// -> vertex). False on a damaged file.
@(private = "file")
read_quads :: proc(saved: []u8, l: ^Levels, file_order: []u32) -> bool {
	if len(saved) % size_of([4]u32) != 0 do return false
	count := len(saved) / size_of([4]u32)
	if count == 0 do return true
	vertices := u32(len(file_order))
	quads := make([][4]u32, count, l.allocator)
	for &q, i in quads {
		for k in 0 ..< 4 {
			v := intrinsics.unaligned_load(cast(^u32)&saved[size_of([4]u32) * i + size_of(u32) * k])
			if v >= vertices {
				delete(quads, l.allocator)
				return false
			}
			q[k] = file_order[v]
		}
	}
	levels_set_quads(l, quads)
	return true
}

// Reads the base level's UVs into its numbering: triangle t's from the file's triangle
// tri_from[t] (corners keep their order through the renumbering), pins through
// `file_order`. False on a damaged file: a count that differs from the mesh's, a
// coordinate that is not finite, a seam byte or island out of range, seams on one side of
// an edge only, or pins out of order or range.
@(private = "file")
read_uvs :: proc(rec: ^geom.Record, l: ^Levels, file_order, tri_from: []u32) -> bool {
	base := l.levels[0]
	count := len(base.mesh.indices) / 3
	corners, _ := geom.rec_find(rec, Uvs_Tag.Corner)
	seams, _ := geom.rec_find(rec, Uvs_Tag.Seam)
	islands_bytes, _ := geom.rec_find(rec, Uvs_Tag.Island)
	pin_bytes, _ := geom.rec_find(rec, Uvs_Tag.Pins)
	islands := int(geom.rec_get(rec, Uvs_Tag.Islands, u32, 0))
	filled := geom.rec_get(rec, Uvs_Tag.Filled, f32, 0)
	if !rec.ok || len(corners) != count * size_of([3][2]f32) || len(seams) != count * size_of(uv.Seams) || len(islands_bytes) != count * size_of(u32) do return false
	if islands > count || len(pin_bytes) % size_of(u32) != 0 do return false
	pins := len(pin_bytes) / size_of(u32)
	if pins > len(file_order) do return false
	u := uv.Uvs {
		corner  = make([][3][2]f32, count, l.allocator),
		seam    = make([]uv.Seams, count, l.allocator),
		island  = make([]u32, count, l.allocator),
		pins    = make([]u32, pins, l.allocator),
		islands = islands,
		filled  = filled,
	}
	ok := false
	defer if !ok do uv.destroy(&u, l.allocator)
	for t in 0 ..< count {
		from := int(tri_from[t])
		u.corner[t] = intrinsics.unaligned_load(cast(^[3][2]f32)&corners[size_of([3][2]f32) * from])
		bits := seams[from]
		if bits >= 8 do return false
		u.seam[t] = transmute(uv.Seams)bits
		u.island[t] = intrinsics.unaligned_load(cast(^u32)&islands_bytes[size_of(u32) * from])
	}
	last := -1
	for &p, i in u.pins {
		v := int(intrinsics.unaligned_load(cast(^u32)&pin_bytes[size_of(u32) * i]))
		if v <= last || v >= len(file_order) do return false
		last = v
		p = file_order[v]
	}
	slice.sort(u.pins)
	if uv.check(u, base.mesh.indices[:], base.sculptor.faces, len(base.mesh.positions)) != "" do return false
	levels_take_uvs(l, u)
	ok = true
	return true
}

// Reads the Catmull-Clark record into a single-level `l`: the rule, then the base's
// polygons, triangles' polygons and creases in the file's order, put in the level's by
// `file_order` (per file vertex, the level's) and `tri_from` (per triangle, its file
// number). False on a damaged file: sizes that do not agree, or polygons, corners or
// creases that do not fit the base.
@(private = "file")
read_cc :: proc(rec: ^geom.Record, l: ^Levels, file_order, tri_from: []u32) -> bool {
	rule := geom.rec_need(rec, Cc_Tag.Rule, u8)
	tcount := len(tri_from)
	first_bytes, _ := geom.rec_find(rec, Cc_Tag.First)
	corner_bytes, _ := geom.rec_find(rec, Cc_Tag.Corners)
	tri_bytes, _ := geom.rec_find(rec, Cc_Tag.Tri_Poly)
	edge_keys, _ := geom.rec_find(rec, Cc_Tag.Sharp_Edges)
	edge_values, _ := geom.rec_find(rec, Cc_Tag.Sharp_Edge)
	vert_keys, _ := geom.rec_find(rec, Cc_Tag.Sharp_Verts)
	vert_values, _ := geom.rec_find(rec, Cc_Tag.Sharp_Vert)
	if !rec.ok || rule < u8(Subdivision_Rule.Smooth) || rule > u8(Subdivision_Rule.Flat) do return false
	if len(first_bytes) % 4 != 0 || len(corner_bytes) % 4 != 0 || len(tri_bytes) != tcount * 4 do return false
	if len(edge_keys) % 8 != 0 || len(edge_values) * 2 != len(edge_keys) || len(vert_keys) % 4 != 0 || len(vert_values) != len(vert_keys) do return false
	pcount := len(first_bytes) / 4 - 1
	corners_count := len(corner_bytes) / 4
	ecount, vcount := len(edge_keys) / 8, len(vert_keys) / 4
	if pcount < 1 || pcount > tcount || corners_count < 3 * pcount do return false
	first := make([]u32, pcount + 1, l.allocator)
	copy(slice.to_bytes(first), first_bytes)
	if first[0] != 0 || int(first[pcount]) != corners_count {
		delete(first, l.allocator)
		return false
	}
	p := Polys{first = first, corners = make([]u32, corners_count, l.allocator), tri_poly = make([]u32, tcount, l.allocator)}
	s := Sharp{make([]u64, ecount, l.allocator), make([]f32, ecount, l.allocator), make([]u32, vcount, l.allocator), make([]f32, vcount, l.allocator)}
	saved := make([]u32, tcount, context.temp_allocator)
	copy(slice.to_bytes(p.corners), corner_bytes)
	copy(slice.to_bytes(saved), tri_bytes)
	copy(slice.to_bytes(s.edges), edge_keys)
	copy(slice.to_bytes(s.edge), edge_values)
	copy(slice.to_bytes(s.verts), vert_keys)
	copy(slice.to_bytes(s.vert), vert_values)
	vertices := u32(len(file_order))
	fits := true
	for i in 0 ..< pcount do fits &&= first[i] < first[i + 1]
	for &c in p.corners {
		fits &&= c < vertices
		if fits do c = file_order[c]
	}
	for &t, i in p.tri_poly {
		t = saved[tri_from[i]]
		fits &&= int(t) < pcount
	}
	// Creases in the level's numbers, sorted again.
	Edge :: struct {
		key: u64,
		c:   f32,
	}
	edges := make([]Edge, ecount, context.temp_allocator)
	for key, i in s.edges {
		a, b := u32(key >> 32), u32(key & 0xffff_ffff)
		fits &&= a < vertices && b < vertices && a != b && s.edge[i] >= 0 && s.edge[i] <= INFINITE_SHARP // NaN too
		if fits do edges[i] = {sharp_key(file_order[a], file_order[b]), s.edge[i]}
	}
	slice.sort_by(edges, proc(x, y: Edge) -> bool {return x.key < y.key})
	for e, i in edges do s.edges[i], s.edge[i] = e.key, e.c
	Vert :: struct {
		v: u32,
		c: f32,
	}
	verts := make([]Vert, vcount, context.temp_allocator)
	for v, i in s.verts {
		fits &&= v < vertices && s.vert[i] >= 0 && s.vert[i] <= INFINITE_SHARP
		if fits do verts[i] = {file_order[v], s.vert[i]}
	}
	slice.sort_by(verts, proc(x, y: Vert) -> bool {return x.v < y.v})
	for v, i in verts do s.verts[i], s.vert[i] = v.v, v.c
	if !fits {
		polys_destroy(&p, l.allocator)
		sharp_destroy(&s, l.allocator)
		return false
	}
	return levels_set_polys(l, p, s, Subdivision_Rule(rule))
}
