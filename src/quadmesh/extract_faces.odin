package quadmesh

import "base:runtime"
import "core:math"
import "core:slice"

import "../geom"

// The extraction's faces (extract.odin finds the quad vertices and traces their
// edges): the cycles the traced edges close, and the holes a fold or a flipped triangle
// left filled. A hole whose border walks round a piece of the grid gets that piece's cells
// as quads (lattice_patch: the fold unfolded, its layers zipped where they meet); any other
// is cut into the squarest ladder or fan of quads that adds no edge the mesh already has.
// The mesh is then checked, and a patch that tore it is cut instead, so the result is
// closed and manifold wherever the cover was.

// ---- Faces ---------------------------------------------------------------------------

// The polygons the matched slots close (extract_cycles), in quad vertices, each corner
// with its grid point in the polygon's own chart where the walk round it closes.
@(private = "file")
Cycles :: struct {
	first:   [dynamic]u32, // polygon p's corners are corners[first[p]:first[p + 1]]
	corners: [dynamic]u32,
	lattice: [dynamic][2]i32, // per corner: its grid point, when the polygon is walked
	walked:  [dynamic]bool, // per polygon: its walk closed, each corner at one grid point
	uses:    []u32, // per quad vertex: the polygons it is a corner of
}

@(private = "file")
cycles_destroy :: proc(c: ^Cycles, heap: runtime.Allocator) {
	delete(c.first)
	delete(c.corners)
	delete(c.lattice)
	delete(c.walked)
	delete(c.uses, heap)
}

// The faces: the cycles, the larger ones filled (extract_emit), and, where a patch left the
// mesh torn, emitted again with that patch cut as a ladder instead (PATCH_TRIES at most).
@(private)
extract_faces :: proc(x: ^Extractor, target: []u32) -> (out: Quads) {
	cy := extract_cycles(x, target)
	defer cycles_destroy(&cy, x.heap)
	disabled := make([]bool, len(cy.walked), x.heap)
	defer delete(disabled, x.heap)
	for _ in 0 ..< PATCH_TRIES {
		torn: bool
		out, torn = extract_emit(x, &cy, disabled)
		if !torn do return
	}
	// Still torn: no patches, which cannot tear.
	for &d in disabled do d = true
	out, _ = extract_emit(x, &cy, disabled)
	return
}

// The most times the faces are emitted again with patches that tore the mesh cut as ladders.
@(private = "file")
PATCH_TRIES :: 4

// The cycles the matched slots close: a slot's next is the matched slot before its partner
// round the partner's vertex, so each cycle runs round one face with the face on its left.
// A cycle with the border on its left is the border and makes no face. Where a fold or a
// hole leaves an edge walked there and back in one cycle (a spike into the face, or two
// traces of one edge with nothing between them), the walk is taken out, and a cycle it
// empties is dropped.
@(private = "file")
extract_cycles :: proc(x: ^Extractor, target: []u32) -> (cy: Cycles) {
	n := len(x.slots)
	matched := make([]bool, n, x.heap)
	defer delete(matched, x.heap)
	for t, s in target {
		matched[s] = t != NONE && target[t] == u32(s)
		if !matched[s] do x.unmatched += 1
	}
	before := make([]u32, n, x.heap) // the matched slot before each, round its vertex
	defer delete(before, x.heap)
	ring := make([dynamic]u32, 0, 8, x.heap)
	defer delete(ring)
	for v in 0 ..< len(x.vertices) {
		clear(&ring)
		for s in x.slot_first[v] ..< x.slot_first[v + 1] do if matched[s] do append(&ring, s)
		for s, i in ring do before[s] = ring[(i + len(ring) - 1) % len(ring)]
	}
	seen := make([]bool, n, x.heap)
	defer delete(seen, x.heap)
	cy.first = make([dynamic]u32, 0, n / 4 + 2, x.heap)
	cy.corners = make([dynamic]u32, 0, n, x.heap)
	cy.lattice = make([dynamic][2]i32, 0, n, x.heap)
	cy.walked = make([dynamic]bool, 0, n / 4 + 1, x.heap)
	cy.uses = make([]u32, len(x.vertices), x.heap)
	last := make([]i32, len(x.vertices), x.heap) // the last polygon each vertex was counted in
	defer delete(last, x.heap)
	for &l in last do l = -1
	cycle := make([dynamic]u32, 0, 8, x.heap)
	defer delete(cycle)
	cycle_slots := make([dynamic]u32, 0, 8, x.heap)
	defer delete(cycle_slots)
	at := make([dynamic][2]i32, 0, 8, x.heap)
	defer delete(at)
	bay := make([dynamic]u32, 0, 8, x.heap)
	defer delete(bay)
	for s0 in 0 ..< n {
		if !matched[s0] || seen[s0] do continue
		clear(&cycle)
		clear(&cycle_slots)
		on_border := false
		s := u32(s0)
		for _ in 0 ..< n {
			seen[s] = true
			append(&cycle, x.slots[s].vertex)
			append(&cycle_slots, s)
			on_border ||= x.slots[s].left == LEFT_BORDER
			s = before[target[s]]
			if s == u32(s0) do break
		}
		if on_border {
			border_bays(x, &cy, cycle[:], cycle_slots[:], last, &bay)
			continue
		}
		walked := len(cycle) > 4 && len(cycle) <= WALK_CORNERS && lattice_walk(x, cycle_slots[:], target, before, &at)
		// Each vertex at one grid point, or the polygon is not walked.
		if walked {
			check: for v, i in cycle do for j in 0 ..< i {
				if cycle[j] == v && at[j] != at[i] {
					walked = false
					break check
				}
			}
		}
		raw := len(cycle)
		collapse_spikes(&cycle)
		if len(cycle) < 3 {
			x.dropped += 1
			continue
		}
		p := i32(len(cy.walked))
		append(&cy.first, u32(len(cy.corners)))
		append(&cy.corners, ..cycle[:])
		for v in cycle {
			point: [2]i32
			if walked do for j in 0 ..< raw do if x.slots[cycle_slots[j]].vertex == v {
				point = at[j]
				break
			}
			append(&cy.lattice, point)
			if last[v] != p {
				last[v] = p
				cy.uses[v] += 1
			}
		}
		append(&cy.walked, walked)
	}
	append(&cy.first, u32(len(cy.corners)))
	return
}

