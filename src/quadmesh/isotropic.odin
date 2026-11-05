package quadmesh

import "base:runtime"
import "core:math"
import "core:slice"

import "../geom"
import "../jobs"

// The isotropic remesh in Odin (Core.Odin), the stage qm_stage_isotropic runs in C++
// (AutoRemesher's isotropicremesher, MIT, by Jeremy Hu, whose rules this follows): the
// island remeshed to triangles of about the stage's edge length, or each vertex's own, by
// Botsch and Kobbelt's loop of splitting the long edges, collapsing the short ones,
// flipping toward valence six, relaxing each vertex in its tangent plane and projecting it
// back onto the island. Where the core moves a vertex to its neighbours' mean once a
// round, this moves it to its cell's centre three times (Lloyd's steps, which even the
// triangles' areas), then turns the obtuse pairs left and opens the sharpest angles
// (isotropic_lift), so the smallest angle and the spread of the edges come out better
// than the core's on every fixture the tests compare (isotropic_test.odin), in less time.
// It runs over a corner table (mesh.odin), so a pinch, a torn edge
// or a repeated corner is split or cut where the mesh is built instead of hanging a walk
// round a vertex; every collapse keeps the link condition and three edges at the far
// corners, every move is refused that would flatten or turn a triangle over, and the
// splits stop at a cap the targets set, so no input makes it loop. The relax and the
// projection work out every vertex's move from the same positions on the thread pool
// (Stage_Run.pool) and apply them in vertex order, so any thread count gives the same
// mesh, bit for bit. The caller's feature edges stay edges on the caller's polyline,
// edges sharper than the stage's angle and borders stay where they are, and the density's
// edge factor rides the vertices as a payload, which the cover's sizes come from.

// Rounds of split, collapse, flip, relax and project (the core's three), and the steps of
// relaxing and projecting in each, where the core takes one: each step moves a vertex
// part of the way to its cell's centre, and three bring the smallest angles and the
// spread of the edges well past the core's for about a third of its time.
@(private = "file")
ISOTROPIC_ROUNDS :: 3
@(private = "file")
RELAX_STEPS :: 3

// How far (in targets) a border vertex may lie from the line between its neighbours and
// still collapse along the border (isotropic_collapse): a wiggle smaller than the quads
// goes, as the rest of the surface's detail below their size does, and a corner of the
// border's own, a target or more across, stays.
@(private = "file")
BORDER_WANDER :: 0.25

// An edge is split above 4/3 of its target and collapsed below 4/5 (Botsch and Kobbelt).
@(private = "file")
SPLIT_ABOVE :: 4.0 / 3.0
@(private = "file")
COLLAPSE_BELOW :: 4.0 / 5.0

// The Delaunay flips' passes at most, by how much (radians) the two far angles must pass
// a half turn, and how flat (the normals' cosine) the two triangles must be.
@(private = "file")
DELAUNAY_PASSES :: 4
@(private = "file")
DELAUNAY_MARGIN :: 0.05
@(private = "file")
DELAUNAY_FLAT :: 0.85

// The lift's sweeps at most, and the angle below which a triangle's corners are lifted
// (its cosine).
@(private = "file")
LIFT_SWEEPS :: 4
@(private = "file")
LIFT_COSINE :: 0.766044443118978 // cos(40 degrees)

// How far, in target edges, a vertex looks for the island when it is projected back: a
// relaxed vertex has moved by about an edge along the surface.
@(private = "file")
PROJECT_REACH :: 2.0

// The splits may make at most this many times the triangles the targets ask for, plus the
// input's own count, before they stop (a target the input's scale makes tiny).
@(private = "file")
SPLIT_CAP :: 8

// The first split's flips inside flat regions (isotropic_cut_edges): two triangles count
// as one plane when their normals' cosine is at least IN_ONE_PLANE (a facet's own pieces
// are, to rounding), and an edge flips when the angles across it pass a half turn by
// LAWSON_MARGIN radians, so points on a circle do not flip back and forth. LAWSON_BUDGET
// bounds a split pass's flips, which the margin already makes finite.
@(private = "file")
IN_ONE_PLANE :: 1 - 1e-9
@(private = "file")
LAWSON_MARGIN :: 1e-6
@(private = "file")
LAWSON_BUDGET :: 1 << 26

