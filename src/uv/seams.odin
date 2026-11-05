package uv

import pq "core:container/priority_queue"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:time"

import "../geom"
import "../jobs"

// Auto seams, as Blender's Smart UV Project, 3D-Coat's auto seams and xatlas's charts
// cut a surface: charts grown from seeds over triangles whose normals stay within a cone
// of the chart's mean, held back where an edge is a good place for a seam (a crease, a
// polygroup border, a hidden place), each chart then made a disc (one border loop, no
// handle) so it can lie flat. The seams are the edges between charts.

Seam_Options :: struct {
	cone:   f32, // the largest angle, in degrees, between a chart's triangles and its mean normal
	crease: f32, // how much a crease holds a chart back (its dihedral angle over 90°, times this)
	group:  f32, // how much a polygroup border does; at 1 or more it is never crossed
	hidden: f32, // how much a hidden place does (`hidden` per vertex, 0 seen to 1 hidden)
}

DEFAULT_SEAMS :: Seam_Options{66, 1, 1, 1}

// Chooses the seams of `u` (any it had are replaced) for the mesh `positions` and
// `indices` with `faces`, then finds the islands. `groups` (one a triangle) and `hidden`
// (one a vertex) may be nil. With `partner` (one a triangle: the other half of its quad,
// -1 for none; quad_partners), the two halves of a quad always share a chart, so no seam
// cuts a quad's diagonal and the UVs read as the quads' (to_quads). Returns how many
// charts it cut. Runs on the calling thread with temp memory; the result follows from the
// mesh alone.
auto_seams :: proc(u: ^Uvs, positions: []geom.Vec3, indices: []u32, faces: geom.Vertex_Faces, groups: []u16 = nil, hidden: []f32 = nil, options := DEFAULT_SEAMS, partner: []i32 = nil) -> (charts: int) {
	a := context.temp_allocator
	count := len(indices) / 3
	if count == 0 || len(u.corner) != count do return 0

	// Each triangle's neighbours, normal and area.
	across_of := make([][3]i32, count, a)
	normal := make([]geom.Vec3, count, a)
	area := make([]f32, count, a)
	for t in 0 ..< count {
		tri := indices[3 * t:][:3]
		n := linalg.cross(positions[tri[1]] - positions[tri[0]], positions[tri[2]] - positions[tri[0]])
		l := linalg.length(n)
		area[t] = l * 0.5
		normal[t] = n / l if l > 0 else {}
		for k in 0 ..< 3 {
			o, _, ok := across(indices, faces, u32(t), k)
			across_of[t][k] = i32(o) if ok else -1
		}
	}
	// How strongly each edge holds a chart back (0: not at all).
	hold := make([][3]f32, count, a)
	for t in 0 ..< count do for k in 0 ..< 3 {
		o := across_of[t][k]
		if o < 0 do continue
		h: f32 = 0
		bend := math.acos(clamp(linalg.dot(normal[t], normal[o]), -1, 1))
		h += options.crease * bend / (0.5 * math.PI)
		if groups != nil && groups[t] != groups[o] do h += options.group
		if hidden != nil {
			tri := indices[3 * t:][:3]
			h += options.hidden * 0.5 * (hidden[tri[k]] + hidden[tri[(k + 1) % 3]])
		}
		hold[t][k] = h
	}

	// Charts grown one at a time from the lowest triangle not yet in one: the candidate
	// with the least cost joins first (its turn from the chart's mean normal, the hold of
	// the edge it is reached across, less a little for each edge it shares with the
	// chart, so charts come out round), while its normal stays within the cone.
	chart := make([]i32, count, a)
	for &c in chart do c = -1
	cone := math.cos(math.to_radians(clamp(options.cone, 1, 179)))
	Candidate :: struct {
		cost: f32,
		tri:  i32,
	}
	queue: pq.Priority_Queue(Candidate)
	pq.init(&queue, proc(x, y: Candidate) -> bool {return x.cost < y.cost || (x.cost == y.cost && x.tri < y.tri)}, pq.default_swap_proc(Candidate), 64, a)
	cost_of :: proc(t: i32, c: i32, mean: geom.Vec3, chart: []i32, across_of: [][3]i32, hold: [][3]f32, normal: []geom.Vec3) -> (cost: f32, ok: bool) {
		m := linalg.normalize0(mean)
		d := linalg.dot(normal[t], m)
		cost = 1 - d
		worst: f32 = 0
		for k in 0 ..< 3 {
			o := across_of[t][k]
			if o >= 0 && chart[o] == c {
				worst = max(worst, hold[t][k])
				cost -= 0.05
			}
		}
		return cost + worst, worst < 1
	}
	for seed in 0 ..< count {
		if chart[seed] >= 0 do continue
		c := i32(charts)
		charts += 1
		mean: geom.Vec3
		pq.clear(&queue)
		// A triangle joins with its quad's other half, which needs no test of its own: a
		// seam across the diagonal is never wanted.
		join :: proc(t, c: i32, mean: ^geom.Vec3, chart: []i32, partner: []i32, normal: []geom.Vec3, area: []f32) -> (both: [2]i32, n: int) {
			chart[t] = c
			mean^ += normal[t] * area[t]
			both[0], n = t, 1
			if partner != nil && partner[t] >= 0 && chart[partner[t]] < 0 {
				p := partner[t]
				chart[p] = c
				mean^ += normal[p] * area[p]
				both[1], n = p, 2
			}
			return
		}
		joined, n := join(i32(seed), c, &mean, chart, partner, normal, area)
		for j in 0 ..< n do for k in 0 ..< 3 do if o := across_of[joined[j]][k]; o >= 0 && chart[o] < 0 {
			if cost, ok := cost_of(o, c, mean, chart, across_of, hold, normal); ok do pq.push(&queue, Candidate{cost, o})
		}
		for pq.len(queue) > 0 {
			next := pq.pop(&queue)
			t := next.tri
			if chart[t] >= 0 do continue
			if linalg.dot(normal[t], linalg.normalize0(mean)) < cone do continue
			if _, ok := cost_of(t, c, mean, chart, across_of, hold, normal); !ok do continue
			joined, n = join(t, c, &mean, chart, partner, normal, area)
			for j in 0 ..< n do for k in 0 ..< 3 do if o := across_of[joined[j]][k]; o >= 0 && chart[o] < 0 {
				if cost, ok := cost_of(o, c, mean, chart, across_of, hold, normal); ok do pq.push(&queue, Candidate{cost, o})
			}
		}
	}

	// Every chart made a disc: one that is not is split in two from its two triangles
	// farthest apart (in steps across edges), grown side by side, until each is.
	charts = discs(chart, charts, indices, across_of, partner)

	for &s, t in u.seam {
		s = {}
		for k in 0 ..< 3 do if o := across_of[t][k]; o >= 0 && chart[o] != chart[t] do s += {k}
	}
	islands_find(u, indices, faces)
	return
}