// A hole that reaches the border joins the border's cycle: each run of that cycle's slots
// with no border on their left is the hole's side, from where it leaves the border to where
// it comes back. Its polygon, closed by an edge from that end back to the start where the
// border would run, is filled as any hole is (not walked: the closing edge is no traced
// one), when it has at most BAY_CORNERS. Left open, the border makes a bay there: a fold of
// the cover beside a mirrored half's cut, where the mirror then cannot close the seam.
@(private = "file")
border_bays :: proc(x: ^Extractor, cy: ^Cycles, cycle, cycle_slots: []u32, last: []i32, bay: ^[dynamic]u32) {
	k := len(cycle)
	start := -1
	for s, j in cycle_slots do if x.slots[s].left == LEFT_BORDER {
		start = j
		break
	}
	if start < 0 do return
	// Slot j runs from cycle[j] to cycle[j + 1]; the walk starts on the border.
	off :: proc(x: ^Extractor, cycle_slots: []u32, j: int) -> bool {return x.slots[cycle_slots[j % len(cycle_slots)]].left != LEFT_BORDER}
	for j := 0; j < k; {
		if !off(x, cycle_slots, start + j) {
			j += 1
			continue
		}
		m := 0
		for j + m < k && off(x, cycle_slots, start + j + m) do m += 1
		clear(bay)
		for i in 0 ..= m do append(bay, cycle[(start + j + i) % k])
		j += m
		collapse_spikes(bay)
		if len(bay) < 3 || len(bay) > BAY_CORNERS do continue
		x.bays += 1
		p := i32(len(cy.walked))
		append(&cy.first, u32(len(cy.corners)))
		append(&cy.corners, ..bay[:])
		for v in bay {
			append(&cy.lattice, [2]i32{})
			if last[v] != p {
				last[v] = p
				cy.uses[v] += 1
			}
		}
		append(&cy.walked, false)
	}
}

// The most corners a bay's polygon may have to be filled (border_bays): a fold beside the
// border is a few quads across, and a longer run's closing edge would cut across the
// border's own curve.
@(private = "file")
BAY_CORNERS :: 16

// The most corners a hole's polygon may have to be walked in the grid.
@(private = "file")
WALK_CORNERS :: 1024

// Walks cycle `slots` in the grid: each corner's grid point, in the chart of the first
// slot's vertex, into `at`, a unit step a side. Each step's direction is its slot's turned
// into its vertex's chart and from there into the walk's, which the step before gave: the
// step into a vertex arrives opposite its partner slot. Leaving a vertex by a slot past the
// one it arrived by (round the end of its slots) crosses where its fan's charts are cut,
// which turns them by the fan's turn. False when the walk does not come back to its start
// the way it left: a singularity inside, or charts that disagree.
@(private = "file")
lattice_walk :: proc(x: ^Extractor, slots: []u32, target, before: []u32, at: ^[dynamic][2]i32) -> bool {
	clear(at)
	p := [2]i32{0, 0}
	r := u8(0) // the current vertex's chart to the walk's
	for s, k in slots {
		slot := x.slots[s]
		d := (slot.dir + slot.rot + r) & 3
		append(at, p)
		p += unit(d)
		t := target[s]
		back := x.slots[t]
		r = (d + 2 - back.dir - back.rot) & 3
		next := slots[(k + 1) % len(slots)]
		if next >= t do r = (r + x.turn[back.vertex]) & 3
	}
	return p == {0, 0} && r == 0
}

