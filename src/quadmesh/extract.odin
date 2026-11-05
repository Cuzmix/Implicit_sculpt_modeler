package quadmesh

import "base:runtime"
import "core:math"

// The quad extraction, written from the description of QEx (Ebke,
// Bommes, Campen and Kobbelt, "QEx: Robust Quad Mesh Extraction", 2013; libQEx's source
// is GPL and was not read). Every integer point of the cover is a quad vertex, every unit
// step of the grid from one is a quad edge, traced across the triangles to the next point,
// and the faces are the cycles those edges close, so each cell of the grid is one quad
// and none is lost, where AutoRemesher's extractor cut the cover's lines into segments and
// joined them again by position, losing a few percent of the cells.
//
// Exactness first. The cover's UVs are made seamless in fixed point (EXTRACT_FIXED units
// a cell): each mesh vertex's UV is taken in one triangle's chart and carried to its other
// corners by the edges' transitions (a quarter turn count and a whole translation), so a
// point is the same integer in every chart and every test below is exact in 128 bits.
// A triangle the cover turns over or flattens, or one beside an edge whose transition does
// not close, is a hole the extraction goes around: the polygon around it, and any face of
// more than four sides that an unmatched edge leaves, is filled with quads (extract_faces.odin).

// Fixed-point units a cell: 2^24, so a UV within about 3e-8 of a grid line is on it.
@(private = "file")
EXTRACT_FIXED :: i64(1) << 24

// The largest UV coordinate taken, in cells, so the fixed point fits 64 bits and every
// product 128.
@(private = "file")
EXTRACT_RANGE :: f64(1 << 30)

// Triangles a unit step may cross before its trace is given up (a cell is a few).
@(private = "file")
TRACE_STEPS :: 4096

// The most grid points a triangle's box may hold before the triangle counts as a hole:
// a cover that blew up gives nothing sensible there.
@(private = "file")
BOX_POINTS :: 4096

@(private)
NONE :: max(u32)

@(private = "file")
Fixed :: [2]i64

// A slot's left side: the face its edge bounds is outside the mesh (its border) or a hole.
@(private)
LEFT_BORDER :: u8(1)
@(private = "file")
LEFT_HOLE :: u8(2)

// A chart to the next: `r` quarter turns counter-clockwise, then `t` (whole cells in
// fixed point).
@(private = "file")
Transition :: struct {
	r: u8,
	t: Fixed,
}

// An outgoing edge of a quad vertex: the triangle its first step lies in, its direction in
// that triangle's chart (0 +u, 1 +v, 2 -u, 3 -v), where it starts in that chart, what lies
// to its left, the vertex it leaves, and the quarter turns from the triangle's chart to
// the vertex's own (its first triangle's), which a hole's walk in the grid goes by.
@(private)
Slot :: struct {
	start:  Fixed,
	face:   u32,
	vertex: u32,
	dir:    u8,
	left:   u8,
	rot:    u8,
}

// A grid point filed under the triangle (inside it) or the corner (on its edge) it lies in.
@(private = "file")
Filed_Point :: struct {
	p:      Fixed,
	vertex: u32,
}

// What kind of place a quad vertex has, for matching an edge's arrival to its slot.
@(private)
Vertex_Kind :: enum u8 {
	Mesh_Vertex, // at a vertex of the triangles: `owner` is one of its corners
	Edge, // inside an edge: `owner` is the corner it is filed under
	Face, // inside a triangle: `owner` is the triangle
}

@(private)
Quad_Vertex :: struct {
	kind:  Vertex_Kind,
	owner: u32,
}

