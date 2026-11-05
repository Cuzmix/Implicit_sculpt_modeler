package quadmesh

import "base:runtime"
import "core:math"

// The isotropic remesh's working mesh (isotropic.odin): triangles that are split,
// collapsed and flipped in place, kept as a corner table. Corner c is corner c % 3 of
// triangle c / 3; its edge runs from its vertex to the next corner's, and `twin[c]` is the
// corner of the other triangle whose edge runs back, or NONE on a border. Every vertex is
// one fan of corners joined through twins: where the input shares a vertex between fans
// (a pinch, which hung AutoRemesher's remesher), each fan past the first gets a vertex of its
// own, and an edge of more than two triangles, or of two running the same way, is cut
// into borders. A border vertex's `corner` is the corner whose edge leaves it along the
// border, so the walk round it starts there and ends at its other border edge; the edits
// below keep that so. Twins pair corners both ways, which is what makes every walk end.
// Everything is allocated with runtime.heap_allocator(), as the stages' outputs are.
Work_Mesh :: struct {
	pos:      [dynamic][3]f64,
	corner:   [dynamic]u32, // per vertex: a corner at it (its border corner on a border), NONE once removed
	target:   [dynamic]f64, // per vertex: the edge length wanted there, 0 for the stage's own
	payload:  [dynamic]f64, // per vertex: the caller's value, which a split averages and a collapse keeps
	featured: [dynamic]bool, // per vertex: on a feature, a border or a torn edge, so it moves only along a feature if at all
	near:     [dynamic]u32, // per vertex: the input triangle it was last projected onto, a hint for the next time
	vert:     [dynamic]u32, // per corner: its vertex
	twin:     [dynamic]u32, // per corner
	state:    [dynamic]i8, // per corner: its edge's feature state, the same on both sides (Edge_State)
	dead:     [dynamic]bool, // per triangle: collapsed away
	stamp:    [dynamic]u32, // per vertex: scratch marks for the serial edits (work_shared_neighbours)
	stamped:  u32,
}

// An edge's feature state. A split keeps it on both halves, a flip refuses an edge of 1 or
// more, a collapse runs only along such an edge, and the two edges a collapsed triangle
// merges keep the stronger.
UNJUDGED :: i8(-1) // not looked at by angle (every edge made after the first split)
SMOOTH :: i8(0)
SHARP :: i8(1) // sharper than the stage's angle, or a border
CALLER :: i8(2) // one of the caller's feature edges, held on its polyline
FROZEN :: i8(3) // a border kept as it is (Params.frozen): never split or collapsed, its vertices never moved

work_mesh_destroy :: proc(m: ^Work_Mesh) {
	delete(m.pos)
	delete(m.corner)
	delete(m.target)
	delete(m.payload)
	delete(m.featured)
	delete(m.near)
	delete(m.vert)
	delete(m.twin)
	delete(m.state)
	delete(m.dead)
	delete(m.stamp)
	m^ = {}
}

