package geom

import "core:encoding/endian"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

import "../jobs"

// Binary glTF 2.0 (.glb) out: one mesh in one node in one scene, with positions,
// normals, optional vertex colours, triangles and morph targets. The JSON is written by
// hand (its shape is small and fixed) and the binary chunk is laid out before anything is
// written, so the vertex arrays go straight into `out` without a second copy. Every
// buffer view starts on a 4-byte boundary, as the spec asks of vertex attributes.

// One morph target: how far some vertices move at weight 1. `vertices` increase and
// `deltas` match them; a target with no vertices moves nothing.
Morph_Target :: struct {
	name:     string,
	weight:   f32,
	vertices: []u32,
	deltas:   []Vec3,
}

// What a glTF or USD file carries beyond its triangles. `positions` are the surface as
// shown, with every morph at its weight; `colors` are sRGB, nil for none.
Mesh_Export :: struct {
	name:      string,
	positions: []Vec3,
	normals:   []Vec3,
	indices:   []u32,
	colors:    [][3]u8,
	morphs:    []Morph_Target,
	scale:     f32, // the file's units: positions become scale * p + offset, deltas scale * d
	offset:    Vec3,
	// USD only (usd_write.odin): the faces as quads in place of `indices` (a retopologized
	// base level), their UVs a corner at a time, and each face's polygroup; nil for none.
	quads:     [][4]u32,
	uvs:       [][4][2]f32,
	groups:    []u16,
}

// glTF's numbers for what the accessors and views hold.
@(private = "file")
GL_UNSIGNED_SHORT :: 5123
@(private = "file")
GL_UNSIGNED_INT :: 5125
@(private = "file")
GL_FLOAT :: 5126
@(private = "file")
GL_ARRAY_BUFFER :: 34962
@(private = "file")
GL_ELEMENT_ARRAY_BUFFER :: 34963

// Appends `m` as a .glb file, the big arrays through `pool` (nil: on this thread). The
// base positions written are the shown ones less each morph at its weight, so a reader
// that applies the weights rebuilds the shown surface (to f32 rounding). Colours are
// written linear, as glTF wants them. Returns false, having appended nothing, when the
// file would pass the 4 GB its header can count.
mesh_write_glb :: proc(out: ^[dynamic]u8, m: Mesh_Export, pool: ^jobs.Pool = nil) -> bool {
	n := len(m.positions)
	// The binary chunk's layout: positions, normals, colours, indices, then per morph its
	// sparse indices and values. Every size is a multiple of 4.
	g := Glb{m = m, scale = m.scale if m.scale != 0 else 1}
	g.views = make([dynamic]Glb_View, 0, 4 + 2 * len(m.morphs), context.temp_allocator)
	g.positions_view = glb_view(&g, 12 * n, GL_ARRAY_BUFFER)
	g.normals_view = glb_view(&g, 12 * n, GL_ARRAY_BUFFER)
	g.colors_view = glb_view(&g, 8 * n, GL_ARRAY_BUFFER) if m.colors != nil else -1
	g.indices_view = glb_view(&g, 4 * len(m.indices), GL_ELEMENT_ARRAY_BUFFER)
	g.morph_views = make([][2]int, len(m.morphs), context.temp_allocator)
	for t, k in m.morphs {
		g.morph_views[k] = {-1, -1}
		if len(t.vertices) > 0 do g.morph_views[k] = {glb_view(&g, 4 * len(t.vertices), 0), glb_view(&g, 12 * len(t.vertices), 0)}
	}
	g.bounds = make([][2]Vec3, 1 + len(m.morphs), context.temp_allocator)

	// The JSON chunk comes first but holds the bounds of what the binary chunk holds, so
	// it gets a slot as long as any bounds can make it (16 characters a number at most,
	// where 0 takes 1), the binary chunk is written straight into its place after it,
	// and the JSON then fills the slot, padded with spaces as the format pads it anyway.
	// That writes each big array once, into `out`, with no copy in between.
	j := strings.builder_make(context.temp_allocator)
	glb_json(&j, &g)
	slot := (len(j.buf) + 16 * 6 * len(g.bounds) + 3) &~ 3
	total := 12 + 8 + slot + 8 + g.bin_len
	if total > int(max(u32)) do return false
	start := len(out)
	non_zero_resize(out, start + total)
	file := out[start:]
	g.bin = file[12 + 8 + slot + 8:]
	glb_fill(&g, pool)
	strings.builder_reset(&j)
	glb_json(&j, &g)
	assert(len(j.buf) <= slot)
	copy(file[20:], j.buf[:])
	for &c in file[20 + len(j.buf):][:slot - len(j.buf)] do c = ' '
	put32 :: proc(b: []u8, at: int, x: u32) {endian.unchecked_put_u32le(b[at:], x)}
	put32(file, 0, 0x46546C67) // "glTF"
	put32(file, 4, 2)
	put32(file, 8, u32(total))
	put32(file, 12, u32(slot))
	put32(file, 16, 0x4E4F534A) // "JSON"
	put32(file, 20 + slot, u32(g.bin_len))
	put32(file, 24 + slot, 0x004E4942) // "BIN\0"
	return true
}