@(private)
Extractor :: struct {
	heap:        runtime.Allocator,
	positions:   [][3]f64, // the isotropic mesh's
	triangles:   [][3]u32,
	opp:         []u32, // per corner: the corner across its edge, or NONE
	border:      []bool, // per corner: its edge is the mesh's border or meets three triangles
	trans:       []Transition, // per corner with an opposite: its triangle's chart to the other's
	fp:          [][3]Fixed, // per triangle corner: the seamless UV in fixed point
	good:        []bool, // per triangle: the cover keeps it the right way round
	fan_rot:     []u8, // per corner: the quarter turns from its fan's first triangle's chart to its triangle's
	canonical:   []bool, // per corner: the grid points inside its edge are filed under it
	fan_vertex:  []u32, // per corner: the quad vertex at its mesh vertex, or NONE
	face_first:  []u32, // per triangle: its grid points in face_points
	face_points: [dynamic]Filed_Point,
	edge_first:  []u32, // per corner: its edge's grid points in edge_points
	edge_points: [dynamic]Filed_Point,
	vertices:    [dynamic]Quad_Vertex,
	quad_pos:    [dynamic][3]f64,
	turn:        [dynamic]u8, // per quad vertex: the quarter turns its fan's charts gain round it (a singular vertex's)
	slot_first:  [dynamic]u32, // per quad vertex: its slots, counter-clockwise
	slots:       [dynamic]Slot,
	holes:       int, // triangles turned over, flattened or beside an edge that does not close
	open_seams:  int, // edges whose two triangles' charts do not meet
	unmatched:   int, // slots whose trace found no partner
	filled:      int, // faces of more than four sides filled with quads
	dropped:     int, // cycles a walk there and back emptied, dropped
	bays:        int, // holes reaching the border, closed along it and filled (border_bays)
	bad_cuts:    int, // faces no cut could fill without joining a corner to itself twice
	largest_cut: int, // the most sides a face cut into quads had
	patched:     int, // faces filled with their grid cells
}

// The quads of `cover` over `iso`: see the file's comment. Reports its own 0..1 through
// `run`, whose false cancels.
@(private)
odin_extract :: proc(iso: Isotropic, cover: Cover, run: ^Stage_Run, reason: ^Reason, checks: ^Checks) -> (out: Quads, err: Stage_Error) {
	x := Extractor {
		heap      = runtime.heap_allocator(),
		positions = iso.positions,
		triangles = iso.triangles,
	}
	defer extractor_destroy(&x)
	if len(cover.uvs) != len(iso.triangles) {
		reason_set(reason, "the cover does not match its mesh")
		return {}, .Failed
	}
	for t in cover.uvs do for c in t do for u in c {
		if !(abs(u) < EXTRACT_RANGE) {
			reason_set(reason, "the cover's UVs are out of range")
			return {}, .Failed
		}
	}
	if !extract_report(run, 0) do return {}, .Cancelled
	extract_topology(&x)
	extract_transitions(&x, cover)
	extract_seamless(&x, cover)
	if !extract_report(run, 0.15) do return {}, .Cancelled
	extract_mesh_vertices(&x)
	extract_edge_points(&x)
	extract_face_points(&x)
	if !extract_report(run, 0.35) do return {}, .Cancelled
	target := make([]u32, len(x.slots), x.heap)
	defer delete(target, x.heap)
	for s, i in x.slots {
		target[i] = extract_trace(&x, s)
		if i % 4096 == 4095 && !extract_report(run, 0.35 + 0.5 * f32(i) / f32(len(x.slots))) do return {}, .Cancelled
	}
	out = extract_faces(&x, target)
	if !extract_report(run, 1) {
		quads_destroy(&out)
		return {}, .Cancelled
	}
	checks.extract_points = len(x.vertices)
	checks.extract_holes = x.holes
	checks.extract_open_seams = x.open_seams
	checks.extract_unmatched = x.unmatched
	checks.extract_filled = x.filled
	checks.extract_dropped = x.dropped
	checks.extract_bays = x.bays
	checks.extract_bad_cuts = x.bad_cuts
	checks.extract_largest_cut = x.largest_cut
	checks.extract_patched = x.patched
	return out, .None
}

@(private = "file")
extract_report :: proc(run: ^Stage_Run, fraction: f32) -> bool {
	if run == nil || run.progress == nil do return true
	return run.progress(run.tag, fraction)
}

@(private = "file")
extractor_destroy :: proc(x: ^Extractor) {
	delete(x.opp, x.heap)
	delete(x.border, x.heap)
	delete(x.trans, x.heap)
	delete(x.fp, x.heap)
	delete(x.good, x.heap)
	delete(x.canonical, x.heap)
	delete(x.fan_vertex, x.heap)
	delete(x.fan_rot, x.heap)
	delete(x.turn)
	delete(x.face_first, x.heap)
	delete(x.face_points)
	delete(x.edge_first, x.heap)
	delete(x.edge_points)
	delete(x.vertices)
	delete(x.quad_pos)
	delete(x.slot_first)
	delete(x.slots)
}

