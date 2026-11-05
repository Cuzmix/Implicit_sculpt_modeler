package uv

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:slice"

import "../geom"

// Symmetric layouts, as ZBrush UV Master's Symmetry and RizomUV's give them: on a model
// that is its own mirror across the plane `axis` = 0, an island whose mirror is another
// island is not flattened itself but takes that island's coordinates reflected across u,
// so the two read the same way in a texture; an island that is its own mirror (it
// straddles the plane) is solved with a mirror pair held, which makes the solve
// symmetric, and then made exactly symmetric. Where the model or the seams are not
// symmetric the islands touching it are laid out on their own.

Symmetry :: struct {
	axis:      u8,  // 0 x, 1 y, 2 z: the plane through the origin across it
	tolerance: f32, // how far a vertex may be from another's reflection, as a share of the box's diagonal
}

DEFAULT_SYMMETRY :: Symmetry{0, 1e-4}

// The mirror of the triangles and islands of one mesh and its UVs, made with the temp
// allocator on the calling thread.
@(private)
Mirror :: struct {
	axis:   int,
	tri:    []i32,    // per triangle, its mirror triangle, -1 for none
	at:     [][3]u8,  // corner k of t is corner at[t][k] of tri[t]
	leader: []i32,    // per island, the island whose reflection it takes, -1 for its own layout
	self:   []bool,   // per island, whether it is its own mirror
}

@(private)
mirror_build :: proc(u: Uvs, positions: []geom.Vec3, indices: []u32, faces: geom.Vertex_Faces, sym: Symmetry, order, first: []u32) -> (r: Mirror) {
	a := context.temp_allocator
	axis := int(min(sym.axis, 2))
	r.axis = axis
	count := len(indices) / 3
	r.tri = make([]i32, count, a)
	r.at = make([][3]u8, count, a)
	r.leader = make([]i32, u.islands, a)
	r.self = make([]bool, u.islands, a)
	for &l in r.leader do l = -1
	for &t in r.tri do t = -1
	if len(positions) == 0 do return

	// Each vertex's mirror: the nearest vertex to its reflection within the tolerance,
	// found through a grid of cells the tolerance wide, sorted by cell, the lowest index
	// on a tie; kept only where the mirror's mirror is the vertex again.
	lo, hi := positions[0], positions[0]
	for p in positions do lo, hi = linalg.min(lo, p), linalg.max(hi, p)
	tol := max(sym.tolerance, 1e-7) * max(linalg.length(hi - lo), 1e-20)
	Cell :: struct {
		key:    [3]i32,
		vertex: u32,
	}
	cell_of :: proc(p: geom.Vec3, lo: geom.Vec3, tol: f32) -> [3]i32 {
		q := (p - lo) / tol
		return {i32(math.floor(q.x)), i32(math.floor(q.y)), i32(math.floor(q.z))}
	}
	less :: proc(x, y: [3]i32) -> bool {
		if x.x != y.x do return x.x < y.x
		if x.y != y.y do return x.y < y.y
		return x.z < y.z
	}
	// The box is reflected too, so the reflections land inside the same grid.
	glo := lo
	glo[axis] = min(lo[axis], -hi[axis])
	cells := make([]Cell, len(positions), a)
	for p, v in positions do cells[v] = {cell_of(p, glo, tol), u32(v)}
	slice.sort_by(cells, proc(x, y: Cell) -> bool {return less(x.key, y.key) || (x.key == y.key && x.vertex < y.vertex)})
	mirror := make([]i32, len(positions), a)
	for p, v in positions {
		q := p
		q[axis] = -q[axis]
		c := cell_of(q, glo, tol)
		best, best_d := i32(-1), tol * tol
		for dx in i32(-1) ..= 1 do for dy in i32(-1) ..= 1 do for dz in i32(-1) ..= 1 {
			key := c + {dx, dy, dz}
			at, _ := slice.binary_search_by(cells, key, proc(e: Cell, k: [3]i32) -> slice.Ordering {
				if less(e.key, k) do return .Less
				if e.key == k do return .Equal
				return .Greater
			})
			// The first of the cell's run.
			for at > 0 && cells[at - 1].key == key do at -= 1
			for ; at < len(cells) && cells[at].key == key; at += 1 {
				w := cells[at].vertex
				d := linalg.length2(positions[w] - q)
				if d < best_d || (d == best_d && best >= 0 && i32(w) < best) do best, best_d = i32(w), d
			}
		}
		mirror[v] = best
	}
	for &m, v in mirror do if m >= 0 && mirror[m] != i32(v) do m = -1

	// Each triangle's mirror: reflection reverses the winding, so (a, b, c) meets the
	// triangle whose corners run m(a), m(c), m(b).
	for t in 0 ..< count {
		tri := indices[3 * t:][:3]
		ma, mb, mc := mirror[tri[0]], mirror[tri[1]], mirror[tri[2]]
		if ma < 0 || mb < 0 || mc < 0 do continue
		for o in faces.tris[faces.offsets[ma]:faces.offsets[ma + 1]] {
			ot := indices[3 * o:][:3]
			for k in 0 ..< 3 do if i32(ot[k]) == ma && i32(ot[(k + 1) % 3]) == mc && i32(ot[(k + 2) % 3]) == mb {
				r.tri[t] = i32(o)
				r.at[t] = {u8(k), u8((k + 2) % 3), u8((k + 1) % 3)}
			}
		}
	}

	// The islands: each triangle of island i has its mirror in one island j, which has
	// as many triangles, each of whose mirrors is back in i, and corners that are joined
	// in i are joined in j (the seams agree). The lower island leads.
	for i in 0 ..< u.islands {
		tris := order[first[i]:first[i + 1]]
		j := -1
		fits := len(tris) > 0
		for t in tris {
			o := r.tri[t]
			if o < 0 || r.tri[o] != i32(t) {
				fits = false
				break
			}
			oi := int(u.island[o])
			if j < 0 do j = oi
			if oi != j {
				fits = false
				break
			}
		}
		if !fits || first[j + 1] - first[j] != u32(len(tris)) do continue
		// Seams: an edge of t is a seam exactly when its mirror edge is (corner k's edge
		// runs to k + 1, which on the mirror runs the other way: from at[k + 1] to at[k]).
		for t in tris {
			o := r.tri[t]
			for k in 0 ..< 3 {
				mk := (int(r.at[t][(k + 1) % 3])) // the mirror edge starts at the next corner's image
				if (k in u.seam[t]) != (mk in u.seam[o]) do fits = false
			}
		}
		if !fits do continue
		if j == i do r.self[i] = true
		else if j < i do r.leader[i] = i32(j)
	}
	return
}

