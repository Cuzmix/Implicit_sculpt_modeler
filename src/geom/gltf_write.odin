package geom

import "core:encoding/endian"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

import "../jobs"

// Binary glTF 2.0 (.glb) out: one mesh in one node in one scene, with positions,
// normals, optional vertex colours, triangles and morph targets, and a primitive for each
// material its triangles use (all sharing the vertices and targets). The JSON is written by
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
	name:            string,
	positions:       []Vec3,
	normals:         []Vec3,
	indices:         []u32,
	colors:          [][3]u8,
	morphs:          []Morph_Target,
	scale:           f32, // the file's units: positions become scale * p + offset, deltas scale * d
	offset:          Vec3,
	// USD only (usd_write.odin): the faces as quads in place of `indices` (a retopologized
	// base level), their UVs a corner at a time, and each face's polygroup; nil for none.
	quads:           [][4]u32,
	uvs:             [][4][2]f32,
	groups:          []u16,
	// The surface it is shaded with, or nil for none: glTF's material, a UsdPreviewSurface
	// in USD. With colours the colours are the surface's colour and `base` multiplies
	// them, as both formats take vertex colours.
	material:        Maybe(Export_Material),
	// More surfaces for some faces (polygroup materials), with `material` set: each written
	// face's (a triangle of `indices`, or a quad) is face_material[f], 0 for `material` and
	// k for group_materials[k - 1]; nil for all `material`. glTF writes a primitive for each
	// used, USD a GeomSubset.
	group_materials: []Export_Material,
	face_material:   []u8,
	// USD only: `colors` are one a face corner (faceVarying, in the order of `indices` or
	// of the quads' corners) rather than one a vertex, as paint over the materials of two
	// faces meeting at a vertex can differ there.
	corner_colors:   bool,
}

// The material slot of written face `f` of `m`: 0 for its `material`, k for
// group_materials[k - 1], and 0 for a number past them.
export_face_slot :: proc(m: Mesh_Export, f: int) -> int {
	if m.face_material == nil do return 0
	s := int(m.face_material[f])
	return s if s <= len(m.group_materials) else 0
}

// Gives each material slot of `m`'s triangles vertices of their own: a vertex that faces
// of two slots share is copied for the later slot (in triangle order), with its normal and
// its movement in each morph, and those faces use the copy. glTF needs that for paint over
// the materials, whose colour at a seam differs on its two sides. Returns, per vertex of
// the new mesh, the vertex it came from and its slot (0 for one no triangle uses); the
// new arrays, and `m`'s colours copied over to them, are made with `allocator`.
mesh_export_split_materials :: proc(m: ^Mesh_Export, allocator := context.temp_allocator) -> (from: []u32, slot: []u8) {
	assert(m.quads == nil)
	n := len(m.positions)
	NONE :: max(u8)
	owner := make([]u8, n, context.temp_allocator)
	slice.fill(owner, NONE)
	// The copy of each (vertex, slot) made so far, looked up only, so its order decides
	// nothing.
	copies := make(map[u64]u32, 64, context.temp_allocator)
	extra := make([dynamic]u32, 0, 64, context.temp_allocator)
	extra_slot := make([dynamic]u8, 0, 64, context.temp_allocator)
	indices := make([]u32, len(m.indices), allocator)
	for f in 0 ..< len(m.indices) / 3 {
		s := u8(export_face_slot(m^, f))
		for c in 0 ..< 3 {
			v := m.indices[3 * f + c]
			if owner[v] == NONE do owner[v] = s
			if owner[v] == s {
				indices[3 * f + c] = v
				continue
			}
			key := u64(v) << 8 | u64(s)
			w, ok := copies[key]
			if !ok {
				w = u32(n + len(extra))
				copies[key] = w
				append(&extra, v)
				append(&extra_slot, s)
			}
			indices[3 * f + c] = w
		}
	}
	total := n + len(extra)
	from = make([]u32, total, allocator)
	slot = make([]u8, total, allocator)
	for v in 0 ..< n {
		from[v] = u32(v)
		slot[v] = owner[v] if owner[v] != NONE else 0
	}
	for e, k in extra do from[n + k], slot[n + k] = e, extra_slot[k]
	m.indices = indices
	if len(extra) == 0 do return
	positions := make([]Vec3, total, allocator)
	normals := make([]Vec3, total, allocator)
	for v, k in from do positions[k], normals[k] = m.positions[v], m.normals[v]
	m.positions, m.normals = positions, normals
	if m.colors != nil {
		colors := make([][3]u8, total, allocator)
		for v, k in from do colors[k] = m.colors[v]
		m.colors = colors
	}
	// The copies come after every vertex and in order, so each morph's vertices still rise.
	morphs := make([]Morph_Target, len(m.morphs), allocator)
	for t, k in m.morphs {
		vertices := make([dynamic]u32, 0, len(t.vertices), allocator)
		deltas := make([dynamic]Vec3, 0, len(t.deltas), allocator)
		append(&vertices, ..t.vertices)
		append(&deltas, ..t.deltas)
		for e, c in extra {
			if i, found := slice.binary_search(t.vertices, e); found {
				append(&vertices, u32(n + c))
				append(&deltas, t.deltas[i])
			}
		}
		morphs[k] = {t.name, t.weight, vertices[:], deltas[:]}
	}
	m.morphs = morphs
	return
}

