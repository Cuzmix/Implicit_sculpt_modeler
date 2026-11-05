package quadmesh

import "base:runtime"
import "core:math"

import "../jobs"
import "../sparse"

// The frame field in Odin (Core.Odin): what qm_stage_cover works out in C++ before the
// cover itself (AutoRemesher's FrameField, SingularitySimplifier and Parameterizer's sizes,
// MIT, by Jeremy Hu, whose rules this follows), handed to the cover as a Field. Each
// triangle's frame is a direction in its plane, kept while solving as the four-fold
// periodic pair (cos 4θ, sin 4θ) of its angle θ from the triangle's own basis, so the four
// directions of a cross are one value. A triangle beside a sharp edge, a feature edge or
// the border is locked to that edge; a curved one is pulled toward its curvature's
// principal direction as firmly as the curvature is certain, and a guided one toward its
// guide; every two triangles sharing an edge are pulled toward agreeing across it, their
// pairs transported by the turn between their bases (and by the density's turn, when a
// density scales the metric). That least squares problem is factored once (src/sparse: the
// AMD order and the LDLᵀ) and solved five times, each time aiming the curvature's pull at
// the last solution's own direction, so only the smoothness decides where the field turns.
// Singular vertices of opposite charge lying close are then cancelled in pairs
// (singular.odin), and each triangle's quad size and stretch worked out from the curvature
// (Adaptivity) and the field (Anisotropy). None of it depends on the cover's scaling, so
// the driver solves it once for all of an island's covers, where the C++ solves it again
// for each. The per-triangle loops run on the pool, each writing its own triangle's
// values, so any thread count gives the same field, bit for bit.

// A frame field and the sizes the cover is asked, one a triangle.
Field :: struct {
	directions:      [][3]f64, // a unit vector in the triangle's plane: one of its frame's four directions
	sizes:           [][3]f64, // the quad size relative to the rest, and the stretch along the direction and across it
	singular_solved: int, // the field's singular vertices as solved
	singular:        int, // and once the clean-up cancelled what pairs it could
	smoothness:      f64, // the mean over the inner edges of 1 - cos 4(the frames' turn across the edge): 0 for a field that never turns
}

field_destroy :: proc(f: ^Field) {
	heap := runtime.heap_allocator()
	delete(f.directions, heap)
	delete(f.sizes, heap)
	f^ = {}
}

// The solve's rounds, each aiming the curvature's pull at the last solution.
@(private = "file")
FIELD_ROUNDS :: 5

// How far (degrees) two feature edges of one triangle may be from along or across each
// other for the triangle to lock to them; between, the field bends round the corner.
@(private = "file")
FEATURE_TOLERANCE :: 15.0

// The ridge on the normal matrix, relative to its mean diagonal (ConstrainedLeastSquares's).
@(private = "file")
RIDGE :: 1e-10

// The stretch the anisotropy may ask at most, a quad's long side over its short one.
@(private = "file")
MAX_ASPECT :: 2.3

// The curvature's smoothing passes over the vertices before the anisotropy reads it.
@(private = "file")
ANISOTROPY_PASSES :: 12

// ---- The surface ------------------------------------------------------------------------

// A triangle mesh's corners and what the field reads of them: corner c is corner c % 3 of
// triangle c / 3, and its edge runs from its vertex to the next corner's.
Surface :: struct {
	positions:  [][3]f64, // borrowed
	triangles:  [][3]u32, // borrowed
	opp:        []u32, // per corner: the corner whose edge runs the other way, NONE on the border
	first:      []u32, // vertex v's corners are corners[first[v]:first[v + 1]], ascending
	corners:    []u32,
	normal:     [][3]f64, // per triangle: its unit normal, zero when it has no area
	tangent:    [][3]f64, // per triangle: the basis its angles are measured from, in its plane
	bitangent:  [][3]f64,
	dihedral:   []f64, // per corner: the turn between the normals across its edge, signed, π on the border
	connection: []f64, // per corner: its edge's angle in the other triangle's basis less in its own
	pool:       ^jobs.Pool,
}

