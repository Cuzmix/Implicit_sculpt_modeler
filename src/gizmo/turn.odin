package gizmo

import "core:math"
import "core:math/linalg"

Mat3 :: matrix[3, 3]f32

// The turn and scale handles, and the plane squares, beside the move arms: still pure
// math on points already projected to the screen and rays already made.

// How many points a ring is drawn and picked with.
RING_POINTS :: 64
// The view ring sits this much outside the axis rings, as Blender's and Maya's do.
VIEW_RING_SCALE :: 1.25
// The plane squares span this share of the arms, from the centre outward.
SQUARE_FROM :: 0.28
SQUARE_TO :: 0.48
// The All mode, in shares of the arm: the axis rings shrink so the view ring (a quarter
// further out) stays inside the arms, which run on to arrows past it, so no ring ever
// hides an arrow; a scale knob sits on each arm between the plane squares and the rings,
// far enough from both for a finger to tell them apart.
ALL_RING :: 0.85
ALL_ARM :: 1.35
KNOB_AT :: 0.62
// Half a scale knob's side, in pixels; it picks within this plus the pointer's grow.
KNOB_PX :: 6
// The All mode's arrowheads: their length and half their width, in pixels.
ARROW_PX :: 12
ARROW_HALF_PX :: 6

// The turn of `degrees` about x, then y, then z, as Transform.rotation stores it.
rotation_matrix :: proc(degrees: Vec3) -> Mat3 {
	if degrees == {} do return 1
	r := linalg.to_radians(degrees)
	return linalg.matrix3_rotate_f32(r.z, {0, 0, 1}) * linalg.matrix3_rotate_f32(r.y, {0, 1, 0}) * linalg.matrix3_rotate_f32(r.x, {1, 0, 0})
}

// The degrees about x, then y, then z that rotation_matrix turns back into `m`, each
// between -180 and 180 and the y turn between -90 and 90. At a y turn of ±90 degrees x
// and z turn about the same axis, so x is taken as 0 and z carries it all.
rotation_degrees :: proc(m: Mat3) -> Vec3 {
	// m = Rz(c) Ry(b) Rx(a): m[2,0] = -sin b, m[2,1] = cos b sin a, m[2,2] = cos b cos a,
	// m[1,0] = sin c cos b, m[0,0] = cos c cos b.
	// atan2 rather than asin: asin loses half its digits as the turn nears the poles.
	cb := math.sqrt(m[0, 0] * m[0, 0] + m[1, 0] * m[1, 0])
	b := math.atan2(-m[2, 0], cb)
	a, c: f32
	if cb > 1e-5 {
		a = math.atan2(m[2, 1], m[2, 2])
		c = math.atan2(m[1, 0], m[0, 0])
	} else {
		// With a = 0: m[0,1] = -sin c and m[1,1] = cos c.
		c = math.atan2(-m[0, 1], m[1, 1])
	}
	return linalg.to_degrees(Vec3{a, b, c})
}

// The ring of `radius` about `axis` through `center`, projected; ok false when any point
// is behind the eye. `front` says which points face the eye (`toward_eye` from the
// centre), for drawing the far half dimmer.
ring :: proc(view_proj: Mat4, center, axis: Vec3, radius: f32, toward_eye: Vec3, size: Vec2) -> (points: [RING_POINTS]Vec2, front: [RING_POINTS]bool, ok: bool) {
	u, v := plane_basis(axis)
	for i in 0 ..< RING_POINTS {
		a := f32(i) / RING_POINTS * math.TAU
		d := u * math.cos(a) + v * math.sin(a)
		points[i] = project(view_proj, center + d * radius, size) or_return
		front[i] = linalg.dot(d, toward_eye) >= 0
	}
	return points, front, true
}

// Two unit vectors that span the plane square to `axis`.
plane_basis :: proc(axis: Vec3) -> (u, v: Vec3) {
	n := linalg.normalize(axis)
	helper := Vec3{1, 0, 0} if abs(n.x) < 0.9 else Vec3{0, 1, 0}
	u = linalg.normalize(linalg.cross(n, helper))
	v = linalg.cross(n, u)
	return
}

