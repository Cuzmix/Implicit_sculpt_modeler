package poly

import "core:math"
import "core:math/linalg"
import "core:slice"

// Edge and point actions, as ZModeler's: each takes the cage and the edges or points its
// target reached (cage ids), changes the cage through an Edit and says what it made. A
// refused action leaves the cage as it was, with the reason.

// What insert_loop made: the new loop's vertices along the ring (new ids), and the slide
// that moves them along the edges they split, by a share of each edge.
Loop_Insert :: struct {
	edit:  Edit_Result,
	verts: []u32,
	// Per new vertex, the two ends of the edge it splits (new ids), the first the one a
	// share of 0 lies on.
	ends:  [][2]u32,
	at:      f32, // the share it went in at, from each edge's first end
	pressed: int, // which of verts is on edge e
}

loop_insert_destroy :: proc(r: ^Loop_Insert) {
	edit_result_destroy(&r.edit)
	delete(r.verts)
	delete(r.ends)
	r^ = {}
}

// Insert loop (ZModeler's Insert edge loop, Blender's Ctrl+R): a loop of new edges across
// every quad of the ring through edge e, each splitting the ring's edges at share `at`
// (0 at e's first vertex, he_vert[2e], to 1 at its other), the share carried across each
// quad to the parallel side so the loop runs straight. Faces at an open ring's ends that
// are not quads take the new point on their side, so the cage stays closed.
insert_loop :: proc(m: ^Mesh, e: u32, share: f32, allocator := context.allocator) -> (r: Loop_Insert, err: Build_Error) {
	edges := make([dynamic]u32, context.temp_allocator)
	faces := make([dynamic]u32, context.temp_allocator)
	edge_ring(m, e, &edges)
	face_loop(m, e, &faces)
	if len(faces) == 0 do return {}, .Degenerate_Face
	at := clamp(share, 0, 1)
	// Each ring edge's first end, carried from one edge to the next across the quad between
	// them: a quad's opposite sides run opposite ways, so the end across from a side's
	// first corner is the corner before the opposite side's first.
	first := make([]u32, len(edges), context.temp_allocator)
	first[0], _ = edge_verts(m, edges[0])
	for i in 0 ..< len(edges) - 1 {
		f := faces[i]
		corners := make([dynamic]u32, context.temp_allocator)
		face_verts(m, f, &corners)
		a := slice_index(corners[:], first[i])
		// The side runs from a to the corner after it or before it round the face; the
		// parallel side's matching end is the corner beside a the other way.
		other := edge_tip_other(m, edges[i], first[i])
		first[i + 1] = corners[(a + 3) % 4] if corners[(a + 1) % 4] == other else corners[(a + 1) % 4]
	}
	// The share is measured from e's own first vertex.
	ea, _ := edge_verts(m, e)
	for x, i in edges do if x == e {
		r.pressed = i
		if first[i] != ea do at = 1 - at
	}
	ed := edit_begin(m, context.temp_allocator)
	split := make(map[u64]u32, allocator = context.temp_allocator)
	r.verts = make([]u32, len(edges), allocator)
	r.ends = make([][2]u32, len(edges), allocator)
	made := make([]u32, len(edges), context.temp_allocator)
	for x, i in edges {
		a, b := edge_verts(m, x)
		start, end := a, b
		if a != first[i] do start, end = b, a
		p := linalg.lerp(m.positions[start], m.positions[end], at)
		v := edit_vertex(&ed, p)
		split[edit_key(a, b)] = v
		made[i] = v
		r.ends[i] = {start, end}
	}
	in_ring := make([]bool, len(m.face_he), context.temp_allocator)
	for f in faces do in_ring[f] = true
	out := make([dynamic]Edit_Face, 0, len(ed.faces) + len(faces), context.temp_allocator)
	for &ef in ed.faces {
		vs := ef.verts[:]
		n := len(vs)
		if in_ring[ef.from] {
			// A quad of the ring: its two split sides, and a quad either side of the new edge.
			k := -1
			for i in 0 ..< 4 do if _, ok := split[edit_key(vs[i], vs[(i + 1) % 4])]; ok {
				k = i
				break
			}
			s1 := split[edit_key(vs[k], vs[(k + 1) % 4])]
			s2 := split[edit_key(vs[(k + 2) % 4], vs[(k + 3) % 4])]
			q1 := Edit_Face{verts = make([dynamic]u32, context.temp_allocator), group = ef.group, from = ef.from}
			q2 := Edit_Face{verts = make([dynamic]u32, context.temp_allocator), group = ef.group, from = NONE}
			append(&q1.verts, vs[k], s1, s2, vs[(k + 3) % 4])
			append(&q2.verts, s1, vs[(k + 1) % 4], vs[(k + 2) % 4], s2)
			append(&out, q1, q2)
			continue
		}
		// Any other face with a split side takes the new point on it.
		grown := Edit_Face{verts = make([dynamic]u32, 0, n + 2, context.temp_allocator), group = ef.group, from = ef.from}
		for i in 0 ..< n {
			append(&grown.verts, vs[i])
			if s, ok := split[edit_key(vs[i], vs[(i + 1) % n])]; ok do append(&grown.verts, s)
		}
		append(&out, grown)
	}
	ed.faces = out
	r.edit = edit_end(m, &ed, allocator) or_return
	for v, i in made {
		r.verts[i] = r.edit.vert[v]
		r.ends[i] = {r.edit.vert[r.ends[i][0]], r.edit.vert[r.ends[i][1]]}
	}
	r.at = at
	return r, .None
}

