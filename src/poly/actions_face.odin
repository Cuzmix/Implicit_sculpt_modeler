package poly

import "core:math/linalg"
import "core:slice"

// Face actions, as ZModeler's poly actions: each takes the cage and the faces its target
// reached (cage ids), changes the cage, and returns what a drag then moves. Each is a pure
// procedure on the cage, so the app runs it once at the start of a drag and Adjust Last can
// run it again with other values; a refused action leaves the cage as it was.

// What a drag moves after an action: vertices that go from `base` along `dir` by the
// drag's amount (dir already scaled so an amount is a distance where that means anything),
// up to `limit` when it is above zero (an inset that would cross itself).
Drag_Set :: struct {
	verts: []u32,
	base:  []Vec3,
	dir:   []Vec3,
	limit: f32,
}

drag_set_destroy :: proc(d: ^Drag_Set) {
	delete(d.verts)
	delete(d.base)
	delete(d.dir)
	d^ = {}
}

// Puts the drag's vertices `amount` along their ways, clamped to its limit, and returns
// the amount used.
drag_apply :: proc(m: ^Mesh, d: ^Drag_Set, amount: f32) -> f32 {
	a := amount
	if d.limit > 0 do a = clamp(a, -d.limit, d.limit)
	for v, i in d.verts do m.positions[v] = d.base[i] + d.dir[i] * a
	return a
}

// How the faces' vertices move when the faces move along their normals: each along the
// mean of the normals of the faces of `faces` it is a corner of, lengthened where those
// faces meet at an angle so the faces stay parallel to where they were (as Blender's
// even thickness does), at most twice.
@(private = "file")
normal_dirs :: proc(m: ^Mesh, faces: []u32, verts: []u32, allocator := context.allocator) -> []Vec3 {
	sum := make(map[u32]Vec3, allocator = context.temp_allocator)
	for f in faces {
		n := face_normal(m, f)
		w := face_walk(m, f)
		for h in face_walk_next(&w) {
			v := m.he_vert[h]
			sum[v] = sum[v] + n
		}
	}
	dirs := make([]Vec3, len(verts), allocator)
	for v, i in verts {
		s := sum[v]
		if linalg.length2(s) < 1e-20 do continue
		n := linalg.normalize(s)
		// The least the vertex's faces lean from n decides how far it must go.
		least: f32 = 1
		for f in faces {
			w := face_walk(m, f)
			for h in face_walk_next(&w) do if m.he_vert[h] == v do least = min(least, linalg.dot(n, face_normal(m, f)))
		}
		dirs[i] = n / max(least, 0.5)
	}
	return dirs
}

// Moves faces along their normals: their vertices go together (a target of several faces
// keeps its shape), as ZModeler's Move along the normal does.
move_faces :: proc(m: ^Mesh, faces: []u32, allocator := context.allocator) -> Drag_Set {
	verts := face_set_verts(m, faces, allocator)
	d := Drag_Set{verts = verts, base = make([]Vec3, len(verts), allocator)}
	for v, i in verts do d.base[i] = m.positions[v]
	d.dir = normal_dirs(m, faces, verts, allocator)
	return d
}

// Every vertex of the faces, ascending.
face_set_verts :: proc(m: ^Mesh, faces: []u32, allocator := context.allocator) -> []u32 {
	seen := make([]bool, len(m.positions), context.temp_allocator)
	out := make([dynamic]u32, allocator)
	for f in faces {
		w := face_walk(m, f)
		for h in face_walk_next(&w) {
			v := m.he_vert[h]
			if seen[v] do continue
			seen[v] = true
			append(&out, v)
		}
	}
	s := out[:]
	slice.sort(s)
	return s
}

// What extrude_faces and inset_faces do to the cage, and the new numbering.
Face_Ring :: struct {
	edit:   Edit_Result,
	faces:  []u32, // the target's faces, new ids
	sides:  []u32, // the faces the ring added, new ids
	// Each new vertex and the vertex it was copied from (new ids both), by the copy.
	copies: [][2]u32,
}

face_ring_destroy :: proc(r: ^Face_Ring) {
	edit_result_destroy(&r.edit)
	delete(r.faces)
	delete(r.sides)
	delete(r.copies)
	r^ = {}
}

