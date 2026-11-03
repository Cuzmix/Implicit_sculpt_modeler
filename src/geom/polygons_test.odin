package geom

import "core:slice"
import "core:testing"

import "../jobs"

// The polygons an OBJ or PLY text's parts come back as, after the cleaning an import does.
@(private = "file")
read_polygons :: proc(t: ^testing.T, text: string, ply := false, loc := #caller_location) -> (first, corners, tri_poly: []u32) {
	parts: [dynamic]Mesh_Part
	defer mesh_parts_destroy(&parts)
	if ply {
		p: Mesh_Part
		err: Mesh_File_Error
		p.mesh, err, _ = mesh_read_ply(transmute([]u8)text, nil, polys = &p.polys)
		testing.expect_value(t, err, Mesh_File_Error.None, loc = loc)
		append(&parts, p)
	} else {
		err, _ := mesh_read_obj_parts(&parts, transmute([]u8)text, nil)
		testing.expect_value(t, err, Mesh_File_Error.None, loc = loc)
	}
	if len(parts) != 1 do return
	p := &parts[0]
	_, err := mesh_clean(&p.mesh, nil, &p.colors, &p.groups, &p.polys)
	testing.expect_value(t, err, Mesh_File_Error.None, loc = loc)
	return mesh_polygons(p.mesh.indices[:], p.polys[:])
}

@(private = "file")
polygons_free :: proc(first, corners, tri_poly: []u32) {
	delete(first)
	delete(corners)
	delete(tri_poly)
}

// Two quads side by side, a triangle and a pentagon: each comes back as the file's face,
// corners in the file's order, its triangles naming it.
@(test)
obj_faces_come_back_as_polygons :: proc(t: ^testing.T) {
	text := `v 0 0 0
v 1 0 0
v 2 0 0
v 0 1 0
v 1 1 0
v 2 1 0
v 3 0.5 0
v 2.5 -1 0
v 3.5 -1 0
v 4 0 0
f 1 2 5 4
f 2 3 6 5
f 3 8 7
f 8 9 10 7 6/1/1
`
	first, corners, tri_poly := read_polygons(t, text)
	defer polygons_free(first, corners, tri_poly)
	testing.expect(t, slice.equal(first, []u32{0, 4, 8, 11, 16}), "four polygons of 4, 4, 3 and 5 corners")
	testing.expect(t, slice.equal(corners, []u32{0, 1, 4, 3, 1, 2, 5, 4, 2, 7, 6, 7, 8, 9, 6, 5}), "corners in the file's order")
	testing.expect(t, slice.equal(tri_poly, []u32{0, 0, 1, 1, 2, 3, 3, 3}), "each fan's triangles name their face")
}

// A file of only triangles has no polygons to keep.
@(test)
obj_of_triangles_keeps_no_polygons :: proc(t: ^testing.T) {
	first, corners, tri_poly := read_polygons(t, "v 0 0 0\nv 1 0 0\nv 0 1 0\nv 1 1 0\nf 1 2 3\nf 2 4 3\n")
	defer polygons_free(first, corners, tri_poly)
	testing.expect(t, first == nil && corners == nil && tri_poly == nil, "nil for triangles")
}

// Cleaning welds a quad's two corners at one place into a triangle and drops the other
// fan triangle: what is left stays a polygon of its own, and the next quad is untouched.
@(test)
welded_quad_becomes_a_triangle :: proc(t: ^testing.T) {
	text := `v 0 0 0
v 1 0 0
v 1 1 0
v 1 1 0
v 2 0 0
v 2 1 0
f 1 2 3 4
f 2 5 6 3
`
	first, corners, tri_poly := read_polygons(t, text)
	defer polygons_free(first, corners, tri_poly)
	testing.expect(t, slice.equal(first, []u32{0, 3, 7}), "a triangle then a quad")
	testing.expect_value(t, len(tri_poly), 3)
}

