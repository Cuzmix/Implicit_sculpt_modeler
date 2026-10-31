package main

import "base:runtime"
import "core:bytes"
import "core:compress"
import "core:compress/zlib"
import "core:encoding/endian"
import "core:fmt"

// OpenEXR panoramas (stage 8a of the viewport polish plan): our own reader of the parts an
// environment needs, so the Android and iPad builds gain no C++ library. It reads one-part
// scanline files whose pixels are stored plain, as RLE, ZIPS, ZIP or PIZ, in half, float or
// unsigned channels, taking R, G and B (or Y alone, spread to all three) and passing over
// the rest (alpha, depth, a layer's other channels). Tiled, deep and multi-part files and
// the lossy compressions (PXR24, B44, B44A, DWAA, DWAB) are refused with a reason. Rows go
// into the panorama as they are read, so the file never sits in memory as floats at full
// size. The format is OpenEXR's "File Layout" and "Compression" documents; PIZ follows
// the reference implementation's Huffman and wavelet coding.

EXR_MAGIC :: [4]u8{0x76, 0x2f, 0x31, 0x01}

// The version field's flags: tiles, names longer than 31 bytes, deep data and several parts.
@(private = "file")
EXR_TILED :: 0x200
@(private = "file")
EXR_DEEP :: 0x800
@(private = "file")
EXR_MULTIPART :: 0x1000

// The compressions by their number in the header, and the scanlines each chunk holds.
@(private = "file")
Exr_Compression :: enum u8 {
	None,
	RLE,
	ZIPS,
	ZIP,
	PIZ,
	PXR24,
	B44,
	B44A,
	DWAA,
	DWAB,
}

@(private = "file")
EXR_LINES := [Exr_Compression]int {
	.None  = 1,
	.RLE   = 1,
	.ZIPS  = 1,
	.ZIP   = 16,
	.PIZ   = 32,
	.PXR24 = 16,
	.B44   = 32,
	.B44A  = 32,
	.DWAA  = 32,
	.DWAB  = 256,
}

@(private = "file")
EXR_COMPRESSION_NAMES := [Exr_Compression]string {
	.None  = "none",
	.RLE   = "RLE",
	.ZIPS  = "ZIPS",
	.ZIP   = "ZIP",
	.PIZ   = "PIZ",
	.PXR24 = "PXR24",
	.B44   = "B44",
	.B44A  = "B44A",
	.DWAA  = "DWAA",
	.DWAB  = "DWAB",
}

// A channel: its name, its type (0 unsigned int, 1 half, 2 float), its bytes a sample,
// and which of R, G and B it fills (-1 none, 3 for Y, which fills all three).
@(private = "file")
Exr_Channel :: struct {
	name:  string,
	kind:  i32,
	size:  int,
	takes: int,
}

// Whether `data` starts as an OpenEXR file.
exr_is :: proc(data: []u8) -> bool {
	return len(data) >= 4 && [4]u8{data[0], data[1], data[2], data[3]} == EXR_MAGIC
}