odin_isotropic :: proc(island: Island, voxel_size, adaptivity, sharp_degrees: f64, run: ^Stage_Run, reason: ^Reason, checks: ^Checks) -> (out: Isotropic, err: Stage_Error) {
	heap := runtime.heap_allocator()
	context.allocator = heap
	n := len(island.positions)
	if n == 0 || len(island.triangles) == 0 do return
	if !(voxel_size > 0) || voxel_size >= math.F64_MAX {
		reason_set(reason, "the isotropic edge length is not a positive number")
		return {}, .Failed
	}

	// Each vertex's target: Adaptivity's, shortened where the density asks for more quads
	// (a quad's edge goes as 1 / sqrt(density), which also rides the vertices as the
	// payload the cover sizes its quads by) and where the refinement asks for finer
	// triangles alone (thin parts), which the payload does not see.
	targets := adaptive_target_lengths(island.positions, island.triangles, voxel_size, adaptivity)
	defer delete(targets, heap)
	dense := len(island.density) == n
	edge_factor: []f64
	defer delete(edge_factor, heap)
	if dense {
		edge_factor = make([]f64, n, heap)
		for &e, v in edge_factor do e = 1 / math.sqrt(island.density[v])
		if targets == nil {
			targets = make([]f64, n, heap)
			for &t in targets do t = voxel_size
		}
		for &t, v in targets do t *= edge_factor[v]
	}
	if len(island.refine) == n {
		if targets == nil {
			targets = make([]f64, n, heap)
			for &t in targets do t = voxel_size
		}
		for &t, v in targets do t *= island.refine[v]
	}

	m, fans, torn, dropped := work_mesh_build(island.positions, island.triangles, island.features, targets, edge_factor)
	defer work_mesh_destroy(&m)
	checks.iso_split_fans += fans
	checks.iso_torn_edges += torn
	checks.iso_dropped += dropped
	if !stage_report(run, 0) do return {}, .Cancelled

	// What the vertices are projected back onto: the island (its triangles in f32 for the
	// tree, the points taken in f64 from its own positions), and the caller's feature
	// polylines, eased as the C++ eases them.
	source := geom.Mesh {
		positions = make([dynamic]geom.Vec3, n, heap),
		indices   = make([dynamic]u32, 0, 3 * len(island.triangles), heap),
	}
	defer geom.mesh_destroy(&source)
	for p, v in island.positions do source.positions[v] = {f32(p.x), f32(p.y), f32(p.z)}
	for t in island.triangles {
		if t[0] >= u32(n) || t[1] >= u32(n) || t[2] >= u32(n) do continue
		append(&source.indices, t[0], t[1], t[2])
	}
	tree := geom.bvh_build_morton(source, pool = run.pool if run != nil else nil, allocator = heap)
	defer geom.bvh_destroy(&tree)
	longest_target := voxel_size
	for t in targets do longest_target = max(longest_target, t)
	// The creases (the island's edges sharper than the stage's angle, which the judge below
	// finds again on the split edges) as polylines of their own, which a vertex on one is
	// put back onto after its relax, so a curved crease keeps its curve; the C++ leaves it
	// where the relax took it, a little inside the curve. The caller's features are eased
	// as the C++ eases them, except where they cross a crease.
	creases: [][2]u32
	defer delete(creases, heap)
	if sharp_degrees > 0 do creases = sharp_edges(island.positions, island.triangles, sharp_degrees * math.PI / 180)
	on_crease: []bool
	defer delete(on_crease, heap)
	if len(creases) > 0 {
		on_crease = make([]bool, n, heap)
		for e in creases do on_crease[e[0]], on_crease[e[1]] = true, true
	}
	cell := PROJECT_REACH * longest_target
	eased := feature_positions(island.positions, island.features, on_crease)
	defer delete(eased, heap)
	lines := segment_grid_build(eased, island.features, cell)
	defer segment_grid_destroy(&lines)
	crease_lines := segment_grid_build(island.positions, creases, cell)
	defer segment_grid_destroy(&crease_lines)

	// The splits' cap: the triangles the targets ask for over the island's area, each
	// triangle taken at its corners' shortest target, since the splits between a short
	// target and a long one carry the short one some way in (an edge's target is the
	// mean of its ends', a new vertex's the mean of the edge's), more than the corners'
	// mean would count.
	asked := f64(0)
	for t in island.triangles {
		if t[0] >= u32(n) || t[1] >= u32(n) || t[2] >= u32(n) do continue
		edge := voxel_size
		if targets != nil do edge = min(m.target[t[0]], m.target[t[1]], m.target[t[2]])
		if !(edge > 0) do edge = voxel_size
		p, q, r := island.positions[t[0]], island.positions[t[1]], island.positions[t[2]]
		// A long sliver takes about as many triangles as its longest side's square in
		// targets, whatever its area: the splits cut it across as well as along.
		longest := max(dot3(q - p, q - p), dot3(r - q, r - q), dot3(p - r, p - r))
		asked += max(triangle_area(p, q, r) / (edge * edge * EQUILATERAL_AREA), longest / (edge * edge))
	}
	cap := int(min(SPLIT_CAP * asked, f64(1 << 28))) + SPLIT_CAP * len(m.dead) + 4096

	work := Isotropic_Work {
		m      = &m,
		edge   = voxel_size,
		tree   = &tree,
		source = &source,
		island = island.positions,
		lines  = &lines,
		creases = &crease_lines,
		pool   = run.pool if run != nil else nil,
		cap    = cap,
	}
	defer delete(work.normals)
	defer delete(work.moved)
	defer delete(work.moves)

	isotropic_cut_edges(&work)
	isotropic_split(&work, true)
	if sharp_degrees > 0 do isotropic_judge(&m, sharp_degrees * math.PI / 180)
	for v in 0 ..< len(m.pos) do if m.corner[v] != NONE && work_border(&m, u32(v)) do m.featured[v] = true
	if !stage_report(run, 0.15) do return {}, .Cancelled
	passes := f32(ISOTROPIC_ROUNDS * (3 + RELAX_STEPS))
	pass := f32(0)
	for round in 0 ..< ISOTROPIC_ROUNDS {
		// The first round's split is the one above, made before the edges were judged.
		if round > 0 do isotropic_split(&work, false)
		pass += 1
		if !stage_report(run, 0.25 + 0.75 * pass / passes) do return {}, .Cancelled
		isotropic_collapse(&work)
		pass += 1
		if !stage_report(run, 0.25 + 0.75 * pass / passes) do return {}, .Cancelled
		isotropic_flip(&work)
		pass += 1
		if !stage_report(run, 0.25 + 0.75 * pass / passes) do return {}, .Cancelled
		for _ in 0 ..< RELAX_STEPS {
			isotropic_relax(&work)
			isotropic_project(&work)
			pass += 1
			if !stage_report(run, 0.25 + 0.75 * pass / passes) do return {}, .Cancelled
		}
	}
	// What the core does not do: the obtuse pairs the valence flips left turned, and the
	// sharpest angles opened where a vertex can move.
	isotropic_delaunay(&work)
	isotropic_lift(&work)
	if work.capped do checks.iso_capped += 1

	out = isotropic_output(&m, len(island.features) > 0, dense)
	return out, .None
}

// The stage's 0..1, and whether to go on (false once cancelled).
@(private)
stage_report :: proc(run: ^Stage_Run, fraction: f32) -> bool {
	return run == nil || run.progress == nil || run.progress(run.tag, fraction)
}

@(private = "file")
Isotropic_Work :: struct {
	m:       ^Work_Mesh,
	edge:    f64, // the stage's own target edge
	tree:    ^geom.Bvh, // over source
	source:  ^geom.Mesh, // the island in f32
	island:  [][3]f64, // the island's own positions
	lines:   ^Segment_Grid, // the caller's features, eased
	creases: ^Segment_Grid, // the island's creases
	pool:    ^jobs.Pool,
	cap:     int, // the most triangles the splits may make
	capped:  bool, // the splits reached it
	normals: [dynamic][3]f64, // per vertex, from the relax's start
	moved:   [dynamic][3]f64, // per vertex: where its move goes
	moves:   [dynamic]bool, // per vertex: whether it moves
}