// ---- Fixed-point geometry ------------------------------------------------------------

@(private = "file")
rotate :: proc(p: Fixed, r: u8) -> Fixed {
	switch r & 3 {
	case 1: return {-p.y, p.x}
	case 2: return {-p.x, -p.y}
	case 3: return {p.y, -p.x}
	}
	return p
}

@(private = "file")
apply :: proc(m: Transition, p: Fixed) -> Fixed {
	return rotate(p, m.r) + m.t
}

// `first`, then `then`.
@(private = "file")
compose :: proc(first, then: Transition) -> Transition {
	return {(first.r + then.r) & 3, rotate(first.t, then.r) + then.t}
}

@(private = "file")
inverse :: proc(m: Transition) -> Transition {
	r := (4 - m.r) & 3
	return {r, -rotate(m.t, r)}
}

// Twice the signed area of a, b, c: positive when they turn counter-clockwise.
@(private = "file")
orient :: proc(a, b, c: Fixed) -> i128 {
	return i128(b.x - a.x) * i128(c.y - a.y) - i128(b.y - a.y) * i128(c.x - a.x)
}

@(private = "file")
cross :: proc(a, b: Fixed) -> i128 {
	return i128(a.x) * i128(b.y) - i128(a.y) * i128(b.x)
}

@(private = "file")
dot :: proc(a, b: Fixed) -> i128 {
	return i128(a.x) * i128(b.x) + i128(a.y) * i128(b.y)
}

// The unit step of direction d, in fixed point.
@(private = "file")
step :: proc(d: u8) -> Fixed {
	switch d & 3 {
	case 1: return {0, EXTRACT_FIXED}
	case 2: return {-EXTRACT_FIXED, 0}
	case 3: return {0, -EXTRACT_FIXED}
	}
	return {EXTRACT_FIXED, 0}
}

@(private = "file")
floor_div :: proc(a, b: i64) -> i64 {
	q := a / b
	if a % b != 0 && a < 0 do q -= 1
	return q
}

@(private = "file")
ceil_div :: proc(a, b: i64) -> i64 {
	return -floor_div(-a, b)
}

@(private = "file")
on_grid :: proc(p: Fixed) -> bool {
	return p.x % EXTRACT_FIXED == 0 && p.y % EXTRACT_FIXED == 0
}

// Direction d at or after `e` and short of half a turn past it: `e`'s side of the grid.
@(private = "file")
ahead_of :: proc(e: Fixed, d: u8) -> bool {
	s := step(d)
	c := cross(e, s)
	return c > 0 || (c == 0 && dot(e, s) > 0)
}

// The first of the four directions at or after `e`, counter-clockwise.
@(private = "file")
first_after :: proc(e: Fixed) -> u8 {
	for d in u8(0) ..< 4 do if ahead_of(e, d) && !ahead_of(e, (d + 3) & 3) do return d
	return 0
}

// Whether direction d lies in the corner from `a` to `b` (less than half a turn): from `a`
// up to short of `b` for an edge that keeps its face on the left, or from just past `a`
// up to `b` for one that keeps it on the right.
@(private = "file")
in_sector :: proc(a, b: Fixed, d: u8, right: bool) -> bool {
	s := step(d)
	ca, cb := cross(a, s), cross(s, b)
	if right do return ca > 0 && (cb > 0 || (cb == 0 && dot(b, s) > 0))
	return (ca > 0 || (ca == 0 && dot(a, s) > 0)) && cb > 0
}

// The direction along `e` when `e` runs along the grid.
@(private = "file")
along :: proc(e: Fixed) -> (d: u8, ok: bool) {
	if e.y == 0 && e.x > 0 do return 0, true
	if e.x == 0 && e.y > 0 do return 1, true
	if e.y == 0 && e.x < 0 do return 2, true
	if e.x == 0 && e.y < 0 do return 3, true
	return 0, false
}