@(private = "file")
Glb_View :: struct {
	offset, length: int,
	target:         int,
}

// A .glb being written: where each array goes in the binary chunk and, once it is
// written, the bounds of the base positions (bounds[0]) and of each morph (bounds[1:]).
@(private = "file")
Glb :: struct {
	m:                                                       Mesh_Export,
	scale:                                                   f32,
	views:                                                   [dynamic]Glb_View,
	bin_len:                                                 int,
	positions_view, normals_view, colors_view, indices_view: int,
	morph_views:                                             [][2]int, // per morph: its sparse indices and values, -1 for none
	bounds:                                                  [][2]Vec3,
	bin:                                                     []u8,
	range_bounds:                                            [][2]Vec3,
	linear:                                                  [256]u16,
}

@(private = "file")
glb_view :: proc(g: ^Glb, length, target: int) -> int {
	append(&g.views, Glb_View{g.bin_len, length, target})
	g.bin_len += length
	return len(g.views) - 1
}

@(private = "file")
glb_array :: proc(g: ^Glb, view: int, $T: typeid) -> []T {
	v := g.views[view]
	return mem.slice_data_cast([]T, g.bin[v.offset:][:v.length])
}

// Writes the binary chunk and works out the bounds.
@(private = "file")
glb_fill :: proc(g: ^Glb, pool: ^jobs.Pool) {
	m := g.m
	n := len(m.positions)
	for &x, k in g.linear do x = u16(math.round(srgb_to_linear(f32(k) / 255) * 65535))
	// Positions in the file's units, normals, colours and indices, a range at a time.
	jobs.parallel_ranges(pool, n, g, proc(data: rawptr, lo, hi: int) {
		g := cast(^Glb)data
		m := g.m
		base := glb_array(g, g.positions_view, Vec3)
		if g.scale != 1 || m.offset != {} {
			for v in lo ..< hi do base[v] = m.positions[v] * g.scale + m.offset
		} else {
			copy(base[lo:hi], m.positions[lo:hi])
		}
		normals := glb_array(g, g.normals_view, Vec3)
		for v in lo ..< hi {
			// The spec wants unit normals; a vertex whose triangles have no area has none,
			// and gets one that points up.
			nr := m.normals[v]
			l := math.sqrt(nr.x * nr.x + nr.y * nr.y + nr.z * nr.z)
			normals[v] = nr / l if l > 1e-20 else {0, 1, 0}
		}
		if g.colors_view >= 0 {
			linear := glb_array(g, g.colors_view, [4]u16)
			for c, v in m.colors[lo:hi] do linear[lo + v] = {g.linear[c.r], g.linear[c.g], g.linear[c.b], 65535}
		}
	}, RANGE_GRAIN)
	jobs.parallel_ranges(pool, len(m.indices), g, proc(data: rawptr, lo, hi: int) {
		g := cast(^Glb)data
		copy(glb_array(g, g.indices_view, u32)[lo:hi], g.m.indices[lo:hi])
	}, RANGE_GRAIN)
	// The morphs come off the base one after another, as two may move one vertex.
	base := glb_array(g, g.positions_view, Vec3)
	for t in m.morphs {
		if t.weight == 0 do continue
		for v, i in t.vertices do base[v] -= t.weight * g.scale * t.deltas[i]
	}
	// The base's bounds, which the accessor's min and max must be, a range at a time.
	g.range_bounds = make([][2]Vec3, (n + RANGE_GRAIN - 1) / RANGE_GRAIN, context.temp_allocator)
	jobs.parallel_ranges(pool, n, g, proc(data: rawptr, lo, hi: int) {
		g := cast(^Glb)data
		b := [2]Vec3{AABB_EMPTY.lo, AABB_EMPTY.hi}
		for p in glb_array(g, g.positions_view, Vec3)[lo:hi] do b = {linalg.min(b[0], p), linalg.max(b[1], p)}
		g.range_bounds[lo / RANGE_GRAIN] = b
	}, RANGE_GRAIN)
	g.bounds[0] = {}
	if n > 0 do g.bounds[0] = {AABB_EMPTY.lo, AABB_EMPTY.hi}
	for b in g.range_bounds do g.bounds[0] = {linalg.min(g.bounds[0][0], b[0]), linalg.max(g.bounds[0][1], b[1])}
	for t, k in m.morphs {
		// A target that leaves any vertex where it is has 0 in its bounds as well.
		b := [2]Vec3{AABB_EMPTY.lo, AABB_EMPTY.hi}
		if len(t.vertices) < n do b = {}
		if views := g.morph_views[k]; views[0] >= 0 {
			copy(glb_array(g, views[0], u32), t.vertices)
			values := glb_array(g, views[1], Vec3)
			for d, i in t.deltas {
				values[i] = d * g.scale
				b = {linalg.min(b[0], values[i]), linalg.max(b[1], values[i])}
			}
		}
		g.bounds[1 + k] = b
	}
}

