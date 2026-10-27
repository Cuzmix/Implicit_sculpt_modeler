package geom

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:slice"

import "../jobs"

// Automatic retopology, after ZBrush's ZRemesher in what it gives back: a light mesh of
// quads only, of about the size asked for, lying on the sculpt. The way there is not
// ZRemesher's (whose edge flow follows the surface's curvature, which this does not
// try): the sculpt is decimated by quadric error to half as many triangles as quads are
// wanted, which keeps more of them where the shape bends; neighbouring triangles that
// make a good quad pair up; then every face is cut into quads at its middle and its
// edges' middles (a quad into four, a triangle left alone into three), as a
// Catmull-Clark step cuts, so every face is a quad; last, the vertices relax toward the
// middle of their neighbours along the surface, and each is put back onto the sculpt
// along its normal, so the quads even out without leaving the shape.

// Quads, each four vertex numbers counter-clockwise seen from outside.
Quad_Mesh :: struct {
	positions: []Vec3,
	quads:     [][4]u32,
	// Per quad, whether its triangles meet along corners 1-3 rather than 0-2, as the
	// mesh drawn and sculpted has them (quad_mesh_diagonals); nil: every quad along 0-2.
	// Whatever is rasterized or written as triangles over the quads follows it, so it
	// lies exactly on the surface the viewport shows.
	across:    []bool,
}

// A quad's two triangles as corner numbers (0 to 3), along the diagonal `across` gives;
// the same split quad_split makes.
quad_halves :: proc(q: Quad_Mesh, i: int) -> [2][3]int {
	if q.across != nil && q.across[i] do return {{0, 1, 3}, {1, 2, 3}}
	return {{0, 1, 2}, {0, 2, 3}}
}

// Which diagonal each quad of `q` is split along in the triangle mesh `indices` (whose
// vertices are the quads'), with `faces` that mesh's triangles round each vertex: true
// where corners 0 and 2 share no triangle. A quad whose diagonal cannot be found reads
// as 0-2.
quad_mesh_diagonals :: proc(q: Quad_Mesh, indices: []u32, faces: Vertex_Faces, allocator := context.allocator) -> []bool {
	across := make([]bool, len(q.quads), allocator)
	for f, i in q.quads {
		a, c := f[0], f[2]
		shared := false
		for t in faces.tris[faces.offsets[a]:faces.offsets[a + 1]] {
			tri := indices[3 * t:][:3]
			if tri[0] == c || tri[1] == c || tri[2] == c {
				shared = true
				break
			}
		}
		if !shared {
			b, d := f[1], f[3]
			for t in faces.tris[faces.offsets[b]:faces.offsets[b + 1]] {
				tri := indices[3 * t:][:3]
				if tri[0] == d || tri[1] == d || tri[2] == d {
					across[i] = true
					break
				}
			}
		}
	}
	return across
}

quad_mesh_destroy :: proc(q: ^Quad_Mesh, allocator := context.allocator) {
	delete(q.positions, allocator)
	delete(q.quads, allocator)
	q^ = {}
}

// Relaxation rounds after the cut, each followed by putting the vertices back onto the
// sculpt.
RETOPO_RELAX_ROUNDS :: 12
// Triangle pairs whose quad would have a corner further than this from square, or
// whose triangles meet at a sharper fold, stay apart.
RETOPO_PAIR_MAX_CORNER :: 60 // degrees off 90
RETOPO_PAIR_MAX_FOLD :: 40   // degrees between the triangles' normals

Retopo_Report :: struct {
	decimated:   int, // triangles after decimating
	paired:      int, // of those, triangles that made a quad with a neighbour
	unprojected: int, // vertices no ray put back onto the sculpt in the last round
}

// Quads remeshing `source`, about `wanted` of them, with the sculpt's own `bvh` (over
// `source`'s triangles) to put vertices back onto it. ok is false when there is too
// little to work from (or too much asked: the result would not be lighter).
mesh_retopo :: proc(source: Mesh, bvh: ^Bvh, wanted: int, pool: ^jobs.Pool, allocator := context.allocator) -> (out: Quad_Mesh, report: Retopo_Report, ok: bool) {
	triangles := len(source.indices) / 3
	// About three in four triangles pair: 2 quads from a pair, 3 from a triangle alone.
	goal := max(int(f32(wanted) * 0.45), 8)
	if triangles < 8 || goal >= triangles do return {}, {}, false
	coarse, _, decimated := mesh_decimate(source, goal, pool, context.temp_allocator)
	if !decimated do return {}, {}, false
	report.decimated = len(coarse.indices) / 3

	faces, paired := pair_triangles(coarse.positions[:], coarse.indices[:])
	report.paired = paired
	out = cut_into_quads(coarse.positions[:], faces[:], allocator)
	report.unprojected = relax_onto(&out, source, bvh, RETOPO_RELAX_ROUNDS, pool)
	return out, report, true
}