// Reads an OpenEXR file as a panorama no wider than `max_width` (a power of two halves
// it); why it cannot be one otherwise (a temp string). Never reads past `data`.
exr_decode :: proc(data: []u8, max_width: int, allocator := context.allocator) -> (img: Environment_Image, why: string) {
	if !exr_is(data) || len(data) < 8 do return {}, "it is not an OpenEXR file"
	version, _ := endian.get_u32(data[4:], .Little)
	if version & 0xff != 2 do return {}, fmt.tprintf("OpenEXR version %d is not read", version & 0xff)
	switch {
	case version & EXR_MULTIPART != 0: return {}, "multi-part OpenEXR files are not read: save one part"
	case version & EXR_DEEP != 0:      return {}, "deep OpenEXR files are not read"
	case version & EXR_TILED != 0:     return {}, "tiled OpenEXR files are not read: save it as scanlines"
	}
	at := 8
	channels := make([dynamic]Exr_Channel, 0, 8, context.temp_allocator)
	compression := -1
	window: [4]i32
	has_window := false
	// The header: attributes, each a name, a type, a size and a value, up to an empty name.
	for {
		name, named := exr_string(data, &at)
		if !named do return {}, "its header is cut short"
		if name == "" do break
		kind, typed := exr_string(data, &at)
		if !typed || at + 4 > len(data) do return {}, "its header is cut short"
		size := int(i32(endian.unchecked_get_u32le(data[at:])))
		at += 4
		if size < 0 || at + size > len(data) do return {}, "its header is damaged"
		value := data[at:][:size]
		at += size
		switch name {
		case "channels":
			if kind != "chlist" do return {}, "its channel list is damaged"
			if !exr_channels(value, &channels) do return {}, "its channel list is damaged"
		case "compression":
			if size != 1 do return {}, "its compression is damaged"
			compression = int(value[0])
		case "dataWindow":
			if size != 16 do return {}, "its data window is damaged"
			for &w, i in window do w = i32(endian.unchecked_get_u32le(value[4 * i:]))
			has_window = true
		}
	}
	if !has_window || len(channels) == 0 || compression < 0 do return {}, "its header lacks the channels, compression or data window"
	if compression >= len(Exr_Compression) do return {}, fmt.tprintf("compression %d is not one OpenEXR has", compression)
	comp := Exr_Compression(compression)
	#partial switch comp {
	case .None, .RLE, .ZIPS, .ZIP, .PIZ:
	case:
		return {}, fmt.tprintf("%s compression is not read: save it with ZIP or PIZ", EXR_COMPRESSION_NAMES[comp])
	}
	found: [4]bool
	for c in channels do if c.takes >= 0 do found[c.takes] = true
	if !(found[0] && found[1] && found[2]) && !found[3] do return {}, "it has no R, G and B channels nor a Y channel"
	// With R, G and B, a Y channel (a luminance alongside) is passed over.
	if found[0] && found[1] && found[2] do for &c in channels do if c.takes == 3 do c.takes = -1
	x0, y0 := int(window[0]), int(window[1])
	width, height := int(window[2]) - x0 + 1, int(window[3]) - y0 + 1
	if width <= 0 || height <= 0 do return {}, "its data window is empty"
	if why = panorama_size_check(width, height); why != "" do return
	line_bytes := 0
	for c in channels do line_bytes += width * c.size
	lines := EXR_LINES[comp]
	chunks := (height + lines - 1) / lines
	if at + 8 * chunks > len(data) do return {}, "its chunk table is cut short"
	table := at

	shrink := halvings(width, max_width)
	img = environment_image_make(width, height, shrink, allocator)
	row := make([][3]f32, width, context.temp_allocator)
	plain := make([]u8, line_bytes * lines, context.temp_allocator)
	work := make([]u8, line_bytes * lines, context.temp_allocator)
	piz: Exr_Piz
	// The inflated chunk, on the heap as the decode runs on a thread, its buffer refused
	// growth far past a chunk's size, so a damaged stream cannot take the memory. zlib
	// starts it at COMPRESS_OUTPUT_ALLOCATE_MIN at least and doubles it, so twice that is
	// the most an honest chunk asks for.
	cap := Exr_Cap{limit = 2 * max(len(plain), compress.COMPRESS_OUTPUT_ALLOCATE_MIN), parent = runtime.heap_allocator()}
	inflated: bytes.Buffer
	inflated.buf = make([dynamic]u8, 0, 0, exr_cap_allocator(&cap))
	defer delete(inflated.buf)
	seen := make([]bool, chunks, context.temp_allocator)
	for i in 0 ..< chunks {
		offset := int(endian.unchecked_get_u64le(data[table + 8 * i:]))
		if offset < 0 || offset > len(data) - 8 {
			environment_image_destroy(&img, allocator)
			return {}, "a chunk lies outside the file"
		}
		y := int(i32(endian.unchecked_get_u32le(data[offset:])))
		size := int(i32(endian.unchecked_get_u32le(data[offset + 4:])))
		first := y - y0
		if first < 0 || first >= height || first % lines != 0 || seen[first / lines] || size < 0 || size > len(data) - offset - 8 {
			environment_image_destroy(&img, allocator)
			return {}, "a chunk is damaged"
		}
		seen[first / lines] = true
		n := min(lines, height - first)
		want := n * line_bytes
		packed := data[offset + 8:][:size]
		out := plain[:want]
		reason := ""
		switch {
		// A chunk compression did not shrink is stored as it is.
		case size == want || comp == .None:
			if size != want do reason = "a chunk has the wrong size"
			else do copy(out, packed)
		case comp == .RLE:
			reason = exr_rle(packed, work[:want])
			if reason == "" do exr_unpredict(work[:want], out)
		case comp == .ZIPS || comp == .ZIP:
			reason = exr_inflate(&inflated, packed, work[:want])
			if reason == "" do exr_unpredict(work[:want], out)
		case comp == .PIZ:
			reason = exr_piz(&piz, packed, out, channels[:], width, n)
		}
		if reason != "" {
			environment_image_destroy(&img, allocator)
			return {}, reason
		}
		// Each scanline holds every channel in the header's order, a whole row of each.
		for l in 0 ..< n {
			line := out[l * line_bytes:][:line_bytes]
			start := 0
			for c in channels {
				if c.takes >= 0 {
					for x in 0 ..< width {
						v := exr_sample(line[start + x * c.size:], c.kind)
						if c.takes == 3 do row[x] = {v, v, v}
						else do row[x][c.takes] = v
					}
				}
				start += width * c.size
			}
			environment_add_row(&img, row, first + l, shrink)
		}
	}
	return img, ""
}

