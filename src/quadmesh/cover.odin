package quadmesh

import "base:runtime"
import "core:math"

// The quad cover: AutoRemesher's QuadParameterizer (MIT, by Jeremy Hu), whose steps and
// choices this follows, on the frame field and sizes the field gave (field.odin). Each triangle gets a UV per corner whose integer lines are the quads'
// edges. The field's four directions are first made to agree across a spanning tree of
// the triangles (each turned by quarter turns to its parent's), so every edge says by how
// many quarter turns its two triangles' frames differ. A face beside a sharp or feature
// edge gets that edge held along an integer line. The field's curl is then taken out as
// far as a small turn and stretch of each triangle can (a least squares over the face
// turns and log sizes), so the cover's gradients can follow it. The edges whose frames
// differ, and a tree's worth of the rest, are the seam: across a seam edge the two
// triangles' UVs differ by the quarter turns and a translation of even integers. The UVs
// are then the least squares fit of each triangle's edges to its frame at its size, every
// edge's corners tied as the seam allows, solved with every integer rounded at once
// (mixed.odin). None of it but the curl correction's numbers and the fit's depends on the
// scaling, so the frames' turns, the holds, the seam, the constraints' elimination and the
// solves' orderings are made once (Cover_Plan) for all of the landing's covers. Every
// solve gives the same bits on any thread count, so the cover does too.

// A corner's edge held along a line of the grid: none, a line of constant u, of constant v.
@(private = "file")
Edge_Hold :: enum i8 {
	None,
	U,
	V,
}

// The quarter turns, as AutoRemesher's quarterTurn table.
@(private = "file")
QUARTER_TURN := [4][2][2]f64{{{1, 0}, {0, 1}}, {{0, 1}, {-1, 0}}, {{-1, 0}, {0, -1}}, {{0, -1}, {1, 0}}}

// How far (degrees) a hard edge may lie from a frame direction and still be held along it.
@(private = "file")
HOLD_DEGREES :: 10.0

// The curl correction's regularization, and how far it may turn (radians) and stretch.
@(private = "file")
CURL_REGULARIZATION :: 1e-4
@(private = "file")
CURL_TURN_LIMIT :: 0.3
@(private = "file")
CURL_STRETCH_LIMIT :: 1.5

@(private = "file")
Cover_Work :: struct {
	s:        Surface,
	normal:   [][3]f64, // per triangle, AutoRemesher's unit normal
	field:    [][3]f64, // per triangle, its frame's direction
	before:   [][3]f64, // and before the spanning tree turned it
	rotation: []i8, // per corner: the quarter turns from the other triangle's frame to this one's
	hold:     []Edge_Hold, // per corner
	seam:     []bool, // per corner
	su, sv:   []f64, // per triangle: the stretch along the frame and across it
	sizes:    []f64, // per triangle: the quad size
	features: []u8,
}

// What the landing's covers share: everything of the cover that does not depend on the
// scaling, and the solves' orderings and structures.
Cover_Plan :: struct {
	w:           Cover_Work,
	turn_weight: []f64, // per triangle, a guided one's hold on its turn; nil for none
	mixed:       Mixed,
	kernel:      int,
	seam_edges:  int, // edges inside the mesh the seam cuts, for the checks
	singular:    []u32,
	mean_edge:   f64,
	curl:        Least_System,
	free:        Least_System,
	held:        Least_System,
}

// One quad cover of the isotropic mesh at `scaling` times its mean edge, on `field`;
// `face_guides` (one a triangle, or nil) holds a guided face's turn through the curl
// correction as firmly as its guide pulled.
odin_cover :: proc(iso: Isotropic, field: Field, face_guides: [][3]f64, scaling, sharp_degrees: f64, run: ^Stage_Run, reason: ^Reason, checks: ^Checks) -> (out: Cover, err: Stage_Error) {
	plan: Cover_Plan
	defer cover_plan_destroy(&plan)
	plan, err = odin_cover_plan(iso, field, face_guides, sharp_degrees, run, reason)
	if err != .None do return
	return odin_cover_at(&plan, scaling, run, reason, checks)
}

