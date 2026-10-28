package sculpt

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:sync"

import "../geom"
import "../jobs"

// Catmull-Clark levels, for an object made from a Model mode cage: the base level is the
// cage cut into triangles, keeping its polygons, and each level above is one Catmull-Clark
// step of the one below with semi-sharp creases, so stepping up the levels shows what the
// cage's Smooth showed. Every level above the base is quads, each cut on the fixed
// diagonal from its corner to its face point, so its triangles follow from the topology
// alone. The rules are poly's (src/poly/subdivide.odin), point for point: a vertex keeps
// its place's id as the vertex point, then one point per edge and one per polygon.
//
// A Catmull-Clark point's parents keep Loop's [4]u32 so the carries that read p[0] and
// p[1] (masks, colours, selection sets) work unchanged: a vertex point is {v, a neighbour
// of v, EVEN, 0}; an edge point {a, b, f1, f2}, f1 the polygon where a runs to b and f2
// the other; a face point {c0, c2, FACE, f}, two of its polygon's corners and the polygon.

// How the levels above the base are made.
Subdivision_Rule :: enum u8 {
	Loop, // Loop subdivision of the triangles, as every sculpt has
	Smooth, // Catmull-Clark of the base's polygons, with creases
	Flat, // the same split with every new point in the middle of its edge or polygon
}

// parents[2] of a face point.
@(private)
FACE :: max(u32) - 1

// A level's polygons: polygon p's corners are corners[first[p]:first[p + 1]], counter-
// clockwise seen from outside, and tri_poly gives each triangle's polygon.
Polys :: struct {
	first:    []u32,
	corners:  []u32,
	tri_poly: []u32,
}

// A level's creased edges and corners: edges[i] (the key lo << 32 | hi of its ends) has
// sharpness edge[i], verts[i] has corner sharpness vert[i], both sorted by key. Sharpness
// runs from 0 up to INFINITE_SHARP and drops by one a step, as poly's does.
Sharp :: struct {
	edges: []u64,
	edge:  []f32,
	verts: []u32,
	vert:  []f32,
}

// Sharpness that never rounds off, as poly.INFINITE_SHARP.
INFINITE_SHARP :: f32(10)

polys_destroy :: proc(p: ^Polys, allocator := context.allocator) {
	delete(p.first, allocator)
	delete(p.corners, allocator)
	delete(p.tri_poly, allocator)
	p^ = {}
}

sharp_destroy :: proc(s: ^Sharp, allocator := context.allocator) {
	delete(s.edges, allocator)
	delete(s.edge, allocator)
	delete(s.verts, allocator)
	delete(s.vert, allocator)
	s^ = {}
}

// The key of the edge between a and b, either way round.
sharp_key :: #force_inline proc "contextless" (a, b: u32) -> u64 {return u64(min(a, b)) << 32 | u64(max(a, b))}

// How sharp the edge a-b is, 0 when it is not creased.
@(private)
sharp_edge :: proc(s: ^Sharp, a, b: u32) -> f32 {
	if len(s.edges) == 0 do return 0
	i, found := slice.binary_search(s.edges, sharp_key(a, b))
	return s.edge[i] if found else 0
}

// How sharp vertex v is as a corner, 0 when it is not one.
@(private)
sharp_vert :: proc(s: ^Sharp, v: u32) -> f32 {
	if len(s.verts) == 0 do return 0
	i, found := slice.binary_search(s.verts, v)
	return s.vert[i] if found else 0
}

