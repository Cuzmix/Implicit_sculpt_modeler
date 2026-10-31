package main

import "base:runtime"
import "core:bytes"
import "core:compress"
import "core:compress/zlib"
import "core:encoding/endian"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:sync"

// OpenEXR panoramas (stage 8a of the viewport polish plan): our own reader of the parts an
// environment needs, so the Android and iPad builds gain no C++ library. It reads scanline
// and tiled files (the full-size level of a mipmapped or ripmapped one), and of a file of
// several parts the first that holds a picture, whose pixels are stored plain, as RLE,
// ZIPS, ZIP, PIZ or PXR24, or lossily as B44, B44A, DWAA or DWAB, in half, float or
// unsigned channels, taking R, G and B (or Y alone, spread to all three) and passing over
// the rest (alpha, depth, a layer's other channels). Deep files, subsampled chroma and the
// newest compressions (HTJ2K, ZSTD) are refused with a reason. A band of rows goes into
// the panorama as it is read, so the file never sits in memory as floats at full size.
// The format is OpenEXR's "File Layout" and "Compression" documents; PIZ, B44 and DWA
// follow the reference implementation's coding, which the fixtures check value for value.

EXR_MAGIC :: [4]u8{0x76, 0x2f, 0x31, 0x01}

// The version field's flags: tiles, names longer than 31 bytes, deep data and several parts.
@(private = "file")
EXR_TILED :: 0x200
@(private = "file")
EXR_DEEP :: 0x800
@(private = "file")
EXR_MULTIPART :: 0x1000

// The most parts a file may list, and the most pixels a tile may hold (4096 x 4096), so a
// damaged header cannot ask for a band of rows larger than the panorama's own limit.
@(private = "file")
EXR_PARTS_MAX :: 1024
@(private = "file")
EXR_TILE_MAX :: 1 << 24

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

// A channel: its name, its type (0 unsigned int, 1 half, 2 float), its bytes a sample,
// whether it is stored perceptually linear (B44 and DWA code those differently), and which
// of R, G and B it fills (-1 none, 3 for Y, which fills all three).
@(private = "file")
Exr_Channel :: struct {
	name:   string,
	kind:   i32,
	size:   int,
	linear: bool,
	takes:  int,
}

// One part's header: what the reader needs of its attributes.
@(private = "file")
Exr_Header :: struct {
	channels:    [dynamic]Exr_Channel,
	compression: int,
	window:      [4]i32,
	has_window:  bool,
	// The tile size, when the part is tiled.
	tiles:       [2]int,
	has_tiles:   bool,
	tiled_type:  bool,
	deep:        bool,
	// The part's entries in the chunk table (a multi-part file must say).
	chunks:      int,
}

