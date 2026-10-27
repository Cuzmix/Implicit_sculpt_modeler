package geom

import "core:encoding/endian"
import "core:encoding/json"
import "core:math"
import "core:mem"
import "core:testing"

import "../jobs"

// What the tests read back of a .glb's JSON.
@(private = "file")
Glb_Json :: struct {
	meshes:      []struct {
		name:       string,
		primitives: []struct {
			attributes: map[string]int,
			indices:    int,
			material:   Maybe(int),
			targets:    []map[string]int,
		},
		weights:    []f32,
		extras:     struct {
			targetNames: []string,
		},
	},
	materials:   []struct {
		name:                 string,
		pbrMetallicRoughness: struct {
			baseColorFactor:                 [4]f32,
			metallicFactor, roughnessFactor: f32,
			baseColorTexture:                Maybe(struct {
				index: int,
			}),
			metallicRoughnessTexture:        Maybe(struct {
				index: int,
			}),
		},
		normalTexture:        Maybe(struct {
			index: int,
		}),
		occlusionTexture:     Maybe(struct {
			index: int,
		}),
	},
	images:      []struct {
		bufferView: int,
		mimeType:   string,
		name:       string,
	},
	textures:    []struct {
		sampler, source: int,
	},
	samplers:    []struct {
		magFilter, minFilter: int,
	},
	bufferViews: []struct {
		byteOffset, byteLength: int,
	},
	accessors:   []struct {
		bufferView:    Maybe(int),
		byteOffset:    int,
		componentType: int,
		normalized:    bool,
		count:         int,
		type:          string,
		min, max:      []f32,
		sparse:        Maybe(struct {
			count:   int,
			indices: struct {
				bufferView: int,
			},
			values:  struct {
				bufferView: int,
			},
		}),
	},
}

// Splits a .glb into its JSON and binary chunks, checking the header and the chunks'
// lengths and alignment on the way.
@(private = "file")
glb_chunks :: proc(t: ^testing.T, file: []u8, loc := #caller_location) -> (doc: Glb_Json, bin: []u8, ok: bool) {
	u32_at :: proc(b: []u8, at: int) -> u32 {
		x, _ := endian.get_u32(b[at:][:4], .Little)
		return x
	}
	if !testing.expect(t, len(file) >= 20 && len(file) % 4 == 0, "too short or unaligned", loc = loc) do return
	testing.expect_value(t, u32_at(file, 0), 0x46546C67, loc = loc)
	testing.expect_value(t, u32_at(file, 4), 2, loc = loc)
	testing.expect_value(t, int(u32_at(file, 8)), len(file), loc = loc)
	json_len := int(u32_at(file, 12))
	testing.expect_value(t, u32_at(file, 16), 0x4E4F534A, loc = loc)
	testing.expect_value(t, json_len % 4, 0, loc = loc)
	at := 20 + json_len
	if !testing.expect(t, at + 8 <= len(file), "no binary chunk", loc = loc) do return
	testing.expect_value(t, u32_at(file, at + 4), 0x004E4942, loc = loc)
	bin = file[at + 8:][:u32_at(file, at)]
	err := json.unmarshal(file[20:][:json_len], &doc, allocator = context.temp_allocator)
	testing.expectf(t, err == nil, "JSON: %v in %s", err, string(file[20:][:json_len]), loc = loc)
	return doc, bin, err == nil
}

@(private = "file")
view_of :: proc(doc: Glb_Json, bin: []u8, view: int) -> []u8 {
	v := doc.bufferViews[view]
	return bin[v.byteOffset:][:v.byteLength]
}

