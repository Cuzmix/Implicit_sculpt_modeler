package geom

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strings"
import "core:unicode/utf8"

import "../jobs"

// USD text (.usda) out: one mesh under a root prim, in the form Blender's, Houdini's and
// Maya's importers read. Sculpt layers become blend shapes (each the vertices it moves and
// how far) bound to a skeleton without joints, whose animation gives their strengths;
// the weights are written both as the default and as a time sample at frame 1, since
// Blender's importer reads only time samples (it keys them in an action). Quads with UVs,
// polygroups and vertex colours go as primvars. The big arrays are written as text a
// range at a time on the pool, as the OBJ writer does.

// Appends `m` as a .usda file, the big arrays through `pool` (nil: on this thread). The
// points written are the shown ones less each blend shape at its weight, so a reader
// that applies the weights rebuilds the shown surface (to f32 rounding). Colours are
// written linear, as USD wants them.
mesh_write_usda :: proc(out: ^[dynamic]u8, m: Mesh_Export, pool: ^jobs.Pool = nil) {
	u := Usd{m = m, scale = m.scale if m.scale != 0 else 1, b = strings.builder_make(context.temp_allocator)}
	n := len(m.positions)
	for &x, k in u.linear do x = srgb_to_linear(f32(k) / 255)

	// The points: in the file's units, less each shape at its weight.
	u.base = make([]Vec3, n, context.temp_allocator)
	jobs.parallel_ranges(pool, n, &u, proc(data: rawptr, lo, hi: int) {
		u := cast(^Usd)data
		for v in lo ..< hi do u.base[v] = u.m.positions[v] * u.scale + u.m.offset
	}, RANGE_GRAIN)
	for t in m.morphs {
		if t.weight == 0 do continue
		for v, i in t.vertices do u.base[v] -= t.weight * u.scale * t.deltas[i]
	}
	// Room for about what the file takes, so the arrays land without the buffer moving
	// as it grows (a 10M vertex mesh with a layer is about 2 GB of text).
	reserve(out, len(out) + 200 * n + 12 * len(m.indices))
	extent := [2]Vec3{}
	if n > 0 do extent = {AABB_EMPTY.lo, AABB_EMPTY.hi}
	for p in u.base do extent = {linalg.min(extent[0], p), linalg.max(extent[1], p)}

	// Prim names are identifiers; the shapes keep their own names as the tokens that
	// list them, which is what importers show.
	taken := make([dynamic]string, 0, len(m.morphs) + 2, context.temp_allocator)
	append(&taken, "Skel")
	mesh_name := usd_identifier(&taken, m.name, "Mesh")
	material, has_material := m.material.?
	material_name := usd_identifier(&taken, material.name, "Material") if has_material else ""
	shapes := make([]string, len(m.morphs), context.temp_allocator)
	clear(&taken)
	for t, k in m.morphs do shapes[k] = usd_identifier(&taken, t.name, fmt.tprintf("Layer_%d", k + 1))
	skinned := len(m.morphs) > 0

	w :: proc(out: ^[dynamic]u8, s: string) {append(out, s)}
	w(out, "#usda 1.0\n(\n    defaultPrim = \"Root\"\n    doc = \"Written by Sculpt\"\n    metersPerUnit = 1\n    upAxis = \"Y\"\n)\n\n")
	w(out, "def SkelRoot \"Root\"\n{\n" if skinned else "def Xform \"Root\"\n{\n")
	fmt.sbprintf(&u.b, "    def Mesh \"%s\"", mesh_name)
	usd_flush(out, &u)
	switch {
	case skinned && has_material: w(out, " (\n        prepend apiSchemas = [\"SkelBindingAPI\", \"MaterialBindingAPI\"]\n    )\n    {\n")
	case skinned:                 w(out, " (\n        prepend apiSchemas = [\"SkelBindingAPI\"]\n    )\n    {\n")
	case has_material:            w(out, " (\n        prepend apiSchemas = [\"MaterialBindingAPI\"]\n    )\n    {\n")
	case:                         w(out, "\n    {\n")
	}
	w(out, "        float3[] extent = [")
	usd_vec3(out, extent[0])
	w(out, ", ")
	usd_vec3(out, extent[1])
	w(out, "]\n")
	quads := m.quads != nil
	w(out, "        int[] faceVertexCounts = ")
	usd_array(out, &u, .Counts, len(m.quads) if quads else len(m.indices) / 3, pool)
	w(out, "\n        int[] faceVertexIndices = ")
	usd_array(out, &u, .Quad_Corners if quads else .Indices, 4 * len(m.quads) if quads else len(m.indices), pool)
	w(out, "\n        normal3f[] normals = ")
	usd_array(out, &u, .Normals, n, pool)
	w(out, " (\n            interpolation = \"vertex\"\n        )\n        point3f[] points = ")
	usd_array(out, &u, .Points, n, pool)
	w(out, "\n")
	if m.colors != nil {
		w(out, "        color3f[] primvars:displayColor = ")
		usd_array(out, &u, .Colors, n, pool)
		w(out, " (\n            interpolation = \"vertex\"\n        )\n")
	}
	if m.groups != nil {
		w(out, "        int[] primvars:polygroup = ")
		usd_array(out, &u, .Groups, len(m.quads) if quads else len(m.indices) / 3, pool)
		w(out, " (\n            interpolation = \"uniform\"\n        )\n")
	}
	if quads && m.uvs != nil {
		w(out, "        texCoord2f[] primvars:st = ")
		usd_array(out, &u, .Uvs, 4 * len(m.uvs), pool)
		w(out, " (\n            interpolation = \"faceVarying\"\n        )\n")
	}
	if has_material {
		fmt.sbprintf(&u.b, "        rel material:binding = </Root/%s>\n", material_name)
		usd_flush(out, &u)
	}
	// The surface as it is, not a cage to subdivide.
	w(out, "        uniform token subdivisionScheme = \"none\"\n")
	if skinned {
		w(out, "        uniform token[] skel:blendShapes = ")
		usd_tokens(out, m.morphs)
		w(out, "\n        rel skel:blendShapeTargets = [")
		for s, k in shapes {
			fmt.sbprintf(&u.b, "%s</Root/%s/%s>", ", " if k > 0 else "", mesh_name, s)
			usd_flush(out, &u)
		}
		w(out, "]\n        rel skel:skeleton = </Root/Skel>\n")
		for t, k in m.morphs {
			fmt.sbprintf(&u.b, "\n        def BlendShape \"%s\"\n        {{\n            uniform vector3f[] offsets = ", shapes[k])
			usd_flush(out, &u)
			if len(t.vertices) == 0 {
				// A shape that moves nothing still names one point, by not moving it:
				// Blender's importer drops a shape with no offsets, and the layer with it.
				w(out, "[(0, 0, 0)]\n            uniform int[] pointIndices = [0]\n        }\n")
				continue
			}
			u.morph = k
			usd_array(out, &u, .Offsets, len(t.vertices), pool)
			w(out, "\n            uniform int[] pointIndices = ")
			usd_array(out, &u, .Point_Indices, len(t.vertices), pool)
			w(out, "\n        }\n")
		}
	}
	w(out, "    }\n")
	if has_material do usd_material(out, &u, material, material_name, m.colors != nil)
	if skinned {
		w(out, "\n    def Skeleton \"Skel\" (\n        prepend apiSchemas = [\"SkelBindingAPI\"]\n    )\n    {\n")
		w(out, "        uniform token[] joints = []\n        uniform matrix4d[] bindTransforms = []\n        uniform matrix4d[] restTransforms = []\n")
		w(out, "        rel skel:animationSource = </Root/Skel/Strengths>\n\n        def SkelAnimation \"Strengths\"\n        {\n            uniform token[] blendShapes = ")
		usd_tokens(out, m.morphs)
		w(out, "\n            float[] blendShapeWeights = ")
		usd_weights(out, m.morphs)
		w(out, "\n            float[] blendShapeWeights.timeSamples = {\n                1: ")
		usd_weights(out, m.morphs)
		w(out, ",\n            }\n        }\n    }\n")
	}
	w(out, "}\n")
}

