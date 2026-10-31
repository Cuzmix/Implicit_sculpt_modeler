// Package camera holds the orbit camera used by the viewport. It is pure math:
// callers feed it input deltas and read matrices back.
package camera

import "core:math"
import "core:math/linalg"

Vec2 :: [2]f32
Vec3 :: [3]f32
Mat4 :: matrix[4, 4]f32

// Where the camera is, as ZBrush keeps it: a target to turn about, how far the eye is
// from it, and which way it looks as three angles. The view is built from the angles
// alone, never by looking at the target with the world's up, so it stays steady over
// the top and upside down: there is no pole for it to flip at.
Orbit :: struct {
	target:   Vec3,
	distance: f32,
	yaw:      f32, // radians around the world's +Y
	pitch:    f32, // radians above the horizon; past a quarter turn the view is upside down
	roll:     f32, // radians around the view direction
	fov_y:    f32, // radians
	near:     f32,
	far:      f32,
	ortho:    bool, // parallel projection, as wide at the target as the perspective view
	// Where the target is drawn: half-heights of the viewport from its middle, x right and
	// y up, so a model can sit in the middle of the room the panels leave and still turn
	// about itself. Zero draws it in the middle.
	shift:    Vec2,
}

// How a drag turns the view (Settings > Camera): ZBrush's kinds of rotation.
Orbit_Style :: enum u8 {
	// A trackball, ZBrush's Rot XYZ and its default: a drag turns the model about the
	// screen's own axes, sideways about the screen's up and up and down about its right,
	// so every view is one drag away and the view may end up rolled.
	Free,
	// ZBrush's Rot Y, and the app's default, as most 3D apps orbit: sideways turns about
	// the world's up axis, up and down tilts, so the horizon stays level. Round and round
	// both ways without end, over the top too unless `limit_pitch` stops it at straight up
	// and straight down. A rolled view (orbit_roll) shows the turntable tilted, and a drag
	// still turns it about the world's up, read along the rolled screen.
	Turntable,
	// ZBrush's Rot X and Rot Z: sideways turns about the world's X (or Z) axis, and up
	// and down turns about the screen's right, as Free does.
	Axis_X,
	Axis_Z,
}

// How the pointer turns the view.
Orbit_Settings :: struct {
	style:       Orbit_Style,
	limit_pitch: bool, // a turntable stops just short of straight up and straight down
	speed:       f32, // radians per pixel
	invert_x:    bool, // dragging right turns the model left
	invert_y:    bool, // dragging down tilts the model away
	// Axis_X and Axis_Z: which way round a sideways drag turns about the axis, +1 or -1,
	// decided once as the drag begins (orbit_axis_sign), since the view's own up may lie
	// square to the axis, where a wobble up and down would flip it mid-drag. 0 decides from
	// the view as it is now.
	axis_sign:   f32,
}

ORBIT_SPEED :: 0.008 // radians per pixel at 1x
ORBIT_DEFAULT :: Orbit_Settings{style = .Turntable, speed = ORBIT_SPEED}

PITCH_LIMIT :: math.PI / 2 - 0.01
MIN_DISTANCE :: 0.05
MAX_DISTANCE :: 1000

// The field of view's range, in radians: from a long lens's flat look to a wide angle's
// strong perspective.
FOV_MIN :: f32(15 * math.PI / 180)
FOV_MAX :: f32(100 * math.PI / 180)

orbit_default :: proc() -> Orbit {
	return Orbit{distance = 3.5, yaw = 0.6, pitch = 0.35, fov_y = math.to_radians(f32(40)), near = 0.01, far = 100}
}

// The camera's turn: the yaw about the world's Y, then the pitch about the camera's
// right (negated, so a positive pitch looks down from above), then the roll about the
// view direction. Its columns are the camera's right, up and back (from the target
// toward the eye) in world space.
orbit_rotation :: proc(c: Orbit) -> matrix[3, 3]f32 {
	return linalg.matrix3_rotate(c.yaw, Vec3{0, 1, 0}) * linalg.matrix3_rotate(-c.pitch, Vec3{1, 0, 0}) * linalg.matrix3_rotate(c.roll, Vec3{0, 0, 1})
}