// A sample as linear light, clamped to what a half float holds and to no less than nothing
// (an environment emits no negative light; a NaN or an infinity is dark).
@(private = "file")
exr_sample :: proc(b: []u8, kind: i32) -> f32 {
	v: f32
	switch kind {
	case 0: v = f32(endian.unchecked_get_u32le(b))
	case 1: v = f32(transmute(f16)endian.unchecked_get_u16le(b))
	case:   v = transmute(f32)endian.unchecked_get_u32le(b)
	}
	if !(v >= 0) do return 0
	return min(v, HDR_MAX_VALUE)
}

// Reads a zero-ended string at `at`, moving past it.
@(private = "file")
exr_string :: proc(data: []u8, at: ^int) -> (s: string, ok: bool) {
	for i in at^ ..< len(data) {
		if data[i] != 0 do continue
		s = string(data[at^:i])
		at^ = i + 1
		return s, len(s) < 256
	}
	return "", false
}

// The channel list: each a name, its type, a linear flag and three reserved bytes, and its
// sampling across and down; an empty name ends it. Subsampled channels (a chroma image's
// RY and BY) are refused, as the reader keeps every pixel's own value.
@(private = "file")
exr_channels :: proc(value: []u8, out: ^[dynamic]Exr_Channel) -> bool {
	at := 0
	for {
		name, ok := exr_string(value, &at)
		if !ok do return false
		if name == "" do return true
		if at + 16 > len(value) do return false
		kind := i32(endian.unchecked_get_u32le(value[at:]))
		xs := i32(endian.unchecked_get_u32le(value[at + 8:]))
		ys := i32(endian.unchecked_get_u32le(value[at + 12:]))
		at += 16
		if kind < 0 || kind > 2 || xs != 1 || ys != 1 do return false
		takes := -1
		switch name {
		case "R": takes = 0
		case "G": takes = 1
		case "B": takes = 2
		case "Y": takes = 3
		}
		append(out, Exr_Channel{name = name, kind = kind, size = 2 if kind == 1 else 4, takes = takes})
	}
}

// Undoes ZIP's and RLE's preparation of a chunk: each byte was stored as its difference
// from the one before (plus 128), and the bytes were split into the even ones, then the
// odd ones, so that the high and low bytes of each sample sit together.
@(private = "file")
exr_unpredict :: proc(t, out: []u8) {
	for i in 1 ..< len(t) do t[i] = u8(int(t[i - 1]) + int(t[i]) - 128)
	half := (len(t) + 1) / 2
	for i in 0 ..< len(out) do out[i] = t[i / 2] if i % 2 == 0 else t[half + i / 2]
}