@(private = "file")
Usd :: struct {
	m:      Mesh_Export,
	scale:  f32,
	base:   []Vec3,
	linear: [256]f32,
	morph:  int, // the blend shape .Offsets and .Point_Indices write
	b:      strings.Builder,
	kind:   Usd_Kind,
	parts:  [][dynamic]u8,
}

// What usd_array writes, an item each.
@(private = "file")
Usd_Kind :: enum u8 {
	Counts, // 3 or 4 for every face
	Indices,
	Quad_Corners,
	Normals,
	Points,
	Colors,
	Groups,
	Uvs,
	Offsets,
	Point_Indices,
}

// Writes an array of `count` items of `kind` as "[a, b, ...]", a range at a time on the
// pool, each range into its own buffer, which are then appended in order.
@(private = "file")
usd_array :: proc(out: ^[dynamic]u8, u: ^Usd, kind: Usd_Kind, count: int, pool: ^jobs.Pool) {
	u.kind = kind
	u.parts = make([][dynamic]u8, (count + RANGE_GRAIN - 1) / RANGE_GRAIN, context.temp_allocator)
	jobs.parallel_ranges(pool, count, u, proc(data: rawptr, lo, hi: int) {
		u := cast(^Usd)data
		m := u.m
		WIDTH := [Usd_Kind]int{.Counts = 3, .Indices = 12, .Quad_Corners = 12, .Normals = 56, .Points = 56, .Colors = 56, .Groups = 8, .Uvs = 38, .Offsets = 56, .Point_Indices = 12}
		buf := make([dynamic]u8, 0, WIDTH[u.kind] * (hi - lo), runtime.heap_allocator())
		for i in lo ..< hi {
			if i > 0 do append(&buf, ", ")
			switch u.kind {
			case .Counts:
				append(&buf, '4' if m.quads != nil else '3')
			case .Indices:
				usd_int(&buf, int(m.indices[i]))
			case .Quad_Corners:
				usd_int(&buf, int(m.quads[i / 4][i % 4]))
			case .Normals:
				// A vertex whose triangles have no area has no normal, and gets one that
				// points up.
				nr := m.normals[i]
				l := math.sqrt(nr.x * nr.x + nr.y * nr.y + nr.z * nr.z)
				usd_vec3(&buf, nr / l if l > 1e-20 else {0, 1, 0})
			case .Points:
				usd_vec3(&buf, u.base[i])
			case .Colors:
				c := m.colors[i]
				usd_vec3(&buf, {u.linear[c.r], u.linear[c.g], u.linear[c.b]})
			case .Groups:
				usd_int(&buf, int(m.groups[i]))
			case .Uvs:
				t := m.uvs[i / 4][i % 4]
				append(&buf, '(')
				usd_float(&buf, t.x)
				append(&buf, ", ")
				usd_float(&buf, t.y)
				append(&buf, ')')
			case .Offsets:
				usd_vec3(&buf, m.morphs[u.morph].deltas[i] * u.scale)
			case .Point_Indices:
				usd_int(&buf, int(m.morphs[u.morph].vertices[i]))
			}
		}
		u.parts[lo / RANGE_GRAIN] = buf
	}, RANGE_GRAIN)
	total := 2
	for p in u.parts do total += len(p)
	reserve(out, len(out) + total)
	append(out, '[')
	for &p in u.parts {
		append(out, ..p[:])
		delete(p)
	}
	append(out, ']')
}

