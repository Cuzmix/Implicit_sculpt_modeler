package uv

import "core:math"
import "core:slice"

import "../geom"

// UVs on any triangle mesh: a texture coordinate per triangle corner, the seams that cut
// the surface into islands, the islands themselves and the pinned vertices, for the
// base level of an object (sculpt.Levels keeps one). A coordinate is kept per corner, not
// per vertex, since a vertex on a seam has one on each side; v runs up, as
// geom.Uv_Layout's does. Everything follows the triangle numbering of the mesh it was
// made for, so whoever renumbers the triangles renumbers these with them.
//
// A quad object's layout (geom.Uv_Layout, a coordinate per quad corner) folds into this
// (from_quads) and is seen again as quads (to_quads) by what bakes and exports quads.

// The edges of a triangle that are seams: edge k runs from corner k to corner (k + 1) % 3.
Seams :: bit_set[0 ..< 3;u8]

Uvs :: struct {
	corner:  [][3][2]f32, // per triangle, per corner; nil when the mesh has no UVs
	seam:    []Seams,     // per triangle; both triangles of an edge agree (check proves it)
	island:  []u32,       // per triangle
	islands: int,
	pins:    []u32,       // vertices whose coordinates hold still, ascending, each once
	filled:  f32,         // share of the unit square the islands' boxes cover
}

destroy :: proc(u: ^Uvs, allocator := context.allocator) {
	delete(u.corner, allocator)
	delete(u.seam, allocator)
	delete(u.island, allocator)
	delete(u.pins, allocator)
	u^ = {}
}

has :: proc(u: Uvs) -> bool {return u.corner != nil}

// Bytes `u` holds, counted toward the undo memory limit and the exit stats.
bytes :: proc(u: Uvs) -> int {
	return len(u.corner) * size_of([3][2]f32) + len(u.seam) * size_of(Seams) + len(u.island) * size_of(u32) + len(u.pins) * size_of(u32)
}

clone :: proc(u: Uvs, allocator := context.allocator) -> (c: Uvs) {
	if !has(u) do return
	c = u
	c.corner = slice.clone(u.corner, allocator)
	c.seam = slice.clone(u.seam, allocator)
	c.island = slice.clone(u.island, allocator)
	c.pins = slice.clone(u.pins, allocator)
	return
}

// Room for `triangles`, every coordinate zero, no seams, one island, nothing pinned.
make_uvs :: proc(triangles: int, allocator := context.allocator) -> (u: Uvs) {
	u.corner = make([][3][2]f32, triangles, allocator)
	u.seam = make([]Seams, triangles, allocator)
	u.island = make([]u32, triangles, allocator)
	u.islands = 1 if triangles > 0 else 0
	return
}

// The triangle across edge `k` of triangle `t` (corner k to corner k + 1) and the number
// of that edge in it, which runs the other way; false on a border. Where more than two
// triangles share the edge, the lowest numbered one that runs the other way, so the
// answer never depends on anything but the mesh.
across :: proc(indices: []u32, faces: geom.Vertex_Faces, t: u32, k: int) -> (t2: u32, k2: int, ok: bool) {
	a, b := indices[3 * t + u32(k)], indices[3 * t + u32((k + 1) % 3)]
	for o in geom.vertex_faces_of(faces, b) {
		if o == t do continue
		tri := indices[3 * o:][:3]
		for j in 0 ..< 3 do if tri[j] == b && tri[(j + 1) % 3] == a do return o, j, true
	}
	return
}

// Marks a seam on every edge whose two triangles disagree: on the coordinates at either
// end, or (when `u.island` is already set) on the island. Borders are not seams: nothing
// lies across them.
seams_from_breaks :: proc(u: ^Uvs, indices: []u32, faces: geom.Vertex_Faces) {
	for &s in u.seam do s = {}
	for t in 0 ..< len(u.corner) {
		for k in 0 ..< 3 {
			o, j, ok := across(indices, faces, u32(t), k)
			if !ok do continue
			here := u.corner[t]
			there := u.corner[o]
			// Corner k of t is corner j + 1 of o; corner k + 1 of t is corner j of o.
			if here[k] != there[(j + 1) % 3] || here[(k + 1) % 3] != there[j] || u.island[t] != u.island[o] {
				u.seam[t] += {k}
			}
		}
	}
}