surface_build :: proc(positions: [][3]f64, triangles: [][3]u32, pool: ^jobs.Pool) -> (s: Surface) {
	heap := runtime.heap_allocator()
	s.positions, s.triangles, s.pool = positions, triangles, pool
	faces, vertices := len(triangles), len(positions)
	s.opp = corner_opposites(vertices, triangles, heap)
	s.first = make([]u32, vertices + 1, heap)
	for t in triangles do for v in t do s.first[v + 1] += 1
	for v in 0 ..< vertices do s.first[v + 1] += s.first[v]
	s.corners = make([]u32, 3 * faces, heap)
	at := make([]u32, vertices, heap)
	defer delete(at, heap)
	copy(at, s.first[:vertices])
	for t, f in triangles do for k in 0 ..< 3 {
		s.corners[at[t[k]]] = u32(3 * f + k)
		at[t[k]] += 1
	}
	s.normal = make([][3]f64, faces, heap)
	s.tangent = make([][3]f64, faces, heap)
	s.bitangent = make([][3]f64, faces, heap)
	jobs.parallel_ranges(pool, faces, &s, proc(data: rawptr, lo, hi: int) {
		s := cast(^Surface)data
		for f in lo ..< hi {
			t := s.triangles[f]
			a, b, c := s.positions[t[0]], s.positions[t[1]], s.positions[t[2]]
			n := unit_or_zero(cross3(b - a, c - a))
			s.normal[f] = n
			// The basis: the first edge in the triangle's plane, or an axis when the edge
			// runs along the normal (createFacetTangentBasis).
			if length3(n) <= 1e-12 do n = {0, 0, 1}
			e := b - a
			e -= dot3(e, n) * n
			if length3(e) <= 1e-12 {
				e = {1, 0, 0} if abs(n.x) < 0.9 else {0, 1, 0}
				e -= dot3(e, n) * n
			}
			e = unit_or(e, {1, 0, 0})
			s.tangent[f] = e
			s.bitangent[f] = cross3(n, e)
		}
	}, 4096)
	s.dihedral = make([]f64, 3 * faces, heap)
	s.connection = make([]f64, 3 * faces, heap)
	jobs.parallel_ranges(pool, 3 * faces, &s, proc(data: rawptr, lo, hi: int) {
		s := cast(^Surface)data
		for c in lo ..< hi {
			o := s.opp[c]
			if o == NONE {
				s.dihedral[c] = math.PI
				continue
			}
			f, g := c / 3, int(o) / 3
			e := surface_edge(s, u32(c))
			n, m := s.normal[f], s.normal[g]
			sign := -1.0 if dot3(cross3(n, m), e) > 0 else 1.0
			s.dihedral[c] = sign * math.acos(clamp(dot3(n, m), -1, 1))
			s.connection[c] = tangent_angle(s, e, g) - tangent_angle(s, e, f)
		}
	}, 4096)
	return
}

surface_destroy :: proc(s: ^Surface) {
	heap := runtime.heap_allocator()
	delete(s.opp, heap)
	delete(s.first, heap)
	delete(s.corners, heap)
	delete(s.normal, heap)
	delete(s.tangent, heap)
	delete(s.bitangent, heap)
	delete(s.dihedral, heap)
	delete(s.connection, heap)
	s^ = {}
}

@(private)
surface_vertex :: #force_inline proc(s: ^Surface, c: u32) -> u32 {
	return s.triangles[c / 3][c % 3]
}

// Corner c's edge, from its vertex to the next corner's.
@(private)
surface_edge :: #force_inline proc(s: ^Surface, c: u32) -> [3]f64 {
	return s.positions[surface_vertex(s, corner_next(c))] - s.positions[surface_vertex(s, c)]
}

// The angle of `v` in triangle f's basis.
@(private)
tangent_angle :: #force_inline proc(s: ^Surface, v: [3]f64, f: int) -> f64 {
	return math.atan2(dot3(v, s.bitangent[f]), dot3(v, s.tangent[f]))
}

