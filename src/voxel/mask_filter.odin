package voxel

import "base:runtime"
import "core:slice"

import "../jobs"

// Blur, Sharpen, Grow and Shrink of the mask on clay, the mesh's mask commands: each step
// gives every voxel of the band a value from itself and its six neighbours, as a mesh
// vertex takes one from the corners of its triangles. Only voxels within the band take
// part, and only those count as neighbours, so the mask spreads and shrinks over the
// surface's shell rather than into the clay or out into the air, and Shrink does not eat in
// from the band's edge. A step reads the mask as the step before left it and writes each
// brick once, in parallel, so the result is the same on any thread count.

Mask_Filter :: enum u8 {
	Blur,    // the mean
	Sharpen, // half way to the mean, then pushed towards whichever end it is nearer: edges go crisp
	Grow,    // the most
	Shrink,  // the least
}

// The voxels that take part: those within the band, the ones the mask shapes and the
// Mask brush reach (clay_mask_shape).
@(private = "file")
MASK_LIMIT :: i16(BAND * SCALE)

// How far one Sharpen step pushes a value towards the end it is nearer, of 255: the
// mesh's SHARPEN_PUSH, so the two read the same.
MASK_SHARPEN_PUSH :: 13

@(private = "file")
Filter_Run :: struct {
	v:      ^Volume,
	op:     Mask_Filter,
	slots:  []u32,
	out:    []Mask_Brick,
	change: []bool,
}

// Applies `op` `steps` times to the clay's mask as an undo step of its own (no stroke may
// be running). Returns whether the mask changed.
clay_mask_filter :: proc(c: ^Clay, op: Mask_Filter, steps: int) -> bool {
	assert(!c.in_stroke, "a stroke is running")
	if !clay_has_mask(c) do return false
	v := &c.volume
	heap := runtime.heap_allocator()
	seen := make([]bool, len(v.coords), heap)
	defer delete(seen, heap)
	slots := make([dynamic]u32, heap)
	defer delete(slots)
	out := make([dynamic]Mask_Brick, heap)
	defer delete(out)
	change := make([dynamic]bool, heap)
	defer delete(change)
	clay_stroke_begin(c)
	for _ in 0 ..< max(steps, 1) {
		// The masked bricks and the bricks beside them, in slot order.
		clear(&slots)
		for coord, slot in v.coords {
			if coord == BRICK_FREE || mask_of(v, u32(slot)) == nil do continue
			for dz in i32(-1) ..= 1 do for dy in i32(-1) ..= 1 do for dx in i32(-1) ..= 1 {
				s := volume_slot(v, coord + {dx, dy, dz})
				if s == TILE_EMPTY || s == TILE_INSIDE || seen[s] do continue
				seen[s] = true
				append(&slots, s)
			}
		}
		if len(slots) == 0 do break
		for s in slots do seen[s] = false
		slice.sort(slots[:])
		resize(&out, len(slots))
		resize(&change, len(slots))
		run := Filter_Run{v, op, slots[:], out[:], change[:]}
		jobs.parallel_for(c.pool, len(slots), &run, proc(data: rawptr, i: int) {
			r := cast(^Filter_Run)data
			r.change[i] = mask_filter_brick(r.v, r.op, r.slots[i], &r.out[i])
		})
		any := false
		for s, i in slots {
			if !change[i] do continue
			any = true
			coord := v.coords[s]
			undo_record(&c.history, v, coord)
			nothing := true
			for x in out[i].m do if x != 0 {
				nothing = false
				break
			}
			if nothing do mask_drop(v, s)
			else do mask_make(v, s)^ = out[i]
			surface_mark_brick(c, coord)
		}
		if !any do break
	}
	c.in_stroke = false
	return undo_end(&c.history)
}

// Brick `slot`'s mask after one step of `op`, into `out`; whether it differs from now.
@(private = "file")
mask_filter_brick :: proc(v: ^Volume, op: Mask_Filter, slot: u32, out: ^Mask_Brick) -> bool {
	bc := v.coords[slot]
	// The 27 bricks round it: their values (nil for a tile, which takes no part) and masks.
	values: [27]^Brick
	masks: [27]^Mask_Brick
	for dz in i32(-1) ..= 1 do for dy in i32(-1) ..= 1 do for dx in i32(-1) ..= 1 {
		k := (dz + 1) * 9 + (dy + 1) * 3 + dx + 1
		s := volume_slot(v, bc + {dx, dy, dz})
		if s == TILE_EMPTY || s == TILE_INSIDE do continue
		values[k] = &v.bricks[s]
		masks[k] = mask_of(v, s)
	}
	own := masks[13]
	changed := false
	STEPS :: [6][3]int{{-1, 0, 0}, {1, 0, 0}, {0, -1, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 1}}
	for z in 0 ..< BRICK do for y in 0 ..< BRICK do for x in 0 ..< BRICK {
		i := voxel_index(x, y, z)
		k := u32(own.m[i]) if own != nil else 0
		out.m[i] = u8(k)
		d := values[13].d[i]
		if abs(d) > MASK_LIMIT do continue
		lo, hi, sum, n := k, k, k, u32(1)
		for s in STEPS {
			p := [3]int{x + s.x, y + s.y, z + s.z}
			b := 13
			stride := [3]int{1, 3, 9}
			for a in 0 ..< 3 {
				if p[a] < 0 {
					p[a] += BRICK
					b -= stride[a]
				} else if p[a] >= BRICK {
					p[a] -= BRICK
					b += stride[a]
				}
			}
			if values[b] == nil do continue
			j := voxel_index(p.x, p.y, p.z)
			nd := values[b].d[j]
			if abs(nd) > MASK_LIMIT do continue
			m := u32(masks[b].m[j]) if masks[b] != nil else 0
			lo, hi, sum, n = min(lo, m), max(hi, m), sum + m, n + 1
		}
		value := k
		switch op {
		case .Blur:
			value = (sum + n / 2) / n
		case .Sharpen:
			push: f32 = MASK_SHARPEN_PUSH if k >= 128 else -MASK_SHARPEN_PUSH
			value = u32(clamp(f32(k) + push + 0.5 * (f32(sum) / f32(n) - f32(k)) + 0.5, 0, 255))
		case .Grow:
			value = hi
		case .Shrink:
			value = lo
		}
		out.m[i] = u8(value)
		changed ||= value != k
	}
	return changed
}
