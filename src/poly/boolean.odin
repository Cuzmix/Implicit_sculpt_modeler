package poly

import "core:math"
import "core:math/linalg"
import "core:slice"

// Exact polygon booleans of two closed cages (Blender's Boolean modifier, Exact; Plasticity's
// and Shapr3D's solid booleans): union, subtract and intersect, cut along the planes of
// the faces themselves, so flat faces stay flat and edges stay straight where the sculpt's
// voxel boolean (geom.mesh_boolean) rounds the seam to its voxels. Each cage's polygons are
// split where the other's cross them and kept or dropped by where each piece lies, in
// double precision with a tolerance of a hundred-millionth of the pair's
// size. The pieces are then welded, every point lying on another piece's edge put into
// that edge so the cage is watertight, and the pieces of each original face joined back
// into as few faces as can be, so a face the cut never reached comes out as it went in.
// The faces of `b` that end up in the result get a polygroup of their own, and with
// `crease` the seam where the two meet is fully creased, so Smooth keeps it sharp.

Boolean_Op :: enum u8 {
	Union,
	Subtract,
	Intersect,
}

@(private = "file")
V3 :: [3]f64

@(private = "file")
Csg_Plane :: struct {
	n: V3,
	w: f64,
}

@(private = "file")
Csg_Polygon :: struct {
	verts:  [dynamic]V3,
	plane:  Csg_Plane,
	source: u32, // the face it came from: a's ids first, then b's after them
	bent:   bool, // that face was bent and went in as a fan of triangles
}

@(private = "file")
Csg :: struct {
	eps: f64,
}

@(private = "file")
plane_of :: proc(verts: []V3) -> (p: Csg_Plane, ok: bool) {
	// Newell's normal, the best fit for any polygon.
	n: V3
	for a, i in verts {
		b := verts[(i + 1) % len(verts)]
		n.x += (a.y - b.y) * (a.z + b.z)
		n.y += (a.z - b.z) * (a.x + b.x)
		n.z += (a.x - b.x) * (a.y + b.y)
	}
	l := linalg.length(n)
	if l < 1e-300 do return {}, false
	n /= l
	c: V3
	for v in verts do c += v
	c /= f64(len(verts))
	return {n, linalg.dot(n, c)}, true
}

@(private = "file")
flip :: proc(p: ^Csg_Polygon) {
	slice.reverse(p.verts[:])
	p.plane.n = -p.plane.n
	p.plane.w = -p.plane.w
}

@(private = "file")
COPLANAR :: 0
@(private = "file")
FRONT :: 1
@(private = "file")
BACK :: 2
@(private = "file")
SPANNING :: 3

// Splits `poly` by `plane` into the lists it belongs to, as CSG.js's splitPolygon
// (coplanar ones go front or back by which way they face).
@(private = "file")
split_polygon :: proc(c: ^Csg, plane: Csg_Plane, poly: Csg_Polygon, coplanar_front, coplanar_back, front, back: ^[dynamic]Csg_Polygon) {
	kinds := make([]int, len(poly.verts), context.temp_allocator)
	all := 0
	for v, i in poly.verts {
		t := linalg.dot(plane.n, v) - plane.w
		k := BACK if t < -c.eps else (FRONT if t > c.eps else COPLANAR)
		all |= k
		kinds[i] = k
	}
	switch all {
	case COPLANAR:
		if linalg.dot(plane.n, poly.plane.n) > 0 do append(coplanar_front, poly)
		else do append(coplanar_back, poly)
	case FRONT:
		append(front, poly)
	case BACK:
		append(back, poly)
	case:
		f := make([dynamic]V3, context.temp_allocator)
		b := make([dynamic]V3, context.temp_allocator)
		n := len(poly.verts)
		for i in 0 ..< n {
			j := (i + 1) % n
			ti, tj := kinds[i], kinds[j]
			vi, vj := poly.verts[i], poly.verts[j]
			if ti != BACK do append(&f, vi)
			if ti != FRONT do append(&b, vi)
			if (ti | tj) == SPANNING {
				t := (plane.w - linalg.dot(plane.n, vi)) / linalg.dot(plane.n, vj - vi)
				p := vi + (vj - vi) * t
				append(&f, p)
				append(&b, p)
			}
		}
		if len(f) >= 3 do append(front, Csg_Polygon{verts = f, plane = poly.plane, source = poly.source, bent = poly.bent})
		if len(b) >= 3 do append(back, Csg_Polygon{verts = b, plane = poly.plane, source = poly.source, bent = poly.bent})
	}
}