@(test)
glb_rebuilds_the_shown_surface :: proc(t: ^testing.T) {
	positions := []Vec3{{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}}
	normals := []Vec3{{0, 0, 2}, {0, 0, 1}, {0, 0, 1}, {0, 0, 0}}
	indices := []u32{0, 1, 2, 0, 2, 3}
	colors := [][3]u8{{255, 255, 255}, {0, 0, 0}, {128, 64, 32}, {255, 0, 0}}
	// The first layer shows at half strength, the second is hidden (weight 0) and the
	// third moved nothing.
	morphs := []Morph_Target {
		{name = "Lift \"top\"", weight = 0.5, vertices = {1, 3}, deltas = {{0, 0, 1}, {0, 0, -2}}},
		{name = "Hidden", weight = 0, vertices = {0, 1, 2, 3}, deltas = {{1, 0, 0}, {1, 0, 0}, {1, 0, 0}, {1, 0, 0}}},
		{name = "Empty", weight = 1.5},
	}
	scale, offset := f32(2), Vec3{1, 0, 0}
	out := make([dynamic]u8)
	defer delete(out)
	ok := mesh_write_glb(&out, {name = "Quad", positions = positions, normals = normals, indices = indices, colors = colors, morphs = morphs, scale = scale, offset = offset})
	testing.expect(t, ok)
	doc, bin, read := glb_chunks(t, out[:])
	defer free_all(context.temp_allocator)
	if !read do return

	mesh := doc.meshes[0]
	testing.expect_value(t, mesh.name, "Quad")
	prim := mesh.primitives[0]
	acc := doc.accessors
	pos := acc[prim.attributes["POSITION"]]
	testing.expect_value(t, pos.count, 4)
	base := mem.slice_data_cast([]Vec3, view_of(doc, bin, pos.bufferView.?))
	// The base and the first layer at its weight rebuild the shown surface, in the file's
	// units; the hidden layer adds nothing.
	shown := [4]Vec3{}
	for p, v in positions do shown[v] = p * scale + offset
	rebuilt := [4]Vec3{base[0], base[1], base[2], base[3]}
	rebuilt[1] += 0.5 * scale * Vec3{0, 0, 1}
	rebuilt[3] += 0.5 * scale * Vec3{0, 0, -2}
	for v in 0 ..< 4 do for k in 0 ..< 3 do testing.expectf(t, abs(rebuilt[v][k] - shown[v][k]) < 1e-6, "vertex %d: %v, shown %v", v, rebuilt[v], shown[v])
	// The bounds describe the base, as the spec asks.
	lo, hi := base[0], base[0]
	for p in base do for k in 0 ..< 3 do lo[k], hi[k] = min(lo[k], p[k]), max(hi[k], p[k])
	for k in 0 ..< 3 do testing.expect(t, pos.min[k] == lo[k] && pos.max[k] == hi[k])

	nrm := mem.slice_data_cast([]Vec3, view_of(doc, bin, acc[prim.attributes["NORMAL"]].bufferView.?))
	testing.expect_value(t, nrm[0], Vec3{0, 0, 1})
	testing.expect_value(t, nrm[3], Vec3{0, 1, 0}) // no normal: one pointing up

	col := acc[prim.attributes["COLOR_0"]]
	testing.expect(t, col.normalized && col.componentType == 5123 && col.type == "VEC4")
	lin := mem.slice_data_cast([][4]u16, view_of(doc, bin, col.bufferView.?))
	testing.expect_value(t, lin[0], [4]u16{65535, 65535, 65535, 65535})
	testing.expect_value(t, lin[1], [4]u16{0, 0, 0, 65535})
	testing.expect_value(t, lin[2].r, u16(math.round(srgb_to_linear(128.0 / 255) * 65535)))
	testing.expect(t, lin[2].r < 128 << 8, "colours are written linear")

	idx := acc[prim.indices]
	testing.expect_value(t, idx.componentType, 5125)
	testing.expect_value(t, mem.slice_data_cast([]u32, view_of(doc, bin, idx.bufferView.?))[5], 3)

	testing.expect_value(t, len(prim.targets), 3)
	testing.expect_value(t, len(mesh.weights), 3)
	testing.expect_value(t, mesh.weights[0], 0.5)
	testing.expect_value(t, mesh.weights[2], 1.5)
	testing.expect_value(t, mesh.extras.targetNames[0], "Lift \"top\"")
	testing.expect_value(t, mesh.extras.targetNames[1], "Hidden")

	// A sparse target holds its vertices and their deltas in the file's units, and its
	// bounds take in the zeros of the vertices it leaves alone.
	first := acc[prim.targets[0]["POSITION"]]
	sparse, is_sparse := first.sparse.?
	testing.expect(t, is_sparse && sparse.count == 2)
	testing.expect_value(t, mem.slice_data_cast([]u32, view_of(doc, bin, sparse.indices.bufferView))[1], 3)
	testing.expect_value(t, mem.slice_data_cast([]Vec3, view_of(doc, bin, sparse.values.bufferView))[1], Vec3{0, 0, -4})
	testing.expect(t, first.min[2] == -4 && first.max[2] == 2 && first.min[0] == 0 && first.max[0] == 0)
	// A target over every vertex has no zeros to take in.
	hidden := acc[prim.targets[1]["POSITION"]]
	testing.expect(t, hidden.min[0] == 2 && hidden.max[0] == 2)
	// One that moved nothing is all zeros, with no data at all.
	empty := acc[prim.targets[2]["POSITION"]]
	_, empty_sparse := empty.sparse.?
	_, empty_view := empty.bufferView.?
	testing.expect(t, !empty_sparse && !empty_view && empty.count == 4)
	testing.expect(t, empty.min[1] == 0 && empty.max[1] == 0)
}

