package geom

import "core:encoding/base64"
import "core:fmt"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import "core:testing"

@(test)
gltf_reads_back_what_the_glb_writer_wrote :: proc(t: ^testing.T) {
	sphere := icosphere(3)
	defer mesh_destroy(&sphere)
	rgb := make([][3]u8, len(sphere.positions))
	defer delete(rgb)
	for &c, v in rgb do c = {u8(v), u8(255 - v % 256), 128}
	out := make([dynamic]u8)
	defer delete(out)
	// Written at twice the size and moved, as an export puts a mesh back in its file.
	testing.expect(t, mesh_write_glb(&out, {name = "Ball", positions = sphere.positions[:], normals = sphere.normals[:], indices = sphere.indices[:], colors = rgb, scale = 2, offset = {1, 0, 0}}))
	parts := make([dynamic]Mesh_Part)
	defer mesh_parts_destroy(&parts)
	skipped, err := mesh_read_gltf(&parts, out[:])
	testing.expect_value(t, err, Mesh_File_Error.None)
	testing.expect_value(t, skipped, Gltf_Skipped{})
	testing.expect_value(t, len(parts), 1)
	if len(parts) != 1 do return
	p := parts[0]
	testing.expect_value(t, p.name, "Ball")
	testing.expect_value(t, len(p.mesh.positions), len(sphere.positions))
	testing.expect(t, slice.equal(p.mesh.indices[:], sphere.indices[:]), "triangles")
	worst: f32
	for q, v in p.mesh.positions do worst = max(worst, linalg.length(q - (sphere.positions[v] * 2 + {1, 0, 0})))
	testing.expectf(t, worst < 1e-5, "positions off by %v", worst)
	// sRGB bytes go out as linear 16-bit and come back as the same bytes.
	for c, v in p.colors {
		if c != {rgb[v].r, rgb[v].g, rgb[v].b, 255} {
			testing.expectf(t, false, "vertex %d: %v, not %v", v, c, rgb[v])
			break
		}
	}
	testing.expect_value(t, len(p.groups), 0)
}

