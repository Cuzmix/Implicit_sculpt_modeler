package poly

import pq "core:container/priority_queue"
import "core:math"
import "core:math/linalg"
import "core:slice"

// The targets an action works on, from one picked element: loops, rings, islands, groups,
// borders and paths, as ZModeler's targets and Blender's selection tools find them. Each
// returns its elements in a fixed order (along the loop, or ascending ids for a region),
// so the same pick always gives the same result.

// The edge loop through edge e, in order along it: from each end it carries on to the
// edge straight across the vertex where four edges meet, and stops at a pole, a border,
// or (with `stop_at_groups`) where it would cross into another polygroup. A border edge's
// loop is the border's. Returns whether the loop closed on itself.
edge_loop :: proc(m: ^Mesh, e: u32, out: ^[dynamic]u32, stop_at_groups := false) -> (closed: bool) {
	clear(out)
	if edge_border(m, e) {
		border_loop(m, e, out)
		return true
	}
	ahead := make([dynamic]u32, context.temp_allocator)
	behind := make([dynamic]u32, context.temp_allocator)
	closed = loop_walk_from(m, 2 * e, e, &ahead, stop_at_groups)
	if !closed do loop_walk_from(m, 2 * e + 1, e, &behind, stop_at_groups)
	#reverse for x in behind do append(out, x)
	append(out, e)
	append(out, ..ahead[:])
	return
}

// Walks on from half-edge h through the vertex it ends at, appending the edges passed,
// until it stops (false) or comes back to edge `start` (true).
@(private = "file")
loop_walk_from :: proc(m: ^Mesh, h: u32, start: u32, out: ^[dynamic]u32, stop_at_groups: bool) -> bool {
	h := h
	for _ in 0 ..< len(m.crease) {
		v := he_tip(m, h)
		if vert_border(m, v) || valence(m, v) != 4 do return false
		// Round v from the way back: the side edge, the edge straight across, the other side.
		side_a := m.he_next[h]
		across := m.he_next[twin(side_a)]
		side_b := m.he_next[twin(across)]
		if stop_at_groups && (group_border(m, side_a) || group_border(m, side_b)) do return false
		e := edge_of(across)
		if e == start do return true
		append(out, e)
		h = across
	}
	return false
}

// Whether the faces on the two sides of half-edge h's edge are in different polygroups.
@(private = "file")
group_border :: proc(m: ^Mesh, h: u32) -> bool {
	a, b := m.he_face[h], m.he_face[twin(h)]
	return a != NONE && b != NONE && m.group[a] != m.group[b]
}

// The edges of the border loop edge e lies on, in order along the border.
border_loop :: proc(m: ^Mesh, e: u32, out: ^[dynamic]u32) {
	clear(out)
	h := 2 * e if m.he_face[2 * e] == NONE else 2 * e + 1
	if m.he_face[h] != NONE do return
	w := loop_walk(m, h)
	for o in face_walk_next(&w) do append(out, edge_of(o))
}

// The edge ring through edge e: the edges straight across each quad from it, in order,
// until a border, a face that is not a quad, or the start again. Returns whether it closed.
edge_ring :: proc(m: ^Mesh, e: u32, out: ^[dynamic]u32) -> (closed: bool) {
	faces := make([dynamic]u32, context.temp_allocator)
	return ring_walk(m, e, out, &faces)
}

// The face loop beside edge e: the quads its ring crosses, in order.
face_loop :: proc(m: ^Mesh, e: u32, out: ^[dynamic]u32) -> (closed: bool) {
	edges := make([dynamic]u32, context.temp_allocator)
	return ring_walk(m, e, &edges, out)
}

@(private = "file")
ring_walk :: proc(m: ^Mesh, e: u32, edges, faces: ^[dynamic]u32) -> (closed: bool) {
	clear(edges)
	clear(faces)
	ahead_e := make([dynamic]u32, context.temp_allocator)
	ahead_f := make([dynamic]u32, context.temp_allocator)
	behind_e := make([dynamic]u32, context.temp_allocator)
	behind_f := make([dynamic]u32, context.temp_allocator)
	closed = ring_from(m, 2 * e, e, &ahead_e, &ahead_f)
	if !closed do ring_from(m, 2 * e + 1, e, &behind_e, &behind_f)
	#reverse for x in behind_e do append(edges, x)
	append(edges, e)
	append(edges, ..ahead_e[:])
	#reverse for x in behind_f do append(faces, x)
	append(faces, ..ahead_f[:])
	return
}

@(private = "file")
ring_from :: proc(m: ^Mesh, h: u32, start: u32, edges, faces: ^[dynamic]u32) -> bool {
	h := h
	for _ in 0 ..< len(m.face_he) {
		f := m.he_face[h]
		if f == NONE || face_size(m, f) != 4 do return false
		append(faces, f)
		opposite := m.he_next[m.he_next[h]]
		e := edge_of(opposite)
		if e == start do return true
		append(edges, e)
		h = twin(opposite)
	}
	return false
}

// Every face joined to face f across edges, ascending.
island :: proc(m: ^Mesh, f: u32, out: ^[dynamic]u32) {
	grow(m, f, out, proc(m: ^Mesh, seed, from, to: u32, data: rawptr) -> bool {return true}, nil)
}