// RLE: a signed count; below zero, that many bytes follow as they are; otherwise the next
// byte repeats count + 1 times. It must fill `out` exactly.
@(private = "file")
exr_rle :: proc(packed, out: []u8) -> string {
	at, o := 0, 0
	for at < len(packed) {
		count := int(i8(packed[at]))
		at += 1
		if count < 0 {
			n := -count
			if at + n > len(packed) || o + n > len(out) do return "an RLE chunk is damaged"
			copy(out[o:], packed[at:][:n])
			at, o = at + n, o + n
		} else {
			n := count + 1
			if at >= len(packed) || o + n > len(out) do return "an RLE chunk is damaged"
			for k in 0 ..< n do out[o + k] = packed[at]
			at, o = at + 1, o + n
		}
	}
	return "" if o == len(out) else "an RLE chunk is damaged"
}

// ZIP and ZIPS: a zlib stream that must inflate to exactly `out`, into `buf`, which is
// kept from chunk to chunk so it is allocated once.
@(private = "file")
exr_inflate :: proc(buf: ^bytes.Buffer, packed, out: []u8) -> string {
	clear(&buf.buf)
	if zlib.inflate(packed, buf, expected_output_size = len(out)) != nil || len(buf.buf) != len(out) do return "a ZIP chunk is damaged"
	copy(out, buf.buf[:])
	return ""
}

// An allocator that refuses a block bigger than `limit`.
@(private = "file")
Exr_Cap :: struct {
	limit:  int,
	parent: runtime.Allocator,
}

@(private = "file")
exr_cap_allocator :: proc(c: ^Exr_Cap) -> runtime.Allocator {
	return {procedure = proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
		c := cast(^Exr_Cap)data
		if (mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed) && size > c.limit do return nil, .Out_Of_Memory
		return c.parent.procedure(c.parent.data, mode, size, alignment, old_memory, old_size, loc)
	}, data = c}
}

// PIZ: the chunk's samples as 16-bit words (a float or unsigned sample is two), mapped
// through a table of the values used, wavelet coded per channel and Huffman coded. Its
// tables are kept between chunks, as each is the same size.
@(private = "file")
Exr_Piz :: struct {
	words:  []u16,
	lut:    []u16,
	codes:  []u64,
	decode: []Exr_Huf_Dec,
	long:   [dynamic]i32,
}

@(private = "file")
PIZ_USHORT_RANGE :: 1 << 16
@(private = "file")
PIZ_BITMAP_SIZE :: PIZ_USHORT_RANGE >> 3
@(private = "file")
HUF_ENCSIZE :: (1 << 16) + 1
@(private = "file")
HUF_DECBITS :: 14
@(private = "file")
HUF_DECSIZE :: 1 << HUF_DECBITS
@(private = "file")
HUF_DECMASK :: HUF_DECSIZE - 1

// A Huffman decoding table entry: a code of `len` bits at most HUF_DECBITS long for
// `lit`, or for longer codes starting with these bits, `count` symbols from `first` in
// the long list.
@(private = "file")
Exr_Huf_Dec :: struct {
	len:   i32,
	lit:   i32,
	first: i32,
	count: i32,
}