// The squared lengths below which an edge collapses and above which it splits, from its
// ends' targets when both have one, else the stage's.
@(private = "file")
edge_limits :: #force_inline proc(w: ^Isotropic_Work, a, b: u32) -> (lo, hi: f64) {
	t := w.edge
	if ta, tb := w.m.target[a], w.m.target[b]; ta > 0 && tb > 0 do t = 0.5 * (ta + tb)
	return COLLAPSE_BELOW * COLLAPSE_BELOW * t * t, SPLIT_ABOVE * SPLIT_ABOVE * t * t
}

// The first split's edges between two facets that do not lie in one plane (and on
// borders and features), each cut at once into as many pieces as its ends' targets ask,
// graded from one target to the other, and then every flat region's triangles flipped
// until they are Delaunay. Halving a long sliver's longest side again and again cuts it
// across at ever finer heights, about its length squared in targets where its area asks
// for its length times its width: a thin rod's tube of 96 long slivers made 1.4 million
// triangles. Cut along its sides first and flipped, a sliver becomes a ladder of
// triangles about one target long, and the longest-edge splits after it start from
// triangles of a sound shape. An edge inside a flat region is left to those splits,
// which put their points inside the region rather than along a line across it.
@(private = "file")
isotropic_cut_edges :: proc(w: ^Isotropic_Work) {
	m := w.m
	heap := runtime.heap_allocator()
	ends := make([dynamic][2]u32, heap)
	defer delete(ends)
	for c in 0 ..< u32(len(m.vert)) {
		if m.dead[c / 3] do continue
		a, b := m.vert[c], m.vert[corner_next(c)]
		if m.twin[c] != NONE && (a > b || in_one_plane(m, c)) do continue
		append(&ends, [2]u32{a, b})
	}
	for e in ends {
		a, b := e[0], e[1]
		c := work_find(m, a, b)
		if c == NONE do continue
		ta, tb := m.target[a], m.target[b]
		if !(ta > 0) || !(tb > 0) do ta, tb = w.edge, w.edge
		d := m.pos[b] - m.pos[a]
		length := math.sqrt(dot3(d, d))
		// The edge's length in targets, its target running straight from one end's to the
		// other's: the integral of 1 / target along it.
		ratio := tb / ta
		graded := abs(ratio - 1) > 1e-6
		span := length * math.ln(ratio) / (tb - ta) if graded else length / ta
		if !(span < 2 * f64(w.cap)) {
			w.capped = true
			return
		}
		pieces := int(math.round(span))
		if pieces < 2 do continue
		if len(m.dead) + 2 * (pieces - 1) > w.cap {
			w.capped = true
			return
		}
		// Each cut where the length in targets reaches its share: evenly, or where the
		// target has grown by the same factor each piece.
		done := f64(0)
		for k in 1 ..< pieces {
			share := f64(k) / f64(pieces)
			at := length * (ta * math.pow(ratio, share) - ta) / (tb - ta) if graded else length * share
			rest := u32(len(m.vert))
			work_split_at(m, c, (at - done) / (length - done))
			c, done = rest, at
		}
	}
	stack := make([dynamic]u32, 0, len(m.vert), heap)
	defer delete(stack)
	for c in 0 ..< u32(len(m.vert)) do if !m.dead[c / 3] && m.twin[c] != NONE && m.vert[c] < m.vert[corner_next(c)] do append(&stack, c)
	budget := LAWSON_BUDGET
	work_flip_to_delaunay(m, &stack, LAWSON_MARGIN, IN_ONE_PLANE, &budget)
}

// Whether corner c's two triangles lie in one plane (their normals' cosine at least
// IN_ONE_PLANE), so a flip between them leaves the surface as it was.
@(private = "file")
in_one_plane :: proc(m: ^Work_Mesh, c: u32) -> bool {
	t := m.twin[c]
	if t == NONE do return false
	a, b := m.pos[m.vert[c]], m.pos[m.vert[corner_next(c)]]
	top := cross3(b - a, m.pos[m.vert[corner_prev(c)]] - a)
	bottom := cross3(a - b, m.pos[m.vert[corner_prev(t)]] - b)
	lt, lb := math.sqrt(dot3(top, top)), math.sqrt(dot3(bottom, bottom))
	return lt > 0 && lb > 0 && dot3(top, bottom) >= IN_ONE_PLANE * lt * lb
}

// The collapsed triangles taken out, then every triangle in turn, the ones the splits add
// included, splits its longest edge while one is too long, until none is or the cap is
// reached. The longest first, as Rivara's bisection takes it, halves a long thin
// triangle across its length; the C++ splits a triangle's first long edge in its own
// order, which on a coarse input of long slivers (an open cylinder of 96 triangles) cuts
// one side again and again into a fan of slivers round the far corner, and those split
// on into seven times the triangles asked. With `delaunay` (the first split), each split
// is followed by Lawson's flips round the new vertex inside its flat region, so a large
// flat facet fills as a Delaunay refinement does rather than with fans of slivers; a flip
// can change a triangle already passed, so the passes repeat until one splits nothing.
@(private = "file")
isotropic_split :: proc(w: ^Isotropic_Work, delaunay: bool) {
	m := w.m
	heap := runtime.heap_allocator()
	stack := make([dynamic]u32, heap)
	defer delete(stack)
	budget := LAWSON_BUDGET
	for {
		work_compact(m)
		split := false
		for f := 0; f < len(m.dead); {
			longest, over := NONE, f64(1)
			if !m.dead[f] {
				for k in 0 ..< 3 {
					c := u32(3 * f + k)
					a, b := m.vert[c], m.vert[corner_next(c)]
					_, hi := edge_limits(w, a, b)
					d := m.pos[b] - m.pos[a]
					if ratio := dot3(d, d) / hi; ratio > over do longest, over = c, ratio
				}
			}
			if longest == NONE {
				f += 1
				continue
			}
			// The mesh was compacted above, so its triangles are the live ones and those this
			// pass made.
			if len(m.dead) + 2 > w.cap {
				w.capped = true
				return
			}
			mid := work_split(m, longest)
			split = true
			if !delaunay do continue
			// The edges across from the new vertex, which its arrival may have made not
			// Delaunay.
			start := m.corner[mid]
			for c := start; c != NONE; c = ring_step(m, start, c) do append(&stack, corner_next(c))
			work_flip_to_delaunay(m, &stack, LAWSON_MARGIN, IN_ONE_PLANE, &budget)
		}
		if !delaunay || !split do break
	}
}