// Gives a single-level object its polygons, creases and the rule its levels above follow,
// taking all three (in the base level's own numbering, sorted Sharp keys). Returns false,
// freeing them, when the object has levels above its base or they do not fit its mesh.
levels_set_polys :: proc(l: ^Levels, polys: Polys, sharp: Sharp, rule: Subdivision_Rule) -> bool {
	p, s := polys, sharp
	base := l.levels[0]
	vcount := u32(len(base.mesh.positions))
	fits := len(l.levels) == 1 && rule != .Loop && len(p.first) >= 2 && p.first[0] == 0 && int(p.first[len(p.first) - 1]) == len(p.corners)
	fits &&= len(p.tri_poly) == len(base.mesh.indices) / 3
	fits &&= len(s.edges) == len(s.edge) && len(s.verts) == len(s.vert)
	if fits {
		for i in 0 ..< len(p.first) - 1 do fits &&= p.first[i + 1] - p.first[i] >= 3
		for c in p.corners do fits &&= c < vcount
		for t in p.tri_poly do fits &&= int(t) < len(p.first) - 1
		fits &&= slice.is_sorted(s.edges) && slice.is_sorted(s.verts)
	}
	// Each triangle's corners are its polygon's.
	if fits {
		for f, t in p.tri_poly {
			corners := p.corners[p.first[f]:p.first[f + 1]]
			for k in 0 ..< 3 do fits &&= slice.contains(corners, base.mesh.indices[3 * t + k])
		}
	}
	if !fits {
		polys_destroy(&p, l.allocator)
		sharp_destroy(&s, l.allocator)
		return false
	}
	polys_destroy(&base.polys, l.allocator)
	sharp_destroy(&base.sharp, l.allocator)
	base.polys, base.sharp = p, s
	l.rule = rule
	return true
}

// The corners of polygon f.
@(private)
poly_corners :: #force_inline proc(p: ^Polys, f: u32) -> []u32 {
	return p.corners[p.first[f]:p.first[f + 1]]
}

// The middle of polygon f, summed in its corners' order as poly.face_center does.
@(private)
poly_center :: proc(below: ^Loop_Base, f: u32) -> Vec3 {
	c: Vec3
	corners := poly_corners(below.polys, f)
	for v in corners do c += below.positions[v]
	return c / f32(len(corners))
}

// Where Catmull-Clark puts a point given its parents on the level below, and a frame
// there, as frame_at does for Loop. A vertex's polygons are its triangles' polygons, each
// taken at its lowest-numbered triangle there, in the order of the vertex's triangles.
// Never inlined, for the same reason as frame_at.
@(private)
frame_cc :: #force_no_inline proc(below: ^Loop_Base, par: [4]u32) -> Frame {
	P := below.positions
	flat := below.rule == .Flat
	origin, normal, tangent: Vec3
	switch par[2] {
	case EVEN:
		v := par[0]
		p := P[v]
		tris := geom.vertex_faces_of(below.faces, v)
		n := 0
		q, r: Vec3
		sharp_ends: [2]Vec3
		sharp_count := 0
		sharpness: f32
		for t, i in tris {
			f := below.tri_poly[t]
			first := true
			for u in tris[:i] do if below.tri_poly[u] == f do first = false
			if !first do continue
			// The polygon's corners either side of v: the edge to the next is v's own in
			// this polygon, met once round a closed mesh, and the one to the previous is
			// the next's of the polygon beside.
			corners := poly_corners(below.polys, f)
			k, _ := slice.linear_search(corners, v)
			next := corners[(k + 1) % len(corners)]
			prev := corners[(k + len(corners) - 1) % len(corners)]
			n += 1
			// The normal from the polygons' corners either side, not from the triangles,
			// so it does not hang on how the polygons were cut.
			normal += linalg.cross(P[next] - p, P[prev] - p)
			q += poly_center(below, f)
			r += (p + P[next]) * 0.5
			r += (p + P[prev]) * 0.5
			if s := sharp_edge(below.sharp, v, next); s > 0 {
				if sharp_count < 2 do sharp_ends[sharp_count] = P[next]
				sharp_count += 1
				sharpness += min(s, 1)
			}
		}
		tangent = P[par[1]] - p
		origin = p
		if flat || n == 0 do break
		// Each edge was counted from both polygons beside it.
		r *= 0.5
		fn := f32(n)
		smooth := (q / fn + 2 * r / fn + (fn - 3) * p) / fn
		corner := sharp_vert(below.sharp, v)
		switch {
		case corner > 0:          origin = linalg.lerp(smooth, p, clamp(min(corner, 1), 0, 1))
		case sharp_count >= 3:    origin = linalg.lerp(smooth, p, clamp(sharpness / f32(sharp_count), 0, 1))
		case sharp_count == 2:    origin = linalg.lerp(smooth, (sharp_ends[0] + 6 * p + sharp_ends[1]) / 8, clamp(sharpness / 2, 0, 1))
		case:                     origin = smooth
		}
	case FACE:
		f := par[3]
		origin = poly_center(below, f)
		corners := poly_corners(below.polys, f)
		for v, i in corners {
			a, b := P[v], P[corners[(i + 1) % len(corners)]]
			normal += {(a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y)}
		}
		tangent = P[par[1]] - P[par[0]]
	case:
		a, b := P[par[0]], P[par[1]]
		f1, f2 := poly_center(below, par[2]), poly_center(below, par[3])
		mid := (a + b) * 0.5
		s := sharp_edge(below.sharp, par[0], par[1])
		if flat || s >= 1 {
			origin = mid
		} else {
			origin = linalg.lerp((a + b + f1 + f2) * 0.25, mid, s)
		}
		normal = linalg.cross(b - a, f1 - f2)
		tangent = b - a
	}
	return frame_make(origin, normal, tangent)
}