// The working mesh of an island: its triangles but those that repeat a vertex, the
// caller's feature edges marked, the border edges both of whose ends are `frozen` (one a
// vertex, or nil) marked FROZEN, torn edges cut, and pinches split. `target` and
// `payload` (one a vertex, or nil) come along with the vertices. Returns how many vertices
// the pinches added, how many edges were torn and how many triangles were dropped.
work_mesh_build :: proc(positions: [][3]f64, triangles: [][3]u32, features: [][2]u32, target, payload: []f64, frozen: []bool = nil) -> (m: Work_Mesh, fans_split, torn, dropped: int) {
	heap := runtime.heap_allocator()
	n := len(positions)
	m.pos = make([dynamic][3]f64, n, heap)
	m.corner = make([dynamic]u32, n, heap)
	m.target = make([dynamic]f64, n, heap)
	m.payload = make([dynamic]f64, n, heap)
	m.featured = make([dynamic]bool, n, heap)
	m.near = make([dynamic]u32, n, heap)
	m.stamp = make([dynamic]u32, n, heap)
	copy(m.pos[:], positions)
	for v in 0 ..< n {
		m.corner[v] = NONE
		m.near[v] = NONE
		m.target[v] = target[v] if len(target) == n && target[v] > 0 && target[v] < math.F64_MAX else 0
		m.payload[v] = payload[v] if len(payload) == n else 1
	}
	m.vert = make([dynamic]u32, 0, 3 * len(triangles), heap)
	for t in triangles {
		if t[0] >= u32(n) || t[1] >= u32(n) || t[2] >= u32(n) || t[0] == t[1] || t[1] == t[2] || t[2] == t[0] {
			dropped += 1
			continue
		}
		append(&m.vert, t[0], t[1], t[2])
	}
	corners := len(m.vert)
	m.twin = make([dynamic]u32, corners, heap)
	m.state = make([dynamic]i8, corners, heap)
	m.dead = make([dynamic]bool, corners / 3, heap)
	for c in 0 ..< corners do m.twin[c], m.state[c] = NONE, UNJUDGED

	// Each corner filed under its edge's smaller vertex, in corner order: the edges at a
	// vertex are a handful, so matching them is a short scan.
	first := make([]u32, n + 1, heap)
	defer delete(first, heap)
	for c in 0 ..< corners do first[min(m.vert[c], m.vert[corner_next(u32(c))]) + 1] += 1
	for v in 0 ..< n do first[v + 1] += first[v]
	filed := make([]u32, corners, heap)
	defer delete(filed, heap)
	{
		at := make([]u32, n, heap)
		defer delete(at, heap)
		copy(at, first[:n])
		for c in 0 ..< corners {
			lo := min(m.vert[c], m.vert[corner_next(u32(c))])
			filed[at[lo]] = u32(c)
			at[lo] += 1
		}
	}
	other :: #force_inline proc(m: ^Work_Mesh, c, lo: u32) -> u32 {
		a, b := m.vert[c], m.vert[corner_next(c)]
		return b if a == lo else a
	}
	for v in 0 ..< n {
		list := filed[first[v]:first[v + 1]]
		for c, i in list {
			if m.twin[c] != NONE || m.state[c] == SHARP do continue
			w := other(&m, c, u32(v))
			same, partner := 0, NONE
			for d in list[i + 1:] do if other(&m, d, u32(v)) == w {
				same += 1
				partner = d
			}
			// SHARP marks the corners of a torn edge for this loop only; they get UNJUDGED back.
			if same == 1 && m.vert[partner] == m.vert[corner_next(c)] {
				m.twin[c], m.twin[partner] = partner, c
			} else if same > 0 {
				torn += 1
				m.featured[v], m.featured[w] = true, true
				m.state[c] = SHARP
				for d in list[i + 1:] do if other(&m, d, u32(v)) == w do m.state[d] = SHARP
			}
		}
	}
	for &s in m.state do s = UNJUDGED
	for e in features {
		if e[0] >= u32(n) || e[1] >= u32(n) do continue
		lo, hi := min(e[0], e[1]), max(e[0], e[1])
		for c in filed[first[lo]:first[lo + 1]] do if other(&m, c, lo) == hi {
			m.state[c] = CALLER
			m.featured[lo], m.featured[hi] = true, true
		}
	}
	if len(frozen) == n {
		for c in 0 ..< corners {
			a, b := m.vert[c], m.vert[corner_next(u32(c))]
			if m.twin[c] != NONE || !frozen[a] || !frozen[b] do continue
			m.state[c] = FROZEN
			m.featured[a], m.featured[b] = true, true
		}
	}

	// The fans: each walked from its border corner (or anywhere round an inner vertex),
	// the first at a vertex keeping it and each later one getting a copy.
	walked := make([]bool, corners, heap)
	defer delete(walked, heap)
	for c in 0 ..< u32(corners) {
		if walked[c] do continue
		v := m.vert[c]
		if m.corner[v] != NONE {
			w := u32(len(m.pos))
			append(&m.pos, m.pos[v])
			append(&m.corner, NONE)
			append(&m.target, m.target[v])
			append(&m.payload, m.payload[v])
			append(&m.featured, m.featured[v])
			append(&m.near, NONE)
			append(&m.stamp, 0)
			fans_split += 1
			v = w
		}
		start := c
		back := c
		for {
			t := m.twin[back]
			if t == NONE {
				start = back
				break
			}
			back = corner_next(t)
			if back == c do break
		}
		for at := start; at != NONE; at = ring_step(&m, start, at) {
			walked[at] = true
			m.vert[at] = v
		}
		m.corner[v] = start
	}
	return
}