// Every edge judged once, after the first split: sharper than `radians` (or on a border)
// is a feature, which stays an edge; the caller's own stay as they are.
@(private = "file")
isotropic_judge :: proc(m: ^Work_Mesh, radians: f64) {
	normal :: proc(m: ^Work_Mesh, c: u32) -> [3]f64 {
		p := m.pos[m.vert[c]]
		return cross3(m.pos[m.vert[corner_next(c)]] - p, m.pos[m.vert[corner_prev(c)]] - p)
	}
	for c in 0 ..< u32(len(m.vert)) {
		if m.dead[c / 3] || m.state[c] != UNJUDGED do continue
		t := m.twin[c]
		if t == NONE {
			m.state[c] = SHARP
			m.featured[m.vert[c]] = true
			continue
		}
		p, q := normal(m, c), normal(m, t)
		lp, lq := math.sqrt(dot3(p, p)), math.sqrt(dot3(q, q))
		sharp := lp > 0 && lq > 0 && math.acos(clamp(dot3(p, q) / (lp * lq), -1, 1)) >= radians
		s := SHARP if sharp else SMOOTH
		m.state[c], m.state[t] = s, s
		if sharp do m.featured[m.vert[c]], m.featured[m.vert[t]] = true, true
	}
}

// Every triangle in turn collapses its first edge that is too short, if it may: a free
// vertex into the middle of the edge; a vertex inside a feature line only along the line,
// into the neighbour it keeps; a free vertex onto a vertex of the caller's features
// (inside the mesh), which takes the sliver beside such a feature away; a border vertex
// only along the border, into the neighbour it keeps, where it lies within BORDER_WANDER
// of the line between its neighbours and no other feature meets it. So a border as fine
// as the input (a symmetric half's cut, taken from the whole at its own density) comes
// to the target's length, every vertex left on it one it had and so on the plane of a
// cut, rather than keeping slivers along it. A border vertex never goes inward, and a
// free one never goes onto a border or a feature found by angle, or across a feature.
@(private = "file")
isotropic_collapse :: proc(w: ^Isotropic_Work) {
	m := w.m
	for f in 0 ..< len(m.dead) {
		if m.dead[f] do continue
		for k in 0 ..< 3 {
			h := u32(3 * f + k)
			a, b := m.vert[h], m.vert[corner_next(h)]
			lo, hi := edge_limits(w, a, b)
			d := m.pos[b] - m.pos[a]
			if !(dot3(d, d) < lo) do continue
			if m.twin[h] == NONE {
				if m.corner[a] != h || work_feature_edges(m, a) != 2 do continue
				// How far the border strays at a from the line between its neighbours.
				before := m.pos[m.vert[corner_prev(ring_last(m, a))]]
				chord := m.pos[b] - before
				along := dot3(m.pos[a] - before, chord) / max(dot3(chord, chord), 1e-300)
				off := m.pos[a] - (before + clamp(along, 0, 1) * chord)
				wander := BORDER_WANDER * math.sqrt(lo) / COLLAPSE_BELOW
				if dot3(off, off) > wander * wander do continue
				if work_collapse_border(m, h, hi) do break
				continue
			}
			if work_border(m, a) do continue
			along := m.state[h] >= SHARP && m.featured[a] && m.featured[b] && work_feature_edges(m, a) == 2
			onto := !m.featured[a] && m.featured[b] && !work_border(m, b) && work_on_caller(m, b)
			if !along && !onto && (m.featured[a] || m.featured[b]) do continue
			to := m.pos[b] if along || onto else 0.5 * (m.pos[a] + m.pos[b])
			if work_collapse(m, h, to, hi) do break
		}
	}
}

// Every triangle in turn flips its first edge whose flip brings the valences nearer six.
@(private = "file")
isotropic_flip :: proc(w: ^Isotropic_Work) {
	m := w.m
	for f in 0 ..< len(m.dead) {
		if m.dead[f] do continue
		for k in 0 ..< 3 do if work_flip(m, u32(3 * f + k)) do break
	}
}

// Flips the edges whose two far angles sum to clearly more than a half turn, a few passes
// or until none is left: after the rounds, which flip for the valences, an obtuse pair
// still standing is where the smallest angles are.
@(private = "file")
isotropic_delaunay :: proc(w: ^Isotropic_Work) {
	m := w.m
	for _ in 0 ..< DELAUNAY_PASSES {
		flipped := false
		for f in 0 ..< len(m.dead) {
			if m.dead[f] do continue
			for k in 0 ..< 3 {
				if work_flip_delaunay(m, u32(3 * f + k), DELAUNAY_MARGIN, DELAUNAY_FLAT) {
					flipped = true
					break
				}
			}
		}
		if !flipped do break
	}
}

// The vertex normals (area-weighted), then each free vertex's move to the centre of its
// cell (free_centre) and a featured one's to the middle of its two feature neighbours,
// taken in the vertex's tangent plane; a border vertex, a feature's junction or end, and
// a move that would flatten or turn a triangle stay.
@(private = "file")
isotropic_relax :: proc(w: ^Isotropic_Work) {
	m := w.m
	nv := len(m.pos)
	resize(&w.normals, nv)
	resize(&w.moved, nv)
	resize(&w.moves, nv)
	jobs.parallel_ranges(w.pool, nv, w, proc(data: rawptr, lo, hi: int) {
		w := cast(^Isotropic_Work)data
		m := w.m
		for v in lo ..< hi {
			w.moves[v] = false
			start := m.corner[v]
			if start == NONE do continue
			normal := vertex_normal(m, u32(v))
			w.normals[v] = normal
			if m.twin[start] == NONE do continue
			centre: [3]f64
			if m.featured[v] {
				count := 0
				for c := start; c != NONE; c = ring_step(m, start, c) {
					if m.state[c] < SHARP do continue
					centre += m.pos[m.vert[corner_next(c)]]
					count += 1
				}
				if count != 2 do continue
				centre *= 0.5
			} else {
				ok: bool
				if centre, ok = free_centre(m, u32(v)); !ok do continue
			}
			w.moved[v] = centre + normal * dot3(m.pos[v] - centre, normal)
			w.moves[v] = true
		}
	})
	isotropic_apply(w)
}