@(test)
glb_names_are_valid_json_and_utf8 :: proc(t: ^testing.T) {
	positions := []Vec3{{0, 0, 0}, {1, 0, 0}, {0, 1, 0}}
	normals := []Vec3{{0, 0, 1}, {0, 0, 1}, {0, 0, 1}}
	// A name cut in the middle of "é", with a backslash, a tab and a real U+FFFD.
	cut_bytes := [4]u8{'C', 'a', 'f', 0xC3}
	cut := string(cut_bytes[:])
	morphs := []Morph_Target{{name = cut, weight = 1}, {name = "a\\b\tc�", weight = 1}}
	out := make([dynamic]u8)
	defer delete(out)
	testing.expect(t, mesh_write_glb(&out, {name = "Tri", positions = positions, normals = normals, indices = {0, 1, 2}, morphs = morphs}))
	doc, _, read := glb_chunks(t, out[:])
	defer free_all(context.temp_allocator)
	if !read do return
	names := doc.meshes[0].extras.targetNames
	testing.expect_value(t, names[0], "Caf�")
	testing.expect_value(t, names[1], "a\\b\tc�")
	// No colours: no COLOR_0.
	_, has_colors := doc.meshes[0].primitives[0].attributes["COLOR_0"]
	testing.expect(t, !has_colors)
}

@(test)
glb_without_layers_has_no_targets :: proc(t: ^testing.T) {
	sphere := icosphere(2)
	defer mesh_destroy(&sphere)
	out := make([dynamic]u8)
	defer delete(out)
	testing.expect(t, mesh_write_glb(&out, {name = "Sphere", positions = sphere.positions[:], normals = sphere.normals[:], indices = sphere.indices[:]}))
	doc, bin, read := glb_chunks(t, out[:])
	defer free_all(context.temp_allocator)
	if !read do return
	prim := doc.meshes[0].primitives[0]
	testing.expect_value(t, len(prim.targets), 0)
	testing.expect_value(t, len(doc.meshes[0].weights), 0)
	// With no layers the base is the shown surface, bit for bit.
	base := mem.slice_data_cast([]Vec3, view_of(doc, bin, doc.accessors[prim.attributes["POSITION"]].bufferView.?))
	testing.expect(t, mem.compare(mem.slice_to_bytes(base), mem.slice_to_bytes(sphere.positions[:])) == 0)
}

@(test)
glb_is_the_same_on_the_pool :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	sphere := icosphere(7) // more vertices than one range
	defer mesh_destroy(&sphere)
	n := len(sphere.positions)
	colors := make([][3]u8, n)
	defer delete(colors)
	vertices := make([]u32, n / 3)
	defer delete(vertices)
	deltas := make([]Vec3, n / 3)
	defer delete(deltas)
	for v in 0 ..< n do colors[v] = {u8(v), u8(v >> 8), u8(v >> 16)}
	for &x, i in vertices do x = u32(3 * i)
	for &d, i in deltas do d = sphere.normals[3 * i] * 0.01
	m := Mesh_Export{name = "Sphere", positions = sphere.positions[:], normals = sphere.normals[:], indices = sphere.indices[:], colors = colors, scale = 3, offset = {0, 1, 0}}
	m.morphs = []Morph_Target{{name = "Swell", weight = 0.7, vertices = vertices, deltas = deltas}}
	serial, parallel := make([dynamic]u8), make([dynamic]u8)
	defer delete(serial)
	defer delete(parallel)
	testing.expect(t, mesh_write_glb(&serial, m))
	testing.expect(t, mesh_write_glb(&parallel, m, &pool))
	free_all(context.temp_allocator)
	testing.expect(t, len(serial) == len(parallel) && mem.compare(serial[:], parallel[:]) == 0, "the pool changed the file")
}

