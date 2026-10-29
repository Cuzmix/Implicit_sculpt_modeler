package poly

import "core:math/linalg"
import "core:slice"

// The live stack (ZBrush's Dynamic Subdivision Thickness and QGrid, Blender's Mirror,
// Solidify and Bevel modifiers): what Model mode draws in place of the cage, before Smooth
// and Flat, made again from the cage after every edit, so the cage itself stays as simple
// as it was modelled. Mirror adds the cage's image across the planes through its origin,
// the points on a plane shared by both halves; Thickness gives the cage a shell, each border closed by a rim whose
// two edge loops are creased; Bevel creases then makes a strip of every creased edge, so
// Smooth rounds it to a tight fillet instead of a crease (a crease's sharpness then only
// says which edges are bevelled).
//
// The live mesh keeps the cage's points as its first ones, on the side of the shell that
// faces out, except where the bevel replaces a point, and its first faces are the cage's
// own faces in order (the mirror's images come after them), so the app can show and pick the cage on the drawn surface through
// the maps here.

Live :: struct {
	mirror:             Mirror_Axes, // the planes the cage is mirrored across, first
	thickness:          f32, // the shell's thickness; 0 for off
	thickness_segments: int, // faces across each rim, 1 to LIVE_THICKNESS_SEGMENTS_MAX
	side:               Thickness_Side,
	bevel:              f32, // the strips' width; 0 for off
	bevel_segments:     int, // faces across each strip, 1 to BEVEL_SEGMENTS_MAX
}

// Where the shell grows from the cage: outward along its normals, inward, or half each way.
Thickness_Side :: enum u8 {
	Out,
	In,
	Centre,
}

LIVE_THICKNESS_SEGMENTS_MAX :: 6

// What the stack made, and how the cage maps onto it.
Live_Mesh :: struct {
	mesh:          Mesh,
	// Per cage point, the live points standing for it: the one it became, or, where the
	// bevel replaced it, those that took its place (ascending). Point v's are
	// vert_ids[vert_first[v]:vert_first[v + 1]].
	vert_first:    []u32,
	vert_ids:      []u32,
	// Per cage edge, the live half-edge running from its first end's side to the other's,
	// or NONE where the bevel made it a strip.
	edge:          []u32,
	// Per live face, the cage face it came from: a strip's, the face beside its edge; a
	// rim's, the face beside its border; NONE for a bevel's corner patches.
	face_from:     []u32,
	// The bevel was left out: a creased edge reaches a point it cannot round (where only
	// two edges meet), and the stack is drawn without it.
	bevel_refused: bool,
	// The mirror was left out: the cage and its image would share an edge already
	// between two faces (a face of the cage lies across the plane), and the stack is drawn
	// without it.
	mirror_refused: bool,
}

live_mesh_destroy :: proc(lm: ^Live_Mesh) {
	mesh_destroy(&lm.mesh)
	delete(lm.vert_first)
	delete(lm.vert_ids)
	delete(lm.edge)
	delete(lm.face_from)
	lm^ = {}
}

// Whether the stack changes anything.
live_on :: proc(l: Live) -> bool {return l.bevel > 0 || l.thickness > 0 || l.mirror != {}}