// The triangles round vertex v, from its first corner on, while its fan closes; none for a
// vertex on the border or a fan that does not close (facetsAroundVertex).
@(private)
surface_fan :: proc(s: ^Surface, v: u32, out: ^[dynamic]u32) -> bool {
	clear(out)
	if s.first[v] == s.first[v + 1] do return false
	start := s.corners[s.first[v]]
	c := start
	for {
		if len(out) > len(s.opp) do return false
		append(out, c / 3)
		o := s.opp[c]
		if o == NONE do return false
		c = corner_next(o)
		if surface_vertex(s, c) != v do return false
		if c == start do return true
	}
}

// ---- The stage --------------------------------------------------------------------------

// The isotropic mesh's frame field and sizes: `face_guides` (one a triangle, or nil) are
// the guide curves' pull, `adaptivity` sizes quads by the curvature, `anisotropy` stretches
// them along it, `sharp_degrees` locks the frames beside sharper edges.
odin_field :: proc(iso: Isotropic, face_guides: [][3]f64, adaptivity, anisotropy, sharp_degrees: f64, run: ^Stage_Run, reason: ^Reason, checks: ^Checks) -> (out: Field, err: Stage_Error) {
	heap := runtime.heap_allocator()
	context.allocator = heap
	faces := len(iso.triangles)
	if faces == 0 do return
	if !stage_report(run, 0) do return {}, .Cancelled
	s := surface_build(iso.positions, iso.triangles, run.pool if run != nil else nil)
	defer surface_destroy(&s)
	scale := iso.vertex_scale if len(iso.vertex_scale) == len(iso.positions) else nil
	features := iso.corner_feature if len(iso.corner_feature) == 3 * faces else nil
	guides := face_guides if len(face_guides) == faces else nil

	out.sizes = make([][3]f64, faces)
	field_sizes(&s, scale, adaptivity, out.sizes)
	log_scale: []f64
	defer delete(log_scale)
	if scale != nil {
		log_scale = make([]f64, len(scale))
		for &l, v in log_scale do l = math.ln(max(1e-6, scale[v]))
	}
	if !stage_report(run, 0.1) {
		field_destroy(&out)
		return {}, .Cancelled
	}
	angles, ok := field_solve(&s, sharp_degrees, features, log_scale, guides)
	defer delete(angles)
	if !ok {
		field_destroy(&out)
		reason_set(reason, "frame field solve failed")
		return {}, .Failed
	}
	if !stage_report(run, 0.6) {
		field_destroy(&out)
		return {}, .Cancelled
	}
	// A field solved in a scaled metric keeps its singularities: the pairs beyond the
	// plain field's sit along the size's changes and bring the denser part its loops.
	out.singular_solved, out.singular = singular_simplify(&s, angles, sharp_degrees, features, scale == nil)
	out.directions = make([][3]f64, faces)
	for &d, f in out.directions do d = math.cos(angles[f]) * s.tangent[f] + math.sin(angles[f]) * s.bitangent[f]
	if !stage_report(run, 0.9) {
		field_destroy(&out)
		return {}, .Cancelled
	}
	field_anisotropy(&s, out.directions, anisotropy, out.sizes)
	out.smoothness = field_smoothness(&s, angles)
	checks.field_singular_solved += out.singular_solved
	checks.field_singular += out.singular
	checks.field_smoothness = max(checks.field_smoothness, out.smoothness)
	_ = stage_report(run, 1)
	return out, .None
}

// ---- The sizes ----------------------------------------------------------------------------

