package voxel

import "core:math"
import "core:math/linalg"
import "core:slice"

import "../geom"

// Colour on clay, as 3D-Coat's voxel paint and Medium's colour: a brick may carry a colour
// brick beside its mask brick, an sRGB colour and a painted weight a voxel (weight 0 is
// unpainted, where the object's material shows). The Paint brush moves the colour of the
// voxels under it towards its own and leaves the field alone, so a paint stroke needs no
// repair; each surface vertex samples the colour where it stands, weighted, and the app
// uploads it as a mesh's polypaint. A brick that collapses to a tile drops its colour, as it
// drops its mask: a tile lies a band or more from the surface, where no paint shows.

COLOR_NONE :: max(u32)

Color_Brick :: struct {
	c: [BRICK_VOXELS][4]u8, // sRGB, then the painted weight
}

// The brick slot `slot`'s colour, or nil when it has none.
color_of :: #force_inline proc(v: ^Volume, slot: u32) -> ^Color_Brick {
	if int(slot) >= len(v.colors) do return nil
	if k := v.colors[slot]; k != COLOR_NONE do return &v.color_bricks[k]
	return nil
}

// Brick slot `slot`'s colour, made unpainted if it had none.
color_make :: proc(v: ^Volume, slot: u32) -> ^Color_Brick {
	if c := color_of(v, slot); c != nil do return c
	k: u32
	if len(v.color_free) > 0 {
		k = pop(&v.color_free)
		v.color_bricks[k] = {}
	} else {
		k = u32(len(v.color_bricks))
		append(&v.color_bricks, Color_Brick{})
	}
	v.colors[slot] = k
	return &v.color_bricks[k]
}

// Drops brick slot `slot`'s colour, if it has one.
@(private)
color_drop :: proc(v: ^Volume, slot: u32) {
	if int(slot) >= len(v.colors) do return
	if k := v.colors[slot]; k != COLOR_NONE {
		append(&v.color_free, k)
		v.colors[slot] = COLOR_NONE
	}
}

// Whether any voxel of the clay is painted.
clay_has_color :: proc(c: ^Clay) -> bool {
	v := &c.volume
	for coord, slot in v.coords {
		if coord == BRICK_FREE do continue
		b := color_of(v, u32(slot))
		if b == nil do continue
		for x in b.c do if x[3] != 0 do return true
	}
	return false
}

// Whether the clay holds any colour brick (painted or since erased): a check of two counts,
// for the frame to tell whether the surface's colours need uploading.
clay_colored :: #force_inline proc(c: ^Clay) -> bool {
	return len(c.volume.color_bricks) > len(c.volume.color_free)
}

// Bytes the colours take: the colour bricks (free ones included) and the slot table.
color_bytes :: proc(v: ^Volume) -> int {
	return len(v.color_bricks) * size_of(Color_Brick) + len(v.colors) * size_of(u32)
}

// Applies a Paint dab to brick `bc`'s colour `b`: each voxel within the brush moves towards
// the brush's colour (inverted: its weight towards unpainted) by the falloff times the
// strength, less what the mask holds. The box is of every voxel that changed, since the
// colour shows wherever the surface passes.
dab_paint_brick :: proc(d: ^Dab, bc: [3]i32, b: ^Color_Brick, mask: ^Mask_Brick) -> (e: Dab_Effect) {
	e.lo, e.hi = {BRICK, BRICK, BRICK}, {-1, -1, -1}
	p0 := Vec3{f32(bc.x), f32(bc.y), f32(bc.z)} * BRICK
	inv_r2 := 1 / (d.radius * d.radius)
	want := [3]f32{f32(d.color.r), f32(d.color.g), f32(d.color.b)}
	for z in 0 ..< BRICK do for y in 0 ..< BRICK do for x in 0 ..< BRICK {
		p := p0 + {f32(x), f32(y), f32(z)}
		delta := p - d.centre
		w := falloff(linalg.dot(delta, delta) * inv_r2) * d.strength
		if w == 0 do continue
		i := voxel_index(x, y, z)
		if mask != nil do w *= 1 - f32(mask.m[i]) / 255
		if w <= 0 do continue
		was := b.c[i]
		now := was
		if d.invert {
			now[3] = u8(math.max(f32(was[3]) - 255 * w, 0) + 0.5)
		} else {
			// Unpainted voxels take the colour outright; painted ones blend towards it.
			from := [3]f32{f32(was.r), f32(was.g), f32(was.b)} if was[3] != 0 else want
			mixed := linalg.lerp(from, want, w)
			now = {u8(mixed.r + 0.5), u8(mixed.g + 0.5), u8(mixed.b + 0.5), u8(math.min(f32(was[3]) + 255 * w, 255) + 0.5)}
		}
		// An unpainted voxel holds no colour, so equal paint is equal bits (the file packs it so).
		if now[3] == 0 do now = {}
		if now == was do continue
		b.c[i] = now
		e.lo = linalg.min(e.lo, [3]i8{i8(x), i8(y), i8(z)})
		e.hi = linalg.max(e.hi, [3]i8{i8(x), i8(y), i8(z)})
		e.changed = true
	}
	return
}

