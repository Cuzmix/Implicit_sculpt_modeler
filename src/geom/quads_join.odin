package geom

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:slice"

import "../jobs"

// Formats that hold only triangles (STL, glTF) lose the quads a model was made of: an
// exporter cuts each quad along a diagonal. mesh_join_quads finds those pairs again, as
// Blender's Triangles to Quadrilaterals does, and keeps them only when the mesh plainly
// was quads, so a scan or a mesh made of triangles stays as it is.

// A pair is a quad candidate only when its two triangles turn by at most this many
// degrees across the shared edge, the four corners are convex, and none of them is
// further than QUAD_CORNER_LIMIT degrees from square.
QUAD_FOLD_LIMIT :: 40
QUAD_CORNER_LIMIT :: 60

// For the pairs to be kept, this share of the triangles must pair up, and the pairs'
// corners must lie within this many degrees of square on average. A mesh of near-equal
// triangles (an icosphere, dynamic topology, a scan) pairs up as well as quads do, as a
// lattice of triangles is a lattice of rhombi cut in two, but its rhombi have corners of
// about 60 and 120 degrees: 23 to 27 on average for icospheres, geodesic spheres and
// remeshed surfaces, against 2 to 14 for quad models (a torus, Nomad and Blender heads).
QUAD_PAIRED_SHARE :: 0.9
QUAD_CORNER_MEAN :: 18

// The share of the triangles that must lie next to a neighbour they could make a quad with
// for the file's order to count (quad_join_runs).
QUAD_IN_ORDER_SHARE :: 0.5

// What mesh_join_quads found.
Quads_Joined :: struct {
	pairs:  int, // triangle pairs it found
	corner: f64, // the pairs' mean corner distance from square, in degrees
	kept:   bool, // whether it kept them (and set `polys`)
}

// Joins `m`'s triangles in pairs back into the quads they were cut from, when the pairs
// say the mesh was quads (QUAD_PAIRED_SHARE, QUAD_CORNER_MEAN): it then reorders the
// triangles so each pair lies together, with their polygroups (`groups`, one a triangle)
// and texture coordinates (`uvs`, one a corner) alike, and numbers them in `polys` (one a
// triangle, a pair sharing a number), as mesh_polygons reads them. Two triangles pair only
// within one polygroup and where their texture coordinates meet along the shared edge (a
// quad has no seam across its diagonal). Exporters write a quad's two triangles one after
// the other, so triangles next to each other in the file pair first (quad_join_runs);
// each one left then pairs with the best-shaped neighbour that also picks it, a few
// rounds, ties to the lower number, so the result never depends on the pool. Does nothing when `polys` already holds the file's polygons.
mesh_join_quads :: proc(m: ^Mesh, groups: ^[dynamic]u16, uvs: ^[dynamic][2]f32, polys: ^[dynamic]u32, pool: ^jobs.Pool = nil) -> (found: Quads_Joined) {
	triangles := len(m.indices) / 3
	if triangles < 2 || len(polys) > 0 do return
	heap := runtime.heap_allocator()
	vf := vertex_faces_build(m^, pool, heap)
	defer vertex_faces_destroy(&vf, heap)
	Join :: struct {
		m:       ^Mesh,
		vf:      Vertex_Faces,
		groups:  []u16,
		uvs:     [][2]f32,
		partner: []i32, // the triangle paired with, or -1
		pick:    []i32, // this round's best unpaired neighbour, or -1
	}
	j := Join {
		m       = m,
		vf      = vf,
		groups  = groups[:] if groups != nil && len(groups) == triangles else nil,
		uvs     = uvs[:] if uvs != nil && len(uvs) == 3 * triangles else nil,
		partner = make([]i32, triangles, heap),
		pick    = make([]i32, triangles, heap),
	}
	defer delete(j.partner, heap)
	defer delete(j.pick, heap)
	slice.fill(j.partner, -1)
	found.pairs = quad_join_runs(&j.partner, m^, vf, j.groups, j.uvs, pool)
	// The rest (a file whose order says nothing, or a pair written apart): mutual best
	// picks, a few rounds: each round's picks read only the pairs made before it.
	for _ in 0 ..< 4 {
		jobs.parallel_ranges(pool, triangles, &j, proc(data: rawptr, lo, hi: int) {
			j := cast(^Join)data
			for t in lo ..< hi do j.pick[t] = -1 if j.partner[t] >= 0 else quad_best_neighbour(j.m^, j.vf, j.groups, j.uvs, j.partner, t)
		}, RANGE_GRAIN)
		joined := 0
		for t in 0 ..< triangles {
			u := j.pick[t]
			if u > i32(t) && j.pick[u] == i32(t) {
				j.partner[t], j.partner[u] = u, i32(t)
				joined += 1
			}
		}
		if joined == 0 do break
		found.pairs += joined
	}
	for t in 0 ..< triangles {
		u := j.partner[t]
		if u > i32(t) do found.corner += f64(quad_corner_mean(m^, t, int(u)))
	}
	found.corner /= f64(max(found.pairs, 1))
	if f64(2 * found.pairs) < QUAD_PAIRED_SHARE * f64(triangles) || found.corner > QUAD_CORNER_MEAN do return
	found.kept = true
	// Each pair together, in the order of its first triangle, the lone ones where they were.
	order := make([]u32, triangles, heap)
	defer delete(order, heap)
	n := 0
	resize(polys, triangles)
	next: u32
	for t in 0 ..< triangles {
		u := j.partner[t]
		if u >= 0 && u < i32(t) do continue
		order[n] = u32(t)
		polys[n] = next
		n += 1
		if u >= 0 {
			order[n] = u32(u)
			polys[n] = next
			n += 1
		}
		next += 1
	}
	indices := make([]u32, len(m.indices), heap)
	defer delete(indices, heap)
	for t, k in order do copy(indices[3 * k:][:3], m.indices[3 * t:][:3])
	copy(m.indices[:], indices)
	if j.groups != nil {
		g := slice.clone(j.groups, heap)
		defer delete(g, heap)
		for t, k in order do j.groups[k] = g[t]
	}
	if j.uvs != nil {
		w := slice.clone(j.uvs, heap)
		defer delete(w, heap)
		for t, k in order do copy(j.uvs[3 * k:][:3], w[3 * t:][:3])
	}
	return
}

