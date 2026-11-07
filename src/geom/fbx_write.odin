package geom

import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"

// FBX out: binary FBX 7.4, the version Blender, Maya, 3ds Max, Unity and Unreal all read,
// written from the format's own layout (a tree of named records, each with typed values
// and the records nested in it) as Blender's exporter and ufbx document it; the app's
// FBX import (ufbx) reads every file this writes, which the tests check. One mesh: its
// points, its triangles or quads, its normals, vertex colours, the quads' UVs, its material
// (a Phong, the base colour, roughness as shininess and metal as reflection, as Blender's
// importer reads them) and the polygroups' own materials face by face; sculpt layers go as
// blend shape channels at their strengths. Units are metres and Y is up, as the USD
// writer has them. Arrays go uncompressed: the file is about twice the size of a deflated
// one, which every reader takes alike, and the writer needs no deflate.

// Appends `m` as a binary .fbx file. Returns false when it would pass 4 GB, which FBX 7.4's
// 32-bit offsets cannot address. The points written are the shown ones less each blend
// shape at its strength, so a reader that applies the strengths rebuilds the shown
// surface, as in the USD writer.
mesh_write_fbx :: proc(out: ^[dynamic]u8, m: Mesh_Export) -> bool {
	f := Fbx{out = out, base = len(out)}
	f.stack = make([dynamic]Fbx_Open, 0, 16, context.temp_allocator)
	scale := m.scale if m.scale != 0 else 1
	n := len(m.positions)
	quads := m.quads != nil
	face_count := len(m.quads) if quads else len(m.indices) / 3
	corners := 4 if quads else 3
	// Room for the arrays, so the buffer does not move as it grows.
	reserve(out, len(out) + 48 * n + 8 * corners * face_count + 4096)

	append(out, "Kaydara FBX Binary  \x00\x1a\x00")
	fbx_u32(&f, FBX_VERSION)

	// The header's file id, creation time and the footer's code go together: readers that
	// check them (Autodesk's) accept this set, which Blender's exporter writes too.
	fbx_begin(&f, "FBXHeaderExtension")
	fbx_begin(&f, "FBXHeaderVersion"); fbx_i32(&f, 1003); fbx_end(&f)
	fbx_begin(&f, "FBXVersion"); fbx_i32(&f, FBX_VERSION); fbx_end(&f)
	fbx_begin(&f, "EncryptionType"); fbx_i32(&f, 0); fbx_end(&f)
	fbx_begin(&f, "Creator"); fbx_string(&f, FBX_CREATOR); fbx_end(&f)
	fbx_end(&f)
	fbx_begin(&f, "FileId"); fbx_raw(&f, FBX_FILE_ID[:]); fbx_end(&f)
	fbx_begin(&f, "CreationTime"); fbx_string(&f, "1970-01-01 10:00:00:000"); fbx_end(&f)
	fbx_begin(&f, "Creator"); fbx_string(&f, FBX_CREATOR); fbx_end(&f)

	fbx_begin(&f, "GlobalSettings")
	fbx_begin(&f, "Version"); fbx_i32(&f, 1000); fbx_end(&f)
	fbx_begin(&f, "Properties70")
	for axis in ([?]struct {name: string, value: i32}{{"UpAxis", 1}, {"UpAxisSign", 1}, {"FrontAxis", 2}, {"FrontAxisSign", 1}, {"CoordAxis", 0}, {"CoordAxisSign", 1}, {"OriginalUpAxis", 1}, {"OriginalUpAxisSign", 1}}) {
		fbx_p_int(&f, axis.name, axis.value)
	}
	// Centimetres per unit: the points are in metres.
	fbx_p_double(&f, "UnitScaleFactor", 100)
	fbx_p_double(&f, "OriginalUnitScaleFactor", 100)
	fbx_end(&f)
	fbx_end(&f)

	ID_DOCUMENT :: i64(1_000_000)
	ID_MODEL :: i64(2_000_000)
	ID_GEOMETRY :: i64(3_000_000)
	ID_MATERIAL :: i64(4_000_000) // + slot
	ID_BLEND :: i64(5_000_000)
	ID_CHANNEL :: i64(6_000_000) // + layer
	ID_SHAPE :: i64(7_000_000) // + layer

	fbx_begin(&f, "Documents")
	fbx_begin(&f, "Count"); fbx_i32(&f, 1); fbx_end(&f)
	fbx_begin(&f, "Document"); fbx_i64(&f, ID_DOCUMENT); fbx_string(&f, ""); fbx_string(&f, "Scene")
	fbx_begin(&f, "RootNode"); fbx_i64(&f, 0); fbx_end(&f)
	fbx_end(&f)
	fbx_end(&f)

	// Which material slots go out: every one a face uses, in slot order, so a face's
	// index into the model's materials is its slot's place among them.
	material, has_material := m.material.?
	slot_count := 1 + len(m.group_materials)
	used := make([]bool, slot_count, context.temp_allocator)
	place := make([]i32, slot_count, context.temp_allocator)
	materials := 0
	if has_material {
		for f_ in 0 ..< face_count do used[export_face_slot(m, f_)] = true
		if face_count == 0 do used[0] = true
		for u, s in used {
			if !u do continue
			place[s] = i32(materials)
			materials += 1
		}
	}
	layers := len(m.morphs)

	fbx_begin(&f, "Definitions")
	fbx_begin(&f, "Version"); fbx_i32(&f, 100); fbx_end(&f)
	kinds := [?]struct {name: string, count: int}{{"GlobalSettings", 1}, {"Model", 1}, {"Geometry", 1 + layers}, {"Material", materials}, {"Deformer", 1 + layers if layers > 0 else 0}}
	total := 0
	for k in kinds do total += k.count
	fbx_begin(&f, "Count"); fbx_i32(&f, i32(total)); fbx_end(&f)
	for k in kinds {
		if k.count == 0 do continue
		fbx_begin(&f, "ObjectType"); fbx_string(&f, k.name)
		fbx_begin(&f, "Count"); fbx_i32(&f, i32(k.count)); fbx_end(&f)
		fbx_end(&f)
	}
	fbx_end(&f)

	fbx_begin(&f, "Objects")
	name := m.name if m.name != "" else "Mesh"
	fbx_begin(&f, "Geometry"); fbx_i64(&f, ID_GEOMETRY); fbx_class_name(&f, name, "Geometry"); fbx_string(&f, "Mesh")
	fbx_begin(&f, "GeometryVersion"); fbx_i32(&f, 124); fbx_end(&f)
	// The points, in the file's units, less each shape at its strength.
	fbx_begin(&f, "Vertices")
	{
		values := fbx_array_f64(&f, 3 * n)
		for p, v in m.positions do fbx_put3(values, v, p * scale + m.offset)
		for t in m.morphs {
			if t.weight == 0 do continue
			for v, i in t.vertices {
				d := t.weight * scale * t.deltas[i]
				for c in 0 ..< 3 do fbx_put(values, 3 * int(v) + c, fbx_get(values, 3 * int(v) + c) - f64(d[c]))
			}
		}
	}
	fbx_end(&f)
	// Each face's corners, the last one's index written as its bitwise complement, which
	// is how FBX marks where a polygon ends.
	fbx_begin(&f, "PolygonVertexIndex")
	{
		values := fbx_array_i32(&f, corners * face_count)
		for k in 0 ..< corners * face_count {
			v := i32(m.quads[k / 4][k % 4] if quads else m.indices[k])
			fbx_put(values, k, ~v if k % corners == corners - 1 else v)
		}
	}
	fbx_end(&f)
	fbx_begin(&f, "LayerElementNormal"); fbx_i32(&f, 0)
	fbx_layer_head(&f, "", "ByVertice", "Direct")
	fbx_begin(&f, "Normals")
	{
		values := fbx_array_f64(&f, 3 * n)
		for nr, v in m.normals {
			// A vertex whose triangles have no area has no normal, and gets one that
			// points up.
			l := math.sqrt(nr.x * nr.x + nr.y * nr.y + nr.z * nr.z)
			u := nr / l if l > 1e-12 else Vec3{0, 1, 0}
			fbx_put3(values, v, u)
		}
	}
	fbx_end(&f)
	fbx_end(&f)
	if m.colors != nil {
		fbx_begin(&f, "LayerElementColor"); fbx_i32(&f, 0)
		fbx_layer_head(&f, "Col", "ByPolygonVertex" if m.corner_colors else "ByVertice", "Direct")
		fbx_begin(&f, "Colors")
		values := fbx_array_f64(&f, 4 * len(m.colors))
		for c, k in m.colors {
			fbx_put(values, 4 * k, f64(c.r) / 255)
			fbx_put(values, 4 * k + 1, f64(c.g) / 255)
			fbx_put(values, 4 * k + 2, f64(c.b) / 255)
			fbx_put(values, 4 * k + 3, 1)
		}
		fbx_end(&f)
		fbx_end(&f)
	}
	has_uvs := quads && m.uvs != nil
	if has_uvs {
		// One UV a face corner, each its own.
		fbx_begin(&f, "LayerElementUV"); fbx_i32(&f, 0)
		fbx_layer_head(&f, "UVMap", "ByPolygonVertex", "IndexToDirect")
		fbx_begin(&f, "UV")
		{
			values := fbx_array_f64(&f, 2 * 4 * len(m.uvs))
			for q, k in m.uvs do for c in 0 ..< 4 {
				fbx_put(values, 2 * (4 * k + c), f64(q[c].x))
				fbx_put(values, 2 * (4 * k + c) + 1, f64(q[c].y))
			}
		}
		fbx_end(&f)
		fbx_begin(&f, "UVIndex")
		{
			values := fbx_array_i32(&f, 4 * len(m.uvs))
			for k in 0 ..< 4 * len(m.uvs) do fbx_put(values, k, i32(k))
		}
		fbx_end(&f)
		fbx_end(&f)
	}
	by_face := materials > 1
	if materials > 0 {
		fbx_begin(&f, "LayerElementMaterial"); fbx_i32(&f, 0)
		fbx_layer_head(&f, "", "ByPolygon" if by_face else "AllSame", "IndexToDirect")
		fbx_begin(&f, "Materials")
		values := fbx_array_i32(&f, face_count if by_face else 1)
		if by_face do for k in 0 ..< face_count do fbx_put(values, k, place[export_face_slot(m, k)])
		fbx_end(&f)
		fbx_end(&f)
	}
	fbx_begin(&f, "Layer"); fbx_i32(&f, 0)
	fbx_begin(&f, "Version"); fbx_i32(&f, 100); fbx_end(&f)
	for element in ([?]struct {kind: string, on: bool}{{"LayerElementNormal", true}, {"LayerElementColor", m.colors != nil}, {"LayerElementUV", has_uvs}, {"LayerElementMaterial", materials > 0}}) {
		if !element.on do continue
		fbx_begin(&f, "LayerElement")
		fbx_begin(&f, "Type"); fbx_string(&f, element.kind); fbx_end(&f)
		fbx_begin(&f, "TypedIndex"); fbx_i32(&f, 0); fbx_end(&f)
		fbx_end(&f)
	}
	fbx_end(&f)
	fbx_end(&f) // Geometry

	fbx_begin(&f, "Model"); fbx_i64(&f, ID_MODEL); fbx_class_name(&f, name, "Model"); fbx_string(&f, "Mesh")
	fbx_begin(&f, "Version"); fbx_i32(&f, 232); fbx_end(&f)
	fbx_begin(&f, "Properties70")
	fbx_p_vec3(&f, "Lcl Scaling", "Lcl Scaling", "", "A", {1, 1, 1})
	fbx_p_int(&f, "DefaultAttributeIndex", 0)
	fbx_end(&f)
	fbx_begin(&f, "Shading"); fbx_bool(&f, true); fbx_end(&f)
	fbx_begin(&f, "Culling"); fbx_string(&f, "CullingOff"); fbx_end(&f)
	fbx_end(&f)

	if has_material {
		for u, s in used {
			if !u do continue
			mat := material if s == 0 else m.group_materials[s - 1]
			fbx_begin(&f, "Material"); fbx_i64(&f, ID_MATERIAL + i64(s)); fbx_class_name(&f, mat.name if mat.name != "" else "Material", "Material"); fbx_string(&f, "")
			fbx_begin(&f, "Version"); fbx_i32(&f, 102); fbx_end(&f)
			fbx_begin(&f, "ShadingModel"); fbx_string(&f, "phong"); fbx_end(&f)
			fbx_begin(&f, "MultiLayer"); fbx_i32(&f, 0); fbx_end(&f)
			fbx_begin(&f, "Properties70")
			fbx_p_vec3(&f, "DiffuseColor", "Color", "", "A", {f64(mat.base.r), f64(mat.base.g), f64(mat.base.b)})
			fbx_p_double(&f, "DiffuseFactor", 1)
			// Blender's importer reads roughness as 1 - sqrt(Shininess) / 10 and metal as the
			// reflection factor; other readers take ShininessExponent.
			shine := f64((1 - clamp(mat.roughness, 0, 1)) * 10)
			fbx_p_double(&f, "Shininess", shine * shine)
			fbx_p_double(&f, "ShininessExponent", shine * shine)
			fbx_p_double(&f, "ReflectionFactor", f64(clamp(mat.metallic, 0, 1)))
			fbx_end(&f)
			fbx_end(&f)
		}
	}

	if layers > 0 {
		fbx_begin(&f, "Deformer"); fbx_i64(&f, ID_BLEND); fbx_class_name(&f, "Layers", "Deformer"); fbx_string(&f, "BlendShape")
		fbx_begin(&f, "Version"); fbx_i32(&f, 100); fbx_end(&f)
		fbx_end(&f)
		for t, k in m.morphs {
			layer_name := t.name if t.name != "" else fmt.tprintf("Layer %d", k + 1)
			fbx_begin(&f, "Deformer"); fbx_i64(&f, ID_CHANNEL + i64(k)); fbx_class_name(&f, layer_name, "SubDeformer"); fbx_string(&f, "BlendShapeChannel")
			fbx_begin(&f, "Version"); fbx_i32(&f, 100); fbx_end(&f)
			fbx_begin(&f, "DeformPercent"); fbx_f64(&f, f64(t.weight) * 100); fbx_end(&f)
			fbx_begin(&f, "FullWeights"); fbx_put(fbx_array_f64(&f, 1), 0, f64(100)); fbx_end(&f)
			fbx_end(&f)
			// A shape that moves nothing still names one point, by not moving it, so a
			// reader keeps the layer.
			count := max(len(t.vertices), 1)
			fbx_begin(&f, "Geometry"); fbx_i64(&f, ID_SHAPE + i64(k)); fbx_class_name(&f, layer_name, "Geometry"); fbx_string(&f, "Shape")
			fbx_begin(&f, "Version"); fbx_i32(&f, 100); fbx_end(&f)
			fbx_begin(&f, "Indexes")
			indexes := fbx_array_i32(&f, count)
			for v, i in t.vertices do fbx_put(indexes, i, i32(v))
			fbx_end(&f)
			fbx_begin(&f, "Vertices")
			offsets := fbx_array_f64(&f, 3 * count)
			for d, i in t.deltas do fbx_put3(offsets, i, d * scale)
			fbx_end(&f)
			fbx_begin(&f, "Normals"); _ = fbx_array_f64(&f, 3 * count); fbx_end(&f)
			fbx_end(&f)
		}
	}
	fbx_end(&f) // Objects

	fbx_begin(&f, "Connections")
	fbx_connect(&f, ID_MODEL, 0)
	fbx_connect(&f, ID_GEOMETRY, ID_MODEL)
	if has_material {
		for u, s in used do if u do fbx_connect(&f, ID_MATERIAL + i64(s), ID_MODEL)
	}
	if layers > 0 {
		fbx_connect(&f, ID_BLEND, ID_GEOMETRY)
		for k in 0 ..< layers {
			fbx_connect(&f, ID_CHANNEL + i64(k), ID_BLEND)
			fbx_connect(&f, ID_SHAPE + i64(k), ID_CHANNEL + i64(k))
		}
	}
	fbx_end(&f)

	// The end of the top level, then the footer: its code, zeros to a 16-byte boundary
	// (16 when already on one), the version, 120 zeros and the closing code.
	append(out, ..FBX_SENTINEL[:])
	append(out, ..FBX_FOOTER_ID[:])
	fbx_u32(&f, 0)
	at := len(out) - f.base
	pad := ((at + 15) & ~int(15)) - at
	if pad == 0 do pad = 16
	for _ in 0 ..< pad do append(out, 0)
	fbx_u32(&f, FBX_VERSION)
	for _ in 0 ..< 120 do append(out, 0)
	append(out, ..FBX_FOOTER_END[:])
	return !f.too_big && len(out) - f.base <= int(max(u32))
}