// Each triangle's quad size relative to the rest (computeFaceScalingField): smaller where
// the surface bends faster than its mean, by the mean's ratio to the `adaptivity`th power
// within 0.3 and 3, times the density's size at its corners. The bend at a vertex is the
// largest angle between its normal and a neighbour's over their distance.
@(private = "file")
field_sizes :: proc(s: ^Surface, scale: []f64, adaptivity: f64, sizes: [][3]f64) {
	heap := runtime.heap_allocator()
	for &z in sizes do z = {1, 1, 1}
	vertices := len(s.positions)
	if adaptivity > 0 && vertices > 0 {
		normals := make([][3]f64, vertices, heap)
		defer delete(normals, heap)
		for t, f in s.triangles do for v in t do normals[v] += s.normal[f]
		for &n in normals do n = unit_or_keep(n)
		bend := make([]f64, vertices, heap)
		defer delete(bend, heap)
		for t in s.triangles do for k in 0 ..< 3 {
			a, b := t[k], t[(k + 1) % 3]
			distance := length3(s.positions[b] - s.positions[a])
			if distance <= 0 do continue
			curvature := math.acos(clamp(dot3(normals[a], normals[b]), -1, 1)) / distance
			bend[a] = max(bend[a], curvature)
			bend[b] = max(bend[b], curvature)
		}
		sum := f64(0)
		for b in bend do sum += b
		mean := sum / f64(vertices)
		if mean > 0 {
			for t, f in s.triangles {
				ratio := max((bend[t[0]] + bend[t[1]] + bend[t[2]]) / 3 / mean, 1e-3)
				sizes[f][0] = clamp(math.pow(ratio, -adaptivity), 0.3, 3.0)
			}
		}
	}
	if scale != nil do for t, f in s.triangles do sizes[f][0] *= max(1e-6, (scale[t[0]] + scale[t[1]] + scale[t[2]]) / 3)
}

// Each triangle's stretch (computeFaceAnisotropyField): the curvature tensor smoothed over
// the vertices, read along the field's direction and across it, the quad made longer the
// way the surface bends less, by the ratio's fourth root to the `anisotropy`th power,
// at most MAX_ASPECT long side over short.
@(private = "file")
field_anisotropy :: proc(s: ^Surface, directions: [][3]f64, anisotropy: f64, sizes: [][3]f64) {
	if anisotropy <= 0 || MAX_ASPECT <= 1 do return
	heap := runtime.heap_allocator()
	vertices, faces := len(s.positions), len(s.triangles)
	w := Anisotropy_Work{s, make([][6]f64, vertices, heap), make([][6]f64, vertices, heap)}
	defer delete(w.tensor, heap)
	defer delete(w.smooth, heap)
	for o, c in s.opp {
		if o == NONE || int(o) < c do continue
		e := surface_edge(s, u32(c))
		length := length3(e)
		if length <= 0 do continue
		d := e / length
		weight := length * s.dihedral[c]
		add := [6]f64{weight * d.x * d.x, weight * d.x * d.y, weight * d.y * d.y, weight * d.x * d.z, weight * d.y * d.z, weight * d.z * d.z}
		w.tensor[surface_vertex(s, u32(c))] += add
		w.tensor[surface_vertex(s, corner_next(u32(c)))] += add
	}
	// Each pass sets a vertex halfway to the mean of its neighbours, a neighbour across an
	// inner edge counted twice (once from each triangle) and across a border once.
	for _ in 0 ..< ANISOTROPY_PASSES {
		jobs.parallel_ranges(s.pool, vertices, &w, proc(data: rawptr, lo, hi: int) {
			w := cast(^Anisotropy_Work)data
			s := w.s
			for v in lo ..< hi {
				from, to := s.first[v], s.first[v + 1]
				if from == to {
					w.smooth[v] = w.tensor[v]
					continue
				}
				sum: [6]f64
				for i in from ..< to {
					c := s.corners[i]
					sum += w.tensor[surface_vertex(s, corner_next(c))] + w.tensor[surface_vertex(s, corner_prev(c))]
				}
				w.smooth[v] = 0.5 * w.tensor[v] + 0.5 * sum / f64(2 * (to - from))
			}
		}, 4096)
		w.tensor, w.smooth = w.smooth, w.tensor
	}
	along_u := make([]f64, faces, heap)
	defer delete(along_u, heap)
	along_v := make([]f64, faces, heap)
	defer delete(along_v, heap)
	total := f64(0)
	for t, f in s.triangles {
		T := w.tensor[t[0]] + w.tensor[t[1]] + w.tensor[t[2]]
		b := unit_or_zero(directions[f])
		across := cross3(s.normal[f], b)
		along_u[f] = abs(quadratic_form(T, across))
		along_v[f] = abs(quadratic_form(T, b))
		total += along_u[f] + along_v[f]
	}
	if total <= 0 do return
	floor := 0.001 * total / (2 * f64(faces))
	most := math.sqrt(MAX_ASPECT)
	for f in 0 ..< faces {
		rho := math.pow((along_v[f] + floor) / (along_u[f] + floor), 0.25)
		rho = clamp(math.pow(rho, anisotropy), 1 / most, most)
		sizes[f][1], sizes[f][2] = rho, 1 / rho
	}
}