// The cover's work that does not depend on the scaling (progress 0 to 0.35 of a cover).
odin_cover_plan :: proc(iso: Isotropic, field: Field, face_guides: [][3]f64, sharp_degrees: f64, run: ^Stage_Run, reason: ^Reason) -> (plan: Cover_Plan, err: Stage_Error) {
	heap := runtime.heap_allocator()
	context.allocator = heap
	faces := len(iso.triangles)
	if faces == 0 || len(iso.positions) == 0 || len(field.directions) != faces || len(field.sizes) != faces {
		reason_set(reason, "Quad cover solve failed")
		return {}, .Failed
	}
	if !stage_report(run, 0) do return {}, .Cancelled
	w := &plan.w
	w.s = surface_build(iso.positions, iso.triangles, run.pool if run != nil else nil)
	s := &w.s
	corners := 3 * faces
	w.features = iso.corner_feature if len(iso.corner_feature) == corners else nil
	plan.mean_edge = mean_edge_length(s)

	w.normal = make([][3]f64, faces)
	w.field = make([][3]f64, faces)
	w.su = make([]f64, faces)
	w.sv = make([]f64, faces)
	w.sizes = make([]f64, faces)
	for f in 0 ..< faces {
		w.normal[f] = unit_else(s.normal[f], {0, 0, 1})
		w.field[f] = unit_else(field.directions[f], surface_edge(s, u32(3 * f)))
		w.sizes[f] = field.sizes[f][0]
		w.su[f] = field.sizes[f][1]
		w.sv[f] = field.sizes[f][2]
	}
	w.before = make([][3]f64, faces)
	copy(w.before, w.field)
	if !stage_report(run, 0.04) {
		cover_plan_destroy(&plan)
		return {}, .Cancelled
	}
	brush_along_tree(w)
	w.rotation = make([]i8, corners)
	for c in 0 ..< corners do if s.opp[c] != NONE do w.rotation[c] = i8(edge_quarter_turn(w, u32(c)))
	w.hold = make([]Edge_Hold, corners)
	for c in 0 ..< corners do w.hold[c] = edge_hold(w, u32(c), sharp_degrees, w.features != nil && w.features[c] != 0)
	for f in 0 ..< faces {
		before := unit_else(w.before[f], w.field[f])
		after := unit_else(w.field[f], before)
		across := unit_else(cross3(w.normal[f], after), before)
		if abs(dot3(before, after)) < abs(dot3(before, across)) do w.su[f], w.sv[f] = w.sv[f], w.su[f]
	}
	if len(face_guides) == faces {
		plan.turn_weight = make([]f64, faces)
		for g, f in face_guides do plan.turn_weight[f] = length3(g)
	}
	w.seam = cut_seam(w)
	for c in 0 ..< corners do if w.seam[c] && s.opp[c] != NONE && u32(c) < s.opp[c] do plan.seam_edges += 1
	if !stage_report(run, 0.14) {
		cover_plan_destroy(&plan)
		return {}, .Cancelled
	}
	singular := make([dynamic]u32)
	for v in 0 ..< len(iso.positions) {
		sum := 0
		border := false
		for c in s.corners[s.first[v]:s.first[v + 1]] {
			sum = (sum + int(w.rotation[c])) % 4
			if s.opp[c] == NONE do border = true
		}
		if !border && sum != 0 do append(&singular, u32(v))
	}
	plan.singular = singular[:]
	plan.mixed = cover_system(w, cover_pin(w, plan.singular))
	plan.kernel = mixed_finalize(&plan.mixed)
	if !stage_report(run, 0.2) {
		cover_plan_destroy(&plan)
		return {}, .Cancelled
	}
	return plan, .None
}

cover_plan_destroy :: proc(plan: ^Cover_Plan) {
	heap := runtime.heap_allocator()
	cover_work_destroy(&plan.w)
	delete(plan.turn_weight, heap)
	mixed_destroy(&plan.mixed)
	delete(plan.singular, heap)
	least_system_destroy(&plan.curl)
	least_system_destroy(&plan.free)
	least_system_destroy(&plan.held)
	plan^ = {}
}