@(private = "file")
slice_index :: proc(s: []u32, x: u32) -> int {
	for y, i in s do if y == x do return i
	return -1
}

@(private = "file")
edge_tip_other :: proc(m: ^Mesh, e: u32, v: u32) -> u32 {
	a, b := edge_verts(m, e)
	return b if a == v else a
}

// The slide of an inserted loop: its vertices move along the edges they split, a drag of
// 1 the whole of each edge, stopping at the edges' ends.
loop_slide :: proc(m: ^Mesh, r: ^Loop_Insert, allocator := context.allocator) -> (d: Drag_Set) {
	n := len(r.verts)
	d.verts = make([]u32, n, allocator)
	d.base = make([]Vec3, n, allocator)
	d.dir = make([]Vec3, n, allocator)
	for v, i in r.verts {
		a, b := m.positions[r.ends[i][0]], m.positions[r.ends[i][1]]
		d.verts[i], d.base[i], d.dir[i] = v, m.positions[v], b - a
	}
	// A little short of the ends, so the slide never makes an edge of no length.
	d.lo, d.hi = -r.at * 0.98, (1 - r.at) * 0.98
	return
}

// Dissolve edges (ZModeler's Delete on an edge loop, Blender's Dissolve edges): the faces
// on the two sides of each edge become one, and with `drop_points` (Blender's Dissolve
// vertices, on by default there too) the points the edges leave between just two edges
// go as well, so removing a loop leaves the quads it split. Refused when a merged region
// would have a hole (its outline more than one loop) or an edge has no face on one side.
dissolve_edges :: proc(m: ^Mesh, edges: []u32, drop_points := true, allocator := context.allocator) -> (r: Edit_Result, err: Build_Error) {
	gone := make([]bool, len(m.crease), context.temp_allocator)
	for e in edges {
		if edge_border(m, e) do return {}, .Non_Manifold_Edge
		gone[e] = true
	}
	// The faces joined across the edges, each region named by its lowest face.
	root := make([]u32, len(m.face_he), context.temp_allocator)
	for &x, i in root do x = u32(i)
	find :: proc(root: []u32, f: u32) -> u32 {
		f := f
		for root[f] != f {
			root[f] = root[root[f]]
			f = root[f]
		}
		return f
	}
	for e in edges {
		a, b := find(root, m.he_face[2 * e]), find(root, m.he_face[2 * e + 1])
		if a == b do continue
		root[max(a, b)] = min(a, b)
	}
	touched := make([]bool, len(m.positions), context.temp_allocator)
	for e in edges {
		a, b := edge_verts(m, e)
		touched[a], touched[b] = true, true
	}
	// Each region's faces, ascending: the faces sorted by their region, then by id.
	by_region := make([][2]u32, len(m.face_he), context.temp_allocator)
	for f in 0 ..< u32(len(m.face_he)) do by_region[f] = {find(root, f), f}
	slice.sort_by(by_region, proc(x, y: [2]u32) -> bool {return x[0] < y[0] || (x[0] == y[0] && x[1] < y[1])})
	region_at := make([]int, len(m.face_he), context.temp_allocator)
	for i := len(by_region) - 1; i >= 0; i -= 1 do region_at[by_region[i][0]] = i
	ed := edit_begin(m, context.temp_allocator)
	out := make([dynamic]Edit_Face, 0, len(ed.faces), context.temp_allocator)
	region := make([dynamic]u32, context.temp_allocator)
	for f in 0 ..< u32(len(m.face_he)) {
		top := find(root, f)
		if top == f && !has_gone_edge(m, f, gone) {
			append(&out, ed.faces[f])
			continue
		}
		// A region is made once, at its lowest face, which names it.
		if top != f do continue
		clear(&region)
		for i := region_at[top]; i < len(by_region) && by_region[i][0] == top; i += 1 do append(&region, by_region[i][1])
		loop := region_outline(m, region[:], context.temp_allocator) or_return
		nf := Edit_Face{verts = make([dynamic]u32, context.temp_allocator), group = m.group[top], from = top}
		append(&nf.verts, ..loop)
		append(&out, nf)
	}
	ed.faces = out
	if drop_points do drop_two_edge_points(&ed, touched)
	return edit_end(m, &ed, allocator)
}