// PLY polygons, text and binary forms both going through the fan reader.
@(test)
ply_faces_come_back_as_polygons :: proc(t: ^testing.T) {
	text := `ply
format ascii 1.0
element vertex 6
property float x
property float y
property float z
element face 3
property list uchar int vertex_indices
end_header
0 0 0
1 0 0
2 0 0
0 1 0
1 1 0
2 1 0
4 0 1 4 3
3 1 2 5
3 1 5 4
`
	first, corners, tri_poly := read_polygons(t, text, ply = true)
	defer polygons_free(first, corners, tri_poly)
	testing.expect(t, slice.equal(first, []u32{0, 4, 7, 10}), "a quad then two triangles")
	testing.expect(t, slice.equal(tri_poly, []u32{0, 0, 1, 2}), "the quad's fan names it")
}

// Any cut of a polygon into triangles comes back, whichever way round: an ear-clipped
// hexagon (not a fan) and the same turned over.
@(test)
any_cut_and_either_winding_comes_back :: proc(t: ^testing.T) {
	// Hexagon 0..5 cut into (0 1 2) (2 3 4) (4 5 0) (0 2 4).
	cut := []u32{0, 1, 2, 2, 3, 4, 4, 5, 0, 0, 2, 4}
	ids := []u32{7, 7, 7, 7}
	first, corners, tri_poly := mesh_polygons(cut, ids)
	testing.expect(t, slice.equal(first, []u32{0, 6}), "one hexagon")
	testing.expect(t, slice.equal(corners, []u32{0, 1, 2, 3, 4, 5}), "round in the triangles' order")
	polygons_free(first, corners, tri_poly)

	flipped := slice.clone(cut, context.temp_allocator)
	for k := 0; k < len(flipped); k += 3 do flipped[k + 1], flipped[k + 2] = flipped[k + 2], flipped[k + 1]
	first, corners, tri_poly = mesh_polygons(flipped, ids)
	testing.expect(t, slice.equal(corners, []u32{0, 5, 4, 3, 2, 1}), "turned over, the loop runs the other way")
	polygons_free(first, corners, tri_poly)

	// Two triangles sharing only a corner are not one polygon: each stays its own.
	bow := []u32{0, 1, 2, 0, 3, 4}
	first, corners, tri_poly = mesh_polygons(bow, []u32{1, 1})
	testing.expect(t, slice.equal(first, []u32{0, 3, 6}), "a bow tie stays two triangles")
	polygons_free(first, corners, tri_poly)
}

// Merging many parts keeps each part's polygons apart, numbers renewed in order, a part
// without them a number a triangle.
@(test)
merged_parts_keep_their_polygons :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 2)
	defer jobs.pool_destroy(&pool)
	quad :: proc(id: u32, polygon: bool) -> Mesh_Part {
		p: Mesh_Part
		append(&p.mesh.positions, Vec3{0, 0, 0}, Vec3{1, 0, 0}, Vec3{1, 1, 0}, Vec3{0, 1, 0})
		resize(&p.mesh.normals, 4)
		append(&p.mesh.indices, 0, 1, 2, 0, 2, 3)
		if polygon do append(&p.polys, id, id)
		return p
	}
	parts: [dynamic]Mesh_Part
	defer mesh_parts_destroy(&parts)
	// The same numbers in two parts must not join their quads across the seam.
	append(&parts, quad(5, true), quad(5, true), quad(0, false))
	mesh_parts_merge(&parts)
	testing.expect(t, slice.equal(parts[0].polys[:], []u32{0, 0, 1, 1, 2, 3}), "renumbered per part")
	first, corners, tri_poly := mesh_polygons(parts[0].mesh.indices[:], parts[0].polys[:])
	defer polygons_free(first, corners, tri_poly)
	testing.expect(t, slice.equal(first, []u32{0, 4, 8, 11, 14}), "two quads, then the third part's two triangles")
}
