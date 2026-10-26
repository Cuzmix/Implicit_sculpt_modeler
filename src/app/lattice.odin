package main

import "core:math/linalg"
import "core:time"

import "../camera"
import "../gizmo"
import "../sculpt"
import "../ui"

// The lattice deformer (sculpt/lattice.odin) from the Deformers section: with Lattice
// picked there and the Move tool on, a cage of points round the part the mask leaves
// free stands in for the gizmo, and dragging a point (mouse, finger or pen) pulls the
// surface near it smoothly, one undo step a drag. The drag is the Move tool's own
// (move_tool.odin), posing the mesh as a gizmo handle does in pose mode, so Escape, a
// second finger and a lost touch cancel it as they cancel any. The cage keeps its points
// where they were dragged while nothing else changes the object; any other step (a
// stroke, a mask, an undo, another level) makes it again, at rest round the surface as
// it is then.

LATTICE_POINTS_MAX :: sculpt.LATTICE_MAX_POINTS
// Enough points a side to bend a part one way and back, and few enough to pick apart.
LATTICE_POINTS_DEFAULT :: 3
// The cage stands a little off the free part, so its outer vertices sit inside it and
// its edges do not hide the surface's.
LATTICE_PAD :: 0.05

Lattice_View :: struct {
	on:      bool, // Lattice is picked in the Deformers section
	points:  int,  // a side, as the section asks
	// The cage as made: for which object, level and history, its box, its points a side
	// and each point's move so far, in the object's own space.
	made:    bool,
	id, level, levels: int,
	serial:  u64,
	lo, hi:  Vec3,
	n:       int,
	offsets: [LATTICE_POINTS_MAX * LATTICE_POINTS_MAX * LATTICE_POINTS_MAX]Vec3,
	hover:   int, // the point under the pointer, from 1; 0 none
	drags:   int, // drags that moved the surface, for the exit stats
	last:    int,    // the point last dragged, from 1
	// The time each frame of the drag under way took to pose the surface, summed, and the
	// frames; then the mean over the last drag, for the exit stats.
	frame_ms: f64,
	frames:   int,
	ms:       f64,
	last_at: [2]f32, // where it was drawn, for the scripted scenarios
}

// The point's place along each axis, from its number counted from 0.
lattice_index :: proc(n, index: int) -> [3]int {
	return {index % n, index / n % n, index / (n * n)}
}

// Where point `index` is in the object's own space: its place in the box, moved.
lattice_point :: proc(l: ^Lattice_View, index: int) -> Vec3 {
	ijk := lattice_index(l.n, index)
	f := Vec3{f32(ijk.x), f32(ijk.y), f32(ijk.z)} / f32(l.n - 1)
	return l.lo + (l.hi - l.lo) * f + l.offsets[index]
}

// The object whose cage shows: Lattice on, the Move tool, and one object selected that
// can be deformed.
lattice_object :: proc(app: ^App) -> ^Object {
	l := &app.ui.deform.lattice
	if !l.on || app.tool != .Move || len(selection_ids(app)) != 1 do return nil
	obj := selected_object(app)
	if obj == nil || !deform_allowed(app, obj) do return nil
	return obj
}

// Whether the cage stands in for the gizmo now: it shows, and was made round `obj`
// (it is not when nothing is free to put one round, and the gizmo is then back).
lattice_shown :: proc(app: ^App) -> ^Object {
	obj := lattice_object(app)
	l := &app.ui.deform.lattice
	return obj if obj != nil && l.made && l.id == obj.id else nil
}

// Whether the cage made no longer fits its object: the object went, or its level, its
// levels or the history changed since.
@(private = "file")
lattice_stale :: proc(app: ^App) -> bool {
	l := &app.ui.deform.lattice
	obj := object_by_id(app, l.id)
	return obj == nil || l.level != obj.levels.current || l.levels != len(obj.levels.levels) || l.serial != app.history.serial
}

