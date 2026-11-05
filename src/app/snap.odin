package main

import "core:fmt"
import "core:math/linalg"
import "core:slice"

import "../gizmo"
import "../poly"
import "../ui"

// What a snapped move lands on, as Blender's snapping targets and Shapr3D's and
// Plasticity's point snapping do: Grid steps the move by a grid that follows the zoom (the
// way every snapped drag has worked); Points lands the gizmo's middle on the cage point,
// edge middle, face middle or curve point nearest the pointer on screen; Surface lands it
// where the pointer meets a surface. A move snaps while Snap is on or Ctrl is held; turns
// and scales keep their steps. Shared by the object gizmo, a cage's selection and a curve's
// picked points.
Snap_To :: enum u8 {
	Grid,
	Points,
	Surface,
}

@(rodata)
SNAP_TO_NAMES := [Snap_To]string {
	.Grid    = "Grid",
	.Points  = "Points",
	.Surface = "Surface",
}

// How near the pointer, in points on screen, a point must show to be snapped to: about a
// fingertip's half, so a pen or a finger finds it without hunting.
SNAP_POINT_PX :: 18

// What a snap must not land on: what the drag moves. `id` is that object (0 for none);
// `whole` skips all of it, else only `points` (ascending: a cage's moving points, a curve's
// picked points). `others` are more objects skipped whole (a selection moving together).
Snap_Skip :: struct {
	id:     int,
	whole:  bool,
	points: []u32,
	others: []int,
}

@(private = "file")
snap_skipped :: proc(skip: Snap_Skip, obj: ^Object) -> bool {
	if obj.id == skip.id && skip.whole do return true
	return slice.contains(skip.others, obj.id)
}

@(private = "file")
snap_point_moving :: proc(skip: Snap_Skip, obj: ^Object, v: u32) -> bool {
	if obj.id != skip.id do return false
	_, found := slice.binary_search(skip.points, v)
	return found
}

// The world point a snap with the pointer at `at` lands on, as `app.move.snap_to` says;
// not ok for Grid, or when nothing is near enough (the move then goes free).
snap_target :: proc(app: ^App, at, size: [2]f32, skip: Snap_Skip) -> (p: Vec3, ok: bool) {
	return snap_find(app, app.move.snap_to, at, size, skip)
}

// The world point the pointer at `at` lands on by snapping `to`: Measure takes points
// first and the surface second whatever the Snap setting says.
snap_find :: proc(app: ^App, to: Snap_To, at, size: [2]f32, skip: Snap_Skip) -> (p: Vec3, ok: bool) {
	switch to {
	case .Grid:
		return
	case .Surface:
		origin, dir := mouse_ray(app.camera, at, size)
		best := max(f32)
		for obj, i in app.scene.objects {
			if snap_skipped(skip, obj) || obj.id == skip.id do continue
			if !object_pickable(app, obj) || obj.curve != nil do continue
			_, hit, hit_ok := scene_raycast(app, origin, dir, only = i)
			if !hit_ok do continue
			if d := linalg.length(hit - origin); d < best do best, p, ok = d, hit, true
		}
		return
	case .Points:
		vp := view_proj_of(app, size)
		reach := SNAP_POINT_PX * gizmo_scale(app)
		best := reach * reach
		take :: proc(vp: matrix[4, 4]f32, w: Vec3, at, size: [2]f32, best: ^f32, p: ^Vec3, ok: ^bool) {
			s, seen := gizmo.project(vp, w, size)
			if !seen do return
			if d := linalg.length2(s - at); d < best^ {
				best^, p^, ok^ = d, w, true
			}
		}
		for obj in app.scene.objects {
			if snap_skipped(skip, obj) || !object_shown(app, obj) do continue
			t := obj.transform
			if cp := obj.cage; cp != nil {
				m := &cp.mesh
				for q, v in m.positions do if !snap_point_moving(skip, obj, u32(v)) do take(vp, to_world(t, q), at, size, &best, &p, &ok)
				// Middles of edges and faces none of whose corners move.
				for e in 0 ..< u32(len(m.crease)) {
					a, b := poly.edge_verts(m, e)
					if snap_point_moving(skip, obj, a) || snap_point_moving(skip, obj, b) do continue
					take(vp, to_world(t, (m.positions[a] + m.positions[b]) * 0.5), at, size, &best, &p, &ok)
				}
				for f in 0 ..< u32(len(m.face_he)) {
					moving := false
					w := poly.face_walk(m, f)
					for h in poly.face_walk_next(&w) do moving ||= snap_point_moving(skip, obj, m.he_vert[h])
					if !moving do take(vp, to_world(t, poly.face_center(m, f)), at, size, &best, &p, &ok)
				}
			}
			if c := obj.curve; c != nil {
				for q, i in c.points do if !snap_point_moving(skip, obj, u32(i)) do take(vp, to_world(t, q.p), at, size, &best, &p, &ok)
			}
		}
		return
	}
	return
}

// The move a snap to `target` makes from `from`, kept to what the handle allows: along the
// arm `axis` for an arm (its amount too), in the plane square to `normal` for a plane
// square, or all of it for the middle.
snap_move :: proc(handle: gizmo.Handle, from, target: Vec3, axes: [3]Vec3) -> (move: Vec3, amount: f32) {
	d := target - from
	#partial switch handle {
	case .X, .Y, .Z:
		axis := axes[int(handle) - int(gizmo.Handle.X)]
		amount = linalg.dot(d, axis)
		return axis * amount, amount
	case .YZ, .XZ, .XY:
		n := axes[int(handle) - int(gizmo.Handle.YZ)]
		return d - n * linalg.dot(d, n), 0
	}
	return d, 0
}

// A ring where a snapped move landed, so what it stuck to shows.
draw_snap_mark :: proc(app: ^App, o: Overlay, size: [2]f32, at: Vec3) {
	s, seen := gizmo.project(view_proj_of(app, size), at, size)
	if !seen do return
	px := gizmo_scale(app)
	overlay_circle(o, s, 7 * px, overlay_color(GIZMO_HIGHLIGHT), 2 * px)
}

// The Snap switch and what a snapped move lands on, wherever a gizmo's settings show.
kit_snap_rows :: proc(app: ^App, name: string) {
	ctx := &app.kit.ctx
	_ = ui.switch_row(ctx, "Snap", &app.move.snap)
	names: [len(Snap_To)]string
	for n, s in SNAP_TO_NAMES do names[int(s)] = n
	if picked := ui.tabs(ctx, fmt.tprintf("snap to##%s", name), names[:], int(app.move.snap_to)); picked >= 0 do app.move.snap_to = Snap_To(picked)
}
