package sculpt

import "core:log"
import "core:slice"

import "../geom"
import "../jobs"
import "../uv"

// The quads a retopologized object was made of (geom.mesh_retopo): the base level is
// drawn and sculpted as their triangles, two a quad, and these let it be exported as
// quads and baked onto. They follow the base level's vertex numbers and stay while its
// triangles do: deleting the levels below, or dynamic topology, which change the base's
// triangles, drops them, and its UVs (Levels.uvs) with them.
Quad_Faces :: struct {
	quads: [][4]u32, // nil when the object is not made of quads
}

// Takes `quads` (in the base level's vertex numbers) as the object's quads. The object's
// UVs stay: whoever sets quads on levels that have UVs sets UVs that fit them.
levels_set_quads :: proc(l: ^Levels, quads: [][4]u32) {
	delete(l.faces.quads, l.allocator)
	l.faces.quads = quads
}

// Takes `layout` (one entry per quad, taken) as the object's UVs, folded onto the base
// level's triangles (uv.from_quads). False, keeping no UVs, when a base triangle is no
// half of a quad, which a quad object's base never has.
levels_set_uvs :: proc(l: ^Levels, layout: geom.Uv_Layout) -> bool {
	layout := layout
	defer geom.uv_layout_destroy(&layout, l.allocator)
	assert(len(layout.uvs) == len(l.faces.quads))
	base := l.levels[0]
	u, ok := uv.from_quads(layout, levels_quad_mesh(l), base.mesh.indices[:], base.sculptor.faces, l.allocator)
	if !ok {
		log.error("UVs: a base triangle is no half of a quad, so the object keeps no UVs")
		levels_drop_uvs(l)
		return false
	}
	levels_take_uvs(l, u)
	return true
}

// `layout` (one entry per quad, not taken) folded onto the base level's triangles, made
// with `allocator`, for a caller that swaps it in itself (Unwrap's undo step). False when
// a base triangle is no half of a quad.
levels_uvs_from_layout :: proc(l: ^Levels, layout: geom.Uv_Layout, allocator := context.allocator) -> (uv.Uvs, bool) {
	assert(len(layout.uvs) == len(l.faces.quads))
	base := l.levels[0]
	return uv.from_quads(layout, levels_quad_mesh(l), base.mesh.indices[:], base.sculptor.faces, allocator)
}

// Takes `u` (made for the base level's triangles, taken) as the object's UVs.
levels_take_uvs :: proc(l: ^Levels, u: uv.Uvs) {
	assert(len(u.corner) == len(l.levels[0].mesh.indices) / 3)
	uv.destroy(&l.uvs, l.allocator)
	l.uvs = u
	l.uv_stamp += 1
}

levels_has_quads :: proc(l: ^Levels) -> bool {return l.faces.quads != nil}
// Whether the object has UVs, on whatever triangles its base level has.
levels_has_uvs :: proc(l: ^Levels) -> bool {return uv.has(l.uvs)}
// Whether the object is made of quads and has UVs, which baking, the texture views and
// quad exports need.
levels_has_quad_uvs :: proc(l: ^Levels) -> bool {return levels_has_quads(l) && levels_has_uvs(l)}

// The object's UVs seen as its quads' layout (uv.to_quads), made with `allocator`; false
// without quads and UVs.
levels_quad_uvs :: proc(l: ^Levels, allocator := context.temp_allocator) -> (layout: geom.Uv_Layout, ok: bool) {
	if !levels_has_quad_uvs(l) do return
	base := l.levels[0]
	return uv.to_quads(l.uvs, levels_quad_mesh(l), base.mesh.indices[:], base.sculptor.faces, allocator)
}

levels_drop_uvs :: proc(l: ^Levels) {
	uv.destroy(&l.uvs, l.allocator)
	l.uv_stamp += 1
}

// Drops the quads and the UVs, for whatever changes the base level's triangles.
levels_drop_quads :: proc(l: ^Levels) {
	delete(l.faces.quads, l.allocator)
	l.faces = {}
	levels_drop_uvs(l)
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

// Level `level`'s polygon edges (`pairs`, as levels_polygon_edges makes them: lower first,
// sorted) again per triangle, as the wireframe drawn in the shading reads them
// (render.Mesh_Buffers.tri_edges): four bits a triangle, eight triangles a word, the first
// lowest, bit k set where the edge across from the triangle's corner k is a polygon's
// edge and clear where it only cuts a polygon into triangles (a quad's diagonal). Made
// with `allocator`, in parallel over words, the same on every run.
levels_polygon_tri_edges :: proc(l: ^Levels, level: int, pairs: []u32, allocator := context.allocator) -> []u32 {
	indices := l.levels[level].mesh.indices[:]
	tris := len(indices) / 3
	Work :: struct {
		indices: []u32,
		pairs:   []u32,
		first:   []u32, // where each lower vertex's edges start in pairs (by pair), up to the last lower vertex
		words:   []u32,
		tris:    int,
	}
	w := Work{indices = indices, pairs = pairs, tris = tris}
	w.words = make([]u32, (tris + 7) / 8, allocator)
	// The pairs are sorted by their lower vertex, so each one's run is found by counting.
	last := u32(0)
	for i := 0; i < len(pairs); i += 2 do last = max(last, pairs[i])
	w.first = make([]u32, int(last) + 2, context.allocator)
	defer delete(w.first)
	for i := 0; i < len(pairs); i += 2 do w.first[pairs[i] + 1] += 1
	for v in 1 ..< len(w.first) do w.first[v] += w.first[v - 1]
	jobs.parallel_ranges(l.pool, len(w.words), &w, proc(data: rawptr, lo, hi: int) {
		w := (^Work)(data)
		has :: proc(w: ^Work, a, b: u32) -> bool {
			lo, hi := min(a, b), max(a, b)
			if int(lo) + 1 >= len(w.first) do return false
			for e in w.first[lo] ..< w.first[lo + 1] do if w.pairs[2 * e + 1] == hi do return true
			return false
		}
		for word in lo ..< hi {
			bits: u32
			for k in 0 ..< 8 {
				t := 8 * word + k
				if t >= w.tris do break
				a, b, c := w.indices[3 * t], w.indices[3 * t + 1], w.indices[3 * t + 2]
				drawn := u32(0)
				if has(w, b, c) do drawn |= 1
				if has(w, c, a) do drawn |= 2
				if has(w, a, b) do drawn |= 4
				bits |= drawn << (4 * u32(k))
			}
			w.words[word] = bits
		}
	}, grain = 1 << 14)
	return w.words
}