// The cage change both Extrude and Inset make: the faces get vertices of their own (one
// set for the whole target, or with `each` one for each face), and a ring of quads joins
// each of the target's border edges (every edge, with `each`) to its copy. The new
// vertices start where the old ones are; the action's drag moves them. The ring's faces
// take the polygroup of the face they stand on, or with `group_sides` (ZModeler's Alt) a
// new polygroup.
face_ring :: proc(m: ^Mesh, faces: []u32, each, group_sides: bool, allocator := context.allocator) -> (r: Face_Ring, err: Build_Error) {
	in_target := make([]bool, len(m.face_he), context.temp_allocator)
	for f in faces do in_target[f] = true
	e := edit_begin(m, context.temp_allocator)
	side_group := u16(0)
	if group_sides {
		for g in m.group do side_group = max(side_group, g)
		side_group += 1
	}
	// Per target face (or for all of them), each old vertex's copy, in edit ids.
	pairs := make([dynamic][2]u32, context.temp_allocator)
	shared := make(map[u32]u32, allocator = context.temp_allocator)
	for f in faces {
		local := make(map[u32]u32, allocator = context.temp_allocator)
		table := &local if each else &shared
		copy_of :: proc(e: ^Edit, table: ^map[u32]u32, pairs: ^[dynamic][2]u32, v: u32) -> u32 {
			if c, ok := table[v]; ok do return c
			c := edit_vertex(e, e.positions[v], e.corner[v])
			table[v] = c
			append(pairs, [2]u32{c, v})
			return c
		}
		w := face_walk(m, f)
		for h in face_walk_next(&w) {
			a, b := m.he_vert[h], he_tip(m, h)
			other := m.he_face[twin(h)]
			if !each && other != NONE && in_target[other] do continue
			ca, cb := copy_of(&e, table, &pairs, a), copy_of(&e, table, &pairs, b)
			edit_face(&e, {a, b, cb, ca}, side_group if group_sides else m.group[f])
		}
		// Taken after the ring's faces went in, which may have moved the list.
		for &v in e.faces[f].verts do v = copy_of(&e, table, &pairs, v)
	}
	r.edit = edit_end(m, &e, allocator) or_return
	r.copies = make([][2]u32, len(pairs), allocator)
	for p, i in pairs do r.copies[i] = {r.edit.vert[p[0]], r.edit.vert[p[1]]}
	targets := make([dynamic]u32, allocator)
	sides := make([dynamic]u32, allocator)
	for from, i in r.edit.face_from {
		if from == NONE do append(&sides, u32(i))
		else if in_target[from] do append(&targets, u32(i))
	}
	r.faces, r.sides = targets[:], sides[:]
	return r, .None
}

// Extrude (ZModeler's QMesh, Blender's E): the faces come away from the cage on a ring of
// new side faces, and the drag pulls them along their normals. With `each` every face goes
// on its own. Returns the drag; the cage is as it was when refused.
extrude_faces :: proc(m: ^Mesh, faces: []u32, each, group_sides: bool, allocator := context.allocator) -> (r: Face_Ring, d: Drag_Set, err: Build_Error) {
	// The ways out are measured on the faces before they move: the copies start there.
	normals := make([]Vec3, len(m.face_he), context.temp_allocator)
	for f in faces do normals[f] = face_normal(m, f)
	r = face_ring(m, faces, each, group_sides, allocator) or_return
	d.verts = make([]u32, len(r.copies), allocator)
	d.base = make([]Vec3, len(r.copies), allocator)
	for c, i in r.copies {
		d.verts[i] = c[0]
		d.base[i] = m.positions[c[0]]
	}
	d.dir = normal_dirs(m, r.faces, d.verts, allocator)
	return
}

