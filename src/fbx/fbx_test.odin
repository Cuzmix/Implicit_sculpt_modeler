package fbx

import "core:os"
import "core:strings"
import "core:testing"

import "../geom"

// ufbx's own test files, which scripts/build_ufbx.py clones with it.
@(private = "file")
DATA :: #directory + "/../../deps/ufbx-src/data/"

@(private = "file")
load :: proc(name: string) -> []u8 {
	data, err := os.read_entire_file(strings.concatenate({DATA, name}, context.temp_allocator), context.allocator)
	return data if err == nil else nil
}

// Files beside the test files, as the app's resolver gives them.
@(private = "file")
beside :: proc(data: rawptr, uri: string) -> ([]u8, bool) {
	files := cast(^[dynamic][]u8)data
	bytes := load(uri)
	if bytes == nil do return nil, false
	append(files, bytes)
	return bytes, true
}

@(test)
binary_and_text_fbx_read_the_same_coloured_cube :: proc(t: ^testing.T) {
	colors: [2][8]geom.Vertex_Color
	for name, k in ([]string{"blender_279_color_sets_7400_binary.fbx", "blender_279_color_sets_6100_ascii.fbx"}) {
		data := load(name)
		defer delete(data)
		testing.expect(t, recognised(data), name)
		parts := make([dynamic]geom.Mesh_Part)
		defer geom.mesh_parts_destroy(&parts)
		err, _, _ := read(&parts, data)
		testing.expect_value(t, err, geom.Mesh_File_Error.None)
		if len(parts) != 1 do continue
		p := parts[0]
		testing.expect_value(t, p.name, "Cube")
		testing.expect_value(t, len(p.mesh.positions), 8)
		testing.expect_value(t, len(p.mesh.indices), 36)
		testing.expect_value(t, len(p.colors), 8)
		if len(p.colors) == 8 do copy(colors[k][:], p.colors[:])
	}
	testing.expect_value(t, colors[0], colors[1])
	for c in colors[0] do testing.expect_value(t, c.a, 255)
}

@(test)
fbx_instances_each_become_a_part :: proc(t: ^testing.T) {
	data := load("blender_293_instancing_7400_binary.fbx")
	defer delete(data)
	parts := make([dynamic]geom.Mesh_Part)
	defer geom.mesh_parts_destroy(&parts)
	err, _, _ := read(&parts, data)
	testing.expect_value(t, err, geom.Mesh_File_Error.None)
	testing.expect_value(t, len(parts), 8)
	for p in parts do testing.expect_value(t, len(p.mesh.indices), 3 * 968)
	// Placed round a circle, so no two share a place.
	if len(parts) == 8 do testing.expect(t, parts[0].mesh.positions[0] != parts[1].mesh.positions[0], "placed apart")
}

@(test)
fbx_materials_give_groups_and_paint :: proc(t: ^testing.T) {
	data := load("blender_suzanne_multimaterial_7400_binary.fbx")
	defer delete(data)
	parts := make([dynamic]geom.Mesh_Part)
	defer geom.mesh_parts_destroy(&parts)
	look: geom.Mesh_Look
	defer geom.mesh_look_destroy(&look)
	err, _, _ := read(&parts, data, &look)
	testing.expect_value(t, err, geom.Mesh_File_Error.None)
	testing.expect_value(t, len(look.materials), 7)
	if len(parts) != 1 do return
	testing.expect_value(t, len(parts[0].groups), 968)
	report := geom.mesh_parts_paint(parts[:], &look)
	testing.expect(t, report.painted, "painted")
	testing.expect_value(t, len(parts[0].colors), len(parts[0].mesh.positions))
}

