package main

import "core:math/linalg"

import "../geom"
import "../gizmo"

// Growing and reshaping a curve's run of points, as Blender's Extrude, Make Segment, Split
// and Switch Direction do: in the Edit tab a green ＋ nub stands beyond each end of an open
// curve, and a press on it adds a point there that the drag then places; in the Draw tab,
// taps with one end of the selected curve picked carry the curve on from that end, as a pen
// tool continues a path; Join makes two selected curves one (their nearest ends meeting) or
// closes one; Split cuts a curve in two at the picked point (a loop opens there); Reverse
// swaps its start and its end. Each is one undo step.

// How far beyond its end a nub stands on screen, in pixels.
CURVE_NUB_PX :: 30

// Where the nub past end `last` (the first point when false) of the selected open curve
// stands on screen: CURVE_NUB_PX out along the end's outward handle, or along the line
// from its neighbour when that handle has no length. Not ok for a closed curve, outside
// the Edit tab, or with the end behind the eye.
curve_nub_screen :: proc(app: ^App, obj: ^Object, view_proj: matrix[4, 4]f32, size: [2]f32, last: bool) -> (at: [2]f32, ok: bool) {
	cp := obj.curve
	n := len(cp.points)
	if cp.closed || n < 2 || !app.curve.editing do return
	i := n - 1 if last else 0
	p := cp.points[i]
	way := p.h_out if last else p.h_in
	if linalg.length(way) < 1e-7 do way = p.p - cp.points[n - 2 if last else 1].p
	t := obj.transform
	from := gizmo.project(view_proj, to_world(t, p.p), size) or_return
	toward := gizmo.project(view_proj, to_world(t, p.p + linalg.normalize0(way) * 0.05), size) or_return
	dir := linalg.normalize0(toward - from)
	if dir == {} do dir = {1, 0} if last else {-1, 0}
	return from + dir * (CURVE_NUB_PX * gizmo_scale(app)), true
}

// Adds a point past end `last` of `obj`'s open curve, where `at` (a viewport point) lands
// through the end, and returns its index. The new point's handles are Auto, following its
// neighbour; the old end, now inside the curve, gets an outward handle mirroring its inner
// one when it had none, so the curve runs on smoothly through it.
curve_grow :: proc(app: ^App, obj: ^Object, last: bool, at, size: [2]f32) -> (index: int, ok: bool) {
	cp := obj.curve
	n := len(cp.points)
	if cp.closed || n < 2 do return -1, false
	end := n - 1 if last else 0
	t := obj.transform
	hit, _ := curve_land(app, at, size, to_world(t, cp.points[end].p)) or_return
	e := &cp.points[end]
	if last && linalg.length(e.h_out) < 1e-9 do e.h_out = -e.h_in
	if !last && linalg.length(e.h_in) < 1e-9 do e.h_in = -e.h_out
	q := geom.Bezier_Point{p = to_local(t, hit), radius = e.radius, intensity = e.intensity, twist = e.twist, handles = .Auto}
	if last {
		append(&cp.points, q)
		index = n
	} else {
		inject_at(&cp.points, 0, q)
		index = 0
	}
	geom.bezier_auto_handles(cp.points[:], cp.closed)
	return index, true
}

// The end of the selected curve that taps in the Draw tab carry on from: an open curve
// with exactly one point picked, an end. -1 for none; else 0 or the last index.
curve_grow_end :: proc(app: ^App) -> int {
	obj := selected_curve(app)
	if obj == nil || obj.curve.closed || app.curve.editing || app.curve.kind != .Curve do return -1
	cp := obj.curve
	n := len(cp.points)
	if curve_selected_count(cp) != 1 do return -1
	if cp.points[0].selected do return 0
	if cp.points[n - 1].selected do return n - 1
	return -1
}

// A tap at `pos` in the Draw tab with an end of the selected curve picked: a new point
// past that end where the tap lands, picked so the next tap carries on from it, as one
// undo step. False when no end is picked, and the tap places a new curve's point instead.
curve_grow_tap :: proc(app: ^App, pos, size: [2]f32) -> bool {
	end := curve_grow_end(app)
	if end < 0 do return false
	obj := selected_curve(app)
	before := history_snapshot(app, obj, "grow curve")
	index, ok := curve_grow(app, obj, end > 0, pos, size)
	if !ok {
		history_snapshot_drop(before)
		return true
	}
	curve_select_none(obj.curve)
	obj.curve.points[index].selected = true
	app.curve.picked = index + 1
	history_record_swap(app, obj.id, before, kind = .Curve)
	app.curve.edits += 1
	curve_changed(app, obj)
	return true
}