// The next and the previous corner of corner c's triangle (corner c % 3 of triangle c / 3).
@(private)
corner_next :: #force_inline proc(c: u32) -> u32 {
	return c - c % 3 + (c % 3 + 1) % 3
}

@(private)
corner_prev :: #force_inline proc(c: u32) -> u32 {
	return c - c % 3 + (c % 3 + 2) % 3
}

@(private = "file")
corner_vertex :: #force_inline proc(x: ^Extractor, c: u32) -> u32 {
	return x.triangles[c / 3][c % 3]
}

// ---- The mesh and the cover's charts --------------------------------------------------

// Each corner's opposite (corner_opposites); an edge without one is the border.
@(private = "file")
extract_topology :: proc(x: ^Extractor) {
	x.opp = corner_opposites(len(x.positions), x.triangles, x.heap)
	x.border = make([]bool, len(x.opp), x.heap)
	for o, c in x.opp do x.border[c] = o == NONE
}

// The transition across each edge: the quarter turns that best take the edge's direction
// in one triangle's UVs to the other's, and the whole translation that then takes one end.
@(private = "file")
extract_transitions :: proc(x: ^Extractor, cover: Cover) {
	x.trans = make([]Transition, len(x.opp), x.heap)
	for o, c in x.opp {
		if o == NONE || u32(c) > o do continue
		f, k := c / 3, c % 3
		g, l := o / 3, o % 3
		pa, pb := cover.uvs[f][k], cover.uvs[f][(k + 1) % 3]
		qa, qb := cover.uvs[g][(l + 1) % 3], cover.uvs[g][l]
		d, e := pb - pa, qb - qa
		best, best_r := math.INF_F64, u8(0)
		for r in u8(0) ..< 4 {
			rd := rotate_f64(d, r)
			miss := (rd.x - e.x) * (rd.x - e.x) + (rd.y - e.y) * (rd.y - e.y)
			if miss < best do best, best_r = miss, r
		}
		t := qa - rotate_f64(pa, best_r)
		m := Transition{best_r, {i64(math.round(t.x)) * EXTRACT_FIXED, i64(math.round(t.y)) * EXTRACT_FIXED}}
		x.trans[c] = m
		x.trans[o] = inverse(m)
	}
}

@(private = "file")
rotate_f64 :: proc(p: [2]f64, r: u8) -> [2]f64 {
	switch r & 3 {
	case 1: return {-p.y, p.x}
	case 2: return {-p.x, -p.y}
	case 3: return {p.y, -p.x}
	}
	return p
}

