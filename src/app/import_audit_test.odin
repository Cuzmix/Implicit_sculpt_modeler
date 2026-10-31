package main

import "core:strings"
import "core:testing"

import "../geom"

// One file of each format Import reads, as Menu > Import mesh... and --import read them:
// each comes in with its parts, the folders its hierarchy names, its faces as polygons
// where it has them, and a note naming what it holds for animation that is left out.
@(test)
import_reads_one_file_of_each_format :: proc(t: ^testing.T) {
	Case :: struct {
		file:       string,
		parts:      int,
		folders:    []string, // each part's folders on import from the top, joined by "/", in order
		polygons:   bool,
		rig:        geom.Rig_Found,
		note_has:   string,
	}
	DIR :: #directory + "testdata/import/"
	cases := []Case {
		{DIR + "cubes.obj", 2, {"cubes", "cubes"}, true, {}, "its quads and polygons stay"},
		{DIR + "cube.ply", 1, {"cube"}, true, {}, "its quads and polygons stay"},
		{DIR + "tet.stl", 1, {"tet"}, false, {}, "4 vertices, 4 triangles"},
		{DIR + "quad_cube.stl", 1, {"quad_cube"}, true, {}, "its 6 quads found again from its triangle pairs"},
		{DIR + "quad_cube.gltf", 1, {"quad_cube"}, true, {}, "its 6 quads found again from its triangle pairs, with their UVs on objects of quads"},
		{DIR + "rig.gltf", 3, {"rig/Character", "rig/Character/Arms", "rig"}, false, {skins = 1, animations = 1, shapes = 2}, "1 skin, 1 animation and 2 shape keys found and left out"},
		{DIR + "rig.usda", 2, {"rig", "rig/Props"}, false, {skins = 1, animations = 1, shapes = 1}, "1 skin, 1 animation and 1 shape key found and left out"},
		{#directory + "../../deps/ufbx-src/data/blender_279_sausage_7400_binary.fbx", 1, {"blender_279_sausage_7400_binary"}, true, {skins = 1, animations = 3}, "found and left out"},
	}
	for c in cases {
		m, note, _, ok := mesh_import_load(c.file, "Imported", nil)
		defer delete(note)
		defer mesh_import_free(&m)
		if !testing.expectf(t, ok, "%s: %s", c.file, note) do continue
		testing.expectf(t, len(m.parts) == c.parts, "%s: %d parts, want %d", c.file, len(m.parts), c.parts)
		if len(m.parts) == len(c.folders) {
			paths := import_folder_paths(m.parts[:], file_stem(c.file))
			for f, k in c.folders {
				got := strings.join(paths[k], "/", context.temp_allocator)
				testing.expectf(t, got == f, "%s: part %d in %q, want %q", c.file, k, got, f)
			}
		}
		polygons := false
		for p in m.parts do polygons ||= len(p.polys) > 0
		testing.expectf(t, polygons == c.polygons, "%s: polygons %v", c.file, polygons)
		testing.expectf(t, m.rig.skins == c.rig.skins && m.rig.animations == c.rig.animations && (c.rig.shapes == 0 || m.rig.shapes == c.rig.shapes), "%s: rig %v, want %v", c.file, m.rig, c.rig)
		testing.expectf(t, strings.contains(note, c.note_has), "%s: note %q lacks %q", c.file, note, c.note_has)
	}
}

// A file whose meshes sit under one node, or under none, goes in one folder named after
// the file, as a lone root node is the file itself; the nodes under the one they share
// nest inside it, cut to FOLDER_DEPTH_MAX folders.
@(test)
import_one_holder_is_the_files_folder :: proc(t: ^testing.T) {
	joined :: proc(paths: [][]string, k: int) -> string {return strings.join(paths[k], "/", context.temp_allocator)}
	root := []string{"RootNode"}
	parts := []geom.Mesh_Part{{folders = root}, {folders = root}}
	got := import_folder_paths(parts, "statue")
	testing.expect_value(t, joined(got, 0), "statue")
	testing.expect_value(t, joined(got, 1), "statue")
	testing.expect_value(t, import_folder_count(got), 1)
	parts[1].folders = nil
	got = import_folder_paths(parts, "statue")
	testing.expect_value(t, joined(got, 0), "statue/RootNode")
	testing.expect_value(t, joined(got, 1), "statue")
	head := []string{"RootNode", "Head"}
	eyes := []string{"RootNode", "Head", "Eyes"}
	parts[0].folders, parts[1].folders = head, eyes
	got = import_folder_paths(parts, "statue")
	testing.expect_value(t, joined(got, 0), "statue")
	testing.expect_value(t, joined(got, 1), "statue/Eyes")
	deep: [40]string
	for &d in deep do d = "Bone"
	parts[1].folders = deep[:]
	got = import_folder_paths(parts, "statue")
	testing.expect_value(t, len(got[1]), FOLDER_DEPTH_MAX)
	// The file's folder, RootNode and Head, and the bones up to the deepest.
	testing.expect_value(t, import_folder_count(got), FOLDER_DEPTH_MAX + 2)
}

@(private = "file")
file_stem :: proc(path: string) -> string {
	base := path[strings.last_index_byte(path, '/') + 1:]
	if dot := strings.last_index_byte(base, '.'); dot > 0 do return base[:dot]
	return base
}