// A cage's faces as convex flat polygons in `a`'s space: a flat convex face as it is, and
// a bent or concave one (a quad sphere's, an L-shaped n-gon) as the triangles the cage is
// drawn with, since a piece is split by planes and only a convex flat one splits right.
// The joining afterwards makes such a face whole again wherever the cut missed it.
@(private = "file")
mesh_polygons :: proc(m: ^Mesh, to: matrix[4, 4]f32, source_base: u32) -> [dynamic]Csg_Polygon {
	out := make([dynamic]Csg_Polygon, context.temp_allocator)
	vs := make([dynamic]u32, context.temp_allocator)
	tris := make([dynamic][3]int, context.temp_allocator)
	// A mirroring transform turns the faces inside out; their corners are reversed back.
	mirrored := linalg.determinant(to) < 0
	at := make([dynamic]V3, context.temp_allocator)
	for f in 0 ..< u32(len(m.face_he)) {
		face_verts(m, f, &vs)
		clear(&at)
		for v in vs {
			q := (to * [4]f32{m.positions[v].x, m.positions[v].y, m.positions[v].z, 1}).xyz
			append(&at, V3{f64(q.x), f64(q.y), f64(q.z)})
		}
		if mirrored do slice.reverse(at[:])
		plane, ok := plane_of(at[:])
		if !ok do continue
		bend, turn: f64
		lo, hi := at[0], at[0]
		n := len(at)
		for v, i in at {
			bend = max(bend, abs(linalg.dot(plane.n, v) - plane.w))
			lo, hi = linalg.min(lo, v), linalg.max(hi, v)
			prev, next := at[(i + n - 1) % n], at[(i + 1) % n]
			turn = min(turn, linalg.dot(linalg.cross(v - prev, next - v), plane.n))
		}
		size := linalg.length(hi - lo)
		bent := n > 3 && bend > size * 1e-6
		if !bent && turn >= -size * size * 1e-9 {
			p := Csg_Polygon{verts = make([dynamic]V3, context.temp_allocator), plane = plane, source = source_base + f}
			append(&p.verts, ..at[:])
			append(&out, p)
			continue
		}
		clear(&tris)
		face_triangles(m, f, vs[:], &tris)
		for t in tris {
			tri := Csg_Polygon{verts = make([dynamic]V3, context.temp_allocator), source = source_base + f, bent = bent}
			x, y, z := at[t[0]], at[t[1]], at[t[2]]
			if mirrored do x, y, z = at[n - 1 - t[0]], at[n - 1 - t[2]], at[n - 1 - t[1]]
			append(&tri.verts, x, y, z)
			tp, tok := plane_of(tri.verts[:])
			if !tok do continue
			tri.plane = tp
			append(&out, tri)
		}
	}
	return out
}