// A face before the cut: a quad, or a triangle with its fourth corner FACE_NONE.
@(private = "file")
FACE_NONE :: max(u32)

@(private)
retopo_edge_key :: #force_inline proc(a, b: u32) -> u64 {return u64(min(a, b)) << 32 | u64(max(a, b))}

// The triangles, paired into quads where two make a good one, greedily from the best
// pair. Returns the faces (quads first in the order they paired, then the triangles
// left) and how many triangles paired.
@(private = "file")
pair_triangles :: proc(positions: []Vec3, indices: []u32) -> (faces: [dynamic][4]u32, paired: int) {
	count := len(indices) / 3
	Edge :: struct {
		t:    [2]u32,
		uses: u32,
	}
	edges := make(map[u64]Edge, 3 * count, context.temp_allocator)
	for t in 0 ..< count {
		for k in 0 ..< 3 {
			key := retopo_edge_key(indices[3 * t + k], indices[3 * t + (k + 1) % 3])
			e := edges[key]
			if e.uses < 2 do e.t[e.uses] = u32(t)
			e.uses += 1
			edges[key] = e
		}
	}
	tri_normal :: proc(positions: []Vec3, indices: []u32, t: u32) -> Vec3 {
		p0, p1, p2 := positions[indices[3 * t]], positions[indices[3 * t + 1]], positions[indices[3 * t + 2]]
		return linalg.normalize0(linalg.cross(p1 - p0, p2 - p0))
	}
	// The quad two triangles sharing an edge make, counter-clockwise: t1 = (a, b, c)
	// and t2 = (b, a, d) give (a, d, b, c).
	quad_of :: proc(indices: []u32, t1, t2: u32) -> (q: [4]u32, ok: bool) {
		for k in 0 ..< 3 {
			a, b, c := indices[3 * t1 + u32(k)], indices[3 * t1 + u32(k + 1) % 3], indices[3 * t1 + u32(k + 2) % 3]
			for j in 0 ..< 3 {
				if indices[3 * t2 + u32(j)] == b && indices[3 * t2 + u32(j + 1) % 3] == a {
					return {a, indices[3 * t2 + u32(j + 2) % 3], b, c}, true
				}
			}
		}
		return {}, false
	}
	Candidate :: struct {
		score:  f32,
		t1, t2: u32,
		quad:   [4]u32,
	}
	candidates := make([dynamic]Candidate, 0, count * 3 / 2, context.temp_allocator)
	for _, e in edges {
		if e.uses != 2 do continue
		q, shared := quad_of(indices, e.t[0], e.t[1])
		if !shared do continue
		fold := math.to_degrees(math.acos(clamp(linalg.dot(tri_normal(positions, indices, e.t[0]), tri_normal(positions, indices, e.t[1])), -1, 1)))
		if fold > RETOPO_PAIR_MAX_FOLD do continue
		worst: f32
		for k in 0 ..< 4 {
			p := positions[q[k]]
			u := linalg.normalize0(positions[q[(k + 1) % 4]] - p)
			v := linalg.normalize0(positions[q[(k + 3) % 4]] - p)
			worst = max(worst, abs(math.to_degrees(math.acos(clamp(linalg.dot(u, v), -1, 1))) - 90))
		}
		if worst > RETOPO_PAIR_MAX_CORNER do continue
		append(&candidates, Candidate{worst + 0.5 * fold, min(e.t[0], e.t[1]), max(e.t[0], e.t[1]), q})
	}
	// Map order is not fixed: the sort makes the result the same every run.
	slice.sort_by(candidates[:], proc(a, b: Candidate) -> bool {
		if a.score != b.score do return a.score < b.score
		if a.t1 != b.t1 do return a.t1 < b.t1
		return a.t2 < b.t2
	})
	used := make([]bool, count, context.temp_allocator)
	faces = make([dynamic][4]u32, 0, count, context.temp_allocator)
	for c in candidates {
		if used[c.t1] || used[c.t2] do continue
		used[c.t1], used[c.t2] = true, true
		append(&faces, c.quad)
		paired += 2
	}
	for t in 0 ..< count {
		if !used[t] do append(&faces, [4]u32{indices[3 * t], indices[3 * t + 1], indices[3 * t + 2], FACE_NONE})
	}
	return
}