@(test)
gltf_places_each_node_and_reads_strips_fans_and_sparse_values :: proc(t: ^testing.T) {
	// One buffer, as a data: URI: a triangle's three float corners (36 bytes), then a
	// fan of four u8 corners (4 bytes), then a sparse index (u8, padded) and value.
	bin := make([dynamic]u8)
	defer delete(bin)
	for p in ([]Vec3{{0, 0, 0}, {1, 0, 0}, {0, 1, 0}}) do append(&bin, ..slice.to_bytes([]Vec3{p}))
	append(&bin, 0, 1, 2, 0)
	append(&bin, 2, 0, 0, 0)
	append(&bin, ..slice.to_bytes([]Vec3{{0, 2, 0}}))
	uri := fmt.tprintf("data:application/octet-stream;base64,%s", base64.encode(bin[:], allocator = context.temp_allocator))
	json := fmt.tprintf(`{{"asset":{{"version":"2.0"}},"scene":0,"scenes":[{{"nodes":[0,1]}}],
	"nodes":[{{"name":"A","mesh":0,"translation":[10,0,0]}},{{"name":"B","mesh":1,"scale":[-1,1,1],"children":[2]}},{{"mesh":0,"matrix":[1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,5,1]}}],
	"meshes":[{{"name":"Tri","primitives":[{{"attributes":{{"POSITION":0}}}},{{"attributes":{{"POSITION":0}},"material":1}}]}},
	          {{"primitives":[{{"attributes":{{"POSITION":1}},"indices":2,"mode":6}},{{"attributes":{{"POSITION":0}},"mode":1}}]}}],
	"accessors":[{{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}},
	             {{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","sparse":{{"count":1,"indices":{{"bufferView":2,"componentType":5121}},"values":{{"bufferView":3}}}}}},
	             {{"bufferView":1,"componentType":5121,"count":4,"type":"SCALAR"}}],
	"bufferViews":[{{"buffer":0,"byteLength":36}},{{"buffer":0,"byteOffset":36,"byteLength":4}},{{"buffer":0,"byteOffset":40,"byteLength":1}},{{"buffer":0,"byteOffset":44,"byteLength":12}}],
	"buffers":[{{"byteLength":%d,"uri":"%s"}}]}}`, len(bin), uri)
	parts := make([dynamic]Mesh_Part)
	defer mesh_parts_destroy(&parts)
	skipped, err := mesh_read_gltf(&parts, transmute([]u8)json)
	testing.expect_value(t, err, Mesh_File_Error.None)
	testing.expect_value(t, skipped.not_faces, 1)
	testing.expect_value(t, len(parts), 3)
	if len(parts) != 3 do return
	// A: two primitives of the triangle, moved, the second with material 1: groups 0 and 2.
	testing.expect_value(t, parts[0].name, "A")
	testing.expect_value(t, parts[0].mesh.positions[1], Vec3{11, 0, 0})
	testing.expect(t, slice.equal(parts[0].groups[:], []u16{0, 2}), "groups by material")
	// B: mirrored in x, so its fan (0 1 2, 0 2 0 -> one real triangle and one repeated
	// corner mesh_clean drops) is wound the other way; the sparse value moved corner 2.
	testing.expect_value(t, parts[1].name, "B")
	testing.expect_value(t, parts[1].mesh.positions[2], Vec3{0, 2, 0})
	testing.expect_value(t, parts[1].mesh.positions[1], Vec3{-1, 0, 0})
	testing.expect(t, slice.equal(parts[1].mesh.indices[:3], []u32{0, 2, 1}), "mirrored winding")
	// The child: B's mirror, then its own move in z.
	testing.expect_value(t, parts[2].name, "Tri")
	testing.expect_value(t, parts[2].mesh.positions[1], Vec3{-1, 0, 5})
}

@(test)
gltf_refuses_what_it_cannot_follow :: proc(t: ^testing.T) {
	parts := make([dynamic]Mesh_Part)
	defer mesh_parts_destroy(&parts)
	_, not_gltf := mesh_read_gltf(&parts, transmute([]u8)string(`{"asset":{"version":"1.0"}}`))
	testing.expect_value(t, not_gltf, Mesh_File_Error.Not_Recognised)
	_, missing := mesh_read_gltf(&parts, transmute([]u8)string(`{"asset":{"version":"2.0"},"buffers":[{"byteLength":4,"uri":"a%20b.bin"}]}`))
	testing.expect_value(t, missing, Mesh_File_Error.Missing_File)
	// A resolver gets the file name with its escapes undone.
	Seen :: struct {
		name: string,
	}
	seen: Seen
	resolve :: proc(data: rawptr, uri: string) -> ([]u8, bool) {
		(cast(^Seen)data).name = strings.clone(uri, context.temp_allocator)
		return nil, false
	}
	_, _ = mesh_read_gltf(&parts, transmute([]u8)string(`{"asset":{"version":"2.0"},"buffers":[{"byteLength":4,"uri":"a%20b.bin"}]}`), resolve, &seen)
	testing.expect_value(t, seen.name, "a b.bin")
	_, draco := mesh_read_gltf(&parts, transmute([]u8)string(`{"asset":{"version":"2.0"},"nodes":[{"mesh":0}],"meshes":[{"primitives":[{"attributes":{"POSITION":0},"extensions":{"KHR_draco_mesh_compression":{}}}]}]}`))
	testing.expect_value(t, draco, Mesh_File_Error.Empty)
	_, cut := mesh_read_gltf(&parts, transmute([]u8)string("glTF\x02\x00\x00\x00\x40\x00\x00\x00\xff\x00\x00\x00JSON"))
	testing.expect_value(t, cut, Mesh_File_Error.Truncated)
}