// A material goes as glTF's metallic-roughness material on the primitive, its values
// clamped to what the format allows; with none the file has no materials.
@(test)
glb_carries_the_material :: proc(t: ^testing.T) {
	sphere := icosphere(1)
	defer mesh_destroy(&sphere)
	out := make([dynamic]u8)
	defer delete(out)
	m := Mesh_Export{name = "Sphere", positions = sphere.positions[:], normals = sphere.normals[:], indices = sphere.indices[:]}
	m.material = Export_Material{name = "Gold \"1\"", base = {1, 0.77, 1.5}, metallic = 1, roughness = 0.3}
	testing.expect(t, mesh_write_glb(&out, m))
	doc, _, read := glb_chunks(t, out[:])
	defer free_all(context.temp_allocator)
	if !read do return
	testing.expect_value(t, len(doc.materials), 1)
	testing.expect_value(t, doc.meshes[0].primitives[0].material.?, 0)
	mat := doc.materials[0]
	testing.expect_value(t, mat.name, "Gold \"1\"")
	testing.expect_value(t, mat.pbrMetallicRoughness.baseColorFactor, [4]f32{1, 0.77, 1, 1})
	testing.expect_value(t, mat.pbrMetallicRoughness.metallicFactor, 1)
	testing.expect_value(t, mat.pbrMetallicRoughness.roughnessFactor, 0.3)
	clear(&out)
	m.material = nil
	testing.expect(t, mesh_write_glb(&out, m))
	plain, _, plain_read := glb_chunks(t, out[:])
	if !plain_read do return
	testing.expect_value(t, len(plain.materials), 0)
	_, has := plain.meshes[0].primitives[0].material.?
	testing.expect(t, !has)
}

// Face materials go as a primitive a used slot, in slot order, each with its material,
// its run of the shared indices view (the triangles in their order) and every target.
@(test)
glb_writes_a_primitive_a_material :: proc(t: ^testing.T) {
	positions := []Vec3{{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}, {2, 0, 0}}
	normals := []Vec3{{0, 0, 1}, {0, 0, 1}, {0, 0, 1}, {0, 0, 1}, {0, 0, 1}}
	indices := []u32{0, 1, 2, 0, 2, 3, 1, 4, 2}
	m := Mesh_Export{name = "Plate", positions = positions, normals = normals, indices = indices}
	m.material = Export_Material{name = "Steel", base = 0.5, metallic = 1, roughness = 0.4}
	m.group_materials = []Export_Material{{name = "Unused", base = 1}, {name = "Gold", base = {1, 0.7, 0.2}, metallic = 1, roughness = 0.2}}
	// Slot 1 is unused and gets no primitive; a number past the slots is slot 0.
	m.face_material = []u8{2, 0, 9}
	m.morphs = []Morph_Target{{name = "Lift", weight = 1, vertices = []u32{2}, deltas = []Vec3{{0, 0, 1}}}}
	out := make([dynamic]u8)
	defer delete(out)
	testing.expect(t, mesh_write_glb(&out, m))
	doc, bin, read := glb_chunks(t, out[:])
	defer free_all(context.temp_allocator)
	if !read do return
	testing.expect_value(t, len(doc.materials), 3)
	testing.expect_value(t, doc.materials[2].name, "Gold")
	prims := doc.meshes[0].primitives
	if !testing.expect_value(t, len(prims), 2) do return
	testing.expect_value(t, prims[0].material.?, 0)
	testing.expect_value(t, prims[1].material.?, 2)
	testing.expect_value(t, len(doc.meshes[0].weights), 1)
	for p in prims {
		testing.expect_value(t, len(p.targets), 1)
		testing.expect_value(t, p.targets[0]["POSITION"], prims[0].targets[0]["POSITION"])
		testing.expect_value(t, p.attributes["POSITION"], 0)
	}
	want := [2][]u32{{0, 2, 3, 1, 4, 2}, {0, 1, 2}}
	for p, k in prims {
		a := doc.accessors[p.indices]
		testing.expect_value(t, a.count, len(want[k]))
		run := mem.slice_data_cast([]u32, view_of(doc, bin, a.bufferView.?)[a.byteOffset:])[:a.count]
		for x, i in want[k] do testing.expect_value(t, run[i], x)
	}
}