// Each corner's UV in fixed point, made seamless: a vertex's fan of triangles is walked
// counter-clockwise from its first, its UV quantized there (a singular vertex's put on its
// grid point) and carried round by the edges' transitions, so two triangles meeting at an
// edge see its ends at the same point up to the transition exactly. Where the walk round a
// vertex does not come back to where it started (a singularity the cover did not name, or
// rounding that disagrees), and wherever two charts do not meet, the triangles there are
// holes; so are triangles the cover turns over or flattens.
@(private = "file")
extract_seamless :: proc(x: ^Extractor, cover: Cover) {
	corners := u32(len(x.opp))
	x.fp = make([][3]Fixed, len(x.triangles), x.heap)
	x.good = make([]bool, len(x.triangles), x.heap)
	x.fan_rot = make([]u8, corners, x.heap)
	singular := make([]bool, len(x.positions), x.heap)
	defer delete(singular, x.heap)
	for s in cover.singular do if int(s) < len(singular) do singular[s] = true
	visited := make([]bool, corners, x.heap)
	defer delete(visited, x.heap)
	broken := make([]bool, len(x.triangles), x.heap)
	defer delete(broken, x.heap)
	for c0 in 0 ..< corners {
		if visited[c0] do continue
		start, closed := fan_start(x, c0)
		uv := cover.uvs[start / 3][start % 3]
		ref: Fixed
		if singular[corner_vertex(x, start)] {
			ref = {i64(math.round(uv.x)) * EXTRACT_FIXED, i64(math.round(uv.y)) * EXTRACT_FIXED}
		} else {
			ref = {i64(math.round(uv.x * f64(EXTRACT_FIXED))), i64(math.round(uv.y * f64(EXTRACT_FIXED)))}
		}
		m := Transition{}
		c := start
		for _ in 0 ..< corners {
			visited[c] = true
			x.fp[c / 3][c % 3] = apply(m, ref)
			x.fan_rot[c] = m.r
			p := corner_prev(c)
			o := x.opp[p]
			if o == NONE do break
			if o == start {
				if closed && apply(compose(m, x.trans[p]), ref) != ref {
					broken[c / 3] = true
					broken[start / 3] = true
				}
				break
			}
			if visited[o] do break
			m = compose(m, x.trans[p])
			c = o
		}
	}
	for c in 0 ..< corners {
		o := x.opp[c]
		if o == NONE || c > o do continue
		f, k := c / 3, c % 3
		g, l := o / 3, o % 3
		m := x.trans[c]
		if apply(m, x.fp[f][k]) != x.fp[g][(l + 1) % 3] || apply(m, x.fp[f][(k + 1) % 3]) != x.fp[g][l] {
			broken[f] = true
			broken[g] = true
			x.open_seams += 1
		}
	}
	for t, f in x.fp {
		x.good[f] = !broken[f] && orient(t[0], t[1], t[2]) > 0
		if x.good[f] {
			lo, hi := fixed_min(t[0], t[1], t[2]), fixed_max(t[0], t[1], t[2])
			span := (floor_div(hi.x, EXTRACT_FIXED) - ceil_div(lo.x, EXTRACT_FIXED) + 1) * (floor_div(hi.y, EXTRACT_FIXED) - ceil_div(lo.y, EXTRACT_FIXED) + 1)
			if span > BOX_POINTS do x.good[f] = false
		}
		if !x.good[f] do x.holes += 1
	}
}

// The first corner of c's fan counter-clockwise (the one after the border, when the fan
// is open), and whether the fan closes.
@(private = "file")
fan_start :: proc(x: ^Extractor, c: u32) -> (start: u32, closed: bool) {
	start = c
	for _ in 0 ..< len(x.opp) {
		o := x.opp[start]
		if o == NONE do return start, false
		cw := corner_next(o)
		if cw == c do return c, true
		start = cw
	}
	return c, true
}

// ---- Grid points and their slots -------------------------------------------------------

@(private = "file")
add_vertex :: proc(x: ^Extractor, kind: Vertex_Kind, owner: u32, position: [3]f64) -> u32 {
	id := u32(len(x.vertices))
	append(&x.vertices, Quad_Vertex{kind, owner})
	append(&x.quad_pos, position)
	append(&x.turn, 0)
	append(&x.slot_first, u32(len(x.slots)))
	return id
}

@(private = "file")
add_slot :: proc(x: ^Extractor, vertex, face: u32, start: Fixed, dir, left, rot: u8) {
	append(&x.slots, Slot{start = start, face = face, vertex = vertex, dir = dir & 3, left = left, rot = rot & 3})
}

// What lies on the left of an edge whose other side is missing or a hole.
@(private = "file")
left_of :: proc(x: ^Extractor, c: u32) -> u8 {
	return LEFT_BORDER if x.border[c] else LEFT_HOLE
}