// The corner after c in the walk round its vertex that starts at `start`, or NONE where
// the walk ends: back at the start, or at the border.
ring_step :: #force_inline proc(m: ^Work_Mesh, start, c: u32) -> u32 {
	t := m.twin[corner_prev(c)]
	return NONE if t == NONE || t == start else t
}

// Whether v is on a border.
work_border :: #force_inline proc(m: ^Work_Mesh, v: u32) -> bool {
	return m.twin[m.corner[v]] == NONE
}

// The last corner of v's walk: on a border, the one whose previous edge comes in along it.
ring_last :: proc(m: ^Work_Mesh, v: u32) -> u32 {
	start := m.corner[v]
	last := start
	for c := start; c != NONE; c = ring_step(m, start, c) do last = c
	return last
}

// How many vertices v has as neighbours.
work_valence :: proc(m: ^Work_Mesh, v: u32) -> int {
	start := m.corner[v]
	n := 0
	for c := start; c != NONE; c = ring_step(m, start, c) do n += 1
	return n + 1 if m.twin[start] == NONE else n
}

// How many of v's edges are features (SHARP or CALLER): two inside a feature line, more
// at a junction.
work_feature_edges :: proc(m: ^Work_Mesh, v: u32) -> (n: int) {
	start := m.corner[v]
	last := start
	for c := start; c != NONE; c = ring_step(m, start, c) {
		if m.state[c] >= SHARP do n += 1
		last = c
	}
	// A border vertex's incoming border edge is seen only from its own triangle.
	if m.twin[start] == NONE && m.state[corner_prev(last)] >= SHARP do n += 1
	return
}

// Whether v lies on one of the caller's feature edges.
work_on_caller :: proc(m: ^Work_Mesh, v: u32) -> bool {
	start := m.corner[v]
	last := start
	for c := start; c != NONE; c = ring_step(m, start, c) {
		if m.state[c] == CALLER do return true
		last = c
	}
	return m.twin[start] == NONE && m.state[corner_prev(last)] == CALLER
}

// Marks v's neighbours with a new stamp and returns it.
@(private = "file")
work_mark_neighbours :: proc(m: ^Work_Mesh, v: u32) -> u32 {
	m.stamped += 1
	if m.stamped == 0 {
		for &s in m.stamp do s = 0
		m.stamped = 1
	}
	start := m.corner[v]
	last := start
	for c := start; c != NONE; c = ring_step(m, start, c) {
		m.stamp[m.vert[corner_next(c)]] = m.stamped
		last = c
	}
	if m.twin[start] == NONE do m.stamp[m.vert[corner_prev(last)]] = m.stamped
	return m.stamped
}

// Whether a and b are joined by an edge.
work_joined :: proc(m: ^Work_Mesh, a, b: u32) -> bool {
	start := m.corner[a]
	for c := start; c != NONE; c = ring_step(m, start, c) {
		if m.vert[corner_next(c)] == b || m.vert[corner_prev(c)] == b do return true
	}
	return false
}

// How many neighbours a and b share.
@(private = "file")
work_shared_neighbours :: proc(m: ^Work_Mesh, a, b: u32) -> int {
	s := work_mark_neighbours(m, a)
	start := m.corner[b]
	last := start
	n := 0
	for c := start; c != NONE; c = ring_step(m, start, c) {
		if m.stamp[m.vert[corner_next(c)]] == s do n += 1
		last = c
	}
	if m.twin[start] == NONE && m.stamp[m.vert[corner_prev(last)]] == s do n += 1
	return n
}

// A triangle counts as degenerate when its area is negligible beside the square of its
// longest edge, which does not depend on the mesh's scale.
degenerate :: proc(a, b, c: [3]f64) -> bool {
	ab, bc, ca := b - a, c - b, a - c
	longest := max(dot3(ab, ab), dot3(bc, bc), dot3(ca, ca))
	if !(longest > 0) do return true
	n := cross3(ab, c - a)
	return 0.5 * math.sqrt(dot3(n, n)) <= 1e-6 * longest
}