// Copies the colours of the n³ voxels from `lo` into `out` (unpainted where a brick has
// none), as gather_mask_window does the mask.
@(private)
gather_color_window :: proc(v: ^Volume, lo: [3]i32, n: int, out: [][4]u8) {
	assert(len(out) == n * n * n, "window size")
	slice.zero(out)
	hi := lo + i32(n - 1)
	blo, bhi := shr3(lo, 3), shr3(hi, 3)
	for bz in blo.z ..= bhi.z do for by in blo.y ..= bhi.y do for bx in blo.x ..= bhi.x {
		bc := [3]i32{bx, by, bz}
		if !brick_in_domain(bc) do continue
		slot := volume_slot(v, bc)
		if slot == TILE_EMPTY || slot == TILE_INSIDE do continue
		m := color_of(v, slot)
		if m == nil do continue
		base := bc * BRICK
		l := linalg.max(lo - base, [3]i32{0, 0, 0})
		h := linalg.min(hi - base, [3]i32{BRICK - 1, BRICK - 1, BRICK - 1})
		if l.x > h.x || l.y > h.y || l.z > h.z do continue
		for z in l.z ..= h.z do for y in l.y ..= h.y {
			row := (int(base.z + z - lo.z) * n + int(base.y + y - lo.y)) * n + int(base.x - lo.x)
			src := voxel_index(int(l.x), int(y), int(z))
			copy(out[row + int(l.x):row + int(h.x) + 1], m.c[src:src + int(h.x - l.x) + 1])
		}
	}
}

// Whether any brick under the n³ voxels from `lo` has a colour.
@(private)
volume_colored_over :: proc(v: ^Volume, lo: [3]i32, n: int) -> bool {
	hi := lo + i32(n - 1)
	blo, bhi := shr3(lo, 3), shr3(hi, 3)
	for bz in blo.z ..= bhi.z do for by in blo.y ..= bhi.y do for bx in blo.x ..= bhi.x {
		bc := [3]i32{bx, by, bz}
		if !brick_in_domain(bc) do continue
		slot := volume_slot(v, bc)
		if slot == TILE_EMPTY || slot == TILE_INSIDE do continue
		if color_of(v, slot) != nil do return true
	}
	return false
}

// The colour at a point between eight voxels (`corners` in x, then y, then z order, `t`
// the point's place in the cell): the painted ones' colour weighted by their weight, and
// the weight trilinear, so an unpainted corner thins the paint without greying it.
@(private)
color_trilinear :: proc(corners: [8][4]u8, t: Vec3) -> [4]u8 {
	sum: [3]f32
	weight, total: f32
	for k in 0 ..< 8 {
		wx := t.x if k & 1 != 0 else 1 - t.x
		wy := t.y if k >> 1 & 1 != 0 else 1 - t.y
		wz := t.z if k >> 2 & 1 != 0 else 1 - t.z
		a := f32(corners[k][3]) * wx * wy * wz
		sum += [3]f32{f32(corners[k].r), f32(corners[k].g), f32(corners[k].b)} * a
		weight += a
		total += wx * wy * wz
	}
	if weight <= 0 do return {}
	rgb := sum / weight
	return {u8(rgb.r + 0.5), u8(rgb.g + 0.5), u8(rgb.b + 0.5), u8(math.min(weight / total, 255) + 0.5)}
}

// The most bytes a packed colour's runs may take before the raw colour is written instead.
@(private)
COLOR_RAW :: size_of(Color_Brick)

// Appends the colour as runs (a count of 1 to 255, then the four bytes), or raw, after
// their byte count (0 for raw), as pack_mask does the mask. An unpainted voxel's colour is
// written as zeros, whatever it held, so it joins its neighbours' run.
pack_color :: proc(out: ^[dynamic]u8, b: ^Color_Brick) {
	start := len(out)
	geom.byte_put(out, u16(0))
	at :: proc(b: ^Color_Brick, i: int) -> [4]u8 {return b.c[i] if b.c[i][3] != 0 else {}}
	i := 0
	for i < BRICK_VOXELS && len(out) - start - 2 < COLOR_RAW {
		x := at(b, i)
		j := i + 1
		for j < BRICK_VOXELS && at(b, j) == x && j - i < 255 do j += 1
		append(out, u8(j - i), x[0], x[1], x[2], x[3])
		i = j
	}
	size := len(out) - start - 2
	if size >= COLOR_RAW {
		resize(out, start + 2)
		geom.byte_put_slice(out, b.c[:])
		return
	}
	out[start], out[start + 1] = u8(size), u8(size >> 8)
}

// Reads a colour written by pack_color into `b`; false when the bytes are not one.
unpack_color :: proc(r: ^geom.Byte_Reader, b: ^Color_Brick) -> bool {
	size := int(geom.byte_get(r, u16))
	if !r.ok do return false
	if size == 0 {
		geom.byte_get_slice(r, b.c[:])
		return r.ok
	}
	s := geom.byte_get_bytes(r, size)
	if s == nil || size % 5 != 0 do return false
	n := 0
	for at := 0; at < size; at += 5 {
		count := int(s[at])
		if count == 0 || n + count > BRICK_VOXELS do return false
		for _ in 0 ..< count {
			b.c[n] = {s[at + 1], s[at + 2], s[at + 3], s[at + 4]}
			n += 1
		}
	}
	return n == BRICK_VOXELS
}
