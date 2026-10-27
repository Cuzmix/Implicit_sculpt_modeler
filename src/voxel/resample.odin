package voxel

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:slice"

import "../jobs"

// Res+ and Res−: the clay rebuilt with twice or half the voxels along each axis. The new
// band is sampled from the old field (trilinear between the old voxel centres, distances
// rescaled to the new voxel). At ×2 that is the whole job: the old band reaches two old
// voxels past the new clamp, and between the centres of a distance field the interpolation
// is off by the field's curvature over a voxel, far under a thousandth of a voxel for any
// shape that is voxels wide. At ÷2 the samples land on old centres, so the band is exact
// to two new voxels and clamped past it: the band repair solves the rest, as a stroke's end
// does, growing into the tiles it reaches, and detail finer than the coarser voxel goes.

// The factors a resample takes: the voxel halves or doubles.
RESAMPLE_UP :: f32(2)
RESAMPLE_DOWN :: f32(0.5)

@(private = "file")
Resampler :: struct {
	old:   ^Volume,
	new:   ^Volume,
	scale: f32, // old voxels to new: the factor
	slots: []u32, // the new bricks to fill, in the new volume's pool
}

// Rebuilds the clay with `factor` (RESAMPLE_UP or RESAMPLE_DOWN) times the voxels along
// each axis. The domain stays centred where it was, so at ×2 it covers half the object
// space it did: a clay that would not fit, with its band, is refused (false, the clay as it
// was). The surface, its undo steps and its GPU copy go: the caller records the whole
// change as one undo step and the next flush remakes the copy. Returns false too for a
// factor that is neither.
clay_resample :: proc(c: ^Clay, factor: f32) -> bool {
	if factor != RESAMPLE_UP && factor != RESAMPLE_DOWN do return false
	assert(!c.in_stroke, "a stroke is running")
	old := &c.volume
	voxel := old.voxel / factor
	centre := old.origin + f32(DOMAIN) * 0.5 * old.voxel
	// The new domain, less the band the repair needs around the clay, must hold the clay.
	if bounds := volume_bounds(old); bounds.lo.x <= bounds.hi.x {
		half := (f32(DOMAIN) * 0.5 - f32(BAND + 2)) * voxel
		for a in 0 ..< 3 do if bounds.lo[a] < centre[a] - half || bounds.hi[a] > centre[a] + half do return false
	}
	heap := runtime.heap_allocator()
	x := Resampler{old = old, scale = factor}
	nv: Volume
	volume_init(&nv, voxel, centre, c.allocator)
	x.new = &nv

	// The candidate new bricks: the children (×2) or parents (÷2) of every old brick, each
	// once, in coordinate order (so the pool's slots are the same whatever the thread count).
	candidates := make([dynamic][3]i32, 0, len(old.coords) * 8, heap)
	defer delete(candidates)
	for bc in old.coords {
		if bc == BRICK_FREE do continue
		lo, hi := new_bricks_over(&x, bc)
		for z in lo.z ..= hi.z do for y in lo.y ..= hi.y do for xx in lo.x ..= hi.x do append(&candidates, [3]i32{xx, y, z})
	}
	slice.sort_by(candidates[:], proc(a, b: [3]i32) -> bool {
		if a.z != b.z do return a.z < b.z
		if a.y != b.y do return a.y < b.y
		return a.x < b.x
	})
	slots := make([dynamic]u32, 0, len(candidates), heap)
	defer delete(slots)
	for bc, i in candidates {
		if i > 0 && candidates[i - 1] == bc do continue
		if !brick_in_domain(bc) do continue
		slot, _ := volume_brick_make(&nv, bc, CLAMP)
		append(&slots, slot)
	}
	x.slots = slots[:]
	// Old Inside tiles become new Inside tiles where no candidate stands.
	for t, i in old.chunks {
		if t == 0 do continue
		table := old.tables[t - 1]
		chunk := [3]i32{i32(i % MAX_CHUNKS), i32(i / MAX_CHUNKS % MAX_CHUNKS), i32(i / (MAX_CHUNKS * MAX_CHUNKS))}
		for bz in 0 ..< CHUNK_BRICKS do for by in 0 ..< CHUNK_BRICKS do for bx in 0 ..< CHUNK_BRICKS {
			if table.bricks[(bz * CHUNK_BRICKS + by) * CHUNK_BRICKS + bx] != TILE_INSIDE do continue
			lo, hi := new_bricks_over(&x, chunk * CHUNK_BRICKS + {i32(bx), i32(by), i32(bz)})
			for z in lo.z ..= hi.z do for y in lo.y ..= hi.y do for xx in lo.x ..= hi.x {
				nbc := [3]i32{xx, y, z}
				if !brick_in_domain(nbc) do continue
				new_table := volume_table_make(&nv, nbc)
				at := brick_slot_in_chunk(nbc)
				if new_table.bricks[at] == TILE_EMPTY do new_table.bricks[at] = TILE_INSIDE
			}
		}
	}
	jobs.parallel_for(c.pool, len(x.slots), &x, proc(data: rawptr, i: int) {
		x := cast(^Resampler)data
		fill_brick(x, x.slots[i])
	})

	// The old clay goes and the new volume takes its place; a brick the band never reached
	// is a tile after all.
	clay_clear_history(c)
	volume_destroy(old)
	c.volume = nv
	surface_destroy(&c.surface)
	surface_init(&c.surface, c.allocator)
	clear(&c.pending)
	v := &c.volume
	kept := make([dynamic]u32, 0, len(x.slots), heap)
	defer delete(kept)
	for slot in x.slots {
		if tile := brick_tile(&v.bricks[slot]); tile != .Brick {
			volume_brick_collapse(v, v.coords[slot], tile)
			continue
		}
		append(&kept, slot)
	}
	// Coarser sampling makes saddle faces freely; finer sampling cannot (the sign of a
	// bilinear patch between four centres is one curve), but the pass costs little.
	flips := resolve_saddles(c, kept[:], false)
	if factor < 1 {
		// The band past two new voxels: solved from the seeds, then grown a layer of bricks
		// at a time into the tiles it reaches, each layer solved from the last, until the
		// clamp is reached everywhere (the band is under a brick wide, so a round or two).
		for slot in kept do band_mark(c, slot)
		band_repair(c)
		for len(kept) > 0 {
			grown := grow_band(c, kept[:], heap)
			delete(kept)
			kept = grown
			if len(kept) > 0 do band_repair(c)
		}
	} else if flips > 0 {
		band_repair(c)
	}
	surface_mark_all(c)
	return true
}