// Splits the charts that are not discs until every one is; returns the chart count. A
// chart is a disc when V - E + F is 1 and its border is one loop; one that is not is cut
// into the triangles nearer (in steps across edges) to one or the other of two that lie
// farthest apart, the lower on a tie, which leaves both halves connected. A quad's two
// halves (`partner`) go to the side of the lower of them, next to each other, so they
// stay connected too.
@(private = "file")
discs :: proc(chart: []i32, charts: int, indices: []u32, across_of: [][3]i32, partner: []i32) -> int {
	a := context.temp_allocator
	charts := charts
	count := len(chart)
	vertices := int(slice.max(indices)) + 1
	seen := make([]i32, vertices, a) // the test that last counted the vertex
	on_border := make([]i32, vertices, a)
	parent := make([]u32, vertices, a)
	for &x in seen do x = -1
	for &x in on_border do x = -1
	hops_a := make([]i32, count, a)
	hops_b := make([]i32, count, a)
	members := make([dynamic]i32, a)
	first_tri := make([dynamic]i32, charts, a)
	for &f in first_tri do f = -1
	for c, t in chart do if first_tri[c] < 0 do first_tri[c] = i32(t)
	todo := make([dynamic]i32, a)
	for c := charts - 1; c >= 0; c -= 1 do append(&todo, i32(c))
	root :: proc(parent: []u32, v: u32) -> u32 {
		v := v
		for parent[v] != v {
			parent[v] = parent[parent[v]]
			v = parent[v]
		}
		return v
	}
	test := i32(0)
	for len(todo) > 0 {
		c := pop(&todo)
		walk(first_tri[c], c, chart, across_of, &members, hops_a)
		f := len(members)
		if f <= 1 do continue
		test += 1
		v, border := 0, 0
		for t in members do for k in 0 ..< 3 {
			p := indices[3 * t + i32(k)]
			if seen[p] != test {
				seen[p] = test
				v += 1
			}
		}
		loops := 0
		for t in members do for k in 0 ..< 3 {
			o := across_of[t][k]
			if o >= 0 && chart[o] == c do continue
			border += 1
			for p in ([2]u32{indices[3 * t + i32(k)], indices[3 * t + i32((k + 1) % 3)]}) do if on_border[p] != test {
				on_border[p] = test
				parent[p] = p
				loops += 1
			}
		}
		for t in members do for k in 0 ..< 3 {
			o := across_of[t][k]
			if o >= 0 && chart[o] == c do continue
			p, q := root(parent, indices[3 * t + i32(k)]), root(parent, indices[3 * t + i32((k + 1) % 3)])
			if p != q {
				parent[max(p, q)] = min(p, q)
				loops -= 1
			}
		}
		if v - (3 * f + border) / 2 + f == 1 && loops == 1 do continue

		// The split.
		far_a := members[0]
		for t in members do if hops_a[t] > hops_a[far_a] do far_a = t
		walk(far_a, c, chart, across_of, &members, hops_a)
		far_b := far_a
		for t in members do if hops_a[t] > hops_a[far_b] do far_b = t
		walk(far_b, c, chart, across_of, &members, hops_b)
		half := i32(charts)
		side :: proc(t: i32, hops_a, hops_b, partner: []i32) -> bool {
			lo := t
			if partner != nil && partner[t] >= 0 do lo = min(t, partner[t])
			return hops_b[lo] < hops_a[lo]
		}
		in_half, in_c := i32(-1), i32(-1)
		for t in members {
			if side(t, hops_a, hops_b, partner) {
				if in_half < 0 do in_half = t
			} else if in_c < 0 do in_c = t
		}
		// A chart the pairs leave in one piece stays as it is rather than split forever.
		if in_half < 0 || in_c < 0 do continue
		// The walks start again from the two far ones where they stay on their sides.
		if side(far_b, hops_a, hops_b, partner) do in_half = far_b
		if !side(far_a, hops_a, hops_b, partner) do in_c = far_a
		charts += 1
		append(&first_tri, in_half)
		first_tri[c] = in_c
		for t in members do if side(t, hops_a, hops_b, partner) do chart[t] = half
		append(&todo, half, c)
	}
	return charts
}