@(private = "file")
has_gone_edge :: proc(m: ^Mesh, f: u32, gone: []bool) -> bool {
	w := face_walk(m, f)
	for h in face_walk_next(&w) do if gone[edge_of(h)] do return true
	return false
}

// The outline of a set of faces as one loop of vertices, running as the faces do, or an
// error when it is not one loop (a hole inside, or the outline touching itself).
region_outline :: proc(m: ^Mesh, faces: []u32, allocator := context.allocator) -> (loop: []u32, err: Build_Error) {
	in_set := make(map[u32]bool, allocator = context.temp_allocator)
	for f in faces do in_set[f] = true
	next_of := make(map[u32]u32, allocator = context.temp_allocator)
	start := NONE
	count := 0
	for f in faces {
		w := face_walk(m, f)
		for h in face_walk_next(&w) {
			if other := m.he_face[twin(h)]; other != NONE && in_set[other] do continue
			a := m.he_vert[h]
			if _, twice := next_of[a]; twice do return nil, .Non_Manifold_Vertex
			next_of[a] = he_tip(m, h)
			if start == NONE || a < start do start = a
			count += 1
		}
	}
	if count < 3 do return nil, .Degenerate_Face
	out := make([dynamic]u32, 0, count, allocator)
	v := start
	for _ in 0 ..< count {
		append(&out, v)
		v = next_of[v]
		if v == start do break
	}
	if len(out) != count {
		delete(out)
		return nil, .Non_Manifold_Edge
	}
	return out[:], .None
}