// Makes a brick of every tile beside a face of one of `slots` (bricks the repair just
// solved) that the band still reaches through, queued for the next repair, and returns
// their slots. The face test is dilate_band's (clay.odin); nothing is recorded for undo,
// since a resample is a swap step of the caller's.
@(private = "file")
grow_band :: proc(c: ^Clay, slots: []u32, allocator: runtime.Allocator) -> (made: [dynamic]u32) {
	v := &c.volume
	made = make([dynamic]u32, allocator)
	LIMIT :: i16(BAND * SCALE)
	for slot in slots {
		if v.coords[slot] == BRICK_FREE do continue // collapsed by the repair
		bc := v.coords[slot]
		b := &v.bricks[slot]
		for axis in 0 ..< 3 do for side in 0 ..< 2 {
			nc := bc
			nc[axis] += 1 if side == 1 else -1
			if !brick_in_domain(nc) do continue
			tile, _ := volume_tile(v, nc)
			if tile == .Brick do continue
			face := BRICK - 1 if side == 1 else 0
			near := false
			for u in 0 ..< BRICK do for w in 0 ..< BRICK {
				g: [3]int
				g[axis] = face
				g[(axis + 1) % 3] = u
				g[(axis + 2) % 3] = w
				d := b.d[voxel_index(g.x, g.y, g.z)]
				if (tile == .Empty && d >= 0 && d < LIMIT) || (tile == .Inside && d <= 0 && d > -LIMIT) {
					near = true
					break
				}
			}
			if !near do continue
			new_slot, _ := volume_brick_make(v, nc, tile_value(tile))
			band_mark(c, new_slot)
			append(&made, new_slot)
		}
	}
	return
}

