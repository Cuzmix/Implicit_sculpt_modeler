package poly

import "core:math"
import "core:math/linalg"
import "core:slice"

// Bevel (ZModeler's Bevel edge, Blender's Bevel, the fillet and chamfer of Shapr3D and
// Plasticity): each edge becomes a strip `segments` faces across, rounded with more than
// one, and the drag sets the strip's width. The new points sit at the old ones and move
// straight out as the width grows, so one Drag_Set carries every width.
//
// Round each point v the edges and faces turn in order. Where two or more bevelled edges
// meet at v, the faces between two of them (a sector) share one new point: inside the
// face, on the lines the width away from both edges (Blender's miter), when the sector is
// one face; sliding along the edges between them otherwise. Where three or more meet, a
// patch polygon closes the corner. Where one bevelled edge ends at v, its strip's two
// sides slide along the edges either side of it, and v stays (with an end face) unless
// only three edges meet there, where the face across takes the strip's end. Rounded
// strips follow circular arcs whose corner is v, so a strip meets the faces either side
// tangent to them. The width is clamped so no point passes the middle of an edge it
// slides along (or most of its length, when its far end does not move) and no mitered
// corner crosses half the face.
//
// Refused: edges on a border or meeting a border point (Unsupported), as are points
// where only two edges meet.

// The most segments a bevel takes.
BEVEL_SEGMENTS_MAX :: 12

// With `corners`, each face corner a bevelled point had is put there (by bevel_key of the
// old face and point) with the new points that took its place in that face, in order round
// it, as new ids: the live stack follows the cage's points and edges through them.
bevel_edges :: proc(m: ^Mesh, edges: []u32, segments: int, allocator := context.allocator, corners: ^map[u64][]u32 = nil) -> (r: Edit_Result, d: Drag_Set, err: Build_Error) {
	s := clamp(segments, 1, BEVEL_SEGMENTS_MAX)
	bevelled := make([]bool, len(m.crease), context.temp_allocator)
	list := make([dynamic]u32, context.temp_allocator)
	for e in edges {
		if int(e) >= len(m.crease) || bevelled[e] do continue
		if edge_border(m, e) do return {}, {}, .Unsupported
		bevelled[e] = true
		append(&list, e)
	}
	if len(list) == 0 do return {}, {}, .None
	slice.sort(list[:])
	// The points the bevel reaches, ascending, so ids follow from the cage alone.
	touched := make([dynamic]u32, context.temp_allocator)
	for e in list {
		a, b := edge_verts(m, e)
		append(&touched, a, b)
	}
	slice.sort(touched[:])
	points := slice.unique(touched[:])
	for v in points do if vert_border(m, v) || valence(m, v) < 3 do return {}, {}, .Unsupported

	ed := edit_begin(m, context.temp_allocator)
	b := Bevel_Build {
		m     = m,
		ed    = &ed,
		s     = s,
		sub   = make(map[u64][dynamic]u32, allocator = context.temp_allocator),
		arc   = make(map[u64][]u32, allocator = context.temp_allocator),
		dir   = make(map[u32]Vec3, allocator = context.temp_allocator),
		order = make([dynamic]u32, context.temp_allocator),
		ends  = make([dynamic]Bevel_End, context.temp_allocator),
		hi    = max(f32),
	}
	// First every corner's new points, then every arc between them (an arc needs both of
	// its ends, which may come from the point's other sectors).
	for v in points do bevel_corner(&b, v, bevelled)
	for v in points do bevel_arcs(&b, v, bevelled)

	// The old faces with their corners at bevelled points swapped for the new points.
	for &f in ed.faces {
		if f.from == NONE do continue
		out := make([dynamic]u32, 0, len(f.verts) + 2, context.temp_allocator)
		for v in f.verts {
			if seq, ok := b.sub[bevel_key(f.from, v)]; ok {
				append(&out, ..seq[:])
			} else {
				append(&out, v)
			}
		}
		clear(&f.verts)
		append(&f.verts, ..out[:])
	}

	// Each edge's strip: from its first point's side of the face on half-edge 2e round to
	// the other, `s` quads across, pairing each arc point at one end with its partner at
	// the other.
	for e in list {
		h := 2 * e
		v, x := m.he_vert[h], he_tip(m, h)
		at_v := bevel_profile(&b, v, h)
		at_x := bevel_profile(&b, x, twin(h))
		group := m.group[m.he_face[h]]
		for j in 0 ..< s {
			edit_face(&ed, {at_x[s - j], at_v[j], at_v[j + 1], at_x[s - j - 1]}, group)
		}
	}
	// The corners where three or more bevelled edges meet, and the ends of single ones.
	for end in b.ends do edit_face(&ed, end.verts[:], end.group)

	r = edit_end(m, &ed, allocator) or_return
	d.verts = make([]u32, len(b.order), allocator)
	d.base = make([]Vec3, len(b.order), allocator)
	d.dir = make([]Vec3, len(b.order), allocator)
	for p, i in b.order {
		nv := r.vert[p]
		d.verts[i], d.base[i], d.dir[i] = nv, m.positions[nv], b.dir[p]
	}
	d.lo, d.hi = 0, max(b.hi, 0)
	if corners != nil {
		for key, seq in b.sub {
			ids := make([]u32, len(seq), context.temp_allocator)
			for p, i in seq do ids[i] = r.vert[p]
			corners[key] = ids
		}
	}
	return r, d, .None
}

