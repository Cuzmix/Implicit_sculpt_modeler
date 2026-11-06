package poly

import "core:math/linalg"
import "core:slice"

// More of Blender's and ZModeler's edits, each a rebuild through the polygon list (edit.odin),
// so each leaves a valid cage or is refused with the cage as it was. The faces each one
// makes from a face keep that face's polygroup and selection.

// The midpoint of the edge from a to b in an edit, made once per edge and shared.
@(private = "file")
edge_mid :: proc(ed: ^Edit, mids: ^map[u64]u32, a, b: u32) -> u32 {
	key := edit_key(a, b)
	if v, ok := mids[key]; ok do return v
	v := edit_vertex(ed, (ed.positions[a] + ed.positions[b]) * 0.5)
	mids[key] = v
	// The halves keep the edge's crease.
	if c, ok := ed.creases[key]; ok {
		ed.creases[edit_key(a, v)] = c
		ed.creases[edit_key(v, b)] = c
	}
	return v
}

@(private = "file")
polygon_center :: proc(ed: ^Edit, verts: []u32) -> Vec3 {
	sum: Vec3
	for v in verts do sum += ed.positions[v]
	return sum / f32(max(len(verts), 1))
}

// Subdivide (Blender's Subdivide, one cut): each of `faces` becomes a quad per corner,
// from a new point at its middle to new points at its edges' middles. A face beside one
// takes those edge middles as corners of its own, so nothing is left open, as Blender does.
subdivide_faces :: proc(m: ^Mesh, faces: []u32, allocator := context.allocator) -> (r: Edit_Result, err: Build_Error) {
	ed := edit_begin(m, context.temp_allocator)
	mids := make(map[u64]u32, allocator = context.temp_allocator)
	split := make([]bool, len(ed.faces), context.temp_allocator)
	for f in faces do if int(f) < len(split) do split[f] = true
	// The middles first, in face order, so ids do not depend on the order `faces` came in.
	for s, f in split {
		if !s do continue
		vs := ed.faces[f].verts[:]
		for v, i in vs do edge_mid(&ed, &mids, v, vs[(i + 1) % len(vs)])
	}
	if len(mids) == 0 do return {}, .Degenerate_Face
	count := len(ed.faces)
	for f in 0 ..< count {
		vs := slice.clone(ed.faces[f].verts[:], context.temp_allocator)
		group, from := ed.faces[f].group, ed.faces[f].from
		n := len(vs)
		if split[f] {
			center := edit_vertex(&ed, polygon_center(&ed, vs))
			for v, i in vs {
				before := mids[edit_key(vs[(i + n - 1) % n], v)]
				after := mids[edit_key(v, vs[(i + 1) % n])]
				quad := [4]u32{v, after, center, before}
				if i == 0 {
					clear(&ed.faces[f].verts)
					append(&ed.faces[f].verts, ..quad[:])
				} else {
					edit_face(&ed, quad[:], group, from)
				}
			}
			continue
		}
		// A neighbour takes the middles of the edges it shares with a split face.
		out := make([dynamic]u32, context.temp_allocator)
		for v, i in vs {
			append(&out, v)
			if mid, ok := mids[edit_key(v, vs[(i + 1) % n])]; ok do append(&out, mid)
		}
		if len(out) != n {
			clear(&ed.faces[f].verts)
			append(&ed.faces[f].verts, ..out[:])
		}
	}
	return edit_end(m, &ed, allocator)
}

// Poke (Blender's Poke faces): each of `faces` becomes a fan of triangles round a new
// point at its middle.
poke_faces :: proc(m: ^Mesh, faces: []u32, allocator := context.allocator) -> (r: Edit_Result, err: Build_Error) {
	ed := edit_begin(m, context.temp_allocator)
	poked := make([]bool, len(ed.faces), context.temp_allocator)
	for f in faces do if int(f) < len(poked) do poked[f] = true
	any := false
	count := len(ed.faces)
	for f in 0 ..< count {
		if !poked[f] do continue
		any = true
		vs := slice.clone(ed.faces[f].verts[:], context.temp_allocator)
		group, from := ed.faces[f].group, ed.faces[f].from
		center := edit_vertex(&ed, polygon_center(&ed, vs))
		for v, i in vs {
			tri := [3]u32{v, vs[(i + 1) % len(vs)], center}
			if i == 0 {
				clear(&ed.faces[f].verts)
				append(&ed.faces[f].verts, ..tri[:])
			} else {
				edit_face(&ed, tri[:], group, from)
			}
		}
	}
	if !any do return {}, .Degenerate_Face
	return edit_end(m, &ed, allocator)
}

