// Package gizmo is the pure math behind the move tool: projecting points to the
// screen, picking a handle under the cursor, and turning mouse rays into motion along
// an axis or across the view plane. It knows nothing of the interface, the renderer or meshes.
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
}

AXES := [3]Vec3{{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}

// Axis arms are this long on screen, whatever the zoom.
ARM_PX :: 90 // an arm's length on screen; camera.orbit_world_per_px turns it into world units
// The cursor picks an arm within this many pixels of it.
PICK_PX :: 8
// Half the side of the centre square.
CENTER_PX :: 9

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

// The handle under `mouse`, given the gizmo's centre and arm tips already projected.
// Arms whose tip did not project, or that collapse to a point, cannot be picked.
pick :: proc(mouse, center: Vec2, tips: [3]Vec2, tip_ok: [3]bool) -> Handle {
	d := mouse - center
	if abs(d.x) <= CENTER_PX && abs(d.y) <= CENTER_PX do return .View
	best := Handle.None
	best_dist := f32(PICK_PX)
	for i in 0 ..< 3 {
		if !tip_ok[i] || linalg.length(tips[i] - center) < 2 * CENTER_PX do continue
		if dist := segment_distance(mouse, center, tips[i]); dist <= best_dist {
			best, best_dist = Handle(i + 1), dist
		}
	}
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