// The faces joined to f whose normals lie within `degrees` of f's, through faces that do
// too (ZModeler's flat island; 15 degrees is its default tolerance), ascending.
flat_island :: proc(m: ^Mesh, f: u32, degrees: f32, out: ^[dynamic]u32) {
	limit := math.cos(degrees * math.RAD_PER_DEG)
	Flat :: struct {
		normal: Vec3,
		limit:  f32,
	}
	data := Flat{face_normal(m, f), limit}
	grow(m, f, out, proc(m: ^Mesh, seed, from, to: u32, data: rawptr) -> bool {
		d := (^Flat)(data)
		return linalg.dot(face_normal(m, to), d.normal) >= d.limit
	}, &data)
}

// The faces of f's polygroup joined to it, ascending.
group_island :: proc(m: ^Mesh, f: u32, out: ^[dynamic]u32) {
	grow(m, f, out, proc(m: ^Mesh, seed, from, to: u32, data: rawptr) -> bool {return m.group[to] == m.group[seed]}, nil)
}

// Every face in polygroup g, ascending.
group_all :: proc(m: ^Mesh, g: u16, out: ^[dynamic]u32) {
	clear(out)
	for f in 0 ..< u32(len(m.face_he)) do if m.group[f] == g do append(out, f)
}

// The faces reached from `seed` across edges where `keep` says yes, ascending.
@(private = "file")
grow :: proc(m: ^Mesh, seed: u32, out: ^[dynamic]u32, keep: proc(m: ^Mesh, seed, from, to: u32, data: rawptr) -> bool, data: rawptr) {
	clear(out)
	seen := make([]bool, len(m.face_he), context.temp_allocator)
	stack := make([dynamic]u32, context.temp_allocator)
	append(&stack, seed)
	seen[seed] = true
	for len(stack) > 0 {
		f := pop(&stack)
		append(out, f)
		w := face_walk(m, f)
		for h in face_walk_next(&w) {
			g := m.he_face[twin(h)]
			if g == NONE || seen[g] || !keep(m, seed, f, g, data) do continue
			seen[g] = true
			append(&stack, g)
		}
	}
	slice.sort(out[:])
}

@(private = "file")
Step :: struct {
	cost: f32,
	at:   u32,
}

// The shortest way along edges from vertex a to vertex b (Dijkstra by length, ties to
// the lower id): its vertices from a to b into `verts` and its edges into `edges`.
// Returns false, with both empty, when b cannot be reached.
shortest_vertex_path :: proc(m: ^Mesh, a, b: u32, verts, edges: ^[dynamic]u32) -> bool {
	clear(verts)
	clear(edges)
	n := len(m.positions)
	cost := make([]f32, n, context.temp_allocator)
	via := make([]u32, n, context.temp_allocator)
	for i in 0 ..< n {
		cost[i] = math.INF_F32
		via[i] = NONE
	}
	q: pq.Priority_Queue(Step)
	pq.init(&q, step_less, pq.default_swap_proc(Step), allocator = context.temp_allocator)
	cost[a] = 0
	pq.push(&q, Step{0, a})
	for pq.len(q) > 0 {
		s := pq.pop(&q)
		if s.cost > cost[s.at] do continue
		if s.at == b do break
		w := vertex_walk(m, s.at)
		for h in vertex_walk_next(&w) {
			t := he_tip(m, h)
			c := s.cost + edge_length(m, edge_of(h))
			if c < cost[t] || (c == cost[t] && via[t] != NONE && h < via[t]) {
				cost[t] = c
				via[t] = h
				pq.push(&q, Step{c, t})
			}
		}
	}
	if a != b && via[b] == NONE do return false
	at := b
	append(verts, b)
	for at != a {
		h := via[at]
		append(edges, edge_of(h))
		at = m.he_vert[h]
		append(verts, at)
	}
	slice.reverse(verts[:])
	slice.reverse(edges[:])
	return true
}

// The shortest way across edges from face a to face b, by the distance between their
// centres, from a to b. Returns false, with `faces` empty, when b cannot be reached.
shortest_face_path :: proc(m: ^Mesh, a, b: u32, faces: ^[dynamic]u32) -> bool {
	clear(faces)
	n := len(m.face_he)
	cost := make([]f32, n, context.temp_allocator)
	via := make([]u32, n, context.temp_allocator)
	centre := make([]Vec3, n, context.temp_allocator)
	for i in 0 ..< n {
		cost[i] = math.INF_F32
		via[i] = NONE
		centre[i] = face_center(m, u32(i))
	}
	q: pq.Priority_Queue(Step)
	pq.init(&q, step_less, pq.default_swap_proc(Step), allocator = context.temp_allocator)
	cost[a] = 0
	pq.push(&q, Step{0, a})
	for pq.len(q) > 0 {
		s := pq.pop(&q)
		if s.cost > cost[s.at] do continue
		if s.at == b do break
		w := face_walk(m, s.at)
		for h in face_walk_next(&w) {
			t := m.he_face[twin(h)]
			if t == NONE do continue
			c := s.cost + linalg.length(centre[t] - centre[s.at])
			if c < cost[t] || (c == cost[t] && via[t] != NONE && s.at < via[t]) {
				cost[t] = c
				via[t] = s.at
				pq.push(&q, Step{c, t})
			}
		}
	}
	if a != b && via[b] == NONE do return false
	at := b
	append(faces, b)
	for at != a {
		at = via[at]
		append(faces, at)
	}
	slice.reverse(faces[:])
	return true
}

@(private = "file")
step_less :: proc(x, y: Step) -> bool {
	if x.cost != y.cost do return x.cost < y.cost
	return x.at < y.at
}
