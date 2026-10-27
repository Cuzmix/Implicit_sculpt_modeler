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
// The sweeps run in parallel a brick at a time, Gauss-Seidel inside the brick and Jacobi
// across bricks (a brick reads its neighbours from a snapshot taken before the sweep), so
// the result does not depend on which thread ran which brick.

// Sweeps over the region: the eight corner-to-corner directions, so a value crosses a
// brick border in every direction once.
REPAIR_SWEEPS :: 8
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
// bricks a dab wrote or made), and a brick it empties is collapsed like any other.
@(private)
band_repair :: proc(c: ^Clay) {
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
	// neighbourhood is read live into the brick's window and the result goes to scratch.
	jobs.parallel_for(c.pool, n, c, proc(data: rawptr, i: int) {
		c := cast(^Clay)data
		v := &c.volume
		slot := c.region[i]
		b := &v.bricks[slot]
		out := &c.scratch[i]
		fixed := &c.fixed[i]
		fixed^ = {}
		window := c.windows[i * WINDOW_VOXELS:][:WINDOW_VOXELS]
		gather_window(v, v.coords[slot] * BRICK - 1, WINDOW, window)
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

	// The sweeps. Each takes a snapshot of the region, then every brick gathers its
	// neighbourhood from the snapshot and sweeps its own voxels in the direction's order. A
	// brick that a sweep left unchanged is at a fixed point of the update, whatever the
	// order, so it is skipped until a brick beside it changes.
	resize(&c.settled, n)
	resize(&c.settled_next, n)
	slice.fill(c.settled[:], false)
	for sweep in 0 ..< REPAIR_SWEEPS {
		c.sweep = sweep
		jobs.parallel_for(c.pool, n, c, proc(data: rawptr, i: int) {
			c := cast(^Clay)data
			c.scratch[i] = c.volume.bricks[c.region[i]]
		})
		jobs.parallel_for(c.pool, n, c, proc(data: rawptr, i: int) {
			c := cast(^Clay)data
			c.settled_next[i] = band_sweep_brick(c, i)
		})
		c.settled, c.settled_next = c.settled_next, c.settled
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

// One Godunov sweep over brick `i` of the region in direction `c.sweep` (bit a set: axis a
// runs backwards), unless the brick and the bricks on its faces were settled by the last
// sweep. The brick's window, gathered from the snapshot, is updated along with the brick,
// so every neighbour read is a window read. Returns whether the brick is settled now.
@(private)
band_sweep_brick :: proc(c: ^Clay, i: int) -> bool {
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
			if ns := volume_slot(v, nc); v.pending[ns] == IN_REGION && !c.settled[v.region[ns]] do quiet = false
		}
		if quiet do return true
	}
	b := &v.bricks[slot]
	fixed := &c.fixed[i]
	window := c.windows[i * WINDOW_VOXELS:][:WINDOW_VOXELS]
	gather_window(v, bc * BRICK - 1, WINDOW, window, c)
	dir := c.sweep
	far := f32(CLAMP) / SCALE
	steps := [3]int{1, WINDOW, WINDOW * WINDOW}
	settled := true
	for sz in 0 ..< BRICK do for sy in 0 ..< BRICK do for sx in 0 ..< BRICK {
		x := BRICK - 1 - sx if dir & 1 != 0 else sx
		y := BRICK - 1 - sy if dir & 2 != 0 else sy
		z := BRICK - 1 - sz if dir & 4 != 0 else sz
		k := voxel_index(x, y, z)
		if fixed[k >> 6] & (1 << uint(k & 63)) != 0 do continue
		w := window_at(x + 1, y + 1, z + 1)
		d := window[w]
		inside := d < 0
		// The smaller unsigned neighbour per axis, in voxels; a neighbour of the other
		// sign counts as zero distance (the surface is between).
		near: [3]f32
		for axis in 0 ..< 3 {
			m := far
			for side in 0 ..< 2 {
				dn := window[w + steps[axis] if side == 1 else w - steps[axis]]
				u := f32(abs(dn)) / SCALE if (dn < 0) == inside else 0
				m = min(m, u)
			}
			near[axis] = m
		}
		u := eikonal_update(near)
		if u < f32(abs(d)) / SCALE {
			q := quantize(u)
			q = -q if inside else q
			if q != d {
				b.d[k] = q
				window[w] = q
				settled = false
			}
		}
	}
	return settled
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