@(private = "file")
unit :: proc(d: u8) -> [2]i32 {
	switch d & 3 {
	case 1: return {0, 1}
	case 2: return {-1, 0}
	case 3: return {0, -1}
	}
	return {1, 0}
}

// The points the faces are made over while they are emitted: the quad vertices first, then
// the patches' and fans' new points; the merges a patch makes, and who made each point.
@(private = "file")
Emit :: struct {
	pos:     [dynamic][3]f64,
	alias:   [dynamic]u32, // per point: the point it was merged into, or itself
	owner:   [dynamic]i32, // per point: the patch that moved, merged or made it, or -1
	edges:   map[u64]u32, // per edge: the polygon sides and cuts that use it
	first:   [dynamic]u32,
	corners: [dynamic]u32, // in points, before the merges
	grid:    Surface_Grid, // the isotropic mesh's triangles by place, made when a new point first needs it
}

@(private = "file")
find :: proc(alias: []u32, v: u32) -> u32 {
	r := v
	for alias[r] != r do r = alias[r]
	return r
}

@(private = "file")
add_point :: proc(e: ^Emit, p: [3]f64, owner: i32) -> u32 {
	id := u32(len(e.pos))
	append(&e.pos, p)
	append(&e.alias, id)
	append(&e.owner, owner)
	return id
}

// The faces of the cycles: a polygon of up to four sides as it is, a larger one filled
// with its grid cells where its walk closed (lattice_patch), else cut into quads, as the
// squarer of a ladder and a fan round a new centre gives them. Then each face's corners go
// through the merges, and the mesh is checked: an edge of one face or of three or more, or
// a face with a corner twice, at a patch's point marks that patch (every one it finds),
// and `torn` says to emit again without them.
@(private = "file")
extract_emit :: proc(x: ^Extractor, cy: ^Cycles, disabled: []bool) -> (out: Quads, torn: bool) {
	x.filled, x.patched, x.bad_cuts, x.largest_cut = 0, 0, 0, 0
	e := Emit {
		pos     = make([dynamic][3]f64, 0, len(x.vertices) + 64, x.heap),
		alias   = make([dynamic]u32, 0, len(x.vertices) + 64, x.heap),
		owner   = make([dynamic]i32, 0, len(x.vertices) + 64, x.heap),
		edges   = make(map[u64]u32, len(cy.corners), x.heap),
		first   = make([dynamic]u32, 0, len(cy.walked) + 64, x.heap),
		corners = make([dynamic]u32, 0, len(cy.corners) + 256, x.heap),
	}
	defer {
		delete(e.pos)
		delete(e.alias)
		delete(e.owner)
		delete(e.edges)
		delete(e.first)
		delete(e.corners)
		surface_grid_destroy(&e.grid, x.heap)
	}
	for p in x.quad_pos do add_point(&e, p, -1)
	polygons := len(cy.walked)
	for p in 0 ..< polygons {
		c := cy.corners[cy.first[p]:cy.first[p + 1]]
		for v, i in c do e.edges[edge_key(v, c[(i + 1) % len(c)])] += 1
	}
	// The patches first, so a ladder's rungs never stand in a patch's way, then the rest.
	patched := make([]bool, polygons, x.heap)
	defer delete(patched, x.heap)
	for p in 0 ..< polygons {
		c := cy.corners[cy.first[p]:cy.first[p + 1]]
		if len(c) <= 4 {
			append(&e.first, u32(len(e.corners)))
			append(&e.corners, ..c)
			continue
		}
		x.filled += 1
		x.largest_cut = max(x.largest_cut, len(c))
		if cy.walked[p] && !disabled[p] && lattice_patch(x, &e, cy, p) {
			x.patched += 1
			patched[p] = true
		}
	}
	for p in 0 ..< polygons {
		c := cy.corners[cy.first[p]:cy.first[p + 1]]
		if len(c) <= 4 || patched[p] do continue
		// Else the squarer of a ladder and a fan round a centre on the surface.
		r, ladder_quality := ladder_plan(&e, c)
		centre: [3]f64
		for v in c do centre += e.pos[find(e.alias[:], v)]
		centre /= f64(len(c))
		if !e.grid.built do surface_grid_build(&e.grid, x.positions, x.triangles, x.heap)
		centre = surface_grid_closest(&e.grid, x.positions, x.triangles, centre)
		s, fan_quality := -1, -math.INF_F64
		if len(c) <= FAN_CORNERS do s, fan_quality = fan_plan(&e, c, centre)
		switch {
		case s >= 0 && (r < 0 || fan_quality > ladder_quality):
			fan_emit(&e, c, s, add_point(&e, centre, -1))
		case r >= 0:
			ladder_emit(&e, c, r)
		case:
			// Neither: a fan though it joins a corner twice, which the check then finds.
			x.bad_cuts += 1
			fan_emit(&e, c, 0, add_point(&e, centre, -1))
		}
	}
	append(&e.first, u32(len(e.corners)))
	// Through the merges, then the check.
	for &v in e.corners do v = find(e.alias[:], v)
	faces := len(e.first) - 1
	keys := make([]u64, len(e.corners), x.heap)
	defer delete(keys, x.heap)
	mark :: proc(e: ^Emit, disabled: []bool, v: u32) -> bool {
		o := e.owner[v]
		if o < 0 || disabled[o] do return false
		disabled[o] = true
		return true
	}
	for f in 0 ..< faces {
		q := e.corners[e.first[f]:e.first[f + 1]]
		if repeats(q) do for v in q do if mark(&e, disabled, v) do torn = true
		for v, i in q do keys[int(e.first[f]) + i] = edge_key(v, q[(i + 1) % len(q)])
	}
	slice.sort(keys)
	for i := 0; i < len(keys); {
		j := i + 1
		for j < len(keys) && keys[j] == keys[i] do j += 1
		if j - i != 2 {
			if mark(&e, disabled, u32(keys[i] >> 32)) do torn = true
			if mark(&e, disabled, u32(keys[i] & 0xffffffff)) do torn = true
		}
		i = j
	}
	if torn do return {}, true
	// The points the faces use, in order of first use.
	used := make([]u32, len(e.pos), x.heap)
	defer delete(used, x.heap)
	for &u in used do u = NONE
	positions := make([dynamic][3]f64, 0, len(e.pos), x.heap)
	for &v in e.corners {
		if used[v] == NONE {
			used[v] = u32(len(positions))
			append(&positions, e.pos[v])
		}
		v = used[v]
	}
	first := make([dynamic]u32, 0, len(e.first), x.heap)
	append(&first, ..e.first[:])
	corners := make([dynamic]u32, 0, len(e.corners), x.heap)
	append(&corners, ..e.corners[:])
	return Quads{positions = positions[:], first = first[:], corners = corners[:]}, false
}