// Whether moving v to `to` makes one of its triangles degenerate or turns one over.
work_move_breaks :: proc(m: ^Work_Mesh, v: u32, to: [3]f64) -> bool {
	start := m.corner[v]
	for c := start; c != NONE; c = ring_step(m, start, c) {
		p, q := m.pos[m.vert[corner_next(c)]], m.pos[m.vert[corner_prev(c)]]
		if degenerate(to, p, q) do return true
		before := cross3(p - m.pos[v], q - m.pos[v])
		if dot3(before, before) > 0 && dot3(before, cross3(p - to, q - to)) <= 0 do return true
	}
	return false
}

// The collapsed triangles taken out, the rest moved down in order (their corners' twins
// and the vertices' corners renumbered to match), so the next pass walks and counts only
// live triangles and the arrays stop growing with the churn of the rounds.
work_compact :: proc(m: ^Work_Mesh) {
	heap := runtime.heap_allocator()
	moved := make([]u32, len(m.dead), heap)
	defer delete(moved, heap)
	live := 0
	for d, f in m.dead {
		moved[f] = NONE
		if d do continue
		moved[f] = u32(live)
		live += 1
	}
	if live == len(m.dead) do return
	renumber :: #force_inline proc(moved: []u32, c: u32) -> u32 {
		return NONE if c == NONE else 3 * moved[c / 3] + c % 3
	}
	for f in 0 ..< len(m.dead) {
		to := moved[f]
		if to == NONE do continue
		for k in u32(0) ..< 3 {
			from := 3 * u32(f) + k
			at := 3 * to + k
			m.vert[at] = m.vert[from]
			m.twin[at] = renumber(moved, m.twin[from])
			m.state[at] = m.state[from]
		}
	}
	for &c in m.corner do c = renumber(moved, c)
	resize(&m.vert, 3 * live)
	resize(&m.twin, 3 * live)
	resize(&m.state, 3 * live)
	resize(&m.dead, live)
	for &d in m.dead do d = false
}

// Splits corner c's edge at its middle; returns the new vertex.
work_split :: proc(m: ^Work_Mesh, c: u32) -> u32 {
	a, b := m.vert[c], m.vert[corner_next(c)]
	ta, tb := m.target[a], m.target[b]
	return split_edge(m, c, 0.5 * (m.pos[a] + m.pos[b]), 0.5 * (ta + tb) if ta > 0 && tb > 0 else ta + tb, 0.5 * (m.payload[a] + m.payload[b]))
}

// Splits corner c's edge `t` of the way along it (0 < t < 1), the new vertex's target and
// payload taken there on the straight line between its ends'; returns the new vertex. The
// rest of the edge, on to its end, is the corner that len(m.vert) gave before the call.
work_split_at :: proc(m: ^Work_Mesh, c: u32, t: f64) -> u32 {
	a, b := m.vert[c], m.vert[corner_next(c)]
	ta, tb := m.target[a], m.target[b]
	return split_edge(m, c, m.pos[a] + t * (m.pos[b] - m.pos[a]), ta + t * (tb - ta) if ta > 0 && tb > 0 else ta + tb, m.payload[a] + t * (m.payload[b] - m.payload[a]))
}

// The corner whose edge runs from a to b, or NONE.
work_find :: proc(m: ^Work_Mesh, a, b: u32) -> u32 {
	start := m.corner[a]
	for c := start; c != NONE; c = ring_step(m, start, c) do if m.vert[corner_next(c)] == b do return c
	return NONE
}