// Takes out of the edit's polygons every vertex of `touched` left between exactly two
// edges in the middle of a run (on no border), which a dissolve leaves on a straight
// side; a polygon that would drop below three corners keeps them.
@(private = "file")
drop_two_edge_points :: proc(e: ^Edit, touched: []bool) {
	neighbours := make([][dynamic]u32, len(e.positions), context.temp_allocator)
	uses := make([]int, len(e.positions), context.temp_allocator)
	add :: proc(list: ^[dynamic]u32, v: u32) {
		for x in list do if x == v do return
		append(list, v)
	}
	for f in e.faces {
		n := len(f.verts)
		for i in 0 ..< n {
			v := f.verts[i]
			if int(v) >= len(touched) || !touched[v] do continue
			if neighbours[v] == nil do neighbours[v] = make([dynamic]u32, context.temp_allocator)
			add(&neighbours[v], f.verts[(i + 1) % n])
			add(&neighbours[v], f.verts[(i + n - 1) % n])
			uses[v] += 1
		}
	}
	for &f in e.faces {
		kept := make([dynamic]u32, 0, len(f.verts), context.temp_allocator)
		for v in f.verts {
			// Two edges and two faces: a point inside a straight run, not a border corner.
			if int(v) < len(touched) && touched[v] && len(neighbours[v]) == 2 && uses[v] == 2 do continue
			append(&kept, v)
		}
		if len(kept) >= 3 && len(kept) < len(f.verts) {
			clear(&f.verts)
			append(&f.verts, ..kept[:])
		}
	}
}

// Collapse (ZModeler's Collapse on an edge) and weld: every edge of `edges` shrinks to a
// point, its two ends becoming its first, at the middle (or, with `keep_first`, where the
// first end is: ZModeler's Weld points). Faces left with fewer than three corners go.
collapse_edges :: proc(m: ^Mesh, edges: []u32, keep_first := false, allocator := context.allocator) -> (r: Edit_Result, err: Build_Error) {
	pairs := make([][2]u32, len(edges), context.temp_allocator)
	for e, i in edges {
		a, b := edge_verts(m, e)
		pairs[i] = {a, b}
	}
	return merge_points(m, pairs, keep_first, allocator)
}

// Merges each pair's second point into its first (chains follow through), placing each
// merged point at the mean of what joined it, or with `keep_first` where its first point
// is. Consecutive repeats in a polygon fold, and polygons left with fewer than three
// corners go.
merge_points :: proc(m: ^Mesh, pairs: [][2]u32, keep_first := false, allocator := context.allocator) -> (r: Edit_Result, err: Build_Error) {
	into := make([]u32, len(m.positions), context.temp_allocator)
	for &x, i in into do x = u32(i)
	find :: proc(into: []u32, v: u32) -> u32 {
		v := v
		for into[v] != v {
			into[v] = into[into[v]]
			v = into[v]
		}
		return v
	}
	for p in pairs {
		a, b := find(into, p[0]), find(into, p[1])
		if a == b do continue
		// The lower id stays, so the result does not depend on the pairs' order.
		into[max(a, b)] = min(a, b)
	}
	ed := edit_begin(m, context.temp_allocator)
	sum := make([]Vec3, len(m.positions), context.temp_allocator)
	count := make([]int, len(m.positions), context.temp_allocator)
	for v in 0 ..< u32(len(m.positions)) {
		t := find(into, v)
		sum[t] += m.positions[v]
		count[t] += 1
	}
	if !keep_first {
		for v in 0 ..< len(m.positions) do if count[v] > 1 do ed.positions[v] = sum[v] / f32(count[v])
	} else {
		// Where each pair's first point is: the first of the first pair that names the group.
		placed := make([]bool, len(m.positions), context.temp_allocator)
		for p in pairs {
			t := find(into, p[0])
			if placed[t] do continue
			placed[t] = true
			ed.positions[t] = m.positions[p[0]]
		}
	}
	out := make([dynamic]Edit_Face, 0, len(ed.faces), context.temp_allocator)
	for &f in ed.faces {
		folded := make([dynamic]u32, 0, len(f.verts), context.temp_allocator)
		for v in f.verts {
			t := find(into, v)
			if len(folded) > 0 && folded[len(folded) - 1] == t do continue
			append(&folded, t)
		}
		for len(folded) > 1 && folded[0] == folded[len(folded) - 1] do pop(&folded)
		if len(folded) < 3 do continue
		f.verts = folded
		append(&out, f)
	}
	ed.faces = out
	return edit_end(m, &ed, allocator)
}

