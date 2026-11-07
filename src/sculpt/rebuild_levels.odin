package sculpt

import "core:math/linalg"
import "core:slice"

import "../geom"
import "../jobs"

// Rebuild levels, after ZBrush's Reconstruct Subdiv and Blender's Rebuild Subdivisions: a
// dense mesh that was made by subdividing (an import from ZBrush, Blender or Mudbox) gets
// back the coarser levels it came from, with its own surface as the top level, so the
// big shapes can be moved on a light level and the detail rides along.
//
// Each step down finds which vertices of the mesh were there before the step and which
// came from it, by its topology alone:
//   - Loop (triangles): a step put a vertex on every edge and cut each triangle into four.
//     An old vertex has only new neighbours, and a new one (always six triangles round it
//     on a closed mesh) has the two ends of its old edge three steps apart round it.
//   - Catmull-Clark (quads): a step put a point on every edge and in every polygon and
//     cut each polygon into quads, each with an old corner, two edge points and the face
//     point, the old corner opposite the face point.
// The step's coarse mesh is then the old vertices joined as the cut polygons say, placed
// where one subdivision step puts them back where they were, as near as it can. The top
// level is the mesh itself, exactly: each level above the base stores its offset from
// the level below's subdivision as its detail, as subdividing and opening a file do.

@(private = "file")
Role :: enum u8 {
	Unknown,
	Old, // a vertex the step kept: a coarse vertex (Loop's even, Catmull-Clark's vertex point)
	Edge, // a vertex the step put on a coarse edge
	Face, // a Catmull-Clark face point
}

// One step down: the coarse polygons and points, and for each coarse vertex, edge and
// polygon, the fine vertex the step made of it.
@(private = "file")
Unsub :: struct {
	quads:     bool, // a Catmull-Clark step (the fine mesh is quads), else Loop's
	positions: []Vec3,
	first:     []u32, // coarse polygon p's corners are corners[first[p]:first[p + 1]]
	corners:   []u32,
	vert_fine: []u32, // per coarse vertex
	edge_keys: []u64, // sorted sharp_key of each coarse edge
	edge_fine: []u32, // per edge_keys entry
	face_fine: []u32, // per coarse polygon, Catmull-Clark only
}

// A polygon mesh as the steps take it: polygon p's corners are corners[first[p]:first[p+1]].
@(private = "file")
Poly_Mesh :: struct {
	positions: []Vec3,
	first:     []u32,
	corners:   []u32,
}

// Per vertex its polygons, as vertex_faces does for triangles.
@(private = "file")
Vert_Polys :: struct {
	offsets: []u32,
	polys:   []u32,
}

@(private = "file")
vert_polys :: proc(m: Poly_Mesh, allocator := context.temp_allocator) -> Vert_Polys {
	n := len(m.positions)
	vp := Vert_Polys{offsets = make([]u32, n + 1, allocator), polys = make([]u32, len(m.corners), allocator)}
	for c in m.corners do vp.offsets[c + 1] += 1
	for i in 0 ..< n do vp.offsets[i + 1] += vp.offsets[i]
	at := make([]u32, n, context.temp_allocator)
	copy(at, vp.offsets[:n])
	for p in 0 ..< len(m.first) - 1 {
		for c in m.corners[m.first[p]:m.first[p + 1]] {
			vp.polys[at[c]] = u32(p)
			at[c] += 1
		}
	}
	return vp
}

@(private = "file")
corners_of :: #force_inline proc(m: Poly_Mesh, p: u32) -> []u32 {return m.corners[m.first[p]:m.first[p + 1]]}

// The corner after v in polygon p, and the one before it.
@(private = "file")
around :: proc(m: Poly_Mesh, p, v: u32) -> (next, prev: u32) {
	c := corners_of(m, p)
	for x, i in c do if x == v do return c[(i + 1) % len(c)], c[(i + len(c) - 1) % len(c)]
	return max(u32), max(u32)
}

// The polygon holding the directed edge a -> b, or max(u32).
@(private = "file")
poly_with :: proc(m: Poly_Mesh, vp: Vert_Polys, a, b: u32) -> u32 {
	for p in vp.polys[vp.offsets[a]:vp.offsets[a + 1]] {
		if next, _ := around(m, p, a); next == b do return p
	}
	return max(u32)
}