FBX_VERSION :: 7400
@(private = "file")
FBX_CREATOR :: "Sculpt"
@(private = "file")
FBX_SENTINEL := [13]u8{}
@(private = "file")
FBX_FILE_ID := [16]u8{0x28, 0xb3, 0x2a, 0xeb, 0xb6, 0x24, 0xcc, 0xc2, 0xbf, 0xc8, 0xb0, 0x2a, 0xa9, 0x2b, 0xfc, 0xf1}
@(private = "file")
FBX_FOOTER_ID := [16]u8{0xfa, 0xbc, 0xab, 0x09, 0xd0, 0xc8, 0xd4, 0x66, 0xb1, 0x76, 0xfb, 0x83, 0x1c, 0xf7, 0x26, 0x7e}
@(private = "file")
FBX_FOOTER_END := [16]u8{0xf8, 0x5a, 0x8c, 0x6a, 0xde, 0xf5, 0xd9, 0x7e, 0xec, 0xe9, 0x0c, 0xe3, 0x75, 0x8f, 0x29, 0x0b}

// The writer: the file so far, and the records open, innermost last.
@(private = "file")
Fbx :: struct {
	out:     ^[dynamic]u8,
	base:    int, // where the file starts in `out`
	stack:   [dynamic]Fbx_Open,
	too_big: bool,
}