// Spin (ZModeler's Spin edge, Blender's Rotate edge): the edge turns one step round the
// two faces it joins, so their shared side runs between the next corners instead.
spin_edge :: proc(m: ^Mesh, e: u32, allocator := context.allocator) -> (r: Edit_Result, err: Build_Error) {
	if edge_border(m, e) do return {}, .Non_Manifold_Edge
	h1, h2 := 2 * e, 2 * e + 1
	f1, f2 := m.he_face[h1], m.he_face[h2]
	if f1 == f2 do return {}, .Non_Manifold_Edge
	// f1 = a, b, c1 .. ck; f2 = b, a, d1 .. dm; the new side runs c1 - d1.
	cs := make([dynamic]u32, context.temp_allocator)
	ds := make([dynamic]u32, context.temp_allocator)
	for h := m.he_next[m.he_next[h1]]; h != h1; h = m.he_next[h] do append(&cs, m.he_vert[h])
	for h := m.he_next[m.he_next[h2]]; h != h2; h = m.he_next[h] do append(&ds, m.he_vert[h])
	a, b := m.he_vert[h1], m.he_vert[h2]
	ed := edit_begin(m, context.temp_allocator)
	fa := &ed.faces[f1]
	fb := &ed.faces[f2]
	clear(&fa.verts)
	clear(&fb.verts)
	// c1 .. ck, a, d1 and d1 .. dm, b, c1.
	append(&fa.verts, ..cs[:])
	append(&fa.verts, a, ds[0])
	append(&fb.verts, ..ds[:])
	append(&fb.verts, b, cs[0])
	return edit_end(m, &ed, allocator)
}

// Close hole (ZModeler's Close on a border, Blender's F): one face over the border loop
// edge e lies on.
close_hole :: proc(m: ^Mesh, e: u32, group: u16, allocator := context.allocator) -> (r: Edit_Result, err: Build_Error) {
	h := 2 * e if m.he_face[2 * e] == NONE else 2 * e + 1
	if m.he_face[h] != NONE do return {}, .Non_Manifold_Edge
	loop := make([dynamic]u32, context.temp_allocator)
	w := loop_walk(m, h)
	for o in face_walk_next(&w) do append(&loop, m.he_vert[o])
	if len(loop) < 3 do return {}, .Degenerate_Face
	ed := edit_begin(m, context.temp_allocator)
	edit_face(&ed, loop[:], group)
	return edit_end(m, &ed, allocator)
}

// What extrude_border made: the new faces and the drag that moves the new points.
Border_Extrude :: struct {
	edit:  Edit_Result,
	sides: []u32,
}

border_extrude_destroy :: proc(r: ^Border_Extrude) {
	edit_result_destroy(&r.edit)
	delete(r.sides)
	r^ = {}
}

// Extrude a border (ZModeler's Extrude on a border edge, Blender's E on a border): each
// border edge of `edges` grows a quad outward, its outer points shared where the edges
// meet; the drag pulls them out in the surface's plane (with `along_normal`, ZModeler's
// Alt, along the surface's normal instead).
extrude_border :: proc(m: ^Mesh, edges: []u32, along_normal: bool, allocator := context.allocator) -> (r: Border_Extrude, d: Drag_Set, err: Build_Error) {
	ed := edit_begin(m, context.temp_allocator)
	copy_of := make(map[u32]u32, allocator = context.temp_allocator)
	way := make(map[u32]Vec3, allocator = context.temp_allocator)
	order := make([dynamic]u32, context.temp_allocator)
	group := u16(0)
	for e in edges {
		h := 2 * e if m.he_face[2 * e] == NONE else 2 * e + 1
		if m.he_face[h] != NONE do return {}, {}, .Non_Manifold_Edge
		a, b := m.he_vert[h], he_tip(m, h)
		inner := m.he_face[twin(h)]
		group = m.group[inner]
		n := face_normal(m, inner)
		// Outward: away from the inner face, in its plane (the face runs b -> a here, so
		// its inside is to the left of b -> a about n).
		out := linalg.normalize0(linalg.cross(n, m.positions[b] - m.positions[a]))
		if along_normal do out = n
		for v in ([2]u32{a, b}) {
			if _, ok := copy_of[v]; !ok {
				copy_of[v] = edit_vertex(&ed, m.positions[v], m.corner[v])
				append(&order, v)
			}
			way[v] = way[v] + out
		}
	}
	for e in edges {
		h := 2 * e if m.he_face[2 * e] == NONE else 2 * e + 1
		a, b := m.he_vert[h], he_tip(m, h)
		edit_face(&ed, {a, b, copy_of[b], copy_of[a]}, group)
	}
	r.edit = edit_end(m, &ed, allocator) or_return
	sides := make([dynamic]u32, allocator)
	for from, i in r.edit.face_from do if from == NONE do append(&sides, u32(i))
	r.sides = sides[:]
	d.verts = make([]u32, len(order), allocator)
	d.base = make([]Vec3, len(order), allocator)
	d.dir = make([]Vec3, len(order), allocator)
	for v, i in order {
		nv := r.edit.vert[copy_of[v]]
		d.verts[i], d.base[i] = nv, m.positions[nv]
		d.dir[i] = linalg.normalize0(way[v])
	}
	return r, d, .None
}

