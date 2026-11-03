package send

// LZ4 blocks, the fast greedy way of the reference coder (one hash of each 4-byte run, the
// last place seen, no chains), and a byte shuffle before it: a scene file is mostly 4-byte
// floats and integers, whose high bytes repeat where their low bytes do not, so putting
// each byte lane together gives LZ4 runs to find. Measured by `bench --send` against
// what crosses the network (README "Send").

@(private = "file")
LZ4_HASH_BITS :: 14
@(private = "file")
LZ4_MIN_MATCH :: 4
// The reference format's rules for a block's end: the last match ends at least 12 bytes
// before it and the last 5 bytes are literals.
@(private = "file")
LZ4_LAST_MATCH :: 12
@(private = "file")
LZ4_LAST_LITERALS :: 5

// The most a block of n bytes takes, for the output to hold whatever the input is.
lz4_bound :: proc(n: int) -> int {return n + n / 255 + 16}

@(private = "file")
lz4_read32 :: #force_inline proc(b: []u8, i: int) -> u32 {
	return u32(b[i]) | u32(b[i + 1]) << 8 | u32(b[i + 2]) << 16 | u32(b[i + 3]) << 24
}

@(private = "file")
lz4_put_length :: proc(out: []u8, o: ^int, n: int) {
	n := n
	for n >= 255 {
		out[o^] = 255
		o^ += 1
		n -= 255
	}
	out[o^] = u8(n)
	o^ += 1
}

// Writes src as one LZ4 block into out (at least lz4_bound(len(src)) long) and returns
// how many bytes it took.
lz4_compress :: proc(src: []u8, out: []u8) -> int {
	assert(len(out) >= lz4_bound(len(src)))
	table: [1 << LZ4_HASH_BITS]i32
	for &v in table do v = -1
	o, anchor, i := 0, 0, 0
	limit := len(src) - LZ4_LAST_MATCH
	for i < limit {
		seq := lz4_read32(src, i)
		h := (seq * 2654435761) >> (32 - LZ4_HASH_BITS)
		ref := int(table[h])
		table[h] = i32(i)
		if ref < 0 || i - ref > 65535 || lz4_read32(src, ref) != seq {
			i += 1
			continue
		}
		// Grow the match forward, keeping the last literals.
		n := LZ4_MIN_MATCH
		end := len(src) - LZ4_LAST_LITERALS
		for i + n < end && src[ref + n] == src[i + n] do n += 1
		literals := i - anchor
		token := o
		o += 1
		if literals >= 15 {
			out[token] = 15 << 4
			lz4_put_length(out, &o, literals - 15)
		} else {
			out[token] = u8(literals) << 4
		}
		copy(out[o:], src[anchor:i])
		o += literals
		offset := i - ref
		out[o], out[o + 1] = u8(offset), u8(offset >> 8)
		o += 2
		m := n - LZ4_MIN_MATCH
		if m >= 15 {
			out[token] |= 15
			lz4_put_length(out, &o, m - 15)
		} else {
			out[token] |= u8(m)
		}
		i += n
		anchor = i
	}
	literals := len(src) - anchor
	if literals >= 15 {
		out[o] = 15 << 4
		o += 1
		lz4_put_length(out, &o, literals - 15)
	} else {
		out[o] = u8(literals) << 4
		o += 1
	}
	copy(out[o:], src[anchor:])
	return o + literals
}

// Decodes one LZ4 block into out, returning how many bytes it wrote; false when the block
// runs past its input, points before its output, or would overflow out.
@(require_results)
lz4_decompress :: proc(src: []u8, out: []u8) -> (written: int, ok: bool) {
	at, o := 0, 0
	length :: proc(src: []u8, at: ^int, n: int) -> (int, bool) {
		n := n
		for {
			if at^ >= len(src) do return 0, false
			b := src[at^]
			at^ += 1
			n += int(b)
			if b != 255 do return n, true
		}
	}
	for at < len(src) {
		token := src[at]
		at += 1
		literals := int(token >> 4)
		if literals == 15 do literals = length(src, &at, literals) or_return
		if literals > len(src) - at || literals > len(out) - o do return 0, false
		copy(out[o:], src[at:][:literals])
		at += literals
		o += literals
		// The last sequence has literals only.
		if at >= len(src) do break
		if at + 2 > len(src) do return 0, false
		offset := int(src[at]) | int(src[at + 1]) << 8
		at += 2
		match := int(token & 15)
		if match == 15 do match = length(src, &at, match) or_return
		match += LZ4_MIN_MATCH
		if offset == 0 || offset > o || match > len(out) - o do return 0, false
		// Byte by byte: a match may overlap what it copies.
		for k in 0 ..< match do out[o + k] = out[o - offset + k]
		o += match
	}
	return o, true
}

// Puts byte k of every 4-byte word together, lane by lane, into out (as long as src); a
// tail of fewer than 4 bytes stays as it is at the end.
shuffle4 :: proc(src: []u8, out: []u8) {
	words := len(src) / 4
	for w in 0 ..< words do for k in 0 ..< 4 do out[k * words + w] = src[w * 4 + k]
	copy(out[words * 4:], src[words * 4:])
}

// Undoes shuffle4.
unshuffle4 :: proc(src: []u8, out: []u8) {
	words := len(src) / 4
	for w in 0 ..< words do for k in 0 ..< 4 do out[w * 4 + k] = src[k * words + w]
	copy(out[words * 4:], src[words * 4:])
}