// A mesh vertex on a grid point is a quad vertex, one for each fan of triangles round it
// that has a sound triangle. Its slots are the directions in each sound triangle's corner,
// from the corner's first edge up to short of its second, in fan order; and the direction
// along a corner's second edge where the next triangle is missing or a hole, which runs
// with that side on its left.
@(private = "file")
extract_mesh_vertices :: proc(x: ^Extractor) {
	corners := u32(len(x.opp))
	x.fan_vertex = make([]u32, corners, x.heap)
	for &v in x.fan_vertex do v = NONE
	visited := make([]bool, corners, x.heap)
	defer delete(visited, x.heap)
	for c0 in 0 ..< corners {
		if visited[c0] do continue
		start, _ := fan_start(x, c0)
		fan := make([dynamic]u32, 0, 8, x.heap)
		defer delete(fan)
		any_good := false
		c := start
		for _ in 0 ..< corners {
			visited[c] = true
			append(&fan, c)
			any_good ||= x.good[c / 3]
			o := x.opp[corner_prev(c)]
			if o == NONE || o == start || visited[o] do break
			c = o
		}
		ref := x.fp[start / 3][start % 3]
		if !any_good || !on_grid(ref) do continue
		id := add_vertex(x, .Mesh_Vertex, start, x.positions[corner_vertex(x, start)])
		last := fan[len(fan) - 1]
		if pl := corner_prev(last); x.opp[pl] == start do x.turn[id] = (x.fan_rot[last] + x.trans[pl].r) & 3
		for fc, i in fan {
			x.fan_vertex[fc] = id
			f, k := fc / 3, fc % 3
			if !x.good[f] do continue
			p := x.fp[f][k]
			a, b := x.fp[f][(k + 1) % 3] - p, x.fp[f][(k + 2) % 3] - p
			d0 := first_after(a)
			for j in u8(0) ..< 4 {
				d := (d0 + j) & 3
				if in_sector(a, b, d, false) do add_slot(x, id, f, p, d, 0, 4 - x.fan_rot[fc])
			}
			o := x.opp[corner_prev(fc)]
			next_good := o != NONE && x.good[o / 3] && (i + 1 < len(fan) || o == start)
			if !next_good {
				if d, ok := along(b); ok do add_slot(x, id, f, p, d, left_of(x, corner_prev(fc)), 4 - x.fan_rot[fc])
			}
		}
	}
}

// The grid points inside each edge, filed under the corner of its sound triangle (the
// lower corner when both are sound), with their slots in counter-clockwise order from the
// edge's own direction.
@(private = "file")
extract_edge_points :: proc(x: ^Extractor) {
	corners := u32(len(x.opp))
	x.canonical = make([]bool, corners, x.heap)
	x.edge_first = make([]u32, corners + 1, x.heap)
	for c in 0 ..< corners {
		x.edge_first[c] = u32(len(x.edge_points))
		f, k := c / 3, c % 3
		o := x.opp[c]
		if !x.good[f] || !(o == NONE || !x.good[o / 3] || c < o) do continue
		x.canonical[c] = true
		a, b := x.fp[f][k], x.fp[f][(k + 1) % 3]
		lo, hi := fixed_min(a, b, b), fixed_max(a, b, b)
		e := b - a
		length := dot(e, e)
		for j in ceil_div(lo.y, EXTRACT_FIXED) ..= floor_div(hi.y, EXTRACT_FIXED) {
			for i in ceil_div(lo.x, EXTRACT_FIXED) ..= floor_div(hi.x, EXTRACT_FIXED) {
				q := Fixed{i * EXTRACT_FIXED, j * EXTRACT_FIXED}
				if orient(a, b, q) != 0 do continue
				t := dot(q - a, e)
				if t <= 0 || t >= length do continue
				s := f64(t) / f64(length)
				pa, pb := x.positions[corner_vertex(x, c)], x.positions[corner_vertex(x, corner_next(c))]
				id := add_vertex(x, .Edge, c, pa + (pb - pa) * s)
				append(&x.edge_points, Filed_Point{q, id})
				d0 := first_after(e)
				for n in u8(0) ..< 4 {
					d := (d0 + n) & 3
					if face, dir, left, ok := edge_slot(x, c, d); ok {
						start := q if face == f else apply(x.trans[c], q)
						add_slot(x, id, face, start, dir, left, 0 if face == f else 4 - x.trans[c].r)
					}
				}
			}
		}
	}
	x.edge_first[corners] = u32(len(x.edge_points))
}

// The slot for direction d (in the chart of corner c's triangle) at a grid point inside
// c's edge: into c's triangle, or along the edge its own way, starts there; into the other
// triangle, or along the edge the other way, starts in the other triangle when it is sound,
// and the way back along the edge otherwise runs in c's triangle with that side on its left.
@(private = "file")
edge_slot :: proc(x: ^Extractor, c: u32, d: u8) -> (face: u32, dir: u8, left: u8, ok: bool) {
	f, k := c / 3, c % 3
	e := x.fp[f][(k + 1) % 3] - x.fp[f][k]
	s := step(d)
	side := cross(e, s)
	o := x.opp[c]
	other := o != NONE && x.good[o / 3]
	if side > 0 || (side == 0 && dot(e, s) > 0) do return f, d, 0, true
	if other do return o / 3, (d + x.trans[c].r) & 3, 0, true
	if side == 0 do return f, d, left_of(x, c), true
	return 0, 0, 0, false
}

