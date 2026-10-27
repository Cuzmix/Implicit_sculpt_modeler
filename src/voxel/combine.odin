package voxel

import "base:runtime"
import "core:math/linalg"
import "core:slice"

import "../geom"
import "../jobs"

// Booleans between clays, as 3D-Coat's voxel room and OpenVDB's CSG do them: on the fields,
// a voxel at a time, so two pieces merge, cut or intersect exactly, with no mesh to
// intersect and nothing that can fail. The other clay is read at this clay's voxel centres
// (trilinear between its own centres, placed by a transform); union keeps the smaller
// distance, subtract the larger of this and the other's negation, intersect the larger of
// the two. A blend radius rounds the seam the way the Add brush blends (a smooth minimum,
// Houdini's SDF blend). The band is then solved again where anything changed, so the
// result is a clay like any other.

Clay_Op :: enum u8 {
	Union,
	Subtract,
	Intersect,
}

// Makes `c`, which must not be initialised, a copy of `src`: its field, with no undo steps
// and an unmeshed surface (every node marked). The surface is meshed by the next flush.
clay_copy :: proc(c: ^Clay, src: ^Clay, allocator := context.allocator) {
	clay_init(c, src.volume.voxel, {}, src.pool, allocator)
	v, s := &c.volume, &src.volume
	v.origin = s.origin // bit for bit, rather than through a centre
	copy(v.chunks, s.chunks)
	for table in s.tables {
		t := new(Chunk_Table, allocator)
		t^ = table^
		slice.fill(t.nodes[:], NODE_NONE) // the nodes are the source's surface's
		append(&v.tables, t)
	}
	resize(&v.bricks, len(s.bricks))
	copy(v.bricks[:], s.bricks[:])
	resize(&v.coords, len(s.coords))
	copy(v.coords[:], s.coords[:])
	// The stamps are this clay's own: nothing saved, nothing pending (resize zeroes them).
	resize(&v.saved, len(s.saved))
	resize(&v.pending, len(s.pending))
	resize(&v.region, len(s.region))
	resize(&v.free, len(s.free))
	copy(v.free[:], s.free[:])
	surface_mark_all(c)
}

// Whether the volume holds any clay: a brick, or an Inside tile.
volume_has_clay :: proc(v: ^Volume) -> bool {
	if volume_brick_count(v) > 0 do return true
	for table in v.tables do for slot in table.bricks do if slot == TILE_INSIDE do return true
	return false
}

@(private = "file")
Combine :: struct {
	c:        ^Clay,
	other:    ^Volume,
	to_other: matrix[4, 4]f32, // this clay's object space into the other's
	ratio:    f32, // the other's voxel-unit values into this clay's voxels
	op:       Clay_Op,
	blend:    f32, // in this clay's voxels
	slots:    []u32, // the bricks to compute, in this clay's pool
}

