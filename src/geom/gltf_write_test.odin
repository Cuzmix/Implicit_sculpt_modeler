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
			targets:    []map[string]int,
		},
		weights:    []f32,
		extras:     struct {
			targetNames: []string,
		},
	},
	bufferViews: []struct {
		byteOffset, byteLength: int,
	},
	accessors:   []struct {
		bufferView:    Maybe(int),
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
