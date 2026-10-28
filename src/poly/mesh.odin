package poly

import "core:math/linalg"

import "../geom"

// The cage of Model mode: a polygon mesh of any face size kept as half-edges, so the
// modelling actions (extrude, inset, loop insert, bevel, ...) can walk loops and rings
// and change topology locally, the way ZBrush's ZModeler and Blender's edit mode do. It
// knows nothing of drawing or sculpting: the app triangulates it (triangulate.odin) into
// the mesh it draws and sculpts.
//
// Half-edges come in pairs: edge e owns half-edges 2e and 2e + 1, so a half-edge's twin
// is h ~ 1 and its edge h >> 1, and an edge needs no record of its own beyond its
// crease. A face's half-edges run counter-clockwise seen from outside, as every geom
// mesh's triangles do. A half-edge with no face lies on a border; border half-edges are
// linked into loops through next and prev like a face's, which keeps every walk the same.
//
// Topology changes go through an Edit (edit.odin), which builds the cage again, so no
// element is ever left half removed and ids follow from the order of the operations.

Vec3 :: geom.Vec3

// No element: a half-edge on a border has no face.
NONE :: max(u32)
// An edge or corner crease that never softens, however many times the cage is smoothed
// (OpenSubdiv's SHARPNESS_INFINITE).
INFINITE_SHARP :: f32(10)

Mesh :: struct {
	// Per vertex: where it is, one half-edge leaving it (on a border, the border one, so a
	// walk round the vertex starts and ends at the gap), and its corner sharpness.
	positions: [dynamic]Vec3,
	vert_he:   [dynamic]u32,
	corner:    [dynamic]f32,
	// Per half-edge.
	he_next:   [dynamic]u32,
	he_prev:   [dynamic]u32,
	he_vert:   [dynamic]u32, // the vertex it starts at
	he_face:   [dynamic]u32, // NONE on a border
	// Per edge (half-edge pair): its crease, 0 smooth up to INFINITE_SHARP.
	crease:    [dynamic]f32,
	// Per face: one of its half-edges, and its polygroup.
	face_he:   [dynamic]u32,
	group:     [dynamic]u16,
}

mesh_destroy :: proc(m: ^Mesh) {
	delete(m.positions)
	delete(m.vert_he)
	delete(m.corner)
	delete(m.he_next)
	delete(m.he_prev)
	delete(m.he_vert)
	delete(m.he_face)
	delete(m.crease)
	delete(m.face_he)
	delete(m.group)
	m^ = {}
}

// An empty mesh whose arrays use `allocator`.
mesh_make :: proc(allocator := context.allocator) -> Mesh {
	return {
		positions = make([dynamic]Vec3, allocator),
		vert_he = make([dynamic]u32, allocator),
		corner = make([dynamic]f32, allocator),
		he_next = make([dynamic]u32, allocator),
		he_prev = make([dynamic]u32, allocator),
		he_vert = make([dynamic]u32, allocator),
		he_face = make([dynamic]u32, allocator),
		crease = make([dynamic]f32, allocator),
		face_he = make([dynamic]u32, allocator),
		group = make([dynamic]u16, allocator),
	}
}

// A copy of `m` that owns its own arrays.
mesh_clone :: proc(m: Mesh, allocator := context.allocator) -> (c: Mesh) {
	c = mesh_make(allocator)
	append(&c.positions, ..m.positions[:])
	append(&c.vert_he, ..m.vert_he[:])
	append(&c.corner, ..m.corner[:])
	append(&c.he_next, ..m.he_next[:])
	append(&c.he_prev, ..m.he_prev[:])
	append(&c.he_vert, ..m.he_vert[:])
	append(&c.he_face, ..m.he_face[:])
	append(&c.crease, ..m.crease[:])
	append(&c.face_he, ..m.face_he[:])
	append(&c.group, ..m.group[:])
	return
}

twin :: #force_inline proc "contextless" (h: u32) -> u32 {return h ~ 1}
edge_of :: #force_inline proc "contextless" (h: u32) -> u32 {return h >> 1}
// The vertex a half-edge ends at.
he_tip :: #force_inline proc(m: ^Mesh, h: u32) -> u32 {return m.he_vert[h ~ 1]}

vertex_count :: proc(m: ^Mesh) -> int {return len(m.positions)}
edge_count :: proc(m: ^Mesh) -> int {return len(m.crease)}
face_count :: proc(m: ^Mesh) -> int {return len(m.face_he)}

// Whether the edge has a face on one side only.
edge_border :: proc(m: ^Mesh, e: u32) -> bool {return m.he_face[2 * e] == NONE || m.he_face[2 * e + 1] == NONE}
// The edge's two ends, in the direction of its first half-edge.
edge_verts :: proc(m: ^Mesh, e: u32) -> (a, b: u32) {return m.he_vert[2 * e], m.he_vert[2 * e + 1]}

// Adds a vertex with no edges yet; the caller links it.
@(private)
add_vertex :: proc(m: ^Mesh, p: Vec3) -> u32 {
	append(&m.positions, p)
	append(&m.vert_he, NONE)
	append(&m.corner, 0)
	return u32(len(m.positions) - 1)
}

// Adds an edge from a to b whose two half-edges have no face and no links yet; returns
// the half-edge from a.
@(private)
add_edge :: proc(m: ^Mesh, a, b: u32) -> u32 {
	h := u32(len(m.he_next))
	append(&m.he_next, NONE, NONE)
	append(&m.he_prev, NONE, NONE)
	append(&m.he_vert, a, b)
	append(&m.he_face, NONE, NONE)
	append(&m.crease, 0)
	return h
}