// Runs the stack over `cage`. Returns the error of a step whose result cannot be built,
// which a valid cage never gives.
live_build :: proc(cage: ^Mesh, l: Live, allocator := context.allocator) -> (lm: Live_Mesh, err: Build_Error) {
	n := u32(len(cage.positions))
	// The cage with its mirror images, and per face the cage face it is (NONE for an
	// image).
	half := cage
	whole: Mesh
	m_from: []u32
	if l.mirror != {} {
		mm, mf, m_err := live_mirror(cage, l.mirror, mirror_slack(cage), context.temp_allocator)
		if m_err == .None {
			whole, m_from, half = mm, mf, &whole
		} else {
			lm.mirror_refused = true
		}
	}
	// The shell, or the mirrored cage itself, with its faces' cage faces.
	t: Mesh
	t_from: []u32
	if l.thickness > 0 {
		t, t_from = live_thickness(half, l.thickness, l.thickness_segments, l.side, context.temp_allocator) or_return
		if m_from != nil do for &f in t_from do f = m_from[f]
	} else {
		t = mesh_clone(half^, context.temp_allocator)
		t_from = make([]u32, len(half.face_he), context.temp_allocator)
		for &f, i in t_from do f = m_from[i] if m_from != nil else u32(i)
	}
	nf := u32(len(t.face_he))
	// The bevel over every creased edge of the shell, in ascending order as bevel_edges
	// takes them, so its strips follow the original faces in that order.
	list := make([dynamic]u32, context.temp_allocator)
	if l.bevel > 0 do for c, e in t.crease do if c > 0 do append(&list, u32(e))
	s := clamp(l.bevel_segments, 1, BEVEL_SEGMENTS_MAX)
	corners := make(map[u64][]u32, allocator = context.temp_allocator)
	r: Edit_Result
	bevelled := false
	if len(list) > 0 {
		b := mesh_clone(t, context.temp_allocator)
		r_b, d, b_err := bevel_edges(&b, list[:], s, context.temp_allocator, &corners)
		if b_err == .None {
			_ = drag_apply(&b, &d, l.bevel)
			old_edges := t
			t, r, bevelled = b, r_b, true
			// The edge map below reads the shell before the bevel.
			defer mesh_destroy(&old_edges)
			lm.vert_first = make([]u32, n + 1, allocator)
			ids := make([dynamic]u32, allocator)
			for v in 0 ..< n {
				if nv := r.vert[v]; nv != NONE {
					append(&ids, nv)
				} else {
					// The points that took its place round it, each once, ascending.
					here := make([dynamic]u32, context.temp_allocator)
					w := vertex_walk(&old_edges, v)
					for h in vertex_walk_next(&w) {
						f := old_edges.he_face[h]
						if f == NONE do continue
						if seq, ok := corners[bevel_key(f, v)]; ok do append(&here, ..seq)
					}
					slice.sort(here[:])
					append(&ids, ..slice.unique(here[:]))
				}
				lm.vert_first[v + 1] = u32(len(ids))
			}
			lm.vert_ids = ids[:]
			lm.edge = make([]u32, len(cage.crease), allocator)
			for e in 0 ..< u32(len(cage.crease)) {
				a, c := edge_verts(cage, e)
				th := find_half_edge(&old_edges, a, c)
				lm.edge[e] = NONE
				if th == NONE || old_edges.crease[edge_of(th)] > 0 do continue
				// On the face beside it, from the last point standing for a there to the
				// first standing for c, or the other way along the face across a border.
				f := old_edges.he_face[th]
				from, to := a, c
				if f == NONE do f, from, to = old_edges.he_face[twin(th)], c, a
				at_from := live_corner(&corners, r.vert, f, from)
				at_to := live_corner(&corners, r.vert, f, to)
				lh := find_half_edge(&t, at_from[len(at_from) - 1], at_to[0])
				if lh != NONE && from != a do lh = twin(lh)
				lm.edge[e] = lh
			}
			lm.face_from = make([]u32, len(r.face_from), allocator)
			for f, i in r.face_from {
				switch {
				case f != NONE:
					lm.face_from[i] = t_from[f]
				case u32(i) < nf + u32(len(list) * s):
					// A strip: the face beside the edge it rounds.
					e := list[(u32(i) - nf) / u32(s)]
					beside := old_edges.he_face[2 * e]
					if beside == NONE do beside = old_edges.he_face[2 * e + 1]
					lm.face_from[i] = t_from[beside]
				case:
					lm.face_from[i] = NONE
				}
			}
		} else {
			mesh_destroy(&b)
			lm.bevel_refused = true
		}
	}
	if !bevelled {
		lm.vert_first = make([]u32, n + 1, allocator)
		lm.vert_ids = make([]u32, n, allocator)
		for v in 0 ..< n do lm.vert_first[v + 1], lm.vert_ids[v] = v + 1, v
		lm.edge = make([]u32, len(cage.crease), allocator)
		for e in 0 ..< u32(len(cage.crease)) {
			a, c := edge_verts(cage, e)
			lm.edge[e] = find_half_edge(&t, a, c)
		}
		lm.face_from = make([]u32, len(t_from), allocator)
		copy(lm.face_from, t_from)
	}
	lm.mesh = mesh_clone(t, allocator)
	mesh_destroy(&t)
	return lm, .None
}