// `a` op `b`, `b` brought into `a`'s space by `to`. Refused when either cage is open
// (a boolean needs an inside), or when the result is empty or would not be a valid cage.
//
// Each polygon is split only by the other cage's polygons that really cross it, so a face
// far from the seam comes through whole; each piece is then inside or outside the other
// cage by its winding number (the solid angle the other cage fills round the piece's
// middle), or lies on the other cage's surface, where which way the two face decides it.
cage_boolean :: proc(a, b: ^Mesh, to: matrix[4, 4]f32, op: Boolean_Op, crease := true, allocator := context.allocator) -> (out: Mesh, err: Build_Error) {
	for e in 0 ..< u32(len(a.crease)) do if edge_border(a, e) do return {}, .Non_Manifold_Edge
	for e in 0 ..< u32(len(b.crease)) do if edge_border(b, e) do return {}, .Non_Manifold_Edge
	identity := matrix[4, 4]f32{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}
	pa := mesh_polygons(a, identity, 0)
	pb := mesh_polygons(b, to, u32(len(a.face_he)))
	if len(pa) == 0 || len(pb) == 0 do return {}, .Degenerate_Face
	// The tolerance, from the pair's size.
	lo, hi := V3{max(f64), max(f64), max(f64)}, V3{min(f64), min(f64), min(f64)}
	for list in ([2][]Csg_Polygon{pa[:], pb[:]}) do for p in list do for v in p.verts {
		lo = linalg.min(lo, v)
		hi = linalg.max(hi, v)
	}
	size := linalg.length(hi - lo)
	c := Csg{eps = max(size, 1e-12) * 1e-8}
	boxes_a := polygon_boxes(&c, pa[:])
	boxes_b := polygon_boxes(&c, pb[:])
	result := make([dynamic]Csg_Polygon, context.temp_allocator)
	for side in 0 ..< 2 {
		mine, theirs := pa[:], pb[:]
		my_boxes, their_boxes := boxes_a, boxes_b
		m, base := a, u32(0)
		if side == 1 {
			mine, theirs = pb[:], pa[:]
			my_boxes, their_boxes = boxes_b, boxes_a
			m, base = b, u32(len(a.face_he))
		}
		// The other cage's polygons near each of these, by their boxes.
		near_start := make([]int, len(mine) + 1, context.temp_allocator)
		near := make([dynamic]int, context.temp_allocator)
		for _, i in mine {
			near_start[i] = len(near)
			for _, j in theirs do if boxes_overlap(my_boxes[i], their_boxes[j]) do append(&near, j)
		}
		near_start[len(mine)] = len(near)
		// Faces near nothing of the other cage cannot cross it, nor can the edges between
		// two of them, so each connected patch of them lies all inside or all outside and
		// needs only one winding number, the costly part.
		face_count := len(m.face_he)
		far := make([]bool, face_count, context.temp_allocator)
		for &x in far do x = true
		for p, i in mine do if near_start[i + 1] > near_start[i] do far[p.source - base] = false
		patch := make([]u32, face_count, context.temp_allocator)
		for &x, f in patch do x = u32(f)
		root :: proc(patch: []u32, f: u32) -> u32 {
			f := f
			for patch[f] != f {
				patch[f] = patch[patch[f]]
				f = patch[f]
			}
			return f
		}
		for e in 0 ..< len(m.crease) {
			fa, fb := m.he_face[2 * e], m.he_face[2 * e + 1]
			if fa == NONE || fb == NONE || !far[fa] || !far[fb] do continue
			ra, rb := root(patch, fa), root(patch, fb)
			if ra != rb do patch[max(ra, rb)] = min(ra, rb)
		}
		known := make([]i8, face_count, context.temp_allocator)
		for &x in known do x = -1
		pieces := make([dynamic]Csg_Polygon, context.temp_allocator)
		for p, i in mine {
			mine_near := near[near_start[i]:near_start[i + 1]]
			clear(&pieces)
			append(&pieces, p)
			for j in mine_near do split_by(&c, &pieces, p, theirs[j])
			for piece in pieces {
				where_: Where
				if far[p.source - base] {
					r := root(patch, p.source - base)
					if known[r] < 0 do known[r] = i8(classify(&c, piece, theirs, mine_near))
					where_ = Where(known[r])
				} else {
					where_ = classify(&c, piece, theirs, mine_near)
				}
				keep, turn := false, false
				switch op {
				case .Union:
					keep = where_ == .Outside || (side == 0 && where_ == .Same)
				case .Subtract:
					if side == 0 do keep = where_ == .Outside || where_ == .Opposite
					else do keep, turn = where_ == .Inside, true
				case .Intersect:
					keep = where_ == .Inside || (side == 0 && where_ == .Same)
				}
				if !keep do continue
				q := piece
				if turn {
					q.verts = slice.clone_to_dynamic(piece.verts[:], context.temp_allocator)
					flip(&q)
				}
				append(&result, q)
			}
		}
	}
	if len(result) == 0 do return {}, .Degenerate_Face
	return assemble(&c, a, b, result[:], crease, allocator)
}

@(private = "file")
Box :: [2]V3

@(private = "file")
polygon_boxes :: proc(c: ^Csg, polys: []Csg_Polygon) -> []Box {
	out := make([]Box, len(polys), context.temp_allocator)
	for p, i in polys {
		lo, hi := p.verts[0], p.verts[0]
		for v in p.verts do lo, hi = linalg.min(lo, v), linalg.max(hi, v)
		out[i] = {lo - c.eps * 10, hi + c.eps * 10}
	}
	return out
}

