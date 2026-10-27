package voxel

import "core:math/linalg"
import "core:slice"

// Masks on clay, kept in the volume rather than on the surface (3D-Coat's Freeze is a
// voxel channel too): a brick may carry a mask brick of one byte a voxel, 255 fully
// masked, and a masked voxel takes a dab's new value only by what is left unmasked. The
// mask shows on the surface the way the mesh brushes' mask does: each surface vertex
// samples the mask field where it stands (mesh.odin) and the value goes up with the
// normal, so no shader changes. Tiles carry no mask (nothing there to sculpt), a brick
// that collapses to a tile drops its mask, and a brick made from a tile starts unmasked.

MASK_NONE :: max(u32)
MASK_FULL :: u8(255)

Mask_Brick :: struct {
	m: [BRICK_VOXELS]u8,
}

// The mask of brick slot `slot`, or nil.
mask_of :: #force_inline proc(v: ^Volume, slot: u32) -> ^Mask_Brick {
	if int(slot) >= len(v.masks) do return nil
	if k := v.masks[slot]; k != MASK_NONE do return &v.mask_bricks[k]
	return nil
}

// Gives brick slot `slot` a mask brick (all 0) when it has none, and returns it.
@(private)
mask_make :: proc(v: ^Volume, slot: u32) -> ^Mask_Brick {
	if m := mask_of(v, slot); m != nil do return m
	k: u32
	if len(v.mask_free) > 0 {
		k = pop(&v.mask_free)
		v.mask_bricks[k] = {}
	} else {
		k = u32(len(v.mask_bricks))
		append(&v.mask_bricks, Mask_Brick{})
	}
	v.masks[slot] = k
	return &v.mask_bricks[k]
}

// Drops brick slot `slot`'s mask, if it has one.
@(private)
mask_drop :: proc(v: ^Volume, slot: u32) {
	if int(slot) >= len(v.masks) do return
	if k := v.masks[slot]; k != MASK_NONE {
		append(&v.mask_free, k)
		v.masks[slot] = MASK_NONE
	}
}

// Whether any voxel of the clay is masked at all.
clay_has_mask :: proc(c: ^Clay) -> bool {
	v := &c.volume
	for coord, slot in v.coords {
		if coord == BRICK_FREE do continue
		m := mask_of(v, u32(slot))
		if m == nil do continue
		words := slice.reinterpret([]u64, m.m[:])
		for w in words do if w != 0 do return true
	}
	return false
}

// Bytes the masks take: the mask bricks (free ones included) and the slot table.
mask_bytes :: proc(v: ^Volume) -> int {
	return len(v.mask_bricks) * size_of(Mask_Brick) + len(v.masks) * size_of(u32)
}

Mask_Op :: enum u8 {
	Clear,  // unmask everything
	Invert, // masked becomes unmasked and the other way round, on every brick
	Fill,   // mask everything
}

// Applies `op` to the whole clay as an undo step of its own (no stroke may be running):
// Clear drops every mask, Fill masks every brick fully, Invert turns every brick's mask
// over (a brick without one becomes fully masked). Returns whether anything changed; the
// surface is marked where it did, since the mask shows on it.
clay_mask_command :: proc(c: ^Clay, op: Mask_Op) -> bool {
	assert(!c.in_stroke, "a stroke is running")
	v := &c.volume
	if op == .Clear && !clay_has_mask(c) do return false
	clay_stroke_begin(c)
	for coord, slot in v.coords {
		if coord == BRICK_FREE do continue
		s := u32(slot)
		m := mask_of(v, s)
		switch op {
		case .Clear:
			if m == nil do continue
			undo_record(&c.history, v, coord)
			mask_drop(v, s)
		case .Fill:
			if m != nil && slice.count(m.m[:], MASK_FULL) == BRICK_VOXELS do continue
			undo_record(&c.history, v, coord)
			m = mask_make(v, s)
			slice.fill(m.m[:], MASK_FULL)
		case .Invert:
			undo_record(&c.history, v, coord)
			m = mask_make(v, s)
			for &x in m.m do x = MASK_FULL - x
		}
		surface_mark_brick(c, coord)
	}
	c.in_stroke = false
	return undo_end(&c.history)
}