// One cover on the plan at `scaling` (progress 0.2 to 1 of a cover): the curl correction,
// then the fit and its integers: the cover at that scaling.
odin_cover_at :: proc(plan: ^Cover_Plan, scaling: f64, run: ^Stage_Run, reason: ^Reason, checks: ^Checks) -> (out: Cover, err: Stage_Error) {
	heap := runtime.heap_allocator()
	context.allocator = heap
	w := &plan.w
	s := &w.s
	faces := len(s.triangles)
	if faces == 0 || !(scaling > 0) || plan.kernel == 0 {
		reason_set(reason, "Quad cover solve failed")
		return {}, .Failed
	}
	scale := max(1e-12, scaling * plan.mean_edge)
	report :: proc(data: rawptr, fraction: f32) -> bool {
		return stage_report(cast(^Stage_Run)data, 0.35 + 0.63 * (0.3 + 0.65 * fraction))
	}
	field := make([][3]f64, faces)
	defer delete(field)
	copy(field, w.field)
	su := make([]f64, faces)
	defer delete(su)
	copy(su, w.su)
	sv := make([]f64, faces)
	defer delete(sv)
	copy(sv, w.sv)
	if !stage_report(run, 0.2) do return {}, .Cancelled
	correct_curl(plan, field, su, sv, scale)
	if !stage_report(run, 0.35 + 0.63 * 0.3) do return {}, .Cancelled
	cover_energy(plan, field, su, sv, scale)
	solved, integers, stopped := mixed_solve(&plan.mixed, &plan.free, &plan.held, s.pool, report, run)
	if stopped do return {}, .Cancelled
	if !solved {
		reason_set(reason, "Quad cover solve failed")
		return {}, .Failed
	}

	if !stage_report(run, 0.99) do return {}, .Cancelled
	out.uvs = make([][3][2]f64, faces)
	for f in 0 ..< faces do for k in 0 ..< 3 {
		c := 3 * f + k
		for j in 0 ..< 2 {
			x := mixed_value(&plan.mixed, 2 * c + j)
			n := math.round(x)
			out.uvs[f][k][j] = n if abs(x - n) < 0.01 else x
		}
	}
	out.singular = make([]u32, len(plan.singular))
	copy(out.singular, plan.singular)
	if checks != nil {
		checks.cover_seam = plan.seam_edges
		checks.cover_unknowns = plan.kernel
		checks.cover_integers = integers
	}
	_ = stage_report(run, 1)
	return out, .None
}

@(private = "file")
cover_work_destroy :: proc(w: ^Cover_Work) {
	heap := runtime.heap_allocator()
	surface_destroy(&w.s)
	delete(w.normal, heap)
	delete(w.field, heap)
	delete(w.before, heap)
	delete(w.rotation, heap)
	delete(w.hold, heap)
	delete(w.seam, heap)
	delete(w.su, heap)
	delete(w.sv, heap)
	delete(w.sizes, heap)
	w^ = {}
}

// `v` made unit, or `fallback` made unit when `v` is nearly zero (AutoRemesher's unit()).
@(private = "file")
unit_else :: #force_inline proc(v, fallback: [3]f64) -> [3]f64 {
	l := length3(v)
	if l < 1e-12 {
		m := length3(fallback)
		return {} if m <= math.F64_EPSILON else fallback / m
	}
	return v / l
}

// The mean length of the edges, each counted once (SurfaceMesh::averageEdgeLength).
@(private = "file")
mean_edge_length :: proc(s: ^Surface) -> f64 {
	total := f64(0)
	count := 0
	for c in 0 ..< len(s.opp) {
		o := s.opp[c]
		if o != NONE && int(o) < c do continue
		total += length3(surface_edge(s, u32(c)))
		count += 1
	}
	return 0 if count == 0 else total / f64(count)
}