// Applies `other`, placed by `to_other` (a point of this clay's object space into the
// other's; `scale` is this clay's object-space length of one unit of the other's), to `c`
// by `op`, with a seam `blend` of this clay's voxels wide (0 for a sharp edge). No stroke
// may be running; the clay's undo steps go (the caller records the whole change) and its
// surface is marked where it changed. One thread and many give the same field bit for bit.
// Returns false when the result holds no clay at all, the clay then emptied.
clay_combine :: proc(c: ^Clay, other: ^Volume, to_other: matrix[4, 4]f32, scale: f32, op: Clay_Op, blend: f32 = 0) -> bool {
	assert(!c.in_stroke, "a stroke is running")
	assert(other != &c.volume, "a clay combined with itself")
	clay_clear_history(c)
	heap := runtime.heap_allocator()
	v := &c.volume
	x := Combine{c = c, other = other, to_other = to_other, ratio = other.voxel * scale / v.voxel, op = op, blend = max(blend, 0)}

	// The other's box in this clay's bricks, with the band around it: outside it the other
	// reads as Empty, which leaves a union or a subtract as it is and empties an intersect.
	from_other := linalg.inverse(to_other)
	ob := volume_bounds(other)
	box := geom.AABB_EMPTY
	if ob.lo.x <= ob.hi.x {
		for k in 0 ..< 8 {
			corner := Vec3{ob.lo.x if k & 1 == 0 else ob.hi.x, ob.lo.y if k & 2 == 0 else ob.hi.y, ob.lo.z if k & 4 == 0 else ob.hi.z}
			geom.aabb_grow(&box, (from_other * [4]f32{corner.x, corner.y, corner.z, 1}).xyz)
		}
	}
	// Past the box the other's values are at the clamp a brick and more away, so even a
	// blend as wide as a brick cannot reach: the box takes the band and the blend around it.
	lo, hi := [3]i32{1, 1, 1}, [3]i32{0, 0, 0} // an empty box: the other has no clay
	if box.lo.x <= box.hi.x {
		margin := f32(BAND + 2) + x.blend
		lo = brick_floor(voxel_coords(v, box.lo) - margin)
		hi = brick_floor(voxel_coords(v, box.hi) + margin)
		lo = linalg.max(lo, [3]i32{0, 0, 0})
		hi = linalg.min(hi, [3]i32{MAX_BRICKS - 1, MAX_BRICKS - 1, MAX_BRICKS - 1})
	}
	in_box :: proc(bc, lo, hi: [3]i32) -> bool {
		return bc.x >= lo.x && bc.y >= lo.y && bc.z >= lo.z && bc.x <= hi.x && bc.y <= hi.y && bc.z <= hi.z
	}

	// An intersect keeps nothing outside the box: every brick there goes, and every Inside
	// tile; a chunk with no table is Empty already.
	if op == .Intersect {
		for coord in v.coords do if coord != BRICK_FREE && !in_box(coord, lo, hi) do volume_brick_collapse(v, coord, .Empty)
		for t, i in v.chunks {
			if t == 0 do continue
			table := v.tables[t - 1]
			chunk := [3]i32{i32(i % MAX_CHUNKS), i32(i / MAX_CHUNKS % MAX_CHUNKS), i32(i / (MAX_CHUNKS * MAX_CHUNKS))}
			for &slot, k in table.bricks {
				if slot != TILE_INSIDE do continue
				bc := chunk * CHUNK_BRICKS + {i32(k % CHUNK_BRICKS), i32(k / CHUNK_BRICKS % CHUNK_BRICKS), i32(k / (CHUNK_BRICKS * CHUNK_BRICKS))}
				if !in_box(bc, lo, hi) do slot = TILE_EMPTY
			}
		}
	}

	// The bricks to compute: in the box, every brick, and every tile the op can change (a
	// union adds into Empty, a subtract and an intersect carve into Inside) where the other
	// has bricks of its own over it; where the other is all one tile over the brick, the
	// brick's result is a tile and is set here.
	slots := make([dynamic]u32, heap)
	defer delete(slots)
	for z in lo.z ..= hi.z do for y in lo.y ..= hi.y do for xx in lo.x ..= hi.x {
		bc := [3]i32{xx, y, z}
		tile, _ := volume_tile(v, bc)
		switch other_tile_over(&x, bc) {
		case .Empty:
			// min(a, +) = a; max(a, −(+)) = a; max(a, +) = +.
			if op == .Intersect && tile != .Empty do volume_brick_collapse(v, bc, .Empty)
			continue
		case .Inside:
			// min(a, −) = −; max(a, +) = +; max(a, −) = a.
			if op == .Union && tile != .Inside do volume_brick_collapse(v, bc, .Inside)
			if op == .Subtract && tile != .Empty do volume_brick_collapse(v, bc, .Empty)
			continue
		case .Brick:
		}
		if tile == .Brick || (op == .Union && tile == .Empty) || (op != .Union && tile == .Inside) {
			slot, _ := volume_brick_make(v, bc, tile_value(tile))
			append(&slots, slot)
		}
	}
	x.slots = slots[:]
	jobs.parallel_for(c.pool, len(slots), &x, proc(data: rawptr, i: int) {
		x := cast(^Combine)data
		combine_brick(x, x.slots[i])
	})

	// Bricks that came out all one clamp are tiles; the rest are repaired and remeshed.
	kept := make([dynamic]u32, 0, len(slots), heap)
	defer delete(kept)
	for slot in slots {
		if tile := brick_tile(&v.bricks[slot]); tile != .Brick {
			volume_brick_collapse(v, v.coords[slot], tile)
			continue
		}
		append(&kept, slot)
	}
	clear(&c.pending)
	if !volume_has_clay(v) do return false
	// The combined values are the exact distance only outside the seam, as with any CSG on
	// distances: the repair solves the band again from the crossings, then grows it into
	// the tiles it now reaches, a layer of bricks at a time, until the clamp is met.
	_ = resolve_saddles(c, kept[:], false)
	for slot in kept do band_mark(c, slot)
	band_repair(c)
	for len(kept) > 0 {
		grown := grow_band(c, kept[:], heap)
		delete(kept)
		kept = grown
		if len(kept) > 0 do band_repair(c)
	}
	surface_mark_all(c)
	return true
}

