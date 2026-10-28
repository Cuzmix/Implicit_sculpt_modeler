package poly

import "core:math/linalg"

// Catmull-Clark subdivision with semi-sharp creases, as OpenSubdiv and Blender's
// Subdivision Surface work: Model mode's Smooth draws the cage this many steps finer,
// live, as ZBrush's Dynamic Subdivision does. Each step makes every face a ring of quads
// round its middle. Its points are numbered in a fixed way, so the finer cages' topology
// is made once and a drag that only moves the cage's points recomputes positions alone:
// a vertex keeps its id (its vertex point), edge e's point is V + e, face f's is V + E + f.
//
// Creases and corners step down by one each step, as OpenSubdiv's do: a crease of 2 stays
// sharp for two steps and then rounds off, which is what makes it look semi-sharp; one at
// INFINITE_SHARP never rounds. Flat splits the faces the same way without moving any
// point, for hard surfaces that want more faces and no rounding. Borders keep sharp as
// fully creased edges, and a border's corner (a point with only its two border edges)
// stays where it is.

// A cage's finer cages, finest last, and what Model mode needs to draw and pick on it.
Subdivision :: struct {
	steps:     [dynamic]Mesh,
	// Per face of the finest cage, the cage face it lies in.
	face_from: []u32,
	// Per cage edge, its points along the finest cage from its first end to its other,
	// line_points of them each: edge e's are edge_line[e * line_points:][:line_points].
	edge_line:   []u32,
	line_points: int,
}

subdivision_destroy :: proc(s: ^Subdivision) {
	for &m in s.steps do mesh_destroy(&m)
	delete(s.steps)
	delete(s.face_from)
	delete(s.edge_line)
	s^ = {}
}

// The finest cage, or the cage itself when there are no steps.
subdivision_top :: proc(s: ^Subdivision, cage: ^Mesh) -> ^Mesh {
	return &s.steps[len(s.steps) - 1] if len(s.steps) > 0 else cage
}

// The cage `steps` steps finer (0 to SUBDIVIDE_MAX); with `flat`, split without
// smoothing (every new point in the middle of its edge or face). Returns the error of a step whose
// cage cannot be built, which a valid cage never gives.
subdivide :: proc(cage: ^Mesh, steps: int, flat := false, allocator := context.allocator) -> (s: Subdivision, err: Build_Error) {
	s.steps = make([dynamic]Mesh, allocator)
	from := make([]u32, len(cage.face_he), allocator)
	for &f, i in from do f = u32(i)
	s.line_points = 2
	line := make([]u32, 2 * len(cage.crease), allocator)
	for e in 0 ..< u32(len(cage.crease)) do line[2 * e], line[2 * e + 1] = edge_verts(cage, e)
	parent := cage
	for _ in 0 ..< clamp(steps, 0, SUBDIVIDE_MAX) {
		child, child_from, step_err := subdivide_step(parent, flat, allocator)
		if step_err != .None {
			delete(from, allocator)
			delete(line, allocator)
			subdivision_destroy(&s)
			return {}, step_err
		}
		// Each finer face lies in its parent's cage face.
		for &f in child_from do f = from[f]
		delete(from, allocator)
		from = child_from
		// Each edge's line gains the point in the middle of each of its pieces.
		points := 2 * s.line_points - 1
		finer := make([]u32, len(cage.crease) * points, allocator)
		nv := u32(len(parent.positions))
		for e in 0 ..< len(cage.crease) {
			old := line[e * s.line_points:][:s.line_points]
			out := finer[e * points:][:points]
			for i in 0 ..< len(old) - 1 {
				h := find_half_edge(parent, old[i], old[i + 1])
				out[2 * i] = old[i]
				out[2 * i + 1] = nv + edge_of(h)
			}
			out[points - 1] = old[len(old) - 1]
		}
		delete(line, allocator)
		line = finer
		s.line_points = points
		append(&s.steps, child)
		parent = &s.steps[len(s.steps) - 1]
	}
	s.face_from = from
	s.edge_line = line
	return s, .None
}

// The most steps Smooth takes: each makes four times the faces.
SUBDIVIDE_MAX :: 4

// Moves the finer cages' points after the cage's moved without a change of topology,
// creases or corners, made with the same `flat`.
subdivision_update :: proc(s: ^Subdivision, cage: ^Mesh, flat := false) {
	parent := cage
	for &child in s.steps {
		subdivide_positions(parent, child.positions[:], flat)
		parent = &child
	}
}

