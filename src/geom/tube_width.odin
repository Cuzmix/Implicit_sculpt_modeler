package geom

import "core:math"

// A tube's width along its curve, as Blender's taper curve: an open Bézier graph from the
// start (x 0) to the end (x 1) whose height times each point's radius is the tube's radius
// there, edited with the same points, handles and handle types as a curve. Its ends stay at
// x 0 and 1, and the points keep their order along x, so each place along has one height.

// The tallest the graph goes: a tube half as wide again as its points' radius.
WIDTH_MAX :: 1.6

// The fewest points the graph keeps: its two ends.
WIDTH_POINTS_MIN :: 2

Tube_Width :: struct {
	points: [PROFILE_POINTS_MAX]Profile_Point,
	count:  int,
}

// The starting shapes: Even keeps each point's radius; Taper narrows to the end; Both ends
// narrows to both; Bulge swells in the middle.
Width_Preset :: enum u8 {
	Even,
	Taper,
	Both_Ends,
	Bulge,
}

// Even as a constant, for TUBE_DEFAULTS: a level line at one.
WIDTH_EVEN :: Tube_Width {
	count = 2,
	points = {0 = {p = {0, 1}, h_out = {1.0 / 3, 0}, handles = .Auto}, 1 = {p = {1, 1}, h_in = {-1.0 / 3, 0}, handles = .Auto}},
}

// The preset `kind` as a graph of Auto points.
width_preset :: proc(kind: Width_Preset) -> (w: Tube_Width) {
	heights: []f32
	switch kind {
	case .Even:
		return WIDTH_EVEN
	case .Taper:
		heights = {1, 0.15}
	case .Both_Ends:
		heights = {0.15, 1, 0.15}
	case .Bulge:
		heights = {0.5, 1.4, 0.5}
	}
	for y, i in heights {
		w.points[i] = {p = {f32(i) / f32(len(heights) - 1), y}, handles = .Auto}
	}
	w.count = len(heights)
	width_auto_handles(&w)
	return
}

// The graph as curve points (z = 0), in the temporary allocator, for the curve's own procs.
width_bezier :: proc(w: Tube_Width, allocator := context.temp_allocator) -> []Bezier_Point {
	out := make([]Bezier_Point, w.count, allocator)
	for i in 0 ..< w.count {
		q := w.points[i]
		out[i] = {p = {q.p.x, q.p.y, 0}, h_in = {q.h_in.x, q.h_in.y, 0}, h_out = {q.h_out.x, q.h_out.y, 0}, handles = q.handles}
	}
	return out
}

// Sets the graph's points from curve points (z dropped), up to PROFILE_POINTS_MAX.
width_from_bezier :: proc(w: ^Tube_Width, points: []Bezier_Point) {
	w.count = min(len(points), PROFILE_POINTS_MAX)
	for p, i in points[:w.count] do w.points[i] = {p = p.p.xy, h_in = p.h_in.xy, h_out = p.h_out.xy, handles = p.handles}
}

// Sets the handles of the graph's Auto and Vector points from their neighbours.
width_auto_handles :: proc(w: ^Tube_Width) {
	pts := width_bezier(w^)
	bezier_auto_handles(pts, false)
	width_from_bezier(w, pts)
}

// Keeps point i where the graph allows: the ends at x 0 and 1, a point between its
// neighbours, every point from 0 to WIDTH_MAX high, and its handles pointing back and on
// along x, so the graph never doubles back.
width_hold :: proc(w: ^Tube_Width, i: int) {
	if i < 0 || i >= w.count do return
	q := &w.points[i]
	GAP :: 0.02
	switch {
	case i == 0:
		q.p.x = 0
	case i == w.count - 1:
		q.p.x = 1
	case:
		q.p.x = clamp(q.p.x, w.points[i - 1].p.x + GAP, w.points[i + 1].p.x - GAP)
	}
	q.p.y = clamp(q.p.y, 0, WIDTH_MAX)
	q.h_in.x = min(q.h_in.x, 0)
	q.h_out.x = max(q.h_out.x, 0)
}

// Adds a point at place `u` of the graph without changing its shape. Returns its index, -1
// when the graph is full or the place is a point already.
width_insert :: proc(w: ^Tube_Width, u: f32) -> int {
	if w.count + 1 > PROFILE_POINTS_MAX do return -1
	pts := make([dynamic]Bezier_Point, 0, PROFILE_POINTS_MAX, context.temp_allocator)
	append(&pts, ..width_bezier(w^))
	at := bezier_insert(&pts, false, u)
	width_from_bezier(w, pts[:])
	return at
}

// Deletes point i, the ends staying. Returns whether it went.
width_delete :: proc(w: ^Tube_Width, i: int) -> bool {
	if i <= 0 || i >= w.count - 1 do return false
	for k in i ..< w.count - 1 do w.points[k] = w.points[k + 1]
	w.count -= 1
	width_auto_handles(w)
	return true
}

// Whether the graph is level at one everywhere, so the tube can skip it.
width_is_even :: proc(w: Tube_Width) -> bool {
	for i in 0 ..< w.count {
		q := w.points[i]
		if q.p.y != 1 || q.h_in.y != 0 || q.h_out.y != 0 do return false
	}
	return true
}

// The graph as a table of (x, height) places in order along x, for width_lookup: fine
// enough that a straight line between them stays close to the curve.
width_table :: proc(w: Tube_Width, allocator := context.temp_allocator) -> [][2]f32 {
	if w.count < WIDTH_POINTS_MIN do return nil
	STEPS :: 16
	pts := width_bezier(w)
	segs := w.count - 1
	out := make([][2]f32, segs * STEPS + 1, allocator)
	for &q, k in out do q = bezier_at(pts, false, f32(k) / STEPS).xy
	return out
}

// The height at `f` along (0 to 1) from a table of width_table, no lower than zero. `from`
// is where the last lookup ended, so walking along in order costs one pass in all.
width_lookup :: proc(table: [][2]f32, f: f32, from: ^int = nil) -> f32 {
	if len(table) == 0 do return 1
	k := from^ if from != nil else 0
	k = clamp(k, 0, len(table) - 1)
	for k > 0 && table[k].x > f do k -= 1
	for k + 1 < len(table) && table[k + 1].x < f do k += 1
	if from != nil do from^ = k
	if k + 1 >= len(table) || f <= table[k].x do return max(table[k].y, 0)
	a, b := table[k], table[k + 1]
	t := (f - a.x) / max(b.x - a.x, 1e-9)
	return max(math.lerp(a.y, b.y, clamp(t, 0, 1)), 0)
}