@(private = "file")
exr_piz :: proc(p: ^Exr_Piz, packed, out: []u8, channels: []Exr_Channel, width, lines: int) -> string {
	n := len(out) / 2
	if len(p.words) < n do p.words = make([]u16, n, context.temp_allocator)
	if p.lut == nil {
		p.lut = make([]u16, PIZ_USHORT_RANGE, context.temp_allocator)
		p.codes = make([]u64, HUF_ENCSIZE, context.temp_allocator)
		p.decode = make([]Exr_Huf_Dec, HUF_DECSIZE, context.temp_allocator)
		p.long = make([dynamic]i32, 0, 64, context.temp_allocator)
	}
	words := p.words[:n]
	if len(packed) < 4 do return "a PIZ chunk is cut short"
	lo := int(endian.unchecked_get_u16le(packed[0:]))
	hi := int(endian.unchecked_get_u16le(packed[2:]))
	at := 4
	bitmap: [PIZ_BITMAP_SIZE]u8
	if lo <= hi {
		if hi >= PIZ_BITMAP_SIZE || at + hi - lo + 1 > len(packed) do return "a PIZ chunk is damaged"
		copy(bitmap[lo:hi + 1], packed[at:][:hi - lo + 1])
		at += hi - lo + 1
	}
	// The values used, in order, zero always first: the table maps each word back.
	k := 0
	for i in 0 ..< PIZ_USHORT_RANGE {
		if i == 0 || bitmap[i >> 3] & (1 << uint(i & 7)) != 0 {
			p.lut[k] = u16(i)
			k += 1
		}
	}
	most := u16(k - 1)
	for i in k ..< PIZ_USHORT_RANGE do p.lut[i] = 0
	if at + 4 > len(packed) do return "a PIZ chunk is cut short"
	length := int(i32(endian.unchecked_get_u32le(packed[at:])))
	at += 4
	if length < 0 || at + length > len(packed) do return "a PIZ chunk is damaged"
	if why := huf_uncompress(p, packed[at:][:length], words); why != "" do return why
	// Each channel's words run on from the last one's, a whole chunk of it, its samples'
	// words interleaved; each word position is a wavelet of its own.
	start := 0
	for c in channels {
		size := c.size / 2
		for j in 0 ..< size do wav2_decode(words[start + j:], width, size, lines, width * size, most)
		start += width * lines * size
	}
	for &w in words do w = p.lut[w]
	// Back into scanlines: each line holds every channel's row in turn.
	o := 0
	from := make([]int, len(channels), context.temp_allocator)
	start = 0
	for c, i in channels {
		from[i] = start
		start += width * lines * (c.size / 2)
	}
	for _ in 0 ..< lines {
		for c, i in channels {
			m := width * (c.size / 2)
			for w in words[from[i]:][:m] {
				out[o], out[o + 1] = u8(w), u8(w >> 8)
				o += 2
			}
			from[i] += m
		}
	}
	return ""
}

// The inverse of PIZ's two-dimensional wavelet over `nx` by `ny` words `ox` apart across
// and `oy` down, in place; `mx` the largest word, which says whether the 14-bit form was
// used.
@(private = "file")
wav2_decode :: proc(w: []u16, nx, ox, ny, oy: int, mx: u16) {
	w14 := mx < (1 << 14)
	n := min(nx, ny)
	p := 1
	for p <= n do p <<= 1
	p >>= 1
	p2 := p
	p >>= 1
	for p >= 1 {
		py := 0
		ey := oy * (ny - p2)
		oy1, oy2 := oy * p, oy * p2
		ox1, ox2 := ox * p, ox * p2
		for ; py <= ey; py += oy2 {
			px := py
			ex := py + ox * (nx - p2)
			for ; px <= ex; px += ox2 {
				p01 := px + ox1
				p10 := px + oy1
				p11 := p10 + ox1
				i00, i01, i10, i11: u16
				if w14 {
					i00, i10 = wdec14(w[px], w[p10])
					i01, i11 = wdec14(w[p01], w[p11])
					w[px], w[p01] = wdec14(i00, i01)
					w[p10], w[p11] = wdec14(i10, i11)
				} else {
					i00, i10 = wdec16(w[px], w[p10])
					i01, i11 = wdec16(w[p01], w[p11])
					w[px], w[p01] = wdec16(i00, i01)
					w[p10], w[p11] = wdec16(i10, i11)
				}
			}
			// An odd column at the right.
			if nx & p != 0 {
				p10 := px + oy1
				if w14 do w[px], w[p10] = wdec14(w[px], w[p10])
				else do w[px], w[p10] = wdec16(w[px], w[p10])
			}
		}
		// An odd row at the bottom.
		if ny & p != 0 {
			px := py
			ex := py + ox * (nx - p2)
			for ; px <= ex; px += ox2 {
				p01 := px + ox1
				if w14 do w[px], w[p01] = wdec14(w[px], w[p01])
				else do w[px], w[p01] = wdec16(w[px], w[p01])
			}
		}
		p2 = p
		p >>= 1
	}
}

// One step of the 14-bit wavelet back: the low `l` and high `h` parts to the two values.
@(private = "file")
wdec14 :: #force_inline proc(l, h: u16) -> (a, b: u16) {
	ls, hs := int(i16(l)), int(i16(h))
	ai := ls + (hs & 1) + (hs >> 1)
	return u16(i16(ai)), u16(i16(ai - hs))
}