// Whether every edge is in exactly two polygons, once each way, and every polygon has
// `size` corners: the closed meshes a level is made of.
@(private = "file")
closed_of :: proc(m: Poly_Mesh, vp: Vert_Polys, size: int) -> bool {
	if len(m.first) < 2 do return false
	for p in 0 ..< len(m.first) - 1 {
		c := corners_of(m, u32(p))
		if len(c) != size do return false
		for x, i in c {
			y := c[(i + 1) % len(c)]
			if x == y || poly_with(m, vp, y, x) == max(u32) do return false
		}
	}
	return true
}

// One step down of a closed triangle mesh, the inverse of a Loop step; ok is false when the
// mesh is not one.
@(private = "file")
unsub_loop :: proc(m: Poly_Mesh, vp: Vert_Polys) -> (u: Unsub, ok: bool) {
	n := len(m.positions)
	t := context.temp_allocator
	role := make([]Role, n, t)
	ends := make([][2]u32, n, t) // per Edge vertex, its coarse edge's fine ends
	for &e in ends do e = {max(u32), max(u32)}
	valence :: proc(vp: Vert_Polys, v: u32) -> int {return int(vp.offsets[v + 1] - vp.offsets[v])}
	// From an Old vertex o, its neighbours are Edge vertices, and each one's other end
	// is three steps round it.
	walk :: proc(m: Poly_Mesh, vp: Vert_Polys, role: []Role, ends: [][2]u32, seed: u32) -> (set: [dynamic]u32, ok: bool) {
		set = make([dynamic]u32, context.temp_allocator)
		queue := make([dynamic]u32, context.temp_allocator)
		mark :: proc(role: []Role, set: ^[dynamic]u32, v: u32, r: Role) -> bool {
			if role[v] == r do return true
			if role[v] != .Unknown do return false
			role[v] = r
			append(set, v)
			return true
		}
		if !mark(role, &set, seed, .Old) do return set, false
		append(&queue, seed)
		for head := 0; head < len(queue); head += 1 {
			o := queue[head]
			for p in vp.polys[vp.offsets[o]:vp.offsets[o + 1]] {
				e, _ := around(m, p, o)
				if !mark(role, &set, e, .Edge) do return set, false
				if valence(vp, e) != 6 do return set, false
				// Three steps round e from o.
				x := o
				for _ in 0 ..< 3 {
					q := poly_with(m, vp, e, x)
					if q == max(u32) do return set, false
					x, _ = around(m, q, x)
				}
				pair := [2]u32{min(o, x), max(o, x)}
				if ends[e][0] != max(u32) && ends[e] != pair do return set, false
				ends[e] = pair
				if role[x] == .Unknown {
					if !mark(role, &set, x, .Old) do return set, false
					append(&queue, x)
				} else if role[x] != .Old do return set, false
			}
		}
		return set, true
	}
	// A vertex without six triangles round it is an old one, so those seed first; on an
	// island as regular as a torus, where every vertex has six, v or one of its
	// neighbours is.
	for pass in 0 ..< 2 do for v in 0 ..< n {
		if role[v] != .Unknown || (pass == 0 && valence(vp, u32(v)) == 6) do continue
		seeds := make([dynamic]u32, t)
		append(&seeds, u32(v))
		if pass == 1 {
			for p in vp.polys[vp.offsets[v]:vp.offsets[v + 1]] {
				e, _ := around(m, p, u32(v))
				append(&seeds, e)
			}
		}
		found := false
		for seed in seeds {
			set, good := walk(m, vp, role, ends, seed)
			if good {
				found = true
				break
			}
			for x in set {
				role[x] = .Unknown
				ends[x] = {max(u32), max(u32)}
			}
		}
		if !found do return {}, false
	}
	// Every vertex is placed; the triangles must be one old corner and two edge points, or
	// three edge points.
	coarse := make([]u32, n, t)
	olds := 0
	for r, v in role {
		if r == .Unknown do return {}, false
		if r == .Old {
			coarse[v] = u32(olds)
			olds += 1
		}
	}
	tris := len(m.first) - 1
	if tris % 4 != 0 do return {}, false
	first := make([dynamic]u32, 0, tris / 4 + 1)
	corners := make([dynamic]u32, 0, 3 * (tris / 4))
	append(&first, 0)
	other :: proc(ends: [2]u32, o: u32) -> u32 {return ends[1] if ends[0] == o else ends[0]}
	centres := 0
	for p in 0 ..< tris {
		c := corners_of(m, u32(p))
		k := -1
		count := 0
		for x, i in c do if role[x] == .Old {
			k = i
			count += 1
		}
		if count == 0 {
			centres += 1
			continue
		}
		if count != 1 do return {}, false
		o, e1, e2 := c[k], c[(k + 1) % 3], c[(k + 2) % 3]
		a, b, d := coarse[o], coarse[other(ends[e1], o)], coarse[other(ends[e2], o)]
		// Each coarse triangle shows up at its three corners: kept at its lowest.
		if a > b || a > d do continue
		append(&corners, a, b, d)
		append(&first, u32(len(corners)))
	}
	if centres != tris / 4 || len(first) - 1 != tris / 4 {
		delete(first)
		delete(corners)
		return {}, false
	}
	u.first, u.corners = first[:], corners[:]
	u.vert_fine = make([]u32, olds)
	for r, v in role do if r == .Old do u.vert_fine[coarse[v]] = u32(v)
	u.edge_keys, u.edge_fine = edge_table(role, ends, coarse)
	return u, true
}