// What decodes one chunk: its compression's state, kept from chunk to chunk so each table
// and buffer is allocated once.
@(private = "file")
Exr_Decoder :: struct {
	comp:     Exr_Compression,
	channels: []Exr_Channel,
	work:     []u8,
	inflated: bytes.Buffer,
	piz:      Exr_Piz,
	dwa:      Exr_Dwa,
	// B44's table from its perceptually linear form back to linear light, made when a
	// channel needs it.
	b44_log:  []u16,
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
	multi := version & EXR_MULTIPART != 0
	if !multi && version & EXR_DEEP != 0 do return {}, "deep OpenEXR files hold samples, not a picture: save it flat"
	at := 8
	parts := make([dynamic]Exr_Header, 0, 4, context.temp_allocator)
	// A multi-part file lists its headers one after another, an empty one ending them.
	for {
		if multi {
			if at >= len(data) do return {}, "its header is cut short"
			if data[at] == 0 {
				at += 1
				break
			}
			if len(parts) == EXR_PARTS_MAX do return {}, "it lists too many parts"
		}
		h: Exr_Header
		if why = exr_header(data, &at, &h); why != "" do return
		append(&parts, h)
		if !multi do break
	}
	if len(parts) == 0 do return {}, "it has no parts"
	// The first part with R, G and B, or failing that the first with Y.
	pick := -1
	for want in 0 ..< 2 {
		for &p, i in parts {
			if p.deep do continue
			rgb, y := exr_finds(p.channels[:])
			if (want == 0 && rgb) || (want == 1 && y) {
				pick = i
				break
			}
		}
		if pick >= 0 do break
	}
	if pick < 0 {
		for p in parts do if p.deep do return {}, "its parts are deep or hold no R, G and B channels nor a Y channel"
		return {}, "it has no R, G and B channels nor a Y channel"
	}
	// The chunk tables follow the headers, one a part, each as long as its part says.
	table := at
	for p in parts[:pick] {
		if p.chunks < 0 do return {}, "a part does not say how many chunks it has"
		table += 8 * p.chunks
		if table > len(data) do return {}, "its chunk table is cut short"
	}
	h := &parts[pick]
	tiled := h.tiled_type || (!multi && version & EXR_TILED != 0)
	if tiled && !h.has_tiles do return {}, "its tiles are not described"
	if !h.has_window || len(h.channels) == 0 || h.compression < 0 do return {}, "its header lacks the channels, compression or data window"
	switch h.compression {
	case 0 ..< len(Exr_Compression):
	case 10, 11, 12, 13:
		return {}, "its compression (HTJ2K or ZSTD) is newer than the reader: save it with ZIP, PIZ or DWAA"
	case:
		return {}, fmt.tprintf("compression %d is not one OpenEXR has", h.compression)
	}
	comp := Exr_Compression(h.compression)
	channels := h.channels[:]
	// With R, G and B, a Y channel (a luminance alongside) is passed over.
	if rgb, _ := exr_finds(channels); rgb do for &c in channels do if c.takes == 3 do c.takes = -1
	x0, y0 := int(h.window[0]), int(h.window[1])
	width, height := int(h.window[2]) - x0 + 1, int(h.window[3]) - y0 + 1
	if width <= 0 || height <= 0 do return {}, "its data window is empty"
	if why = panorama_size_check(width, height); why != "" do return
	// A chunk is a band of whole rows, or under tiles one tile of a band of them.
	tile_w, band := width, EXR_LINES[comp]
	if tiled {
		tile_w, band = h.tiles.x, h.tiles.y
		if min(tile_w, width) * min(band, height) > EXR_TILE_MAX do return {}, "its tiles are too large"
	}
	across := (width + tile_w - 1) / tile_w
	bands := (height + band - 1) / band
	chunks := across * bands
	if multi && h.chunks < chunks do return {}, "its chunk table is damaged"
	if table + 8 * chunks > len(data) do return {}, "its chunk table is cut short"
	sample := 0
	for c in channels do sample += c.size
	chunk_bytes := sample * min(tile_w, width) * min(band, height)

	shrink := halvings(width, max_width)
	img = environment_image_make(width, height, shrink, allocator)
	rows := make([][3]f32, width * min(band, height), context.temp_allocator)
	plain := make([]u8, chunk_bytes, context.temp_allocator)
	d := Exr_Decoder{comp = comp, channels = channels, work = make([]u8, chunk_bytes, context.temp_allocator)}
	// The inflated chunk, on the heap as the decode runs on a thread, its buffer refused
	// growth far past a chunk's size, so a damaged stream cannot take the memory. zlib
	// starts it at COMPRESS_OUTPUT_ALLOCATE_MIN at least and doubles it, so twice that is
	// the most an honest chunk asks for.
	cap := Exr_Cap{limit = 2 * max(chunk_bytes, compress.COMPRESS_OUTPUT_ALLOCATE_MIN), parent = runtime.heap_allocator()}
	d.inflated.buf = make([dynamic]u8, 0, 0, exr_cap_allocator(&cap))
	defer delete(d.inflated.buf)
	seen := make([]bool, chunks, context.temp_allocator)
	// A chunk's leader: its part (several parts only), then its first row, or its tile's
	// column, row and two levels; then its size.
	leader := (20 if tiled else 8) + (4 if multi else 0)
	for i in 0 ..< chunks {
		offset := int(endian.unchecked_get_u64le(data[table + 8 * i:]))
		if offset < 0 || offset > len(data) - leader {
			environment_image_destroy(&img, allocator)
			return {}, "a chunk lies outside the file"
		}
		o := offset
		if multi {
			if int(endian.unchecked_get_u32le(data[o:])) != pick {
				environment_image_destroy(&img, allocator)
				return {}, "a chunk is damaged"
			}
			o += 4
		}
		column, first := 0, 0
		if tiled {
			tx := int(i32(endian.unchecked_get_u32le(data[o:])))
			ty := int(i32(endian.unchecked_get_u32le(data[o + 4:])))
			lx := i32(endian.unchecked_get_u32le(data[o + 8:]))
			ly := i32(endian.unchecked_get_u32le(data[o + 12:]))
			// The full-size level's tiles come first in the table, row by row.
			if tx != i % across || ty != i / across || lx != 0 || ly != 0 {
				environment_image_destroy(&img, allocator)
				return {}, "a tile is damaged"
			}
			column, first = tx * tile_w, ty * band
			o += 16
		} else {
			first = int(i32(endian.unchecked_get_u32le(data[o:]))) - y0
			if first < 0 || first >= height || first % band != 0 || seen[first / band] {
				environment_image_destroy(&img, allocator)
				return {}, "a chunk is damaged"
			}
			seen[first / band] = true
			o += 4
		}
		size := int(i32(endian.unchecked_get_u32le(data[o:])))
		o += 4
		if size < 0 || size > len(data) - o {
			environment_image_destroy(&img, allocator)
			return {}, "a chunk is damaged"
		}
		w, n := min(tile_w, width - column), min(band, height - first)
		out := plain[:n * w * sample]
		if reason := exr_chunk(&d, data[o:][:size], out, w, n); reason != "" {
			environment_image_destroy(&img, allocator)
			return {}, reason
		}
		// Each scanline holds every channel in the header's order, a whole row of each.
		line_bytes := w * sample
		for l in 0 ..< n {
			line := out[l * line_bytes:][:line_bytes]
			row := rows[l * width + column:][:w]
			start := 0
			for c in channels {
				if c.takes >= 0 {
					for x in 0 ..< w {
						v := exr_sample(line[start + x * c.size:], c.kind)
						if c.takes == 3 do row[x] = {v, v, v}
						else do row[x][c.takes] = v
					}
				}
				start += w * c.size
			}
		}
		// A band is whole once its last tile is in (a scanline chunk is a band alone).
		if column + w == width {
			for l in 0 ..< n do environment_add_row(&img, rows[l * width:][:width], first + l, shrink)
		}
	}
	return img, ""
}