// The grid points strictly inside each sound triangle, four slots each.
@(private = "file")
extract_face_points :: proc(x: ^Extractor) {
	x.face_first = make([]u32, len(x.triangles) + 1, x.heap)
	for t, f in x.fp {
		x.face_first[f] = u32(len(x.face_points))
		if !x.good[f] do continue
		lo, hi := fixed_min(t[0], t[1], t[2]), fixed_max(t[0], t[1], t[2])
		for j in ceil_div(lo.y, EXTRACT_FIXED) ..= floor_div(hi.y, EXTRACT_FIXED) {
			for i in ceil_div(lo.x, EXTRACT_FIXED) ..= floor_div(hi.x, EXTRACT_FIXED) {
				q := Fixed{i * EXTRACT_FIXED, j * EXTRACT_FIXED}
				w0, w1, w2 := orient(t[1], t[2], q), orient(t[2], t[0], q), orient(t[0], t[1], q)
				if w0 <= 0 || w1 <= 0 || w2 <= 0 do continue
				sum := f64(w0 + w1 + w2)
				tri := x.triangles[f]
				p := (x.positions[tri[0]] * f64(w0) + x.positions[tri[1]] * f64(w1) + x.positions[tri[2]] * f64(w2)) / sum
				id := add_vertex(x, .Face, u32(f), p)
				append(&x.face_points, Filed_Point{q, id})
				for d in u8(0) ..< 4 do add_slot(x, id, u32(f), q, d, 0, 0)
			}
		}
	}
	x.face_first[len(x.triangles)] = u32(len(x.face_points))
	append(&x.slot_first, u32(len(x.slots)))
}

// ---- Tracing ---------------------------------------------------------------------------

// The slot at the far end of slot s's unit step, or NONE: the step is walked across the
// triangles, through their edges' transitions, until the triangle that holds its end,
// where the quad vertex is looked up and the step back from it matched to its slot.
@(private = "file")
extract_trace :: proc(x: ^Extractor, s: Slot) -> u32 {
	f := s.face
	d := s.dir
	p := s.start
	q := p + step(d)
	right := s.left != 0
	for _ in 0 ..< TRACE_STEPS {
		t := x.fp[f]
		o0, o1, o2 := orient(t[1], t[2], q), orient(t[2], t[0], q), orient(t[0], t[1], q)
		if o0 >= 0 && o1 >= 0 && o2 >= 0 do return arrive(x, f, q, (d + 2) & 3, [3]i128{o0, o1, o2})
		side := [3]i128{orient(p, q, t[0]), orient(p, q, t[1]), orient(p, q, t[2])}
		// Out through an edge's inside: its first corner on the right, its second on the left.
		crossed := -1
		for j in 0 ..< 3 do if side[j] < 0 && side[(j + 1) % 3] > 0 do crossed = j
		if crossed >= 0 {
			c := u32(3 * int(f) + crossed)
			o := x.opp[c]
			if o == NONE || !x.good[o / 3] do return NONE
			m := x.trans[c]
			p, q = apply(m, p), apply(m, q)
			d = (d + m.r) & 3
			f = o / 3
			continue
		}
		// Out through a corner: along an edge to its far end, or through a corner alone.
		through := -1
		for j in 0 ..< 3 {
			if side[j] == 0 && side[(j + 1) % 3] == 0 {
				through = (j + 1) % 3 if side[(j + 2) % 3] > 0 else j
				break
			}
		}
		if through < 0 {
			for j in 0 ..< 3 do if side[j] == 0 do through = j
		}
		if through < 0 do return NONE
		corner := t[through]
		if dot(corner - p, q - p) <= 0 do return NONE
		nf, m, ok := pass_corner(x, u32(3 * int(f) + through), d, right)
		if !ok do return NONE
		f = nf
		p, q = apply(m, p), apply(m, q)
		d = (d + m.r) & 3
	}
	return NONE
}