// The coarse edges as sorted keys, and per key its fine vertex.
@(private = "file")
edge_table :: proc(role: []Role, ends: [][2]u32, coarse: []u32) -> (keys: []u64, fine: []u32) {
	Pair :: struct {
		key:  u64,
		fine: u32,
	}
	pairs := make([dynamic]Pair, context.temp_allocator)
	for r, v in role do if r == .Edge do append(&pairs, Pair{sharp_key(coarse[ends[v][0]], coarse[ends[v][1]]), u32(v)})
	slice.sort_by(pairs[:], proc(a, b: Pair) -> bool {return a.key < b.key})
	keys = make([]u64, len(pairs))
	fine = make([]u32, len(pairs))
	for p, i in pairs do keys[i], fine[i] = p.key, p.fine
	return
}

// One step down of a closed quad mesh, the inverse of a Catmull-Clark step; ok is false
// when the mesh is not one.
@(private = "file")
unsub_cc :: proc(m: Poly_Mesh, vp: Vert_Polys, face_first: bool) -> (u: Unsub, ok: bool) {
	n := len(m.positions)
	quads := len(m.first) - 1
	t := context.temp_allocator
	role := make([]Role, n, t)
	// Per quad, which corner is its old vertex (opposite its face point), 4 while unknown.
	old_at := make([]u8, quads, t)
	slice.fill(old_at, 4)
	roles_of :: proc(k: u8) -> [4]Role {
		r: [4]Role
		r[k] = .Old
		r[(k + 2) % 4] = .Face
		r[(k + 1) % 4], r[(k + 3) % 4] = .Edge, .Edge
		return r
	}
	walk :: proc(m: Poly_Mesh, vp: Vert_Polys, role: []Role, old_at: []u8, seed: u32, k: u8) -> (vs, qs: [dynamic]u32, ok: bool) {
		vs = make([dynamic]u32, context.temp_allocator)
		qs = make([dynamic]u32, context.temp_allocator)
		place :: proc(m: Poly_Mesh, role: []Role, old_at: []u8, vs, qs: ^[dynamic]u32, q: u32, k: u8) -> bool {
			if old_at[q] != 4 do return old_at[q] == k
			old_at[q] = k
			append(qs, q)
			r := roles_of(k)
			for x, i in corners_of(m, q) {
				if role[x] == .Unknown {
					role[x] = r[i]
					append(vs, x)
				} else if role[x] != r[i] do return false
			}
			return true
		}
		if !place(m, role, old_at, &vs, &qs, seed, k) do return vs, qs, false
		for head := 0; head < len(qs); head += 1 {
			q := qs[head]
			c := corners_of(m, q)
			for i in 0 ..< 4 {
				a, b := c[i], c[(i + 1) % 4]
				other := poly_with(m, vp, b, a)
				if other == max(u32) do return vs, qs, false
				// The neighbour's old corner: a shared old vertex, or the one opposite a
				// shared face point.
				oc := corners_of(m, other)
				kk := u8(4)
				for x, j in oc {
					if x == a || x == b {
						if role[x] == .Old do kk = u8(j)
						if role[x] == .Face do kk = u8((j + 2) % 4)
					}
				}
				if kk == 4 || !place(m, role, old_at, &vs, &qs, other, kk) do return vs, qs, false
			}
		}
		return vs, qs, true
	}
	for q in 0 ..< quads {
		if old_at[q] != 4 do continue
		// An old vertex or face point is the corner with other than four quads round it;
		// failing one, each corner of q is tried as the old one.
		tries := make([dynamic]u8, t)
		c := corners_of(m, u32(q))
		for x, i in c do if vp.offsets[x + 1] - vp.offsets[x] != 4 {
			if face_first do append(&tries, u8((i + 2) % 4), u8(i))
			else do append(&tries, u8(i), u8((i + 2) % 4))
			break
		}
		if len(tries) == 0 do append(&tries, 0, 1, 2, 3)
		found := false
		for k in tries {
			vs, qs, good := walk(m, vp, role, old_at, u32(q), k)
			if good {
				found = true
				break
			}
			for x in vs do role[x] = .Unknown
			for x in qs do old_at[x] = 4
		}
		if !found do return {}, false
	}
	coarse := make([]u32, n, t)
	olds, faces := 0, 0
	for r, v in role {
		#partial switch r {
		case .Unknown: return {}, false
		case .Old:
			coarse[v] = u32(olds)
			olds += 1
		case .Face:
			faces += 1
		}
	}
	// Each coarse polygon round its face point: from a quad (old, e1, face, e2) to the one
	// holding face -> e1, whose old corner is the polygon's next.
	first := make([dynamic]u32, 0, faces + 1)
	corners := make([dynamic]u32, 0, quads)
	face_fine := make([dynamic]u32, 0, faces)
	append(&first, 0)
	for r, f in role {
		if r != .Face do continue
		start := vp.polys[vp.offsets[f]]
		q := start
		for {
			c := corners_of(m, q)
			k := old_at[q]
			append(&corners, coarse[c[k]])
			e1 := c[(k + 1) % 4]
			q = poly_with(m, vp, u32(f), e1)
			if q == max(u32) || len(corners) > quads {
				delete(first)
				delete(corners)
				delete(face_fine)
				return {}, false
			}
			if q == start do break
		}
		append(&first, u32(len(corners)))
		append(&face_fine, u32(f))
	}
	if len(corners) != quads {
		delete(first)
		delete(corners)
		delete(face_fine)
		return {}, false
	}
	// Each edge point's ends: its two old neighbours.
	ends := make([][2]u32, n, t)
	for r, v in role {
		if r != .Edge do continue
		got := 0
		for q in vp.polys[vp.offsets[v]:vp.offsets[v + 1]] {
			next, prev := around(m, q, u32(v))
			for x in ([2]u32{next, prev}) do if role[x] == .Old && (got == 0 || ends[v][0] != x) && got < 2 {
				ends[v][got] = x
				got += 1
			}
		}
		if got != 2 {
			delete(first)
			delete(corners)
			delete(face_fine)
			return {}, false
		}
	}
	u.quads = true
	u.first, u.corners, u.face_fine = first[:], corners[:], face_fine[:]
	u.vert_fine = make([]u32, olds)
	for r, v in role do if r == .Old do u.vert_fine[coarse[v]] = u32(v)
	u.edge_keys, u.edge_fine = edge_table(role, ends, coarse)
	return u, true
}

