package geom

import "core:encoding/base64"
import "core:fmt"
import "core:slice"
import "core:testing"

// Files beside a file being read, by name, for a resolver.
@(private = "file")
Files :: map[string][]u8

@(private = "file")
files_resolve :: proc(data: rawptr, uri: string) -> ([]u8, bool) {
	files := cast(^Files)data
	bytes, ok := files[uri]
	return bytes, ok
}

// A 2 by 2 QOI image: red and green on the top row, blue and white below.
@(private = "file")
qoi_2x2 :: proc() -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, 'q', 'o', 'i', 'f', 0, 0, 0, 2, 0, 0, 0, 2, 3, 0)
	for c in ([][3]u8{{255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {255, 255, 255}}) do append(&out, 0xFE, c.r, c.g, c.b)
	append(&out, 0, 0, 0, 0, 0, 0, 0, 1)
	return out[:]
}

@(test)
obj_materials_paint_their_colours_and_name_groups :: proc(t: ^testing.T) {
	// Two triangles sharing no vertices: one red, one of the default white. The MTL's
	// comment and the material it never uses change nothing.
	obj := "mtllib my look.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nv 5 0 0\nv 6 0 0\nv 5 1 0\n" +
		"usemtl Red\nf 1 2 3\nusemtl White\nf 4 5 6\n"
	mtl := "# made by hand\nnewmtl Unused\nKd 0 1 0\nnewmtl Red\nKd 1 0 0 # red\nnewmtl White\nKd 1 1 1\n"
	files := Files{}
	defer delete(files)
	files["my look.mtl"] = transmute([]u8)mtl
	look: Mesh_Look
	defer mesh_look_destroy(&look)
	parts := make([dynamic]Mesh_Part)
	defer mesh_parts_destroy(&parts)
	err, _ := mesh_read_obj_parts(&parts, transmute([]u8)obj, nil, look = &look, resolve = files_resolve, resolve_data = &files)
	testing.expect_value(t, err, Mesh_File_Error.None)
	testing.expect_value(t, len(look.materials), 3)
	if len(parts) != 1 do return
	testing.expect_value(t, len(parts[0].groups), 2)
	testing.expect_value(t, len(parts[0].uvs), 0)
	report := mesh_parts_paint(parts[:], &look)
	testing.expect(t, report.painted, "painted")
	p := parts[0]
	testing.expect_value(t, len(p.materials), 0)
	testing.expect_value(t, len(p.colors), 6)
	if len(p.colors) != 6 do return
	testing.expect_value(t, p.colors[0], Vertex_Color{255, 0, 0, 255})
	testing.expect_value(t, p.colors[5], Vertex_Color{255, 255, 255, 255})
}

@(test)
obj_default_grey_material_keeps_the_clay :: proc(t: ^testing.T) {
	obj := "mtllib a.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nusemtl Material\nf 1 2 3\n"
	files := Files{}
	defer delete(files)
	files["a.mtl"] = transmute([]u8)string("newmtl Material\nKd 0.8 0.8 0.8\n")
	look: Mesh_Look
	defer mesh_look_destroy(&look)
	parts := make([dynamic]Mesh_Part)
	defer mesh_parts_destroy(&parts)
	_, _ = mesh_read_obj_parts(&parts, transmute([]u8)obj, nil, look = &look, resolve = files_resolve, resolve_data = &files)
	report := mesh_parts_paint(parts[:], &look)
	testing.expect(t, !report.painted, "a lone grey material says nothing of colour")
	if len(parts) == 1 do testing.expect_value(t, len(parts[0].colors), 0)
}

@(test)
obj_texture_paints_through_vt_and_map_kd :: proc(t: ^testing.T) {
	// Each corner at a texel's centre (v counted up in OBJ), the image named with options
	// and a Windows path, found by its name beside the file; one corner with a negative
	// vt index, one face over two objects to check the split carries coordinates.
	obj := "mtllib t.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nv 1 1 0\n" +
		"vt 0.25 0.75\nvt 0.75 0.75\nvt 0.25 0.25\nvt 0.75 0.25\n" +
		"o A\nusemtl Skin\nf 1/1 2/2 3/-2\no B\nf 2/2/1 4/4/1 3/3/1\n"
	files := Files{}
	defer delete(files)
	files["t.mtl"] = transmute([]u8)string("newmtl Skin\nKd 1 1 1\nmap_Kd -s 1 1 1 -clamp off C:\\maps\\skin.qoi\n")
	files["skin.qoi"] = qoi_2x2()
	look: Mesh_Look
	defer mesh_look_destroy(&look)
	parts := make([dynamic]Mesh_Part)
	defer mesh_parts_destroy(&parts)
	err, _ := mesh_read_obj_parts(&parts, transmute([]u8)obj, nil, look = &look, resolve = files_resolve, resolve_data = &files)
	testing.expect_value(t, err, Mesh_File_Error.None)
	testing.expect_value(t, len(parts), 2)
	if len(parts) != 2 do return
	testing.expect_value(t, len(parts[0].uvs), 3)
	report := mesh_parts_paint(parts[:], &look)
	testing.expect_value(t, report, Mesh_Paint_Report{painted = true, textures = 1})
	testing.expect_value(t, len(parts[0].colors), 3)
	testing.expect_value(t, len(parts[1].colors), 3)
	if len(parts[0].colors) != 3 || len(parts[1].colors) != 3 do return
	testing.expect_value(t, parts[0].colors[0], Vertex_Color{255, 0, 0, 255})
	testing.expect_value(t, parts[0].colors[1], Vertex_Color{0, 255, 0, 255})
	testing.expect_value(t, parts[0].colors[2], Vertex_Color{0, 0, 255, 255})
	// Part B's corners: 2, 4, 3 in its own numbering.
	testing.expect_value(t, parts[1].colors[1], Vertex_Color{255, 255, 255, 255})
}