// How good a quad the corners a, b, c, d (in order) make, lower being better: how far
// its two halves' normals part, and how far its corners are from square. Not ok when it
// would fold or is not convex.
@(private = "file")
quad_score :: proc(p: [4]Vec3) -> (score: f32, ok: bool) {
	n1 := linalg.cross(p[1] - p[0], p[2] - p[0])
	n2 := linalg.cross(p[2] - p[0], p[3] - p[0])
	l1, l2 := linalg.length(n1), linalg.length(n2)
	if l1 < 1e-12 || l2 < 1e-12 do return 0, false
	normal := (n1 + n2) / (l1 + l2)
	bend := 1 - linalg.dot(n1 / l1, n2 / l2)
	for i in 0 ..< 4 {
		a, b, c := p[(i + 3) % 4], p[i], p[(i + 1) % 4]
		turn := linalg.dot(linalg.cross(b - a, c - b), normal)
		if turn <= 0 do return 0, false
		u, v := linalg.normalize0(a - b), linalg.normalize0(c - b)
		score += abs(linalg.dot(u, v))
	}
	return score + 4 * bend, true
}

// Triangles to quads (Blender's Alt J, ZModeler's join): pairs of triangles among `faces`
// sharing an uncreased edge, inside one polygroup, become quads, best-shaped pairs first,
// each triangle in one quad at most. Not ok (refused) when no pair can join.
tris_to_quads :: proc(m: ^Mesh, faces: []u32, allocator := context.allocator) -> (r: Edit_Result, joined: int, err: Build_Error) {
	in_set := make([]bool, len(m.face_he), context.temp_allocator)
	for f in faces do if int(f) < len(in_set) && face_size(m, f) == 3 do in_set[f] = true
	Pair :: struct {
		score: f32,
		edge:  u32,
	}
	pairs := make([dynamic]Pair, context.temp_allocator)
	for e in 0 ..< u32(len(m.crease)) {
		fa, fb := m.he_face[2 * e], m.he_face[2 * e + 1]
		if fa == NONE || fb == NONE || !in_set[fa] || !in_set[fb] || m.crease[e] > 0 || m.group[fa] != m.group[fb] do continue
		q, ok := joined_quad(m, e)
		if !ok do continue
		p := [4]Vec3{m.positions[q[0]], m.positions[q[1]], m.positions[q[2]], m.positions[q[3]]}
		if s, good := quad_score(p); good do append(&pairs, Pair{s, e})
	}
	// Best first; the edge id breaks ties, so the result never hangs on the sort.
	slice.sort_by(pairs[:], proc(a, b: Pair) -> bool {return a.score < b.score || (a.score == b.score && a.edge < b.edge)})
	used := make([]bool, len(m.face_he), context.temp_allocator)
	ed := edit_begin(m, context.temp_allocator)
	gone := make([]bool, len(ed.faces), context.temp_allocator)
	for p in pairs {
		fa, fb := m.he_face[2 * p.edge], m.he_face[2 * p.edge + 1]
		if used[fa] || used[fb] do continue
		used[fa], used[fb] = true, true
		q, _ := joined_quad(m, p.edge)
		clear(&ed.faces[fa].verts)
		append(&ed.faces[fa].verts, ..q[:])
		gone[fb] = true
		joined += 1
	}
	if joined == 0 do return {}, 0, .Degenerate_Face
	kept := make([dynamic]Edit_Face, 0, len(ed.faces), context.temp_allocator)
	for f, i in ed.faces do if !gone[i] do append(&kept, f)
	clear(&ed.faces)
	append(&ed.faces, ..kept[:])
	r, err = edit_end(m, &ed, allocator)
	return r, joined, err
}

// The quad the two triangles across edge e make, in the first triangle's order.
@(private = "file")
joined_quad :: proc(m: ^Mesh, e: u32) -> (q: [4]u32, ok: bool) {
	h := 2 * e
	a, b := m.he_vert[h], he_tip(m, h)
	// The corner of each triangle off the edge.
	c := he_tip(m, m.he_next[h])
	d := he_tip(m, m.he_next[twin(h)])
	if c == d do return {}, false
	// h runs a to b in the first triangle (a, b, c); the other runs b to a (b, a, d).
	return {a, d, b, c}, true
}