@(private = "file")
boxes_overlap :: proc(a, b: Box) -> bool {
	return a[0].x <= b[1].x && b[0].x <= a[1].x && a[0].y <= b[1].y && b[0].y <= a[1].y && a[0].z <= b[1].z && b[0].z <= a[1].z
}

// The pieces of polygon `p` split where `q` crosses it: by q's plane when the two cross
// along a stretch of the line their planes share, or, when q lies in p's plane, by the
// planes standing on q's edges, so each piece is wholly on q or wholly off it.
@(private = "file")
split_by :: proc(c: ^Csg, pieces: ^[dynamic]Csg_Polygon, p, q: Csg_Polygon) {
	tol := c.eps * 10
	q_on, q_front, q_back := 0, 0, 0
	for v in q.verts {
		d := linalg.dot(p.plane.n, v) - p.plane.w
		if d > tol do q_front += 1
		else if d < -tol do q_back += 1
		else do q_on += 1
	}
	planes := make([dynamic]Csg_Plane, context.temp_allocator)
	if q_front == 0 && q_back == 0 {
		// In p's plane: split by the planes on q's edges, outward from q.
		for v, i in q.verts {
			e := q.verts[(i + 1) % len(q.verts)] - v
			n := linalg.normalize0(linalg.cross(e, q.plane.n))
			if n == {} do continue
			append(&planes, Csg_Plane{n, linalg.dot(n, v)})
		}
	} else {
		// q must cross p's plane, or lie against it along an edge (two cages touching
		// along a line still part there).
		if !(q_front > 0 && q_back > 0) && q_on < 2 do return
		p_front, p_back := false, false
		for v in p.verts {
			d := linalg.dot(q.plane.n, v) - q.plane.w
			if d > tol do p_front = true
			if d < -tol do p_back = true
		}
		if !(p_front && p_back) do return
		// Where each crosses the other's plane, along the line the planes share.
		dir := linalg.cross(p.plane.n, q.plane.n)
		if linalg.length(dir) < 1e-12 do return
		p0, p1, pok := crossing_span(p.verts[:], q.plane, dir, tol)
		q0, q1, qok := crossing_span(q.verts[:], p.plane, dir, tol)
		if !pok || !qok do return
		if min(p1, q1) - max(p0, q0) <= tol * linalg.length(dir) do return
		append(&planes, q.plane)
	}
	for plane in planes {
		next := make([dynamic]Csg_Polygon, context.temp_allocator)
		for piece in pieces do split_polygon(c, plane, piece, &next, &next, &next, &next)
		clear(pieces)
		append(pieces, ..next[:])
	}
}

// The stretch of the line along `dir` that a convex polygon covers where it meets `plane`.
@(private = "file")
crossing_span :: proc(verts: []V3, plane: Csg_Plane, dir: V3, tol: f64) -> (t0, t1: f64, ok: bool) {
	t0, t1 = max(f64), min(f64)
	n := len(verts)
	for v, i in verts {
		w := verts[(i + 1) % n]
		dv := linalg.dot(plane.n, v) - plane.w
		dw := linalg.dot(plane.n, w) - plane.w
		if abs(dv) <= tol {
			t := linalg.dot(v, dir)
			t0, t1, ok = min(t0, t), max(t1, t), true
		}
		if (dv > tol && dw < -tol) || (dv < -tol && dw > tol) {
			x := v + (w - v) * (dv / (dv - dw))
			t := linalg.dot(x, dir)
			t0, t1, ok = min(t0, t), max(t1, t), true
		}
	}
	return
}

@(private = "file")
Where :: enum u8 {
	Outside,
	Inside,
	Same, // on the other cage's surface, facing the same way
	Opposite, // on it, facing the other way
}