// A surface in glTF's metallic-roughness terms, which USD's UsdPreviewSurface shares.
// `base` is linear, 0 to 1 each.
Export_Material :: struct {
	name:      string,
	base:      [3]f32,
	metallic:  f32,
	roughness: f32,
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
	g.prims = glb_primitives(m)

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
	prims:                                                   []Glb_Prim,
	range_bounds:                                            [][2]Vec3,
	linear:                                                  [256]u16,
}

// A primitive: the triangles of material slot `slot`, a run of `count` indices from
// `first` in the indices view, which holds the slots' runs one after another.
@(private = "file")
Glb_Prim :: struct {
	slot, first, count: int,
}

// The primitives of `m`, one a used slot in slot order; one with every triangle when it
// has no face materials, and one with none for a mesh with no triangles, as a glTF mesh
// has at least one primitive.
@(private = "file")
glb_primitives :: proc(m: Mesh_Export) -> []Glb_Prim {
	prims := make([dynamic]Glb_Prim, 0, 1 + len(m.group_materials), context.temp_allocator)
	if m.face_material == nil {
		append(&prims, Glb_Prim{0, 0, len(m.indices)})
		return prims[:]
	}
	counts := make([]int, 1 + len(m.group_materials), context.temp_allocator)
	for f in 0 ..< len(m.indices) / 3 do counts[export_face_slot(m, f)] += 3
	first := 0
	for c, slot in counts {
		if c == 0 do continue
		append(&prims, Glb_Prim{slot, first, c})
		first += c
	}
	if len(prims) == 0 do append(&prims, Glb_Prim{})
	return prims[:]
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
	if m.face_material != nil {
		// Each slot's triangles in their run, in the order they come.
		indices := glb_array(g, g.indices_view, u32)
		at := make([]int, 1 + len(m.group_materials), context.temp_allocator)
		for p in g.prims do at[p.slot] = p.first
		for f in 0 ..< len(m.indices) / 3 {
			slot := export_face_slot(m, f)
			copy(indices[at[slot]:][:3], m.indices[3 * f:][:3])
			at[slot] += 3
		}
	} else {
		jobs.parallel_ranges(pool, len(m.indices), g, proc(data: rawptr, lo, hi: int) {
			g := cast(^Glb)data
			copy(glb_array(g, g.indices_view, u32)[lo:hi], g.m.indices[lo:hi])
		}, RANGE_GRAIN)
	}
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
	// Accessors: 0 positions, 1 normals, then colours if any, then each primitive's
	// indices, then one per morph target.
	accessor := 2
	colors_accessor := -1
	if g.colors_view >= 0 {
		colors_accessor = accessor
		accessor += 1
	}
	indices_accessor := accessor
	accessor += len(g.prims)
	material, has_material := m.material.?
	strings.write_string(j, `,"primitives":[`)
	for p, k in g.prims {
		// Every primitive has the same targets, as the mesh's weights are for all of them.
		strings.write_string(j, `{"attributes":{"POSITION":0,"NORMAL":1` if k == 0 else `,{"attributes":{"POSITION":0,"NORMAL":1`)
		if colors_accessor >= 0 do fmt.sbprintf(j, `,"COLOR_0":%d`, colors_accessor)
		fmt.sbprintf(j, `}},"indices":%d,"mode":4`, indices_accessor + k)
		if has_material do fmt.sbprintf(j, `,"material":%d`, p.slot)
		if len(m.morphs) > 0 {
			strings.write_string(j, `,"targets":[`)
			for _, t in m.morphs do fmt.sbprintf(j, `%s{{"POSITION":%d}}`, "," if t > 0 else "", accessor + t)
			strings.write_byte(j, ']')
		}
		strings.write_byte(j, '}')
	}
	strings.write_byte(j, ']')
	if len(m.morphs) > 0 {
		strings.write_string(j, `,"weights":[`)
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
		strings.write_string(j, `]}`)
	}
	strings.write_string(j, `}]`)
	if has_material {
		strings.write_string(j, `,"materials":[`)
		glb_material(j, material)
		for gm in m.group_materials {
			strings.write_byte(j, ',')
			glb_material(j, gm)
		}
		strings.write_byte(j, ']')
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
	for p in g.prims {
		fmt.sbprintf(j, `,{{"bufferView":%d,`, g.indices_view)
		if p.first > 0 do fmt.sbprintf(j, `"byteOffset":%d,`, 4 * p.first)
		fmt.sbprintf(j, `"componentType":%d,"count":%d,"type":"SCALAR"}}`, GL_UNSIGNED_INT, p.count)
	}
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

// A material in the materials array.
@(private = "file")
glb_material :: proc(j: ^strings.Builder, mat: Export_Material) {
	strings.write_string(j, `{"name":`)
	json_string(j, mat.name)
	strings.write_string(j, `,"pbrMetallicRoughness":{"baseColorFactor":[`)
	for c in mat.base {
		json_number(j, clamp(c, 0, 1))
		strings.write_byte(j, ',')
	}
	strings.write_string(j, `1],"metallicFactor":`)
	json_number(j, clamp(mat.metallic, 0, 1))
	strings.write_string(j, `,"roughnessFactor":`)
	json_number(j, clamp(mat.roughness, 0, 1))
	strings.write_string(j, `}}`)
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
