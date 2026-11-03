package geom

import "core:encoding/endian"
import "core:math"

// NVIDIA's displacement micro-map container (`.bary`, version 100), as its reference
// library (NVIDIAGameWorks/Displacement-MicroMap-BaryFile, Apache-2.0) lays it out: a
// header, an array of property records, then each property's bytes 4-byte aligned. A
// micro-map gives each base triangle a grid of 2^level segments along each edge and one
// scalar per grid vertex; the displaced point is
//     interpolated(position) + interpolated(direction) * (bias + scale * value),
// with no normalising of the interpolated direction. The values are written
// uncompressed, 11 bits in 16 (the precision the hardware's compressed blocks hold), in
// the bird-curve order the compressed formats and NVIDIA's tools take, with the mesh's
// positions, triangles and directions beside them so the file stands alone.

// The scalars of a micro-mapped mesh: `values` holds bary_vertex_count(level) per
// triangle, triangle after triangle, each triangle's in bird-curve order
// (bary_bird_index), the vertex at (u, v) being at
//     (1 - u - v) * corner 0 + u * corner 1 + v * corner 2   (u, v in segments / 2^level).
Bary_Mesh :: struct {
	positions:  []Vec3,
	directions: []Vec3,
	indices:    []u32,
	level:      u32,
	values:     []f32,
}

// The file's first sixteen bytes, its version 100.
BARY_VERSION := [16]u8{0xAB, 'B', 'A', 'R', 'Y', ' ', '0', '0', '1', '0', '0', 0xBB, '\r', '\n', 0x1A, '\n'}

// The finest level written: 2^5 segments, the finest the compressed blocks go to.
BARY_LEVEL_MAX :: 5

// The reference library's formats (Vulkan's numbers) and enums this writer uses.
@(private = "file")
BARY_FORMAT_R11_UNORM_PACK16 :: 1000397001
@(private = "file")
BARY_FORMAT_RGB32_SFLOAT :: 106
@(private = "file")
BARY_FORMAT_R32_UINT :: 98
@(private = "file")
BARY_LAYOUT_BIRD_CURVE :: 2
@(private = "file")
BARY_PER_VERTEX :: 1

// Each property's UUID, as four 32-bit words.
@(private = "file")
Bary_Property :: enum {
	Values,
	Groups,
	Triangles,
	Histogram,
	Group_Histograms,
	Directions,
	Positions,
	Indices,
}

@(private = "file", rodata)
BARY_IDS := [Bary_Property][4]u32 {
	.Values           = {0xb44daa04, 0xc9e044d5, 0x9a944de0, 0xcfd8fe35},
	.Groups           = {0x39ee40d0, 0x9dc44517, 0x8e5ab15d, 0xb09c74bc},
	.Triangles        = {0x00458e68, 0xee59426c, 0xb3bf1b7f, 0x749deb8e},
	.Histogram        = {0x6e756bc1, 0x839a438a, 0xad4a745e, 0x556c3851},
	.Group_Histograms = {0x400d972f, 0x76dd4337, 0x9900c6e9, 0xc9c46ffe},
	.Directions       = {0xf262d687, 0xb9284aeb, 0xa706803c, 0xcbedae52},
	.Positions        = {0xac071cfe, 0xc01d430d, 0x936ff822, 0xa2d6b48e},
	.Indices          = {0x48f106db, 0x1daf410f, 0x8cf1c35c, 0x69559309},
}

// Header: version, total size, the property records' range.
@(private = "file")
BARY_HEADER_SIZE :: 16 + 8 + 16
// Property record: id, range, scheme (with its padding), uncompressed length, global data.
@(private = "file")
BARY_RECORD_SIZE :: 16 + 16 + 8 + 8 + 16

// The grid vertices of a triangle at `level`: (2^level + 1)(2^level + 2) / 2.
bary_vertex_count :: proc(level: u32) -> int {
	s := 1 << level
	return (s + 1) * (s + 2) / 2
}

// Where the grid vertex at (u, v) of a triangle at `level` is in the bird-curve order:
// the three corners, then each level's new vertices, the midpoints of the edges of the
// level above's triangles, triangle by triangle along the curve. The reference
// library's bird_getMicroVertexIndex.
bary_bird_index :: proc(u, v, level: u32) -> u32 {
	w := (u32(1) << level) - u - v
	// The level the vertex first appears on: where its coordinates' lowest set bit is.
	on := u32(0)
	if w != u32(1) << level && u != u32(1) << level && v != u32(1) << level {
		low := w | u | v
		shift := u32(0)
		for shift < level && low & (u32(1) << shift) == 0 do shift += 1
		on = level - shift
	}
	down := level - on
	bw, bu, bv := w >> down, u >> down, v >> down
	if on == 0 {
		return 0 if bw != 0 else (1 if bu != 0 else 2)
	}
	// Among that level's vertices: the triangle of the level above it splits, then which
	// of its three edges it is the middle of.
	qu, qv, qw := bu & ~u32(1), bv & ~u32(1), bw & ~u32(1)
	edge := u32(0) if bu & 1 == 0 else (1 if bv & 1 == 1 else 2)
	index := bird_triplet(qu, qv, qw, on) * 3 + edge
	return index + u32(bary_vertex_count(on - 1))
}