// The JSON chunk, with the bounds as they stand. fmt reads braces in a format, so the
// formats double them.
@(private = "file")
glb_json :: proc(j: ^strings.Builder, g: ^Glb) {
	m := g.m
	n := len(m.positions)
	strings.write_string(j, `{"asset":{"version":"2.0","generator":"Sculpt"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0,"name":`)
	json_string(j, m.name)
	strings.write_string(j, `}],"meshes":[{"name":`)
	json_string(j, m.name)
	// Accessors: 0 positions, 1 normals, then colours if any, then indices, then one per
	// morph target.
	accessor := 2
	colors_accessor := -1
	if g.colors_view >= 0 {
		colors_accessor = accessor
		accessor += 1
	}
	indices_accessor := accessor
	accessor += 1
	strings.write_string(j, `,"primitives":[{"attributes":{"POSITION":0,"NORMAL":1`)
	if colors_accessor >= 0 do fmt.sbprintf(j, `,"COLOR_0":%d`, colors_accessor)
	fmt.sbprintf(j, `}},"indices":%d,"mode":4`, indices_accessor)
	if len(m.morphs) > 0 {
		strings.write_string(j, `,"targets":[`)
		for _, k in m.morphs do fmt.sbprintf(j, `%s{{"POSITION":%d}}`, "," if k > 0 else "", accessor + k)
		strings.write_string(j, `]}],"weights":[`)
		for t, k in m.morphs {
			if k > 0 do strings.write_byte(j, ',')
			json_number(j, t.weight)
		}
		// Blender's importer and others name the targets from here.
		strings.write_string(j, `],"extras":{"targetNames":[`)
		for t, k in m.morphs {
			if k > 0 do strings.write_byte(j, ',')
			json_string(j, t.name)
		}
		strings.write_string(j, `]}}]`)
	} else {
		strings.write_string(j, `}]}]`)
	}
	fmt.sbprintf(j, `,"buffers":[{{"byteLength":%d}}],"bufferViews":[`, g.bin_len)
	for v, k in g.views {
		fmt.sbprintf(j, `%s{{"buffer":0,"byteOffset":%d,"byteLength":%d`, "," if k > 0 else "", v.offset, v.length)
		if v.target != 0 do fmt.sbprintf(j, `,"target":%d`, v.target)
		strings.write_byte(j, '}')
	}
	strings.write_string(j, `],"accessors":[`)
	fmt.sbprintf(j, `{{"bufferView":%d,"componentType":%d,"count":%d,"type":"VEC3",`, g.positions_view, GL_FLOAT, n)
	json_bounds(j, g.bounds[0])
	fmt.sbprintf(j, `}},{{"bufferView":%d,"componentType":%d,"count":%d,"type":"VEC3"}}`, g.normals_view, GL_FLOAT, n)
	if g.colors_view >= 0 do fmt.sbprintf(j, `,{{"bufferView":%d,"componentType":%d,"normalized":true,"count":%d,"type":"VEC4"}}`, g.colors_view, GL_UNSIGNED_SHORT, n)
	fmt.sbprintf(j, `,{{"bufferView":%d,"componentType":%d,"count":%d,"type":"SCALAR"}}`, g.indices_view, GL_UNSIGNED_INT, len(m.indices))
	for t, k in m.morphs {
		// A target is sparse: zeros but for the vertices it moves. One that moves none is
		// all zeros, which an accessor with no buffer view is.
		fmt.sbprintf(j, `,{{"componentType":%d,"count":%d,"type":"VEC3",`, GL_FLOAT, n)
		json_bounds(j, g.bounds[1 + k])
		if views := g.morph_views[k]; views[0] >= 0 {
			fmt.sbprintf(j, `,"sparse":{{"count":%d,"indices":{{"bufferView":%d,"componentType":%d}},"values":{{"bufferView":%d}}}}`, len(t.vertices), views[0], GL_UNSIGNED_INT, views[1])
		}
		strings.write_byte(j, '}')
	}
	strings.write_string(j, "]}")
}