// Turns the selected curve round: its last point first, each point's handles swapped, its
// picks with it. One undo step.
curve_reverse :: proc(app: ^App) {
	obj := selected_curve(app)
	if obj == nil do return
	before := history_snapshot(app, obj, "reverse curve")
	geom.bezier_reverse(obj.curve.points[:])
	n := len(obj.curve.points)
	if app.curve.picked >= 1 && app.curve.picked <= n do app.curve.picked = n + 1 - app.curve.picked
	history_record_swap(app, obj.id, before, kind = .Curve)
	app.curve.edits += 1
	curve_changed(app, obj)
}

// The one point Split cuts at: the single picked point (or the last picked one with none
// picked), inside an open curve or anywhere on a loop. -1 for none.
curve_split_at :: proc(app: ^App) -> int {
	obj := selected_curve(app)
	if obj == nil do return -1
	targets := curve_targets(app, obj.curve)
	if len(targets) != 1 do return -1
	i := targets[0]
	n := len(obj.curve.points)
	if obj.curve.closed do return i if n >= 3 else -1
	return i if i > 0 && i < n - 1 else -1
}

// Cuts the selected curve at its picked point: a loop opens there, its start and end at
// the point; an open curve keeps the points up to it, and the rest from it on become a new
// curve beside it, with the same look, the point in both. One undo step; the first curve
// stays selected.
curve_split :: proc(app: ^App) -> bool {
	at := curve_split_at(app)
	if at < 0 do return true
	obj := selected_curve(app)
	cp := obj.curve
	n := len(cp.points)
	before := history_snapshot(app, obj, "split curve")
	curve_select_none(cp)
	if cp.closed {
		// Rotated so the point leads, then again at the end, open.
		turned := make([]geom.Bezier_Point, n + 1, context.temp_allocator)
		for k in 0 ..< n do turned[k] = cp.points[(at + k) % n]
		turned[n] = turned[0]
		clear(&cp.points)
		append(&cp.points, ..turned)
		cp.closed = false
		history_record_swap(app, obj.id, before, kind = .Curve)
		app.curve.edits += 1
		app.curve.picked = 0
		curve_changed(app, obj)
		return true
	}
	// The rest, in world space, for the new curve; its handles carried through the
	// object's turn and scale.
	t := obj.transform
	rest := make([]geom.Bezier_Point, n - at, context.temp_allocator)
	for k in 0 ..< n - at {
		p := cp.points[at + k]
		q := p
		q.p = to_world(t, p.p)
		q.h_in = to_world(t, p.p + p.h_in) - q.p
		q.h_out = to_world(t, p.p + p.h_out) - q.p
		rest[k] = q
	}
	resize(&cp.points, at + 1)
	history_record_swap(app, obj.id, before, kind = .Curve)
	app.curve.edits += 1
	app.curve.picked = 0
	curve_changed(app, obj)
	look := cp.look
	id := obj.id
	if !curve_object_add(app, rest, false, look, chain = true) do return false
	added := selected_object(app)
	added.folder = obj.folder
	scene_place_after(app, added, obj)
	curve_changed(app, added)
	for o, i in app.scene.objects do if o.id == id do select_only(app, i)
	return true
}

// The two curves Join makes one: the selected curve and one other curve selected with it,
// both open. Nil when there are not exactly two.
curve_join_pair :: proc(app: ^App) -> (a, b: ^Object) {
	ids := selection_ids(app)
	if len(ids) != 2 do return
	a, b = object_by_id(app, ids[0]), object_by_id(app, ids[1])
	if !object_is_curve(a) || !object_is_curve(b) || a.curve.closed || b.curve.closed do return nil, nil
	return
}

// Whether Join has something to do: two open curves selected, or one open curve of three
// points or more to close.
curve_joinable :: proc(app: ^App) -> bool {
	if a, _ := curve_join_pair(app); a != nil do return true
	obj := selected_curve(app)
	return obj != nil && len(selection_ids(app)) == 1 && !obj.curve.closed && len(obj.curve.points) >= 3
}

