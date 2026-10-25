// Package camera holds the orbit camera used by the viewport. It is pure math:
// callers feed it input deltas and read matrices back.
package camera

import "core:math"
import "core:math/linalg"

Vec2 :: [2]f32
Vec3 :: [3]f32
Mat4 :: matrix[4, 4]f32

Orbit :: struct {
	target:   Vec3,
	distance: f32,
	yaw:      f32, // radians around +Y
	pitch:    f32, // radians, clamped short of the poles
	fov_y:    f32, // radians
	near:     f32,
	far:      f32,
	ortho:    bool, // parallel projection, as wide at the target as the perspective view
}

PITCH_LIMIT :: math.PI / 2 - 0.01
MIN_DISTANCE :: 0.05
MAX_DISTANCE :: 1000

orbit_default :: proc() -> Orbit {
	return Orbit{distance = 3.5, yaw = 0.6, pitch = 0.35, fov_y = math.to_radians(f32(40)), near = 0.01, far = 100}
}

orbit_eye :: proc(c: Orbit) -> Vec3 {
	cp, sp := math.cos(c.pitch), math.sin(c.pitch)
	cy, sy := math.cos(c.yaw), math.sin(c.yaw)
	return c.target + c.distance * Vec3{cp * sy, sp, cp * cy}
}

// Rotates around the target. Delta is in pixels; `speed` is radians per pixel.
orbit_rotate :: proc(c: ^Orbit, delta: Vec2, speed: f32 = 0.008) {
	c.yaw -= delta.x * speed
	c.pitch = clamp(c.pitch + delta.y * speed, -PITCH_LIMIT, PITCH_LIMIT)
}

// Moves the target in the view plane so the point under the cursor follows it.
orbit_pan :: proc(c: ^Orbit, delta: Vec2, viewport_height: f32) {
	if viewport_height <= 0 do return
	view := orbit_view(c^)
	right := Vec3{view[0, 0], view[0, 1], view[0, 2]}
	up := Vec3{view[1, 0], view[1, 1], view[1, 2]}
	world_per_pixel := 2 * c.distance * math.tan(c.fov_y / 2) / viewport_height
	c.target += (-delta.x * right + delta.y * up) * world_per_pixel
}

// Scales distance exponentially so each wheel notch feels the same at any zoom.
orbit_zoom :: proc(c: ^Orbit, wheel_steps: f32) {
	c.distance = clamp(c.distance * math.pow(0.88, wheel_steps), MIN_DISTANCE, MAX_DISTANCE)
}

// Moves the eye `factor` times closer, as spreading two fingers that many times apart
// does; below 1 moves it away.
orbit_zoom_by :: proc(c: ^Orbit, factor: f32) {
	if factor <= 0 do return
	c.distance = clamp(c.distance / factor, MIN_DISTANCE, MAX_DISTANCE)
}

// The turn a leaning pen gives the brush (the direction it pushes along): `tilt` is the
// pen's lean in degrees, x to the right and y toward the bottom of the screen, as SDL
// reports it, and `strength` how much of it the brush follows. The brush direction
// turns about the view's up axis by strength times the x lean and about its right axis
// by strength times the y lean, at most MAX_TILT in all, so a brush facing the viewer
// leans the way the top of the pen does, as Blender's tilt strength works. Identity
// for no lean.
orbit_tilt :: proc(c: Orbit, tilt: Vec2, strength: f32) -> matrix[3, 3]f32 {
	angles := linalg.to_radians(tilt * strength)
	if l := linalg.length(angles); l > MAX_TILT do angles *= MAX_TILT / l
	view := orbit_view(c)
	right := Vec3{view[0, 0], view[0, 1], view[0, 2]}
	up := Vec3{view[1, 0], view[1, 1], view[1, 2]}
	// About up by +x turns the viewer's direction toward right; about right by +y
	// turns it toward -up, the bottom of the screen.
	return linalg.matrix3_rotate(angles.x, up) * linalg.matrix3_rotate(angles.y, right)
}

// The most a pen's lean turns the brush, in radians.
MAX_TILT :: math.PI / 2 * 0.9

orbit_view :: proc(c: Orbit) -> Mat4 {
	return look_at(orbit_eye(c), c.target, {0, 1, 0})
}

orbit_proj :: proc(c: Orbit, aspect: f32) -> Mat4 {
	if c.ortho {
		// Depth reaches as far behind the eye as in front of it, so zooming in (moving
		// the eye toward the target) never cuts into what is drawn.
		return orthographic(c.distance * math.tan(c.fov_y / 2), aspect, -c.far, c.far)
	}
	return perspective(c.fov_y, aspect, c.near, c.far)
}

// World units one pixel covers at `p`, for a viewport `viewport_height` pixels tall:
// further means larger in perspective, the same everywhere in parallel projection.
orbit_world_per_px :: proc(c: Orbit, p: Vec3, viewport_height: f32) -> f32 {
	dist := c.distance if c.ortho else linalg.length(p - orbit_eye(c))
	return 2 * dist * math.tan(c.fov_y / 2) / max(viewport_height, 1)
}

// The way the camera looks at `p`: from the eye to it, or the view's own direction in
// parallel projection.
orbit_toward :: proc(c: Orbit, p: Vec3) -> Vec3 {
	return linalg.normalize((c.target if c.ortho else p) - orbit_eye(c))
}

// Right-handed view matrix (camera looks down -Z).
look_at :: proc(eye, target, up: Vec3) -> Mat4 {
	f := linalg.normalize(target - eye)
	s := linalg.normalize(linalg.cross(f, up))
	u := linalg.cross(s, f)
	return Mat4{
		s.x, s.y, s.z, -linalg.dot(s, eye),
		u.x, u.y, u.z, -linalg.dot(u, eye),
		-f.x, -f.y, -f.z, linalg.dot(f, eye),
		0, 0, 0, 1,
	}
}

// Right-handed parallel projection `half_height` world units above and below the view's
// middle, with view-space depths -near to -far mapped to [0, 1].
orthographic :: proc(half_height, aspect, near, far: f32) -> Mat4 {
	h := 1 / half_height
	return Mat4{
		h / aspect, 0, 0, 0,
		0, h, 0, 0,
		0, 0, 1 / (near - far), near / (near - far),
		0, 0, 0, 1,
	}
}

// Right-handed perspective with clip-space depth in [0, 1], as SDL_GPU expects.
perspective :: proc(fov_y, aspect, near, far: f32) -> Mat4 {
	f := 1 / math.tan(fov_y / 2)
	return Mat4{
		f / aspect, 0, 0, 0,
		0, f, 0, 0,
		0, 0, far / (near - far), near * far / (near - far),
		0, 0, -1, 0,
	}
}

// The six views along the axes, as Blender's numpad keys give them.
Axis_View :: enum {
	Front,  // from +Z, looking down -Z
	Back,   // from -Z
	Right,  // from +X
	Left,   // from -X
	Top,    // from +Y, as near straight down as the pitch limit allows
	Bottom, // from -Y
}

// Turns the camera to look at its target from along an axis, keeping target and distance.
orbit_axis_view :: proc(c: ^Orbit, view: Axis_View) {
	switch view {
	case .Front:  c.yaw, c.pitch = 0, 0
	case .Back:   c.yaw, c.pitch = math.PI, 0
	case .Right:  c.yaw, c.pitch = math.PI / 2, 0
	case .Left:   c.yaw, c.pitch = -math.PI / 2, 0
	case .Top:    c.yaw, c.pitch = 0, PITCH_LIMIT
	case .Bottom: c.yaw, c.pitch = 0, -PITCH_LIMIT
	}
}