// A frame at `origin` from an unnormalised normal and a tangent, which is made square to
// the normal; any perpendicular when either has no length.
@(private)
frame_make :: #force_inline proc(origin, normal, tangent: Vec3) -> Frame {
	n := normal
	if len2 := linalg.dot(n, n); len2 > 1e-30 {
		n *= 1 / math.sqrt(len2)
	} else {
		n = {0, 0, 1}
	}
	t := tangent - n * linalg.dot(n, tangent)
	if len2 := linalg.dot(t, t); len2 > 1e-30 {
		t *= 1 / math.sqrt(len2)
	} else {
		t = linalg.normalize(linalg.cross(n, Vec3{1, 0, 0} if abs(n.x) < 0.9 else Vec3{0, 1, 0}))
	}
	return {origin, t, linalg.cross(n, t), n}
}

// One Catmull-Clark step of `below` under the levels' rule: its vertices first, keeping
// their ids, then a point per edge and one per polygon, numbered as poly numbers them, and
// one quad per polygon corner in the polygons' order, each cut on the diagonal from that
// corner to the face point. Every point starts with zero detail. Returns false for a
// mesh with an edge not shared by exactly two polygons running opposite ways along it.
@(private)
level_above_cc :: proc(l: ^Levels, below: ^Level) -> (^Level, bool) {
	p := &below.polys
	vcount, pcount, ccount := len(below.mesh.positions), len(p.first) - 1, len(p.corners)
	b := Cc_Build{below = below, base = level_base(below, l.rule), polys = p, vcount = u32(vcount)}
	b.poly_of = make([]u32, ccount, context.temp_allocator)
	for f in 0 ..< pcount do slice.fill(b.poly_of[p.first[f]:p.first[f + 1]], u32(f))
	b.vert_first = make([]u32, vcount + 1, context.temp_allocator)
	for v in p.corners do b.vert_first[v + 1] += 1
	for v in 0 ..< vcount do b.vert_first[v + 1] += b.vert_first[v]
	b.vert_corner = make([]u32, ccount, context.temp_allocator)
	cursor := slice.clone(b.vert_first[:vcount], context.temp_allocator)
	for v, c in p.corners {
		b.vert_corner[cursor[v]] = u32(c)
		cursor[v] += 1
	}
	b.edge_first = make([]u32, vcount + 1, context.temp_allocator)
	b.corner_edge = make([]u32, ccount, context.temp_allocator)

	// Each corner whose next corner is higher numbered gives an edge at its own vertex, and
	// each side must have exactly one twin running the other way.
	jobs.parallel_ranges(l.pool, vcount, &b, proc(data: rawptr, lo, hi: int) {
		b := cast(^Cc_Build)data
		for v in u32(lo) ..< u32(hi) {
			mine := b.vert_corner[b.vert_first[v]:b.vert_first[v + 1]]
			if len(mine) < 2 do sync.atomic_store(&b.bad, true)
			count: u32
			for c in mine {
				w := cc_next(b, c)
				count += u32(w > v)
				same := 0
				for d in mine do same += int(cc_next(b, d) == w)
				if w == v || same != 1 || cc_twin(b, w, v) == NO_SLOT do sync.atomic_store(&b.bad, true)
			}
			b.edge_first[v + 1] = count
		}
	}, geom.RANGE_GRAIN)
	if sync.atomic_load(&b.bad) do return nil, false
	for v in 0 ..< vcount do b.edge_first[v + 1] += b.edge_first[v]
	b.ecount = b.edge_first[vcount]
	fine_count := vcount + int(b.ecount) + pcount
	b.parents = make([][4]u32, fine_count, context.temp_allocator)
	jobs.parallel_ranges(l.pool, vcount, &b, proc(data: rawptr, lo, hi: int) {
		b := cast(^Cc_Build)data
		for v in u32(lo) ..< u32(hi) {
			mine := b.vert_corner[b.vert_first[v]:b.vert_first[v + 1]]
			b.parents[v] = {v, cc_next(b, mine[0]), EVEN, 0}
			next := b.edge_first[v]
			for c in mine {
				w := cc_next(b, c)
				if w < v do continue
				b.corner_edge[c] = next
				b.parents[b.vcount + next] = {v, w, b.poly_of[c], b.poly_of[cc_twin(b, w, v)]}
				next += 1
			}
		}
	}, geom.RANGE_GRAIN)
	// The sides numbered at the other end.
	jobs.parallel_ranges(l.pool, vcount, &b, proc(data: rawptr, lo, hi: int) {
		b := cast(^Cc_Build)data
		for v in u32(lo) ..< u32(hi) {
			for c in b.vert_corner[b.vert_first[v]:b.vert_first[v + 1]] {
				if w := cc_next(b, c); w < v do b.corner_edge[c] = b.corner_edge[cc_twin(b, w, v)]
			}
		}
	}, geom.RANGE_GRAIN)
	for f in 0 ..< pcount {
		corners := p.corners[p.first[f]:p.first[f + 1]]
		b.parents[vcount + int(b.ecount) + f] = {corners[0], corners[2], FACE, u32(f)}
	}

	lv := new(Level, l.allocator)
	m := &lv.mesh
	m.positions = make([dynamic]Vec3, fine_count, l.allocator)
	m.normals = make([dynamic]Vec3, fine_count, l.allocator)
	m.indices = make([dynamic]u32, 6 * ccount, l.allocator)
	b.mesh = m
	b.quads = make([]u32, 4 * ccount, context.temp_allocator)
	jobs.parallel_ranges(l.pool, fine_count, &b, proc(data: rawptr, lo, hi: int) {
		b := cast(^Cc_Build)data
		for i in lo ..< hi do b.mesh.positions[i] = frame_point(frame_at(&b.base, b.parents[i]), {})
	}, geom.RANGE_GRAIN)
	jobs.parallel_ranges(l.pool, ccount, &b, proc(data: rawptr, lo, hi: int) {
		b := cast(^Cc_Build)data
		for c in u32(lo) ..< u32(hi) {
			f := b.poly_of[c]
			v := b.polys.corners[c]
			e1 := b.vcount + b.corner_edge[c]
			e0 := b.vcount + b.corner_edge[cc_prev_corner(b, c)]
			mid := b.vcount + b.ecount + f
			q := b.quads[4 * c:]
			q[0], q[1], q[2], q[3] = v, e1, mid, e0
			out := b.mesh.indices[6 * c:]
			out[0], out[1], out[2] = v, e1, mid
			out[3], out[4], out[5] = v, mid, e0
		}
	}, geom.RANGE_GRAIN)

	old_to_new := make([]u32, fine_count, context.temp_allocator)
	tri_from := make([]u32, 2 * ccount, context.temp_allocator)
	sculptor_init(&lv.sculptor, m, l.pool, l.node_triangles, old_to_new, tri_from, allocator = l.allocator)
	lv.parents = make([][4]u32, fine_count, l.allocator)
	lv.detail = make([]Vec3, fine_count, l.allocator)
	lv.even_of = make([]u32, vcount, l.allocator)
	b.old_to_new, b.parents_out, b.detail_out = old_to_new, lv.parents, lv.detail
	jobs.parallel_ranges(l.pool, fine_count, &b, proc(data: rawptr, lo, hi: int) {
		b := cast(^Cc_Build)data
		for i in lo ..< hi {
			b.parents_out[b.old_to_new[i]] = b.parents[i]
			b.detail_out[b.old_to_new[i]] = {} // mapped now, as level_above does
		}
	}, geom.RANGE_GRAIN)
	copy(lv.even_of, old_to_new[:vcount])

	// The new level's quads, in their parents' corner order, and their triangles'.
	lv.polys.first = make([]u32, ccount + 1, l.allocator)
	for &x, i in lv.polys.first do x = u32(4 * i)
	lv.polys.corners = make([]u32, 4 * ccount, l.allocator)
	for v, i in b.quads do lv.polys.corners[i] = old_to_new[v]
	lv.polys.tri_poly = make([]u32, 2 * ccount, l.allocator)
	for old, t in tri_from do lv.polys.tri_poly[t] = old / 2
	lv.sharp = cc_sharp_above(&b, &below.sharp, old_to_new, l.allocator)

	lv.node_of_vertex = node_of_vertex_build(&lv.sculptor, l.allocator)
	link_levels(l, below, lv)
	sculptor_recompute_all(&lv.sculptor)
	return lv, true
}