@(private = "file")
Bevel_Build :: struct {
	m:     ^Mesh,
	ed:    ^Edit,
	s:     int,
	// Per face corner (bevel_key of the face and the old point), what replaces the point.
	sub:   map[u64][dynamic]u32,
	// Per bevelled half-edge leaving a point, the arc's points between the strip's two sides
	// there (s - 1 of them), from the side of the half-edge's face to the other.
	arc:   map[u64][]u32,
	// Per new point (edit id), its way out per unit of width, in the order made.
	dir:   map[u32]Vec3,
	order: [dynamic]u32,
	ends:  [dynamic]Bevel_End,
	hi:    f32, // the widest the bevel may go
}

@(private = "file")
Bevel_End :: struct {
	verts: [dynamic]u32,
	group: u16,
}

@(private)
bevel_key :: #force_inline proc "contextless" (a, b: u32) -> u64 {return u64(a) << 32 | u64(b)}

// A new point at old point v moving `dir` per unit of width.
@(private = "file")
bevel_point :: proc(b: ^Bevel_Build, v: u32, dir: Vec3) -> u32 {
	p := edit_vertex(b.ed, b.m.positions[v])
	b.dir[p] = dir
	append(&b.order, p)
	return p
}

// The half-edges leaving v in turn: the face on half-edge i lies between half-edges i - 1
// and i.
@(private = "file")
bevel_ring :: proc(m: ^Mesh, v: u32) -> []u32 {
	out := make([dynamic]u32, context.temp_allocator)
	w := vertex_walk(m, v)
	for h in vertex_walk_next(&w) do append(&out, h)
	return out[:]
}

// The unit way along half-edge h and its length.
@(private = "file")
bevel_along :: proc(m: ^Mesh, h: u32) -> (way: Vec3, length: f32) {
	d := m.positions[he_tip(m, h)] - m.positions[m.he_vert[h]]
	length = linalg.length(d)
	return d / max(length, 1e-20), length
}

// How far a point sliding along half-edge h may go: to the edge's middle when its far end
// moves too, else most of the way.
@(private = "file")
bevel_room :: proc(m: ^Mesh, h: u32, bevelled: []bool) -> f32 {
	_, length := bevel_along(m, h)
	x := he_tip(m, h)
	w := vertex_walk(m, x)
	for o in vertex_walk_next(&w) do if bevelled[edge_of(o)] do return 0.5 * length
	return 0.9 * length
}

// A point sliding along half-edge h, a width away from bevelled edge way `from` (unit):
// its way and the widest it allows.
@(private = "file")
bevel_slide :: proc(b: ^Bevel_Build, h: u32, from: Vec3, bevelled: []bool) -> Vec3 {
	way, _ := bevel_along(b.m, h)
	dir := way / max(linalg.length(linalg.cross(way, from)), 0.25)
	b.hi = min(b.hi, bevel_room(b.m, h, bevelled) / linalg.length(dir))
	return dir
}

