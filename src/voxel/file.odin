package voxel

import "core:math"
import "core:sync"

import "../geom"
import "../jobs"

// The clay in a scene file: a tag and a version of its own inside the object, then the
// field chunk by chunk: each occupied chunk's coordinate, its 4096 tile codes and the
// values of its bricks in table order. The surface is not stored; it is meshed again on
// reading. Damaged bytes are refused, never asserted on: every count is checked against
// what is left before anything is read.

SVOX_TAG :: u32(0x584F_5653) // "SVOX" in the file
SVOX_VERSION :: u32(1)

// Tile codes in the file.
@(private = "file")
FILE_EMPTY :: u8(0)
@(private = "file")
FILE_INSIDE :: u8(1)
@(private = "file")
FILE_BRICK :: u8(2)

// Appends the clay's field to `out`. `abort`, when given, is read between chunks (the
// autosave thread asks the writer to stop before a change): false when it was set.
clay_write :: proc(c: ^Clay, out: ^[dynamic]u8, abort: ^bool = nil) -> bool {
	v := &c.volume
	geom.byte_put(out, SVOX_TAG)
	geom.byte_put(out, SVOX_VERSION)
	geom.byte_put(out, v.voxel)
	geom.byte_put(out, v.origin)
	geom.byte_put(out, u32(len(v.tables)))
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
		geom.byte_put(out, cc)
		codes := geom.byte_put_bytes(out, len(table.bricks))
		for slot, i in table.bricks {
			switch slot {
			case TILE_EMPTY:
				codes[i] = FILE_EMPTY
			case TILE_INSIDE:
				codes[i] = FILE_INSIDE
			case:
				codes[i] = FILE_BRICK
			}
		}
		for slot in table.bricks {
			if slot == TILE_EMPTY || slot == TILE_INSIDE do continue
			geom.byte_put_slice(out, v.bricks[slot].d[:])
		}
	}
	return true
}

// Reads a clay written by clay_write into `c`, which must not be initialised; false, with
// `c` left empty, when the bytes are not a clay. Every node is queued for meshing.
clay_read :: proc(c: ^Clay, r: ^geom.Byte_Reader, pool: ^jobs.Pool, allocator := context.allocator) -> bool {
	if geom.byte_get(r, u32) != SVOX_TAG do return false
	if geom.byte_get(r, u32) != SVOX_VERSION do return false
	voxel := geom.byte_get(r, f32)
	origin := geom.byte_get(r, Vec3)
	count := int(geom.byte_get(r, u32))
	if !r.ok || !(voxel > 0) || math.is_inf(voxel) || count > MAX_CHUNKS * MAX_CHUNKS * MAX_CHUNKS do return false
	for x in origin do if math.is_nan(x) || math.is_inf(x) do return false
	clay_init(c, voxel, {}, pool, allocator)
	c.volume.origin = origin
	ok := clay_read_chunks(c, r, count)
	if !ok {
		clay_destroy(c)
		return false
	}
	surface_mark_all(c)
	return true
}

@(private = "file")
clay_read_chunks :: proc(c: ^Clay, r: ^geom.Byte_Reader, count: int) -> bool {
	v := &c.volume
	for _ in 0 ..< count {
		cc := geom.byte_get(r, [3]u32)
		if !r.ok || cc.x >= MAX_CHUNKS || cc.y >= MAX_CHUNKS || cc.z >= MAX_CHUNKS do return false
		bc := [3]i32{i32(cc.x), i32(cc.y), i32(cc.z)} * CHUNK_BRICKS
		if volume_table(v, bc) != nil do return false // listed twice
		codes := geom.byte_get_bytes(r, CHUNK_BRICKS * CHUNK_BRICKS * CHUNK_BRICKS)
		if codes == nil do return false
		bricks := 0
		for code in codes {
			if code > FILE_BRICK do return false
			if code == FILE_BRICK do bricks += 1
		}
		if len(r.data) - r.at < bricks * size_of(Brick) do return false
		table := volume_table_make(v, bc)
		for code, i in codes {
			lb := [3]i32{i32(i % CHUNK_BRICKS), i32(i / CHUNK_BRICKS % CHUNK_BRICKS), i32(i / (CHUNK_BRICKS * CHUNK_BRICKS))}
			switch code {
			case FILE_INSIDE:
				table.bricks[i] = TILE_INSIDE
			case FILE_BRICK:
				_, brick := volume_brick_make(v, bc + lb, 0)
				geom.byte_get_slice(r, brick.d[:])
			}
		}
	}
	return r.ok
}

// The bytes clay_write appends, to reserve them up front.
clay_write_estimate :: proc(c: ^Clay) -> int {
	v := &c.volume
	// The header: tag, version, voxel, origin and the chunk count.
	return 28 + len(v.tables) * (12 + CHUNK_BRICKS * CHUNK_BRICKS * CHUNK_BRICKS) + volume_brick_count(v) * size_of(Brick)
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