// Triangle `t`'s best unpaired neighbour to make a quad with, or -1: the one whose quad is
// the most square and the least folded (quad_shape), the lower number on a tie.
@(private = "file")
quad_best_neighbour :: proc(m: Mesh, vf: Vertex_Faces, groups: []u16, uvs: [][2]f32, partner: []i32, t: int) -> i32 {
	best: i32 = -1
	best_cost := max(f32)
	for e in 0 ..< 3 {
		u, cost, ok := quad_candidate(m, vf, groups, uvs, t, e)
		if !ok || partner[u] >= 0 do continue
		if cost < best_cost || (cost == best_cost && i32(u) < best) {
			best, best_cost = i32(u), cost
		}
	}
	return best
}

// The triangle across triangle `t`'s edge `e` and what their quad costs (quad_shape), when
// the two may make one: the edge has just the two of them, run opposite ways, both are in
// one polygroup, their texture coordinates meet along it, and the quad is not too folded
// or skewed.
@(private = "file")
quad_candidate :: proc(m: Mesh, vf: Vertex_Faces, groups: []u16, uvs: [][2]f32, t, e: int) -> (u: int, cost: f32, ok: bool) {
	tri := m.indices[3 * t:][:3]
	a, b, c := tri[e], tri[(e + 1) % 3], tri[(e + 2) % 3]
	u = -1
	d: u32
	for f in vertex_faces_of(vf, a) {
		if int(f) == t do continue
		other := m.indices[3 * f:][:3]
		for k in 0 ..< 3 {
			if other[k] != a do continue
			if other[(k + 2) % 3] == b {
				if u >= 0 do return
				u, d = int(f), other[(k + 1) % 3]
			} else if other[(k + 1) % 3] == b {
				return
			}
		}
	}
	if u < 0 do return
	if groups != nil && groups[t] != groups[u] do return
	if uvs != nil {
		other := m.indices[3 * u:][:3]
		va, vb: [2]f32
		for k in 0 ..< 3 {
			if other[k] == a do va = uvs[3 * u + k]
			if other[k] == b do vb = uvs[3 * u + k]
		}
		if uvs[3 * t + e] != va || uvs[3 * t + (e + 1) % 3] != vb do return
	}
	cost, ok = quad_shape({m.positions[a], m.positions[d], m.positions[b], m.positions[c]})
	return
}

// How far the quad a, d, b, c (round it, the triangles a b c and b a d meeting along a b)
// is from a flat square: its fold across a b in degrees plus its corners' distances from
// 90 degrees, summed in sorted order so either triangle sees the same cost; false when it
// folds or bends too far, a corner is not convex, or an edge has no length.
@(private = "file")
quad_shape :: proc(q: [4]Vec3) -> (cost: f32, ok: bool) {
	a, d, b, c := q[0], q[1], q[2], q[3]
	nt := linalg.cross(b - a, c - a)
	nu := linalg.cross(a - b, d - b)
	lt, lu := linalg.length(nt), linalg.length(nu)
	if lt == 0 || lu == 0 do return
	fold := math.to_degrees(math.acos(clamp(linalg.dot(nt, nu) / (lt * lu), -1, 1)))
	if fold > QUAD_FOLD_LIMIT do return
	n := nt / lt + nu / lu
	off: [4]f32
	for i in 0 ..< 4 {
		cur, next, prev := q[i], q[(i + 1) % 4], q[(i + 3) % 4]
		e1, e0 := next - cur, prev - cur
		l1, l0 := linalg.length(e1), linalg.length(e0)
		if l1 == 0 || l0 == 0 || linalg.dot(linalg.cross(e1, e0), n) <= 0 do return
		off[i] = corner_off(cur, next, prev)
		if off[i] > QUAD_CORNER_LIMIT do return
	}
	slice.sort(off[:])
	return fold + off[0] + off[1] + off[2] + off[3], true
}