// Where the coarse vertices go: those whose one subdivision step lands each old vertex
// where the fine mesh has it, found by moving each by what its step misses by, forty
// times over (each round removes most of the miss: a step's vertex rule weighs a vertex
// at least a quarter, its neighbours the rest).
@(private = "file")
unsub_place :: proc(u: ^Unsub, fine: []Vec3) {
	c := Poly_Mesh{first = u.first, corners = u.corners}
	nv := len(u.vert_fine)
	p := make([]Vec3, nv)
	for v, i in u.vert_fine do p[i] = fine[v]
	c.positions = p
	vp := vert_polys(c)
	step := make([]Vec3, nv, context.temp_allocator)
	for _ in 0 ..< 40 {
		for v in 0 ..< nv {
			polys := vp.polys[vp.offsets[v]:vp.offsets[v + 1]]
			k := f32(len(polys))
			if u.quads {
				// Catmull-Clark: (F + 2R + (n - 3)P) / n.
				face, mid: Vec3
				for f in polys {
					cs := corners_of(c, f)
					centre: Vec3
					for x in cs do centre += p[x]
					face += centre / f32(len(cs))
					next, _ := around(c, f, u32(v))
					mid += (p[v] + p[next]) / 2
				}
				step[v] = (face / k + 2 * mid / k + (k - 3) * p[v]) / k
			} else {
				// Loop: (1 - nβ)P + β Σ neighbours.
				beta := loop_beta(len(polys))
				sum: Vec3
				for f in polys {
					next, _ := around(c, f, u32(v))
					sum += p[next]
				}
				step[v] = (1 - k * beta) * p[v] + beta * sum
			}
		}
		for v in 0 ..< nv do p[v] += fine[u.vert_fine[v]] - step[v]
	}
	u.positions = p
}

