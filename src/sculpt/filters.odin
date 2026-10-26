package sculpt

import "base:runtime"
import "core:math/linalg"
import "core:slice"

import "../jobs"

// Two stroke options that narrow what a dab works on, as Nomad's and ZBrush's do.
//
// Lock plane (Brush.lock_plane): the area normal and plane centre the stroke's first dab
// finds are kept for the rest of the stroke, as ZBrush's Original plane and Nomad's lock,
// so a long Flatten or Clay stroke over changing ground does not drift with it. It is
// locked before Clay's offset and a leaning pen's turn, which still apply on top, and a
// mirror image takes the locked plane mirrored.
//
// Connected (Brush.connected), as ZBrush's topological auto masking: a dab works only on
// what joins the place it presses through the shown surface without leaving the brush,
// so a finger pressed against another, or the far side of a thin fold, stays untouched
// however near it is in space. Which vertices are reached is found on worker threads, a
// hit leaf each: each leaf marks the vertices it owns inside the reach, then joins them
// into pieces along its shown triangles' edges inside the reach and notes the edges that
// end at another leaf's vertex; those few joins are made one after another, and the
// piece holding the corner nearest the centre of the triangle the centre lies on is what
// the dab works on. The set found is the part of the surface inside the reach joined to
// that corner, which does not depend on the order anything ran in, so serial and
// parallel dabs agree.

// The plane a stroke locked, in the mesh's space as the stroke's own (unmirrored) dabs
// see it.
Locked_Plane :: struct {
	set:    bool,
	normal: Vec3,
	plane:  Vec3,
}

// What Connected keeps between dabs. Per vertex, `mark` is the dab's stamp for one
// inside its reach and the stamp + 1 for one reached, so nothing has to be cleared
// between dabs; `label` chains a vertex inside the reach to its piece's root. And a
// scratch per hit leaf, kept to be reused.
@(private)
Connected_State :: struct {
	mark:   [dynamic]u32,
	label:  [dynamic]u32,
	stamp:  u32, // even: the in-reach stamp; the reached one is stamp + 1
	root:   u32, // the piece the dab works on
	leaves: [dynamic]Connected_Leaf,
}

// One hit leaf's part of the flood, on the heap since jobs grow it.
@(private)
Connected_Leaf :: struct {
	links:      [dynamic][2]u32, // edges inside the reach to a vertex another leaf owns
	nearest:    u32, // its vertex nearest the centre, for a dab no triangle is found under
	nearest_d2: f32,
	under:      u32, // its shown triangle nearest the centre, near enough to be the one it lies on
	under_d2:   f32,
}

@(private)
connected_free :: proc(s: ^Sculptor) {
	c := &s.connected
	delete(c.mark)
	delete(c.label)
	for &l in c.leaves {
		delete(l.links)
	}
	delete(c.leaves)
	c^ = {}
}

// Whether a dab of `kind` works along the plane Lock plane keeps: the kinds that use the
// area normal for their direction or plane. Any kind with an alpha lays the image on it.
brush_locks_plane :: #force_inline proc(kind: Brush_Kind, alpha: bool) -> bool {
	#partial switch kind {
	case .Draw, .Clay, .Flatten, .Pinch, .Crease: return true
	}
	return alpha
}

// The plane the stroke under way locked, for a stroke joining it to keep.
sculptor_locked_plane :: proc(s: ^Sculptor) -> Locked_Plane {return s.locked}

// Makes `l` the stroke's locked plane: a stroke joining another (begun with
// sculptor_stroke_begin, which unlocks) carries on its plane.
sculptor_lock_plane :: proc(s: ^Sculptor, l: Locked_Plane) {s.locked = l}

// Puts the locked plane in place of the dab's own area, mirrored by `mirror` (the
// dab's symmetry image), once the stroke has one; the stroke's first own dab with
// anything under it locks it.
@(private)
lock_plane_apply :: proc(s: ^Sculptor, d: ^Dab, mirror: Vec3, weight: f32) {
	l := &s.locked
	if l.set {
		d.normal, d.plane = l.normal * mirror, l.plane * mirror
	} else if mirror == {1, 1, 1} && weight > 0 && d.normal != {} {
		l^ = {true, d.normal, d.plane}
	}
}