// The distance from `p` to the closed polyline through `points`.
ring_distance :: proc(p: Vec2, points: []Vec2) -> f32 {
	best := max(f32)
	for i in 0 ..< len(points) {
		best = min(best, segment_distance(p, points[i], points[(i + 1) % len(points)]))
	}
	return best
}

// The turn, in radians about `axis`, that takes the direction from `center` to `from`
// onto the direction to `to`, both points on the plane square to the axis.
plane_turn :: proc(center, axis, from, to: Vec3) -> f32 {
	a, b := from - center, to - center
	return math.atan2(linalg.dot(linalg.normalize(axis), linalg.cross(a, b)), linalg.dot(a, b))
}

// The turn about `axis` a drag of `delta` pixels gives along a ring seen nearly edge on,
// where a ray meets its plane far from where the pointer is: the drag along the ring's
// direction on the screen at the grab point (`tangent`, in pixels a radian) turns it.
tangent_turn :: proc(delta, tangent: Vec2) -> f32 {
	len2 := linalg.dot(tangent, tangent)
	if len2 < 1e-6 do return 0
	return linalg.dot(delta, tangent) / len2
}

// How far a scale drag has gone: `arm_px` further from the centre than the press doubles
// the size about e times (e^1), and as far toward it shrinks it as much. Measured by the
// change in distance rather than its ratio, so a press on the very centre scales as
// evenly as one on the circle.
scale_factor :: proc(center, from, to: Vec2, arm_px: f32) -> f32 {
	return math.exp((linalg.length(to - center) - linalg.length(from - center)) / max(arm_px, 1))
}

// The direction a ring runs on screen at the point of it nearest `p`, in pixels a radian
// of turn about its axis: what a drag along an edge-on ring turns it by (tangent_turn).
ring_tangent :: proc(points: []Vec2, p: Vec2) -> Vec2 {
	n := len(points)
	if n < 3 do return {}
	near, best := 0, max(f32)
	for q, i in points {
		if d := linalg.length(q - p); d < best do near, best = i, d
	}
	step := math.TAU / f32(n)
	return (points[(near + 1) % n] - points[(near + n - 1) % n]) / (2 * step)
}

// `degrees` brought into -180 up to (not including) 180.
wrap_degrees :: proc(degrees: f32) -> f32 {
	w := math.mod(degrees + 180, 360)
	if w < 0 do w += 360
	return w - 180
}

// The plane square between arms `a` and `b` (projected tips), as a quad on screen.
plane_square :: proc(center, tip_a, tip_b: Vec2) -> [4]Vec2 {
	da, db := tip_a - center, tip_b - center
	return {
		center + da * SQUARE_FROM + db * SQUARE_FROM,
		center + da * SQUARE_TO + db * SQUARE_FROM,
		center + da * SQUARE_TO + db * SQUARE_TO,
		center + da * SQUARE_FROM + db * SQUARE_TO,
	}
}

// Whether `p` is inside the convex quad `q` (either winding).
inside_quad :: proc(p: Vec2, q: [4]Vec2) -> bool {
	sign: f32
	for i in 0 ..< 4 {
		e, w := q[(i + 1) % 4] - q[i], p - q[i]
		c := e.x * w.y - e.y * w.x
		if c == 0 do continue
		if sign == 0 do sign = c
		if (c > 0) != (sign > 0) do return false
	}
	return true
}

// `v` to the nearest whole multiple of `step` (unchanged when step is 0).
snap :: proc(v, step: f32) -> f32 {
	if step <= 0 do return v
	return math.round(v / step) * step
}

// The move grid's step at a zoom of `world_per_px`: a power of ten about half an arm
// long on screen, so a snapped drag moves in steps that read at that zoom.
grid_step :: proc(world_per_px: f32) -> f32 {
	return math.pow(10, math.floor(math.log10(max(world_per_px * ARM_PX * 0.5, 1e-9))))
}

// Turns snap to this many degrees, and scale factors to steps of SCALE_SNAP.
TURN_SNAP_DEGREES :: 15
SCALE_SNAP :: 0.1