// The camera's right, up and back (toward the viewer) directions in world space.
orbit_basis :: proc(c: Orbit) -> (right, up, back: Vec3) {
	m := orbit_rotation(c)
	return {m[0, 0], m[1, 0], m[2, 0]}, {m[0, 1], m[1, 1], m[2, 1]}, {m[0, 2], m[1, 2], m[2, 2]}
}

orbit_eye :: proc(c: Orbit) -> Vec3 {
	_, _, back := orbit_basis(c)
	return c.target + c.distance * back
}

// Rotates around the target as `s` says; `delta` is how far the pointer moved, in
// pixels. Dragging right turns the model right and dragging down tilts it toward the
// viewer, for as many turns as the drag goes, either way. The angles stay within a turn
// of zero, so a long session never wears their precision down, and wrapping them
// changes nothing on screen.
orbit_rotate :: proc(c: ^Orbit, delta: Vec2, s := ORBIT_DEFAULT) {
	d := delta * s.speed
	if s.invert_x do d.x = -d.x
	if s.invert_y do d.y = -d.y
	switch s.style {
	case .Free:
		// About the screen's up, then its right: turns made in the camera's own frame.
		m := orbit_rotation(c^) * linalg.matrix3_rotate(-d.x, Vec3{0, 1, 0}) * linalg.matrix3_rotate(-d.y, Vec3{1, 0, 0})
		orbit_set_rotation(c, m)
	case .Turntable:
		// The roll turns the screen about the view direction after the yaw and pitch, so
		// the drag is turned back by it into the unrolled view, where sideways is the yaw
		// and up and down the pitch: the model follows the pointer however far it rolled.
		cr, sr := math.cos(c.roll), math.sin(c.roll)
		d = {d.x * cr + d.y * sr, d.y * cr - d.x * sr}
		// Upside down (pitched past a quarter turn), the world's up points down the
		// unrolled screen, so a drag right would turn the model left: turn the other way to
		// keep the model under the pointer.
		c.yaw = wrap_angle(c.yaw + (d.x if math.cos(c.pitch) < 0 else -d.x))
		if s.limit_pitch {
			c.pitch = clamp(c.pitch + d.y, -PITCH_LIMIT, PITCH_LIMIT)
		} else {
			c.pitch = wrap_angle(c.pitch + d.y)
		}
	case .Axis_X, .Axis_Z:
		// About the world's axis, applied in world space, then the screen's right in the
		// camera's own frame.
		axis := orbit_style_axis(s.style)
		sign := s.axis_sign if s.axis_sign != 0 else orbit_axis_sign(c^, s.style)
		m := linalg.matrix3_rotate(-d.x * sign, axis) * orbit_rotation(c^) * linalg.matrix3_rotate(-d.y, Vec3{1, 0, 0})
		orbit_set_rotation(c, m)
	}
}

// The world axis a single-axis style turns about sideways (Y for the turntable).
orbit_style_axis :: proc(style: Orbit_Style) -> Vec3 {
	#partial switch style {
	case .Axis_X: return {1, 0, 0}
	case .Axis_Z: return {0, 0, 1}
	}
	return {0, 1, 0}
}

// Which way round a sideways drag turns the view about a single-axis style's axis so the
// model follows the pointer: as the turntable does, by whether the screen's up points
// along the axis or against it; where the up lies nearly square to the axis (a front or
// side view, for Z), by whether the view looks along it.
orbit_axis_sign :: proc(c: Orbit, style: Orbit_Style) -> f32 {
	axis := orbit_style_axis(style)
	_, up, back := orbit_basis(c)
	along := linalg.dot(up, axis)
	if abs(along) < 0.2 do along = linalg.dot(back, axis)
	return -1 if along < 0 else 1
}