// Where a step through corner c (in direction d of c's triangle's chart) goes on: the
// triangle round c's vertex whose corner holds the direction, searched counter-clockwise
// and then clockwise, and the transition to its chart.
@(private = "file")
pass_corner :: proc(x: ^Extractor, c: u32, d: u8, right: bool) -> (face: u32, m: Transition, ok: bool) {
	walk := c
	for _ in 0 ..< 64 {
		p := corner_prev(walk)
		o := x.opp[p]
		if o == NONE || !x.good[o / 3] do break
		m = compose(m, x.trans[p])
		walk = o
		if walk == c do break
		if sector_holds(x, walk, (d + m.r) & 3, right) do return walk / 3, m, true
	}
	m = {}
	walk = c
	for _ in 0 ..< 64 {
		o := x.opp[walk]
		if o == NONE || !x.good[o / 3] do break
		m = compose(m, x.trans[walk])
		walk = corner_next(o)
		if walk == c do break
		if sector_holds(x, walk, (d + m.r) & 3, right) do return walk / 3, m, true
	}
	return 0, {}, false
}

@(private = "file")
sector_holds :: proc(x: ^Extractor, c: u32, d: u8, right: bool) -> bool {
	f, k := c / 3, c % 3
	p := x.fp[f][k]
	return in_sector(x.fp[f][(k + 1) % 3] - p, x.fp[f][(k + 2) % 3] - p, d, right)
}

// The slot of the quad vertex at q in triangle f (q inside f, on an edge of it, or at a
// corner, as `o` says) that leaves it in direction `back`, or NONE.
@(private = "file")
arrive :: proc(x: ^Extractor, f: u32, q: Fixed, back: u8, o: [3]i128) -> u32 {
	zeros := int(o[0] == 0) + int(o[1] == 0) + int(o[2] == 0)
	vertex := NONE
	face, dir := f, back
	switch zeros {
	case 0:
		for i in x.face_first[f] ..< x.face_first[f + 1] do if x.face_points[i].p == q do vertex = x.face_points[i].vertex
	case 1:
		// On the edge opposite the corner whose weight is zero: that corner's next's edge.
		k := 0 if o[0] == 0 else (1 if o[1] == 0 else 2)
		c := u32(3 * int(f) + (k + 1) % 3)
		filed, at, d := c, q, back
		if !x.canonical[c] {
			oc := x.opp[c]
			if oc == NONE || !x.canonical[oc] do return NONE
			filed, at, d = oc, apply(x.trans[c], q), (back + x.trans[c].r) & 3
		}
		for i in x.edge_first[filed] ..< x.edge_first[filed + 1] do if x.edge_points[i].p == at do vertex = x.edge_points[i].vertex
		ok: bool
		left: u8
		face, dir, left, ok = edge_slot(x, filed, d)
		if !ok do return NONE
	case:
		k := 0 if o[0] > 0 else (1 if o[1] > 0 else 2)
		c := u32(3 * int(f) + k)
		vertex = x.fan_vertex[c]
		t := x.fp[f]
		p := t[k]
		a, b := t[(k + 1) % 3] - p, t[(k + 2) % 3] - p
		if !in_sector(a, b, back, false) {
			// Along the corner's second edge: the next triangle's, when it is sound.
			s := step(back)
			if cross(b, s) != 0 || dot(b, s) <= 0 do return NONE
			pc := corner_prev(c)
			on := x.opp[pc]
			if on != NONE && x.good[on / 3] {
				face, dir = on / 3, (back + x.trans[pc].r) & 3
			}
		}
	}
	if vertex == NONE do return NONE
	for i in x.slot_first[vertex] ..< x.slot_first[vertex + 1] {
		if x.slots[i].face == face && x.slots[i].dir == dir do return i
	}
	return NONE
}

@(private = "file")
fixed_min :: proc(a, b, c: Fixed) -> Fixed {
	return {min(a.x, b.x, c.x), min(a.y, b.y, c.y)}
}

@(private = "file")
fixed_max :: proc(a, b, c: Fixed) -> Fixed {
	return {max(a.x, b.x, c.x), max(a.y, b.y, c.y)}
}