// Where a piece lies against the other cage: on a polygon of it (among `near`, those whose
// boxes meet the piece's polygon) or by its middle's winding number about all of it.
@(private = "file")
classify :: proc(c: ^Csg, piece: Csg_Polygon, theirs: []Csg_Polygon, near: []int) -> Where {
	mid: V3
	for v in piece.verts do mid += v
	mid /= f64(len(piece.verts))
	tol := c.eps * 10
	for j in near {
		q := theirs[j]
		if abs(linalg.dot(q.plane.n, mid) - q.plane.w) > tol do continue
		if abs(linalg.dot(q.plane.n, piece.plane.n)) < 1 - 1e-6 do continue
		inside := true
		for v, i in q.verts {
			e := q.verts[(i + 1) % len(q.verts)] - v
			if linalg.dot(linalg.cross(e, mid - v), q.plane.n) < -tol * linalg.length(e) {
				inside = false
				break
			}
		}
		if inside do return .Same if linalg.dot(q.plane.n, piece.plane.n) > 0 else .Opposite
	}
	// The generalized winding number: the solid angles of the other cage's triangles as
	// seen from the middle, which sum to a whole sphere inside and nothing outside.
	total: f64
	for q in theirs {
		for i in 1 ..< len(q.verts) - 1 {
			x, y, z := q.verts[0] - mid, q.verts[i] - mid, q.verts[i + 1] - mid
			lx, ly, lz := linalg.length(x), linalg.length(y), linalg.length(z)
			num := linalg.dot(x, linalg.cross(y, z))
			den := lx * ly * lz + linalg.dot(x, y) * lz + linalg.dot(x, z) * ly + linalg.dot(y, z) * lx
			total += 2 * math.atan2(num, den)
		}
	}
	return .Inside if total > 2 * math.PI else .Outside
}