// The triangles of chart `c` reached from `start` across edges, in that order, into
// `members`, each with its steps from `start` in `hops`.
@(private = "file")
walk :: proc(start, c: i32, chart: []i32, across_of: [][3]i32, members: ^[dynamic]i32, hops: []i32) {
	clear(members)
	append(members, start)
	hops[start] = 0
	// `hops` is only trusted for triangles already in `members`, so membership is
	// marked by a negative chart number while the walk runs and put back after.
	chart[start] = -c - 2
	for i := 0; i < len(members); i += 1 {
		t := members[i]
		for k in 0 ..< 3 do if o := across_of[t][k]; o >= 0 && chart[o] == c {
			chart[o] = -c - 2
			hops[o] = hops[t] + 1
			append(members, o)
		}
	}
	for t in members do chart[t] = c
}

Unwrap_Options :: struct {
	seams:      Seam_Options,
	keep_seams: bool,     // flatten along the seams the UVs have instead of cutting new ones
	method:     Method,
	relax:      int,      // stretch relax iterations after (0: none)
	symmetric:  bool,
	symmetry:   Symmetry,
}

DEFAULT_UNWRAP :: Unwrap_Options{DEFAULT_SEAMS, false, .Abf, 5, false, DEFAULT_SYMMETRY}

Unwrap_Report :: struct {
	charts:  int, // charts the auto seams cut (0 when the seams were kept)
	flatten: Flatten_Report,
	relax:   Relax_Report,
	ms:      f64,
	cancelled: bool,
}

// UVs in one call, as one tap gives them: auto seams (unless kept), every island
// flattened, relaxed and packed into the unit square. `partner` keeps quads whole
// (auto_seams). With `progress`, the stages move it (seams to 15 %, flattening to 80 %,
// relaxing the rest) and a cancel stops it between them, `cancelled` then set and `u`
// half made: the caller drops it.
unwrap :: proc(u: ^Uvs, positions: []geom.Vec3, indices: []u32, faces: geom.Vertex_Faces, groups: []u16 = nil, hidden: []f32 = nil, options := DEFAULT_UNWRAP, pool: ^jobs.Pool = nil, partner: []i32 = nil, progress: ^jobs.Progress = nil) -> (r: Unwrap_Report) {
	start := time.tick_now()
	defer r.ms = time.duration_milliseconds(time.tick_since(start))
	if !has(u^) do return
	if !options.keep_seams do r.charts = auto_seams(u, positions, indices, faces, groups, hidden, options.seams, partner)
	jobs.progress_set(progress, 0, 1, 0.15)
	if r.cancelled = jobs.progress_cancelled(progress); r.cancelled do return
	sym := options.symmetry
	at: ^Symmetry = &sym if options.symmetric else nil
	r.flatten = flatten(u, positions, indices, faces, options.method, pool, at)
	jobs.progress_set(progress, 0, 1, 0.8)
	if r.cancelled = jobs.progress_cancelled(progress); r.cancelled do return
	if options.relax > 0 do r.relax = relax(u, positions, indices, faces, options.relax, pool, at)
	jobs.progress_set(progress, 0, 1, 1)
	return
}

// Each triangle's other half of its quad in `q` (the triangles `indices` with `faces`
// are its halves), -1 where it is none, for auto_seams to keep quads whole; made with
// `allocator`. False when a triangle is no half of a quad.
quad_partners :: proc(q: geom.Quad_Mesh, indices: []u32, faces: geom.Vertex_Faces, allocator := context.allocator) -> (partner: []i32, ok: bool) {
	slots := half_slots(q, indices, faces) or_return
	count := len(indices) / 3
	halves := make([][2]i32, len(q.quads), context.temp_allocator)
	for &h in halves do h = {-1, -1}
	for t in 0 ..< count {
		s := int(slots[3 * t])
		halves[s / 6][s % 6 / 3] = i32(t)
	}
	partner = make([]i32, count, allocator)
	for t in 0 ..< count {
		s := int(slots[3 * t])
		partner[t] = halves[s / 6][1 - s % 6 / 3]
	}
	return partner, true
}