// The range of new bricks holding the new voxels whose centres fall strictly within the old
// brick `bc`'s span (old voxel coordinates 8 bc − ½ to 8 bc + 7½): at ×2 its eight
// children, at ÷2 its parent. A new voxel on the span's edge, between an old brick and a
// tile, reads at least half the clamp: it is never in the band. At ÷2 the new band reaches
// past the parents (eight old voxels): the repair grows into the tiles afterwards.
@(private = "file")
new_bricks_over :: proc(x: ^Resampler, bc: [3]i32) -> (lo, hi: [3]i32) {
	// In new voxel coordinates g' = scale · g + DOMAIN / 2 · (1 − scale): both lattices are
	// centred on the domain's centre.
	shift := f32(DOMAIN) * 0.5 * (1 - x.scale)
	for a in 0 ..< 3 {
		g_lo := x.scale * (f32(bc[a]) * BRICK - 0.5) + shift
		g_hi := x.scale * (f32(bc[a]) * BRICK + BRICK - 0.5) + shift
		first := i32(math.floor(g_lo)) + 1
		last := i32(math.ceil(g_hi)) - 1
		lo[a] = first >> 3
		hi[a] = last >> 3
	}
	return
}

// The old voxels a new brick's samples read: 8 new voxels span 3½ old ones at ×2 (five
// old centres) and 14 at ÷2 (sixteen), plus the centre past the last.
@(private = "file")
GATHER :: 17

// Fills new brick `slot` with the old field sampled at each voxel's centre (trilinear
// between the old centres, as volume_sample), in new voxels. The old values the brick
// reads are gathered once: at ÷2 every sample lands on an old centre, at ×2 halfway between.
@(private = "file")
fill_brick :: proc(x: ^Resampler, slot: u32) {
	v := x.new
	bc := v.coords[slot]
	b := &v.bricks[slot]
	// Old voxel coordinates of the brick's first voxel: g = (g' − shift) / scale, exact in
	// f32 (shift is an integer and scale a power of two).
	shift := f32(DOMAIN) * 0.5 * (1 - x.scale)
	first := [3]f32{f32(bc.x * BRICK), f32(bc.y * BRICK), f32(bc.z * BRICK)}
	for a in 0 ..< 3 do first[a] = (first[a] - shift) / x.scale
	lo := [3]i32{i32(math.floor(first.x)), i32(math.floor(first.y)), i32(math.floor(first.z))}
	span := i32(math.floor(f32(BRICK - 1) / x.scale)) + 2 // old centres read along an axis
	assert(span <= GATHER)
	window: [GATHER * GATHER * GATHER]f32
	for z in 0 ..< span do for y in 0 ..< span do for xx in 0 ..< span {
		window[(int(z) * GATHER + int(y)) * GATHER + int(xx)] = f32(volume_value(x.old, lo + {xx, y, z}))
	}
	step := 1 / x.scale // old voxels a new voxel
	for z in 0 ..< BRICK do for y in 0 ..< BRICK do for xx in 0 ..< BRICK {
		g := first - {f32(lo.x), f32(lo.y), f32(lo.z)} + Vec3{f32(xx), f32(y), f32(z)} * step
		f := linalg.floor(g)
		i := [3]int{int(f.x), int(f.y), int(f.z)}
		t := g - f
		c: [8]f32
		for k in 0 ..< 8 {
			c[k] = window[((i.z + (k >> 2 & 1)) * GATHER + i.y + (k >> 1 & 1)) * GATHER + i.x + (k & 1)]
		}
		x0 := math.lerp(c[0], c[1], t.x)
		x1 := math.lerp(c[2], c[3], t.x)
		x2 := math.lerp(c[4], c[5], t.x)
		x3 := math.lerp(c[6], c[7], t.x)
		d := math.lerp(math.lerp(x0, x1, t.y), math.lerp(x2, x3, t.y), t.z) / SCALE
		b.d[voxel_index(xx, y, z)] = quantize(d * x.scale)
	}
}
