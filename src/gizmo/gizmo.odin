// Package gizmo is the pure math behind the move tool: projecting points to the
// screen, picking a handle under the cursor, and turning mouse rays into motion along
// an axis or a plane, turns about an axis and uniform scales. It knows nothing of the
// interface, the renderer or meshes.
package gizmo

import "core:math/linalg"

Vec2 :: [2]f32
Vec3 :: [3]f32
Mat4 :: matrix[4, 4]f32

// Which part of the gizmo is under the cursor or being dragged.
Handle :: enum u8 {
	None,
	X,
	Y,
	Z,
	View, // the centre square: move in the view plane
	// The plane squares between two arms, each named by the plane it moves in and
	// ordered by the axis it holds still.
	YZ,
	XZ,
	XY,
	// The rings, each turning about its axis, and the outer ring about the view's.
	Turn_X,
	Turn_Y,
	Turn_Z,
	Turn_View,
	Scale, // the centre disc and the circle round it
}

// What the gizmo's handles do: move, turn or scale.
Mode :: enum u8 {
	Move,
	Turn,
	Scale,
}

AXES := [3]Vec3{{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}

// Axis arms are this long on screen, whatever the zoom.
ARM_PX :: 90 // an arm's length on screen; camera.orbit_world_per_px turns it into world units
// The cursor picks an arm within this many pixels of it.
PICK_PX :: 8
// Half the side of the centre square.
CENTER_PX :: 9
// The scale mode's centre disc's radius.
SCALE_DISC_PX :: 12

// Projects a world point to viewport pixels (origin top-left). Not ok behind the camera.
project :: proc(view_proj: Mat4, p: Vec3, size: Vec2) -> (screen: Vec2, ok: bool) {
	h := view_proj * [4]f32{p.x, p.y, p.z, 1}
	if h.w <= 1e-6 do return
	ndc := h.xy / h.w
	return {(ndc.x + 1) * 0.5 * size.x, (1 - ndc.y) * 0.5 * size.y}, true
}

// Distance from p to the segment a-b, in the same units as the inputs.
segment_distance :: proc(p, a, b: Vec2) -> f32 {
	ab := b - a
	len2 := linalg.dot(ab, ab)
	t: f32 = 0
	if len2 > 0 do t = clamp(linalg.dot(p - a, ab) / len2, 0, 1)
	return linalg.length(p - (a + ab * t))
}

// The gizmo as it is seen: its centre, arm tips and rings projected to the screen.
Screen :: struct {
	center:     Vec2,
	tips:       [3]Vec2,
	tip_ok:     [3]bool,
	// The rings about x, y and z, then the view ring; a ring with a point behind the eye
	// is not ok, and is neither drawn nor picked.
	rings:      [4][RING_POINTS]Vec2,
	ring_front: [4][RING_POINTS]bool,
	ring_ok:    [4]bool,
	arm_px:     f32, // an arm's length on screen, which the scale circle's radius is too
	ok:         bool,
}

// Projects the gizmo at `center` whose arms are `arm` long in the world, seen from the
// direction `toward_eye` (from the centre to the eye, or the view's own in parallel
// projection), on a viewport of `size`, whose arms are `arm_px` long on screen.
screen :: proc(view_proj: Mat4, center: Vec3, arm: f32, toward_eye: Vec3, size: Vec2, arm_px: f32) -> (s: Screen) {
	s.center, s.ok = project(view_proj, center, size)
	if !s.ok do return
	s.arm_px = arm_px
	for axis, i in AXES {
		s.tips[i], s.tip_ok[i] = project(view_proj, center + axis * arm, size)
		s.rings[i], s.ring_front[i], s.ring_ok[i] = ring(view_proj, center, axis, arm, toward_eye, size)
	}
	s.rings[3], _, s.ring_ok[3] = ring(view_proj, center, toward_eye, arm * VIEW_RING_SCALE, toward_eye, size)
	for &f in s.ring_front[3] do f = true
	return
}

// The handle of `mode` under `mouse`, picked within `radius` pixels (PICK_PX for a mouse,
// more for a finger, whose centre handles grow by as much): the nearest one wins, and the
// centre before anything. Arms that did not project, or that point at the eye, cannot be
// picked, nor a plane square seen edge on.
pick :: proc(s: Screen, mode: Mode, mouse: Vec2, radius: f32) -> Handle {
	s := s
	if !s.ok do return .None
	// The centre handles grow with the interface's scale, as they are drawn, and by as
	// much again as the radius exceeds the mouse's.
	k := s.arm_px / ARM_PX if s.arm_px > 0 else 1
	grow := max(radius - PICK_PX * k, 0)
	d := mouse - s.center
	best := Handle.None
	best_dist := radius
	consider :: proc(best: ^Handle, best_dist: ^f32, h: Handle, dist: f32) {
		if dist <= best_dist^ do best^, best_dist^ = h, dist
	}
	switch mode {
	case .Move:
		if abs(d.x) <= CENTER_PX * k + grow && abs(d.y) <= CENTER_PX * k + grow do return .View
		for i in 0 ..< 3 {
			if !arm_shows(s, i) do continue
			consider(&best, &best_dist, Handle(int(Handle.X) + i), segment_distance(mouse, s.center, s.tips[i]))
		}
		for i in 0 ..< 3 {
			q, ok := square_of(s, i)
			if !ok do continue
			dist: f32 = 0
			if !inside_quad(mouse, q) do dist = quad_distance(mouse, q)
			consider(&best, &best_dist, Handle(int(Handle.YZ) + i), dist)
		}
	case .Turn:
		for i in 0 ..< 4 {
			if !s.ring_ok[i] do continue
			consider(&best, &best_dist, Handle(int(Handle.Turn_X) + i), ring_distance(mouse, s.rings[i][:]))
		}
	case .Scale:
		dist := linalg.length(d)
		if dist <= SCALE_DISC_PX * k + grow do return .Scale
		consider(&best, &best_dist, .Scale, abs(dist - s.arm_px))
	}
	return best
}

// Whether arm `i` shows: its tip projected and it does not point at the eye.
arm_shows :: proc(s: Screen, i: int) -> bool {
	return s.tip_ok[i] && linalg.length(s.tips[i] - s.center) >= 2 * CENTER_PX
}

// The plane square that holds axis `i` still, between the other two arms; not ok when
// either arm is hidden or the plane is seen nearly edge on, where it is a sliver.
square_of :: proc(s: Screen, i: int) -> (q: [4]Vec2, ok: bool) {
	a, b := (i + 1) % 3, (i + 2) % 3
	if !arm_shows(s, a) || !arm_shows(s, b) do return
	da, db := s.tips[a] - s.center, s.tips[b] - s.center
	if abs(da.x * db.y - da.y * db.x) < 0.2 * linalg.length(da) * linalg.length(db) do return
	return plane_square(s.center, s.tips[a], s.tips[b]), true
}

// The distance from `p` to the outline of quad `q`.
quad_distance :: proc(p: Vec2, q: [4]Vec2) -> f32 {
	best := max(f32)
	for i in 0 ..< 4 do best = min(best, segment_distance(p, q[i], q[(i + 1) % 4]))
	return best
}

// Parameter s of the point on the line origin + s*axis closest to the ray. Not ok when
// the ray runs (nearly) parallel to the axis, where dragging along it is meaningless.
closest_on_axis :: proc(origin, axis, ray_origin, ray_dir: Vec3) -> (s: f32, ok: bool) {
	// Minimise |origin + s*axis - (ray_origin + t*ray_dir)| over s and t.
	w := origin - ray_origin
	a := linalg.dot(axis, axis)
	b := linalg.dot(axis, ray_dir)
	c := linalg.dot(ray_dir, ray_dir)
	d := linalg.dot(axis, w)
	e := linalg.dot(ray_dir, w)
	denom := a * c - b * b
	if denom < 1e-6 * a * c do return
	return (b * e - c * d) / denom, true
}

// Where the ray meets the plane through `point` with normal `normal`.
ray_plane :: proc(ray_origin, ray_dir, point, normal: Vec3) -> (hit: Vec3, ok: bool) {
	denom := linalg.dot(ray_dir, normal)
	if abs(denom) < 1e-6 do return
	t := linalg.dot(point - ray_origin, normal) / denom
	if t < 0 do return
	return ray_origin + ray_dir * t, true
}