@(private = "file")
Anisotropy_Work :: struct {
	s:              ^Surface,
	tensor, smooth: [][6]f64, // per vertex: the curvature tensor, and the next pass's
}

@(private = "file")
quadratic_form :: #force_inline proc(T: [6]f64, t: [3]f64) -> f64 {
	return T[0] * t.x * t.x + T[2] * t.y * t.y + T[5] * t.z * t.z + 2 * (T[1] * t.x * t.y + T[3] * t.x * t.z + T[4] * t.y * t.z)
}

// ---- The solve ----------------------------------------------------------------------------

@(private = "file")
Solve_Work :: struct {
	s:         ^Surface,
	tensor:    [][6]f64, // per vertex: the curvature tensor, from the dihedral angles of its edges
	locked:    []bool,
	periodic:  [][2]f64,
	certainty: []f64,
}

// The field's angle in each triangle's basis (FrameField::create), or false when the
// system could not be solved. `features` (three a triangle, or nil) lock as sharp edges
// do, `log_scale` (one a vertex, or nil) turns the transport by the density's change, and
// `guides` (one a triangle, or nil) pull toward their direction by their length.
@(private = "file")
field_solve :: proc(s: ^Surface, sharp_degrees: f64, features: []u8, log_scale: []f64, guides: [][3]f64) -> (angles: []f64, ok: bool) {
	heap := runtime.heap_allocator()
	faces := len(s.triangles)
	w := Solve_Work {
		s         = s,
		locked    = make([]bool, faces, heap),
		periodic  = make([][2]f64, faces, heap),
		certainty = make([]f64, faces, heap),
		tensor    = make([][6]f64, len(s.positions), heap),
	}
	defer delete(w.locked, heap)
	defer delete(w.periodic, heap)
	defer delete(w.certainty, heap)
	defer delete(w.tensor, heap)

	// A triangle with two feature edges neither along nor across each other cannot lock to
	// both, so it locks to neither and the field bends round that corner.
	locks := make([]bool, faces, heap)
	defer delete(locks, heap)
	for &l in locks do l = true
	if features != nil {
		along_least := math.cos(FEATURE_TOLERANCE * math.PI / 180)
		across_most := math.sin(FEATURE_TOLERANCE * math.PI / 180)
		for f in 0 ..< faces do for a in 3 * f ..< 3 * f + 3 {
			if features[a] == 0 do continue
			for b in a + 1 ..< 3 * f + 3 {
				if features[b] == 0 do continue
				along := abs(dot3(unit_or_zero(surface_edge(s, u32(a))), unit_or_zero(surface_edge(s, u32(b)))))
				if along < along_least && along > across_most do locks[f] = false
			}
		}
	}
	sharp := sharp_degrees * math.PI / 180
	for f in 0 ..< faces do for c in 3 * f ..< 3 * f + 3 {
		flagged := features != nil && features[c] != 0 && locks[f]
		if !flagged && s.opp[c] != NONE && abs(s.dihedral[c]) <= sharp do continue
		angle := 4 * tangent_angle(s, surface_edge(s, u32(c)), f)
		w.periodic[f] = {math.cos(angle), math.sin(angle)}
		w.locked[f] = true
	}

	// The curvature tensor at each vertex, from its edges (each inner edge once).
	for o, c in s.opp {
		if o == NONE || int(o) < c do continue
		e := surface_edge(s, u32(c))
		d := unit_or(e, {1, 0, 0})
		weight := length3(e) * s.dihedral[c]
		add := [6]f64{weight * d.x * d.x, weight * d.x * d.y, weight * d.y * d.y, weight * d.x * d.z, weight * d.y * d.z, weight * d.z * d.z}
		w.tensor[surface_vertex(s, u32(c))] += add
		w.tensor[surface_vertex(s, corner_next(u32(c)))] += add
	}
	// A free triangle's pull: its corners' tensors summed, the direction of the eigenvalue
	// largest in size, as certain as it stands apart from the next.
	jobs.parallel_ranges(s.pool, faces, &w, proc(data: rawptr, lo, hi: int) {
		w := cast(^Solve_Work)data
		s := w.s
		for f in lo ..< hi {
			if w.locked[f] do continue
			t := s.triangles[f]
			T := w.tensor[t[0]] + w.tensor[t[1]] + w.tensor[t[2]]
			m := [3][3]f64{{T[0], T[1], T[3]}, {T[1], T[2], T[4]}, {T[3], T[4], T[5]}}
			trace := m[0][0] + m[1][1] + m[2][2]
			ridge := 1e-6 if trace == 0 else 1e-6 * trace
			for i in 0 ..< 3 do m[i][i] += ridge
			values, vectors, solved := symmetric_eigen3(m)
			if !solved do continue
			order := [3]int{0, 1, 2}
			// The three by size, largest first (a stable insertion sort).
			for i in 1 ..< 3 {
				for j := i; j > 0 && abs(values[order[j]]) > abs(values[order[j - 1]]); j -= 1 do order[j], order[j - 1] = order[j - 1], order[j]
			}
			first := order[0]
			direction := [3]f64{vectors[0][first], vectors[1][first], vectors[2][first]}
			angle := 4 * tangent_angle(s, direction, f)
			w.periodic[f] = {math.cos(angle), math.sin(angle)}
			w.certainty[f] = abs(values[first] - values[order[1]])
		}
	}, 1024)
	most := f64(0)
	for c in w.certainty do most = max(most, c)
	if most > 0 do for &c in w.certainty do c /= most
	for &p in w.periodic do p = unit2(p)

	// The free triangles' unknowns, numbered in order: each one complex number, its periodic
	// pair u + iv, so the normal matrix is Hermitian (every row pair of the real system
	// turns u and v alike) and factors at half the real system's size. A locked triangle's
	// pair is known and goes to the right side.
	index := make([]u32, faces, heap)
	defer delete(index, heap)
	free := 0
	for f in 0 ..< faces {
		index[f] = NONE
		if !w.locked[f] {
			index[f] = u32(free)
			free += 1
		}
	}
	angles = make([]f64, faces, heap)
	if free == 0 {
		for p, f in w.periodic do angles[f] = math.atan2(p[1], p[0]) / 4
		return angles, true
	}
	diagonal := make([]f64, free, heap)
	defer delete(diagonal, heap)
	known := make([]complex128, free, heap) // the right side's part that stays: the locked neighbours and the guides
	defer delete(known, heap)
	t := sparse.hermitian_triplets_make(free, len(s.opp) / 2 + free, heap)
	defer sparse.hermitian_triplets_destroy(&t)
	for o, c in s.opp {
		if o == NONE do continue
		f, g := c / 3, int(o) / 3
		if f <= g do continue
		turn := s.connection[c]
		if log_scale != nil do turn += conformal_turn(s, u32(c), log_scale)
		// The smoothness rows |e^{i 4 turn} z_f - z_g|²: f's pair carried across the edge,
		// less g's (the C++'s two real rows co u_f + si v_f - u_g and -si u_f + co v_f - v_g,
		// transport = -4 turn).
		transport := -4 * turn
		co, si := math.cos(transport), math.sin(transport)
		carry := complex(co, -si)
		i, j := index[f], index[g]
		switch {
		case i != NONE && j != NONE:
			diagonal[i] += co * co + si * si
			diagonal[j] += 1
			sparse.hermitian_triplets_add(&t, int(i), int(j), -conj(carry))
		case i != NONE:
			diagonal[i] += co * co + si * si
			known[i] += conj(carry) * complex(w.periodic[g][0], w.periodic[g][1])
		case j != NONE:
			diagonal[j] += 1
			known[j] += carry * complex(w.periodic[f][0], w.periodic[f][1])
		}
	}
	for f in 0 ..< faces {
		i := index[f]
		if i == NONE do continue
		if c := w.certainty[f]; c > 0 do diagonal[i] += c * c
		// The guides' rows aim at the guide itself every round, where the curvature's are
		// aimed again at the last solution.
		if guides != nil {
			weight := length3(guides[f])
			if !(weight > 1e-12) do continue
			angle := 4 * tangent_angle(s, guides[f], f)
			diagonal[i] += weight
			known[i] += complex(weight * math.cos(angle), weight * math.sin(angle))
		}
	}
	// The ridge: a share of the mean diagonal, as the C++ takes it over its real unknowns
	// (each complex one's diagonal twice, so the same mean).
	mean := f64(0)
	for d in diagonal do mean += d
	mean /= f64(free)
	ridge := RIDGE * mean if mean > 0 else RIDGE
	for d, k in diagonal do sparse.hermitian_triplets_add(&t, k, k, complex(d + ridge, 0))
	m, built := sparse.hermitian_from_triplets(t, heap)
	if !built do return angles, false
	defer sparse.hermitian_destroy(&m, heap)
	symbolic := sparse.ldlt_analyze(sparse.hermitian_pattern(m), allocator = heap)
	defer sparse.symbolic_destroy(&symbolic, heap)
	factor: sparse.Hermitian_Factor
	defer sparse.hermitian_factor_destroy(&factor, heap)
	if !sparse.hermitian_factor(&factor, &symbolic, m, heap) do return angles, false

	b := make([]complex128, free, heap)
	defer delete(b, heap)
	x := make([]complex128, free, heap)
	defer delete(x, heap)
	for _ in 0 ..< FIELD_ROUNDS {
		copy(b, known)
		for f in 0 ..< faces {
			i := index[f]
			if i == NONE do continue
			if c := w.certainty[f]; c > 0 do b[i] += complex(c * c * w.periodic[f][0], c * c * w.periodic[f][1])
		}
		sparse.hermitian_solve(&factor, b, x)
		for v in x do if !(abs(real(v)) <= math.F64_MAX && abs(imag(v)) <= math.F64_MAX) do return angles, false
		for f in 0 ..< faces {
			i := index[f]
			if i != NONE do w.periodic[f] = unit2({real(x[i]), imag(x[i])})
		}
	}
	for p, f in w.periodic do angles[f] = math.atan2(p[1], p[0]) / 4
	return angles, true
}

