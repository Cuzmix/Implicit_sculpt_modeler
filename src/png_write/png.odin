// Package png_write writes PNG images (Odin's core:image/png only reads them): 8-bit RGB or
// RGBA, each row filtered with Up or Sub, whichever leaves smaller numbers, and
// deflated with greedy LZ77 matches and the fixed Huffman codes. That is far from the
// smallest PNG, but a viewport screenshot, mostly flat background and smooth shading,
// comes out a fraction of its raw size, quickly.
package png_write

import "core:hash"

// Encodes `pixels` (RGBA, 4 bytes a pixel, rows top to bottom) as a PNG, keeping the
// alpha channel when `alpha` is set and dropping it otherwise.
encode :: proc(pixels: []u8, width, height: int, alpha: bool, allocator := context.allocator) -> []u8 {
	assert(len(pixels) >= width * height * 4 && width > 0 && height > 0)
	channels := 4 if alpha else 3
	packed := make([]u8, width * height * channels, context.temp_allocator)
	for i in 0 ..< width * height do for c in 0 ..< channels do packed[i * channels + c] = pixels[i * 4 + c]
	return encode_packed(packed, width, height, channels, 8, 6 if alpha else 2, allocator)
}

// Encodes `values` (one 16-bit grey sample a pixel, rows top to bottom) as a 16-bit
// greyscale PNG, as displacement maps are kept.
encode_gray16 :: proc(values: []u16, width, height: int, allocator := context.allocator) -> []u8 {
	assert(len(values) >= width * height && width > 0 && height > 0)
	packed := make([]u8, width * height * 2, context.temp_allocator)
	for v, i in values[:width * height] do packed[2 * i], packed[2 * i + 1] = u8(v >> 8), u8(v)
	return encode_packed(packed, width, height, 2, 16, 0, allocator)
}

// The PNG of rows packed as the file keeps them (`bpp` bytes a pixel), with that bit
// depth and colour type.
@(private)
encode_packed :: proc(packed: []u8, width, height, bpp: int, depth, color_type: u8, allocator := context.allocator) -> []u8 {
	stride := width * bpp

	// The rows as PNG filters them: a filter byte, then the filtered row.
	raw := make([]u8, height * (stride + 1), context.temp_allocator)
	above := make([]u8, stride, context.temp_allocator)
	sub := make([]u8, stride, context.temp_allocator)
	up := make([]u8, stride, context.temp_allocator)
	for y in 0 ..< height {
		row := packed[y * stride:][:stride]
		cost_sub, cost_up: int
		for i in 0 ..< stride {
			left := row[i - bpp] if i >= bpp else 0
			sub[i] = row[i] - left
			up[i] = row[i] - above[i]
			cost_sub += int(abs(i8(sub[i])))
			cost_up += int(abs(i8(up[i])))
		}
		out := raw[y * (stride + 1):][:stride + 1]
		if cost_up < cost_sub {
			out[0] = 2
			copy(out[1:], up)
		} else {
			out[0] = 1
			copy(out[1:], sub)
		}
		copy(above, row)
	}

	data := make([dynamic]u8, 0, len(raw) / 4 + 1024, allocator)
	append(&data, 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n')
	header: [13]u8
	put_u32(header[0:], u32(width))
	put_u32(header[4:], u32(height))
	header[8], header[9] = depth, color_type
	chunk(&data, "IHDR", header[:])
	chunk(&data, "IDAT", zlib(raw, context.temp_allocator))
	chunk(&data, "IEND", nil)
	return data[:]
}

@(private)
put_u32 :: proc(b: []u8, v: u32) {
	b[0], b[1], b[2], b[3] = u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)
}

@(private)
chunk :: proc(out: ^[dynamic]u8, kind: string, body: []u8) {
	n: [4]u8
	put_u32(n[:], u32(len(body)))
	append(out, ..n[:])
	start := len(out)
	append(out, kind)
	append(out, ..body)
	put_u32(n[:], hash.crc32(out[start:]))
	append(out, ..n[:])
}

// A zlib stream of `data`: the deflate stream between zlib's header and checksum.
@(private)
zlib :: proc(data: []u8, allocator := context.allocator) -> []u8 {
	w := Bits{out = make([dynamic]u8, 0, len(data) / 4 + 64, allocator)}
	append(&w.out, 0x78, 0x01)
	deflate_into(&w, data)
	sum := adler32(data)
	tail: [4]u8
	put_u32(tail[:], sum)
	append(&w.out, ..tail[:])
	return w.out[:]
}