// Moves the target of `c`, whose angles have just changed from those of `before`, so that
// `pivot` stays where it was on screen: the eye swings about the pivot rather than about
// the target, as ZBrush's Local and Blender's Orbit Around Selection turn about the last
// stroke. Only the target moves, so the distance, and with it the pan and zoom rates and
// the parallel view's size, stay as they were. A pivot at the target changes nothing, so
// turning about the target stays exactly as orbit_rotate leaves it.
orbit_turn_about :: proc(c: ^Orbit, before: Orbit, pivot: Vec3) {
	if pivot == before.target do return
	// The pivot in the camera's frame before the turn, then the eye that puts it there
	// again after it.
	local := linalg.transpose(orbit_rotation(before)) * (pivot - orbit_eye(before))
	eye := pivot - orbit_rotation(c^) * local
	_, _, back := orbit_basis(c^)
	c.target = eye - c.distance * back
}

// Turns the view about the world's up axis by `angle` radians, as a turntable under the
// model would: the time-lapse's spin and the benchmarks' orbit.
orbit_spin :: proc(c: ^Orbit, angle: f32) {
	c.yaw = wrap_angle(c.yaw + angle)
}

// Rolls the view about its own direction by `angle` radians: positive turns what is on
// screen clockwise, as twisting two fingers clockwise does.
orbit_roll :: proc(c: ^Orbit, angle: f32) {
	c.roll = wrap_angle(c.roll + angle)
}

// Rolls the view as orbit_roll does, about the point `offset` pixels from the viewport's
// middle (x right, y down) rather than about the middle, so what is under two twisting
// fingers stays under them, as Procreate turns its canvas. Only the target's plane is
// kept exactly, as orbit_zoom_toward keeps it.
orbit_roll_about :: proc(c: ^Orbit, angle: f32, offset: Vec2, viewport_height: f32) {
	from := offset - orbit_shift_px(c^, viewport_height)
	if viewport_height <= 0 || from == {} {
		orbit_roll(c, angle)
		return
	}
	world_per_pixel := 2 * c.distance * math.tan(c.fov_y / 2) / viewport_height
	right, up, _ := orbit_basis(c^)
	under := c.target + (right * from.x - up * from.y) * world_per_pixel
	orbit_roll(c, angle)
	right, up, _ = orbit_basis(c^)
	c.target = under - (right * from.x - up * from.y) * world_per_pixel
}

// Sets the camera's turn from a rotation matrix (columns right, up, back), as yaw, pitch
// and roll. Looking straight up or down, where yaw and roll turn about one axis, roll is
// 0 and yaw takes it all.
orbit_set_rotation :: proc(c: ^Orbit, m: matrix[3, 3]f32) {
	sp := clamp(m[1, 2], -1, 1)
	c.pitch = math.asin(sp)
	if math.sqrt(m[0, 2] * m[0, 2] + m[2, 2] * m[2, 2]) > 1e-5 {
		c.yaw = math.atan2(m[0, 2], m[2, 2])
		c.roll = math.atan2(m[1, 0], m[1, 1])
	} else {
		c.yaw = math.atan2(-m[2, 0], m[0, 0])
		c.roll = 0
	}
}

// Turns the view to the nearest of the 24 views square to the axes, as ZBrush does while
// Shift is held during a rotation: front, side, top and so on, at a quarter turn of roll.
orbit_snap :: proc(c: ^Orbit) {
	_, up, back := orbit_basis(c^)
	b := nearest_axis(back, -1)
	u := nearest_axis(up, axis_of(b))
	r := linalg.cross(u, b)
	m := matrix[3, 3]f32{
		r.x, u.x, b.x,
		r.y, u.y, b.y,
		r.z, u.z, b.z,
	}
	orbit_set_rotation(c, m)

	axis_of :: proc(v: Vec3) -> int {
		for k in 0 ..< 3 do if v[k] != 0 do return k
		return 0
	}
	// The axis direction (+-X, +-Y or +-Z) closest to `v`, other than along `skip`.
	nearest_axis :: proc(v: Vec3, skip: int) -> Vec3 {
		best, at := f32(-1), 0
		for k in 0 ..< 3 {
			if k != skip && abs(v[k]) > best do best, at = abs(v[k]), k
		}
		out: Vec3
		out[at] = 1 if v[at] >= 0 else -1
		return out
	}
}

