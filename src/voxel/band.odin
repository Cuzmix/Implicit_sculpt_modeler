package voxel

import "core:math"
import "core:slice"

import "../jobs"

// Band repair puts true distances back into the bricks a stroke touched. Add and Subtract
// leave distances (a smooth minimum of two distance fields is one, within the blend), but
// Smooth, Flatten and Inflate leave values that only have the right sign and the right
// zero crossings; the normals, the raycast and the next stamp's blend read the values
// farther out, so at a stroke's end the touched bricks are solved again from their
// crossings: a voxel beside a sign change keeps its value (so the surface does not move)
// and every other voxel gets the eikonal solution |∇d| = 1 by Godunov upwind sweeps.
//
// A sweep visits the bricks in wavefronts: the bricks whose coordinates sum (in the sweep's
// direction) to the same level share no face, so a wavefront runs in parallel, a brick at a
// time, and reads its neighbours live, the upstream ones already swept this sweep and the
// downstream ones not yet, which is Gauss-Seidel across bricks as inside them. The result
// does not depend on which thread ran which brick, since no brick reads one being written.

// The most sweeps a repair runs: it stops at the first sweep that changes nothing. Fast
// sweeping in wavefront order converges in one sweep per direction (eight, corner to
// corner, so a value crosses every border in every direction once); the rest is slack for
// the last steps of the quantised values.
REPAIR_SWEEPS :: 16
// A sweep that moves no value of a brick by more than this (in SCALE units, a 256th of a
// voxel) leaves the brick settled: the first-order scheme's directional bias keeps
// nudging values by a quantum or two for sweeps after the solution is as good as it gets.
REPAIR_SETTLED :: 16
// The pending stamp of a brick while it is in the running repair's region.
IN_REGION :: max(u32)

// Queues brick `slot` for the repair at the stroke's end, once a repair.
@(private)
band_mark :: proc(c: ^Clay, slot: u32) {
	v := &c.volume
	if v.pending[slot] == c.repair_gen do return
	v.pending[slot] = c.repair_gen
	append(&c.pending, v.coords[slot])
}