// `m` with its images across the planes through the origin square to each of `axes`, one
// axis after another (so X and Y give four copies), as Blender's Mirror modifier with
// Clipping and Merge on: a point within `slack` of a plane is on the seam, put on the
// plane and shared by both halves; every other point and every face gets an image, the
// face turned over to face out, with its group, creases and corners. m's points and faces
// come first, with their ids. Per face, m's face it is, or NONE for an image. Refused
// when the halves would share an edge that already has two faces, which a face lying
// across the plane gives.
live_mirror :: proc(m: ^Mesh, axes: Mirror_Axes, slack: f32, allocator := context.allocator) -> (out: Mesh, face_from: []u32, err: Build_Error) {
	out = mesh_clone(m^, allocator)
	from := make([dynamic]u32, len(m.face_he), allocator)
	for &f, i in from do f = u32(i)
	for axis in Mirror_Axis {
		if axis not_in axes do continue
		a := int(axis)
		n := u32(len(out.positions))
		e := edit_begin(&out, context.temp_allocator)
		image := make([]u32, n, context.temp_allocator)
		for v in 0 ..< n {
			p := out.positions[v]
			if abs(p[a]) <= slack {
				e.positions[v][a] = 0
				image[v] = v
				continue
			}
			p[a] = -p[a]
			image[v] = edit_vertex(&e, p, out.corner[v])
		}
		verts := make([dynamic]u32, context.temp_allocator)
		for i in 0 ..< len(out.face_he) {
			clear(&verts)
			#reverse for v in e.faces[i].verts do append(&verts, image[v])
			edit_face(&e, verts[:], e.faces[i].group)
			append(&from, NONE)
		}
		// The images' creases, taken from a list since the map grows.
		creased := make([dynamic]u64, 0, len(e.creases), context.temp_allocator)
		for key in e.creases do append(&creased, key)
		for key in creased {
			c := e.creases[key]
			e.creases[edit_key(image[u32(key >> 32)], image[u32(key & 0xffff_ffff)])] = c
		}
		r, edit_err := edit_end(&out, &e, context.temp_allocator)
		// Every point of a cage is in a face, so edit_end keeps every id; were one not,
		// the ids after it would move, and the mirror is refused instead.
		if edit_err == .None && len(r.vert) != len(out.positions) do edit_err = .Degenerate_Face
		if edit_err != .None {
			mesh_destroy(&out)
			delete(from)
			return {}, nil, edit_err
		}
	}
	return out, from[:], .None
}

// Copies the positions of the stack made again from `cage` (moved without a change of
// topology or creases) into `lm`. Returns false, changing nothing, when what it makes no
// longer matches (which the same topology never gives).
live_update :: proc(cage: ^Mesh, l: Live, lm: ^Live_Mesh) -> bool {
	fresh, err := live_build(cage, l, context.temp_allocator)
	if err != .None || len(fresh.mesh.positions) != len(lm.mesh.positions) do return false
	copy(lm.mesh.positions[:], fresh.mesh.positions[:])
	return true
}

// The points standing at face f's corner v after the bevel: those that took its place
// there, or the one it became.
@(private = "file")
live_corner :: proc(corners: ^map[u64][]u32, vert: []u32, f, v: u32) -> []u32 {
	if seq, ok := corners[bevel_key(f, v)]; ok && len(seq) > 0 do return seq
	one := make([]u32, 1, context.temp_allocator)
	one[0] = vert[v]
	return one
}