// ---- Lattice patches -------------------------------------------------------------------

// A hole's polygon whose walk closed is the border of a piece of the grid: its corners'
// grid points bound the cells it encloses, each once (a winding of one; none or more than
// one, as a fold that the walk wraps twice gives, is not a patch). Those cells are its
// quads, over its corners and new points inside; corners that land on one grid point
// become one vertex (a fold's two layers zipped together). The patch is taken only where
// it keeps the mesh closed and manifold and its topology what the polygon's was: every
// edge it touches has two faces, no new edge runs where one already is, and the vertices
// less edges plus faces it changes come out even. The new points lie where the patch's
// border pulls them (each the mean of its four neighbours) and then on the surface.
@(private = "file")
lattice_patch :: proc(x: ^Extractor, e: ^Emit, cy: ^Cycles, p: int) -> bool {
	from, to := cy.first[p], cy.first[p + 1]
	c := cy.corners[from:to]
	lattice := cy.lattice[from:to]
	n := len(c)
	lo, hi := lattice[0], lattice[0]
	for q in lattice do lo, hi = {min(lo.x, q.x), min(lo.y, q.y)}, {max(hi.x, q.x), max(hi.y, q.y)}
	w, h := int(hi.x - lo.x), int(hi.y - lo.y)
	if w * h > PATCH_CELLS do return false
	heap := x.heap
	// The winding round each cell: each step up along x = X counts for the cells left of it
	// in its row, each step down against them.
	winding := make([]i32, max(w * h, 1), heap)
	defer delete(winding, heap)
	for k in 0 ..< n {
		a, b := lattice[k] - lo, lattice[(k + 1) % n] - lo
		if a.x != b.x do continue
		row := int(min(a.y, b.y))
		sign := i32(1) if b.y > a.y else -1
		for i in 0 ..< int(a.x) do winding[row * w + i] += sign
	}
	cells := 0
	for v in winding[:w * h] {
		if v != 0 && v != 1 do return false
		cells += int(v)
	}
	cell :: proc(winding: []i32, w, h, i, j: int) -> i32 {
		if i < 0 || j < 0 || i >= w || j >= h do return 0
		return winding[j * w + i]
	}
	// Grid points: a corner's vertex (the first at each point; the others merge into it),
	// else a new point inside, made as a cell needs it.
	stride := w + 1
	point := make([]u32, stride * (h + 1), heap)
	defer delete(point, heap)
	for &q in point do q = NONE
	Merge :: struct {
		into, from: u32,
	}
	merges := make([dynamic]Merge, 0, 4, heap)
	defer delete(merges)
	for v, k in c {
		g := lattice[k] - lo
		at := int(g.y) * stride + int(g.x)
		if point[at] == NONE {
			point[at] = v
			continue
		}
		if point[at] == v do continue
		known := false
		for m in merges do known ||= m.from == v
		if !known do append(&merges, Merge{point[at], v})
	}
	path_points := 0
	for q in point do if q != NONE do path_points += 1
	inner := make([dynamic]int, 0, 16, heap) // the new points' grid indices
	defer delete(inner)
	NEW :: max(u32) - 1
	for j in 0 ..< h do for i in 0 ..< w {
		if winding[j * w + i] == 0 do continue
		for at in ([4]int{j * stride + i, j * stride + i + 1, (j + 1) * stride + i + 1, (j + 1) * stride + i}) {
			if point[at] == NONE {
				point[at] = NEW
				append(&inner, at)
			}
		}
	}
	// The edges: each side of the polygon has the faces outside it (the polygons using it
	// less this one's own sides on it), and each grid edge the cells beside it; every grid
	// edge the polygon runs along must come to two.
	Side :: struct {
		grid: int, // 2 a grid point, + 1 for the edge up from it rather than right
		key:  u64,
	}
	sides := make([]Side, n, heap)
	defer delete(sides, heap)
	for k in 0 ..< n {
		a, b := lattice[k] - lo, lattice[(k + 1) % n] - lo
		g := min(int(a.y) * stride + int(a.x), int(b.y) * stride + int(b.x))
		sides[k] = {2 * g + (1 if a.x == b.x else 0), edge_key(c[k], c[(k + 1) % n])}
	}
	slice.sort_by(sides, proc(a, b: Side) -> bool {return a.grid < b.grid || (a.grid == b.grid && a.key < b.key)})
	edges_before, edges_after := 0, 0
	for i := 0; i < n; {
		j := i
		outside := 0
		for j < n && sides[j].grid == sides[i].grid {
			k := j
			for k < n && sides[k].grid == sides[i].grid && sides[k].key == sides[j].key do k += 1
			outside += int(e.edges[sides[j].key]) - (k - j)
			edges_before += 1
			j = k
		}
		g := sides[i].grid
		gi, gj := (g / 2) % stride, (g / 2) / stride
		beside := cell(winding, w, h, gi, gj) + (cell(winding, w, h, gi - 1, gj) if g % 2 == 1 else cell(winding, w, h, gi, gj - 1))
		if outside + int(beside) != 2 do return false
		edges_after += 1
		i = j
	}
	// Cell edges the polygon does not run along are new: inside the patch, never where an
	// edge already is between two of its corners.
	on_path := make(map[int]bool, n, heap)
	defer delete(on_path)
	for s in sides do on_path[s.grid] = true
	for j in 0 ..= h do for i in 0 ..= w {
		for up in 0 ..< 2 {
			if up == 0 && i == w do continue
			if up == 1 && j == h do continue
			g := 2 * (j * stride + i) + up
			if on_path[g] do continue
			beside := cell(winding, w, h, i, j) + (cell(winding, w, h, i - 1, j) if up == 1 else cell(winding, w, h, i, j - 1))
			if beside == 0 do continue
			edges_after += 1
			a := point[j * stride + i]
			b := point[(j + up) * stride + i + (1 - up)]
			if a != NEW && b != NEW && edge_key(a, b) in e.edges do return false
		}
	}
	// What the patch changes of vertices less edges plus faces must be nothing.
	distinct_before := path_points + len(merges)
	used_after := len(inner)
	for j in 0 ..= h do for i in 0 ..= w {
		v := point[j * stride + i]
		if v == NONE || v == NEW do continue
		corner_of := cell(winding, w, h, i, j) + cell(winding, w, h, i - 1, j) + cell(winding, w, h, i, j - 1) + cell(winding, w, h, i - 1, j - 1) > 0
		outside := cy.uses[v] >= 2
		for m in merges do if m.into == v do outside ||= cy.uses[m.from] >= 2
		if corner_of || outside do used_after += 1
	}
	if (used_after - distinct_before) - (edges_after - edges_before) + (cells - 1) != 0 do return false
	// Taken: the merges, each kept vertex at its group's mean.
	owner := i32(p)
	for m in merges {
		e.alias[m.from] = m.into
		e.owner[m.from] = owner
	}
	for v in c {
		r := find(e.alias[:], v)
		e.owner[r] = owner
	}
	if len(merges) > 0 {
		for m in merges {
			members := 1
			sum := x.quad_pos[m.into]
			for o in merges do if o.into == m.into {
				sum += x.quad_pos[o.from]
				members += 1
			}
			e.pos[m.into] = sum / f64(members)
		}
	}
	for at in inner do point[at] = add_point(e, {}, owner)
	// The new points (and the merged ones, which the zip moved off the surface) relaxed
	// with the border held, then onto the surface.
	if len(inner) > 0 {
		middle: [3]f64
		for v in c do middle += e.pos[find(e.alias[:], v)]
		middle /= f64(n)
		for at in inner do e.pos[point[at]] = middle
		rounds := min(4 * max(w, h) * max(w, h), 400)
		// Every cell round a new point is the patch's (no side of the polygon passes it, so
		// the winding is the same all round), so its four neighbours are all points.
		for _ in 0 ..< rounds {
			for at in inner {
				sum: [3]f64
				for nb in ([4]int{at - 1, at + 1, at - stride, at + stride}) do sum += e.pos[find(e.alias[:], point[nb])]
				e.pos[point[at]] = sum / 4
			}
		}
	}
	if len(inner) > 0 || len(merges) > 0 {
		if !e.grid.built do surface_grid_build(&e.grid, x.positions, x.triangles, heap)
		for at in inner do e.pos[point[at]] = surface_grid_closest(&e.grid, x.positions, x.triangles, e.pos[point[at]])
		for m in merges do e.pos[m.into] = surface_grid_closest(&e.grid, x.positions, x.triangles, e.pos[m.into])
	}
	// The cells, and their new edges (two faces each) for the cuts after; the polygon's own
	// sides keep the count they have.
	for j in 0 ..< h do for i in 0 ..< w {
		if winding[j * w + i] == 0 do continue
		append(&e.first, u32(len(e.corners)))
		append(&e.corners, point[j * stride + i], point[j * stride + i + 1], point[(j + 1) * stride + i + 1], point[(j + 1) * stride + i])
	}
	for j in 0 ..= h do for i in 0 ..= w {
		for up in 0 ..< 2 {
			if (up == 0 && i == w) || (up == 1 && j == h) || on_path[2 * (j * stride + i) + up] do continue
			beside := cell(winding, w, h, i, j) + (cell(winding, w, h, i - 1, j) if up == 1 else cell(winding, w, h, i, j - 1))
			if beside > 0 do e.edges[edge_key(point[j * stride + i], point[(j + up) * stride + i + (1 - up)])] += 2
		}
	}
	return true
}