// Each follower island's corners from its leader's, reflected across u = 0, where
// `take` says the leader was laid out.
@(private)
mirror_copy :: proc(u: ^Uvs, r: Mirror, take: proc(island: u32, data: rawptr) -> bool, data: rawptr) {
	for t in 0 ..< len(u.corner) {
		l := r.leader[u.island[t]]
		if l < 0 || !take(u32(l), data) do continue
		o := r.tri[t]
		for k in 0 ..< 3 {
			p := u.corner[o][r.at[t][k]]
			u.corner[t][k] = {-p.x, p.y}
		}
	}
}

// Per wedge of island `m` (its own mirror), the wedge its mirror corners join; -1 where
// the corners of one wedge do not all land in one wedge.
@(private)
mirror_wedges :: proc(m: ^Island_Mesh, r: Mirror, allocator := context.allocator) -> []i32 {
	out := make([]i32, m.wedges, allocator)
	for &w in out do w = -2
	for t, li in m.tris {
		o := u32(r.tri[t])
		lo, _ := slice.binary_search(m.tris, o)
		for k in 0 ..< 3 {
			w := m.wedge[3 * li + k]
			mw := i32(m.wedge[3 * lo + int(r.at[t][k])])
			if out[w] == -2 do out[w] = mw
			else if out[w] != mw do out[w] = -1
		}
	}
	for w in 0 ..< m.wedges do if out[w] >= 0 && out[out[w]] != i32(w) do out[w] = -1
	return out
}

// Makes the coordinates `flat` of a self-mirrored island exactly symmetric: the mirror
// line is the one the pairs' midpoints and differences give, and each wedge becomes the
// mean of itself and its mirror's reflection. Left as it was (false) when a wedge has no
// mirror or the mean would fold a triangle.
@(private)
symmetrize :: proc(flat: [][2]f64, m: ^Island_Mesh, mirrors: []i32, positions: []geom.Vec3, axis: int) -> bool {
	centre, normal: [2]f64
	pairs := 0
	for w in 0 ..< m.wedges {
		mw := mirrors[w]
		if mw < 0 do return false
		centre += (flat[w] + flat[mw]) * 0.5
		pairs += 1
		if positions[m.vertex[w]][axis] > 0 do normal += flat[w] - flat[mw]
	}
	l := linalg.length(normal)
	if pairs == 0 || !(l > 0) do return false
	centre /= f64(pairs)
	normal /= l
	out := make([][2]f64, m.wedges, runtime.heap_allocator())
	defer delete(out, runtime.heap_allocator())
	for w in 0 ..< m.wedges {
		q := flat[mirrors[w]]
		reflected := q - 2 * linalg.dot(q - centre, normal) * normal
		out[w] = (flat[w] + reflected) * 0.5
	}
	for li in 0 ..< len(m.tris) do if signed_area(out, m.wedge[3 * li:][:3]) <= 0 do return false
	copy(flat, out)
	return true
}

// symmetrize on an island's coordinates as u.corner holds them (each wedge where its
// first corner is), written back when it took.
@(private)
symmetrize_corners :: proc(u: ^Uvs, m: ^Island_Mesh, mirrors: []i32, positions: []geom.Vec3, axis: int) {
	heap := runtime.heap_allocator()
	flat := make([][2]f64, m.wedges, heap)
	defer delete(flat, heap)
	#reverse for t, li in m.tris do for k in 0 ..< 3 {
		p := u.corner[t][k]
		flat[m.wedge[3 * li + k]] = {f64(p.x), f64(p.y)}
	}
	if !symmetrize(flat, m, mirrors, positions, axis) do return
	for t, li in m.tris do for k in 0 ..< 3 {
		p := flat[m.wedge[3 * li + k]]
		u.corner[t][k] = {f32(p.x), f32(p.y)}
	}
}

// For a self-mirrored island with no pins: the border wedge farthest from the plane on
// its positive side (the lowest on a tie) and its mirror, the pair the solve holds so
// that it comes out symmetric. -1, -1 when there is none.
@(private)
mirror_pair :: proc(positions: []geom.Vec3, m: ^Island_Mesh, mirrors: []i32, axis: int) -> (p, q: int) {
	p, q = -1, -1
	best: f32 = 0
	for w in 0 ..< m.wedges {
		if !m.on_edge[w] || mirrors[w] < 0 || mirrors[w] == i32(w) do continue
		at := positions[m.vertex[w]][axis]
		if at > best do p, q, best = w, int(mirrors[w]), at
	}
	return
}