// The quarter turns from triangle g's frame to triangle f's across corner c's edge, the
// lower triangle's view taken and the higher's its inverse (edgeQuarterTurn).
@(private = "file")
edge_quarter_turn :: proc(w: ^Cover_Work, c: u32) -> int {
	s := &w.s
	o := s.opp[c]
	if o == NONE do return 0
	f, g := c / 3, o / 3
	if f > g do return (4 - edge_quarter_turn(w, o)) % 4
	v0, v1 := surface_vertex(s, c), surface_vertex(s, corner_next(c))
	if v1 < v0 do v0, v1 = v1, v0
	e := unit_else(s.positions[v1] - s.positions[v0], {1, 0, 0})
	y0 := unit_else(cross3(w.normal[f], e), {0, 1, 0})
	yg := unit_else(cross3(w.normal[g], e), {0, 1, 0})
	a0 := math.atan2(dot3(w.field[f], y0), dot3(w.field[f], e))
	best := 0
	best_error := f64(1e100)
	candidate := w.field[g]
	for r in 0 ..< 4 {
		ag := math.atan2(dot3(candidate, yg), dot3(candidate, e))
		d := abs(a0 - ag)
		for d > math.PI do d = abs(d - 2 * math.PI)
		if d < best_error {
			best_error = d
			best = r
		}
		candidate = cross3(w.normal[g], candidate)
	}
	return best
}

// Turns each triangle's frame by quarter turns to agree with its parent's in a breadth
// first tree from triangle 0 (brushFieldAlongSpanningTree).
@(private = "file")
brush_along_tree :: proc(w: ^Cover_Work) {
	s := &w.s
	faces := len(s.triangles)
	seen := make([]bool, faces)
	defer delete(seen)
	queue := make([]u32, faces)
	defer delete(queue)
	head, tail := 0, 1
	seen[0] = true
	for head < tail {
		f := queue[head]
		head += 1
		for l in u32(0) ..< 3 {
			c := 3 * f + l
			o := s.opp[c]
			if o == NONE do continue
			g := o / 3
			if seen[g] do continue
			turns := edge_quarter_turn(w, c)
			brushed := w.field[g]
			for _ in 0 ..< turns do brushed = cross3(w.normal[g], brushed)
			w.field[g] = unit_else(brushed, surface_edge(s, 3 * g))
			seen[g] = true
			queue[tail] = g
			tail += 1
		}
	}
}

// Whether corner c's edge is held along a line of the grid, and which (edgeConstraint): a
// feature edge or a crease sharper than `sharp_degrees` lying within HOLD_DEGREES of one
// of the frame's directions and not of the other, and a border edge always, along the
// nearer. AutoRemesher held a border as a crease, but it never saw one (it closes holes
// first); Keep symmetry's half goes in open, and its cut must end on lines of the grid all
// round for the mirror to close: where the cut
// turns sharply its triangle's frame follows one edge, the next lies 30 or 40 degrees off
// it, and left free, the quads stopped short of the plane there.
@(private = "file")
edge_hold :: proc(w: ^Cover_Work, c: u32, sharp_degrees: f64, flagged: bool) -> Edge_Hold {
	s := &w.s
	if !flagged && s.opp[c] != NONE && abs(s.dihedral[c]) * 180.0 / math.PI < sharp_degrees do return .None
	f := c / 3
	edge := unit_else(surface_edge(s, c), {1, 0, 0})
	b := unit_else(w.field[f], edge)
	br := unit_else(cross3(w.normal[f], b), {0, 1, 0})
	if s.opp[c] == NONE do return .V if abs(dot3(edge, b)) >= abs(dot3(edge, br)) else .U
	limit := HOLD_DEGREES * math.PI / 180.0
	along_b := math.acos(clamp(abs(dot3(edge, b)), -1, 1)) < limit
	along_br := math.acos(clamp(abs(dot3(edge, br)), -1, 1)) < limit
	if along_b == along_br do return .None
	return .V if along_b else .U
}