// v's normal: its triangles' normals weighted by their areas, or zero.
@(private = "file")
vertex_normal :: proc(m: ^Work_Mesh, v: u32) -> [3]f64 {
	start := m.corner[v]
	sum := [3]f64{}
	p := m.pos[v]
	for c := start; c != NONE; c = ring_step(m, start, c) do sum += cross3(m.pos[m.vert[corner_next(c)]] - p, m.pos[m.vert[corner_prev(c)]] - p)
	l := math.sqrt(dot3(sum, sum))
	return sum / l if l > 0 else 0
}

// The centre of the cell a free vertex owns: each of its triangles' middles weighted by
// the triangle's area over the square of its corners' mean target. Moving there evens the
// triangles' areas against the sizes asked (a step of Lloyd's toward a centroidal
// tessellation), where the plain mean of the neighbours, which the C++ takes, evens only
// their distances and leaves slivers beside a vertex of odd valence.
@(private = "file")
free_centre :: proc(m: ^Work_Mesh, v: u32) -> (centre: [3]f64, ok: bool) {
	start := m.corner[v]
	total := f64(0)
	p := m.pos[v]
	for c := start; c != NONE; c = ring_step(m, start, c) {
		q, r := m.vert[corner_next(c)], m.vert[corner_prev(c)]
		n := cross3(m.pos[q] - p, m.pos[r] - p)
		weight := math.sqrt(dot3(n, n))
		if size := (m.target[v] + m.target[q] + m.target[r]) / 3; size > 0 do weight /= size * size
		centre += weight * (p + m.pos[q] + m.pos[r]) / 3
		total += weight
	}
	if !(total > 0) do return
	return centre / total, true
}

// Each vertex back onto the island: a free one onto the nearest point of a triangle that
// faces the way it does (on a thin part the other side faces away), within PROJECT_REACH
// of its target; one inside a line of the caller's features onto the nearest point of
// their polylines, and one inside a crease onto the creases; any other featured vertex (a
// border, a junction, a loose end) stays where it is.
@(private = "file")
isotropic_project :: proc(w: ^Isotropic_Work) {
	m := w.m
	nv := len(m.pos)
	resize(&w.moved, nv)
	resize(&w.moves, nv)
	jobs.parallel_ranges(w.pool, nv, w, proc(data: rawptr, lo, hi: int) {
		w := cast(^Isotropic_Work)data
		m := w.m
		for v in lo ..< hi {
			w.moves[v] = false
			if m.corner[v] == NONE do continue
			if m.featured[v] {
				// Only a vertex inside a feature line slides onto its polyline, the caller's
				// or a crease's; a junction, a loose end and a border stay, as the relax
				// keeps them.
				if work_border(m, u32(v)) || work_feature_edges(m, u32(v)) != 2 do continue
				grid := w.lines if work_on_caller(m, u32(v)) else w.creases
				if len(grid.segments) == 0 do continue
				reach := PROJECT_REACH * (m.target[v] if m.target[v] > 0 else w.edge)
				if to, ok := segment_grid_nearest(grid, m.pos[v], reach); ok {
					w.moved[v], w.moves[v] = to, true
				}
				continue
			}
			if to, tri, ok := onto_island(w, u32(v), m.pos[v], w.normals[v] if v < len(w.normals) else 0); ok {
				w.moved[v], w.moves[v] = to, true
				m.near[v] = tri
			}
		}
	})
	isotropic_apply(w)
}

// The nearest point to p of an island triangle facing along `normal` (any, when it is
// zero), within PROJECT_REACH of v's target, searched from the triangle v was last
// projected onto.
@(private = "file")
onto_island :: proc(w: ^Isotropic_Work, v: u32, p, normal: [3]f64) -> (to: [3]f64, tri: u32, ok: bool) {
	m := w.m
	reach := PROJECT_REACH * (m.target[v] if m.target[v] > 0 else w.edge)
	tri, _, _, ok = geom.bvh_closest(w.tree^, w.source^, {f32(p.x), f32(p.y), f32(p.z)}, f32(reach), m.near[v], {f32(normal.x), f32(normal.y), f32(normal.z)})
	if !ok do return
	// The tree finds the triangle in f32; the point on it is worked out again from the
	// island's own f64 corners, so a flat face keeps its vertices in its plane exactly.
	s := w.source.indices[3 * tri:]
	return closest_on_triangle64(p, w.island[s[0]], w.island[s[1]], w.island[s[2]]), tri, true
}

// The point of triangle abc nearest to p, in f64 (geom.closest_on_triangle's regions); a
// triangle with no area gives the nearest point of its edges.
@(private = "file")
closest_on_triangle64 :: proc(p, a, b, c: [3]f64) -> [3]f64 {
	ab, ac, ap := b - a, c - a, p - a
	d1, d2 := dot3(ab, ap), dot3(ac, ap)
	if d1 <= 0 && d2 <= 0 do return a
	bp := p - b
	d3, d4 := dot3(ab, bp), dot3(ac, bp)
	if d3 >= 0 && d4 <= d3 do return b
	vc := d1 * d4 - d3 * d2
	if vc <= 0 && d1 >= 0 && d3 <= 0 && d1 - d3 > 0 do return a + ab * (d1 / (d1 - d3))
	cp := p - c
	d5, d6 := dot3(ab, cp), dot3(ac, cp)
	if d6 >= 0 && d5 <= d6 do return c
	vb := d5 * d2 - d1 * d6
	if vb <= 0 && d2 >= 0 && d6 <= 0 && d2 - d6 > 0 do return a + ac * (d2 / (d2 - d6))
	va := d3 * d6 - d5 * d4
	if va <= 0 && d4 - d3 >= 0 && d5 - d6 >= 0 && (d4 - d3) + (d5 - d6) > 0 do return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
	if sum := va + vb + vc; sum > 0 do return a + ab * (vb / sum) + ac * (vc / sum)
	on_segment :: proc(p, from, to: [3]f64) -> [3]f64 {
		d := to - from
		l := dot3(d, d)
		return from + d * (clamp(dot3(p - from, d) / l, 0, 1) if l > 0 else 0)
	}
	q := on_segment(p, a, b)
	for e in ([2][2][3]f64{{b, c}, {c, a}}) {
		if r := on_segment(p, e[0], e[1]); dot3(r - p, r - p) < dot3(q - p, q - p) do q = r
	}
	return q
}

