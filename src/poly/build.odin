package poly

import "../geom"

// Why a list of polygons cannot be a cage: the half-edge structure holds only meshes
// where each edge has one face on each side (or one, on a border), every face runs the
// same way round as its neighbours, and the faces round a vertex form one fan.
Build_Error :: enum u8 {
	None,
	Degenerate_Face, // fewer than three corners, a repeated corner, or one past the vertices
	Non_Manifold_Edge, // an edge with more than two faces
	Inconsistent, // two faces run an edge the same way: one of them is turned over
	Non_Manifold_Vertex, // the faces round a vertex form more than one fan
	Unused_Vertex, // a vertex no face uses
	Unsupported, // an action meets a shape it does not handle, such as a bevel at a border
}

// Builds a cage from polygons: face k has sizes[k] corners, taken in order from
// `corners`, counter-clockwise seen from outside; `groups` is a polygroup per face or nil
// for group 0. On an error the returned mesh is empty and owns nothing.
mesh_from_polygons :: proc(positions: []Vec3, sizes: []int, corners: []u32, groups: []u16 = nil, allocator := context.allocator) -> (m: Mesh, err: Build_Error) {
	m = mesh_make(allocator)
	reserve(&m.positions, len(positions))
	for p in positions do add_vertex(&m, p)
	// The edge between two vertices, by the pair (low, high), found while it is made.
	edges := make(map[u64]u32, len(corners), context.temp_allocator)
	at := 0
	for size, f in sizes {
		if size < 3 || at + size > len(corners) do return refuse(&m, .Degenerate_Face)
		face := corners[at:at + size]
		at += size
		for v, i in face {
			if int(v) >= len(positions) do return refuse(&m, .Degenerate_Face)
			for w in face[i + 1:] do if w == v do return refuse(&m, .Degenerate_Face)
		}
		fi := add_face(&m, NONE, groups[f] if groups != nil else 0)
		first, last: u32 = NONE, NONE
		for v, i in face {
			w := face[(i + 1) % size]
			key := u64(min(v, w)) << 32 | u64(max(v, w))
			h: u32
			if e, found := edges[key]; found {
				h = 2 * e if m.he_vert[2 * e] == v else 2 * e + 1
				if m.he_face[h] != NONE {
					return refuse(&m, .Non_Manifold_Edge if m.he_face[h ~ 1] != NONE else .Inconsistent)
				}
			} else {
				h = add_edge(&m, v, w)
				edges[key] = h >> 1
			}
			m.he_face[h] = fi
			if first == NONE do first = h
			else do link(&m, last, h)
			last = h
		}
		link(&m, last, first)
		m.face_he[fi] = first
	}
	// Every vertex leaves through one of its half-edges; a border one where it has a gap.
	for h in 0 ..< u32(len(m.he_vert)) {
		v := m.he_vert[h]
		if m.vert_he[v] == NONE || m.he_face[h] == NONE do m.vert_he[v] = h
	}
	for v in 0 ..< u32(len(m.positions)) do if m.vert_he[v] == NONE do return refuse(&m, .Unused_Vertex)
	// Border half-edges link into loops: the one ending at v runs on into the one leaving
	// v. A vertex with two gaps would need two, which is a bow-tie.
	gap_out := make([]u32, len(m.positions), context.temp_allocator)
	for &g in gap_out do g = NONE
	for h in 0 ..< u32(len(m.he_vert)) {
		if m.he_face[h] != NONE do continue
		v := m.he_vert[h]
		if gap_out[v] != NONE do return refuse(&m, .Non_Manifold_Vertex)
		gap_out[v] = h
	}
	for h in 0 ..< u32(len(m.he_vert)) {
		if m.he_face[h] != NONE do continue
		link(&m, h, gap_out[he_tip(&m, h)])
	}
	// Each vertex's walk must meet every half-edge leaving it, or its faces form two fans.
	leaving := make([]u32, len(m.positions), context.temp_allocator)
	for v in m.he_vert do leaving[v] += 1
	for v in 0 ..< u32(len(m.positions)) {
		n: u32
		w := vertex_walk(&m, v)
		for _ in vertex_walk_next(&w) {
			n += 1
			if n > leaving[v] do break
		}
		if n != leaving[v] do return refuse(&m, .Non_Manifold_Vertex)
	}
	return m, .None
}

// Frees what a refused build made: the caller gets an empty mesh.
@(private = "file")
refuse :: proc(m: ^Mesh, err: Build_Error) -> (Mesh, Build_Error) {
	mesh_destroy(m)
	return {}, err
}

// A cage of the mesh's triangles, one face each, all in group 0.
mesh_from_triangles :: proc(t: geom.Mesh, allocator := context.allocator) -> (Mesh, Build_Error) {
	sizes := make([]int, len(t.indices) / 3, context.temp_allocator)
	for &s in sizes do s = 3
	return mesh_from_polygons(t.positions[:], sizes, t.indices[:], nil, allocator)
}

// The cage as a list of polygons, the inverse of mesh_from_polygons: its positions, each
// face's size and corners, and each face's group.
Polygons :: struct {
	positions: [dynamic]Vec3,
	sizes:     [dynamic]int,
	corners:   [dynamic]u32,
	groups:    [dynamic]u16,
}

polygons_destroy :: proc(p: ^Polygons) {
	delete(p.positions)
	delete(p.sizes)
	delete(p.corners)
	delete(p.groups)
	p^ = {}
}

mesh_polygons :: proc(m: ^Mesh, allocator := context.allocator) -> (p: Polygons) {
	p.positions = make([dynamic]Vec3, allocator)
	p.sizes = make([dynamic]int, allocator)
	p.corners = make([dynamic]u32, allocator)
	p.groups = make([dynamic]u16, allocator)
	append(&p.positions, ..m.positions[:])
	for f in 0 ..< u32(len(m.face_he)) {
		n := 0
		w := face_walk(m, f)
		for h in face_walk_next(&w) {
			append(&p.corners, m.he_vert[h])
			n += 1
		}
		append(&p.sizes, n)
		append(&p.groups, m.group[f])
	}
	return
}