// Takes the field's curl out as far as a small turn and stretch of each triangle can
// (applyCurlCorrection): each inner edge asks that it come out as the same step in the
// grid seen from either triangle, linearized in each triangle's turn and log stretches;
// a triangle with a held edge keeps its turn. The turns are kept within
// CURL_TURN_LIMIT radians and the stretches within CURL_STRETCH_LIMIT, and the stretches
// are then scaled together so the cover's area in cells stays as it was.
@(private = "file")
correct_curl :: proc(plan: ^Cover_Plan, field: [][3]f64, w_su, w_sv: []f64, scale: f64) {
	w := &plan.w
	turn_weight := plan.turn_weight
	s := &w.s
	faces := len(s.triangles)
	su := make([]f64, faces)
	defer delete(su)
	sv := make([]f64, faces)
	defer delete(sv)
	across := make([][3]f64, faces)
	defer delete(across)
	for f in 0 ..< faces {
		size := max(1e-12, w.sizes[f])
		su[f] = scale * size * max(1e-12, w_su[f])
		sv[f] = scale * size * max(1e-12, w_sv[f])
		across[f] = unit_else(cross3(w.normal[f], field[f]), surface_edge(s, u32(3 * f)))
	}
	anchored := make([]bool, faces)
	defer delete(anchored)
	for c in 0 ..< len(w.hold) do if w.hold[c] != .None do anchored[c / 3] = true

	Request :: struct {
		constant, turn, along, across: [2]f64,
	}
	request :: proc(w: ^Cover_Work, field: [][3]f64, su, sv: []f64, across: [][3]f64, c, f: u32) -> (q: Request) {
		e := surface_edge(&w.s, c)
		a := dot3(field[f], e)
		b := dot3(across[f], e)
		q.constant = {a / su[f], b / sv[f]}
		q.turn = {b / su[f], -a / sv[f]}
		q.along = {-a / su[f], 0}
		q.across = {0, -b / sv[f]}
		return
	}
	rows := least_rows_make()
	defer least_rows_destroy(&rows)
	edges := 0
	for c in 0 ..< len(s.opp) {
		o := s.opp[c]
		if o == NONE || int(o) < c do continue
		f, g := u32(c / 3), o / 3
		r := int(w.rotation[c])
		here := request(w, field, su, sv, across, u32(c), f)
		there := request(w, field, su, sv, across, o, g)
		turned :: #force_inline proc(v: [2]f64, r, k: int) -> f64 {return QUARTER_TURN[r][k][0] * v[0] + QUARTER_TURN[r][k][1] * v[1]}
		for k in 0 ..< 2 {
			residual := here.constant[k] + turned(there.constant, r, k)
			row := [6]Coeff {
				{i32(3 * f), here.turn[k]},
				{i32(3 * f + 1), here.along[k]},
				{i32(3 * f + 2), here.across[k]},
				{i32(3 * g), turned(there.turn, r, k)},
				{i32(3 * g + 1), turned(there.along, r, k)},
				{i32(3 * g + 2), turned(there.across, r, k)},
			}
			least_rows_add(&rows, row[:], -residual, 1)
		}
		edges += 1
	}
	if edges == 0 do return
	fixed := make([]bool, 3 * faces)
	defer delete(fixed)
	for f in 0 ..< faces {
		if anchored[f] {
			fixed[3 * f] = true
		} else {
			least_rows_add(&rows, {{i32(3 * f), 1}}, 0, CURL_REGULARIZATION + (turn_weight[f] if turn_weight != nil else 0))
		}
		least_rows_add(&rows, {{i32(3 * f + 1), 1}}, 0, CURL_REGULARIZATION)
		least_rows_add(&rows, {{i32(3 * f + 2), 1}}, 0, CURL_REGULARIZATION)
	}
	correction := make([]f64, 3 * faces)
	defer delete(correction)
	held := make([]f64, 3 * faces)
	defer delete(held)
	if !least_squares(&plan.curl, &rows, 3 * faces, fixed, held, correction, s.pool, 3) do return

	stretch_limit := math.ln(f64(CURL_STRETCH_LIMIT))
	for f in 0 ..< faces {
		angle := max(-CURL_TURN_LIMIT, min(CURL_TURN_LIMIT, correction[3 * f]))
		field[f] = unit_else(math.cos(angle) * field[f] + math.sin(angle) * across[f], field[f])
		w_su[f] *= math.exp(max(-stretch_limit, min(stretch_limit, correction[3 * f + 1])))
		w_sv[f] *= math.exp(max(-stretch_limit, min(stretch_limit, correction[3 * f + 2])))
	}
	area_before, area_after := f64(0), f64(0)
	for f in 0 ..< faces {
		size := max(1e-12, w.sizes[f])
		area := length3(cross3(surface_edge(s, u32(3 * f)), -surface_edge(s, u32(3 * f + 2))))
		area_before += area / (su[f] * sv[f])
		su[f] = scale * size * max(1e-12, w_su[f])
		sv[f] = scale * size * max(1e-12, w_sv[f])
		area_after += area / (su[f] * sv[f])
	}
	if area_before > 0 && area_after > 0 {
		factor := math.sqrt(area_after / area_before)
		for f in 0 ..< faces {
			w_su[f] *= factor
			w_sv[f] *= factor
		}
	}
}