// Finds what of the surface inside the dab's reach joins the place it presses
// (connected_weight), on `pool`'s threads when given.
@(private)
connected_flood :: proc(s: ^Sculptor, d: ^Dab, pool: ^jobs.Pool) {
	c := &s.connected
	n := len(s.mesh.positions)
	if len(c.mark) < n {
		resize(&c.mark, n)
		resize(&c.label, n)
	}
	c.stamp += 2
	if c.stamp < 2 {
		// Wrapped: marks from long ago would look current.
		slice.zero(c.mark[:])
		c.stamp = 2
	}
	for len(c.leaves) < len(s.hit) {
		append(&c.leaves, Connected_Leaf {
			links = make([dynamic][2]u32, runtime.heap_allocator()),
		})
	}
	d.connected = true
	// Every mark first, so the joins read them all done: a vertex no hit leaf owns (a
	// dynamic topology page left without triangles) is outside, as dabs leave it.
	jobs.parallel_for(pool, len(s.hit), d, job_connected_marks)
	jobs.parallel_for(pool, len(s.hit), d, job_connected_pieces)
	// Where it starts: the corner nearest the centre of the triangle the centre lies on,
	// or with none found (triangles large beside the brush), the vertex nearest it. Ties
	// go to the lower number, so the start does not depend on the leaves' order.
	tri, tri_d2 := max(u32), max(f32)
	nearest, nearest_d2 := max(u32), d.r2
	for l in c.leaves[:len(s.hit)] {
		if l.under != max(u32) && (l.under_d2 < tri_d2 || (l.under_d2 == tri_d2 && l.under < tri)) do tri, tri_d2 = l.under, l.under_d2
		if l.nearest != max(u32) && (l.nearest_d2 < nearest_d2 || (l.nearest_d2 == nearest_d2 && l.nearest < nearest)) do nearest, nearest_d2 = l.nearest, l.nearest_d2
	}
	start := nearest
	if tri != max(u32) {
		m := s.mesh
		best := max(f32)
		for corner in 0 ..< u32(3) {
			v := m.indices[3 * tri + corner]
			delta := m.positions[v] - d.center
			d2 := linalg.dot(delta, delta)
			if d2 < best || (d2 == best && v < start) do start, best = v, d2
		}
	}
	if start == max(u32) {
		// Nothing inside the reach: no vertex carries the reached stamp.
		c.root = max(u32)
		return
	}
	// Join the pieces the crossing edges join, the lower root under the other: first each
	// leaf's edges become the pairs of pieces they join, most leaves' few.
	jobs.parallel_for(pool, len(s.hit), d, job_connected_links)
	label := c.label[:]
	for l in c.leaves[:len(s.hit)] {
		for e in l.links {
			a, b := connected_root(label, e[0]), connected_root(label, e[1])
			if a < b do label[b] = a
			else if b < a do label[a] = b
		}
	}
	c.root = connected_root(label, start)
	jobs.parallel_for(pool, len(s.hit), d, job_connected_mark)
}

// The root of v's piece: its label's chain followed to a vertex labelled itself.
@(private = "file")
connected_root :: #force_inline proc(label: []u32, v: u32) -> u32 {
	r := label[v]
	for label[r] != r do r = label[r]
	return r
}

// One hit leaf: marks the vertices it owns inside the reach, each its own piece, and
// finds the one nearest the centre.
@(private = "file")
job_connected_marks :: proc(data: rawptr, i: int) {
	d := cast(^Dab)data
	s := d.s
	c := &s.connected
	m := s.mesh
	l := &c.leaves[i]
	l.nearest, l.nearest_d2 = max(u32), d.r2
	first, last := owned(s, s.hit[i])
	for v in first ..< last {
		delta := m.positions[v] - d.center
		d2 := linalg.dot(delta, delta)
		if d2 >= d.r2 do continue
		c.mark[v], c.label[v] = c.stamp, v
		if d2 < l.nearest_d2 do l.nearest, l.nearest_d2 = v, d2
	}
}