// `m` as a shell `t` thick (Blender's Solidify with even thickness): the side facing out
// first, its points keeping m's ids and its faces m's, then the side facing in, turned
// over, then each border's rim `segments` faces across, its two edge loops creased so
// Smooth keeps the shell's edges. Per face, the face of `m` it came from (a rim's, the
// face beside its border).
@(private = "file")
live_thickness :: proc(m: ^Mesh, t: f32, segments: int, side: Thickness_Side, allocator := context.allocator) -> (out: Mesh, face_from: []u32, err: Build_Error) {
	n := u32(len(m.positions))
	s := clamp(segments, 1, LIVE_THICKNESS_SEGMENTS_MAX)
	outer, inner: f32
	switch side {
	case .Out:    outer, inner = t, 0
	case .In:     outer, inner = 0, -t
	case .Centre: outer, inner = t / 2, -t / 2
	}
	dirs := live_even_normals(m)
	positions := make([dynamic]Vec3, 0, 2 * n, context.temp_allocator)
	for v in 0 ..< n do append(&positions, m.positions[v] + outer * dirs[v])
	for v in 0 ..< n do append(&positions, m.positions[v] + inner * dirs[v])
	// Per border point, its rim's inner rings, ring k (1 to s - 1) at k - 1.
	rings := u32(s - 1)
	ring := make([]u32, n * rings, context.temp_allocator)
	for v in 0 ..< n {
		if !vert_border(m, v) do continue
		for k in 1 ..< u32(s) {
			ring[v * rings + k - 1] = u32(len(positions))
			append(&positions, m.positions[v] + linalg.lerp(outer, inner, f32(k) / f32(s)) * dirs[v])
		}
	}
	at :: proc(v: u32, k, s: u32, n: u32, ring: []u32) -> u32 {
		if k == 0 do return v
		if k == s do return v + n
		return ring[v * (s - 1) + k - 1]
	}
	sizes := make([dynamic]int, context.temp_allocator)
	corners := make([dynamic]u32, context.temp_allocator)
	groups := make([dynamic]u16, context.temp_allocator)
	from := make([dynamic]u32, allocator)
	verts := make([dynamic]u32, context.temp_allocator)
	nf := u32(len(m.face_he))
	for layer in u32(0) ..< 2 {
		for f in 0 ..< nf {
			face_verts(m, f, &verts)
			append(&sizes, len(verts))
			if layer == 0 {
				for v in verts do append(&corners, v)
			} else {
				#reverse for v in verts do append(&corners, v + n)
			}
			append(&groups, m.group[f])
			append(&from, f)
		}
	}
	// Each border half-edge a to b (no face) gets a column of quads from the outer side to
	// the inner, running b to a on the outer side as the face beside it there runs a to b.
	for h in 0 ..< u32(len(m.he_vert)) {
		if m.he_face[h] != NONE do continue
		a, b := m.he_vert[h], he_tip(m, h)
		beside := m.he_face[twin(h)]
		for k in 0 ..< u32(s) {
			append(&sizes, 4)
			append(&corners, at(a, k, u32(s), n, ring), at(b, k, u32(s), n, ring), at(b, k + 1, u32(s), n, ring), at(a, k + 1, u32(s), n, ring))
			append(&groups, m.group[beside])
			append(&from, beside)
		}
	}
	out, err = mesh_from_polygons(positions[:], sizes[:], corners[:], groups[:], allocator)
	if err != .None {
		delete(from)
		return {}, nil, err
	}
	// Both sides keep the cage's creases and corners; the rim's edge loops are creased.
	for c, e in m.crease {
		a, b := edge_verts(m, u32(e))
		sharp := INFINITE_SHARP if edge_border(m, u32(e)) else c
		if sharp <= 0 do continue
		for shift in ([2]u32{0, n}) {
			if h := find_half_edge(&out, a + shift, b + shift); h != NONE do out.crease[edge_of(h)] = sharp
		}
	}
	for c, v in m.corner do if c > 0 do out.corner[v], out.corner[u32(v) + n] = c, c
	return out, from[:], .None
}

// Per point, the way the shell's side moves from it: the mean of its faces' normals,
// lengthened where they meet at an angle so the side stays parallel to them (as
// Blender's even thickness does), at most twice; along a border, the faces' own.
@(private = "file")
live_even_normals :: proc(m: ^Mesh) -> []Vec3 {
	dirs := make([]Vec3, len(m.positions), context.temp_allocator)
	for v in 0 ..< u32(len(m.positions)) {
		sum: Vec3
		w := vertex_walk(m, v)
		for h in vertex_walk_next(&w) do if f := m.he_face[h]; f != NONE do sum += face_normal(m, f)
		if linalg.length2(sum) < 1e-20 do continue
		dir := linalg.normalize(sum)
		least: f32 = 1
		w = vertex_walk(m, v)
		for h in vertex_walk_next(&w) do if f := m.he_face[h]; f != NONE do least = min(least, linalg.dot(dir, face_normal(m, f)))
		dirs[v] = dir / max(least, 0.5)
	}
	return dirs
}
