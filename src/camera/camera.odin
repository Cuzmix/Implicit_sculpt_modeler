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

orbit_view :: proc(c: Orbit) -> Mat4 {
	return look_at(orbit_eye(c), c.target, {0, 1, 0})
}

orbit_proj :: proc(c: Orbit, aspect: f32) -> Mat4 {
	return perspective(c.fov_y, aspect, c.near, c.far)
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