// The linear value of an sRGB channel, both 0 to 1.
srgb_to_linear :: proc(c: f32) -> f32 {
	return c / 12.92 if c <= 0.04045 else math.pow((c + 0.055) / 1.055, 2.4)
}

// Writes `s` as a JSON string: quotes, backslashes and control characters escaped, and
// any bytes that are not UTF-8 (a name cut short mid-character) as U+FFFD.
@(private)
json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i := 0; i < len(s); {
		r, w := utf8.decode_rune_in_string(s[i:])
		switch {
		case r == utf8.RUNE_ERROR && w <= 1:
			strings.write_rune(b, utf8.RUNE_ERROR)
		case r == '"' || r == '\\':
			strings.write_byte(b, '\\')
			strings.write_byte(b, u8(r))
		case r < 0x20:
			fmt.sbprintf(b, `\u%04x`, int(r))
		case:
			strings.write_string(b, s[i:][:w])
		}
		i += max(w, 1)
	}
	strings.write_byte(b, '"')
}

// Nine significant digits, which read back as the same f32.
@(private = "file")
json_number :: proc(b: ^strings.Builder, x: f32) {
	tmp: [32]u8
	strings.write_bytes(b, tmp[:format_f32(tmp[:], x)])
}

// An accessor's "min" and "max".
@(private = "file")
json_bounds :: proc(b: ^strings.Builder, bounds: [2]Vec3) {
	for v, k in bounds {
		strings.write_string(b, `"min":[` if k == 0 else `,"max":[`)
		for x, i in v {
			if i > 0 do strings.write_byte(b, ',')
			json_number(b, x)
		}
		strings.write_byte(b, ']')
	}
}