@(private)
add_face :: proc(m: ^Mesh, h: u32, group: u16) -> u32 {
	append(&m.face_he, h)
	append(&m.group, group)
	return u32(len(m.face_he) - 1)
}

@(private)
link :: #force_inline proc(m: ^Mesh, a, b: u32) {
	m.he_next[a] = b
	m.he_prev[b] = a
}

// The face's corners and half-edges, from its first half-edge on, in order.
Face_Walk :: struct {
	m:     ^Mesh,
	start: u32,
	at:    u32,
	done:  bool,
}

face_walk :: proc(m: ^Mesh, f: u32) -> Face_Walk {return {m = m, start = m.face_he[f], at = m.face_he[f]}}
// The half-edges of the loop through `h` (a face's or a border's), from `h` on.
loop_walk :: proc(m: ^Mesh, h: u32) -> Face_Walk {return {m = m, start = h, at = h}}

face_walk_next :: proc(w: ^Face_Walk) -> (h: u32, ok: bool) {
	if w.done do return NONE, false
	h = w.at
	w.at = w.m.he_next[h]
	if w.at == w.start do w.done = true
	return h, true
}

// The number of corners of face f.
face_size :: proc(m: ^Mesh, f: u32) -> int {
	n := 0
	w := face_walk(m, f)
	for _ in face_walk_next(&w) do n += 1
	return n
}

// The vertices of face f in order, from its first half-edge, into `out` (cleared first).
face_verts :: proc(m: ^Mesh, f: u32, out: ^[dynamic]u32) {
	clear(out)
	w := face_walk(m, f)
	for h in face_walk_next(&w) do append(out, m.he_vert[h])
}

// The half-edges leaving vertex v, turning one way round it from vert_he: on a border
// vertex the first is the border's own and the walk ends at the other side of the gap.
Vertex_Walk :: struct {
	m:     ^Mesh,
	start: u32,
	at:    u32,
	done:  bool,
}

vertex_walk :: proc(m: ^Mesh, v: u32) -> Vertex_Walk {
	h := m.vert_he[v]
	return {m = m, start = h, at = h, done = h == NONE}
}

vertex_walk_next :: proc(w: ^Vertex_Walk) -> (h: u32, ok: bool) {
	if w.done do return NONE, false
	h = w.at
	w.at = w.m.he_next[h ~ 1]
	if w.at == w.start do w.done = true
	return h, true
}

// How many edges meet at v.
valence :: proc(m: ^Mesh, v: u32) -> int {
	n := 0
	w := vertex_walk(m, v)
	for _ in vertex_walk_next(&w) do n += 1
	return n
}

vert_border :: proc(m: ^Mesh, v: u32) -> bool {
	h := m.vert_he[v]
	return h != NONE && m.he_face[h] == NONE
}

// The half-edge from a to b, or NONE.
find_half_edge :: proc(m: ^Mesh, a, b: u32) -> u32 {
	w := vertex_walk(m, a)
	for h in vertex_walk_next(&w) do if he_tip(m, h) == b do return h
	return NONE
}

// Points vert_he[v] at the border half-edge leaving v when there is one, so walks round
// a border vertex start at its gap. Actions call it on every vertex whose ring changed.
vert_settle :: proc(m: ^Mesh, v: u32) {
	h := m.vert_he[v]
	if h == NONE do return
	w := vertex_walk(m, v)
	for o in vertex_walk_next(&w) {
		if m.he_face[o] == NONE {
			m.vert_he[v] = o
			return
		}
	}
}

// The face's normal by Newell's method, unit length (zero for a degenerate face): right
// for any planar polygon and the best fit for a bent one.
face_normal :: proc(m: ^Mesh, f: u32) -> Vec3 {
	return linalg.normalize0(face_area_vector(m, f))
}

// Newell's sum: its direction is the face's normal and its length twice its area.
face_area_vector :: proc(m: ^Mesh, f: u32) -> (n: Vec3) {
	w := face_walk(m, f)
	for h in face_walk_next(&w) {
		a := m.positions[m.he_vert[h]]
		b := m.positions[he_tip(m, h)]
		n.x += (a.y - b.y) * (a.z + b.z)
		n.y += (a.z - b.z) * (a.x + b.x)
		n.z += (a.x - b.x) * (a.y + b.y)
	}
	return
}

face_area :: proc(m: ^Mesh, f: u32) -> f32 {return linalg.length(face_area_vector(m, f)) / 2}

// The mean of the face's corners.
face_center :: proc(m: ^Mesh, f: u32) -> Vec3 {
	c: Vec3
	n := 0
	w := face_walk(m, f)
	for h in face_walk_next(&w) {
		c += m.positions[m.he_vert[h]]
		n += 1
	}
	return c / f32(max(n, 1))
}

edge_length :: proc(m: ^Mesh, e: u32) -> f32 {
	a, b := edge_verts(m, e)
	return linalg.length(m.positions[b] - m.positions[a])
}

// The vertex normal as the area-weighted mean of its faces' normals.
vert_normal :: proc(m: ^Mesh, v: u32) -> Vec3 {
	n: Vec3
	w := vertex_walk(m, v)
	for h in vertex_walk_next(&w) do if f := m.he_face[h]; f != NONE do n += face_area_vector(m, f)
	return linalg.normalize0(n)
}

// The mesh's bounds.
mesh_bounds :: proc(m: ^Mesh) -> geom.Aabb {
	b := geom.AABB_EMPTY
	for p in m.positions do geom.aabb_grow(&b, p)
	return b
}