// Corner c's edge split at `at`, the new vertex given `target` and `payload`.
@(private = "file")
split_edge :: proc(m: ^Work_Mesh, c: u32, at: [3]f64, target, payload: f64) -> u32 {
	nc, pc := corner_next(c), corner_prev(c)
	a, b, x := m.vert[c], m.vert[nc], m.vert[pc]
	d := m.twin[c]
	mid := u32(len(m.pos))
	append(&m.pos, at)
	append(&m.corner, NONE)
	append(&m.target, target)
	append(&m.payload, payload)
	// The middle of a feature edge is on the feature, and the middle of a border edge on
	// the border; a chord between two featured vertices is neither.
	append(&m.featured, m.state[c] >= SHARP || d == NONE)
	append(&m.near, m.near[a])
	append(&m.stamp, 0)

	// Triangle (a, b, x) becomes (a, mid, x), and (mid, b, x) is added.
	p0 := u32(len(m.vert))
	append(&m.vert, mid, b, x)
	append(&m.twin, NONE, NONE, NONE)
	append(&m.state, m.state[c], m.state[nc], UNJUDGED)
	append(&m.dead, false)
	p1, p2 := p0 + 1, p0 + 2
	m.twin[p1] = m.twin[nc]
	if m.twin[p1] != NONE do m.twin[m.twin[p1]] = p1
	m.vert[nc] = mid
	m.twin[nc], m.twin[p2] = p2, nc
	m.state[nc] = UNJUDGED
	if m.corner[b] == nc do m.corner[b] = p1
	m.corner[mid] = p0
	if d == NONE do return mid

	// Its neighbour (b, a, y) becomes (b, mid, y), and (mid, a, y) is added.
	nd, pd := corner_next(d), corner_prev(d)
	y := m.vert[pd]
	q0 := u32(len(m.vert))
	append(&m.vert, mid, a, y)
	append(&m.twin, NONE, NONE, NONE)
	append(&m.state, m.state[c], m.state[nd], UNJUDGED)
	append(&m.dead, false)
	q1, q2 := q0 + 1, q0 + 2
	m.twin[q1] = m.twin[nd]
	if m.twin[q1] != NONE do m.twin[m.twin[q1]] = q1
	m.vert[nd] = mid
	m.twin[nd], m.twin[q2] = q2, nd
	m.state[nd] = UNJUDGED
	m.twin[c], m.twin[q0] = q0, c
	m.twin[d], m.twin[p0] = p0, d
	if m.corner[a] == nd do m.corner[a] = q1
	return mid
}

// Collapses corner h's edge, its start going into its end, which moves to `to`, if the
// mesh stays sound: no border triangle goes, the two triangles' far corners differ, no
// neighbour is left farther than `longest` (squared) from `to`, the ends share no
// neighbour but those two corners (the link condition), each of those keeps at least
// three edges, and no triangle left round either end turns over or flattens. The feature
// rules are the caller's (isotropic.odin). Returns whether it collapsed.
work_collapse :: proc(m: ^Work_Mesh, h: u32, to: [3]f64, longest: f64) -> bool {
	o := m.twin[h]
	if o == NONE do return false
	nh, ph, no, po := corner_next(h), corner_prev(h), corner_next(o), corner_prev(o)
	a, b, x, y := m.vert[h], m.vert[nh], m.vert[ph], m.vert[po]
	if x == y do return false
	t1, t2, t3, t4 := m.twin[ph], m.twin[nh], m.twin[po], m.twin[no]
	if t1 == NONE || t2 == NONE || t3 == NONE || t4 == NONE do return false
	for v in ([2]u32{a, b}) {
		start := m.corner[v]
		last := start
		for c := start; c != NONE; c = ring_step(m, start, c) {
			p := m.pos[m.vert[corner_next(c)]] - to
			if dot3(p, p) > longest do return false
			last = c
		}
		if m.twin[start] == NONE {
			p := m.pos[m.vert[corner_prev(last)]] - to
			if dot3(p, p) > longest do return false
		}
	}
	if work_shared_neighbours(m, a, b) > 2 do return false
	if work_valence(m, x) <= 3 || work_valence(m, y) <= 3 do return false
	f, g := h / 3, o / 3
	for v in ([2]u32{a, b}) {
		start := m.corner[v]
		for c := start; c != NONE; c = ring_step(m, start, c) {
			if c / 3 == f || c / 3 == g do continue
			corners := [3]u32{c, corner_next(c), corner_prev(c)}
			before, after: [3][3]f64
			for k in 0 ..< 3 {
				w := m.vert[corners[k]]
				before[k] = m.pos[w]
				after[k] = to if w == a || w == b else m.pos[w]
			}
			if degenerate(after[0], after[1], after[2]) do return false
			n0 := cross3(before[1] - before[0], before[2] - before[0])
			if dot3(n0, n0) > 0 && dot3(n0, cross3(after[1] - after[0], after[2] - after[0])) <= 0 do return false
		}
	}

	b_border, x_border, y_border := work_border(m, b), work_border(m, x), work_border(m, y)
	start := m.corner[a]
	for c := start; c != NONE; c = ring_step(m, start, c) do m.vert[c] = b
	// The two edges each lost triangle merges become one, with the stronger feature state.
	merge :: proc(m: ^Work_Mesh, p, q, tp, tq: u32) {
		s := max(m.state[p], m.state[q])
		if s >= SHARP do m.state[tp], m.state[tq] = s, s
		m.twin[tp], m.twin[tq] = tq, tp
	}
	merge(m, ph, nh, t1, t2)
	merge(m, po, no, t3, t4)
	for k in ([6]u32{h, nh, ph, o, no, po}) do m.twin[k] = NONE
	if !b_border do m.corner[b] = t3
	if !x_border do m.corner[x] = t2
	if !y_border do m.corner[y] = t4
	m.corner[a] = NONE
	m.pos[b] = to
	m.dead[f], m.dead[g] = true, true
	return true
}