// What the other clay is over this clay's brick `bc`: Empty or Inside when every brick of
// the other's lattice that the brick's samples (and the blend) reach is that tile, Brick
// when any holds values or the two tiles meet (the other's surface is between them).
@(private = "file")
other_tile_over :: proc(x: ^Combine, bc: [3]i32) -> Tile {
	v := &x.c.volume
	// The brick's box a voxel out either way (a sample reads the centres around it), in
	// the other's voxel coordinates, then the bricks it reaches with the blend.
	box := geom.AABB_EMPTY
	for k in 0 ..< 8 {
		corner := bc * BRICK + {i32(k & 1), i32(k >> 1 & 1), i32(k >> 2 & 1)} * (BRICK + 1) - 1
		p := voxel_centre(v, corner)
		q := (x.to_other * [4]f32{p.x, p.y, p.z, 1}).xyz
		geom.aabb_grow(&box, voxel_coords(x.other, q))
	}
	reach := 1 + x.blend / x.ratio
	lo := brick_floor(box.lo - reach)
	hi := brick_floor(box.hi + reach)
	seen: bit_set[Tile]
	for z in lo.z ..= hi.z do for y in lo.y ..= hi.y do for xx in lo.x ..= hi.x {
		tile, _ := volume_tile(x.other, {xx, y, z})
		if tile == .Brick do return .Brick
		seen += {tile}
		if card(seen) > 1 do return .Brick
	}
	return .Inside if .Inside in seen else .Empty
}

// Combines one brick, every voxel from its own value and the other's sample there.
@(private = "file")
combine_brick :: proc(x: ^Combine, slot: u32) {
	v := &x.c.volume
	b := &v.bricks[slot]
	bc := v.coords[slot]
	for z in 0 ..< BRICK do for y in 0 ..< BRICK do for xx in 0 ..< BRICK {
		k := voxel_index(xx, y, z)
		a := f32(b.d[k]) / SCALE
		p := voxel_centre(v, bc * BRICK + {i32(xx), i32(y), i32(z)})
		q := (x.to_other * [4]f32{p.x, p.y, p.z, 1}).xyz
		o := volume_sample(x.other, q) * x.ratio
		r: f32
		switch x.op {
		case .Union:
			r = smin(a, o, x.blend)
		case .Subtract:
			r = -smin(-a, o, x.blend)
		case .Intersect:
			r = -smin(-a, -o, x.blend)
		}
		b.d[k] = quantize(r)
	}
}