// Split (Blender's Split, Y, and Rip's whole-face form): `faces` come away from the rest
// of the cage along their outline, each point they share with a face not among them
// copied for them, so the part can be moved apart.
split_faces :: proc(m: ^Mesh, faces: []u32, allocator := context.allocator) -> (r: Edit_Result, err: Build_Error) {
	ed := edit_begin(m, context.temp_allocator)
	inside := make([]bool, len(ed.faces), context.temp_allocator)
	for f in faces do if int(f) < len(inside) do inside[f] = true
	in_used := make([]bool, len(ed.positions), context.temp_allocator)
	out_used := make([]bool, len(ed.positions), context.temp_allocator)
	for f, i in ed.faces do for v in f.verts {
		if inside[i] do in_used[v] = true
		else do out_used[v] = true
	}
	copy_of := make([]u32, len(ed.positions), context.temp_allocator)
	any := false
	n := len(ed.positions)
	for v in 0 ..< n {
		copy_of[v] = NONE
		if !in_used[v] || !out_used[v] do continue
		copy_of[v] = edit_vertex(&ed, ed.positions[v], ed.corner[v])
		any = true
	}
	if !any do return {}, .Degenerate_Face
	for &f, i in ed.faces {
		if !inside[i] do continue
		for &v in f.verts do if copy_of[v] != NONE do v = copy_of[v]
	}
	// Creases along the part's inside edges follow it onto the copies.
	Moved :: struct {
		key:    u64,
		crease: f32,
	}
	extra := make([dynamic]Moved, context.temp_allocator)
	for key, c in ed.creases {
		a, b := u32(key >> 32), u32(key & 0xffff_ffff)
		if int(a) >= n || int(b) >= n do continue
		ca := copy_of[a] if copy_of[a] != NONE else a
		cb := copy_of[b] if copy_of[b] != NONE else b
		if ca != a || cb != b do append(&extra, Moved{edit_key(ca, cb), c})
	}
	for x in extra do ed.creases[x.key] = x.crease
	return edit_end(m, &ed, allocator)
}

// The cage made of `faces` alone (their points renumbered in order), for Separate, which
// then deletes them from the cage.
faces_mesh :: proc(m: ^Mesh, faces: []u32, allocator := context.allocator) -> (out: Mesh, err: Build_Error) {
	ids := make([]u32, len(m.positions), context.temp_allocator)
	for &v in ids do v = NONE
	wanted := make([]bool, len(m.face_he), context.temp_allocator)
	for f in faces do if int(f) < len(wanted) do wanted[f] = true
	positions := make([dynamic]Vec3, context.temp_allocator)
	sizes := make([dynamic]int, context.temp_allocator)
	corners := make([dynamic]u32, context.temp_allocator)
	groups := make([dynamic]u16, context.temp_allocator)
	vs := make([dynamic]u32, context.temp_allocator)
	for w, f in wanted {
		if !w do continue
		face_verts(m, u32(f), &vs)
		for v in vs {
			if ids[v] == NONE {
				ids[v] = u32(len(positions))
				append(&positions, m.positions[v])
			}
			append(&corners, ids[v])
		}
		append(&sizes, len(vs))
		append(&groups, m.group[f])
	}
	if len(sizes) == 0 do return {}, .Degenerate_Face
	out, err = mesh_from_polygons(positions[:], sizes[:], corners[:], groups[:], allocator)
	if err != .None do return
	for v, i in ids do if v != NONE do out.corner[v] = m.corner[i]
	for e in 0 ..< u32(len(m.crease)) {
		if m.crease[e] == 0 do continue
		a, b := edge_verts(m, e)
		if ids[a] == NONE || ids[b] == NONE do continue
		if h := find_half_edge(&out, ids[a], ids[b]); h != NONE do out.crease[edge_of(h)] = m.crease[e]
	}
	return
}