@(private = "file")
usd_flush :: proc(out: ^[dynamic]u8, u: ^Usd) {
	append(out, ..u.b.buf[:])
	strings.builder_reset(&u.b)
}

@(private = "file")
usd_float :: proc(out: ^[dynamic]u8, x: f32) {
	tmp: [32]u8
	append(out, ..tmp[:format_f32(tmp[:], x)])
}

@(private = "file")
usd_vec3 :: proc(out: ^[dynamic]u8, p: Vec3) {
	append(out, '(')
	usd_float(out, p.x)
	append(out, ", ")
	usd_float(out, p.y)
	append(out, ", ")
	usd_float(out, p.z)
	append(out, ')')
}

@(private = "file")
usd_int :: proc(out: ^[dynamic]u8, x: int) {
	tmp: [24]u8
	i := len(tmp)
	v := x
	for {
		i -= 1
		tmp[i] = u8('0' + v % 10)
		v /= 10
		if v == 0 do break
	}
	append(out, ..tmp[i:])
}

// The shapes' names as a token array: each a quoted string, so any name goes.
@(private = "file")
usd_tokens :: proc(out: ^[dynamic]u8, morphs: []Morph_Target) {
	append(out, '[')
	for t, k in morphs {
		if k > 0 do append(out, ", ")
		usd_string(out, t.name)
	}
	append(out, ']')
}