// The largest cosine of a corner of v's triangles with v at `at` (the smallest angle's),
// and where it is: the corner of v that names the triangle, and 0 for the angle at v, 1 at
// the next corner and 2 at the one before. A corner with no length counts as no angle.
@(private = "file")
ring_sharpest :: proc(m: ^Work_Mesh, v: u32, at: [3]f64) -> (cosine: f64, corner: u32, which: int) {
	cos_at :: #force_inline proc(o, p, q: [3]f64) -> f64 {
		u, v := p - o, q - o
		l := dot3(u, u) * dot3(v, v)
		return dot3(u, v) / math.sqrt(l) if l > 0 else 1
	}
	cosine, corner = -2, NONE
	start := m.corner[v]
	for c := start; c != NONE; c = ring_step(m, start, c) {
		p, q := m.pos[m.vert[corner_next(c)]], m.pos[m.vert[corner_prev(c)]]
		corners := [3]f64{cos_at(at, p, q), cos_at(p, q, at), cos_at(q, at, p)}
		for k in 0 ..< 3 do if corners[k] > cosine do cosine, corner, which = corners[k], c, k
	}
	return
}

// The smallest angles lifted: each free vertex of a triangle sharper than LIFT_BELOW
// tries a few places (its cell's centre, its neighbours' mean, and steps that open the
// sharpest angle of its triangles, each in its tangent plane and then back onto the
// island) and takes the one whose sharpest angle is widest, if that is wider than now.
// A move changes no angle but its own triangles', so the mesh's smallest angle never
// shrinks; the vertices that may move are found from the same positions on the pool,
// and moved in vertex order, so the result is the same on any thread count.
@(private = "file")
isotropic_lift :: proc(w: ^Isotropic_Work) {
	m := w.m
	nv := len(m.pos)
	resize(&w.moves, nv)
	resize(&w.normals, nv)
	for _ in 0 ..< LIFT_SWEEPS {
		jobs.parallel_ranges(w.pool, nv, w, proc(data: rawptr, lo, hi: int) {
			w := cast(^Isotropic_Work)data
			m := w.m
			for v in lo ..< hi {
				w.moves[v] = false
				start := m.corner[v]
				if start == NONE || m.featured[v] || m.twin[start] == NONE do continue
				cosine, _, _ := ring_sharpest(m, u32(v), m.pos[v])
				w.moves[v] = cosine > LIFT_COSINE
			}
		})
		lifted := false
		for v in 0 ..< u32(nv) {
			if !w.moves[v] do continue
			now, c, which := ring_sharpest(m, v, m.pos[v])
			if now <= LIFT_COSINE do continue
			normal := vertex_normal(m, v)
			p := m.pos[v]
			start := m.corner[v]
			mean, length, count := [3]f64{}, f64(0), 0
			for e := start; e != NONE; e = ring_step(m, start, e) {
				q := m.pos[m.vert[corner_next(e)]]
				mean += q
				length += math.sqrt(dot3(q - p, q - p))
				count += 1
			}
			if count == 0 do continue
			mean /= f64(count)
			length /= f64(count)
			tries: [6][3]f64
			n := 0
			if centre, ok := free_centre(m, v); ok {
				tries[n] = centre
				n += 1
			}
			tries[n] = mean
			n += 1
			// The way that opens the sharpest angle: away from the far side when it is
			// v's own, else round the corner it is at, away from the triangle's third
			// corner.
			a, b := m.pos[m.vert[corner_next(c)]], m.pos[m.vert[corner_prev(c)]]
			away: [3]f64
			switch which {
			case 0:
				away = p - 0.5 * (a + b)
			case 1:
				u := p - a
				away = (p - b) - u * (dot3(p - b, u) / max(dot3(u, u), 1e-300))
			case:
				u := p - b
				away = (p - a) - u * (dot3(p - a, u) / max(dot3(u, u), 1e-300))
			}
			away -= normal * dot3(away, normal)
			if l := math.sqrt(dot3(away, away)); l > 0 {
				for step in ([3]f64{0.3, 0.15, 0.075}) {
					tries[n] = p + away * (step * length / l)
					n += 1
				}
			}
			best, best_at, best_tri := now, p, m.near[v]
			for to in tries[:n] {
				flat := to - normal * dot3(to - p, normal)
				on, tri, ok := onto_island(w, v, flat, normal)
				if !ok || work_move_breaks(m, v, on) do continue
				if cosine, _, _ := ring_sharpest(m, v, on); cosine < best do best, best_at, best_tri = cosine, on, tri
			}
			if best < now {
				m.pos[v], m.near[v] = best_at, best_tri
				lifted = true
			}
		}
		if !lifted do break
	}
}

// The moves worked out from the same positions, made in vertex order, each unless it
// would flatten or turn over a triangle of the positions as they are by then.
@(private = "file")
isotropic_apply :: proc(w: ^Isotropic_Work) {
	m := w.m
	for v in 0 ..< len(m.pos) {
		if !w.moves[v] do continue
		if work_move_breaks(m, u32(v), w.moved[v]) do continue
		m.pos[v] = w.moved[v]
	}
}