// The new points at point v and which face corners take them.
@(private = "file")
bevel_corner :: proc(b: ^Bevel_Build, v: u32, bevelled: []bool) {
	m := b.m
	ring := bevel_ring(m, v)
	n := len(ring)
	at := make([dynamic]int, context.temp_allocator)
	for h, i in ring do if bevelled[edge_of(h)] do append(&at, i)
	k := len(at)
	put :: proc(b: ^Bevel_Build, f, v: u32, seq: ..u32) {
		list := make([dynamic]u32, context.temp_allocator)
		append(&list, ..seq)
		b.sub[bevel_key(f, v)] = list
	}
	if k == 1 {
		// One bevelled edge ends here: its sides slide along the edges either side of it.
		i := at[0]
		hb := ring[i]
		way, _ := bevel_along(m, hb)
		before, after := ring[(i - 1 + n) % n], ring[(i + 1) % n]
		a := bevel_point(b, v, bevel_slide(b, before, way, bevelled))
		c := bevel_point(b, v, bevel_slide(b, after, way, bevelled))
		f_b, f_after := m.he_face[hb], m.he_face[after]
		put(b, f_b, v, a)
		put(b, f_after, v, c)
		if n == 3 {
			// The face across takes the strip's end: c, the arc back, a. Its arc is filled
			// in with the rest (bevel_arcs), since it needs both ends.
			put(b, m.he_face[ring[(i + 2) % n]], v, c, a)
		} else {
			// v stays; the faces beside the two slid edges take their points next to it,
			// and an end face closes the gap: c, the arc back, a, v.
			put(b, m.he_face[ring[(i + 2) % n]], v, c, v)
			put(b, m.he_face[before], v, v, a)
		}
		return
	}
	// Two or more: each run of faces between two bevelled edges shares one point.
	for j in 0 ..< k {
		first, last := at[j], at[(j + 1) % k]
		span := (last - first + n) % n
		h_first, h_last := ring[first], ring[last]
		d_first, _ := bevel_along(m, h_first)
		d_last, l_last := bevel_along(m, h_last)
		dir: Vec3
		if span == 1 {
			// One face: on the lines a width inside both edges, along the bisector of their
			// insides (inside a face that runs counter-clockwise about n is to the left).
			f := m.he_face[h_last]
			nrm := face_normal(m, f)
			left_out := linalg.normalize0(linalg.cross(nrm, d_last))
			left_in := linalg.normalize0(linalg.cross(d_first, nrm))
			bisector := linalg.normalize0(left_out + left_in)
			if linalg.length2(bisector) < 1e-12 do bisector = left_out
			dir = bisector / max(linalg.dot(bisector, left_out), 0.25)
			_, l_first := bevel_along(m, h_first)
			b.hi = min(b.hi, 0.49 * min(l_first, l_last))
		} else {
			// Several faces: along the mean of the edges between, a width from both.
			mean: Vec3
			for o in 1 ..< span {
				w, _ := bevel_along(m, ring[(first + o) % n])
				mean += w
			}
			mean = linalg.normalize0(mean)
			off := 0.5 * (linalg.length(linalg.cross(mean, d_first)) + linalg.length(linalg.cross(mean, d_last)))
			dir = mean / max(off, 0.25)
			for o in 1 ..< span do b.hi = min(b.hi, bevel_room(m, ring[(first + o) % n], bevelled) / linalg.length(dir))
		}
		p := bevel_point(b, v, dir)
		for o in 1 ..= span do put(b, m.he_face[ring[(first + o) % n]], v, p)
	}
}