// `data` as a raw deflate stream (no zlib header or checksum), as ZIP entries hold it:
// one block with the fixed codes and greedy matches.
deflate :: proc(data: []u8, allocator := context.allocator) -> []u8 {
	w := Bits{out = make([dynamic]u8, 0, len(data) / 4 + 64, allocator)}
	deflate_into(&w, data)
	return w.out[:]
}

@(private)
deflate_into :: proc(w: ^Bits, data: []u8) {
	bits(w, 1, 1) // the last block
	bits(w, 1, 2) // fixed Huffman codes
	HASH_BITS :: 15
	head := make([]i32, 1 << HASH_BITS, context.temp_allocator)
	for &h in head do h = -1
	key :: #force_inline proc(d: []u8, i: int) -> u32 {
		return ((u32(d[i]) << 16 | u32(d[i + 1]) << 8 | u32(d[i + 2])) * 2654435761) >> (32 - HASH_BITS)
	}
	i := 0
	for i < len(data) {
		length, distance := 0, 0
		if i + 3 <= len(data) {
			k := key(data, i)
			if j := int(head[k]); j >= 0 && i - j <= 32768 {
				for length < 258 && i + length < len(data) && data[j + length] == data[i + length] do length += 1
				distance = i - j
			}
			head[k] = i32(i)
		}
		if length >= 3 {
			put_match(w, length, distance)
			// Remember the positions inside the match too, sparsely, for later matches.
			for p := i + 1; p < i + length && p + 3 <= len(data); p += 4 do head[key(data, p)] = i32(p)
			i += length
		} else {
			put_literal(w, int(data[i]))
			i += 1
		}
	}
	put_literal(w, 256) // end of block
	if w.count > 0 do append(&w.out, u8(w.acc))
}

@(private)
Bits :: struct {
	out:   [dynamic]u8,
	acc:   u32,
	count: u32,
}

// `n` bits of `v`, least significant first, as deflate packs everything but codes.
@(private)
bits :: proc(w: ^Bits, v: u32, n: u32) {
	w.acc |= v << w.count
	w.count += n
	for w.count >= 8 {
		append(&w.out, u8(w.acc))
		w.acc >>= 8
		w.count -= 8
	}
}

// A Huffman code, which deflate packs most significant bit first.
@(private)
code :: proc(w: ^Bits, c: u32, n: u32) {
	r: u32
	for k in 0 ..< n do r |= ((c >> k) & 1) << (n - 1 - k)
	bits(w, r, n)
}

// A literal byte or end of block (256), or a length code (257 to 285), in the fixed code.
@(private)
put_literal :: proc(w: ^Bits, v: int) {
	switch {
	case v <= 143: code(w, u32(0x30 + v), 8)
	case v <= 255: code(w, u32(0x190 + v - 144), 9)
	case v <= 279: code(w, u32(v - 256), 7)
	case:          code(w, u32(0xc0 + v - 280), 8)
	}
}

@(private)
LENGTH_BASE := [29]u16{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}
@(private)
LENGTH_EXTRA := [29]u8{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
@(private)
DIST_BASE := [30]u16{1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577}
@(private)
DIST_EXTRA := [30]u8{0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}

@(private)
put_match :: proc(w: ^Bits, length, distance: int) {
	l := 28
	for int(LENGTH_BASE[l]) > length do l -= 1
	put_literal(w, 257 + l)
	bits(w, u32(length - int(LENGTH_BASE[l])), u32(LENGTH_EXTRA[l]))
	d := 29
	for int(DIST_BASE[d]) > distance do d -= 1
	code(w, u32(d), 5)
	bits(w, u32(distance - int(DIST_BASE[d])), u32(DIST_EXTRA[d]))
}

@(private)
adler32 :: proc(data: []u8) -> u32 {
	a, b: u32 = 1, 0
	for i := 0; i < len(data); {
		n := min(len(data) - i, 5552)
		for c in data[i:][:n] {
			a += u32(c)
			b += a
		}
		a %= 65521
		b %= 65521
		i += n
	}
	return b << 16 | a
}