// Collapses corner h's border edge, its start going into its end, which stays where it
// is, if the mesh stays sound: the start is on the border with one fan, the ends share
// only the triangle's far corner (the link condition), which keeps at least three edges,
// no neighbour is left farther than `longest` (squared) from the end, and no triangle
// left round the start turns over or flattens. Where the triangle is the start's only one
// (an ear, its edge before the start on the border too), the ear goes instead and its
// third edge becomes the border, if both its ends keep three edges. Either way the border
// loses the start's vertex and runs straight from the vertex before it to the end, every
// vertex left on it one it had. The caller decides where the border is straight enough
// (isotropic.odin). Returns whether it collapsed.
work_collapse_border :: proc(m: ^Work_Mesh, h: u32, longest: f64) -> bool {
	if m.twin[h] != NONE do return false
	nh, ph := corner_next(h), corner_prev(h)
	a, b, x := m.vert[h], m.vert[nh], m.vert[ph]
	if m.corner[a] != h do return false
	t1, t2 := m.twin[ph], m.twin[nh]
	if t2 == NONE do return false
	if t1 == NONE {
		if work_valence(m, x) < 4 || work_valence(m, b) < 4 do return false
		// The ear's inner edge, seen from the triangle beyond, is the border now, and the
		// vertex before the start goes out along it.
		m.twin[t2] = NONE
		m.state[t2] = max(m.state[t2], SHARP)
		for k in ([3]u32{h, nh, ph}) do m.twin[k] = NONE
		m.corner[x] = t2
		m.corner[a] = NONE
		m.dead[h / 3] = true
		return true
	}
	if work_shared_neighbours(m, a, b) > 1 do return false
	if work_valence(m, x) <= 3 do return false
	to := m.pos[b]
	start := h
	last := start
	for c := start; c != NONE; c = ring_step(m, start, c) {
		p := m.pos[m.vert[corner_next(c)]] - to
		if dot3(p, p) > longest do return false
		last = c
	}
	{
		p := m.pos[m.vert[corner_prev(last)]] - to
		if dot3(p, p) > longest do return false
	}
	f := h / 3
	for c := start; c != NONE; c = ring_step(m, start, c) {
		if c / 3 == f do continue
		corners := [3]u32{c, corner_next(c), corner_prev(c)}
		before, after: [3][3]f64
		for k in 0 ..< 3 {
			w := m.vert[corners[k]]
			before[k] = m.pos[w]
			after[k] = to if w == a else m.pos[w]
		}
		if degenerate(after[0], after[1], after[2]) do return false
		n0 := cross3(before[1] - before[0], before[2] - before[0])
		if dot3(n0, n0) > 0 && dot3(n0, cross3(after[1] - after[0], after[2] - after[0])) <= 0 do return false
	}

	x_border := work_border(m, x)
	for c := start; c != NONE; c = ring_step(m, start, c) do m.vert[c] = b
	// The triangle's two inner edges become one, with the stronger feature state.
	s := max(m.state[ph], m.state[nh])
	if s >= SHARP do m.state[t1], m.state[t2] = s, s
	m.twin[t1], m.twin[t2] = t2, t1
	for k in ([3]u32{h, nh, ph}) do m.twin[k] = NONE
	// The end keeps its own first corner, on its outgoing border edge; its walk now runs on
	// through the start's old fan to the border edge that came into the start.
	if !x_border do m.corner[x] = t2
	m.corner[a] = NONE
	m.dead[f] = true
	return true
}