// Splitting by material copies each vertex two slots share for the later one, with its
// normal, colour and movement, and leaves a mesh of one slot as it was.
@(test)
split_materials_copies_seam_vertices :: proc(t: ^testing.T) {
	positions := []Vec3{{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}}
	normals := []Vec3{{0, 0, 1}, {0, 0, 1}, {0, 0, 1}, {0, 0, 1}}
	colors := [][3]u8{{1, 1, 1}, {2, 2, 2}, {3, 3, 3}, {4, 4, 4}}
	m := Mesh_Export{positions = positions, normals = normals, colors = colors, indices = []u32{0, 1, 2, 0, 2, 3}}
	m.group_materials = []Export_Material{{name = "Gold"}}
	m.face_material = []u8{0, 1}
	m.morphs = []Morph_Target{{name = "A", weight = 1, vertices = []u32{1, 2, 3}, deltas = []Vec3{{1, 0, 0}, {2, 0, 0}, {3, 0, 0}}}}
	defer free_all(context.temp_allocator)
	from, slot := mesh_export_split_materials(&m)
	// Vertices 0 and 2 are on the seam: copies 4 and 5 serve the second triangle.
	testing.expect(t, slice_equal(from, []u32{0, 1, 2, 3, 0, 2}))
	testing.expect(t, slice_equal(slot, []u8{0, 0, 0, 1, 1, 1}))
	testing.expect(t, slice_equal(m.indices, []u32{0, 1, 2, 4, 5, 3}))
	testing.expect_value(t, len(m.positions), 6)
	testing.expect_value(t, m.positions[5], positions[2])
	testing.expect_value(t, m.colors[4], colors[0])
	testing.expect(t, slice_equal(m.morphs[0].vertices, []u32{1, 2, 3, 5}))
	testing.expect_value(t, m.morphs[0].deltas[3], Vec3{2, 0, 0})
	one := Mesh_Export{positions = positions, normals = normals, indices = []u32{0, 1, 2, 0, 2, 3}, face_material = []u8{1, 1}, group_materials = m.group_materials}
	from, slot = mesh_export_split_materials(&one)
	testing.expect_value(t, len(from), 4)
	testing.expect_value(t, len(one.positions), 4)
	testing.expect(t, slice_equal(slot, []u8{1, 1, 1, 1}))
}

@(private = "file")
slice_equal :: proc(a, b: []$T) -> bool {
	if len(a) != len(b) do return false
	for x, i in a do if x != b[i] do return false
	return true
}

// UVs, tangents and pictures: TEXCOORD_0 flipped to glTF's top-left origin, TANGENT as
// given, each picture's bytes in its own view (the next starting 4-aligned after zeros),
// a texture each, and the material's textures where it says, the occlusion one only
// when asked for.
@(test)
glb_embeds_textures :: proc(t: ^testing.T) {
	m := Mesh_Export {
		name      = "Baked",
		positions = []Vec3{{0, 0, 0}, {1, 0, 0}, {0, 1, 0}},
		normals   = []Vec3{{0, 0, 1}, {0, 0, 1}, {0, 0, 1}},
		indices   = []u32{0, 1, 2},
		texcoords = [][2]f32{{0, 0}, {1, 0}, {0, 0.25}},
		tangents  = [][4]f32{{1, 0, 0, 1}, {1, 0, 0, 1}, {1, 0, 0, -1}},
		images    = []Export_Image{{"base colour", []u8{1, 2, 3, 4, 5}}, {"normal", []u8{9, 8, 7, 6, 5, 4, 3}}},
	}
	mat := Export_Material{name = "Baked", base = 1, metallic = 1, roughness = 1}
	mat.textures[.Base_Color], mat.textures[.Normal] = 1, 2
	m.material = mat
	out := make([dynamic]u8)
	defer delete(out)
	testing.expect(t, mesh_write_glb(&out, m))
	doc, bin, read := glb_chunks(t, out[:])
	defer free_all(context.temp_allocator)
	if !read do return
	if !testing.expect_value(t, len(doc.images), 2) do return
	testing.expect_value(t, len(doc.textures), 2)
	testing.expect_value(t, len(doc.samplers), 1)
	for im, k in doc.images {
		testing.expect_value(t, im.mimeType, "image/png")
		testing.expect_value(t, doc.textures[k].source, k)
		v := doc.bufferViews[im.bufferView]
		testing.expect_value(t, v.byteOffset % 4, 0)
		testing.expect(t, mem.compare(bin[v.byteOffset:][:v.byteLength], m.images[k].png) == 0, "a picture's bytes changed")
	}
	pbr := doc.materials[0].pbrMetallicRoughness
	testing.expect_value(t, pbr.baseColorTexture.?.index, 0)
	testing.expect_value(t, doc.materials[0].normalTexture.?.index, 1)
	_, has_orm := pbr.metallicRoughnessTexture.?
	_, has_occlusion := doc.materials[0].occlusionTexture.?
	testing.expect(t, !has_orm && !has_occlusion)
	attributes := doc.meshes[0].primitives[0].attributes
	uv := doc.accessors[attributes["TEXCOORD_0"]]
	testing.expect_value(t, uv.type, "VEC2")
	uvs := mem.slice_data_cast([]f32, view_of(doc, bin, uv.bufferView.?))
	testing.expect_value(t, uvs[1], 1)
	testing.expect_value(t, uvs[5], 0.75)
	tangent := doc.accessors[attributes["TANGENT"]]
	testing.expect_value(t, tangent.type, "VEC4")
	testing.expect_value(t, mem.slice_data_cast([]f32, view_of(doc, bin, tangent.bufferView.?))[11], -1)
}