// The remeshed island: its vertices in order, its triangles in order, the payload
// blurred into the quad size per vertex when the density asked for one, and the feature
// edges as corner flags when the caller gave features.
@(private = "file")
isotropic_output :: proc(m: ^Work_Mesh, flags, dense: bool) -> (out: Isotropic) {
	heap := runtime.heap_allocator()
	renumber := make([]u32, len(m.pos), heap)
	defer delete(renumber, heap)
	kept := 0
	for v in 0 ..< len(m.pos) {
		renumber[v] = NONE
		if m.corner[v] == NONE do continue
		renumber[v] = u32(kept)
		kept += 1
	}
	faces := 0
	for d in m.dead do if !d do faces += 1
	out.positions = make([][3]f64, kept, heap)
	out.triangles = make([][3]u32, faces, heap)
	payload := make([]f64, kept if dense else 0, heap)
	defer delete(payload, heap)
	for v in 0 ..< len(m.pos) {
		if renumber[v] == NONE do continue
		out.positions[renumber[v]] = m.pos[v]
		if dense do payload[renumber[v]] = m.payload[v]
	}
	if flags do out.corner_feature = make([]u8, 3 * faces, heap)
	f := 0
	sum, count := f64(0), 0
	for d, g in m.dead {
		if d do continue
		for k in 0 ..< 3 {
			c := u32(3 * g + k)
			out.triangles[f][k] = renumber[m.vert[c]]
			if flags && m.state[c] >= SHARP do out.corner_feature[3 * f + k] = 1
			// Each edge once: a border edge, or an inner one from its lower corner.
			if t := m.twin[c]; t == NONE || t > c {
				e := m.pos[m.vert[corner_next(c)]] - m.pos[m.vert[c]]
				sum += math.sqrt(dot3(e, e))
				count += 1
			}
		}
		f += 1
	}
	if count > 0 do out.mean_edge = sum / f64(count)
	if dense do out.vertex_scale = blurred_scale(payload, out.triangles, 4)
	return
}

// The quad size per vertex blurred in the log over `rounds` rounds of half toward the
// ring's mean, as the C++ blurs it: the field the size steers turns across the band a
// change is spread over, and a step one triangle wide asks it to turn on the spot, which
// it cannot, so a few pentagons came out there. Each triangle lists its other two corners
// in a vertex's ring, so an inner neighbour counts twice, as it did there.
@(private = "file")
blurred_scale :: proc(scale: []f64, triangles: [][3]u32, rounds: int) -> []f64 {
	heap := runtime.heap_allocator()
	n := len(scale)
	first := make([]u32, n + 1, heap)
	defer delete(first, heap)
	for t in triangles do for v in t do first[v + 1] += 2
	for v in 0 ..< n do first[v + 1] += first[v]
	ring := make([]u32, first[n], heap)
	defer delete(ring, heap)
	at := make([]u32, n, heap)
	defer delete(at, heap)
	copy(at, first[:n])
	for t in triangles do for k in 0 ..< 3 {
		v := t[k]
		ring[at[v]], ring[at[v] + 1] = t[(k + 1) % 3], t[(k + 2) % 3]
		at[v] += 2
	}
	logs := make([]f64, n, heap)
	defer delete(logs, heap)
	next := make([]f64, n, heap)
	defer delete(next, heap)
	for s, v in scale do logs[v] = math.ln(max(1e-6, s))
	for _ in 0 ..< rounds {
		for v in 0 ..< n {
			around := ring[first[v]:first[v + 1]]
			if len(around) == 0 {
				next[v] = logs[v]
				continue
			}
			sum := f64(0)
			for u in around do sum += logs[u]
			next[v] = 0.5 * logs[v] + 0.5 * sum / f64(len(around))
		}
		logs, next = next, logs
	}
	out := make([]f64, n, heap)
	for l, v in logs do out[v] = math.exp(l)
	return out
}

// Adaptivity's target edge per vertex (the shim's adaptiveTargetLengths): shorter where
// the surface turns more than three quarters of it does, by the normal's turn per length
// to the ring, up to 0.35 and down to 3 times the stage's edge, keeping the mean area the
// same; nil at no adaptivity. From the heap.
@(private = "file")
adaptive_target_lengths :: proc(positions: [][3]f64, triangles: [][3]u32, voxel_size, adaptivity: f64) -> []f64 {
	if !(adaptivity > 0) || len(positions) == 0 do return nil
	heap := runtime.heap_allocator()
	MIN_RATIO :: 0.35
	MAX_RATIO :: 3.0
	EPSILON :: 1e-12
	n := len(positions)
	areas := make([]f64, len(triangles), heap)
	defer delete(areas, heap)
	normals := make([][3]f64, n, heap)
	defer delete(normals, heap)
	first := make([]u32, n + 1, heap)
	defer delete(first, heap)
	for t, f in triangles {
		if t[0] >= u32(n) || t[1] >= u32(n) || t[2] >= u32(n) do continue
		areas[f] = triangle_area(positions[t[0]], positions[t[1]], positions[t[2]])
		if areas[f] <= EPSILON do continue
		c := cross3(positions[t[1]] - positions[t[0]], positions[t[2]] - positions[t[0]])
		unit := c / math.sqrt(dot3(c, c))
		for v in t {
			normals[v] += unit * areas[f]
			first[v + 1] += 2
		}
	}
	for v in 0 ..< n do first[v + 1] += first[v]
	ring := make([]u32, first[n], heap)
	defer delete(ring, heap)
	at := make([]u32, n, heap)
	defer delete(at, heap)
	copy(at, first[:n])
	for t, f in triangles {
		if t[0] >= u32(n) || t[1] >= u32(n) || t[2] >= u32(n) || areas[f] <= EPSILON do continue
		for k in 0 ..< 3 {
			v := t[k]
			ring[at[v]], ring[at[v] + 1] = t[(k + 1) % 3], t[(k + 2) % 3]
			at[v] += 2
		}
	}
	curvature := make([]f64, n, heap)
	defer delete(curvature, heap)
	for v in 0 ..< n {
		if l := math.sqrt(dot3(normals[v], normals[v])); l > 0 do normals[v] /= l
	}
	for v in 0 ..< n {
		around := ring[first[v]:first[v + 1]]
		slice.sort(around)
		if len(around) == 0 || dot3(normals[v], normals[v]) <= EPSILON do continue
		turned, length := f64(0), f64(0)
		for u, i in around {
			if i > 0 && around[i - 1] == u do continue
			e := positions[u] - positions[v]
			d := math.sqrt(dot3(e, e))
			if d <= EPSILON || dot3(normals[u], normals[u]) <= EPSILON do continue
			turned += math.acos(clamp(dot3(normals[v], normals[u]), -1, 1))
			length += d
		}
		if length > EPSILON do curvature[v] = turned / length
	}
	turning := make([dynamic]f64, 0, n, heap)
	defer delete(turning)
	for c in curvature do if c > EPSILON do append(&turning, c)
	if len(turning) == 0 do return nil
	slice.sort(turning[:])
	reference := max(turning[(len(turning) - 1) * 3 / 4], EPSILON)
	importance := make([]f64, n, heap)
	defer delete(importance, heap)
	strength := min(adaptivity, 2) * 7
	for &i, v in importance {
		k := min(4, curvature[v] / reference)
		i = 1 + strength * k * k
	}
	total, weighted := f64(0), f64(0)
	for t, f in triangles {
		if t[0] >= u32(n) || t[1] >= u32(n) || t[2] >= u32(n) do continue
		total += areas[f]
		weighted += areas[f] * (importance[t[0]] + importance[t[1]] + importance[t[2]]) / 3
	}
	if total <= EPSILON do return nil
	mean := weighted / total
	out := make([]f64, n, heap)
	for &o, v in out do o = voxel_size * clamp(math.sqrt(mean / importance[v]), MIN_RATIO, MAX_RATIO)
	return out
}