// Reads one part's header at `at`: its attributes, each a name, a type, a size and a
// value, up to an empty name; why not ("" when it did).
@(private = "file")
exr_header :: proc(data: []u8, at: ^int, h: ^Exr_Header) -> string {
	h.compression, h.chunks = -1, -1
	h.channels = make([dynamic]Exr_Channel, 0, 8, context.temp_allocator)
	for {
		name, named := exr_string(data, at)
		if !named do return "its header is cut short"
		if name == "" do return ""
		kind, typed := exr_string(data, at)
		if !typed || at^ + 4 > len(data) do return "its header is cut short"
		size := int(i32(endian.unchecked_get_u32le(data[at^:])))
		at^ += 4
		if size < 0 || at^ + size > len(data) do return "its header is damaged"
		value := data[at^:][:size]
		at^ += size
		switch name {
		case "channels":
			if kind != "chlist" || !exr_channels(value, &h.channels) do return "its channel list is damaged"
		case "compression":
			if size != 1 do return "its compression is damaged"
			h.compression = int(value[0])
		case "dataWindow":
			if size != 16 do return "its data window is damaged"
			for &w, i in h.window do w = i32(endian.unchecked_get_u32le(value[4 * i:]))
			h.has_window = true
		case "tiles":
			// Each tile's width and height, then the levels (one, mipmaps or ripmaps) and
			// how their sizes round, of which only the full-size level is read.
			if kind != "tiledesc" || size != 9 do return "its tile description is damaged"
			tw := i32(endian.unchecked_get_u32le(value[0:]))
			th := i32(endian.unchecked_get_u32le(value[4:]))
			if tw <= 0 || th <= 0 || value[8] & 0xf > 2 do return "its tile description is damaged"
			h.tiles, h.has_tiles = {int(tw), int(th)}, true
		case "type":
			part := strings.trim_right_null(string(value))
			h.tiled_type = part == "tiledimage"
			h.deep = part == "deepscanline" || part == "deeptile"
		case "chunkCount":
			if size != 4 do return "its chunk count is damaged"
			h.chunks = int(i32(endian.unchecked_get_u32le(value)))
			if h.chunks < 0 do return "its chunk count is damaged"
		}
	}
}

// Whether `channels` hold R, G and B, and whether they hold Y.
@(private = "file")
exr_finds :: proc(channels: []Exr_Channel) -> (rgb, y: bool) {
	found: [4]bool
	for c in channels do if c.takes >= 0 do found[c.takes] = true
	return found[0] && found[1] && found[2], found[3]
}