// The two cages as one (Blender's Join): `b`'s points mapped through `to` into `a`'s
// space and appended, its faces after `a`'s, its polygroups and selection kept.
join_meshes :: proc(a, b: ^Mesh, to: matrix[4, 4]f32, allocator := context.allocator) -> (out: Mesh, err: Build_Error) {
	ed := edit_begin(a, context.temp_allocator)
	base := u32(len(ed.positions))
	for p, i in b.positions do edit_vertex(&ed, (to * [4]f32{p.x, p.y, p.z, 1}).xyz, b.corner[i])
	vs := make([dynamic]u32, context.temp_allocator)
	for f in 0 ..< u32(len(b.face_he)) {
		face_verts(b, f, &vs)
		for &v in vs do v += base
		edit_face(&ed, vs[:], b.group[f])
	}
	for e in 0 ..< u32(len(b.crease)) {
		if b.crease[e] == 0 do continue
		x, y := edge_verts(b, e)
		ed.creases[edit_key(x + base, y + base)] = b.crease[e]
	}
	sizes := make([dynamic]int, context.temp_allocator)
	corners := make([dynamic]u32, context.temp_allocator)
	groups := make([dynamic]u16, context.temp_allocator)
	for f in ed.faces {
		append(&sizes, len(f.verts))
		append(&corners, ..f.verts[:])
		append(&groups, f.group)
	}
	out, err = mesh_from_polygons(ed.positions[:], sizes[:], corners[:], groups[:], allocator)
	if err != .None do return
	for c, v in ed.corner do out.corner[v] = c
	for key, c in ed.creases {
		x, y := u32(key >> 32), u32(key & 0xffff_ffff)
		if h := find_half_edge(&out, x, y); h != NONE do out.crease[edge_of(h)] = c
	}
	for f in 0 ..< min(len(a.selected), len(out.selected)) do out.selected[f] = a.selected[f]
	for f in 0 ..< len(b.selected) do if len(a.face_he) + f < len(out.selected) do out.selected[len(a.face_he) + f] = b.selected[f]
	for v in 0 ..< min(len(a.picked), len(out.picked)) do out.picked[v] = a.picked[v]
	for v in 0 ..< len(b.picked) do if int(base) + v < len(out.picked) do out.picked[int(base) + v] = b.picked[v]
	return
}

// Fill (Blender's Grid fill, F on a border): the hole whose border edge e lies on is
// closed. A border of an even count of six points or more gets a grid of quads, its sides
// split as evenly as the count allows and its inside laid out as a Coons patch of the
// border, so it follows the border's bend; any other closes with one face.
fill_hole :: proc(m: ^Mesh, e: u32, allocator := context.allocator) -> (r: Edit_Result, err: Build_Error) {
	h := 2 * e if m.he_face[2 * e] == NONE else 2 * e + 1
	if m.he_face[h] != NONE do return {}, .Non_Manifold_Edge
	loop := make([dynamic]u32, context.temp_allocator)
	w := loop_walk(m, h)
	for o in face_walk_next(&w) do append(&loop, m.he_vert[o])
	n := len(loop)
	if n < 3 do return {}, .Degenerate_Face
	group := m.group[m.he_face[twin(h)]]
	if n < 6 || n % 2 != 0 do return close_hole(m, e, group, allocator)
	// Sides of a and b edges, a + b = n / 2, as near square as the count allows.
	a := n / 4
	b := n / 2 - a
	ed := edit_begin(m, context.temp_allocator)
	// The grid's corner (i, j), i across 0..a, j down 0..b, on the border going round:
	// bottom (j = 0) left to right, right side up, top right to left, left side down.
	border_at :: proc(loop: []u32, a, b, i, j: int) -> u32 {
		switch {
		case j == 0: return loop[i]
		case i == a: return loop[a + j]
		case j == b: return loop[a + b + (a - i)]
		}
		return loop[(2 * a + b + (b - j)) % len(loop)]
	}
	grid := make([]u32, (a + 1) * (b + 1), context.temp_allocator)
	p :: proc(ed: ^Edit, v: u32) -> Vec3 {return ed.positions[v]}
	for j in 0 ..= b {
		for i in 0 ..= a {
			if i == 0 || i == a || j == 0 || j == b {
				grid[j * (a + 1) + i] = border_at(loop[:], a, b, i, j)
				continue
			}
			s, t := f32(i) / f32(a), f32(j) / f32(b)
			bottom, top := p(&ed, border_at(loop[:], a, b, i, 0)), p(&ed, border_at(loop[:], a, b, i, b))
			left, right := p(&ed, border_at(loop[:], a, b, 0, j)), p(&ed, border_at(loop[:], a, b, a, j))
			c00, c10 := p(&ed, border_at(loop[:], a, b, 0, 0)), p(&ed, border_at(loop[:], a, b, a, 0))
			c01, c11 := p(&ed, border_at(loop[:], a, b, 0, b)), p(&ed, border_at(loop[:], a, b, a, b))
			ruled := (1 - t) * bottom + t * top + (1 - s) * left + s * right
			corner := (1 - s) * (1 - t) * c00 + s * (1 - t) * c10 + (1 - s) * t * c01 + s * t * c11
			grid[j * (a + 1) + i] = edit_vertex(&ed, ruled - corner)
		}
	}
	// The loop runs the way the hole's own (border) half-edges do, which is how a face
	// filling it goes round, so each quad follows the same turn.
	for j in 0 ..< b {
		for i in 0 ..< a {
			quad := [4]u32{grid[j * (a + 1) + i], grid[j * (a + 1) + i + 1], grid[(j + 1) * (a + 1) + i + 1], grid[(j + 1) * (a + 1) + i]}
			edit_face(&ed, quad[:], group)
		}
	}
	return edit_end(m, &ed, allocator)
}