// The pieces welded into a cage: equal points shared, every point on a piece's edge put
// into it, then each original face's pieces joined back where they can be.
@(private = "file")
assemble :: proc(c: ^Csg, a, b: ^Mesh, pieces: []Csg_Polygon, crease: bool, allocator := context.allocator) -> (out: Mesh, err: Build_Error) {
	// Welding, through a grid of cells the tolerance's size times a hundred, looking at
	// the cell and its neighbours, so points within the tolerance meet whatever cell they
	// fall in.
	cell := c.eps * 100
	Key :: [3]i64
	grid := make(map[Key][dynamic]u32, allocator = context.temp_allocator)
	points := make([dynamic]V3, context.temp_allocator)
	weld :: proc(grid: ^map[Key][dynamic]u32, points: ^[dynamic]V3, p: V3, cell, eps: f64) -> u32 {
		k := Key{i64(math.floor(p.x / cell)), i64(math.floor(p.y / cell)), i64(math.floor(p.z / cell))}
		for dx in -1 ..= 1 do for dy in -1 ..= 1 do for dz in -1 ..= 1 {
			if list, ok := grid[k + {i64(dx), i64(dy), i64(dz)}]; ok {
				for id in list do if linalg.length(points[id] - p) <= eps * 10 do return id
			}
		}
		id := u32(len(points))
		append(points, p)
		if k not_in grid do grid[k] = make([dynamic]u32, context.temp_allocator)
		append(&grid[k], id)
		return id
	}
	faces := make([dynamic][dynamic]u32, context.temp_allocator)
	sources := make([dynamic]u32, context.temp_allocator)
	bent := make(map[u32]bool, allocator = context.temp_allocator)
	for p in pieces {
		f := make([dynamic]u32, context.temp_allocator)
		for v in p.verts {
			id := weld(&grid, &points, v, cell, c.eps)
			if len(f) > 0 && f[len(f) - 1] == id do continue
			append(&f, id)
		}
		if len(f) > 1 && f[0] == f[len(f) - 1] do pop(&f)
		if len(f) < 3 do continue
		append(&faces, f)
		append(&sources, p.source)
		if p.bent do bent[p.source] = true
	}
	// T-junctions: a point lying inside another face's edge goes into that edge, so both
	// faces share it and the cage closes. The points are bucketed in a coarse grid (about
	// one point a cell) and each edge looks only in the cells its box covers.
	plo, phi := points[0], points[0]
	for q in points do plo, phi = linalg.min(plo, q), linalg.max(phi, q)
	coarse := max(linalg.max(phi - plo) / max(math.cbrt(f64(len(points))), 1), c.eps * 1000)
	cell_of :: proc(q, lo: V3, coarse: f64) -> Key {
		return Key{i64((q.x - lo.x) / coarse), i64((q.y - lo.y) / coarse), i64((q.z - lo.z) / coarse)}
	}
	buckets := make(map[Key][dynamic]u32, allocator = context.temp_allocator)
	for q, id in points {
		k := cell_of(q, plo, coarse)
		if k not_in buckets do buckets[k] = make([dynamic]u32, context.temp_allocator)
		append(&buckets[k], u32(id))
	}
	for &f in faces {
		fixed := make([dynamic]u32, context.temp_allocator)
		for i in 0 ..< len(f) {
			x, y := f[i], f[(i + 1) % len(f)]
			append(&fixed, x)
			px, py := points[x], points[y]
			d := py - px
			l2 := linalg.dot(d, d)
			if l2 < 1e-300 do continue
			Hit :: struct {
				t:  f64,
				id: u32,
			}
			hits := make([dynamic]Hit, context.temp_allocator)
			lo, hi := linalg.min(px, py) - c.eps * 10, linalg.max(px, py) + c.eps * 10
			klo, khi := cell_of(lo, plo, coarse), cell_of(hi, plo, coarse)
			for kx in klo.x ..= khi.x do for ky in klo.y ..= khi.y do for kz in klo.z ..= khi.z {
				list, has := buckets[{kx, ky, kz}]
				if !has do continue
				for id in list {
					if id == x || id == y do continue
					q := points[id]
					if q.x < lo.x || q.y < lo.y || q.z < lo.z || q.x > hi.x || q.y > hi.y || q.z > hi.z do continue
					t := linalg.dot(q - px, d) / l2
					if t <= 0 || t >= 1 do continue
					if linalg.length(px + d * t - q) > c.eps * 10 do continue
					append(&hits, Hit{t, id})
				}
			}
			slice.sort_by(hits[:], proc(a, b: Hit) -> bool {return a.t < b.t || (a.t == b.t && a.id < b.id)})
			for h in hits do if fixed[len(fixed) - 1] != h.id do append(&fixed, h.id)
		}
		f = fixed
	}
	join_pieces(&faces, &sources, &bent, points[:], c.eps)
	// Into a cage, dropping points no face uses.
	used := make([]u32, len(points), context.temp_allocator)
	for &u in used do u = NONE
	positions := make([dynamic]Vec3, context.temp_allocator)
	sizes := make([dynamic]int, context.temp_allocator)
	corners := make([dynamic]u32, context.temp_allocator)
	groups := make([dynamic]u16, context.temp_allocator)
	b_group := group_next(a)
	na := u32(len(a.face_he))
	for f, i in faces {
		if len(f) < 3 do continue
		for v in f {
			if used[v] == NONE {
				used[v] = u32(len(positions))
				append(&positions, Vec3{f32(points[v].x), f32(points[v].y), f32(points[v].z)})
			}
			append(&corners, used[v])
		}
		append(&sizes, len(f))
		src := sources[i]
		append(&groups, a.group[src] if src < na else b_group + b.group[src - na])
	}
	out, err = mesh_from_polygons(positions[:], sizes[:], corners[:], groups[:], allocator)
	if err != .None do return
	// The seam where the two cages meet, creased.
	if crease {
		kept := make([dynamic]u32, context.temp_allocator)
		for f, i in faces do if len(f) >= 3 do append(&kept, sources[i])
		for e in 0 ..< u32(len(out.crease)) {
			fa, fb := out.he_face[2 * e], out.he_face[2 * e + 1]
			if fa == NONE || fb == NONE do continue
			if (kept[fa] < na) != (kept[fb] < na) do out.crease[e] = INFINITE_SHARP
		}
	}
	return out, .None
}