// An open record: where it starts, where its values start, how many it has so far, and
// whether records are nested in it (its values then are done).
@(private = "file")
Fbx_Open :: struct {
	start, values: int,
	count:         u32,
	nested:        bool,
}

@(private = "file")
fbx_u32 :: proc(f: ^Fbx, x: u32) {
	x := x
	append(f.out, ..mem.ptr_to_bytes(&x))
}

@(private = "file")
fbx_put_u32 :: proc(f: ^Fbx, at: int, x: u32) {
	x := x
	copy(f.out[at:][:4], mem.ptr_to_bytes(&x))
}

// Opens record `name`: its end, value count and values' length are filled in later.
@(private = "file")
fbx_begin :: proc(f: ^Fbx, name: string) {
	if n := len(f.stack); n > 0 do fbx_close_values(&f.stack[n - 1], f)
	start := len(f.out)
	for _ in 0 ..< 12 do append(f.out, 0)
	append(f.out, u8(len(name)))
	append(f.out, name)
	append(&f.stack, Fbx_Open{start = start, values = len(f.out)})
}

// The record's values are done once one is nested in it.
@(private = "file")
fbx_close_values :: proc(o: ^Fbx_Open, f: ^Fbx) {
	if o.nested do return
	o.nested = true
	fbx_put_u32(f, o.start + 4, o.count)
	fbx_put_u32(f, o.start + 8, u32(len(f.out) - o.values))
}