@(private = "file")
usd_weights :: proc(out: ^[dynamic]u8, morphs: []Morph_Target) {
	append(out, '[')
	for t, k in morphs {
		if k > 0 do append(out, ", ")
		usd_float(out, t.weight)
	}
	append(out, ']')
}

// Writes `s` as a quoted USD string: quotes and backslashes escaped, control characters
// as spaces, and any bytes that are not UTF-8 (a name cut short mid-character) as U+FFFD.
@(private = "file")
usd_string :: proc(out: ^[dynamic]u8, s: string) {
	append(out, '"')
	for i := 0; i < len(s); {
		r, w := utf8.decode_rune_in_string(s[i:])
		switch {
		case r == utf8.RUNE_ERROR && w <= 1:
			bytes, n := utf8.encode_rune(utf8.RUNE_ERROR)
			append(out, ..bytes[:n])
		case r == '"' || r == '\\':
			append(out, '\\', u8(r))
		case r < 0x20:
			append(out, ' ')
		case:
			append(out, s[i:][:w])
		}
		i += max(w, 1)
	}
	append(out, '"')
}

// A prim name for `name`: its letters, digits and underscores, anything else as an
// underscore, never starting with a digit, `fallback` when nothing is left, and with
// "_2", "_3"... after it when `taken` has it already (which it then has).
@(private = "file")
usd_identifier :: proc(taken: ^[dynamic]string, name, fallback: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in name {
		switch r {
		case 'a' ..= 'z', 'A' ..= 'Z', '_':
			strings.write_rune(&b, r)
		case '0' ..= '9':
			if strings.builder_len(b) == 0 do strings.write_byte(&b, '_')
			strings.write_rune(&b, r)
		case:
			strings.write_byte(&b, '_')
		}
	}
	id := strings.to_string(b) if strings.builder_len(b) > 0 else fallback
	stem := id
	for k := 2; ; k += 1 {
		free := true
		for t in taken do if t == id do free = false
		if free do break
		id = fmt.tprintf("%s_%d", stem, k)
	}
	append(taken, id)
	return id
}

// The mesh's material as a UsdPreviewSurface, the surface every USD reader knows. With
// `painted` its diffuse colour is the mesh's displayColor (the paint, read by a primvar
// reader) times nothing more, so `m.base` is only the fallback where a reader has none.
@(private = "file")
usd_material :: proc(out: ^[dynamic]u8, u: ^Usd, m: Export_Material, name: string, painted: bool) {
	w :: proc(out: ^[dynamic]u8, s: string) {append(out, s)}
	fmt.sbprintf(&u.b, "\n    def Material \"%s\"\n    {{\n        token outputs:surface.connect = </Root/%s/Surface.outputs:surface>\n", name, name)
	usd_flush(out, u)
	w(out, "\n        def Shader \"Surface\"\n        {\n            uniform token info:id = \"UsdPreviewSurface\"\n            color3f inputs:diffuseColor = ")
	base := Vec3{clamp(m.base.r, 0, 1), clamp(m.base.g, 0, 1), clamp(m.base.b, 0, 1)}
	usd_vec3(out, base)
	if painted {
		fmt.sbprintf(&u.b, "\n            color3f inputs:diffuseColor.connect = </Root/%s/Paint.outputs:result>", name)
		usd_flush(out, u)
	}
	w(out, "\n            float inputs:metallic = ")
	usd_float(out, clamp(m.metallic, 0, 1))
	w(out, "\n            float inputs:roughness = ")
	usd_float(out, clamp(m.roughness, 0, 1))
	w(out, "\n            token outputs:surface\n        }\n")
	if painted {
		w(out, "\n        def Shader \"Paint\"\n        {\n            uniform token info:id = \"UsdPrimvarReader_float3\"\n            string inputs:varname = \"displayColor\"\n            float3 inputs:fallback = ")
		usd_vec3(out, base)
		w(out, "\n            float3 outputs:result\n        }\n")
	}
	w(out, "    }\n")
}