// Numbers the islands: triangles joined across edges that are not seams, numbered in the
// order of their lowest triangle, then works out how much of the unit square their boxes
// cover.
islands_find :: proc(u: ^Uvs, indices: []u32, faces: geom.Vertex_Faces) {
	count := len(u.corner)
	parent := make([]u32, count, context.temp_allocator)
	for &p, t in parent do p = u32(t)
	root :: proc(parent: []u32, t: u32) -> u32 {
		t := t
		for parent[t] != t {
			parent[t] = parent[parent[t]]
			t = parent[t]
		}
		return t
	}
	for t in 0 ..< count {
		for k in 0 ..< 3 {
			if k in u.seam[t] do continue
			o, _, ok := across(indices, faces, u32(t), k)
			if !ok do continue
			a, b := root(parent, u32(t)), root(parent, o)
			// The lower root wins, so every island's root is its lowest triangle.
			if a < b do parent[b] = a
			else if b < a do parent[a] = b
		}
	}
	number := make([]u32, count, context.temp_allocator)
	islands: u32 = 0
	for t in 0 ..< count {
		r := root(parent, u32(t))
		if r == u32(t) {
			number[t] = islands
			islands += 1
		}
		u.island[t] = number[r]
	}
	u.islands = int(islands)
	u.filled = boxes_filled(u^)
}

// The share of the unit square the islands' boxes cover, each box clipped to the square.
@(private)
boxes_filled :: proc(u: Uvs) -> f32 {
	if u.islands == 0 do return 0
	lo := make([][2]f32, u.islands, context.temp_allocator)
	hi := make([][2]f32, u.islands, context.temp_allocator)
	for &l in lo do l = {math.F32_MAX, math.F32_MAX}
	for &h in hi do h = {-math.F32_MAX, -math.F32_MAX}
	for c, t in u.corner {
		i := u.island[t]
		for p in c {
			lo[i] = {min(lo[i].x, p.x), min(lo[i].y, p.y)}
			hi[i] = {max(hi[i].x, p.x), max(hi[i].y, p.y)}
		}
	}
	area: f32 = 0
	for i in 0 ..< u.islands {
		a := [2]f32{clamp(lo[i].x, 0, 1), clamp(lo[i].y, 0, 1)}
		b := [2]f32{clamp(hi[i].x, 0, 1), clamp(hi[i].y, 0, 1)}
		area += max(b.x - a.x, 0) * max(b.y - a.y, 0)
	}
	return min(area, 1)
}

// UVs from a file's: one coordinate per corner of its triangles (`file_uvs`, v down from
// the image's top, as geom.Mesh_Part keeps them), for the mesh `indices` whose triangle t
// was the file's triangle tri_from[t] (nil: the same numbering) with its corners in the
// same order. Seams fall where neighbours disagree, and islands follow from them.
from_corners :: proc(indices: []u32, file_uvs: [][2]f32, tri_from: []u32, faces: geom.Vertex_Faces, allocator := context.allocator) -> (u: Uvs) {
	count := len(indices) / 3
	assert(len(file_uvs) == len(indices), "one coordinate a corner")
	assert(tri_from == nil || len(tri_from) == count)
	u = make_uvs(count, allocator)
	for &c, t in u.corner {
		from := tri_from[t] if tri_from != nil else u32(t)
		for k in 0 ..< 3 {
			p := file_uvs[3 * from + u32(k)]
			c[k] = {p.x, 1 - p.y}
		}
	}
	seams_from_breaks(&u, indices, faces)
	islands_find(&u, indices, faces)
	return
}

// For each corner of the triangles `indices` over `q`'s vertices (with `faces`), the
// slot it takes among the quads' halves: slot s is quad s / 6, half (s % 6) / 3, corner
// s % 3 of that half (geom.quad_halves). False when a triangle is no half of a quad.
@(private)
half_slots :: proc(q: geom.Quad_Mesh, indices: []u32, faces: geom.Vertex_Faces) -> (slots: []u32, ok: bool) {
	split := make([]u32, 6 * len(q.quads), context.temp_allocator)
	for &s, i in split do s = u32(i)
	return geom.quad_mesh_triangle_corners(q, split, indices, faces, context.temp_allocator)
}