// The most cells a hole's patch may span (its box) before it is cut as a ladder instead.
@(private = "file")
PATCH_CELLS :: 1 << 16

// ---- The surface, for placing new points ---------------------------------------------

// The isotropic mesh's triangles filed by the cells of a grid of SURFACE_CELL mean edges
// their boxes touch, sorted by cell, for the nearest point of the surface to a patch's new
// point.
@(private = "file")
Surface_Grid :: struct {
	built:   bool,
	size:    f64,
	origin:  [3]f64,
	entries: [dynamic]Grid_Entry,
}

@(private = "file")
Grid_Entry :: struct {
	cell:     u64,
	triangle: u32,
}

@(private = "file")
SURFACE_CELL :: 2.0

@(private = "file")
surface_grid_destroy :: proc(g: ^Surface_Grid, heap: runtime.Allocator) {
	delete(g.entries)
	g^ = {}
}

@(private = "file")
grid_cell :: proc(g: ^Surface_Grid, p: [3]f64) -> [3]i64 {
	q := (p - g.origin) / g.size
	return {i64(math.floor(q.x)), i64(math.floor(q.y)), i64(math.floor(q.z))}
}

// A grid cell's key: 21 bits an axis, so cells far apart may share a key, which only
// adds candidates a query then measures.
@(private)
grid_key :: proc(c: [3]i64) -> u64 {
	return u64(c.x & 0x1fffff) << 42 | u64(c.y & 0x1fffff) << 21 | u64(c.z & 0x1fffff)
}