// Polylines (the caller's features, eased by feature_positions, or the creases) as
// segments no longer than `cell`, each filed under the cell its middle is in, so a point
// looks in the 27 cells round it for the segments within a cell of it.
@(private)
Segment_Grid :: struct {
	segments: [dynamic][2][3]f64,
	entries:  [dynamic]Segment_Entry, // sorted by cell
	cell:     f64,
}

@(private)
Segment_Entry :: struct {
	cell:    u64,
	segment: u32,
}

@(private = "file")
segment_cell :: #force_inline proc(p: [3]f64, cell: f64) -> [3]i64 {
	return {i64(math.floor(p.x / cell)), i64(math.floor(p.y / cell)), i64(math.floor(p.z / cell))}
}

@(private)
segment_grid_destroy :: proc(g: ^Segment_Grid) {
	delete(g.segments)
	delete(g.entries)
	g^ = {}
}

@(private = "file")
segment_grid_build :: proc(along: [][3]f64, edges: [][2]u32, cell: f64) -> (g: Segment_Grid) {
	heap := runtime.heap_allocator()
	g.segments = make([dynamic][2][3]f64, heap)
	g.entries = make([dynamic]Segment_Entry, heap)
	g.cell = cell
	if len(edges) == 0 || !(cell > 0) do return
	for e in edges {
		if e[0] >= u32(len(along)) || e[1] >= u32(len(along)) do continue
		a, b := along[e[0]], along[e[1]]
		d := b - a
		pieces := int(min(math.ceil(math.sqrt(dot3(d, d)) / cell), 1 << 16))
		pieces = max(pieces, 1)
		for k in 0 ..< pieces {
			from := a + d * (f64(k) / f64(pieces))
			to := a + d * (f64(k + 1) / f64(pieces))
			append(&g.entries, Segment_Entry{grid_key(segment_cell(0.5 * (from + to), cell)), u32(len(g.segments))})
			append(&g.segments, [2][3]f64{from, to})
		}
	}
	slice.sort_by(g.entries[:], proc(a, b: Segment_Entry) -> bool {return a.cell < b.cell || (a.cell == b.cell && a.segment < b.segment)})
	return
}

// The nearest point of the grid's segments to p within `reach` (and a cell), if any; of
// two equally near, the first segment's.
@(private = "file")
segment_grid_nearest :: proc(g: ^Segment_Grid, p: [3]f64, reach: f64) -> (q: [3]f64, ok: bool) {
	best := min(reach, g.cell)
	best *= best
	at := segment_cell(p, g.cell)
	for dx in i64(-1) ..= 1 do for dy in i64(-1) ..= 1 do for dz in i64(-1) ..= 1 {
		key := grid_key(at + {dx, dy, dz})
		i, _ := slice.binary_search_by(g.entries[:], key, proc(e: Segment_Entry, key: u64) -> slice.Ordering {return slice.cmp(e.cell, key)})
		for ; i < len(g.entries) && g.entries[i].cell == key; i += 1 {
			s := g.segments[g.entries[i].segment]
			d := s[1] - s[0]
			l := dot3(d, d)
			t := clamp(dot3(p - s[0], d) / l, 0, 1) if l > 0 else 0
			c := s[0] + d * t
			e := c - p
			if dd := dot3(e, e); dd < best {
				best, q, ok = dd, c, true
			}
		}
	}
	return
}

// Where the feature polylines run, per vertex (the shim's smoothedFeaturePositions): a
// vertex inside a chain (two feature edges) eased toward its chain neighbours a few
// times, each moved at most its own edges' length, so a border jagged at the triangles'
// scale (a polygroup's) reads as the curve it draws, as ZRemesher's SmoothGroups eases a
// group's border; a junction, a loose end, a `pinned` vertex (one on a crease, where a
// border that crosses it turns with the surface, which easing would cut through) and
// every other vertex stay. From the heap.
@(private = "file")
feature_positions :: proc(positions: [][3]f64, features: [][2]u32, pinned: []bool) -> [][3]f64 {
	heap := runtime.heap_allocator()
	n := len(positions)
	out := slice.clone(positions, heap)
	degree := make([]u8, n, heap)
	defer delete(degree, heap)
	chain := make([][2]u32, n, heap)
	defer delete(chain, heap)
	for e in features {
		if e[0] >= u32(n) || e[1] >= u32(n) do continue
		for k in 0 ..< 2 {
			v, u := e[k], e[1 - k]
			if degree[v] < 2 do chain[v][degree[v]] = u
			degree[v] = min(degree[v] + 1, 3)
		}
	}
	reach := make([]f64, n, heap)
	defer delete(reach, heap)
	if len(pinned) == n do for p, v in pinned do if p do degree[v] = 3
	for v in 0 ..< n {
		if degree[v] != 2 do continue
		a, b := positions[chain[v][0]] - positions[v], positions[chain[v][1]] - positions[v]
		reach[v] = 0.5 * (math.sqrt(dot3(a, a)) + math.sqrt(dot3(b, b)))
	}
	eased := make([][3]f64, n, heap)
	defer delete(eased, heap)
	for _ in 0 ..< 4 {
		copy(eased, out)
		for v in 0 ..< n {
			if degree[v] != 2 do continue
			middle := 0.5 * (out[chain[v][0]] + out[chain[v][1]])
			moved := out[v] + 0.5 * (middle - out[v])
			away := moved - positions[v]
			if d := math.sqrt(dot3(away, away)); d > reach[v] && d > 0 do moved = positions[v] + away * (reach[v] / d)
			eased[v] = moved
		}
		copy(out, eased)
	}
	return out
}