// Solves the band in every pending brick. Runs inside the stroke's undo step: the bricks
// it writes were saved when the stroke first touched them (band_mark is only called on
// bricks a dab wrote or made), and a brick it empties is collapsed like any other. With
// `every_sweep` the repair runs all REPAIR_SWEEPS sweeps rather than stop at the first that
// changes nothing: the test of that stop.
@(private)
band_repair :: proc(c: ^Clay, every_sweep := false) {
	v := &c.volume
	// The region: the pending coordinates that are still bricks, each once, in slot order
	// (a collapsed and remade brick may be listed twice).
	clear(&c.region)
	for bc in c.pending {
		tile, _ := volume_tile(v, bc)
		if tile != .Brick do continue
		slot := volume_slot(v, bc)
		if v.pending[slot] != c.repair_gen do continue
		v.pending[slot] = IN_REGION
		append(&c.region, slot)
	}
	clear(&c.pending)
	c.repair_gen += 1
	if len(c.region) == 0 do return
	slice.sort_by(c.region[:], proc(a, b: u32) -> bool {return a < b})
	for slot, i in c.region do v.region[slot] = u32(i)
	defer for slot in c.region do v.pending[slot] = 0
	n := len(c.region)
	resize(&c.scratch, n)
	resize(&c.fixed, n)
	resize(&c.windows, n * WINDOW_VOXELS)

	// Seeds: a voxel beside a sign change is fixed (its value capped at a voxel, since the
	// crossing lies on the edge to that neighbour); every other voxel starts far. The
	// neighbours are read live into the brick's window and the result goes to scratch.
	jobs.parallel_for(c.pool, n, c, proc(data: rawptr, i: int) {
		c := cast(^Clay)data
		v := &c.volume
		slot := c.region[i]
		b := &v.bricks[slot]
		out := &c.scratch[i]
		fixed := &c.fixed[i]
		fixed^ = {}
		window := c.windows[i * WINDOW_VOXELS:][:WINDOW_VOXELS]
		gather_faces(v, v.coords[slot], b, window)
		for z in 0 ..< BRICK do for y in 0 ..< BRICK do for x in 0 ..< BRICK {
			k := voxel_index(x, y, z)
			d := b.d[k]
			inside := d < 0
			w := window_at(x + 1, y + 1, z + 1)
			crossing := false
			for step in ([6]int{1, -1, WINDOW, -WINDOW, WINDOW * WINDOW, -WINDOW * WINDOW}) {
				if (window[w + step] < 0) != inside do crossing = true
			}
			if crossing {
				out.d[k] = max(d, -SCALE) if inside else min(d, SCALE)
				fixed[k >> 6] |= 1 << uint(k & 63)
			} else {
				out.d[k] = -CLAMP if inside else CLAMP
			}
		}
	})
	jobs.parallel_for(c.pool, n, c, proc(data: rawptr, i: int) {
		c := cast(^Clay)data
		c.volume.bricks[c.region[i]] = c.scratch[i]
	})

	// The sweeps, each in the next of the eight corner-to-corner directions, the bricks in
	// wavefronts along it. A brick that a sweep left unchanged is at a fixed point of the
	// update, whatever the order the update visits voxels in, so it is skipped until a brick
	// beside it changes; once a sweep changes nothing anywhere the region is at a fixed point
	// in every direction and the repair stops.
	resize(&c.settled, n)
	resize(&c.changed, n)
	resize(&c.levels, n)
	slice.fill(c.settled[:], false)
	c.repair_sweeps = 0
	for sweep in 0 ..< REPAIR_SWEEPS {
		dir := sweep & 7
		c.sweep = dir
		// The level of a brick is the sum of its coordinates, each counted from the side the
		// sweep starts at; bricks of one level share no face.
		for slot, i in c.region {
			bc := v.coords[slot]
			level := 0
			for a in 0 ..< 3 do level += int(MAX_BRICKS - 1 - bc[a]) if dir & (1 << uint(a)) != 0 else int(bc[a])
			c.levels[i] = u64(level) << 32 | u64(i)
		}
		slice.sort(c.levels[:])
		slice.fill(c.changed[:], false)
		at := 0
		for at < n {
			level := c.levels[at] >> 32
			end := at
			for end < n && c.levels[end] >> 32 == level do end += 1
			c.level_first = at
			jobs.parallel_for(c.pool, end - at, c, proc(data: rawptr, i: int) {
				c := cast(^Clay)data
				brick := int(u32(c.levels[c.level_first + i]))
				c.changed[brick] = band_sweep_brick(c, brick)
			})
			at = end
		}
		c.repair_sweeps = sweep + 1
		unsettled := 0
		for ch, i in c.changed {
			c.settled[i] = !ch
			if ch do unsettled += 1
		}
		if !every_sweep && unsettled == 0 do break
	}
	for slot in c.region {
		bc := v.coords[slot]
		surface_mark_brick(c, bc)
		if tile := brick_tile(&v.bricks[slot]); tile != .Brick do volume_brick_collapse(v, bc, tile)
	}
}

// The index into a WINDOW³ window.
@(private)
window_at :: #force_inline proc(x, y, z: int) -> int {
	return (z * WINDOW + y) * WINDOW + x
}

// Reads brick `b` (at `bc`) and the facing layer of each of its six neighbours into
// `window` (WINDOW³, the brick at 1 to 8), a tile as its value. The update at a voxel
// reads its six neighbours only, so the window's edges and corners are left as they were.
@(private)
gather_faces :: proc(v: ^Volume, bc: [3]i32, b: ^Brick, window: []i16) {
	for z in 0 ..< BRICK do for y in 0 ..< BRICK {
		copy(window[window_at(1, y + 1, z + 1):][:BRICK], b.d[voxel_index(0, y, z):][:BRICK])
	}
	for axis in 0 ..< 3 do for side in 0 ..< 2 {
		nc := bc
		nc[axis] += 1 if side == 1 else -1
		tile, nb := volume_tile(v, nc)
		p, q := (axis + 1) % 3, (axis + 2) % 3
		g, h: [3]int // the window's and the neighbour's coordinates
		g[axis] = 0 if side == 0 else BRICK + 1
		h[axis] = BRICK - 1 if side == 0 else 0
		if nb == nil {
			value := tile_value(tile)
			for j in 0 ..< BRICK do for i in 0 ..< BRICK {
				g[p], g[q] = i + 1, j + 1
				window[window_at(g.x, g.y, g.z)] = value
			}
		} else {
			for j in 0 ..< BRICK do for i in 0 ..< BRICK {
				g[p], g[q] = i + 1, j + 1
				h[p], h[q] = i, j
				window[window_at(g.x, g.y, g.z)] = nb.d[voxel_index(h.x, h.y, h.z)]
			}
		}
	}
}

