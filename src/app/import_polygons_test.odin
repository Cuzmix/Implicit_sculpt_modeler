package main

import "core:testing"

import "../geom"
import "../sculpt"

// An imported OBJ of quads and a triangle becomes an object whose base level keeps the
// file's faces: Wireframe draws their edges (no diagonals), an object of only quads keeps
// them as quads for the UV tools, and Subdivide cuts them as Catmull-Clark does.
@(test)
import_keeps_the_files_polygons :: proc(t: ^testing.T) {
	// A cube of six quads, the first of them cut into two triangles in one of the files.
	CUBE :: "v -1 -1 -1\nv 1 -1 -1\nv 1 1 -1\nv -1 1 -1\nv -1 -1 1\nv 1 -1 1\nv 1 1 1\nv -1 1 1\n"
	SIDES :: "f 5 6 7 8\nf 1 2 6 5\nf 2 3 7 6\nf 3 4 8 7\nf 4 1 5 8\n"
	for split in ([2]bool{true, false}) {
		source := CUBE + "f 1 4 3\nf 1 3 2\n" + SIDES if split else CUBE + "f 1 4 3 2\n" + SIDES
		parts: [dynamic]geom.Mesh_Part
		defer geom.mesh_parts_destroy(&parts)
		err, _ := geom.mesh_read_obj_parts(&parts, transmute([]u8)source, nil)
		if !testing.expect_value(t, err, geom.Mesh_File_Error.None) do return
		p := &parts[0]
		_, clean_err := geom.mesh_clean(&p.mesh, nil, &p.colors, &p.groups, &p.polys)
		testing.expect_value(t, clean_err, geom.Mesh_File_Error.None)

		polys: sculpt.Polys
		polys.first, polys.corners, polys.tri_poly = geom.mesh_polygons(p.mesh.indices[:], p.polys[:])
		if !testing.expect(t, polys.first != nil, "the quads were lost") do return
		old_to_new := make([]u32, len(p.mesh.positions))
		defer delete(old_to_new)
		tri_from := make([]u32, len(p.mesh.indices) / 3)
		defer delete(tri_from)
		l: sculpt.Levels
		defer sculpt.levels_destroy(&l)
		mesh := p.mesh
		p.mesh = {}
		sculpt.levels_init(&l, mesh, nil, 4, old_to_new = old_to_new, tri_from = tri_from)
		import_take_polygons(&l, &polys, old_to_new, tri_from)

		// A cube has 12 edges; the cut quad's diagonal is a 13th.
		edges := sculpt.levels_polygon_edges(&l, 0)
		testing.expect_value(t, len(edges) / 2, 13 if split else 12)
		testing.expect_value(t, sculpt.levels_has_quads(&l), !split)
		testing.expect_value(t, l.rule, sculpt.Subdivision_Rule.Smooth)

		// Catmull-Clark: each quad gives four, each triangle three, all quads.
		if !testing.expect(t, sculpt.levels_subdivide(&l)) do continue
		up := l.levels[1]
		testing.expect_value(t, len(up.polys.first) - 1, 5 * 4 + 2 * 3 if split else 24)
		quads := true
		for f in 0 ..< len(up.polys.first) - 1 do quads &&= up.polys.first[f + 1] - up.polys.first[f] == 4
		testing.expect(t, quads, "a level above the file's polygons is all quads")
	}
}