// Every face cut into quads at its middle and its edges' middles: a quad into four,
// a triangle into three. The new vertices sit at the middles, off the surface until
// relax_onto puts them back.
@(private = "file")
cut_into_quads :: proc(positions: []Vec3, faces: [][4]u32, allocator: runtime.Allocator) -> (out: Quad_Mesh) {
	points := make([dynamic]Vec3, 0, len(positions) + 3 * len(faces), allocator)
	quads := make([dynamic][4]u32, 0, 4 * len(faces), allocator)
	append(&points, ..positions)
	middles := make(map[u64]u32, 2 * len(faces), context.temp_allocator)
	middle :: proc(points: ^[dynamic]Vec3, middles: ^map[u64]u32, a, b: u32) -> u32 {
		key := retopo_edge_key(a, b)
		if m, found := middles[key]; found do return m
		m := u32(len(points))
		append(points, 0.5 * (points[a] + points[b]))
		middles[key] = m
		return m
	}
	for f in faces {
		n := 3 if f[3] == FACE_NONE else 4
		centre: Vec3
		for k in 0 ..< n do centre += positions[f[k]]
		c := u32(len(points))
		append(&points, centre / f32(n))
		for k in 0 ..< n {
			next := middle(&points, &middles, f[k], f[(k + 1) % n])
			prev := middle(&points, &middles, f[(k + n - 1) % n], f[k])
			append(&quads, [4]u32{f[k], next, c, prev})
		}
	}
	return {positions = points[:], quads = quads[:]}
}

// Normals of a quad mesh's vertices: each the sum of its quads' diagonal cross
// products (twice the quad's area along its normal), normalized.
quad_mesh_normals :: proc(q: Quad_Mesh, allocator := context.allocator) -> []Vec3 {
	normals := make([]Vec3, len(q.positions), allocator)
	for f in q.quads {
		n := linalg.cross(q.positions[f[2]] - q.positions[f[0]], q.positions[f[3]] - q.positions[f[1]])
		for v in f do normals[v] += n
	}
	for &n in normals do n = linalg.normalize0(n)
	return normals
}

// Rounds of relaxing each vertex toward the middle of its neighbours along the surface,
// each followed by putting every vertex back onto `source` along its normal (the nearer
// hit of a ray each way, at most a few edges away). Border vertices of an open mesh
// stay where they are. Returns how many vertices the last round found no surface for.
@(private = "file")
relax_onto :: proc(q: ^Quad_Mesh, source: Mesh, bvh: ^Bvh, rounds: int, pool: ^jobs.Pool) -> (missed: int) {
	n := len(q.positions)
	// Neighbours along quad edges, in compressed rows.
	Pair :: struct {
		a, b: u32,
	}
	pairs := make([dynamic]Pair, 0, 8 * len(q.quads), context.temp_allocator)
	uses := make(map[u64]u32, 2 * len(q.quads), context.temp_allocator)
	for f in q.quads {
		for k in 0 ..< 4 {
			a, b := f[k], f[(k + 1) % 4]
			uses[retopo_edge_key(a, b)] += 1
			append(&pairs, Pair{a, b}, Pair{b, a})
		}
	}
	border := make([]bool, n, context.temp_allocator)
	for key, count in uses do if count == 1 {
		border[key >> 32] = true
		border[key & 0xffff_ffff] = true
	}
	slice.sort_by(pairs[:], proc(x, y: Pair) -> bool {return x.a < y.a || (x.a == y.a && x.b < y.b)})
	first := make([]u32, n + 1, context.temp_allocator)
	near := make([dynamic]u32, 0, len(pairs) / 2, context.temp_allocator)
	for p, i in pairs {
		if i > 0 && pairs[i - 1] == p do continue // each edge twice, once from each quad
		append(&near, p.b)
		first[p.a + 1] = u32(len(near))
	}
	for v in 1 ..= n do first[v] = max(first[v], first[v - 1])

	length: f32
	for f in q.quads do length += linalg.length(q.positions[f[1]] - q.positions[f[0]])
	length /= f32(max(len(q.quads), 1))

	Job :: struct {
		positions, next: []Vec3,
		normals:         []Vec3,
		first, near:     []u32,
		border:          []bool,
		source:          Mesh,
		bvh:             Bvh,
		reach:           f32,
		relax:           bool,
		missed:          []bool,
	}
	next := make([]Vec3, n, context.temp_allocator)
	missed_at := make([]bool, n, context.temp_allocator)
	job := Job{q.positions[:], next, nil, first, near[:], border, source, bvh^, 3 * length, false, missed_at}
	// Once first to bring the middles of the cut onto the surface, then each round.
	for round in 0 ..= rounds {
		job.normals = quad_mesh_normals(q^, context.temp_allocator)
		job.relax = round > 0
		jobs.parallel_ranges(pool, n, &job, proc(data: rawptr, lo, hi: int) {
			job := cast(^Job)data
			stack := make([dynamic]u32, 0, 64, runtime.heap_allocator())
			defer delete(stack)
			for v in lo ..< hi {
				p := job.positions[v]
				normal := job.normals[v]
				job.missed[v] = false
				if job.border[v] {
					job.next[v] = p
					continue
				}
				if job.relax {
					avg: Vec3
					ns := job.near[job.first[v]:job.first[v + 1]]
					for u in ns do avg += job.positions[u]
					if len(ns) > 0 {
						d := avg / f32(len(ns)) - p
						d -= linalg.dot(d, normal) * normal
						p += 0.5 * d
					}
				}
				if normal == {} {
					job.next[v] = p
					continue
				}
				out_t, _, out_hit := bvh_raycast_with(job.bvh, job.source, p, normal, job.reach, &stack)
				in_t, _, in_hit := bvh_raycast_with(job.bvh, job.source, p, -normal, job.reach, &stack)
				switch {
				case out_hit && (!in_hit || out_t <= in_t): p += out_t * normal
				case in_hit:                                p -= in_t * normal
				case:                                       job.missed[v] = true
				}
				job.next[v] = p
			}
		}, RANGE_GRAIN)
		copy(q.positions[:], next)
	}
	for m in missed_at do if m do missed += 1
	return
}