// The same for the 16-bit wavelet, modulo 2^16.
@(private = "file")
wdec16 :: #force_inline proc(l, h: u16) -> (a, b: u16) {
	A_OFFSET :: 1 << 15
	MOD_MASK :: (1 << 16) - 1
	m, d := int(l), int(h)
	bb := (m - (d >> 1)) & MOD_MASK
	aa := (d + bb - A_OFFSET) & MOD_MASK
	return u16(aa), u16(bb)
}

// PIZ's Huffman stream: the smallest and largest symbol coded, the table's bits, then the
// codes' lengths (zero runs packed) and `nBits` of codes, which must fill `out` exactly.
// The largest symbol stands for a run of the word before.
@(private = "file")
huf_uncompress :: proc(p: ^Exr_Piz, packed: []u8, out: []u16) -> string {
	if len(packed) == 0 do return "" if len(out) == 0 else "a PIZ chunk is empty"
	if len(packed) < 20 do return "a PIZ chunk is cut short"
	im := int(endian.unchecked_get_u32le(packed[0:]))
	iM := int(endian.unchecked_get_u32le(packed[4:]))
	nbits := int(endian.unchecked_get_u32le(packed[12:]))
	if im < 0 || iM < 0 || im >= HUF_ENCSIZE || iM >= HUF_ENCSIZE || im > iM do return "a PIZ chunk's code table is damaged"
	at := 20
	for &c in p.codes do c = 0
	if !huf_unpack_table(packed, &at, im, iM, p.codes) do return "a PIZ chunk's code table is damaged"
	if nbits < 0 || nbits > 8 * (len(packed) - at) do return "a PIZ chunk is cut short"
	if !huf_build_decode(p, im, iM) do return "a PIZ chunk's codes are damaged"
	if !huf_decode(p, packed[at:], nbits, iM, out) do return "a PIZ chunk's codes are damaged"
	return ""
}

// The next `n` bits of `data` at `at`, through the bit buffer `c` holding `lc` of them.
@(private = "file")
huf_bits :: #force_inline proc(n: uint, c: ^u64, lc: ^uint, data: []u8, at: ^int) -> (v: u64, ok: bool) {
	for lc^ < n {
		if at^ >= len(data) do return 0, false
		c^ = c^ << 8 | u64(data[at^])
		at^ += 1
		lc^ += 8
	}
	lc^ -= n
	return (c^ >> lc^) & ((1 << n) - 1), true
}

// The codes' lengths, six bits each, 59 to 62 a short run of zero lengths and 63 then
// eight bits a long one; then the canonical codes from the lengths, each stored as its
// code shifted past six bits of length.
@(private = "file")
huf_unpack_table :: proc(data: []u8, at: ^int, im, iM: int, codes: []u64) -> bool {
	SHORT_ZEROCODE_RUN :: 59
	LONG_ZEROCODE_RUN :: 63
	SHORTEST_LONG_RUN :: 2 + LONG_ZEROCODE_RUN - SHORT_ZEROCODE_RUN
	c: u64
	lc: uint
	for i := im; i <= iM; i += 1 {
		l := huf_bits(6, &c, &lc, data, at) or_return
		codes[i] = l
		if l == LONG_ZEROCODE_RUN {
			run := int(huf_bits(8, &c, &lc, data, at) or_return) + SHORTEST_LONG_RUN
			if i + run > iM + 1 do return false
			for k in 0 ..< run do codes[i + k] = 0
			i += run - 1
		} else if l >= SHORT_ZEROCODE_RUN {
			run := int(l) - SHORT_ZEROCODE_RUN + 2
			if i + run > iM + 1 do return false
			for k in 0 ..< run do codes[i + k] = 0
			i += run - 1
		}
	}
	// Canonical codes: the longest first, each length's codes counting up.
	count: [59]u64
	for code in codes do count[code] += 1
	next: u64
	for l := 58; l > 0; l -= 1 {
		nc := (next + count[l]) >> 1
		count[l] = next
		next = nc
	}
	for &code in codes {
		l := code
		if l > 0 {
			code = l | count[l] << 6
			count[l] += 1
		}
	}
	return true
}