// The turn the density's scaled metric adds to the transport across corner c's edge, from
// its triangle to the one beyond (FrameField::conformalTurn): the log scale's change along
// the edge times the cotangents of the two angles facing it.
@(private = "file")
conformal_turn :: proc(s: ^Surface, c: u32, log_scale: []f64) -> f64 {
	o := s.opp[c]
	if o == NONE do return 0
	cotangent_facing :: proc(s: ^Surface, c: u32) -> f64 {
		to_start := surface_edge(s, corner_prev(c))
		to_end := -surface_edge(s, corner_next(c))
		sine := length3(cross3(to_start, to_end))
		return clamp(dot3(to_start, to_end) / sine, -10, 10) if sine > 1e-30 else 0
	}
	weight := cotangent_facing(s, c) + cotangent_facing(s, o)
	return -weight * (log_scale[surface_vertex(s, corner_next(c))] - log_scale[surface_vertex(s, c)])
}

// The mean over the inner edges of 1 - cos 4(the frames' turn across the edge), the
// transport taken away: what the solve's smoothness rows weigh.
@(private)
field_smoothness :: proc(s: ^Surface, angles: []f64) -> f64 {
	sum, edges := f64(0), 0
	for o, c in s.opp {
		if o == NONE || int(o) < c do continue
		sum += 1 - math.cos(4 * (angles[int(o) / 3] - angles[c / 3] - s.connection[c]))
		edges += 1
	}
	return sum / f64(edges) if edges > 0 else 0
}