// Flips corner h's edge to join the two far corners, if that brings the four corners'
// valences nearer six (four on a border), keeps the ends at three edges or more, adds no
// second edge between two vertices, and neither new triangle flattens or turns against
// the old ones. Returns whether it flipped.
work_flip :: proc(m: ^Work_Mesh, h: u32) -> bool {
	o := m.twin[h]
	if o == NONE || m.state[h] >= SHARP do return false
	a, b, x, y := m.vert[h], m.vert[corner_next(h)], m.vert[corner_prev(h)], m.vert[corner_prev(o)]
	va, vb := work_valence(m, a), work_valence(m, b)
	if va <= 3 || vb <= 3 do return false
	vx, vy := work_valence(m, x), work_valence(m, y)
	deviation :: #force_inline proc(m: ^Work_Mesh, v: u32, valence: int) -> int {
		d := valence - (4 if work_border(m, v) else 6)
		return d * d
	}
	before := deviation(m, a, va) + deviation(m, b, vb) + deviation(m, x, vx) + deviation(m, y, vy)
	after := deviation(m, a, va - 1) + deviation(m, b, vb - 1) + deviation(m, x, vx + 1) + deviation(m, y, vy + 1)
	if after >= before do return false
	return flip_edge(m, h)
}

// Flips corner h's edge if the two angles across it sum to more than a half turn by
// `margin` radians or more (the edge is not locally Delaunay, so the flip makes the
// smaller of the two triangles' smallest angles larger), the two triangles are near flat
// (their normals' cosine at least `flat`, so the surface keeps its shape), the ends keep
// three edges or more, and neither new triangle flattens or turns over.
work_flip_delaunay :: proc(m: ^Work_Mesh, h: u32, margin, flat: f64) -> bool {
	o := m.twin[h]
	if o == NONE || m.state[h] >= SHARP do return false
	a, b, x, y := m.vert[h], m.vert[corner_next(h)], m.vert[corner_prev(h)], m.vert[corner_prev(o)]
	pa, pb, px, py := m.pos[a], m.pos[b], m.pos[x], m.pos[y]
	angle :: #force_inline proc(at, p, q: [3]f64) -> f64 {
		u, v := p - at, q - at
		return math.atan2(math.sqrt(dot3(cross3(u, v), cross3(u, v))), dot3(u, v))
	}
	if angle(px, pa, pb) + angle(py, pb, pa) <= math.PI + margin do return false
	top, bottom := cross3(pb - pa, px - pa), cross3(pa - pb, py - pb)
	lt, lb := math.sqrt(dot3(top, top)), math.sqrt(dot3(bottom, bottom))
	if !(lt > 0) || !(lb > 0) || dot3(top, bottom) < flat * lt * lb do return false
	if work_valence(m, a) <= 3 || work_valence(m, b) <= 3 do return false
	return flip_edge(m, h)
}

// Lawson's flips: the edges of `stack` and the four round each one flipped, while
// work_flip_delaunay takes them, so the triangles of a flat region end Delaunay. The
// margin makes every flip a gain that cannot be undone, so the flips end; `budget` (taken
// down by each) bounds them all the same.
work_flip_to_delaunay :: proc(m: ^Work_Mesh, stack: ^[dynamic]u32, margin, flat: f64, budget: ^int) {
	for len(stack) > 0 {
		h := pop(stack)
		o := m.twin[h]
		if o == NONE || m.dead[h / 3] do continue
		if budget^ <= 0 {
			clear(stack)
			return
		}
		if !work_flip_delaunay(m, h, margin, flat) do continue
		budget^ -= 1
		// The flip made (a, y, x) at h and (b, x, y) at o: their outer edges are h's, the one
		// before it, o's and the one before that.
		append(stack, h, corner_prev(h), o, corner_prev(o))
	}
}