// One hit leaf: joins the vertices it owns inside the reach into the pieces its own shown
// triangles' edges inside the reach make, and notes those edges that end at a vertex
// another leaf owns, to join after; and finds its triangle the centre lies on, if any.
// Its triangles are read in order, so this costs little more than a pass over them.
@(private = "file")
job_connected_pieces :: proc(data: rawptr, i: int) {
	d := cast(^Dab)data
	s := d.s
	c := &s.connected
	m := s.mesh
	l := &c.leaves[i]
	clear(&l.links)
	l.under, l.under_d2 = max(u32), max(f32)
	first, last := owned(s, s.hit[i])
	// Joins the pieces of a and b, both inside: here when the leaf owns both, otherwise
	// after every leaf is done.
	join :: #force_inline proc(c: ^Connected_State, l: ^Connected_Leaf, first, last, a, b: u32) {
		if a < first || a >= last || b < first || b >= last {
			append(&l.links, [2]u32{a, b})
			return
		}
		ra, rb := connected_local_root(c.label[:], a), connected_local_root(c.label[:], b)
		if ra < rb do c.label[rb] = ra
		else if rb < ra do c.label[ra] = rb
	}
	// Only triangles with a corner this near the centre may be the one it lies on: a
	// sixteenth of the reach squared, a quarter of its radius.
	near2 := d.r2 / 16
	hidden := sculptor_hidden_tris(s)
	nd := s.nodes[s.node_of[s.hit[i]]]
	for f in nd.tri_first ..< nd.tri_first + nd.tri_count {
		if hidden != nil && hidden[f] do continue
		a, b, e := m.indices[3 * f], m.indices[3 * f + 1], m.indices[3 * f + 2]
		ia, ib, ie := c.mark[a] == c.stamp, c.mark[b] == c.stamp, c.mark[e] == c.stamp
		if ia && ib do join(c, l, first, last, a, b)
		if ib && ie do join(c, l, first, last, b, e)
		// With all three inside, the two joins above have joined them already.
		if ia && ie && !ib do join(c, l, first, last, a, e)
		if !(ia && ib && ie) do continue
		pa, pb, pe := m.positions[a], m.positions[b], m.positions[e]
		da, db, de := pa - d.center, pb - d.center, pe - d.center
		if min(linalg.dot(da, da), linalg.dot(db, db), linalg.dot(de, de)) >= near2 do continue
		q := triangle_closest(d.center, pa, pb, pe) - d.center
		if d2 := linalg.dot(q, q); d2 < l.under_d2 do l.under, l.under_d2 = f, d2
	}
}

// The point of triangle abc nearest p (Ericson, Real-Time Collision Detection, 5.1.5).
@(private)
triangle_closest :: proc(p, a, b, c: Vec3) -> Vec3 {
	ab, ac, ap := b - a, c - a, p - a
	d1, d2 := linalg.dot(ab, ap), linalg.dot(ac, ap)
	if d1 <= 0 && d2 <= 0 do return a
	bp := p - b
	d3, d4 := linalg.dot(ab, bp), linalg.dot(ac, bp)
	if d3 >= 0 && d4 <= d3 do return b
	vc := d1 * d4 - d3 * d2
	if vc <= 0 && d1 >= 0 && d3 <= 0 do return a + ab * (d1 / (d1 - d3))
	cp := p - c
	d5, d6 := linalg.dot(ab, cp), linalg.dot(ac, cp)
	if d6 >= 0 && d5 <= d6 do return c
	vb := d5 * d2 - d1 * d6
	if vb <= 0 && d2 >= 0 && d6 <= 0 do return a + ac * (d2 / (d2 - d6))
	va := d3 * d6 - d5 * d4
	if va <= 0 && d4 - d3 >= 0 && d5 - d6 >= 0 do return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
	denom := 1 / (va + vb + vc)
	return a + ab * (vb * denom) + ac * (vc * denom)
}

// The root of v's piece among the vertices one leaf owns, halving the chain on the way;
// only that leaf's job calls it, so the labels it writes are its own.
@(private = "file")
connected_local_root :: #force_inline proc(label: []u32, v: u32) -> u32 {
	x := v
	for label[x] != x {
		label[x] = label[label[x]]
		x = label[x]
	}
	return x
}

// One hit leaf: turns its crossing edges into the pairs of pieces they join, leaving out
// a pair the same as the one kept before it: the edges come triangle by triangle, so
// runs of them join the same two pieces, and the joins made one after another are few.
// (Sorting them to keep each pair once costs more than the joins it saves.)
@(private = "file")
job_connected_links :: proc(data: rawptr, i: int) {
	d := cast(^Dab)data
	c := &d.s.connected
	l := &c.leaves[i]
	label := c.label[:]
	kept := 0
	for e in l.links {
		a, b := connected_root(label, e[0]), connected_root(label, e[1])
		pair := [2]u32{min(a, b), max(a, b)}
		if a == b || (kept > 0 && l.links[kept - 1] == pair) do continue
		l.links[kept] = pair
		kept += 1
	}
	resize(&l.links, kept)
}

// One hit leaf: gives its vertices in the dab's piece the reached stamp.
@(private = "file")
job_connected_mark :: proc(data: rawptr, i: int) {
	d := cast(^Dab)data
	c := &d.s.connected
	first, last := owned(d.s, d.s.hit[i])
	label := c.label[:]
	for v in first ..< last {
		if c.mark[v] == c.stamp && connected_root(label, v) == c.root do c.mark[v] = c.stamp + 1
	}
}

// 1 for a vertex the dab may work on with Connected, 0 for one it did not reach; always
// 1 without it.
@(private)
connected_weight :: #force_inline proc(d: ^Dab, v: u32) -> f32 {
	if !d.connected do return 1
	return 1 if d.s.connected.mark[v] == d.s.connected.stamp + 1 else 0
}
