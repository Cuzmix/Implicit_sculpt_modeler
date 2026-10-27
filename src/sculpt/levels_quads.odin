package sculpt

import "../geom"

// The quads a retopologized object was made of, and their UVs (geom.mesh_retopo,
// geom.quad_uv_unwrap): the base level is drawn and sculpted as their triangles, two a
// quad, and these let it be exported as quads and baked onto. They follow the base
// level's vertex numbers and stay while its triangles do: deleting the levels below,
// or dynamic topology, which change the base's triangles, drops them.
Quad_Faces :: struct {
	quads: [][4]u32,       // nil when the object is not made of quads
	uv:    geom.Uv_Layout, // empty until UVs are laid out
}

// Takes `quads` (in the base level's vertex numbers) as the object's quads, without UVs.
levels_set_quads :: proc(l: ^Levels, quads: [][4]u32) {
	levels_drop_quads(l)
	l.faces.quads = quads
}

// Takes `uv` (one entry per quad) as the quads' UVs.
levels_set_uvs :: proc(l: ^Levels, uv: geom.Uv_Layout) {
	assert(len(uv.uvs) == len(l.faces.quads))
	geom.uv_layout_destroy(&l.faces.uv, l.allocator)
	l.faces.uv = uv
}

levels_has_quads :: proc(l: ^Levels) -> bool {return l.faces.quads != nil}
levels_has_uvs :: proc(l: ^Levels) -> bool {return l.faces.uv.uvs != nil}

levels_drop_quads :: proc(l: ^Levels) {
	delete(l.faces.quads, l.allocator)
	geom.uv_layout_destroy(&l.faces.uv, l.allocator)
	l.faces = {}
}

// The base level as a quad mesh: its positions and the quads, not copied, and which way
// each quad's triangles are split there (geom.Quad_Mesh.across, made with `allocator`).
levels_quad_mesh :: proc(l: ^Levels, allocator := context.temp_allocator) -> geom.Quad_Mesh {
	base := l.levels[0]
	q := geom.Quad_Mesh{positions = base.mesh.positions[:], quads = l.faces.quads}
	if q.quads != nil do q.across = geom.quad_mesh_diagonals(q, base.mesh.indices[:], base.sculptor.faces, allocator)
	return q
}