// The seam (computeSeam): every edge outside a breadth first tree of the triangles from
// triangle 0 that crosses only edges whose frames agree, and the border; then the seam's
// loose ends whose frames agree are trimmed back, so it runs between the singular vertices
// and the border.
@(private = "file")
cut_seam :: proc(w: ^Cover_Work) -> []bool {
	s := &w.s
	faces, corners := len(s.triangles), len(s.opp)
	inside := make([]bool, corners)
	defer delete(inside)
	seen := make([]bool, faces)
	defer delete(seen)
	queue := make([]u32, faces)
	defer delete(queue)
	head, tail := 0, 1
	seen[0] = true
	for head < tail {
		f := queue[head]
		head += 1
		for l in u32(0) ..< 3 {
			c := 3 * f + l
			o := s.opp[c]
			if o == NONE || w.rotation[c] != 0 do continue
			g := o / 3
			if seen[g] do continue
			seen[g] = true
			queue[tail] = g
			tail += 1
			inside[c], inside[o] = true, true
		}
	}
	seam := make([]bool, corners)
	degree := make([]i32, len(s.positions))
	defer delete(degree)
	for c in 0 ..< corners {
		seam[c] = s.opp[c] == NONE || !inside[c]
		if seam[c] do degree[surface_vertex(s, u32(c))] += 1
	}
	// A vertex with one seam edge is a loose end: its edge goes when its frames agree, and
	// the vertex at the edge's other end may then be one. Taking the loose ends in any
	// order leaves the same seam as AutoRemesher's passes over the corners.
	stack := make([dynamic]u32)
	defer delete(stack)
	for v in 0 ..< len(s.positions) do if degree[v] == 1 do append(&stack, u32(v))
	for len(stack) > 0 {
		v := pop(&stack)
		if degree[v] != 1 do continue
		for c in s.corners[s.first[v]:s.first[v + 1]] {
			o := s.opp[c]
			if o == NONE || !seam[c] || w.rotation[c] != 0 do continue
			v1 := surface_vertex(s, corner_next(c))
			seam[c], seam[o] = false, false
			degree[v] -= 1
			if degree[v1] > 0 do degree[v1] -= 1
			if degree[v1] == 1 do append(&stack, v1)
			break
		}
	}
	return seam
}