// The mean distance from 90 degrees of the corners of the quad paired triangles `t` and
// `u` make.
@(private = "file")
quad_corner_mean :: proc(m: Mesh, t, u: int) -> f32 {
	tri := m.indices[3 * t:][:3]
	other := m.indices[3 * u:][:3]
	for e in 0 ..< 3 {
		a, b, c := tri[e], tri[(e + 1) % 3], tri[(e + 2) % 3]
		for k in 0 ..< 3 {
			if other[k] != b || other[(k + 1) % 3] != a do continue
			q := [4]Vec3{m.positions[a], m.positions[other[(k + 2) % 3]], m.positions[b], m.positions[c]}
			sum: f32
			for i in 0 ..< 4 do sum += corner_off(q[i], q[(i + 1) % 4], q[(i + 3) % 4])
			return sum / 4
		}
	}
	return 0
}

// How far the corner at `cur`, between its edges to `next` and `prev`, is from 90 degrees.
@(private = "file")
corner_off :: #force_inline proc(cur, next, prev: Vec3) -> f32 {
	e1, e0 := next - cur, prev - cur
	return abs(math.to_degrees(math.acos(clamp(linalg.dot(e1, e0) / (linalg.length(e1) * linalg.length(e0)), -1, 1))) - 90)
}

// Pairs triangles that lie next to each other in the file and make a quad, when at least
// QUAD_IN_ORDER_SHARE of the triangles lie next to such a neighbour: along each run
// of such neighbours (t with t + 1, t + 1 with t + 2, ...) the most pairs, then the
// cheapest, by dynamic programming. A run of an exporter's quads has an even length and
// one way to pair it all, so this finds them whatever their shape; a lone triangle
// written between quads makes a run odd, and the shapes decide which neighbour it leaves.
// Returns the pairs made.
@(private = "file")
quad_join_runs :: proc(partner: ^[]i32, m: Mesh, vf: Vertex_Faces, groups: []u16, uvs: [][2]f32, pool: ^jobs.Pool) -> (pairs: int) {
	triangles := len(m.indices) / 3
	heap := runtime.heap_allocator()
	Runs :: struct {
		m:      Mesh,
		vf:     Vertex_Faces,
		groups: []u16,
		uvs:    [][2]f32,
		link:   []f32, // what pairing t with t + 1 costs, or -1 when they cannot pair
	}
	r := Runs{m = m, vf = vf, groups = groups, uvs = uvs, link = make([]f32, triangles, heap)}
	defer delete(r.link, heap)
	jobs.parallel_ranges(pool, triangles, &r, proc(data: rawptr, lo, hi: int) {
		r := cast(^Runs)data
		for t in lo ..< hi {
			r.link[t] = -1
			if t + 1 == len(r.link) do continue
			for e in 0 ..< 3 {
				u, cost, ok := quad_candidate(r.m, r.vf, r.groups, r.uvs, t, e)
				if ok && u == t + 1 do r.link[t] = cost
			}
		}
	}, RANGE_GRAIN)
	// Only a file written in pairs says anything by its order: most triangles lie next to
	// a neighbour they could make a quad with. In a file in any other order the few that
	// do are there by chance, and pairing them would take a triangle from its own quad.
	linked := 0
	for t in 0 ..< triangles do if r.link[t] >= 0 || (t > 0 && r.link[t - 1] >= 0) do linked += 1
	if f64(linked) < QUAD_IN_ORDER_SHARE * f64(triangles) do return
	// Per run of n triangles: best[i] is the most pairs and least cost of its first i.
	Best :: struct {
		pairs: int,
		cost:  f64,
		pair:  bool, // whether the last two of the first i pair
	}
	best := make([dynamic]Best, heap)
	defer delete(best)
	for start := 0; start < triangles; {
		end := start
		for end + 1 < triangles && r.link[end] >= 0 do end += 1
		n := end - start + 1
		if n >= 2 {
			resize(&best, n + 1)
			best[0], best[1] = {}, {}
			for i in 2 ..= n {
				skip := best[i - 1]
				take := Best{pairs = best[i - 2].pairs + 1, cost = best[i - 2].cost + f64(r.link[start + i - 2]), pair = true}
				skip.pair = false
				best[i] = take if take.pairs > skip.pairs || (take.pairs == skip.pairs && take.cost < skip.cost) else skip
			}
			for i := n; i >= 2; {
				if best[i].pair {
					t := start + i - 2
					partner[t], partner[t + 1] = i32(t + 1), i32(t)
					pairs += 1
					i -= 2
				} else {
					i -= 1
				}
			}
		}
		start = end + 1
	}
	return
}