// Inset (ZModeler's and Blender's): the faces shrink inside their outline, leaving a
// ring of new faces round them, the drag setting the ring's width. With `each` every face
// shrinks on its own. The width is the same all round: each corner moves along the
// bisector of its two border edges, lengthened at sharp corners, and the drag stops before
// a corner would cross the face's middle.
inset_faces :: proc(m: ^Mesh, faces: []u32, each: bool, allocator := context.allocator) -> (r: Face_Ring, d: Drag_Set, err: Build_Error) {
	r = face_ring(m, faces, each, false, allocator) or_return
	in_target := make([]bool, len(m.face_he), context.temp_allocator)
	for f in r.faces do in_target[f] = true
	// Per copied vertex, the border edges of its face set that leave and reach it.
	index := make(map[u32]int, allocator = context.temp_allocator)
	for c, i in r.copies do index[c[0]] = i
	out_to := make([]u32, len(r.copies), context.temp_allocator)
	in_from := make([]u32, len(r.copies), context.temp_allocator)
	normal := make([]Vec3, len(r.copies), context.temp_allocator)
	middle := make([]Vec3, len(r.copies), context.temp_allocator)
	for i in 0 ..< len(r.copies) do out_to[i], in_from[i] = NONE, NONE
	for f in r.faces {
		n := face_normal(m, f)
		c := face_center(m, f)
		w := face_walk(m, f)
		for h in face_walk_next(&w) {
			a := m.he_vert[h]
			i, ok := index[a]
			if !ok do continue
			normal[i] += n
			middle[i] = c
			// A border of the set: the face across is not in it (a ring face, after the change).
			if other := m.he_face[twin(h)]; other != NONE && in_target[other] do continue
			out_to[i] = he_tip(m, h)
			if j, found := index[he_tip(m, h)]; found do in_from[j] = a
		}
	}
	d.verts = make([]u32, len(r.copies), allocator)
	d.base = make([]Vec3, len(r.copies), allocator)
	d.dir = make([]Vec3, len(r.copies), allocator)
	limit := max(f32)
	for c, i in r.copies {
		v := c[0]
		p := m.positions[v]
		d.verts[i], d.base[i] = v, p
		if out_to[i] == NONE || in_from[i] == NONE || linalg.length2(normal[i]) < 1e-20 do continue
		n := linalg.normalize(normal[i])
		// Inside a face that runs counter-clockwise about n is to the left of each edge.
		along_out := m.positions[out_to[i]] - p
		along_in := p - m.positions[in_from[i]]
		if linalg.length2(along_out) < 1e-20 || linalg.length2(along_in) < 1e-20 do continue
		left_out := linalg.normalize(linalg.cross(n, linalg.normalize(along_out)))
		left_in := linalg.normalize(linalg.cross(n, linalg.normalize(along_in)))
		bisector := left_out + left_in
		if linalg.length2(bisector) < 1e-12 do bisector = left_out
		bisector = linalg.normalize(bisector)
		dir := bisector / max(linalg.dot(bisector, left_out), 0.25)
		d.dir[i] = dir
		limit = min(limit, 0.95 * linalg.length(middle[i] - p) / linalg.length(dir))
	}
	d.limit = limit if limit < max(f32) else 0
	return
}

// Delete (ZModeler's): the faces go, leaving a hole; with `close` (its Alt) the hole they
// leave is closed by one face instead, which needs faces whose outline is one loop.
delete_or_dissolve :: proc(m: ^Mesh, faces: []u32, close: bool, allocator := context.allocator) -> (r: Edit_Result, err: Build_Error) {
	if !close do return delete_faces(m, faces, allocator)
	in_target := make([]bool, len(m.face_he), context.temp_allocator)
	for f in faces do in_target[f] = true
	// The outline: each border half-edge of the set, followed by the next one leaving its tip.
	next_of := make(map[u32]u32, allocator = context.temp_allocator)
	start := NONE
	count := 0
	for f in faces {
		w := face_walk(m, f)
		for h in face_walk_next(&w) {
			if other := m.he_face[twin(h)]; other != NONE && in_target[other] do continue
			a := m.he_vert[h]
			// Two border edges leaving one vertex: the outline touches itself.
			if _, twice := next_of[a]; twice do return {}, .Non_Manifold_Vertex
			next_of[a] = he_tip(m, h)
			if start == NONE || a < start do start = a
			count += 1
		}
	}
	if count < 3 do return {}, .Degenerate_Face
	loop := make([dynamic]u32, context.temp_allocator)
	v := start
	for _ in 0 ..< count {
		append(&loop, v)
		v = next_of[v]
		if v == start do break
	}
	// More than one loop: a ring of faces, whose hole one face cannot close.
	if len(loop) != count do return {}, .Non_Manifold_Edge
	e := edit_begin(m, context.temp_allocator)
	kept := make([dynamic]Edit_Face, 0, len(e.faces), context.temp_allocator)
	for f in e.faces do if !in_target[f.from] do append(&kept, f)
	e.faces = kept
	edit_face(&e, loop[:], m.group[faces[0]])
	return edit_end(m, &e, allocator)
}

// Flip (ZModeler's): turns the faces over. Turning over only part of a piece would leave
// faces facing opposite ways across an edge, which is refused; the island target turns a
// whole piece.
flip_faces :: proc(m: ^Mesh, faces: []u32, allocator := context.allocator) -> (r: Edit_Result, err: Build_Error) {
	e := edit_begin(m, context.temp_allocator)
	for f in faces {
		vs := e.faces[f].verts[:]
		for i in 0 ..< len(vs) / 2 do vs[i], vs[len(vs) - 1 - i] = vs[len(vs) - 1 - i], vs[i]
	}
	return edit_end(m, &e, allocator)
}

// Polygroup (ZModeler's): the faces take polygroup `group`. Nothing else changes.
group_faces :: proc(m: ^Mesh, faces: []u32, group: u16) {
	for f in faces do m.group[f] = group
}

// The next polygroup no face has: what a new group takes.
group_next :: proc(m: ^Mesh) -> u16 {
	top: u16
	for g in m.group do top = max(top, g)
	return top + 1
}
