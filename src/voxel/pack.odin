package voxel

import "../geom"

// How a brick's values and its mask go into the file (SVOX version 3), to about half the
// bytes of the raw bricks on a sculpted clay (the plain and the 60-dab 256-across spheres
// both packed to 46 % of the raw bytes, zlib at level 6 to 48 %). The values are taken in
// memory order as one chain and each is sent as the change of its difference from the one
// before, since a distance field is smooth: along a row the difference between neighbours
// moves little, so most residuals fit a byte. Equal values in a row (the clamp either side of
// the band, 57 % of a brick's voxels on average) go as one run token. A brick that would
// not shrink goes raw; the byte count before each stream says which. A mask packs as plain
// runs, since it is mostly 0 or 255.
//
// The stream of a packed brick: the first value as two bytes, then tokens until 512 values
// are out. A token is an LEB128 integer: 0 is a run and the byte after it says how many
// more copies of the last value follow (1 to 255); any other token less one is the zigzag
// residual r, and the next value is last + (prev + r), where prev is the last difference
// sent (a run leaves it at 0, which is what it was when the run was sent).

// The most bytes a packed brick's stream may take before the raw brick is written instead.
@(private = "file")
PACK_RAW :: size_of(Brick)

// The most bytes a packed mask's runs may take before the raw mask is written instead.
@(private = "file")
MASK_RAW :: size_of(Mask_Brick)

// Appends the brick's values, packed or raw, after their byte count (0 for raw).
pack_brick :: proc(out: ^[dynamic]u8, b: ^Brick) {
	start := len(out)
	geom.byte_put(out, u16(0))
	geom.byte_put(out, b.d[0])
	last, prev := i32(b.d[0]), i32(0)
	i := 1
	for i < BRICK_VOXELS && len(out) - start - 2 < PACK_RAW {
		d := i32(b.d[i]) - last
		if d == 0 && prev == 0 {
			j := i + 1
			for j < BRICK_VOXELS && i32(b.d[j]) == last && j - i < 255 do j += 1
			append(out, 0, u8(j - i))
			i = j
			continue
		}
		varint_put(out, zigzag(d - prev) + 1)
		last, prev = last + d, d
		i += 1
	}
	size := len(out) - start - 2
	if size >= PACK_RAW {
		resize(out, start + 2)
		geom.byte_put_slice(out, b.d[:])
		return
	}
	out[start], out[start + 1] = u8(size), u8(size >> 8)
}

// Reads a brick written by pack_brick into `b`; false when the bytes are not one.
unpack_brick :: proc(r: ^geom.Byte_Reader, b: ^Brick) -> bool {
	size := int(geom.byte_get(r, u16))
	if !r.ok do return false
	if size == 0 {
		geom.byte_get_slice(r, b.d[:])
		return r.ok
	}
	s := geom.byte_get_bytes(r, size)
	if s == nil || size < 2 do return false
	last := i32(i16(u16(s[0]) | u16(s[1]) << 8))
	b.d[0] = i16(last)
	n, at, prev := 1, 2, i32(0)
	for n < BRICK_VOXELS {
		t, ok := varint_get(s, &at)
		if !ok do return false
		if t == 0 {
			if at >= size do return false
			count := int(s[at])
			at += 1
			if count == 0 || n + count > BRICK_VOXELS do return false
			for _ in 0 ..< count {
				b.d[n] = i16(last)
				n += 1
			}
			continue
		}
		d := prev + unzigzag(t - 1)
		last += d
		if last < i32(min(i16)) || last > i32(max(i16)) do return false
		b.d[n] = i16(last)
		n += 1
		prev = d
	}
	return at == size
}

// Appends the mask as runs (a count of 1 to 255, then the value), or raw, after their byte
// count (0 for raw).
pack_mask :: proc(out: ^[dynamic]u8, m: ^Mask_Brick) {
	start := len(out)
	geom.byte_put(out, u16(0))
	i := 0
	for i < BRICK_VOXELS && len(out) - start - 2 < MASK_RAW {
		j := i + 1
		for j < BRICK_VOXELS && m.m[j] == m.m[i] && j - i < 255 do j += 1
		append(out, u8(j - i), m.m[i])
		i = j
	}
	size := len(out) - start - 2
	if size >= MASK_RAW {
		resize(out, start + 2)
		geom.byte_put_slice(out, m.m[:])
		return
	}
	out[start], out[start + 1] = u8(size), u8(size >> 8)
}

// Reads a mask written by pack_mask into `m`; false when the bytes are not one.
unpack_mask :: proc(r: ^geom.Byte_Reader, m: ^Mask_Brick) -> bool {
	size := int(geom.byte_get(r, u16))
	if !r.ok do return false
	if size == 0 {
		geom.byte_get_slice(r, m.m[:])
		return r.ok
	}
	s := geom.byte_get_bytes(r, size)
	if s == nil || size % 2 != 0 do return false
	n := 0
	for at := 0; at < size; at += 2 {
		count := int(s[at])
		if count == 0 || n + count > BRICK_VOXELS do return false
		for _ in 0 ..< count {
			m.m[n] = s[at + 1]
			n += 1
		}
	}
	return n == BRICK_VOXELS
}

@(private = "file")
zigzag :: #force_inline proc(v: i32) -> u32 {
	return u32(v << 1) ~ u32(v >> 31)
}

@(private = "file")
unzigzag :: #force_inline proc(u: u32) -> i32 {
	return i32(u >> 1) ~ -i32(u & 1)
}

// LEB128: seven bits a byte, low bits first, the high bit set while more follow.
@(private = "file")
varint_put :: proc(out: ^[dynamic]u8, v: u32) {
	v := v
	for v >= 0x80 {
		append(out, u8(v) | 0x80)
		v >>= 7
	}
	append(out, u8(v))
}

// Reads a varint of at most five bytes at `at`, advancing it; false when the bytes end first.
@(private = "file")
varint_get :: proc(s: []u8, at: ^int) -> (v: u32, ok: bool) {
	shift: uint
	for shift < 35 {
		if at^ >= len(s) do return 0, false
		b := s[at^]
		at^ += 1
		v |= u32(b & 0x7f) << shift
		if b < 0x80 do return v, true
		shift += 7
	}
	return 0, false
}