@(private = "file")
Cc_Build :: struct {
	below:       ^Level,
	base:        Loop_Base,
	polys:       ^Polys,
	poly_of:     []u32, // per corner: its polygon
	vert_first:  []u32, // per vertex: where its corners start in vert_corner
	vert_corner: []u32, // corners, by vertex, in corner order
	edge_first:  []u32, // per vertex: its first edge; an edge is numbered at its lower end
	corner_edge: []u32, // per corner: the edge from it to the polygon's next corner
	parents:     [][4]u32,
	vcount:      u32,
	ecount:      u32,
	mesh:        ^geom.Mesh,
	quads:       []u32, // per new quad, its corners as built
	old_to_new:  []u32,
	parents_out: [][4]u32,
	detail_out:  []Vec3,
	bad:         bool, // atomic
}

// The vertex at the corner after corner c in its polygon, and the corner before c.
@(private = "file")
cc_next :: proc(b: ^Cc_Build, c: u32) -> u32 {
	f := b.poly_of[c]
	lo, hi := b.polys.first[f], b.polys.first[f + 1]
	return b.polys.corners[lo + (c - lo + 1) % (hi - lo)]
}
@(private = "file")
cc_prev_corner :: proc(b: ^Cc_Build, c: u32) -> u32 {
	f := b.poly_of[c]
	lo, hi := b.polys.first[f], b.polys.first[f + 1]
	return lo + (c - lo + hi - lo - 1) % (hi - lo)
}
// The corner of w whose next corner is v, or NO_SLOT.
@(private = "file")
cc_twin :: proc(b: ^Cc_Build, w, v: u32) -> u32 {
	for d in b.vert_corner[b.vert_first[w]:b.vert_first[w + 1]] do if cc_next(b, d) == v do return d
	return NO_SLOT
}
// Each crease one step less sharp, on both halves of its edge; corners the same.
@(private = "file")
cc_sharp_above :: proc(b: ^Cc_Build, s: ^Sharp, old_to_new: []u32, allocator: runtime.Allocator) -> (out: Sharp) {
	Edge :: struct {
		key: u64,
		c:   f32,
	}
	edges := make([dynamic]Edge, 0, 2 * len(s.edges), context.temp_allocator)
	for key, i in s.edges {
		c := s.edge[i] if s.edge[i] >= INFINITE_SHARP else max(s.edge[i] - 1, 0)
		if c <= 0 do continue
		x, y := u32(key >> 32), u32(key & 0xffff_ffff)
		side := cc_twin(b, x, y)
		if side == NO_SLOT do side = cc_twin(b, y, x)
		if side == NO_SLOT do continue
		mid := old_to_new[b.vcount + b.corner_edge[side]]
		append(&edges, Edge{sharp_key(old_to_new[x], mid), c}, Edge{sharp_key(mid, old_to_new[y]), c})
	}
	slice.sort_by(edges[:], proc(x, y: Edge) -> bool {return x.key < y.key})
	out.edges, out.edge = make([]u64, len(edges), allocator), make([]f32, len(edges), allocator)
	for e, i in edges do out.edges[i], out.edge[i] = e.key, e.c
	Vert :: struct {
		v: u32,
		c: f32,
	}
	verts := make([dynamic]Vert, 0, len(s.verts), context.temp_allocator)
	for v, i in s.verts {
		c := s.vert[i] if s.vert[i] >= INFINITE_SHARP else max(s.vert[i] - 1, 0)
		if c > 0 do append(&verts, Vert{old_to_new[v], c})
	}
	slice.sort_by(verts[:], proc(x, y: Vert) -> bool {return x.v < y.v})
	out.verts, out.vert = make([]u32, len(verts), allocator), make([]f32, len(verts), allocator)
	for v, i in verts do out.verts[i], out.vert[i] = v.v, v.c
	return
}

