package camera

import "core:math"
import "core:math/linalg"
import "core:testing"

near_eq :: proc(a, b: f32, eps: f32 = 1e-4) -> bool {
	return math.abs(a - b) < eps
}

project :: proc(m: Mat4, p: Vec3) -> Vec3 {
	h := m * [4]f32{p.x, p.y, p.z, 1}
	return h.xyz / h.w
}

@(test)
target_projects_to_screen_centre :: proc(t: ^testing.T) {
	c := orbit_default()
	c.target = {1, 2, 3}
	ndc := project(orbit_proj(c, 1.5) * orbit_view(c), c.target)
	testing.expect(t, near_eq(ndc.x, 0) && near_eq(ndc.y, 0), "target is off-centre")
	testing.expect(t, ndc.z > 0 && ndc.z < 1, "target outside depth range")
}

@(test)
depth_range_is_zero_to_one :: proc(t: ^testing.T) {
	p := perspective(math.to_radians(f32(60)), 1, 0.1, 10)
	testing.expect(t, near_eq(project(p, {0, 0, -0.1}).z, 0), "near plane should map to 0")
	testing.expect(t, near_eq(project(p, {0, 0, -10}).z, 1), "far plane should map to 1")
}

@(test)
rotate_keeps_distance_and_clamps_pitch :: proc(t: ^testing.T) {
	c := orbit_default()
	orbit_rotate(&c, {120, 10000})
	testing.expect(t, c.pitch <= PITCH_LIMIT, "pitch not clamped")
	testing.expect(t, near_eq(linalg.length(orbit_eye(c) - c.target), c.distance), "eye left the orbit sphere")
}

@(test)
pan_follows_cursor :: proc(t: ^testing.T) {
	c := orbit_default()
	height: f32 = 800
	before := project(orbit_proj(c, 1) * orbit_view(c), {})
	orbit_pan(&c, {100, 0}, height)
	after := project(orbit_proj(c, 1) * orbit_view(c), {})
	// Dragging right by 100 px moves the origin right on screen by 100 px (NDC spans 2 over the height).
	testing.expect(t, near_eq(after.x - before.x, 100 * 2 / height, 1e-3), "pan does not track the cursor")
}

@(test)
zoom_is_clamped :: proc(t: ^testing.T) {
	c := orbit_default()
	orbit_zoom(&c, 1000)
	testing.expect_value(t, c.distance, MIN_DISTANCE)
	orbit_zoom(&c, -10000)
	testing.expect_value(t, c.distance, MAX_DISTANCE)
}

@(test)
tilt_leans_the_brush_toward_the_pen_top :: proc(t: ^testing.T) {
	c := orbit_default()
	view := orbit_view(c)
	right := Vec3{view[0, 0], view[0, 1], view[0, 2]}
	up := Vec3{view[1, 0], view[1, 1], view[1, 2]}
	toward := linalg.normalize(orbit_eye(c) - c.target)
	none := orbit_tilt(c, {0, 0}, 1)
	testing.expect(t, none == linalg.MATRIX3F32_IDENTITY, "no lean, no turn")
	testing.expect(t, orbit_tilt(c, {40, -30}, 0) == linalg.MATRIX3F32_IDENTITY, "no strength, no turn")
	// 30 degrees to the right at full strength: the brush leans 30 degrees right.
	r := orbit_tilt(c, {30, 0}, 1) * toward
	testing.expect(t, near_eq(linalg.dot(r, right), math.sin(math.to_radians(f32(30)))), "x lean turns toward right")
	testing.expect(t, near_eq(linalg.dot(r, up), 0), "x lean stays level")
	// Toward the bottom of the screen at half strength: 20 degrees down.
	d := orbit_tilt(c, {0, 40}, 0.5) * toward
	testing.expect(t, near_eq(linalg.dot(d, up), -math.sin(math.to_radians(f32(20)))), "y lean turns toward the bottom")
	// A rotation, capped.
	m := orbit_tilt(c, {90, 90}, 1)
	testing.expect(t, near_eq(linalg.determinant(m), 1), "not a rotation")
	for v in ([3]Vec3{right, up, toward}) do testing.expect(t, near_eq(linalg.length(m * v), 1), "not a rotation")
	testing.expect(t, linalg.dot(m * toward, toward) >= math.cos(f32(MAX_TILT)) - 1e-4, "turned past MAX_TILT")
}

@(test)
axis_views_look_along_their_axes :: proc(t: ^testing.T) {
	want := [Axis_View]Vec3{.Front = {0, 0, 1}, .Back = {0, 0, -1}, .Right = {1, 0, 0}, .Left = {-1, 0, 0}, .Top = {0, 1, 0}, .Bottom = {0, -1, 0}}
	for dir, view in want {
		c := orbit_default()
		c.target = {1, 2, 3}
		orbit_axis_view(&c, view)
		got := linalg.normalize(orbit_eye(c) - c.target)
		testing.expectf(t, linalg.dot(got, dir) > 0.999, "%v: eye direction %v", view, got)
	}
}

@(test)
ortho_keeps_the_target_size_and_depth_range :: proc(t: ^testing.T) {
	c := orbit_default()
	c.target = {1, 2, 3}
	persp := orbit_proj(c, 1.5) * orbit_view(c)
	c.ortho = true
	ortho := orbit_proj(c, 1.5) * orbit_view(c)
	// A point beside the target lands on the same pixel in both, at the target's depth.
	view := orbit_view(c)
	up := Vec3{view[1, 0], view[1, 1], view[1, 2]}
	p := c.target + up * 0.4
	testing.expect(t, near_eq(project(persp, p).y, project(ortho, p).y), "ortho is not as wide at the target")
	z := project(ortho, c.target).z
	testing.expect(t, z > 0 && z < 1, "target outside depth range")
	// Behind the eye still draws.
	behind := orbit_eye(c) + (orbit_eye(c) - c.target)
	zb := project(ortho, behind).z
	testing.expect(t, zb >= 0 && zb < z, "behind the eye is clipped")
	testing.expect(t, near_eq(orbit_world_per_px(c, behind, 100), orbit_world_per_px(c, c.target, 100)), "ortho pixel size varies")
}