// Closes the innermost record: a record with records nested in it ends with an empty one,
// as the format marks the end of a nested list.
@(private = "file")
fbx_end :: proc(f: ^Fbx) {
	o := pop(&f.stack)
	if o.nested {
		append(f.out, ..FBX_SENTINEL[:])
	} else {
		fbx_put_u32(f, o.start + 4, o.count)
		fbx_put_u32(f, o.start + 8, u32(len(f.out) - o.values))
	}
	end := len(f.out) - f.base
	if end > int(max(u32)) do f.too_big = true
	fbx_put_u32(f, o.start, u32(end))
}

@(private = "file")
fbx_value :: proc(f: ^Fbx, kind: u8) {
	f.stack[len(f.stack) - 1].count += 1
	append(f.out, kind)
}

@(private = "file")
fbx_i32 :: proc(f: ^Fbx, x: i32) {
	fbx_value(f, 'I')
	x := x
	append(f.out, ..mem.ptr_to_bytes(&x))
}

@(private = "file")
fbx_i64 :: proc(f: ^Fbx, x: i64) {
	fbx_value(f, 'L')
	x := x
	append(f.out, ..mem.ptr_to_bytes(&x))
}

@(private = "file")
fbx_f64 :: proc(f: ^Fbx, x: f64) {
	fbx_value(f, 'D')
	x := x
	append(f.out, ..mem.ptr_to_bytes(&x))
}