// How far, all told, the middles of a Catmull-Clark step's placed polygons are from the
// face points the fine mesh has for them (placing them first).
@(private = "file")
face_miss :: proc(u: ^Unsub, fine: []Vec3) -> (miss: f32) {
	if u.positions == nil do unsub_place(u, fine)
	for f in 0 ..< len(u.first) - 1 {
		centre: Vec3
		cs := u.corners[u.first[f]:u.first[f + 1]]
		for c in cs do centre += u.positions[c]
		miss += linalg.length(centre / f32(len(cs)) - fine[u.face_fine[f]])
	}
	return
}

@(private = "file")
unsub_free :: proc(u: ^Unsub) {
	delete(u.positions)
	delete(u.first)
	delete(u.corners)
	delete(u.vert_fine)
	delete(u.edge_keys)
	delete(u.edge_fine)
	delete(u.face_fine)
}

// Gives `l` the levels `positions` and its polygons (`first`, `corners`: all triangles,
// or all quads) were subdivided from, at most `most` of them below, with the mesh itself
// as the top level, exactly, and the top level current. Returns how many levels are
// below the top and, per vertex of the top level, the vertex of `positions` it is; none
// (and `l` left zero) when the mesh is not closed or not the result of a Loop or
// Catmull-Clark step. A Catmull-Clark chain gives the base its polygons, so its levels
// are made by Catmull-Clark as a cage's are.
levels_rebuild :: proc(l: ^Levels, positions: []Vec3, first, corners: []u32, pool: ^jobs.Pool, most := MAX_LEVELS - 1, node_triangles: u32 = NODE_TRIANGLES, allocator := context.allocator) -> (below: int, from: []u32) {
	if len(first) < 2 do return 0, nil
	chain := make([dynamic]Unsub, context.temp_allocator)
	defer for &u in chain do unsub_free(&u)
	cur := Poly_Mesh{positions, first, corners}
	size := int(first[1] - first[0])
	if size != 3 && size != 4 do return 0, nil
	for len(chain) < most {
		vp := vert_polys(cur)
		// One rule all the way down: a Catmull-Clark step's coarse polygons go down
		// another only while they are all quads.
		if !closed_of(cur, vp, size) do break
		u: Unsub
		ok: bool
		if size == 3 {
			u, ok = unsub_loop(cur, vp)
		} else {
			// A Catmull-Clark step's vertex points and face points could swap places as far
			// as the topology goes (the step of a mesh and of its dual join alike): of the two
			// readings, the one whose polygons' middles land on the face points is the step.
			u, ok = unsub_cc(cur, vp, false)
			if dual, dual_ok := unsub_cc(cur, vp, true); dual_ok {
				if !ok || face_miss(&dual, cur.positions) < face_miss(&u, cur.positions) {
					if ok do unsub_free(&u)
					u, ok = dual, true
				} else do unsub_free(&dual)
			}
		}
		if !ok do break
		// A coarse mesh of fewer than four polygons encloses nothing.
		if len(u.first) - 1 < 4 {
			unsub_free(&u)
			break
		}
		if u.positions == nil do unsub_place(&u, cur.positions)
		append(&chain, u)
		cur = {u.positions, u.first, u.corners}
	}
	if len(chain) == 0 do return 0, nil
	steps := len(chain)
	base := &chain[steps - 1]
	quads := base.quads

	// The base: its polygons fanned into triangles.
	nv := len(base.positions)
	nf := len(base.first) - 1
	mesh: geom.Mesh
	mesh.positions = make([dynamic]Vec3, nv, allocator)
	copy(mesh.positions[:], base.positions)
	mesh.normals = make([dynamic]Vec3, nv, allocator)
	mesh.indices = make([dynamic]u32, 0, 3 * (len(base.corners) - 2 * nf), allocator)
	fan_poly := make([dynamic]u32, 0, len(base.corners) - 2 * nf, context.temp_allocator)
	for f in 0 ..< nf {
		c := base.corners[base.first[f]:base.first[f + 1]]
		for k in 1 ..< len(c) - 1 {
			append(&mesh.indices, c[0], c[k], c[k + 1])
			append(&fan_poly, u32(f))
		}
	}
	geom.mesh_recompute_normals(&mesh)
	old_to_new := make([]u32, nv, context.temp_allocator)
	tri_from := make([]u32, len(fan_poly), context.temp_allocator)
	levels_init(l, mesh, pool, node_triangles, old_to_new, tri_from, allocator)
	fail :: proc(l: ^Levels) -> (int, []u32) {
		levels_destroy(l)
		l^ = {}
		return 0, nil
	}
	if quads {
		polys := Polys {
			first    = slice.clone(base.first, allocator),
			corners  = make([]u32, len(base.corners), allocator),
			tri_poly = make([]u32, len(tri_from), allocator),
		}
		for c, i in base.corners do polys.corners[i] = old_to_new[c]
		for old, t in tri_from do polys.tri_poly[t] = fan_poly[old]
		if !levels_set_polys(l, polys, {}, .Smooth) do return fail(l)
	}
	// Per vertex of the level just built, the chain's vertex at that step.
	chain_of := make([]u32, nv, context.temp_allocator)
	for c, old in old_to_new do chain_of[c] = u32(old)
	for j in 1 ..= steps {
		stage := &chain[steps - j]
		fine := positions if j == steps else chain[steps - j - 1].positions
		// Its positions are set below rather than edited: nothing to carry up or down.
		sculptor_clear_edited(&l.levels[j - 1].sculptor)
		if !levels_subdivide(l) do return fail(l)
		lv := l.levels[j]
		if len(lv.mesh.positions) != len(fine) do return fail(l)
		coarse := Poly_Mesh{stage.positions, stage.first, stage.corners}
		cvp := vert_polys(coarse)
		next := make([]u32, len(fine), context.temp_allocator)
		seen := make([]bool, len(fine), context.temp_allocator)
		for p, u in lv.parents {
			f := max(u32)
			switch p[2] {
			case EVEN:
				f = stage.vert_fine[chain_of[p[0]]]
			case FACE:
				// The polygon with these two corners two apart.
				c0, c2 := chain_of[p[0]], chain_of[p[1]]
				search: for q in cvp.polys[cvp.offsets[c0]:cvp.offsets[c0 + 1]] {
					cs := corners_of(coarse, q)
					for x, i in cs do if x == c0 && cs[(i + 2) % len(cs)] == c2 {
						f = stage.face_fine[q]
						break search
					}
				}
			case:
				if i, found := slice.binary_search(stage.edge_keys, sharp_key(chain_of[p[0]], chain_of[p[1]])); found do f = stage.edge_fine[i]
			}
			if f == max(u32) || seen[f] do return fail(l)
			seen[f] = true
			next[u] = f
			lv.mesh.positions[u] = fine[f]
		}
		chain_of = next
	}
	for j in 1 ..= steps {
		lv := l.levels[j]
		all := make([]u32, len(lv.sculptor.nodes), context.temp_allocator)
		for &id, i in all do id = u32(i)
		recode_level(l, j, all, encode = true)
		sculptor_nodes_moved(&lv.sculptor, all)
		_ = sculptor_flush(&lv.sculptor)
	}
	for lv in l.levels do sculptor_clear_edited(&lv.sculptor)
	l.current = steps
	return steps, slice.clone(chain_of, allocator)
}

// Gives the current level of levels levels_rebuild made the mask and colours the mesh had
// (per vertex of that mesh, either nil), through its `from`.
levels_rebuild_take :: proc(l: ^Levels, from: []u32, color: []Color, mask: []u8) {
	s := &l.levels[l.current].sculptor
	if mask != nil {
		mask_ensure(s)
		for f, u in from do s.mask[u] = mask[f]
	}
	if color != nil {
		color_ensure(s)
		for f, u in from do s.color[u] = color[f]
		s.color_edited = true
	}
}