@(private = "file")
surface_grid_build :: proc(g: ^Surface_Grid, positions: [][3]f64, triangles: [][3]u32, heap: runtime.Allocator) {
	g.built = true
	if len(triangles) == 0 do return
	length := f64(0)
	g.origin = positions[triangles[0][0]]
	for t in triangles {
		for k in 0 ..< 3 {
			d := positions[t[(k + 1) % 3]] - positions[t[k]]
			length += math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
			for a in 0 ..< 3 do g.origin[a] = min(g.origin[a], positions[t[k]][a])
		}
	}
	g.size = max(SURFACE_CELL * length / f64(3 * len(triangles)), 1e-12)
	g.entries = make([dynamic]Grid_Entry, 0, 2 * len(triangles), heap)
	for t, f in triangles {
		a, b, c := positions[t[0]], positions[t[1]], positions[t[2]]
		lo := grid_cell(g, {min(a.x, b.x, c.x), min(a.y, b.y, c.y), min(a.z, b.z, c.z)})
		hi := grid_cell(g, {max(a.x, b.x, c.x), max(a.y, b.y, c.y), max(a.z, b.z, c.z)})
		for i in lo.x ..= hi.x do for j in lo.y ..= hi.y do for k in lo.z ..= hi.z do append(&g.entries, Grid_Entry{grid_key({i, j, k}), u32(f)})
	}
	slice.sort_by(g.entries[:], proc(a, b: Grid_Entry) -> bool {return a.cell < b.cell || (a.cell == b.cell && a.triangle < b.triangle)})
}