// Bevel points (Blender's Bevel vertices, Ctrl Shift B): each inner point of `points`
// is cut off by a new face through points `share` of the way along each of its edges
// (kept under half, so two bevelled ends of an edge never meet); a border point is left.
bevel_points :: proc(m: ^Mesh, points: []u32, share: f32, allocator := context.allocator) -> (r: Edit_Result, err: Build_Error) {
	t := clamp(share, 0.01, 0.45)
	ed := edit_begin(m, context.temp_allocator)
	cut := make([]bool, len(m.positions), context.temp_allocator)
	for v in points do if int(v) < len(cut) && !vert_border(m, v) && m.vert_he[v] != NONE do cut[v] = true
	// Per bevelled point and edge out of it, the new point along that edge.
	along := make(map[u64]u32, allocator = context.temp_allocator)
	any := false
	for c, v in cut {
		if !c do continue
		any = true
		w := vertex_walk(m, u32(v))
		ring := make([dynamic]u32, context.temp_allocator)
		for h in vertex_walk_next(&w) {
			o := he_tip(m, h)
			q := edit_vertex(&ed, linalg.lerp(m.positions[v], m.positions[o], t))
			along[u64(v) << 32 | u64(o)] = q
			append(&ring, q)
		}
		// The walk turns from each outgoing edge to the next across the face on its left
		// going backward, so the new face runs the other way round to face out.
		slice.reverse(ring[:])
		edit_face(&ed, ring[:], m.group[m.he_face[m.vert_he[v]]])
	}
	if !any do return {}, .Degenerate_Face
	count := len(m.face_he)
	for f in 0 ..< count {
		vs := slice.clone(ed.faces[f].verts[:], context.temp_allocator)
		n := len(vs)
		out := make([dynamic]u32, context.temp_allocator)
		changed := false
		for v, i in vs {
			if !cut[v] {
				append(&out, v)
				continue
			}
			changed = true
			prev, next := vs[(i + n - 1) % n], vs[(i + 1) % n]
			append(&out, along[u64(v) << 32 | u64(prev)])
			append(&out, along[u64(v) << 32 | u64(next)])
		}
		if changed {
			clear(&ed.faces[f].verts)
			append(&ed.faces[f].verts, ..out[:])
		}
	}
	return edit_end(m, &ed, allocator)
}

// Where each of `points` goes when smoothed once: to the middle of its neighbours (a border
// point to the middle of the border points beside it, so a border slides along itself),
// and with `keep_shape` only across the surface, the move along the point's normal taken
// out, so the points even out without the cage shrinking, as Blender's Relax brush and
// ZBrush's Relax do where plain smoothing (Blender's Smooth) shrinks it.
smooth_goals :: proc(m: ^Mesh, points: []u32, keep_shape: bool, allocator := context.allocator) -> []Vec3 {
	goals := relax_points(m, points, allocator)
	if !keep_shape do return goals
	for v, i in points {
		if vert_border(m, v) do continue
		n: Vec3
		w := vertex_walk(m, v)
		for h in vertex_walk_next(&w) do if f := m.he_face[h]; f != NONE do n += face_normal(m, f)
		l := linalg.length(n)
		if l < 1e-12 do continue
		n /= l
		d := goals[i] - m.positions[v]
		goals[i] = m.positions[v] + d - n * linalg.dot(d, n)
	}
	return goals
}