// Each original face's pieces joined back into as few faces as can be: two pieces of one
// face sharing one unbroken run of edges become one, as long as the run's inner points
// belong to no other piece (so nothing is left hanging); then a point left between just
// two edges in a straight line goes. A piece left round a hole stays in pieces, since a
// face cannot have a hole. Emptied pieces are left with no corners for the caller to skip.
@(private = "file")
join_pieces :: proc(faces: ^[dynamic][dynamic]u32, sources: ^[dynamic]u32, bent: ^map[u32]bool, points: []V3, eps: f64) {
	point_count := len(points)
	Owner :: struct {
		face: int,
		at:   int,
	}
	key :: proc(a, b: u32) -> u64 {return u64(a) << 32 | u64(b)}
	for pass := 0; pass < 64; pass += 1 {
		// Who runs each directed edge, and how many pieces use each point.
		owners := make(map[u64]Owner, allocator = context.temp_allocator)
		users := make([]int, point_count, context.temp_allocator)
		for f, i in faces {
			for v, k in f {
				owners[key(v, f[(k + 1) % len(f)])] = {i, k}
				users[v] += 1
			}
		}
		merged := false
		gone := make([]bool, len(faces), context.temp_allocator)
		for i in 0 ..< len(faces) {
			if gone[i] do continue
			f := faces[i][:]
			n := len(f)
			if n < 3 do continue
			// A neighbour piece of the same face across one of this piece's edges.
			for k in 0 ..< n {
				o, ok := owners[key(f[(k + 1) % n], f[k])]
				if !ok || o.face == i || gone[o.face] || sources[o.face] != sources[i] do continue
				j := o.face
				// The run of edges i shares with j, which must be all of what they share.
				shared := make([]bool, n, context.temp_allocator)
				count := 0
				for x in 0 ..< n {
					if w, has := owners[key(f[(x + 1) % n], f[x])]; has && w.face == j {
						shared[x] = true
						count += 1
					}
				}
				if count == n do continue
				// The run's first edge: shared, with the one before it not.
				first := -1
				runs := 0
				for x in 0 ..< n do if shared[x] && !shared[(x + n - 1) % n] {
					first = x
					runs += 1
				}
				if runs != 1 do continue
				// Its inner points belong to i and j alone.
				clean := true
				for x in 1 ..< count do if users[f[(first + x) % n]] != 2 do clean = false
				if !clean do continue
				// The joined piece: i from the run's end round to its start, then j from
				// after the run's start round to before its end.
				g := faces[j][:]
				m := len(g)
				start, end := f[first], f[(first + count) % n]
				out := make([dynamic]u32, context.temp_allocator)
				for x in 0 ..< n - count + 1 do append(&out, f[(first + count + x) % n])
				// In j the run goes from `end` to `start`; walk from after `start` to before `end`.
				js := -1
				for x in 0 ..< m do if g[x] == start do js = x
				if js < 0 do continue
				for x := 1; ; x += 1 {
					v := g[(js + x) % m]
					if v == end do break
					append(&out, v)
					if x > m do break
				}
				// Pieces that also touch at a lone point would join into a face that passes
				// through it twice; they stay apart.
				sorted := slice.clone(out[:], context.temp_allocator)
				slice.sort(sorted)
				twice := false
				for x in 1 ..< len(sorted) do if sorted[x] == sorted[x - 1] do twice = true
				if twice || len(out) < 3 do continue
				// A bent face's pieces join only back into a quad, the face as it was where
				// the cut missed it: anything larger would be bent and possibly concave,
				// with no plane to cut it into triangles in.
				if sources[i] in bent && len(out) > 4 do continue
				faces[i] = out
				clear(&faces[j])
				gone[j] = true
				merged = true
				break
			}
		}
		if !merged do break
	}
	// Points left between two edges on a straight line go, from every piece that has them.
	neighbours := make([]map[u32]bool, point_count, context.temp_allocator)
	for f in faces do for v, k in f {
		if neighbours[v] == nil do neighbours[v] = make(map[u32]bool, allocator = context.temp_allocator)
		neighbours[v][f[(k + 1) % len(f)]] = true
		neighbours[v][f[(k + len(f) - 1) % len(f)]] = true
	}
	for &f in faces {
		if len(f) < 3 do continue
		kept := make([dynamic]u32, context.temp_allocator)
		for v in f {
			if len(neighbours[v]) == 2 {
				// Only where the two edges run on in one line, so no corner is cut.
				ends: [2]V3
				k := 0
				for o in neighbours[v] {
					ends[k] = points[o]
					k += 1
				}
				d := ends[1] - ends[0]
				l2 := linalg.dot(d, d)
				if l2 > 0 {
					t := linalg.dot(points[v] - ends[0], d) / l2
					if linalg.length(ends[0] + d * t - points[v]) <= eps * 10 do continue
				}
			}
			append(&kept, v)
		}
		if len(kept) >= 3 do f = kept
	}
}