// ---- Small vector helpers (dot3 and cross3 are extract_faces.odin's) ----------------------

@(private)
length3 :: #force_inline proc(a: [3]f64) -> f64 {
	return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
}

// `a` over its length, or zero when its length is within a rounding of zero (Vector3's).
@(private)
unit_or_zero :: #force_inline proc(a: [3]f64) -> [3]f64 {
	l := length3(a)
	return {} if l <= math.F64_EPSILON else a / l
}

// `a` as is when its length is within a rounding of zero (Vector3::normalize).
@(private = "file")
unit_or_keep :: #force_inline proc(a: [3]f64) -> [3]f64 {
	l := length3(a)
	return a if l <= math.F64_EPSILON else a / l
}

// `a` over its length, or `fallback` when `a` is shorter than 1e-12.
@(private = "file")
unit_or :: #force_inline proc(a, fallback: [3]f64) -> [3]f64 {
	l := length3(a)
	return fallback if l <= 1e-12 else a / l
}

@(private = "file")
unit2 :: #force_inline proc(p: [2]f64) -> [2]f64 {
	l := math.hypot(p[0], p[1])
	return p / l if l > 1e-30 else p
}

// The eigenvalues of a symmetric 3 by 3 matrix and their unit eigenvectors, the columns of
// `vectors`, by Jacobi's rotations, each zeroing one entry off the diagonal; false when
// the matrix is not finite.
@(private)
symmetric_eigen3 :: proc(a: [3][3]f64) -> (values: [3]f64, vectors: [3][3]f64, ok: bool) {
	m := a
	vectors = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}
	size := f64(0)
	for i in 0 ..< 3 do for j in 0 ..< 3 do size += m[i][j] * m[i][j]
	if !(size <= math.F64_MAX) do return
	for _ in 0 ..< 32 {
		off := m[0][1] * m[0][1] + m[0][2] * m[0][2] + m[1][2] * m[1][2]
		if off <= 1e-32 * size do break
		pairs := [3][2]int{{0, 1}, {0, 2}, {1, 2}}
		for pq in pairs {
			p, q := pq[0], pq[1]
			if m[p][q] == 0 do continue
			theta := (m[q][q] - m[p][p]) / (2 * m[p][q])
			t := 1 / (abs(theta) + math.sqrt(theta * theta + 1))
			if theta < 0 do t = -t
			c := 1 / math.sqrt(t * t + 1)
			s := t * c
			for k in 0 ..< 3 {
				mp, mq := m[k][p], m[k][q]
				m[k][p], m[k][q] = c * mp - s * mq, s * mp + c * mq
			}
			for k in 0 ..< 3 {
				mp, mq := m[p][k], m[q][k]
				m[p][k], m[q][k] = c * mp - s * mq, s * mp + c * mq
			}
			m[p][q], m[q][p] = 0, 0
			for k in 0 ..< 3 {
				vp, vq := vectors[k][p], vectors[k][q]
				vectors[k][p], vectors[k][q] = c * vp - s * vq, s * vp + c * vq
			}
		}
	}
	return {m[0][0], m[1][1], m[2][2]}, vectors, true
}