// The decoding table: a code of up to HUF_DECBITS bits fills every entry it starts; a
// longer one is listed under the entry its first HUF_DECBITS bits name.
@(private = "file")
huf_build_decode :: proc(p: ^Exr_Piz, im, iM: int) -> bool {
	for &d in p.decode do d = {}
	clear(&p.long)
	// Long codes in two passes, so each entry's symbols lie together in the long list.
	for i in im ..= iM {
		c, l := p.codes[i] >> 6, p.codes[i] & 63
		if l == 0 do continue
		if c >> l != 0 do return false
		if l > HUF_DECBITS {
			d := &p.decode[c >> (l - HUF_DECBITS)]
			if d.len != 0 do return false
			d.count += 1
		} else {
			first := c << (HUF_DECBITS - l)
			for k in 0 ..< u64(1) << (HUF_DECBITS - l) {
				d := &p.decode[first + k]
				if d.len != 0 || d.count != 0 do return false
				d^ = {len = i32(l), lit = i32(i)}
			}
		}
	}
	total: i32
	for &d in p.decode {
		if d.count == 0 do continue
		d.first = total
		total += d.count
		d.count = 0
	}
	resize(&p.long, int(total))
	for i in im ..= iM {
		c, l := p.codes[i] >> 6, p.codes[i] & 63
		if l <= HUF_DECBITS do continue
		d := &p.decode[c >> (l - HUF_DECBITS)]
		p.long[d.first + d.count] = i32(i)
		d.count += 1
	}
	return true
}

// Decodes `nbits` of codes into `out`; the symbol `rlc` is followed by eight bits of how
// many more times the word before repeats.
@(private = "file")
huf_decode :: proc(p: ^Exr_Piz, data: []u8, nbits, rlc: int, out: []u16) -> bool {
	c: u64
	lc: uint
	o := 0
	at := 0
	end := (nbits + 7) / 8
	put :: proc(sym, rlc: int, c: ^u64, lc: ^uint, data: []u8, at: ^int, end: int, out: []u16, o: ^int) -> bool {
		if sym == rlc {
			if lc^ < 8 {
				if at^ >= end do return false
				c^ = c^ << 8 | u64(data[at^])
				at^ += 1
				lc^ += 8
			}
			lc^ -= 8
			run := int(u8(c^ >> lc^))
			if o^ + run > len(out) || o^ < 1 do return false
			w := out[o^ - 1]
			for k in 0 ..< run do out[o^ + k] = w
			o^ += run
			return true
		}
		if o^ >= len(out) do return false
		out[o^] = u16(sym)
		o^ += 1
		return true
	}
	for at < end {
		c = c << 8 | u64(data[at])
		at += 1
		lc += 8
		for lc >= HUF_DECBITS {
			d := p.decode[(c >> (lc - HUF_DECBITS)) & HUF_DECMASK]
			if d.len != 0 {
				lc -= uint(d.len)
				put(int(d.lit), rlc, &c, &lc, data, &at, end, out, &o) or_return
				continue
			}
			if d.count == 0 do return false
			matched := false
			for j in d.first ..< d.first + d.count {
				sym := int(p.long[j])
				l := uint(p.codes[sym] & 63)
				for lc < l && at < end {
					c = c << 8 | u64(data[at])
					at += 1
					lc += 8
				}
				if lc >= l && p.codes[sym] >> 6 == (c >> (lc - l)) & ((1 << l) - 1) {
					lc -= l
					put(sym, rlc, &c, &lc, data, &at, end, out, &o) or_return
					matched = true
					break
				}
			}
			if !matched do return false
		}
	}
	// The last byte's padding bits are not codes.
	pad := uint((8 - nbits) & 7)
	c >>= pad
	lc -= min(pad, lc)
	for lc > 0 {
		d := p.decode[(c << (HUF_DECBITS - lc)) & HUF_DECMASK]
		if d.len == 0 || uint(d.len) > lc do return false
		lc -= uint(d.len)
		put(int(d.lit), rlc, &c, &lc, data, &at, end, out, &o) or_return
	}
	return o == len(out)
}