// Masks (or with `unmask`, unmasks) every voxel of every brick for which `inside` says
// its object-space centre falls in the shape, as ZBrush's mask rectangle and lasso do, as
// an undo step of its own. The test is the caller's (the app projects to the screen and
// tests the shape there, front-only if it wants); only voxels within the band count, so a
// voxel the surface cannot reach is never masked. Returns whether anything changed.
clay_mask_shape :: proc(c: ^Clay, inside: proc(p: Vec3, user: rawptr) -> bool, user: rawptr, unmask: bool) -> bool {
	assert(!c.in_stroke, "a stroke is running")
	v := &c.volume
	value := u8(0) if unmask else MASK_FULL
	clay_stroke_begin(c)
	LIMIT :: i16(BAND * SCALE)
	for coord, slot in v.coords {
		if coord == BRICK_FREE do continue
		s := u32(slot)
		b := &v.bricks[s]
		m := mask_of(v, s)
		if m == nil && unmask do continue
		recorded := false
		for z in 0 ..< BRICK do for y in 0 ..< BRICK do for x in 0 ..< BRICK {
			k := voxel_index(x, y, z)
			if abs(b.d[k]) > LIMIT do continue
			if m != nil && m.m[k] == value do continue
			if !inside(voxel_centre(v, coord * BRICK + {i32(x), i32(y), i32(z)}), user) do continue
			if !recorded {
				undo_record(&c.history, v, coord)
				recorded = true
				m = mask_make(v, s)
				surface_mark_brick(c, coord)
			}
			m.m[k] = value
		}
	}
	c.in_stroke = false
	return undo_end(&c.history)
}

// The mask at object-space point `p`, trilinear between voxel centres, 0 to 1; 0 off the
// bricks.
mask_sample :: proc(v: ^Volume, p: Vec3) -> f32 {
	g := voxel_coords(v, p)
	f := linalg.floor(g)
	i := [3]i32{i32(f.x), i32(f.y), i32(f.z)}
	t := g - f
	c: [8]f32
	for k in 0 ..< 8 do c[k] = f32(mask_value(v, i + {i32(k & 1), i32(k >> 1 & 1), i32(k >> 2 & 1)}))
	x0 := c[0] + (c[1] - c[0]) * t.x
	x1 := c[2] + (c[3] - c[2]) * t.x
	x2 := c[4] + (c[5] - c[4]) * t.x
	x3 := c[6] + (c[7] - c[6]) * t.x
	y0 := x0 + (x1 - x0) * t.y
	y1 := x2 + (x3 - x2) * t.y
	return (y0 + (y1 - y0) * t.z) / 255
}

// The mask at voxel `g`: its brick's, or 0 on a tile and outside the domain.
mask_value :: proc(v: ^Volume, g: [3]i32) -> u8 {
	if g.x < 0 || g.y < 0 || g.z < 0 do return 0
	bc := shr3(g, 3) // BRICK is 8
	if !brick_in_domain(bc) do return 0
	slot := volume_slot(v, bc)
	if slot == TILE_EMPTY || slot == TILE_INSIDE do return 0
	m := mask_of(v, slot)
	if m == nil do return 0
	l := and3(g, BRICK - 1)
	return m.m[voxel_index(int(l.x), int(l.y), int(l.z))]
}

// Whether any brick under the `n`³ voxels from `lo` has a mask.
@(private)
volume_masked_over :: proc(v: ^Volume, lo: [3]i32, n: int) -> bool {
	hi := lo + i32(n - 1)
	blo, bhi := shr3(lo, 3), shr3(hi, 3) // BRICK is 8
	for bz in blo.z ..= bhi.z do for by in blo.y ..= bhi.y do for bx in blo.x ..= bhi.x {
		bc := [3]i32{bx, by, bz}
		if !brick_in_domain(bc) do continue
		slot := volume_slot(v, bc)
		if slot == TILE_EMPTY || slot == TILE_INSIDE do continue
		if mask_of(v, slot) != nil do return true
	}
	return false
}

// Copies the mask of the `n`³ voxels from `lo` into `out`, x fastest, 0 wherever there is
// no mask brick (gather_window's shape).
@(private)
gather_mask_window :: proc(v: ^Volume, lo: [3]i32, n: int, out: []u8) {
	assert(len(out) == n * n * n, "window size")
	slice.zero(out)
	hi := lo + i32(n - 1)
	blo, bhi := shr3(lo, 3), shr3(hi, 3)
	for bz in blo.z ..= bhi.z do for by in blo.y ..= bhi.y do for bx in blo.x ..= bhi.x {
		bc := [3]i32{bx, by, bz}
		if !brick_in_domain(bc) do continue
		slot := volume_slot(v, bc)
		if slot == TILE_EMPTY || slot == TILE_INSIDE do continue
		m := mask_of(v, slot)
		if m == nil do continue
		base := bc * BRICK
		l := linalg.max(lo - base, [3]i32{0, 0, 0})
		h := linalg.min(hi - base, [3]i32{BRICK - 1, BRICK - 1, BRICK - 1})
		if l.x > h.x || l.y > h.y || l.z > h.z do continue
		for z in l.z ..= h.z do for y in l.y ..= h.y {
			row := (int(base.z + z - lo.z) * n + int(base.y + y - lo.y)) * n + int(base.x - lo.x)
			src := voxel_index(int(l.x), int(y), int(z))
			copy(out[row + int(l.x):row + int(h.x) + 1], m.m[src:src + int(h.x - l.x) + 1])
		}
	}
}