// Keeps the cage made for `obj` as it is now, making it again (at rest, round the free
// part) when the object, its level, the history or the points a side changed since.
// False when there is nothing free to put a cage round.
lattice_sync :: proc(app: ^App, obj: ^Object) -> bool {
	l := &app.ui.deform.lattice
	level := obj.levels.current
	if l.made && l.id == obj.id && l.level == level && l.levels == len(obj.levels.levels) && l.serial == app.history.serial && l.n == l.points {
		return true
	}
	lattice_drop(app)
	lo, hi, ok := deform_bounds(app, obj)
	if !ok do return false
	pad := LATTICE_PAD * max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
	l.made, l.id, l.level, l.levels, l.serial, l.n = true, obj.id, level, len(obj.levels.levels), app.history.serial, l.points
	l.lo, l.hi, l.offsets, l.hover = lo - pad, hi + pad, {}, 0
	return true
}

// Forgets the cage, and the places its sculptor noted for it. Every level of the object
// lets them go, not only the one the cage was made on: levels added or taken away since
// renumber them, and a place left on any would be taken for the next cage's.
lattice_drop :: proc(app: ^App) {
	l := &app.ui.deform.lattice
	if !l.made do return
	l.made = false
	obj := object_by_id(app, l.id)
	if obj == nil do return
	for level in obj.levels.levels do sculpt.sculptor_lattice_clear(&level.sculptor)
}

// Each frame: the cage follows the selection and the history while it shows, and goes
// when Lattice is not picked. With another tool it waits as it is while nothing changes,
// and goes, with the places its drags noted, once a step makes it stale, so a session
// that has moved on keeps no 12 bytes a vertex for it. A drag under way keeps it all.
lattice_frame :: proc(app: ^App) {
	l := &app.ui.deform.lattice
	if app.move.drag.lattice > 0 do return
	if obj := lattice_object(app); obj != nil {
		_ = lattice_sync(app, obj)
	} else if !l.on || (l.made && lattice_stale(app)) {
		lattice_drop(app)
	}
}

// The cage's points on screen, in viewport points, and which of them are in front of
// the eye.
lattice_screen :: proc(app: ^App, obj: ^Object, size: [2]f32) -> (at: [len(Lattice_View{}.offsets)][2]f32, ok: [len(Lattice_View{}.offsets)]bool, count: int) {
	l := &app.ui.deform.lattice
	if !l.made || size.x <= 0 || size.y <= 0 do return
	view_proj := camera.orbit_proj(app.camera, size.x / size.y) * camera.orbit_view(app.camera)
	count = l.n * l.n * l.n
	for i in 0 ..< count do at[i], ok[i] = gizmo.project(view_proj, to_world(obj.transform, lattice_point(l, i)), size)
	return
}

// The point under `at` (from 1), the nearest within reach of the pointer in use, the
// one nearer the eye where two are as near; 0 for none. A stale cage is made again
// first, so the pick is of the points drawn this frame.
lattice_pick :: proc(app: ^App, at, size: [2]f32) -> int {
	obj := lattice_object(app)
	if obj == nil || !lattice_sync(app, obj) do return 0
	l := &app.ui.deform.lattice
	points, ok, count := lattice_screen(app, obj, size)
	reach := gizmo_radius(app)
	eye := camera.orbit_eye(app.camera)
	best, best_d, best_depth := 0, reach, f32(0)
	for i in 0 ..< count {
		if !ok[i] do continue
		d := linalg.length(points[i] - at)
		depth := linalg.length(to_world(obj.transform, lattice_point(l, i)) - eye)
		if d < best_d - 0.5 || (d <= best_d + 0.5 && best > 0 && depth < best_depth) {
			best, best_d, best_depth = i + 1, min(d, best_d), depth
		}
	}
	return best
}

// Starts a drag of point `point` (from 1) of `obj`'s cage: notes where the vertices are
// in the cage if this is its first drag, then poses as a gizmo handle does.
lattice_begin :: proc(app: ^App, obj: ^Object) -> bool {
	l := &app.ui.deform.lattice
	s := object_sculptor(obj)
	if !sculpt.sculptor_lattice_ready(s) do sculpt.sculptor_lattice_rest(s, l.lo, l.hi)
	l.frame_ms, l.frames = 0, 0
	return pose_begin(app, obj)
}

// The pose a drag of point `point` (from 1) makes when it has moved by the world
// `offset` on an object placed at `t`.
lattice_pose_of :: proc(app: ^App, point: int, t: Transform, offset: Vec3) -> sculpt.Pose {
	l := &app.ui.deform.lattice
	return {kind = .Lattice, lattice = {points = l.n, point = lattice_index(l.n, point - 1), offset = to_local_dir(t, offset) / t.scale}}
}