// The nearest point of the triangles filed within a cell of `p`'s (two when none is), or
// `p` itself when none is filed there.
@(private = "file")
surface_grid_closest :: proc(g: ^Surface_Grid, positions: [][3]f64, triangles: [][3]u32, p: [3]f64) -> [3]f64 {
	if len(g.entries) == 0 do return p
	centre := grid_cell(g, p)
	best, best_d := p, math.INF_F64
	for reach in 1 ..= 2 {
		r := i64(reach)
		for i in -r ..= r do for j in -r ..= r do for k in -r ..= r {
			key := grid_key(centre + {i, j, k})
			at, _ := slice.binary_search_by(g.entries[:], key, proc(e: Grid_Entry, key: u64) -> slice.Ordering {
				return slice.Ordering.Less if e.cell < key else slice.Ordering.Greater
			})
			for ; at < len(g.entries) && g.entries[at].cell == key; at += 1 {
				t := triangles[g.entries[at].triangle]
				to_f32 :: proc(v: [3]f64) -> geom.Vec3 {return {f32(v.x), f32(v.y), f32(v.z)}}
				q, _ := geom.closest_on_triangle(to_f32(p), to_f32(positions[t[0]]), to_f32(positions[t[1]]), to_f32(positions[t[2]]))
				qd := [3]f64{f64(q.x), f64(q.y), f64(q.z)}
				d := qd - p
				dd := d.x * d.x + d.y * d.y + d.z * d.z
				if dd < best_d do best, best_d = qd, dd
			}
		}
		if best_d < math.INF_F64 do break
	}
	return best
}

// An undirected edge's key: its smaller vertex, then its larger.
@(private)
edge_key :: #force_inline proc(a, b: u32) -> u64 {
	return u64(min(a, b)) << 32 | u64(max(a, b))
}

// Takes out of cycle `c` every walk along an edge and straight back (a, b, a becomes a) and
// every vertex repeated in a row, round the cycle's end too, until none is left.
@(private = "file")
collapse_spikes :: proc(c: ^[dynamic]u32) {
	n := 0
	for v in c {
		if n >= 1 && c[n - 1] == v do continue
		if n >= 2 && c[n - 2] == v {
			n -= 1
			continue
		}
		c[n] = v
		n += 1
	}
	resize(c, n)
	// Round the end: the cycle's last vertices against its first.
	for len(c) >= 2 {
		m := len(c)
		if c[m - 1] == c[0] {
			resize(c, m - 1)
		} else if m >= 3 && c[m - 2] == c[0] {
			resize(c, m - 2)
		} else if m >= 3 && c[m - 1] == c[1] {
			ordered_remove(c, 0)
			ordered_remove(c, 0)
		} else {
			break
		}
	}
	if len(c) == 2 do clear(c)
}

// Whether quad or triangle `q` has a corner twice.
@(private = "file")
repeats :: proc(q: []u32) -> bool {
	for a, i in q do for b in q[i + 1:] do if a == b do return true
	return false
}

// How square a polygon of three or four corners is: the least over its corners of the
// sine of the corner's angle, signed by the polygon's normal, so 1 for a square, nearer
// 0 the thinner a corner, and below 0 for a corner turned over.
@(private = "file")
shape_quality :: proc(q: [][3]f64) -> f64 {
	n := len(q)
	normal: [3]f64
	for k in 0 ..< n do normal += cross3(q[k], q[(k + 1) % n])
	length := math.sqrt(dot3(normal, normal))
	if !(length > 0) do return -1
	normal /= length
	worst := f64(1)
	for k in 0 ..< n {
		before, after := q[(k + n - 1) % n] - q[k], q[(k + 1) % n] - q[k]
		l := math.sqrt(dot3(before, before) * dot3(after, after))
		if !(l > 0) do return -1
		worst = min(worst, dot3(cross3(after, before), normal) / l)
	}
	return worst
}

@(private)
cross3 :: #force_inline proc(a, b: [3]f64) -> [3]f64 {
	return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}
}

@(private)
dot3 :: #force_inline proc(a, b: [3]f64) -> f64 {
	return a.x * b.x + a.y * b.y + a.z * b.z
}

@(private = "file")
corner_at :: proc(p: []u32, r, i: int) -> u32 {
	return p[(r + i) % len(p)]
}

// The ladder of polygon `p` (more than four corners, counter-clockwise) from corner `r`:
// quads between its two halves, quad k from corners k, k + 1, n - 2 - k and n - 1 - k, and
// a triangle at the end when the corners are odd. The rungs inside are those after each
// quad but an even polygon's last, whose far side is the polygon's own edge.
@(private = "file")
ladder_shape :: proc(n: int) -> (quads, rungs: int) {
	quads = (n - 2) / 2 if n % 2 == 0 else (n - 3) / 2
	rungs = quads - 1 if n % 2 == 0 else quads
	return
}