// The corner whose UV is pinned at the origin. The pin only picks where the lattice starts
// in the free solve, but the rounding counts from it and the held solve keeps it on a
// lattice point, so its vertex lands a whole number of quads from every held edge's line.
// AutoRemesher pinned corner 0 wherever it lay: less than a quad from a held border, the strip
// between was taken to nothing (a notch the mirror could not close) or stretched to a quad.
// With an edge held, the pin goes where the cover has a lattice point anyway: at a
// singular vertex, which the turned translations round it leave on one, else at a corner
// whose two edges hold both its coordinates, else at a held corner, whose held coordinate
// is an integer anyway. With none held, corner 0 stays: there is no line for it to pinch a
// strip against, and over a sweep of spheres the two choices folded and filled as often.
@(private = "file")
cover_pin :: proc(w: ^Cover_Work, singular: []u32) -> int {
	s := &w.s
	held := false
	for h in w.hold do if h != .None {
		held = true
		break
	}
	if !held do return 0
	if len(singular) > 0 {
		v := singular[0]
		lowest := max(u32)
		for c in s.corners[s.first[v]:s.first[v + 1]] do lowest = min(lowest, c)
		return int(lowest)
	}
	for c in 0 ..< len(w.hold) {
		p := corner_prev(u32(c))
		if w.hold[c] != .None && w.hold[p] != .None && w.hold[c] != w.hold[p] do return c
	}
	for c in 0 ..< len(w.hold) do if w.hold[c] != .None do return c
	return 0
}

