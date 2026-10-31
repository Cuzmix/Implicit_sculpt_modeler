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
		folders:    []string, // each part's folder on import, in order
		polygons:   bool,
		rig:        geom.Rig_Found,
		note_has:   string,
	}
	DIR :: #directory + "testdata/import/"
	cases := []Case {
		{DIR + "cubes.obj", 2, {"cubes", "cubes"}, true, {}, "its quads and polygons stay"},
		{DIR + "cube.ply", 1, {"cube"}, true, {}, "its quads and polygons stay"},
		{DIR + "tet.stl", 1, {"tet"}, false, {}, "4 vertices, 4 triangles"},
		{DIR + "rig.gltf", 3, {"Character", "Arms", "rig"}, false, {skins = 1, animations = 1, shapes = 2}, "1 skin, 1 animation and 2 shape keys found and left out"},
		{DIR + "rig.usda", 2, {"Character", "Props"}, false, {skins = 1, animations = 1, shapes = 1}, "1 skin, 1 animation and 1 shape key found and left out"},
		{#directory + "../../deps/ufbx-src/data/blender_279_sausage_7400_binary.fbx", 1, {"blender_279_sausage_7400_binary"}, true, {skins = 1, animations = 3}, "found and left out"},
	}
	for c in cases {
		m, note, _, ok := mesh_import_load(c.file, "Imported", nil)
		defer delete(note)
		defer mesh_import_free(&m)
		if !testing.expectf(t, ok, "%s: %s", c.file, note) do continue
		testing.expectf(t, len(m.parts) == c.parts, "%s: %d parts, want %d", c.file, len(m.parts), c.parts)
		if len(m.parts) == len(c.folders) {
			got := import_folder_names(m.parts[:], file_stem(c.file))
			for f, k in c.folders do testing.expectf(t, got[k] == f, "%s: part %d in %q, want %q", c.file, k, got[k], f)
		}
		polygons := false
		for p in m.parts do polygons ||= len(p.polys) > 0
		testing.expectf(t, polygons == c.polygons, "%s: polygons %v", c.file, polygons)
		testing.expectf(t, m.rig.skins == c.rig.skins && m.rig.animations == c.rig.animations && (c.rig.shapes == 0 || m.rig.shapes == c.rig.shapes), "%s: rig %v, want %v", c.file, m.rig, c.rig)
		testing.expectf(t, strings.contains(note, c.note_has), "%s: note %q lacks %q", c.file, note, c.note_has)
	}
}

// A file whose meshes sit under one node, or under none, goes in one folder named after
// the file, as a lone root node is the file itself.
@(test)
import_one_holder_is_the_files_folder :: proc(t: ^testing.T) {
	parts := []geom.Mesh_Part{{folder = "RootNode"}, {folder = "RootNode"}}
	got := import_folder_names(parts, "statue")
	testing.expect_value(t, got[0], "statue")
	testing.expect_value(t, got[1], "statue")
	parts[1].folder = ""
	got = import_folder_names(parts, "statue")
	testing.expect_value(t, got[0], "RootNode")
	testing.expect_value(t, got[1], "statue")
}

@(private = "file")
file_stem :: proc(path: string) -> string {
	base := path[strings.last_index_byte(path, '/') + 1:]
	if dot := strings.last_index_byte(base, '.'); dot > 0 do return base[:dot]
	return base
}
