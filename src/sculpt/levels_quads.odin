package sculpt

import "core:slice"

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

// Where a level's polygons come from, as a key for whatever is built from them (the
// edges the app's wireframe draws): how many there are and the memory holding their
// corners, which every set or drop changes. Zero for a level that is triangles only.
Polygon_Source :: struct {
	polygons: int,
	corners:  rawptr,
}

// Level `level`'s polygons: its own under a Catmull-Clark rule (every level has them),
// otherwise the quads of a retopologized object's base level.
levels_polygon_source :: proc(l: ^Levels, level: int) -> Polygon_Source {
	lv := l.levels[level]
	if lv.polys.first != nil do return {len(lv.polys.first) - 1, raw_data(lv.polys.corners)}
	if level == 0 && l.faces.quads != nil do return {len(l.faces.quads), raw_data(l.faces.quads)}
	return {}
}

// The edges of level `level`'s polygons (levels_polygon_source) as pairs of its vertices,
// lower first, each edge once however many polygons share it, in order of (lower, higher):
// what a wireframe draws to show the polygons rather than the triangles they are cut
// into. Nil for a level that is triangles only. Made with `allocator`.
levels_polygon_edges :: proc(l: ^Levels, level: int, allocator := context.temp_allocator) -> []u32 {
	lv := l.levels[level]
	keys: [dynamic]u64
	defer delete(keys)
	edge := proc(keys: ^[dynamic]u64, a, b: u32) {
		lo, hi := min(a, b), max(a, b)
		if lo != hi do append(keys, u64(lo) << 32 | u64(hi))
	}
	if lv.polys.first != nil {
		p := &lv.polys
		keys = make([dynamic]u64, 0, len(p.corners))
		for f in 0 ..< len(p.first) - 1 {
			c := p.corners[p.first[f]:p.first[f + 1]]
			for k in 0 ..< len(c) do edge(&keys, c[k], c[(k + 1) % len(c)])
		}
	} else if level == 0 && l.faces.quads != nil {
		keys = make([dynamic]u64, 0, 4 * len(l.faces.quads))
		for q in l.faces.quads do for k in 0 ..< 4 do edge(&keys, q[k], q[(k + 1) % 4])
	} else {
		return nil
	}
	slice.sort(keys[:])
	unique := slice.unique(keys[:])
	pairs := make([]u32, 2 * len(unique), allocator)
	for key, i in unique do pairs[2 * i], pairs[2 * i + 1] = u32(key >> 32), u32(key & 0xffff_ffff)
	return pairs
}
