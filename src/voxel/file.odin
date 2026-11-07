package voxel

import "core:math"
import "core:sync"

import "../geom"
import "../jobs"

// The clay in a scene file, as a tagged record (geom/record.odin): its voxel size and
// origin, then a field a chunk, each a record of its coordinate, its 4096 tile codes and
// the values of its bricks in table order, packed (pack.odin), with the masks and colours
// (color.odin) of the bricks whose codes say so in fields of their own. The surface is not
// stored; it is meshed again on reading. Damaged bytes are refused, never asserted on.

// Tags are never reused or retyped.
@(private = "file")
Clay_Tag :: enum u16 {
	Voxel  = 1, // f32, required: a voxel's size
	Origin = 2, // Vec3
	Chunk  = 3, // one an occupied chunk: a Chunk_Tag record
}

@(private = "file")
Chunk_Tag :: enum u16 {
	Coord  = 1, // [3]u32, required
	Codes  = 2, // u8 per tile, CHUNK_BRICKS³ of them, required
	Bricks = 3, // each brick's values packed (pack_brick), in tile order
	Masks  = 4, // each masked brick's mask packed (pack_mask), in tile order
	Colors = 5, // each coloured brick's colours packed (pack_color), in tile order
}

// Tile codes in the file.
@(private = "file")
FILE_EMPTY :: u8(0)
@(private = "file")
FILE_INSIDE :: u8(1)
@(private = "file")
FILE_BRICK :: u8(2)
// A brick's code adds these to FILE_BRICK when it has a mask, a colour or both.
@(private = "file")
FILE_MASKED :: u8(1)
@(private = "file")
FILE_COLORED :: u8(2)
@(private = "file")
FILE_CODE_LAST :: FILE_BRICK + FILE_MASKED + FILE_COLORED

// Appends the clay's field to `out`. `abort`, when given, is read between chunks (the
// autosave thread asks the writer to stop before a change): false when it was set.
clay_write :: proc(c: ^Clay, out: ^[dynamic]u8, abort: ^bool = nil) -> bool {
	v := &c.volume
	rec := geom.record_begin(out)
	defer geom.record_end(out, rec)
	geom.rec_put(out, Clay_Tag.Voxel, v.voxel)
	geom.rec_put(out, Clay_Tag.Origin, v.origin)
	for table, t in v.tables {
		if abort != nil && sync.atomic_load(abort) do return false
		// The chunk's coordinate: found from the directory, which points at the table.
		cc := [3]u32{}
		found := false
		for slot in 0 ..< len(v.chunks) {
			if int(v.chunks[slot]) != t + 1 do continue
			cc = {u32(slot % MAX_CHUNKS), u32(slot / MAX_CHUNKS % MAX_CHUNKS), u32(slot / (MAX_CHUNKS * MAX_CHUNKS))}
			found = true
			break
		}
		assert(found, "every table is in the directory")
		chunk := geom.rec_begin(out, Clay_Tag.Chunk)
		geom.rec_put(out, Chunk_Tag.Coord, cc)
		at := geom.rec_begin(out, Chunk_Tag.Codes)
		codes := geom.byte_put_bytes(out, len(table.bricks))
		geom.rec_end(out, at)
		masked, colored := false, false
		for slot, i in table.bricks {
			switch slot {
			case TILE_EMPTY:
				codes[i] = FILE_EMPTY
			case TILE_INSIDE:
				codes[i] = FILE_INSIDE
			case:
				m, b := mask_of(v, slot) != nil, color_of(v, slot) != nil
				codes[i] = FILE_BRICK + (FILE_MASKED if m else 0) + (FILE_COLORED if b else 0)
				masked ||= m
				colored ||= b
			}
		}
		at = geom.rec_begin(out, Chunk_Tag.Bricks)
		for slot in table.bricks do if slot != TILE_EMPTY && slot != TILE_INSIDE do pack_brick(out, &v.bricks[slot])
		geom.rec_end(out, at)
		if masked {
			at = geom.rec_begin(out, Chunk_Tag.Masks)
			for slot in table.bricks do if slot != TILE_EMPTY && slot != TILE_INSIDE do if m := mask_of(v, slot); m != nil do pack_mask(out, m)
			geom.rec_end(out, at)
		}
		if colored {
			at = geom.rec_begin(out, Chunk_Tag.Colors)
			for slot in table.bricks do if slot != TILE_EMPTY && slot != TILE_INSIDE do if b := color_of(v, slot); b != nil do pack_color(out, b)
			geom.rec_end(out, at)
		}
		geom.rec_end(out, chunk)
	}
	return true
}