// Bridge (ZModeler's Bridge, Blender's Bridge edge loops): a band of quads joining the
// whole border loops edges a and b lie on, which need as many edges each. Each point of
// one loop joins the point of the other that keeps the band least twisted.
bridge_borders :: proc(m: ^Mesh, a, b: u32, allocator := context.allocator) -> (r: Edit_Result, err: Build_Error) {
	la := make([dynamic]u32, context.temp_allocator)
	lb := make([dynamic]u32, context.temp_allocator)
	border_points(m, a, &la) or_return
	border_points(m, b, &lb) or_return
	n := len(la)
	if n != len(lb) || n < 3 do return {}, .Degenerate_Face
	if la[0] == lb[0] || slice.contains(lb[:], la[0]) do return {}, .Non_Manifold_Edge
	// Point i of the first runs to point (s - i) of the second, which runs the other way
	// along its border; s is the turn with the shortest band.
	best_s, best := 0, max(f32)
	for s in 0 ..< n {
		total: f32
		for i in 0 ..< n do total += linalg.length(m.positions[la[i]] - m.positions[lb[(s - i + n) % n]])
		if total < best do best_s, best = s, total
	}
	ed := edit_begin(m, context.temp_allocator)
	group := group_next(m)
	for i in 0 ..< n {
		p0, p1 := la[i], la[(i + 1) % n]
		q0, q1 := lb[(best_s - i + n) % n], lb[(best_s - i - 1 + 2 * n) % n]
		edit_face(&ed, {p0, p1, q1, q0}, group)
	}
	return edit_end(m, &ed, allocator)
}

// The points of the border loop edge e lies on, in the border's own direction.
@(private = "file")
border_points :: proc(m: ^Mesh, e: u32, out: ^[dynamic]u32) -> Build_Error {
	h := 2 * e if m.he_face[2 * e] == NONE else 2 * e + 1
	if m.he_face[h] != NONE do return .Non_Manifold_Edge
	w := loop_walk(m, h)
	for o in face_walk_next(&w) do append(out, m.he_vert[o])
	return .None
}

// Connect (ZModeler's Connect points, Blender's J): face f split in two by a new edge
// between its corners u and v, which must not be neighbours.
connect_points :: proc(m: ^Mesh, f, u, v: u32, allocator := context.allocator) -> (r: Edit_Result, err: Build_Error) {
	ed := edit_begin(m, context.temp_allocator)
	vs := ed.faces[f].verts[:]
	n := len(vs)
	i, j := slice_index(vs, u), slice_index(vs, v)
	if i < 0 || j < 0 || i == j || (i + 1) % n == j || (j + 1) % n == i do return {}, .Degenerate_Face
	part1 := make([dynamic]u32, context.temp_allocator)
	part2 := make([dynamic]u32, context.temp_allocator)
	for k := i; ; k = (k + 1) % n {
		append(&part1, vs[k])
		if k == j do break
	}
	for k := j; ; k = (k + 1) % n {
		append(&part2, vs[k])
		if k == i do break
	}
	group := ed.faces[f].group
	clear(&ed.faces[f].verts)
	append(&ed.faces[f].verts, ..part1[:])
	edit_face(&ed, part2[:], group)
	return edit_end(m, &ed, allocator)
}