// Poses `obj` by `p` for the drag under way, timing the frames that move the surface.
lattice_pose_set :: proc(app: ^App, obj: ^Object, p: sculpt.Pose) {
	drag := &app.move.drag
	if drag.applied ? drag.pose == p : pose_is_still(p) do return
	l := &app.ui.deform.lattice
	start := time.tick_now()
	pose_set(app, obj, p)
	l.frame_ms += time.duration_milliseconds(time.tick_since(start))
	l.frames += 1
}

// The point's drag became an undo step: the point stays where it was dragged to, and
// the cage belongs to the history as it now is.
lattice_moved :: proc(app: ^App, point: int, p: sculpt.Pose) {
	l := &app.ui.deform.lattice
	if !l.made || point < 1 || point > l.n * l.n * l.n do return
	l.offsets[point - 1] += p.lattice.offset
	l.last = point
	l.ms = l.frame_ms / f64(max(l.frames, 1))
	l.frame_ms, l.frames = 0, 0
	l.serial = app.history.serial
	l.drags += 1
}

// The cage: its edges between neighbouring points and its points, the one under the
// pointer or dragged in the highlight colour. Drawn in place of the gizmo.
draw_lattice :: proc(app: ^App, o: Overlay, input: Viewport_Input, obj: ^Object) {
	l := &app.ui.deform.lattice
	points, ok, count := lattice_screen(app, obj, input.size)
	if count == 0 do return
	px := gizmo_scale(app)
	n := l.n
	// While a point is dragged the pose has moved it already; the cage shows it there.
	dragged := app.move.drag.lattice
	if dragged > 0 && app.move.drag.applied {
		view_proj := camera.orbit_proj(app.camera, input.size.x / max(input.size.y, 1)) * camera.orbit_view(app.camera)
		moved := lattice_point(l, dragged - 1) + app.move.drag.pose.lattice.offset
		points[dragged - 1], ok[dragged - 1] = gizmo.project(view_proj, to_world(obj.transform, moved), input.size)
	}
	edge := overlay_color({1, 1, 1, 0.45})
	for i in 0 ..< count {
		ijk := lattice_index(n, i)
		for axis in 0 ..< 3 {
			if ijk[axis] == n - 1 do continue
			step := 1 if axis == 0 else (n if axis == 1 else n * n)
			if ok[i] && ok[i + step] do overlay_line(o, points[i], points[i + step], edge, 1.5 * px)
		}
	}
	active := dragged if dragged > 0 else l.hover
	for i in 0 ..< count {
		if !ok[i] do continue
		color := overlay_color(GIZMO_HIGHLIGHT if i + 1 == active else {1, 1, 1, 0.9})
		overlay_disc(o, points[i], (6 if i + 1 == active else 4.5) * px, color)
	}
	if l.last > 0 && l.last <= count && ok[l.last - 1] do l.last_at = points[l.last - 1]
}

// The Deformers section's Lattice: points a side, the cage made again at rest, and the
// Move tool, whose drags its points take.
kit_lattice :: proc(app: ^App) {
	ctx := &app.kit.ctx
	t := ctx.theme
	l := &app.ui.deform.lattice
	ui.label(ctx, "Points a side", t.small_size)
	names := [?]string{"2##lattice", "3##lattice", "4##lattice"}
	if picked := ui.tabs(ctx, "lattice points", names[:], l.points - 2); picked >= 0 && app.move.drag.lattice == 0 do l.points = picked + 2
	if ui.button(ctx, "Fit the cage again", .Flat, enabled = l.made && app.move.drag.lattice == 0) do lattice_drop(app)
	if app.tool != .Move do _ = command_button(app, .Tool_Move, label = "Use the Move tool", tone = .Accent)
	ui.paragraph(ctx, "With the Move tool, a cage of points stands round the part the mask leaves free in place of the gizmo; drag a point to pull the surface near it. Each drag is one undo step. Any other change (a stroke, a mask, an undo) fits the cage again round the surface as it is; so does Fit the cage again. Not in HD or with dynamic topology.")
}