// Point v's arcs and its corner patch or end face, once every point there is made.
@(private = "file")
bevel_arcs :: proc(b: ^Bevel_Build, v: u32, bevelled: []bool) {
	m := b.m
	ring := bevel_ring(m, v)
	n := len(ring)
	at := make([dynamic]int, context.temp_allocator)
	for h, i in ring do if bevelled[edge_of(h)] do append(&at, i)
	k := len(at)
	for i in at {
		h := ring[i]
		key := bevel_key(h, v)
		if _, done := b.arc[key]; done do continue
		a := bevel_side(b, m.he_face[h], v, last = true)
		c := bevel_side(b, m.he_face[twin(h)], v, last = false)
		// Where two bevelled edges meet, both strips run between the same two points: they
		// share one arc, each walking it its own way.
		if k == 2 {
			other := ring[at[0] if at[1] == i else at[1]]
			if arc, ok := b.arc[bevel_key(other, v)]; ok {
				back := make([]u32, len(arc), context.temp_allocator)
				for x, j in arc do back[len(arc) - 1 - j] = x
				b.arc[key] = back
				continue
			}
		}
		b.arc[key] = bevel_arc(b, v, a, c)
	}
	if k == 1 {
		i := at[0]
		h := ring[i]
		a := bevel_side(b, m.he_face[h], v, last = true)
		c := bevel_side(b, m.he_face[twin(h)], v, last = false)
		arc := b.arc[bevel_key(h, v)]
		if n == 3 {
			// The face across: c, the arc from c back to a, then a.
			key := bevel_key(m.he_face[ring[(i + 2) % n]], v)
			seq := b.sub[key]
			clear(&seq)
			append(&seq, c)
			#reverse for x in arc do append(&seq, x)
			append(&seq, a)
			b.sub[key] = seq
		} else {
			end := Bevel_End{verts = make([dynamic]u32, context.temp_allocator), group = m.group[m.he_face[h]]}
			append(&end.verts, c)
			#reverse for x in arc do append(&end.verts, x)
			append(&end.verts, a, v)
			append(&b.ends, end)
		}
		return
	}
	if k < 3 do return
	// The patch: round the corner against the strips, each strip's far side then its arc
	// backward, from the last bevelled edge down to the first.
	patch := Bevel_End{verts = make([dynamic]u32, context.temp_allocator), group = m.group[m.he_face[ring[at[0]]]]}
	#reverse for i in at {
		h := ring[i]
		append(&patch.verts, bevel_side(b, m.he_face[twin(h)], v, last = false))
		#reverse for x in b.arc[bevel_key(h, v)] do append(&patch.verts, x)
	}
	append(&b.ends, patch)
}

// The strip's side at v in face f: the last new point the face takes there (the face
// leaves v along the strip's edge) or the first (it reaches v along it).
@(private = "file")
bevel_side :: proc(b: ^Bevel_Build, f, v: u32, last: bool) -> u32 {
	seq := b.sub[bevel_key(f, v)]
	return seq[len(seq) - 1] if last else seq[0]
}

// The s - 1 points of a circular arc from a to c whose corner is v: a rational quadratic
// curve, a weight of sin(half the angle at v) making it a true arc when a and c are as
// far from v. Each point is a fixed blend of a's and c's ways, so it moves with the width.
@(private = "file")
bevel_arc :: proc(b: ^Bevel_Build, v, a, c: u32) -> []u32 {
	out := make([]u32, b.s - 1, context.temp_allocator)
	da, dc := b.dir[a], b.dir[c]
	angle := math.acos(clamp(linalg.dot(linalg.normalize0(da), linalg.normalize0(dc)), -1, 1))
	weight := clamp(math.sin(angle / 2), 0.2, 1)
	for j in 1 ..< b.s {
		t := f32(j) / f32(b.s)
		wa, wv, wc := (1 - t) * (1 - t), 2 * t * (1 - t) * weight, t * t
		out[j - 1] = bevel_point(b, v, (da * wa + dc * wc) / (wa + wv + wc))
	}
	return out
}

// The points across the strip at v, from its side in half-edge h's face to the other.
@(private = "file")
bevel_profile :: proc(b: ^Bevel_Build, v, h: u32) -> []u32 {
	m := b.m
	out := make([]u32, b.s + 1, context.temp_allocator)
	out[0] = bevel_side(b, m.he_face[h], v, last = true)
	copy(out[1:], b.arc[bevel_key(h, v)])
	out[b.s] = bevel_side(b, m.he_face[twin(h)], v, last = false)
	return out
}