// Decodes one chunk of `lines` rows `width` samples wide into `out`, a whole row of each
// channel per line; why not ("" when it did).
@(private = "file")
exr_chunk :: proc(d: ^Exr_Decoder, packed, out: []u8, width, lines: int) -> string {
	want := len(out)
	work := d.work[:want]
	switch {
	// A chunk compression did not shrink is stored as it is.
	case len(packed) == want || d.comp == .None:
		if len(packed) != want do return "a chunk has the wrong size"
		copy(out, packed)
	case d.comp == .RLE:
		if why := exr_rle(packed, work); why != "" do return why
		exr_unpredict(work, out)
	case d.comp == .ZIPS || d.comp == .ZIP:
		if why := exr_inflate(&d.inflated, packed, work); why != "" do return why
		exr_unpredict(work, out)
	case d.comp == .PIZ:
		return exr_piz(&d.piz, packed, out, d.channels, width, lines)
	case d.comp == .PXR24:
		// A float keeps its top 24 bits, so its planes are three bytes a sample.
		n := 0
		for c in d.channels do n += width * (3 if c.kind == 2 else c.size)
		if why := exr_inflate(&d.inflated, packed, d.work[:n * lines]); why != "" do return why
		exr_pxr24(d.work[:n * lines], out, d.channels, width, lines)
	case d.comp == .B44 || d.comp == .B44A:
		return exr_b44(d, packed, out, work, width, lines)
	case d.comp == .DWAA || d.comp == .DWAB:
		return exr_dwa(d, packed, out, width, lines)
	}
	return ""
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
		linear := value[at + 4] != 0
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
		append(out, Exr_Channel{name = name, kind = kind, size = 2 if kind == 1 else 4, linear = linear, takes = takes})
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

// PIZ's tables, which DWA's Huffman coded terms share.
@(private = "file")
exr_piz_tables :: proc(p: ^Exr_Piz) {
	p.lut = make([]u16, PIZ_USHORT_RANGE, context.temp_allocator)
	p.codes = make([]u64, HUF_ENCSIZE, context.temp_allocator)
	p.decode = make([]Exr_Huf_Dec, HUF_DECSIZE, context.temp_allocator)
	p.long = make([dynamic]i32, 0, 64, context.temp_allocator)
}

@(private = "file")
exr_piz :: proc(p: ^Exr_Piz, packed, out: []u8, channels: []Exr_Channel, width, lines: int) -> string {
	n := len(out) / 2
	if len(p.words) < n do p.words = make([]u16, n, context.temp_allocator)
	if p.lut == nil do exr_piz_tables(p)
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

// PXR24: per line and channel, the samples' bytes as planes, most significant first, each
// sample stored as its difference from the one before; a float keeps only its top three
// bytes (the rest is lost) and a half or unsigned sample is whole.
@(private = "file")
exr_pxr24 :: proc(src, out: []u8, channels: []Exr_Channel, width, lines: int) {
	at, o := 0, 0
	for _ in 0 ..< lines {
		for c in channels {
			planes := 3 if c.kind == 2 else c.size
			p := src[at:][:planes * width]
			at += planes * width
			pixel: u32
			for x in 0 ..< width {
				diff: u32
				for b in 0 ..< planes do diff = diff << 8 | u32(p[b * width + x])
				if c.kind == 2 do diff <<= 8
				pixel += diff
				if c.kind == 1 {
					endian.unchecked_put_u16le(out[o:], u16(pixel))
					o += 2
				} else {
					endian.unchecked_put_u32le(out[o:], pixel)
					o += 4
				}
			}
		}
	}
}

// B44 and B44A: each half channel in 4 x 4 blocks, 14 bytes a block (its first sample and
// fifteen six-bit steps under a shared shift), or 3 bytes for a block of one value (B44A
// writes those; B44 never does, but reads them alike); other channels are stored as they
// are. Each channel's samples lie together in the chunk, a whole channel at a time, so they
// are gathered in `scratch` and then interleaved back into scanlines.
@(private = "file")
exr_b44 :: proc(d: ^Exr_Decoder, packed, out, scratch: []u8, width, lines: int) -> string {
	CUT :: "a B44 chunk is cut short"
	at, base := 0, 0
	for c in d.channels {
		n := width * lines * c.size
		if c.kind != 1 {
			if at + n > len(packed) do return CUT
			copy(scratch[base:][:n], packed[at:][:n])
			at, base = at + n, base + n
			continue
		}
		if c.linear && d.b44_log == nil {
			// A perceptually linear channel was stored as exp(x / 8); this undoes it.
			d.b44_log = make([]u16, 1 << 16, context.temp_allocator)
			for &v, i in d.b44_log {
				x := u16(i)
				if x & 0x7c00 == 0x7c00 || x > 0x8000 do continue
				v = transmute(u16)f16(f32(8 * math.ln(f64(f32(transmute(f16)x)))))
			}
		}
		for y := 0; y < lines; y += 4 {
			for x := 0; x < width; x += 4 {
				s: [16]u16
				if at + 3 > len(packed) do return CUT
				if packed[at + 2] >= 13 << 2 {
					s = b44_unpack3(packed[at:])
					at += 3
				} else {
					if at + 14 > len(packed) do return CUT
					s = b44_unpack14(packed[at:])
					at += 14
				}
				if c.linear do for &v in s do v = d.b44_log[v]
				for j in 0 ..< min(4, lines - y) {
					for i in 0 ..< min(4, width - x) {
						endian.unchecked_put_u16le(scratch[base + 2 * ((y + j) * width + x + i):], s[4 * j + i])
					}
				}
			}
		}
		base += n
	}
	o := 0
	for l in 0 ..< lines {
		base = 0
		for c in d.channels {
			row := width * c.size
			copy(out[o:][:row], scratch[base + l * row:][:row])
			o += row
			base += width * lines * c.size
		}
	}
	return ""
}

// A 14-byte B44 block: the first sample, then each column's samples down and the first row's
// across as six-bit steps of 2^shift, offset by 32 steps; the samples were stored with their
// sign folded so that they order as integers, which the end undoes.
@(private = "file")
b44_unpack14 :: proc(b: []u8) -> (s: [16]u16) {
	s[0] = u16(b[0]) << 8 | u16(b[1])
	shift := u16(b[2] >> 2)
	bias := u16(0x20) << shift
	step :: #force_inline proc(v: u16, shift: u16) -> u16 {return (v & 0x3f) << shift}
	s[4] = s[0] + step(u16(b[2]) << 4 | u16(b[3]) >> 4, shift) - bias
	s[8] = s[4] + step(u16(b[3]) << 2 | u16(b[4]) >> 6, shift) - bias
	s[12] = s[8] + step(u16(b[4]), shift) - bias
	s[1] = s[0] + step(u16(b[5]) >> 2, shift) - bias
	s[5] = s[4] + step(u16(b[5]) << 4 | u16(b[6]) >> 4, shift) - bias
	s[9] = s[8] + step(u16(b[6]) << 2 | u16(b[7]) >> 6, shift) - bias
	s[13] = s[12] + step(u16(b[7]), shift) - bias
	s[2] = s[1] + step(u16(b[8]) >> 2, shift) - bias
	s[6] = s[5] + step(u16(b[8]) << 4 | u16(b[9]) >> 4, shift) - bias
	s[10] = s[9] + step(u16(b[9]) << 2 | u16(b[10]) >> 6, shift) - bias
	s[14] = s[13] + step(u16(b[10]), shift) - bias
	s[3] = s[2] + step(u16(b[11]) >> 2, shift) - bias
	s[7] = s[6] + step(u16(b[11]) << 4 | u16(b[12]) >> 4, shift) - bias
	s[11] = s[10] + step(u16(b[12]) << 2 | u16(b[13]) >> 6, shift) - bias
	s[15] = s[14] + step(u16(b[13]), shift) - bias
	for &v in s do v = v & 0x7fff if v & 0x8000 != 0 else ~v
	return
}

// A 3-byte B44A block: one value for all sixteen samples.
@(private = "file")
b44_unpack3 :: proc(b: []u8) -> (s: [16]u16) {
	v := u16(b[0]) << 8 | u16(b[1])
	v = v & 0x7fff if v & 0x8000 != 0 else ~v
	for &x in s do x = v
	return
}

// DWAA and DWAB (DreamWorks Animation's lossy coding): the chunk opens with eleven sizes
// and, from version 2, the rules that sorted its channels. R, G and B (and Y, and a layer's
// own R, G and B) were turned perceptually even, R, G and B into Y'CbCr, each 8 x 8 block
// into its cosine transform, quantised and stored as halves: the first terms of all blocks
// together (zipped as ZIP stores a chunk), the rest run-length coded and then Huffman
// coded as PIZ codes or zipped. Alpha's bytes are run-length coded and zipped, and every
// other channel zipped as it is.
@(private = "file")
Exr_Dwa :: struct {
	ac, dc:     []u16,
	unknown:    []u8,
	rle:        []u8,
	packed_rle: []u8,
	plain:      []u8,
	to_linear:  []u16,
	scheme:     []u8,
}

@(private = "file")
DWA_UNKNOWN :: 0
@(private = "file")
DWA_DCT :: 1
@(private = "file")
DWA_RLE :: 2

// A rule: channels whose name ends `suffix` (after any layer's dot) and of type `kind` are
// stored by `scheme`; `csc` says which of R, G and B it is (-1 none).
@(private = "file")
Dwa_Rule :: struct {
	suffix: string,
	scheme: u8,
	kind:   i32,
	csc:    int,
	nocase: bool,
}

// The rules files before version 2 were written with (later ones carry their own).
@(private = "file")
DWA_LEGACY_RULES := [?]Dwa_Rule {
	{"r", DWA_DCT, 1, 0, true}, {"r", DWA_DCT, 2, 0, true}, {"red", DWA_DCT, 1, 0, true}, {"red", DWA_DCT, 2, 0, true},
	{"g", DWA_DCT, 1, 1, true}, {"g", DWA_DCT, 2, 1, true}, {"grn", DWA_DCT, 1, 1, true}, {"grn", DWA_DCT, 2, 1, true},
	{"green", DWA_DCT, 1, 1, true}, {"green", DWA_DCT, 2, 1, true},
	{"b", DWA_DCT, 1, 2, true}, {"b", DWA_DCT, 2, 2, true}, {"blu", DWA_DCT, 1, 2, true}, {"blu", DWA_DCT, 2, 2, true},
	{"blue", DWA_DCT, 1, 2, true}, {"blue", DWA_DCT, 2, 2, true},
	{"y", DWA_DCT, 1, -1, true}, {"y", DWA_DCT, 2, -1, true}, {"by", DWA_DCT, 1, -1, true}, {"by", DWA_DCT, 2, -1, true},
	{"ry", DWA_DCT, 1, -1, true}, {"ry", DWA_DCT, 2, -1, true},
	{"a", DWA_RLE, 0, -1, true}, {"a", DWA_RLE, 1, -1, true}, {"a", DWA_RLE, 2, -1, true},
}

@(private = "file")
exr_dwa :: proc(d: ^Exr_Decoder, packed, out: []u8, width, lines: int) -> string {
	DAMAGED :: "a DWA chunk is damaged"
	HEAD :: 11 * 8
	w := &d.dwa
	if len(packed) < HEAD do return DAMAGED
	sizes: [11]u64
	for &s, i in sizes do s = endian.unchecked_get_u64le(packed[8 * i:])
	version := sizes[0]
	unknown_size, unknown_packed := sizes[1], sizes[2]
	ac_packed, dc_packed := sizes[3], sizes[4]
	rle_packed, rle_size, rle_raw := sizes[5], sizes[6], sizes[7]
	ac_count, dc_count := sizes[8], sizes[9]
	ac_coding := sizes[10]
	limit := u64(len(packed))
	for s in sizes[1:10] do if s > limit * 64 + u64(len(out)) do return DAMAGED
	if version > 2 do return "a DWA chunk is of a version not read"
	at := HEAD
	rules := DWA_LEGACY_RULES[:]
	if version >= 2 {
		if at + 2 > len(packed) do return DAMAGED
		size := int(endian.unchecked_get_u16le(packed[at:]))
		if size < 2 || at + size > len(packed) do return DAMAGED
		list := make([dynamic]Dwa_Rule, 0, 16, context.temp_allocator)
		r := packed[at + 2:][:size - 2]
		at += size
		for len(r) > 0 {
			end := -1
			for b, i in r do if b == 0 {end = i; break}
			if end < 0 || end > 128 || end + 3 > len(r) do return DAMAGED
			value, kind := r[end + 1], r[end + 2]
			csc := int(value >> 4) - 1
			if csc > 2 || (value >> 2) & 3 > 2 || kind > 2 do return DAMAGED
			append(&list, Dwa_Rule{suffix = string(r[:end]), scheme = (value >> 2) & 3, kind = i32(kind), csc = csc, nocase = value & 1 != 0})
			r = r[end + 3:]
		}
		rules = list[:]
	}
	if unknown_packed + ac_packed + dc_packed + rle_packed > u64(len(packed) - at) do return DAMAGED
	// Each channel takes the scheme of the last rule it matches; channels of one layer that
	// are its R, G and B form a set coded together.
	n := len(d.channels)
	if len(w.scheme) < n do w.scheme = make([]u8, n, context.temp_allocator)
	scheme := w.scheme[:n]
	Set :: struct {
		prefix: string,
		idx:    [3]int,
	}
	sets := make([dynamic]Set, 0, n, context.temp_allocator)
	for c, ci in d.channels {
		dot := strings.last_index_byte(c.name, '.')
		prefix, suffix := c.name[:dot + 1], c.name[dot + 1:]
		set := -1
		for s, si in sets do if s.prefix == prefix {set = si; break}
		if set < 0 {
			append(&sets, Set{prefix = prefix, idx = {-1, -1, -1}})
			set = len(sets) - 1
		}
		scheme[ci] = DWA_UNKNOWN
		for rule in rules {
			if rule.kind != c.kind do continue
			if !(rule.suffix == suffix || (rule.nocase && strings.equal_fold(rule.suffix, suffix))) do continue
			scheme[ci] = rule.scheme
			if rule.csc >= 0 do sets[set].idx[rule.csc] = ci
		}
	}
	// What each scheme's channels hold uncoded, which the sizes must cover.
	need: [3]u64
	for c, ci in d.channels do need[scheme[ci]] += u64(width * lines * c.size)
	if (need[DWA_UNKNOWN] > 0) != (unknown_packed > 0) || unknown_size < need[DWA_UNKNOWN] || unknown_size > u64(len(out)) do return DAMAGED
	if (need[DWA_RLE] > 0) != (rle_packed > 0) || rle_raw < need[DWA_RLE] || rle_raw > u64(len(out)) || rle_size > u64(len(out)) * 2 + 64 do return DAMAGED
	if ac_count > u64(len(out)) || dc_count > u64(len(out)) do return DAMAGED
	stream := packed[at:]
	unknown_in := stream[:unknown_packed]
	ac_in := stream[unknown_packed:][:ac_packed]
	dc_in := stream[unknown_packed + ac_packed:][:dc_packed]
	rle_in := stream[unknown_packed + ac_packed + dc_packed:][:rle_packed]
	grow :: proc(b: ^[]$T, n: int) -> []T {
		if len(b^) < n do b^ = make([]T, n, context.temp_allocator)
		return b^[:n]
	}
	unknown := grow(&w.unknown, int(unknown_size))
	if unknown_packed > 0 {
		if why := exr_inflate(&d.inflated, unknown_in, unknown); why != "" do return why
	}
	ac := grow(&w.ac, int(ac_count))
	if ac_packed > 0 {
		switch ac_coding {
		case 0:
			if d.piz.lut == nil do exr_piz_tables(&d.piz)
			if why := huf_uncompress(&d.piz, ac_in, ac); why != "" do return DAMAGED
		case 1:
			bytes_out := grow(&w.packed_rle, 2 * len(ac))
			if why := exr_inflate(&d.inflated, ac_in, bytes_out); why != "" do return why
			for &v, i in ac do v = endian.unchecked_get_u16le(bytes_out[2 * i:])
		case:
			return DAMAGED
		}
	}
	dc := grow(&w.dc, int(dc_count))
	if dc_packed > 0 {
		zipped := grow(&w.packed_rle, 2 * len(dc))
		if why := exr_inflate(&d.inflated, dc_in, zipped); why != "" do return why
		plain := grow(&w.plain, 2 * len(dc))
		exr_unpredict(zipped, plain)
		for &v, i in dc do v = endian.unchecked_get_u16le(plain[2 * i:])
	} else if dc_count != 0 do return DAMAGED
	rle := grow(&w.rle, int(rle_raw))
	if rle_raw > 0 {
		runs := grow(&w.packed_rle, int(rle_size))
		if why := exr_inflate(&d.inflated, rle_in, runs); why != "" do return why
		if exr_rle(runs, rle) != "" do return DAMAGED
	}
	if w.to_linear == nil {
		sync.once_do(&dwa_table_once, dwa_to_linear_fill)
		w.to_linear = dwa_table[:]
	}
	// Where channel `c`'s row `y` starts in `out`.
	row_bytes := 0
	for c in d.channels do row_bytes += width * c.size
	starts := make([]int, n, context.temp_allocator)
	s := 0
	for c, ci in d.channels {
		starts[ci] = s
		s += width * c.size
	}
	done := make([]bool, n, context.temp_allocator)
	ac_at, dc_at := 0, 0
	for &set in sets {
		if set.idx[0] < 0 || set.idx[1] < 0 || set.idx[2] < 0 do continue
		for k in set.idx do if scheme[k] != DWA_DCT do return DAMAGED
		if !dwa_dct(d, out, set.idx[:], starts, row_bytes, ac, dc, &ac_at, &dc_at, w.to_linear, width, lines) do return DAMAGED
		for k in set.idx do done[k] = true
	}
	unknown_at, rle_at := 0, 0
	for c, ci in d.channels {
		if done[ci] do continue
		switch scheme[ci] {
		case DWA_DCT:
			idx := [1]int{ci}
			if !dwa_dct(d, out, idx[:], starts, row_bytes, ac, dc, &ac_at, &dc_at, nil if c.linear else w.to_linear, width, lines) do return DAMAGED
		case DWA_RLE:
			// Its bytes as planes, the first byte of every sample, then the second, and so on.
			plane := width * lines
			for y in 0 ..< lines {
				row := out[y * row_bytes + starts[ci]:][:width * c.size]
				for x in 0 ..< width do for b in 0 ..< c.size do row[x * c.size + b] = rle[rle_at + b * plane + y * width + x]
			}
			rle_at += plane * c.size
		case:
			for y in 0 ..< lines {
				copy(out[y * row_bytes + starts[ci]:][:width * c.size], unknown[unknown_at:][:width * c.size])
				unknown_at += width * c.size
			}
		}
	}
	return ""
}

// The table from DWA's perceptually even halves back to linear light: x^2.2 up to 1 and
// e^(2.2 (x - 1)) past it, so the two meet smoothly; infinities and NaNs read as nothing.
// Worked in double precision and rounded to a float, which is the correctly rounded powf
// the reference tables were made with. Made once, on the first DWA file, and shared by
// every decode after (it never changes, and the once guards the threads).
@(private = "file")
dwa_table: [1 << 16]u16
@(private = "file")
dwa_table_once: sync.Once

@(private = "file")
dwa_to_linear_fill :: proc() {
	for &v, i in dwa_table {
		x := u16(i)
		if x == 0 || x & 0x7c00 == 0x7c00 do continue
		f := f32(transmute(f16)x)
		sign: f32 = -1 if f < 0 else 1
		f = abs(f)
		z := f32(math.pow(f64(f), f64(f32(2.2)))) if f <= 1 else f32(math.pow(f64(f32(9.02501329156)), f64(f - 1)))
		v = transmute(u16)f16(sign * z)
	}
}

// Decodes one DWA set (R, G and B coded together as Y'CbCr) or one channel alone into
// `out`; false when its terms run out. Each block's first terms come one a channel from
// `dc`, all of a channel's blocks together; the rest of each block follows in `ac` in
// zig-zag order, a high byte of 0xff a run of that many zeros (0xff00 the block's end).
@(private = "file")
dwa_dct :: proc(d: ^Exr_Decoder, out: []u8, chans: []int, starts: []int, row_bytes: int, ac, dc: []u16, ac_at, dc_at: ^int, to_linear: []u16, width, lines: int) -> bool {
	// The reference's constants: half cosines of multiples of pi / 16, with pi as 3.14159
	// and each worked in single precision, kept as their bits so every build agrees.
	A :: 0x3eb504fb
	B :: 0x3efb14bf
	C :: 0x3eec8361
	D :: 0x3ed4db36
	E :: 0x3e8e39e5
	F :: 0x3e43ef33
	G :: 0x3dc7c60b
	DC_ONLY :: 0x3eb504fa
	ZIGZAG :: [64]u8 {
		0, 1, 5, 6, 14, 15, 27, 28, 2, 4, 7, 13, 16, 26, 29, 42,
		3, 8, 12, 17, 25, 30, 41, 43, 9, 11, 18, 24, 31, 40, 44, 53,
		10, 19, 23, 32, 39, 45, 52, 54, 20, 22, 33, 38, 46, 51, 55, 60,
		21, 34, 37, 47, 50, 56, 59, 61, 35, 36, 48, 49, 57, 58, 62, 63,
	}
	zz := ZIGZAG
	comps := len(chans)
	bx_n, by_n := (width + 7) / 8, (lines + 7) / 8
	if dc_at^ + comps * bx_n * by_n > len(dc) do return false
	dcs: [3]int
	for k in 0 ..< comps do dcs[k] = dc_at^ + k * bx_n * by_n
	dc_at^ += comps * bx_n * by_n
	blocks := make([]u16, comps * bx_n * 64, context.temp_allocator)
	for by in 0 ..< by_n {
		for bx in 0 ..< bx_n {
			data: [3][64]f32
			for k in 0 ..< comps {
				zig: [64]u16
				zig[0] = dc[dcs[k]]
				dcs[k] += 1
				last := 0
				for i := 1; i < 64; {
					if ac_at^ >= len(ac) do return false
					v := ac[ac_at^]
					ac_at^ += 1
					if v & 0xff00 == 0xff00 {
						run := int(v & 0xff)
						i += 64 if run == 0 else run
					} else {
						zig[i] = v
						last = i
						i += 1
					}
				}
				if last == 0 {
					v := f32(transmute(f16)zig[0]) * transmute(f32)u32(DC_ONLY) * transmute(f32)u32(DC_ONLY)
					for &x in data[k] do x = v
				} else {
					for i in 0 ..< 64 do data[k][i] = f32(transmute(f16)zig[zz[i]])
					dct_inverse(&data[k], transmute(f32)u32(A), transmute(f32)u32(B), transmute(f32)u32(C), transmute(f32)u32(D), transmute(f32)u32(E), transmute(f32)u32(F), transmute(f32)u32(G))
				}
			}
			if comps == 3 {
				for i in 0 ..< 64 {
					y, cb, cr := data[0][i], data[1][i], data[2][i]
					data[0][i] = y + 1.5747 * cr
					data[1][i] = y - 0.1873 * cb - 0.4682 * cr
					data[2][i] = y + 1.8556 * cb
				}
			}
			for k in 0 ..< comps do for i in 0 ..< 64 do blocks[(k * bx_n + bx) * 64 + i] = transmute(u16)f16(data[k][i])
		}
		// Unblock the band of rows into each channel, back to linear light.
		for k in 0 ..< comps {
			c := d.channels[chans[k]]
			for y in by * 8 ..< min(by * 8 + 8, lines) {
				row := out[y * row_bytes + starts[chans[k]]:]
				for x in 0 ..< width {
					v := blocks[(k * bx_n + x / 8) * 64 + (y % 8) * 8 + x % 8]
					if to_linear != nil do v = to_linear[v]
					if c.kind == 2 do endian.unchecked_put_u32le(row[4 * x:], transmute(u32)f32(transmute(f16)v))
					else do endian.unchecked_put_u16le(row[2 * x:], v)
				}
			}
		}
	}
	return true
}

// The reference's inverse 8 x 8 cosine transform in place: rows, then columns, each as
// even and odd halves.
@(private = "file")
dct_inverse :: proc(data: ^[64]f32, a, b, c, d, e, f, g: f32) {
	one :: #force_inline proc(p: [8]f32, a, b, c, d, e, f, g: f32) -> (o: [8]f32) {
		alpha := [4]f32{c * p[2], f * p[2], c * p[6], f * p[6]}
		beta := [4]f32 {
			b * p[1] + d * p[3] + e * p[5] + g * p[7],
			d * p[1] - g * p[3] - b * p[5] - e * p[7],
			e * p[1] - b * p[3] + g * p[5] + d * p[7],
			g * p[1] - e * p[3] + d * p[5] - b * p[7],
		}
		theta := [4]f32{a * (p[0] + p[4]), alpha[0] + alpha[3], alpha[1] - alpha[2], a * (p[0] - p[4])}
		gamma := [4]f32{theta[0] + theta[1], theta[3] + theta[2], theta[3] - theta[2], theta[0] - theta[1]}
		return {
			gamma[0] + beta[0], gamma[1] + beta[1], gamma[2] + beta[2], gamma[3] + beta[3],
			gamma[3] - beta[3], gamma[2] - beta[2], gamma[1] - beta[1], gamma[0] - beta[0],
		}
	}
	for r in 0 ..< 8 {
		row: [8]f32
		for i in 0 ..< 8 do row[i] = data[r * 8 + i]
		row = one(row, a, b, c, d, e, f, g)
		for i in 0 ..< 8 do data[r * 8 + i] = row[i]
	}
	for col in 0 ..< 8 {
		p: [8]f32
		for i in 0 ..< 8 do p[i] = data[i * 8 + col]
		p = one(p, a, b, c, d, e, f, g)
		for i in 0 ..< 8 do data[i * 8 + col] = p[i]
	}
}