// Joins two selected open curves into the first (the primary), at their nearest pair of
// ends: the second's points follow the first's last (each turned round as that needs), in
// the first's space, and ends that meet become one point; the second curve goes, chained
// to it, so Undo brings both back. With one open curve selected, closes it into a loop.
curve_join :: proc(app: ^App) -> bool {
	a, b := curve_join_pair(app)
	if a == nil {
		obj := selected_curve(app)
		if obj != nil && !obj.curve.closed do curve_toggle_closed(app)
		return true
	}
	ta, tb := a.transform, b.transform
	na, nb := len(a.curve.points), len(b.curve.points)
	ends_a := [2]Vec3{to_world(ta, a.curve.points[0].p), to_world(ta, a.curve.points[na - 1].p)}
	ends_b := [2]Vec3{to_world(tb, b.curve.points[0].p), to_world(tb, b.curve.points[nb - 1].p)}
	best, pick_a, pick_b := max(f32), 0, 0
	for i in 0 ..< 2 do for j in 0 ..< 2 {
		if d := linalg.length(ends_a[i] - ends_b[j]); d < best do best, pick_a, pick_b = d, i, j
	}
	before := history_snapshot(app, a, "join curves")
	// The first runs on from its last point into the second's first.
	if pick_a == 0 do geom.bezier_reverse(a.curve.points[:])
	others := make([]geom.Bezier_Point, nb, context.temp_allocator)
	copy(others, b.curve.points[:])
	if pick_b == 1 do geom.bezier_reverse(others)
	// Ends closer than a point's radius meet in one point.
	last := a.curve.points[na - 1]
	first_world := to_world(tb, others[0].p)
	skip := linalg.length(to_world(ta, last.p) - first_world) < max(last.radius * ta.scale, 1e-6)
	for q, k in others {
		if k == 0 && skip {
			a.curve.points[na - 1].h_out = to_local(ta, to_world(tb, q.p + q.h_out)) - to_local(ta, to_world(tb, q.p))
			continue
		}
		r := q
		r.selected = false
		r.p = to_local(ta, to_world(tb, q.p))
		r.h_in = to_local(ta, to_world(tb, q.p + q.h_in)) - r.p
		r.h_out = to_local(ta, to_world(tb, q.p + q.h_out)) - r.p
		r.radius = q.radius * tb.scale / ta.scale
		append(&a.curve.points, r)
	}
	history_record_swap(app, a.id, before, kind = .Curve)
	app.curve.edits += 1
	app.curve.picked = 0
	curve_changed(app, a)
	id := a.id
	for o, i in app.scene.objects do if o == b do select_only(app, i)
	scene_delete_selected(app, chain = true)
	for o, i in app.scene.objects do if o.id == id do select_only(app, i)
	scene_selection_fix(app)
	return true
}

// The nubs past the selected curve's ends, as green rings with a ＋, while the Edit tab is
// on.
draw_curve_nubs :: proc(app: ^App, o: Overlay, obj: ^Object, view_proj: matrix[4, 4]f32, size: [2]f32) {
	green := overlay_color({0.45, 0.85, 0.4, 1})
	dark := overlay_color({0.04, 0.06, 0.08, 0.85})
	n := len(obj.curve.points)
	for last in ([2]bool{false, true}) {
		at, ok := curve_nub_screen(app, obj, view_proj, size, last)
		if !ok do continue
		end, _ := gizmo.project(view_proj, to_world(obj.transform, obj.curve.points[n - 1 if last else 0].p), size)
		overlay_line(o, end, at, overlay_color({0.45, 0.85, 0.4, 0.5}), 1 * o.scale)
		overlay_disc(o, at, 8 * o.scale, dark)
		overlay_circle(o, at, 8 * o.scale, green, 1.5 * o.scale)
		overlay_line(o, at - {4.5 * o.scale, 0}, at + {4.5 * o.scale, 0}, green, 1.5 * o.scale)
		overlay_line(o, at - {0, 4.5 * o.scale}, at + {0, 4.5 * o.scale}, green, 1.5 * o.scale)
	}
}