// `a` moved by whole turns to within half a turn of zero.
wrap_angle :: proc(a: f32) -> f32 {
	return a - 2 * math.PI * math.floor((a + math.PI) / (2 * math.PI))
}

// Moves the target in the view plane so the point under the cursor follows it.
orbit_pan :: proc(c: ^Orbit, delta: Vec2, viewport_height: f32) {
	if viewport_height <= 0 do return
	right, up, _ := orbit_basis(c^)
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

// Zooms `factor` times closer toward the point `offset` pixels from the viewport's
// middle (x right, y down; measured here from where the shift draws the target), keeping what is under it there, as pinching two fingers
// zooms toward the place between them (ZBrush's Center Navigation on Pinch). Only the
// target's plane is kept exactly; nearer and further points drift a little, as they do
// in ZBrush.
orbit_zoom_toward :: proc(c: ^Orbit, factor: f32, offset: Vec2, viewport_height: f32) {
	if factor <= 0 || viewport_height <= 0 do return
	from := offset - orbit_shift_px(c^, viewport_height)
	before := c.distance
	orbit_zoom_by(c, factor)
	right, up, _ := orbit_basis(c^)
	per_pixel_change := 2 * (before - c.distance) * math.tan(c.fov_y / 2) / viewport_height
	c.target += (right * from.x - up * from.y) * per_pixel_change
}

// Moves the target along the view to `depth` in front of the eye, keeping the eye and
// everything on screen where they are, so a zoom or roll about a point (orbit_zoom_toward,
// orbit_roll_about) keeps the plane at that depth exactly: a pinch over the model then
// holds the surface between the fingers rather than the target's plane behind it, and
// zooms in toward that surface at its own pace, as ZBrush, Nomad and Procreate do. A
// parallel view, whose width is the distance, keeps every depth anyway and is left alone.
orbit_rebase :: proc(c: ^Orbit, depth: f32) {
	if c.ortho || depth <= 0 do return
	_, _, back := orbit_basis(c^)
	eye := orbit_eye(c^)
	c.distance = clamp(depth, MIN_DISTANCE, MAX_DISTANCE)
	c.target = eye - back * c.distance
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
	right, up, _ := orbit_basis(c)
	// About up by +x turns the viewer's direction toward right; about right by +y
	// turns it toward -up, the bottom of the screen.
	return linalg.matrix3_rotate(angles.x, up) * linalg.matrix3_rotate(angles.y, right)
}

// The most a pen's lean turns the brush, in radians.
MAX_TILT :: math.PI / 2 * 0.9

// The view matrix: rows are the camera's right, up and back, so it looks down -Z.
orbit_view :: proc(c: Orbit) -> Mat4 {
	right, up, back := orbit_basis(c)
	eye := c.target + c.distance * back
	return Mat4{
		right.x, right.y, right.z, -linalg.dot(right, eye),
		up.x, up.y, up.z, -linalg.dot(up, eye),
		back.x, back.y, back.z, -linalg.dot(back, eye),
		0, 0, 0, 1,
	}
}

orbit_proj :: proc(c: Orbit, aspect: f32) -> Mat4 {
	p: Mat4
	if c.ortho {
		// Depth reaches as far behind the eye as in front of it, so zooming in (moving
		// the eye toward the target) never cuts into what is drawn.
		p = orthographic(c.distance * math.tan(c.fov_y / 2), aspect, -c.far, c.far)
	} else {
		p = perspective(c.fov_y, aspect, c.near, c.far)
	}
	if c.shift == {} do return p
	// The shift moves the whole picture across the screen: a translation in clip space by
	// w, which keeps every depth and every line straight.
	sx, sy := c.shift.x / max(aspect, 1e-6), c.shift.y
	move := Mat4{
		1, 0, 0, sx,
		0, 1, 0, sy,
		0, 0, 1, 0,
		0, 0, 0, 1,
	}
	return move * p
}

// The shift in pixels from the viewport's middle (x right, y down), for a viewport
// `viewport_height` pixels tall: where the target is drawn.
orbit_shift_px :: proc(c: Orbit, viewport_height: f32) -> Vec2 {
	return {c.shift.x, -c.shift.y} * viewport_height * 0.5
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

// Sets the field of view to `fov_y` (clamped to FOV_MIN..FOV_MAX), moving the eye along
// its line so the target's plane spans as much of the view as before: the model keeps its
// size on screen while the perspective strengthens or flattens, and an orthographic view,
// which is as wide as that plane, does not change at all.
orbit_set_fov :: proc(c: ^Orbit, fov_y: f32) {
	fov := clamp(fov_y, FOV_MIN, FOV_MAX)
	c.distance = clamp(c.distance * math.tan(c.fov_y / 2) / math.tan(fov / 2), MIN_DISTANCE, MAX_DISTANCE)
	c.fov_y = fov
}

// The camera reflected in the X symmetry plane (x = 0): it sees the other side of a
// symmetric model from the matching place, the right cheek where `c` sees the left, so
// the two sides can be compared side by side. Reflecting twice gives `c` back.
orbit_mirror_x :: proc(c: Orbit) -> Orbit {
	m := c
	m.target.x = -c.target.x
	m.yaw, m.roll = -c.yaw, -c.roll
	return m
}

// The six views along the axes, as Blender's numpad keys give them.
Axis_View :: enum {
	Front,  // from +Z, looking down -Z
	Back,   // from -Z
	Right,  // from +X
	Left,   // from -X
	Top,    // from +Y, straight down, -Z at the top of the screen
	Bottom, // from -Y
}

// Turns the camera to look at its target from along an axis, keeping target and
// distance and levelling the roll.
orbit_axis_view :: proc(c: ^Orbit, view: Axis_View) {
	c.roll = 0
	switch view {
	case .Front:  c.yaw, c.pitch = 0, 0
	case .Back:   c.yaw, c.pitch = math.PI, 0
	case .Right:  c.yaw, c.pitch = math.PI / 2, 0
	case .Left:   c.yaw, c.pitch = -math.PI / 2, 0
	case .Top:    c.yaw, c.pitch = 0, math.PI / 2
	case .Bottom: c.yaw, c.pitch = 0, -math.PI / 2
	}
}

// The cosine of half a degree: how far from straight up the screen the world's up may lean
// in a view still taken as level.
LEVEL_COS :: 0.99996192

// Whether `c` is a level parallel view: orthographic, with the world's up straight up the
// screen within half a degree, so every level plane shows as a level line across it (the
// side views, and a linked or mirrored view of one). The proportion guides draw in these.
orbit_is_level :: proc(c: Orbit) -> bool {
	if !c.ortho do return false
	_, up, _ := orbit_basis(c)
	return up.y >= LEVEL_COS
}

// Where the level plane at world height `y` crosses level view `c`, as a share of the
// view's height from its top (0 the top edge, 1 the bottom); outside 0 to 1 it is off the
// view. The view's middle is at the target's height, and half its height spans the
// orthographic half height.
orbit_level_frac :: proc(c: Orbit, y: f32) -> f32 {
	half := max(c.distance * math.tan(c.fov_y / 2), 1e-6)
	return 0.5 - (y - c.target.y) / (2 * half)
}

// The world height at share `frac` of level view `c`'s height from its top: the inverse
// of orbit_level_frac, for a guide dragged to the pointer.
orbit_level_height :: proc(c: Orbit, frac: f32) -> f32 {
	half := max(c.distance * math.tan(c.fov_y / 2), 1e-6)
	return c.target.y + (0.5 - frac) * 2 * half
}