// One Godunov sweep over brick `i` of the region in direction `c.sweep` (bit a set: axis a
// runs backwards), unless the brick and the bricks on its faces were settled by the last
// sweep and none of them has changed in this one. The brick's window holds its neighbours'
// facing layers, read live (no brick of the same wavefront shares a face with it), and is
// updated along with the brick. Returns whether the sweep changed a value.
@(private)
band_sweep_brick :: proc(c: ^Clay, i: int) -> (changed: bool) {
	v := &c.volume
	slot := c.region[i]
	bc := v.coords[slot]
	if c.settled[i] {
		quiet := true
		for axis in 0 ..< 3 do for side in 0 ..< 2 {
			nc := bc
			nc[axis] += 1 if side == 1 else -1
			tile, _ := volume_tile(v, nc)
			if tile != .Brick do continue
			if ns := volume_slot(v, nc); v.pending[ns] == IN_REGION {
				j := v.region[ns]
				if !c.settled[j] || c.changed[j] do quiet = false
			}
		}
		if quiet do return false
	}
	b := &v.bricks[slot]
	fixed := &c.fixed[i]
	window := c.windows[i * WINDOW_VOXELS:][:WINDOW_VOXELS]
	gather_faces(v, bc, b, window)
	dir := c.sweep
	for sz in 0 ..< BRICK do for sy in 0 ..< BRICK do for sx in 0 ..< BRICK {
		x := BRICK - 1 - sx if dir & 1 != 0 else sx
		y := BRICK - 1 - sy if dir & 2 != 0 else sy
		z := BRICK - 1 - sz if dir & 4 != 0 else sz
		k := voxel_index(x, y, z)
		if fixed[k >> 6] & (1 << uint(k & 63)) != 0 do continue
		w := window_at(x + 1, y + 1, z + 1)
		d := window[w]
		// The smaller unsigned neighbour per axis, in SCALE units; a neighbour of the other
		// sign counts as zero distance (the surface is between).
		sign := d >> 15 // all ones inside
		near := [3]f32 {
			f32(min(unsigned_toward(window[w - 1], sign), unsigned_toward(window[w + 1], sign))),
			f32(min(unsigned_toward(window[w - WINDOW], sign), unsigned_toward(window[w + WINDOW], sign))),
			f32(min(unsigned_toward(window[w - WINDOW * WINDOW], sign), unsigned_toward(window[w + WINDOW * WINDOW], sign))),
		}
		// The solution is at least the smallest neighbour plus a voxel over √3: when that is
		// no less than the value, the update cannot lower it.
		dist := f32(abs(d))
		if min(near.x, near.y, near.z) + SCALE * 0.577 >= dist do continue
		u := eikonal_update(near / SCALE) * SCALE
		if u < dist {
			q := i16(min(u, f32(CLAMP)))
			q = -q if sign != 0 else q
			if q != d {
				b.d[k] = q
				window[w] = q
				if abs(int(q) - int(d)) > REPAIR_SETTLED do changed = true
			}
		}
	}
	return
}

// A neighbour's unsigned distance, in SCALE units, for a voxel of sign `sign` (all ones
// inside, zero outside): zero when the neighbour is of the other sign.
@(private)
unsigned_toward :: #force_inline proc(dn: i16, sign: i16) -> i16 {
	return abs(dn) if dn >> 15 == sign else 0
}

// Godunov's upwind solution of |∇u| = 1 on a unit grid from the smallest neighbour per
// axis (Zhao's fast sweeping): one, two or three axes take part, as the solution allows.
@(private)
eikonal_update :: proc(near: [3]f32) -> f32 {
	a, b, c := near.x, near.y, near.z
	if a > b do a, b = b, a
	if b > c do b, c = c, b
	if a > b do a, b = b, a
	u := a + 1
	if u <= b do return u
	s := a + b
	u = 0.5 * (s + math.sqrt(max(2 - (a - b) * (a - b), 0)))
	if u <= c do return u
	s += c
	q := a * a + b * b + c * c
	return (s + math.sqrt(max(s * s - 3 * (q - 1), 0))) / 3
}