// One step: the finer cage (positions included) and, per finer face, its parent face.
@(private = "file")
subdivide_step :: proc(m: ^Mesh, flat: bool, allocator := context.allocator) -> (child: Mesh, face_from: []u32, err: Build_Error) {
	nv, ne, nf := u32(len(m.positions)), u32(len(m.crease)), u32(len(m.face_he))
	positions := make([]Vec3, nv + ne + nf, context.temp_allocator)
	subdivide_positions(m, positions, flat)
	sizes := make([dynamic]int, context.temp_allocator)
	corners := make([dynamic]u32, context.temp_allocator)
	groups := make([dynamic]u16, context.temp_allocator)
	from := make([dynamic]u32, allocator)
	for f in 0 ..< nf {
		// Quad i runs from corner i to the middle of its edge on, the face's middle, and
		// the middle of the edge before: the face's own way round.
		w := face_walk(m, f)
		for h in face_walk_next(&w) {
			append(&sizes, 4)
			append(&corners, m.he_vert[h], nv + edge_of(h), nv + ne + f, nv + edge_of(m.he_prev[h]))
			append(&groups, m.group[f])
			append(&from, f)
		}
	}
	child = mesh_from_polygons(positions, sizes[:], corners[:], groups[:], allocator) or_return
	// Creases and corners one step less sharp, on both halves of each edge.
	for c, e in m.crease {
		if c <= 0 do continue
		finer := c if c >= INFINITE_SHARP else max(c - 1, 0)
		if finer <= 0 do continue
		a, b := edge_verts(m, u32(e))
		mid := nv + u32(e)
		if h := find_half_edge(&child, a, mid); h != NONE do child.crease[edge_of(h)] = finer
		if h := find_half_edge(&child, mid, b); h != NONE do child.crease[edge_of(h)] = finer
	}
	for c, v in m.corner do if c > 0 do child.corner[v] = c if c >= INFINITE_SHARP else max(c - 1, 0)
	return child, from[:], .None
}

// The finer cage's points from `m`'s, numbered as the step numbers them, into `out`
// (V + E + F of them); with `flat`, the parent's points stay and the new ones sit in
// the middle of their edge or face.
subdivide_positions :: proc(m: ^Mesh, out: []Vec3, flat := false) {
	nv, ne := len(m.positions), len(m.crease)
	faces := out[nv + ne:]
	for f in 0 ..< u32(len(m.face_he)) do faces[f] = face_center(m, f)
	edges := out[nv:][:ne]
	for e in 0 ..< u32(ne) {
		a, b := edge_verts(m, e)
		mid := (m.positions[a] + m.positions[b]) * 0.5
		s := edge_sharpness(m, e)
		if flat || s >= 1 {
			edges[e] = mid
			continue
		}
		f1, f2 := m.he_face[2 * e], m.he_face[2 * e + 1]
		smooth := (m.positions[a] + m.positions[b] + faces[f1] + faces[f2]) * 0.25
		edges[e] = linalg.lerp(smooth, mid, s)
	}
	if flat {
		copy(out[:nv], m.positions[:])
		return
	}
	for v in 0 ..< u32(nv) do out[v] = vertex_point(m, v, faces, edges)
}

// An edge's sharpness for the rules: its crease, a border fully sharp.
@(private = "file")
edge_sharpness :: proc(m: ^Mesh, e: u32) -> f32 {
	if edge_border(m, e) do return INFINITE_SHARP
	return m.crease[e]
}

// Where vertex v goes: the smooth rule, the crease rule along exactly two sharp edges, or
// staying put at a corner (three or more sharp edges, or its own sharpness), blended by
// how sharp the edges that make it a crease or corner are when that is under one.
@(private = "file")
vertex_point :: proc(m: ^Mesh, v: u32, faces, edges: []Vec3) -> Vec3 {
	p := m.positions[v]
	n := 0
	q, r: Vec3
	sharp_ends: [2]Vec3
	sharp_count := 0
	sharpness: f32
	w := vertex_walk(m, v)
	for h in vertex_walk_next(&w) {
		n += 1
		e := edge_of(h)
		other := m.positions[he_tip(m, h)]
		r += (p + other) * 0.5
		if f := m.he_face[h]; f != NONE do q += faces[f]
		if s := edge_sharpness(m, e); s > 0 {
			if sharp_count < 2 do sharp_ends[sharp_count] = other
			sharp_count += 1
			sharpness += min(s, 1)
		}
	}
	if n == 0 do return p
	faces_round := n - 1 if vert_border(m, v) else n
	smooth := p
	if faces_round == n {
		fn := f32(n)
		smooth = (q / fn + 2 * r / fn + (fn - 3) * p) / fn
	}
	sharp: Vec3
	weight: f32
	switch {
	case faces_round < n && n == 2:
		// A border corner keeps its place, as Blender's Keep corners does.
		return p
	case m.corner[v] > 0:
		sharp, weight = p, min(m.corner[v], 1)
	case sharp_count >= 3:
		sharp, weight = p, sharpness / f32(sharp_count)
	case sharp_count == 2:
		sharp, weight = (sharp_ends[0] + 6 * p + sharp_ends[1]) / 8, sharpness / 2
	case:
		return smooth
	}
	return linalg.lerp(smooth, sharp, clamp(weight, 0, 1))
}