// Dissolve a point (ZModeler's Delete on a point, Blender's Dissolve vertices): the faces
// round inner point v become one, without it; its neighbours stay corners of that face.
dissolve_point :: proc(m: ^Mesh, v: u32, allocator := context.allocator) -> (r: Edit_Result, err: Build_Error) {
	if vert_border(m, v) do return {}, .Non_Manifold_Edge
	edges := make([dynamic]u32, context.temp_allocator)
	w := vertex_walk(m, v)
	for h in vertex_walk_next(&w) do append(&edges, edge_of(h))
	return dissolve_edges(m, edges[:], false, allocator)
}

// Dissolve by angle (Blender's Limited dissolve): every edge whose two faces bend less
// than `degrees` from each other goes, so flat stretches cut into many faces become few.
dissolve_by_angle :: proc(m: ^Mesh, degrees: f32, allocator := context.allocator) -> (r: Edit_Result, err: Build_Error) {
	limit := math.cos(degrees * math.RAD_PER_DEG)
	edges := make([dynamic]u32, context.temp_allocator)
	for e in 0 ..< u32(len(m.crease)) {
		if edge_border(m, e) || m.crease[e] > 0 do continue
		f1, f2 := m.he_face[2 * e], m.he_face[2 * e + 1]
		if f1 == f2 || m.group[f1] != m.group[f2] do continue
		if linalg.dot(face_normal(m, f1), face_normal(m, f2)) >= limit do append(&edges, e)
	}
	if len(edges) == 0 do return {}, .None
	return dissolve_edges(m, edges[:], true, allocator)
}

// Merge by distance (Blender's): points closer than `distance` join, at their middle.
// Points are bucketed on a grid of that spacing, so it stays near linear.
merge_by_distance :: proc(m: ^Mesh, distance: f32, allocator := context.allocator) -> (r: Edit_Result, merged: int, err: Build_Error) {
	if distance <= 0 do return {}, 0, .None
	cell :: proc(p: Vec3, d: f32) -> [3]i32 {return {i32(math.floor(p.x / d)), i32(math.floor(p.y / d)), i32(math.floor(p.z / d))}}
	// The points sorted by cell, and where each cell's run starts.
	Point :: struct {
		cell: [3]i32,
		v:    u32,
	}
	sorted := make([]Point, len(m.positions), context.temp_allocator)
	for p, v in m.positions do sorted[v] = {cell(p, distance), u32(v)}
	slice.sort_by(sorted, proc(a, b: Point) -> bool {
		if a.cell.x != b.cell.x do return a.cell.x < b.cell.x
		if a.cell.y != b.cell.y do return a.cell.y < b.cell.y
		if a.cell.z != b.cell.z do return a.cell.z < b.cell.z
		return a.v < b.v
	})
	runs := make(map[[3]i32]int, allocator = context.temp_allocator)
	for i := len(sorted) - 1; i >= 0; i -= 1 do runs[sorted[i].cell] = i
	pairs := make([dynamic][2]u32, context.temp_allocator)
	d2 := distance * distance
	for p, v in m.positions {
		c := cell(p, distance)
		for dx in i32(-1) ..= 1 do for dy in i32(-1) ..= 1 do for dz in i32(-1) ..= 1 {
			at, ok := runs[c + {dx, dy, dz}]
			if !ok do continue
			for i := at; i < len(sorted) && sorted[i].cell == c + {dx, dy, dz}; i += 1 {
				o := sorted[i].v
				if o > u32(v) && linalg.length2(m.positions[o] - p) < d2 do append(&pairs, [2]u32{u32(v), o})
			}
		}
	}
	if len(pairs) == 0 do return {}, 0, .None
	before := len(m.positions)
	r = merge_points(m, pairs[:], false, allocator) or_return
	return r, before - len(m.positions), .None
}