// The reference library's bird_getTripletIndex: the place along the bird curve of the
// triangle whose corner coordinates (each even) are u, v, w, at `level`.
@(private = "file")
bird_triplet :: proc(u, v, w, level: u32) -> u32 {
	mask := (u32(1) << level) - 1
	b0 := ~(u ~ w) & mask
	t := (u ~ v) & b0
	c := (((u & v & w) | (~u & ~v & ~w)) & mask) << 16
	f := prefix_xor2(t | c) ~ u
	b1 := (f & ~b0) | t
	dist := interleave2(b0, b1)
	f >>= 16
	b0 <<= 1
	return (dist + (b0 & ~f) - (b0 & f)) >> 3

	prefix_xor2 :: proc(x: u32) -> u32 {
		x := x
		x ~= (x >> 1) & 0x7fff7fff
		x ~= (x >> 2) & 0x3fff3fff
		x ~= (x >> 4) & 0x0fff0fff
		x ~= (x >> 8) & 0x00ff00ff
		return x
	}
	interleave2 :: proc(a, b: u32) -> u32 {
		x := (a & 0xffff) | (b << 16)
		x = ((x >> 8) & 0x0000ff00) | ((x << 8) & 0x00ff0000) | (x & 0xff0000ff)
		x = ((x >> 4) & 0x00f000f0) | ((x << 4) & 0x0f000f00) | (x & 0xf00ff00f)
		x = ((x >> 2) & 0x0c0c0c0c) | ((x << 2) & 0x30303030) | (x & 0xc3c3c3c3)
		x = ((x >> 1) & 0x22222222) | ((x << 1) & 0x44444444) | (x & 0x99999999)
		return x
	}
}

// The file for `m`, in `allocator`; nil when `m` does not hold what its level asks for.
// The values share one group, its bias the smallest and its scale their spread, each
// stored as the nearest of 2048 steps.
bary_encode :: proc(m: Bary_Mesh, allocator := context.allocator) -> []u8 {
	tris := len(m.indices) / 3
	per := bary_vertex_count(m.level)
	if m.level > BARY_LEVEL_MAX || tris == 0 || len(m.values) != tris * per || len(m.directions) != len(m.positions) do return nil
	lo, hi := f32(math.F32_MAX), f32(-math.F32_MAX)
	for v in m.values do lo, hi = min(lo, v), max(hi, v)
	scale := hi - lo if hi > lo else 1

	// Each property's bytes, in the order the records list them.
	parts: [Bary_Property][dynamic]u8
	defer for &p in parts do delete(p)
	u32s :: proc(b: ^[dynamic]u8, values: ..u32) {
		for v in values {
			at := len(b)
			resize(b, at + 4)
			endian.unchecked_put_u32le(b[at:], v)
		}
	}
	f32s :: proc(b: ^[dynamic]u8, values: ..f32) {
		for v in values do u32s(b, transmute(u32)v)
	}
	// Values: format, layout, frequency, count, byte size 2, alignment 4, then the values.
	values := &parts[.Values]
	u32s(values, BARY_FORMAT_R11_UNORM_PACK16, BARY_LAYOUT_BIRD_CURVE, BARY_PER_VERTEX, u32(len(m.values)), 2, 4)
	resize(values, len(values) + 2 * len(m.values))
	for v, i in m.values {
		q := u16(clamp((v - lo) / scale * 2047 + 0.5, 0, 2047))
		endian.unchecked_put_u16le(values[24 + 2 * i:], q)
	}
	// One group: every triangle and value, the level, then bias and scale (four floats each).
	u32s(&parts[.Groups], 0, u32(tris), 0, u32(len(m.values)), m.level, m.level)
	f32s(&parts[.Groups], lo, 0, 0, 0, scale, 0, 0, 0)
	// Triangles: where each one's values start, its level, and no block format.
	for t in 0 ..< tris do u32s(&parts[.Triangles], u32(t * per), m.level)
	// The histogram: every triangle at one level and no block format, all in the group.
	u32s(&parts[.Histogram], u32(tris), m.level, 0)
	u32s(&parts[.Group_Histograms], 0, 1)
	// The mesh: directions and positions as three floats each, triangles as three indices.
	element_info :: proc(b: ^[dynamic]u8, format, count, size: u32) {u32s(b, format, count, size, 4)}
	element_info(&parts[.Directions], BARY_FORMAT_RGB32_SFLOAT, u32(len(m.directions)), 12)
	for d in m.directions do f32s(&parts[.Directions], d.x, d.y, d.z)
	element_info(&parts[.Positions], BARY_FORMAT_RGB32_SFLOAT, u32(len(m.positions)), 12)
	for p in m.positions do f32s(&parts[.Positions], p.x, p.y, p.z)
	element_info(&parts[.Indices], BARY_FORMAT_R32_UINT, u32(len(m.indices)), 4)
	u32s(&parts[.Indices], ..m.indices)

	// Each property starts 4-byte aligned; the gap before one is zeros.
	align4 :: proc(n: int) -> int {return (n + 3) &~ 3}
	total := BARY_HEADER_SIZE + BARY_RECORD_SIZE * len(Bary_Property)
	for p in parts do total = align4(total) + len(p)
	out := make([]u8, total, allocator)
	copy(out, BARY_VERSION[:])
	endian.unchecked_put_u64le(out[16:], u64(total))
	endian.unchecked_put_u64le(out[24:], BARY_HEADER_SIZE)
	endian.unchecked_put_u64le(out[32:], u64(BARY_RECORD_SIZE * len(Bary_Property)))
	at := BARY_HEADER_SIZE + BARY_RECORD_SIZE * len(Bary_Property)
	for p, k in parts {
		at = align4(at)
		r := out[BARY_HEADER_SIZE + BARY_RECORD_SIZE * int(k):]
		for word, i in BARY_IDS[k] do endian.unchecked_put_u32le(r[4 * i:], word)
		endian.unchecked_put_u64le(r[16:], u64(at))
		endian.unchecked_put_u64le(r[24:], u64(len(p)))
		// No supercompression: the scheme, the uncompressed length and the global data are 0.
		copy(out[at:], p[:])
		at += len(p)
	}
	return out
}