@(private = "file")
fbx_bool :: proc(f: ^Fbx, x: bool) {
	fbx_value(f, 'C')
	append(f.out, u8(1) if x else u8(0))
}

@(private = "file")
fbx_string :: proc(f: ^Fbx, s: string) {
	fbx_value(f, 'S')
	fbx_u32(f, u32(len(s)))
	append(f.out, s)
}

// An object's name as FBX keeps it: the name, then 0 and 1, then its class.
@(private = "file")
fbx_class_name :: proc(f: ^Fbx, name, class: string) {
	fbx_string(f, strings.concatenate({name, "\x00\x01", class}, context.temp_allocator))
}

@(private = "file")
fbx_raw :: proc(f: ^Fbx, data: []u8) {
	fbx_value(f, 'R')
	fbx_u32(f, u32(len(data)))
	append(f.out, ..data)
}

// An array value's room in the file: `count` items of T, uncompressed and zeroed, for the
// caller to fill in place (fbx_put) before the next write. The file gives them no
// alignment, so each is stored a byte at a time as the platform allows.
@(private = "file")
Fbx_Array :: struct($T: typeid) {
	data: [^]u8,
}

@(private = "file")
fbx_array :: proc(f: ^Fbx, $T: typeid, kind: u8, count: int) -> Fbx_Array(T) {
	fbx_value(f, kind)
	fbx_u32(f, u32(count))
	fbx_u32(f, 0)
	fbx_u32(f, u32(size_of(T) * count))
	at := len(f.out)
	resize(f.out, at + size_of(T) * count)
	mem.zero_slice(f.out[at:])
	return {raw_data(f.out[at:])}
}