// The quads as triangles, two each (quad k gives triangles 2k and 2k + 1, split along
// its shorter diagonal), with zero normals.
quad_mesh_triangulate :: proc(q: Quad_Mesh, allocator := context.allocator) -> (m: Mesh) {
	m.positions = make([dynamic]Vec3, len(q.positions), allocator)
	copy(m.positions[:], q.positions[:])
	m.normals = make([dynamic]Vec3, len(q.positions), allocator)
	m.indices = make([dynamic]u32, 0, 6 * len(q.quads), allocator)
	for f in q.quads {
		t := quad_split(q.positions[:], f)
		append(&m.indices, ..t[:])
	}
	return
}

// The two triangles a quad is drawn as: along its shorter diagonal.
quad_split :: proc(positions: []Vec3, f: [4]u32) -> [6]u32 {
	if linalg.length2(positions[f[2]] - positions[f[0]]) <= linalg.length2(positions[f[3]] - positions[f[1]]) {
		return {f[0], f[1], f[2], f[0], f[2], f[3]}
	}
	return {f[0], f[1], f[3], f[1], f[2], f[3]}
}

// Appends the quads to `out` as OBJ text: `v` lines (each position as `scale * p +
// offset`), with `uvs` (per quad corner) a `vt` line a corner and `f` lines naming both,
// else plain `f` lines.
quad_mesh_write_obj :: proc(out: ^[dynamic]u8, positions: []Vec3, quads: [][4]u32, uvs: [][4][2]f32 = nil, scale: f32 = 1, offset := Vec3{}) {
	tmp: [32]u8
	number :: proc(out: ^[dynamic]u8, tmp: []u8, x: f32) {
		append(out, ' ')
		append(out, ..tmp[:format_f32(tmp, x)])
	}
	for p in positions {
		q := p * scale + offset if scale != 1 || offset != {} else p
		append(out, 'v')
		for x in q do number(out, tmp[:], x)
		append(out, '\n')
	}
	if uvs != nil {
		for corners in uvs {
			for t in corners {
				append(out, "vt")
				number(out, tmp[:], t.x)
				number(out, tmp[:], t.y)
				append(out, '\n')
			}
		}
	}
	for f, i in quads {
		append(out, 'f')
		for v, k in f {
			append(out, ' ')
			append(out, ..tmp[:format_u32(tmp[:], v + 1)])
			if uvs != nil {
				append(out, '/')
				append(out, ..tmp[:format_u32(tmp[:], u32(4 * i + k + 1))])
			}
		}
		append(out, '\n')
	}
}