// A quad object's layout folded into UVs for the triangles `indices` it is drawn as:
// each triangle corner takes its quad corner's coordinate and each triangle its quad's
// chart, which stays its island, so to_quads gives the layout back as it was. False,
// with nothing made, when a triangle is no half of a quad.
from_quads :: proc(l: geom.Uv_Layout, q: geom.Quad_Mesh, indices: []u32, faces: geom.Vertex_Faces, allocator := context.allocator) -> (u: Uvs, ok: bool) {
	assert(len(l.uvs) == len(q.quads))
	slots := half_slots(q, indices, faces) or_return
	u = make_uvs(len(indices) / 3, allocator)
	for t in 0 ..< len(u.corner) {
		for k in 0 ..< 3 {
			s := int(slots[3 * t + k])
			i, h := s / 6, s % 6 / 3
			u.corner[t][k] = l.uvs[i][geom.quad_halves(q, i)[h][s % 3]]
		}
		u.island[t] = l.chart[int(slots[3 * t]) / 6]
	}
	u.islands, u.filled = l.charts, l.filled
	seams_from_breaks(&u, indices, faces)
	return u, true
}

// UVs seen as a quad layout, for whatever bakes or exports quads: each quad corner takes
// the coordinate of the first of the quad's halves that holds it, each quad the island
// of its first half. False when a triangle is no half of a quad. Made with `allocator`.
to_quads :: proc(u: Uvs, q: geom.Quad_Mesh, indices: []u32, faces: geom.Vertex_Faces, allocator := context.temp_allocator) -> (l: geom.Uv_Layout, ok: bool) {
	assert(len(u.corner) == len(indices) / 3)
	slots := half_slots(q, indices, faces) or_return
	at := make([][2]f32, 6 * len(q.quads), context.temp_allocator)
	owner := make([]u32, 6 * len(q.quads), context.temp_allocator)
	for t in 0 ..< len(u.corner) {
		for k in 0 ..< 3 {
			at[slots[3 * t + k]] = u.corner[t][k]
			owner[slots[3 * t + k]] = u32(t)
		}
	}
	l.uvs = make([][4][2]f32, len(q.quads), allocator)
	l.chart = make([]u32, len(q.quads), allocator)
	for i in 0 ..< len(q.quads) {
		halves := geom.quad_halves(q, i)
		done: [4]bool
		for h in 0 ..< 2 {
			for k in 0 ..< 3 {
				corner := halves[h][k]
				if done[corner] do continue
				l.uvs[i][corner] = at[6 * i + 3 * h + k]
				done[corner] = true
			}
		}
		l.chart[i] = u.island[owner[6 * i]]
	}
	l.charts, l.filled = u.islands, u.filled
	return l, true
}

// Why `u` does not fit the mesh `indices` over `vertices` vertices (with `faces`), ""
// when it does: a count that differs, a coordinate that is not finite, a seam on one side
// of an edge only, an island out of range, or pins out of order or range.
check :: proc(u: Uvs, indices: []u32, faces: geom.Vertex_Faces, vertices: int) -> string {
	count := len(indices) / 3
	if len(u.corner) != count || len(u.seam) != count || len(u.island) != count do return "the counts differ from the triangles'"
	if u.islands < 0 || u.islands > count do return "more islands than triangles"
	for c in u.corner do for p in c do if math.is_nan(p.x) || math.is_nan(p.y) || math.is_inf(p.x) || math.is_inf(p.y) do return "a coordinate is not finite"
	for i in u.island do if int(i) >= u.islands do return "an island is out of range"
	for t in 0 ..< count {
		for k in 0 ..< 3 {
			o, j, ok := across(indices, faces, u32(t), k)
			if !ok do continue
			// Where more than two triangles share an edge, only a pair that finds each
			// other is held to agree.
			if back, _, _ := across(indices, faces, o, j); back != u32(t) do continue
			if (k in u.seam[t]) != (j in u.seam[o]) do return "a seam is on one side of its edge only"
		}
	}
	for p, i in u.pins {
		if int(p) >= vertices do return "a pin is out of range"
		if i > 0 && u.pins[i - 1] >= p do return "the pins are not in order"
	}
	return ""
}