// Reads a clay written by clay_write into `c`, which must not be initialised; false, with
// `c` left empty, when the bytes are not a clay. Every node is queued for meshing.
clay_read :: proc(c: ^Clay, r: ^geom.Byte_Reader, pool: ^jobs.Pool, allocator := context.allocator) -> bool {
	rec := geom.record_take(r)
	if !rec.ok do return false
	if known, _ := geom.record_known(&rec, Clay_Tag); !known do return false
	voxel := geom.rec_need(&rec, Clay_Tag.Voxel, f32)
	origin := geom.rec_get(&rec, Clay_Tag.Origin, Vec3, Vec3{})
	count := geom.rec_count(&rec, Clay_Tag.Chunk)
	if !rec.ok || !(voxel > 0) || math.is_inf(voxel) || count > MAX_CHUNKS * MAX_CHUNKS * MAX_CHUNKS do return false
	for x in origin do if math.is_nan(x) || math.is_inf(x) do return false
	clay_init(c, voxel, {}, pool, allocator)
	c.volume.origin = origin
	ok := clay_read_chunks(c, &rec, count)
	if !ok {
		clay_destroy(c)
		return false
	}
	// The field is kept free of saddle faces, as every edit keeps it (clay.odin).
	resolve_all_saddles(c)
	surface_mark_all(c)
	return true
}

@(private = "file")
clay_read_chunks :: proc(c: ^Clay, rec: ^geom.Record, count: int) -> bool {
	v := &c.volume
	at := 0
	for _ in 0 ..< count {
		payload, _ := geom.rec_next(rec, Clay_Tag.Chunk, &at)
		cr := geom.record_of(payload)
		if known, _ := geom.record_known(&cr, Chunk_Tag); !known do return false
		cc := geom.rec_need(&cr, Chunk_Tag.Coord, [3]u32)
		codes, _ := geom.rec_find(&cr, Chunk_Tag.Codes)
		if !cr.ok || len(codes) != CHUNK_BRICKS * CHUNK_BRICKS * CHUNK_BRICKS || cc.x >= MAX_CHUNKS || cc.y >= MAX_CHUNKS || cc.z >= MAX_CHUNKS do return false
		bc := [3]i32{i32(cc.x), i32(cc.y), i32(cc.z)} * CHUNK_BRICKS
		if volume_table(v, bc) != nil do return false // listed twice
		for code in codes do if code > FILE_CODE_LAST do return false
		// Packed bricks, masks and colours carry their own counts and are checked as read.
		bricks, _ := geom.rec_reader(&cr, Chunk_Tag.Bricks)
		masks, _ := geom.rec_reader(&cr, Chunk_Tag.Masks)
		colors, _ := geom.rec_reader(&cr, Chunk_Tag.Colors)
		table := volume_table_make(v, bc)
		for code, i in codes {
			lb := [3]i32{i32(i % CHUNK_BRICKS), i32(i / CHUNK_BRICKS % CHUNK_BRICKS), i32(i / (CHUNK_BRICKS * CHUNK_BRICKS))}
			switch code {
			case FILE_INSIDE:
				table.bricks[i] = TILE_INSIDE
			case FILE_BRICK ..= FILE_CODE_LAST:
				slot, brick := volume_brick_make(v, bc + lb, 0)
				if !unpack_brick(&bricks, brick) do return false
				if (code - FILE_BRICK) & FILE_MASKED != 0 && !unpack_mask(&masks, mask_make(v, slot)) do return false
				if (code - FILE_BRICK) & FILE_COLORED != 0 && !unpack_color(&colors, color_make(v, slot)) do return false
			}
		}
		// Every packed byte belongs to a brick the codes name.
		if !bricks.ok || !masks.ok || !colors.ok || bricks.at != len(bricks.data) || masks.at != len(masks.data) || colors.at != len(colors.data) do return false
	}
	return true
}

// The most bytes clay_write appends (every brick, mask and colour raw), to reserve them up front.
clay_write_estimate :: proc(c: ^Clay) -> int {
	v := &c.volume
	// The record's size, voxel and origin, and per chunk its field heads, coordinate and codes.
	masked, colored := 0, 0
	for coord, slot in v.coords {
		if coord == BRICK_FREE do continue
		if mask_of(v, u32(slot)) != nil do masked += 1
		if color_of(v, u32(slot)) != nil do colored += 1
	}
	return 64 + len(v.tables) * (96 + CHUNK_BRICKS * CHUNK_BRICKS * CHUNK_BRICKS) + volume_brick_count(v) * (2 + size_of(Brick)) + masked * (2 + size_of(Mask_Brick)) + colored * (2 + size_of(Color_Brick))
}

// A hash of the field, for the autosave's torn-file check: a sum of per-brick hashes, so
// the pool order (which differs between a sculpted clay and the same clay read back) does
// not count.
clay_hash :: proc(c: ^Clay) -> (h: u64) {
	v := &c.volume
	for coord, slot in v.coords {
		if coord == BRICK_FREE do continue
		b: u64 = 0xcbf2_9ce4_8422_2325
		for x in coord do b = (b ~ u64(u32(x))) * 0x100_0000_01b3
		for d in v.bricks[slot].d do b = (b ~ u64(u16(d))) * 0x100_0000_01b3
		h += b
	}
	return
}
