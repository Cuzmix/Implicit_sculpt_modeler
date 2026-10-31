package main

import "core:log"
import "core:slice"

import "../geom"
import "../retopo"
import "../sculpt"

// The polygons and creases of the level the object is on, for Mirror and weld to keep,
// and the rule its levels above follow: the level's own under a Catmull-Clark rule, or
// on the base level the quads a retopologized object keeps without them, each quad's two
// triangles found among those round its first and third corners. Empty for a level of
// triangles only. Borrowed from the levels, or temporary.
object_level_polygons :: proc(obj: ^Object) -> (polygons: geom.Polygons, creases: geom.Creases, rule: sculpt.Subdivision_Rule) {
	l := &obj.levels
	lv := l.levels[l.current]
	rule = l.rule if l.rule != .Loop else .Smooth
	if p := &lv.polys; p.first != nil {
		polygons = {p.first, p.corners, p.tri_poly}
		creases = {lv.sharp.edges, lv.sharp.edge, lv.sharp.verts, lv.sharp.vert}
		return
	}
	if l.current != 0 || !sculpt.levels_has_quads(l) do return
	quads := l.faces.quads
	indices := lv.mesh.indices[:]
	first := make([]u32, len(quads) + 1, context.temp_allocator)
	corners := make([]u32, 4 * len(quads), context.temp_allocator)
	tri_poly := make([]u32, len(indices) / 3, context.temp_allocator)
	slice.fill(tri_poly, max(u32))
	for &q, f in quads {
		first[f + 1] = u32(4 * (f + 1))
		copy(corners[4 * f:][:4], q[:])
		for c in ([2]u32{q[0], q[2]}) {
			for t in geom.vertex_faces_of(lv.sculptor.faces, c) {
				tri := indices[3 * t:][:3]
				inside := true
				for v in tri do inside &&= slice.contains(q[:], v)
				if inside do tri_poly[t] = u32(f)
			}
		}
	}
	// A triangle of no quad (a quad mesh some edit changed) leaves the mesh triangles.
	for f in tri_poly do if f == max(u32) do return
	polygons = {first, corners, tri_poly}
	return
}

// Gives the levels just rebuilt from a mirrored mesh (levels_init with the renumbering
// maps) the polygons and creases Mirror and weld kept, in that mesh's numbers, under
// `rule`, taking `polys`; an object of only quads keeps them as quads too, for export and
// UV layout, as an imported quad mesh does (import_take_polygons). The quads' UVs do not
// come through: the cut changed the faces they were laid out on.
symmetrize_take_polygons :: proc(l: ^sculpt.Levels, polys: ^sculpt.Polys, creases: geom.Creases, rule: sculpt.Subdivision_Rule, old_to_new, tri_from: []u32) {
	retopo.polys_renumber(polys, old_to_new, tri_from)
	sharp := symmetrize_sharp(creases, old_to_new)
	quads := true
	for f in 0 ..< len(polys.first) - 1 do quads &&= polys.first[f + 1] - polys.first[f] == 4
	if !sculpt.levels_set_polys(l, polys^, sharp, rule) {
		log.error("mirror and weld: the polygons did not fit the triangles cut from them, so the object keeps triangles")
		return
	}
	if !quads do return
	faces := make([][4]u32, len(polys.first) - 1)
	for &f, q in faces do copy(f[:], polys.corners[4 * q:][:4])
	sculpt.levels_set_quads(l, faces)
}

// The creases in the levels' numbers (each vertex v at old_to_new[v]), sorted by key as
// sculpt.Sharp keeps them.
@(private = "file")
symmetrize_sharp :: proc(c: geom.Creases, old_to_new: []u32) -> (s: sculpt.Sharp) {
	if len(c.edges) == 0 && len(c.verts) == 0 do return
	Edge :: struct {
		key:   u64,
		sharp: f32,
	}
	Vert :: struct {
		v:     u32,
		sharp: f32,
	}
	edges := make([]Edge, len(c.edges), context.temp_allocator)
	for key, i in c.edges do edges[i] = {sculpt.sharp_key(old_to_new[key >> 32], old_to_new[key & 0xffff_ffff]), c.edge[i]}
	verts := make([]Vert, len(c.verts), context.temp_allocator)
	for v, i in c.verts do verts[i] = {old_to_new[v], c.vert[i]}
	slice.sort_by(edges, proc(x, y: Edge) -> bool {return x.key < y.key})
	slice.sort_by(verts, proc(x, y: Vert) -> bool {return x.v < y.v})
	s.edges, s.edge = make([]u64, len(edges)), make([]f32, len(edges))
	for e, i in edges do s.edges[i], s.edge[i] = e.key, e.sharp
	s.verts, s.vert = make([]u32, len(verts)), make([]f32, len(verts))
	for v, i in verts do s.verts[i], s.vert[i] = v.v, v.sharp
	return
}