// The ladder start whose worst piece is the squarest (the rungs' length in all breaking
// ties), among those whose rungs are all new edges, none twice, and whose pieces have no
// corner twice; -1 when no start gives such a ladder.
@(private = "file")
ladder_plan :: proc(e: ^Emit, p: []u32) -> (best: int, quality: f64) {
	n := len(p)
	quads, rungs := ladder_shape(n)
	best, quality = -1, -math.INF_F64
	best_cost := math.INF_F64
	pos :: proc(e: ^Emit, v: u32) -> [3]f64 {return e.pos[find(e.alias[:], v)]}
	rotations: for r in 0 ..< n {
		cost := f64(0)
		for k in 0 ..< rungs {
			a, b := corner_at(p, r, k + 1), corner_at(p, r, n - 2 - k)
			if a == b || edge_key(a, b) in e.edges do continue rotations
			for l in k + 1 ..< rungs do if edge_key(a, b) == edge_key(corner_at(p, r, l + 1), corner_at(p, r, n - 2 - l)) do continue rotations
			d := pos(e, a) - pos(e, b)
			cost += math.sqrt(dot3(d, d))
		}
		worst := f64(1)
		for k in 0 ..< quads {
			q := [4]u32{corner_at(p, r, k), corner_at(p, r, k + 1), corner_at(p, r, n - 2 - k), corner_at(p, r, n - 1 - k)}
			if repeats(q[:]) do continue rotations
			worst = min(worst, shape_quality({pos(e, q[0]), pos(e, q[1]), pos(e, q[2]), pos(e, q[3])}))
		}
		if n % 2 == 1 {
			t := [3]u32{corner_at(p, r, quads), corner_at(p, r, quads + 1), corner_at(p, r, quads + 2)}
			if repeats(t[:]) do continue
			worst = min(worst, shape_quality({pos(e, t[0]), pos(e, t[1]), pos(e, t[2])}))
		}
		if worst > quality || (worst == quality && cost < best_cost) do best, quality, best_cost = r, worst, cost
	}
	return
}

@(private = "file")
ladder_emit :: proc(e: ^Emit, p: []u32, r: int) {
	n := len(p)
	quads, rungs := ladder_shape(n)
	for k in 0 ..< quads {
		append(&e.first, u32(len(e.corners)))
		append(&e.corners, corner_at(p, r, k), corner_at(p, r, k + 1), corner_at(p, r, n - 2 - k), corner_at(p, r, n - 1 - k))
	}
	if n % 2 == 1 {
		append(&e.first, u32(len(e.corners)))
		append(&e.corners, corner_at(p, r, quads), corner_at(p, r, quads + 1), corner_at(p, r, quads + 2))
	}
	for k in 0 ..< rungs do e.edges[edge_key(corner_at(p, r, k + 1), corner_at(p, r, n - 2 - k))] += 2
}

// The most corners a polygon may have to be cut round a centre: ten makes five quads round
// a vertex of five, as a hole round a singularity wants; more would leave the centre with
// too many.
@(private = "file")
FAN_CORNERS :: 10

// The fan of polygon `p` round a new centre at `centre`: every other corner from `start`
// joined to it (the last too when the corners are odd, closed by a triangle), the start
// (0 or 1) whose worst piece is the squarest, among those joining no corner twice (the
// centre's edges are new); -1 when both join one corner twice.
@(private = "file")
fan_plan :: proc(e: ^Emit, p: []u32, centre: [3]f64) -> (best: int, quality: f64) {
	n := len(p)
	best, quality = -1, -math.INF_F64
	pos :: proc(e: ^Emit, v: u32) -> [3]f64 {return e.pos[find(e.alias[:], v)]}
	starts: for s in 0 ..< 2 {
		for i := 0; i < n; i += 2 do for j := i + 2; j < n; j += 2 {
			if p[(s + i) % n] == p[(s + j) % n] do continue starts
		}
		worst := f64(1)
		for i := 0; i + 2 <= n; i += 2 {
			worst = min(worst, shape_quality({centre, pos(e, corner_at(p, s, i)), pos(e, corner_at(p, s, i + 1)), pos(e, corner_at(p, s, (i + 2) % n))}))
		}
		if n % 2 == 1 do worst = min(worst, shape_quality({centre, pos(e, corner_at(p, s, n - 1)), pos(e, corner_at(p, s, 0))}))
		if worst > quality do best, quality = s, worst
	}
	return
}

@(private = "file")
fan_emit :: proc(e: ^Emit, p: []u32, s: int, centre: u32) {
	n := len(p)
	for i := 0; i + 2 <= n; i += 2 {
		append(&e.first, u32(len(e.corners)))
		append(&e.corners, centre, corner_at(p, s, i), corner_at(p, s, i + 1), corner_at(p, s, (i + 2) % n))
	}
	if n % 2 == 1 {
		append(&e.first, u32(len(e.corners)))
		append(&e.corners, centre, corner_at(p, s, n - 1), corner_at(p, s, 0))
	}
}