// The cover's mixed integer least squares (solveQuadCover). Unknowns: two UVs a corner,
// in its triangle's chart, then two translations a corner, of period 2, across its edge.
// Each triangle's edges are fitted to its frame at its size, weighted by the quad's area
// (cover_energy gives the numbers; the rows' pattern is the same at every scaling);
// corner `pin` (cover_pin) is pinned at the origin; across an edge off the seam the
// translation is zero, across the seam the two corners' translations are each other's
// turned back; each corner's UV is the matching corner's across its edge, turned and
// translated; round a vertex whose frames come back to themselves the translations sum to
// zero; and a held edge keeps one coordinate along it, an integer.
@(private = "file")
cover_system :: proc(w: ^Cover_Work, pin: int) -> (m: Mixed) {
	s := &w.s
	corners := len(s.opp)
	uv_count := 2 * corners
	m = mixed_make(2 * uv_count)
	for t in 0 ..< uv_count do mixed_set_period(&m, uv_count + t, 2)
	// Energy row 2c + k is corner c's edge in coordinate k.
	for c in 0 ..< corners {
		n := int(corner_next(u32(c)))
		mixed_energy(&m, 2 * n, 1, 2 * c, -1, 0, 1)
		mixed_energy(&m, 2 * n + 1, 1, 2 * c + 1, -1, 0, 1)
	}
	mixed_constraint(&m, {i32(2 * pin), 1})
	mixed_constraint(&m, {i32(2 * pin + 1), 1})
	for c in 0 ..< corners {
		o := s.opp[c]
		if o == NONE do continue
		tc, to := i32(uv_count + 2 * c), i32(uv_count + 2 * int(o))
		if w.seam[c] {
			switch w.rotation[c] {
			case 0:
				mixed_constraint(&m, {tc, 1}, {to, 1})
				mixed_constraint(&m, {tc + 1, 1}, {to + 1, 1})
			case 1:
				mixed_constraint(&m, {tc, 1}, {to + 1, 1})
				mixed_constraint(&m, {tc + 1, 1}, {to, -1})
			case 2:
				mixed_constraint(&m, {tc, 1}, {to, -1})
				mixed_constraint(&m, {tc + 1, 1}, {to + 1, -1})
			case:
				mixed_constraint(&m, {tc, 1}, {to + 1, -1})
				mixed_constraint(&m, {tc + 1, 1}, {to, 1})
			}
		} else {
			mixed_constraint(&m, {tc, 1})
			mixed_constraint(&m, {tc + 1, 1})
		}
	}
	for c in 0 ..< corners {
		o := s.opp[c]
		if o == NONE do continue
		other := i32(corner_next(o))
		uc := i32(2 * c)
		tc := i32(uv_count + 2 * c)
		switch w.rotation[c] {
		case 0:
			mixed_constraint(&m, {uc, 1}, {2 * other, -1}, {tc, -1})
			mixed_constraint(&m, {uc + 1, 1}, {2 * other + 1, -1}, {tc + 1, -1})
		case 1:
			mixed_constraint(&m, {uc, 1}, {2 * other + 1, -1}, {tc, -1})
			mixed_constraint(&m, {uc + 1, 1}, {2 * other, 1}, {tc + 1, -1})
		case 2:
			mixed_constraint(&m, {uc, 1}, {2 * other, 1}, {tc, -1})
			mixed_constraint(&m, {uc + 1, 1}, {2 * other + 1, 1}, {tc + 1, -1})
		case:
			mixed_constraint(&m, {uc, 1}, {2 * other + 1, 1}, {tc, -1})
			mixed_constraint(&m, {uc + 1, 1}, {2 * other, -1}, {tc + 1, -1})
		}
	}
	wheel := make([dynamic][2]i32)
	defer delete(wheel)
	row := make([dynamic]Coeff)
	defer delete(row)
	for v in 0 ..< len(s.positions) {
		incident := s.corners[s.first[v]:s.first[v + 1]]
		if len(incident) == 0 do continue
		start := incident[0]
		c := start
		turns := 0
		closed := true
		clear(&wheel)
		for {
			o := s.opp[c]
			if o == NONE {
				closed = false
				break
			}
			append(&wheel, [2]i32{i32(c), i32(turns)})
			turns = (turns + int(w.rotation[c])) % 4
			c = corner_next(o)
			if c == start || len(wheel) > len(incident) + 1 do break
		}
		if !closed || c != start || turns != 0 do continue
		for coordinate in 0 ..< 2 {
			clear(&row)
			for item in wheel {
				t := i32(uv_count) + 2 * item[0]
				switch item[1] {
				case 0:
					append(&row, Coeff{t + i32(coordinate), 1})
				case 1:
					append(&row, Coeff{t + 1, 1} if coordinate == 0 else Coeff{t, -1})
				case 2:
					append(&row, Coeff{t + i32(coordinate), -1})
				case:
					append(&row, Coeff{t + 1, -1} if coordinate == 0 else Coeff{t, 1})
				}
			}
			mixed_constraint(&m, ..row[:])
		}
	}
	for c in 0 ..< corners {
		n := int(corner_next(u32(c)))
		switch w.hold[c] {
		case .V:
			mixed_set_period(&m, 2 * c + 1, 1)
			mixed_set_period(&m, 2 * n + 1, 1)
			mixed_constraint(&m, {i32(2 * c + 1), 1}, {i32(2 * n + 1), -1})
		case .U:
			mixed_set_period(&m, 2 * c, 1)
			mixed_set_period(&m, 2 * n, 1)
			mixed_constraint(&m, {i32(2 * c), 1}, {i32(2 * n), -1})
		case .None:
		}
	}
	return m
}

// The fit's numbers at a scaling: each corner's edge in its triangle's frame over the
// quad's size there, weighted by the quad's area, into the reduced rows they became.
@(private = "file")
cover_energy :: proc(plan: ^Cover_Plan, field: [][3]f64, su, sv: []f64, scale: f64) {
	w := &plan.w
	s := &w.s
	faces := len(s.triangles)
	rhs := make([]f64, 6 * faces)
	defer delete(rhs)
	weight := make([]f64, 3 * faces)
	defer delete(weight)
	for f in 0 ..< faces {
		u := field[f]
		v := unit_else(cross3(w.normal[f], u), surface_edge(s, u32(3 * f)))
		size := max(1e-12, w.sizes[f])
		fu := scale * size * max(1e-12, su[f])
		fv := scale * size * max(1e-12, sv[f])
		for l in 0 ..< 3 {
			c := 3 * f + l
			e := surface_edge(s, u32(c))
			rhs[2 * c] = dot3(u, e) / fu
			rhs[2 * c + 1] = dot3(v, e) / fv
			weight[c] = fu * fv
		}
	}
	m := &plan.mixed
	for e, r in m.source {
		m.reduced.rhs[r] = rhs[e]
		m.reduced.weight[r] = weight[e / 2]
	}
}