// Corner h's edge turned to join the two far corners, unless the far corners are joined
// already (a second edge between them) or a new triangle would flatten or turn against
// the old ones. Returns whether it flipped.
@(private = "file")
flip_edge :: proc(m: ^Work_Mesh, h: u32) -> bool {
	o := m.twin[h]
	nh, ph, no, po := corner_next(h), corner_prev(h), corner_next(o), corner_prev(o)
	a, b, x, y := m.vert[h], m.vert[nh], m.vert[ph], m.vert[po]
	if work_joined(m, x, y) do return false
	pa, pb, px, py := m.pos[a], m.pos[b], m.pos[x], m.pos[y]
	if degenerate(px, pa, py) || degenerate(py, pb, px) do return false
	old_top, old_bottom := cross3(pa - px, pb - px), cross3(pb - py, pa - py)
	new_top, new_bottom := cross3(pa - px, py - px), cross3(pb - py, px - py)
	if dot3(new_top, old_top) <= 0 || dot3(new_top, old_bottom) <= 0 || dot3(new_bottom, old_top) <= 0 || dot3(new_bottom, old_bottom) <= 0 do return false

	// (a, b, x) and (b, a, y) become (a, y, x) and (b, x, y).
	t_bx, s_bx := m.twin[nh], m.state[nh]
	t_ay, s_ay := m.twin[no], m.state[no]
	s := m.state[h]
	m.vert[nh] = y
	m.vert[no] = x
	m.twin[h], m.state[h] = t_ay, s_ay
	if t_ay != NONE do m.twin[t_ay] = h
	m.twin[o], m.state[o] = t_bx, s_bx
	if t_bx != NONE do m.twin[t_bx] = o
	m.twin[nh], m.twin[no] = no, nh
	m.state[nh], m.state[no] = s, s
	if m.corner[a] == no do m.corner[a] = h
	if m.corner[b] == nh do m.corner[b] = o
	return true
}

// Each corner of a fixed triangle list's opposite: the one corner whose edge runs the other
// way, or NONE where the edge is of one triangle, of three or more, or run twice the same
// way (all counted as border). Corner c is corner c % 3 of triangle c / 3. Corners are
// filed by their vertex, so each edge is found among its own vertex's corners alone.
corner_opposites :: proc(vertex_count: int, triangles: [][3]u32, allocator: runtime.Allocator) -> []u32 {
	corners := 3 * len(triangles)
	opp := make([]u32, corners, allocator)
	first := make([]u32, vertex_count + 1, allocator)
	defer delete(first, allocator)
	for t in triangles do for v in t do first[v + 1] += 1
	for v in 0 ..< vertex_count do first[v + 1] += first[v]
	cursor := make([]u32, vertex_count, allocator)
	defer delete(cursor, allocator)
	copy(cursor, first[:vertex_count])
	filed := make([]u32, corners, allocator)
	defer delete(filed, allocator)
	for t, f in triangles do for k in 0 ..< 3 {
		filed[cursor[t[k]]] = u32(3 * f + k)
		cursor[t[k]] += 1
	}
	vertex :: #force_inline proc(triangles: [][3]u32, c: u32) -> u32 {
		return triangles[c / 3][c % 3]
	}
	for c in 0 ..< u32(corners) {
		a, b := vertex(triangles, c), vertex(triangles, corner_next(c))
		same, reverse, found := 0, 0, NONE
		for i in first[a] ..< first[a + 1] do if vertex(triangles, corner_next(filed[i])) == b do same += 1
		for i in first[b] ..< first[b + 1] {
			o := filed[i]
			if vertex(triangles, corner_next(o)) == a {
				reverse += 1
				found = o
			}
		}
		opp[c] = found if same == 1 && reverse == 1 else NONE
	}
	// An opposite must name this corner back (two edges one way and one the other do not).
	for c in 0 ..< u32(corners) {
		o := opp[c]
		if o != NONE && opp[o] != c do opp[c] = NONE
	}
	return opp
}