@(test)
gltf_base_colour_texture_and_factor_paint :: proc(t: ^testing.T) {
	// Two primitives over one triangle's corners: the first textured by an image in a
	// data: URI through TEXCOORD_1, the second blue by its factor (linear 0.5 green, as
	// glTF's factors are, becomes sRGB 188).
	bin := make([dynamic]u8, context.temp_allocator)
	for p in ([]Vec3{{0, 0, 0}, {1, 0, 0}, {0, 1, 0}}) do append(&bin, ..slice.to_bytes([]Vec3{p}))
	for uv in ([][2]f32{{0.25, 0.25}, {0.75, 0.25}, {0.25, 0.75}}) do append(&bin, ..slice.to_bytes([][2]f32{uv}))
	data_uri :: proc(kind: string, bytes: []u8) -> string {
		return fmt.tprintf("data:%s;base64,%s", kind, base64.encode(bytes, allocator = context.temp_allocator))
	}
	json := fmt.tprintf(`{{"asset":{{"version":"2.0"}},"nodes":[{{"mesh":0}},{{"mesh":1}}],
	"meshes":[{{"primitives":[{{"attributes":{{"POSITION":0,"TEXCOORD_1":1}},"material":0}}]}},{{"primitives":[{{"attributes":{{"POSITION":0}},"material":1}}]}}],
	"materials":[{{"pbrMetallicRoughness":{{"baseColorTexture":{{"index":0,"texCoord":1}}}}}},{{"pbrMetallicRoughness":{{"baseColorFactor":[0,0.5,1,1]}}}}],
	"textures":[{{"source":0}}],"images":[{{"uri":"%s"}}],
	"accessors":[{{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}},{{"bufferView":1,"componentType":5126,"count":3,"type":"VEC2"}}],
	"bufferViews":[{{"buffer":0,"byteLength":36}},{{"buffer":0,"byteOffset":36,"byteLength":24}}],
	"buffers":[{{"byteLength":%d,"uri":"%s"}}]}}`, data_uri("image/qoi", qoi_2x2()), len(bin), data_uri("application/octet-stream", bin[:]))
	look: Mesh_Look
	defer mesh_look_destroy(&look)
	parts := make([dynamic]Mesh_Part)
	defer mesh_parts_destroy(&parts)
	_, err := mesh_read_gltf(&parts, transmute([]u8)json, look = &look)
	testing.expect_value(t, err, Mesh_File_Error.None)
	testing.expect_value(t, len(parts), 2)
	if len(parts) != 2 do return
	report := mesh_parts_paint(parts[:], &look)
	testing.expect_value(t, report, Mesh_Paint_Report{painted = true, textures = 1})
	testing.expect_value(t, parts[0].colors[0], Vertex_Color{255, 0, 0, 255})
	testing.expect_value(t, parts[0].colors[1], Vertex_Color{0, 255, 0, 255})
	testing.expect_value(t, parts[0].colors[2], Vertex_Color{0, 0, 255, 255})
	testing.expect_value(t, parts[1].colors[0], Vertex_Color{0, 188, 255, 255})
}

@(test)
a_part_of_one_grey_keeps_its_clay_beside_coloured_ones :: proc(t: ^testing.T) {
	obj := "mtllib a.mtl\no Body\nv 0 0 0\nv 1 0 0\nv 0 1 0\nusemtl Material\nf 1 2 3\n" +
		"o Eye\nv 5 0 0\nv 6 0 0\nv 5 1 0\nusemtl Iris\nf 4 5 6\n"
	files := Files{}
	defer delete(files)
	files["a.mtl"] = transmute([]u8)string("newmtl Material\nKd 0.8 0.8 0.8\nnewmtl Iris\nKd 0 0 1\n")
	look: Mesh_Look
	defer mesh_look_destroy(&look)
	parts := make([dynamic]Mesh_Part)
	defer mesh_parts_destroy(&parts)
	_, _ = mesh_read_obj_parts(&parts, transmute([]u8)obj, nil, look = &look, resolve = files_resolve, resolve_data = &files)
	report := mesh_parts_paint(parts[:], &look)
	testing.expect(t, report.painted, "the eye is painted")
	if len(parts) != 2 do return
	testing.expect_value(t, len(parts[0].colors), 0)
	testing.expect_value(t, len(parts[1].colors), 3)
}

@(test)
missing_texture_falls_back_to_the_factor :: proc(t: ^testing.T) {
	obj := "mtllib t.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nvt 0 0\nusemtl Skin\nf 1/1 2/1 3/1\n"
	files := Files{}
	defer delete(files)
	files["t.mtl"] = transmute([]u8)string("newmtl Skin\nKd 1 0 0\nmap_Kd skin.png\n")
	files["skin.png"] = transmute([]u8)string("not a png")
	look: Mesh_Look
	defer mesh_look_destroy(&look)
	parts := make([dynamic]Mesh_Part)
	defer mesh_parts_destroy(&parts)
	_, _ = mesh_read_obj_parts(&parts, transmute([]u8)obj, nil, look = &look, resolve = files_resolve, resolve_data = &files)
	report := mesh_parts_paint(parts[:], &look)
	testing.expect_value(t, report, Mesh_Paint_Report{painted = true, unread = 1})
	if len(parts) == 1 && len(parts[0].colors) == 3 do testing.expect_value(t, parts[0].colors[2], Vertex_Color{255, 0, 0, 255})
}