// For each triangle of Catmull-Clark level j (above the base), the polygon of the level
// below it was cut from: the one whose face point is its corner. Temporary.
@(private)
cc_tri_polys :: proc(l: ^Levels, j: int) -> []u32 {
	Job :: struct {
		lv:  ^Level,
		out: []u32,
	}
	lv := l.levels[j]
	job := Job{lv, make([]u32, len(lv.mesh.indices) / 3, context.temp_allocator)}
	jobs.parallel_ranges(l.pool, len(job.out), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		for t in lo ..< hi {
			for k in 0 ..< 3 {
				p := job.lv.parents[job.lv.mesh.indices[3 * t + k]]
				if p[2] == FACE do job.out[t] = p[3]
			}
		}
	}, geom.RANGE_GRAIN)
	return job.out
}

// Gives the levels above `dst`'s base the detail of `src`'s, as ZBrush's Freeze
// Subdivision Levels keeps a sculpt while its base is edited: both are built by the same
// rule from the same polygons (dst's base vertex v is src's base_map[v]; the points may
// differ), so their levels match vertex for vertex by an order only the topology
// decides (level_canon), and each level of `dst` is then decoded from its new base with
// `src`'s detail, so the sculpt rides on the edited base. Masks, paint, groups and layers
// do not come across. Returns false, changing nothing, when the levels do not match.
levels_take_detail :: proc(dst, src: ^Levels, base_map: []u32) -> bool {
	n := len(dst.levels)
	if n != len(src.levels) || dst.rule != src.rule || dst.hd.window != nil || src.hd.window != nil do return false
	if len(base_map) != len(dst.levels[0].mesh.positions) || len(base_map) != len(src.levels[0].mesh.positions) do return false
	for j in 1 ..< n do if len(dst.levels[j].mesh.positions) != len(src.levels[j].mesh.positions) do return false
	levels_sync(src)
	levels_sync(dst)
	// src's base placed as dst's: its vertex base_map[v] at place v.
	below_src := make([]u32, len(base_map), context.temp_allocator)
	seen := make([]bool, len(base_map), context.temp_allocator)
	for s, v in base_map {
		if int(s) >= len(base_map) || seen[s] do return false
		seen[s] = true
		below_src[s] = u32(v)
	}
	below_dst: []u32
	for j in 1 ..< n {
		cd := level_canon(dst, j, below_dst, dst.pool, allocator = context.temp_allocator)
		cs := level_canon(src, j, below_src, src.pool, allocator = context.temp_allocator)
		at := make([]u32, len(cs), context.temp_allocator)
		for place, u in cs do at[place] = u32(u)
		// A point's frame turns with how its parents are numbered: an edge point's
		// tangent runs from its lower-numbered end, so where the two levels number an
		// edge's ends the other way round its detail turns half a turn about the normal.
		lv, from := dst.levels[j], src.levels[j]
		for spot, u in cd {
			v := at[spot]
			d := from.detail[v]
			pd, ps := lv.parents[u], from.parents[v]
			if pd[2] != EVEN && pd[2] != FACE && placed(below_dst, pd[0]) != placed(below_src, ps[0]) do d.xy = -d.xy
			lv.detail[u] = d
		}
		all := make([]u32, len(lv.sculptor.nodes), context.temp_allocator)
		for &id, i in all do id = u32(i)
		recode_level(dst, j, all, encode = false)
		sculptor_nodes_moved(&lv.sculptor, all)
		_ = sculptor_flush(&lv.sculptor)
		sculptor_clear_edited(&lv.sculptor)
		below_dst, below_src = cd, cs
	}
	return true

	placed :: #force_inline proc(below: []u32, v: u32) -> u32 {return below[v] if below != nil else v}
}