@(test)
fbx_textures_paint_embedded_or_beside :: proc(t: ^testing.T) {
	files := make([dynamic][]u8)
	defer {
		for f in files do delete(f)
		delete(files)
	}
	for name in ([]string{"blender_293_embedded_textures_7400_binary.fbx", "blender_293_textures_7400_binary.fbx"}) {
		data := load(name)
		defer delete(data)
		parts := make([dynamic]geom.Mesh_Part)
		defer geom.mesh_parts_destroy(&parts)
		look: geom.Mesh_Look
		defer geom.mesh_look_destroy(&look)
		// The second names its images by a Windows path below the file.
		err, _, _ := read(&parts, data, &look, beside, &files)
		testing.expect_value(t, err, geom.Mesh_File_Error.None)
		if len(parts) != 1 do continue
		testing.expect_value(t, len(parts[0].uvs), 36)
		report := geom.mesh_parts_paint(parts[:], &look)
		testing.expect_value(t, report, geom.Mesh_Paint_Report{painted = true, textures = 1})
		testing.expect_value(t, len(parts[0].colors), 8)
	}
}

@(test)
not_fbx_is_refused_with_a_reason :: proc(t: ^testing.T) {
	parts := make([dynamic]geom.Mesh_Part)
	defer geom.mesh_parts_destroy(&parts)
	text := "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n"
	testing.expect(t, !recognised(transmute([]u8)text), "OBJ is not FBX")
	err, reason, _ := read(&parts, transmute([]u8)text)
	testing.expect_value(t, err, geom.Mesh_File_Error.Not_Recognised)
	testing.expect(t, reason != "", "ufbx says why")
	// A binary file cut short.
	data := load("blender_279_color_sets_7400_binary.fbx")
	defer delete(data)
	cut, _, _ := read(&parts, data[:len(data) / 2])
	testing.expect_value(t, cut, geom.Mesh_File_Error.Not_Recognised)
	testing.expect_value(t, len(parts), 0)
}

// A Blender cube keeps its six quads; nested meshes name the node above them as their
// folder; a skinned, animated sausage and a mesh with animated shape keys say what they hold
// for animation, which Import leaves for later.
@(test)
fbx_keeps_polygons_folders_and_counts_rigs :: proc(t: ^testing.T) {
	{
		data := load("blender_272_cube_7400_binary.fbx")
		defer delete(data)
		parts := make([dynamic]geom.Mesh_Part)
		defer geom.mesh_parts_destroy(&parts)
		err, _, rig := read(&parts, data)
		testing.expect_value(t, err, geom.Mesh_File_Error.None)
		testing.expect_value(t, rig, geom.Rig_Found{})
		if len(parts) == 1 {
			p := parts[0]
			testing.expect_value(t, len(p.polys), len(p.mesh.indices) / 3)
			faces := map[u32]int{}
			defer delete(faces)
			for f in p.polys do faces[f] += 1
			testing.expect_value(t, len(faces), 6)
			for _, n in faces do testing.expect_value(t, n, 2)
		}
	}
	{
		data := load("blender_279_nested_meshes_7400_binary.fbx")
		defer delete(data)
		parts := make([dynamic]geom.Mesh_Part)
		defer geom.mesh_parts_destroy(&parts)
		err, _, _ := read(&parts, data)
		testing.expect_value(t, err, geom.Mesh_File_Error.None)
		nested := 0
		for p in parts do if len(p.folders) > 0 do nested += 1
		testing.expectf(t, nested > 0 && nested < len(parts), "%d of %d parts sit under another node", nested, len(parts))
	}
	{
		data := load("blender_279_sausage_7400_binary.fbx")
		defer delete(data)
		parts := make([dynamic]geom.Mesh_Part)
		defer geom.mesh_parts_destroy(&parts)
		_, _, rig := read(&parts, data)
		testing.expectf(t, rig.skins > 0 && rig.animations > 0, "%v", rig)
	}
	{
		data := load("blender440_shape_weight_anim_7400_binary.fbx")
		defer delete(data)
		parts := make([dynamic]geom.Mesh_Part)
		defer geom.mesh_parts_destroy(&parts)
		_, _, rig := read(&parts, data)
		testing.expectf(t, rig.shapes > 0 && rig.animations > 0, "%v", rig)
	}
}