@(private = "file")
fbx_array_f64 :: proc(f: ^Fbx, count: int) -> Fbx_Array(f64) {
	return fbx_array(f, f64, 'd', count)
}

@(private = "file")
fbx_array_i32 :: proc(f: ^Fbx, count: int) -> Fbx_Array(i32) {
	return fbx_array(f, i32, 'i', count)
}

@(private = "file")
fbx_put :: #force_inline proc(a: Fbx_Array($T), i: int, x: T) {
	intrinsics.unaligned_store((^T)(&a.data[size_of(T) * i]), x)
}

@(private = "file")
fbx_put3 :: #force_inline proc(a: Fbx_Array(f64), i: int, v: Vec3) {
	fbx_put(a, 3 * i, f64(v.x))
	fbx_put(a, 3 * i + 1, f64(v.y))
	fbx_put(a, 3 * i + 2, f64(v.z))
}

@(private = "file")
fbx_get :: #force_inline proc(a: Fbx_Array($T), i: int) -> T {
	return intrinsics.unaligned_load((^T)(&a.data[size_of(T) * i]))
}

// The head every layer element starts with: its version, name and how its values map
// onto the mesh.
@(private = "file")
fbx_layer_head :: proc(f: ^Fbx, name, mapping, reference: string) {
	fbx_begin(f, "Version"); fbx_i32(f, 101); fbx_end(f)
	fbx_begin(f, "Name"); fbx_string(f, name); fbx_end(f)
	fbx_begin(f, "MappingInformationType"); fbx_string(f, mapping); fbx_end(f)
	fbx_begin(f, "ReferenceInformationType"); fbx_string(f, reference); fbx_end(f)
}

// Properties70's entries: P, the name, its type twice and its flags, then the values.
@(private = "file")
fbx_p_int :: proc(f: ^Fbx, name: string, x: i32) {
	fbx_begin(f, "P"); fbx_string(f, name); fbx_string(f, "int"); fbx_string(f, "Integer"); fbx_string(f, ""); fbx_i32(f, x); fbx_end(f)
}

@(private = "file")
fbx_p_double :: proc(f: ^Fbx, name: string, x: f64) {
	fbx_begin(f, "P"); fbx_string(f, name); fbx_string(f, "double"); fbx_string(f, "Number"); fbx_string(f, ""); fbx_f64(f, x); fbx_end(f)
}

@(private = "file")
fbx_p_vec3 :: proc(f: ^Fbx, name, kind, kind2, flags: string, v: [3]f64) {
	fbx_begin(f, "P"); fbx_string(f, name); fbx_string(f, kind); fbx_string(f, kind2); fbx_string(f, flags)
	fbx_f64(f, v.x); fbx_f64(f, v.y); fbx_f64(f, v.z)
	fbx_end(f)
}

// That object `child` belongs to `parent` (0: the scene's root).
@(private = "file")
fbx_connect :: proc(f: ^Fbx, child, parent: i64) {
	fbx_begin(f, "C"); fbx_string(f, "OO"); fbx_i64(f, child); fbx_i64(f, parent); fbx_end(f)
}
