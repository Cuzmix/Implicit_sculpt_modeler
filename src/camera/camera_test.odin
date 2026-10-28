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
rotate_keeps_distance_and_a_limited_turntable_stops_at_the_poles :: proc(t: ^testing.T) {
	for style in Orbit_Style {
		c := orbit_default()
		orbit_rotate(&c, {120, 10000}, {style = style, speed = ORBIT_SPEED})
		testing.expect(t, near_eq(linalg.length(orbit_eye(c) - c.target), c.distance), "eye left the orbit sphere")
	}
	c := orbit_default()
	orbit_rotate(&c, {120, 10000}, {style = .Turntable, limit_pitch = true, speed = ORBIT_SPEED})
	testing.expect_value(t, c.pitch, PITCH_LIMIT)
}

// Where the eye is after each of `steps` drags of `delta`, for checking a long orbit
// moves smoothly: no step may move the eye further than one drag can.
@(private = "file")
orbit_path_is_smooth :: proc(t: ^testing.T, s: Orbit_Settings, delta: Vec2, steps: int) -> Orbit {
	c := orbit_default()
	step := linalg.length(delta) * s.speed * c.distance // the arc one drag moves the eye
	// A single-axis style's two turns are about axes that need not be square to each other,
	// so a diagonal drag may move the eye as far as both parts in a line.
	if s.style == .Axis_X || s.style == .Axis_Z do step = (abs(delta.x) + abs(delta.y)) * s.speed * c.distance
	prev_eye := orbit_eye(c)
	_, prev_up, _ := orbit_basis(c)
	for _ in 0 ..< steps {
		orbit_rotate(&c, delta, s)
		eye := orbit_eye(c)
		_, up, _ := orbit_basis(c)
		testing.expectf(t, linalg.length(eye - prev_eye) <= step * 1.01 + 1e-4, "%v %v: the eye jumped %v (one drag moves it %v)", s.style, delta, linalg.length(eye - prev_eye), step)
		// The screen's up turns smoothly too: no flip at a pole or at the wrap.
		testing.expectf(t, linalg.dot(up, prev_up) > math.cos(2 * linalg.length(delta) * s.speed) - 1e-4, "%v %v: the view flipped", s.style, delta)
		testing.expect(t, abs(c.yaw) <= math.PI + 1e-5 && abs(c.pitch) <= math.PI + 1e-5 && abs(c.roll) <= math.PI + 1e-5, "angles left their turn")
		prev_eye, prev_up = eye, up
	}
	return c
}

@(test)
orbits_go_round_and_round_both_ways_without_jumps :: proc(t: ^testing.T) {
	// 3 full turns of 80 drags of 10 pixels each, sideways and up and down, both ways,
	// both styles; the speed (near the default's) makes a turn a whole number of drags.
	per_turn := 80
	speed := f32(2 * math.PI / f64(10 * per_turn))
	for style in Orbit_Style {
		s := Orbit_Settings{style = style, speed = speed}
		for delta in ([4]Vec2{{10, 0}, {-10, 0}, {0, 10}, {0, -10}}) {
			start := orbit_default()
			c := orbit_path_is_smooth(t, s, delta, 3 * per_turn)
			// Three whole turns come back to where they began, give or take the rounding
			// of the turn into whole drags.
			testing.expectf(t, linalg.length(orbit_eye(c) - orbit_eye(start)) < 0.05 * c.distance, "%v %v: did not come round (%v)", style, delta, orbit_eye(c))
		}
		// A diagonal drag never jumps either.
		_ = orbit_path_is_smooth(t, s, {7, 7}, 2 * per_turn)
	}
}

@(test)
a_turntable_goes_over_the_top_keeping_the_model_under_the_pointer :: proc(t: ^testing.T) {
	s := Orbit_Settings{style = .Turntable, speed = ORBIT_SPEED}
	c := orbit_default()
	c.yaw, c.pitch = 0, 0
	// Over the top: pitch past a quarter turn looks from behind, upside down.
	orbit_rotate(&c, {0, 0.75 * math.PI / ORBIT_SPEED}, s)
	_, up, back := orbit_basis(c)
	testing.expect(t, up.y < 0 && back.z < 0, "not upside down behind the model")
	// Upside down, a drag right still moves the side facing the viewer right: the point
	// in front of the target goes right on screen.
	q := c.target + linalg.normalize(Vec3{back.x, 0, back.z}) * 0.5
	before := project(orbit_proj(c, 1) * orbit_view(c), q)
	orbit_rotate(&c, {20, 0}, s)
	after := project(orbit_proj(c, 1) * orbit_view(c), q)
	testing.expect(t, after.x > before.x, "upside down, a drag right turned the model left")
}

@(test)
free_rotation_turns_about_the_screens_axes :: proc(t: ^testing.T) {
	s := Orbit_Settings{style = .Free, speed = ORBIT_SPEED}
	c := orbit_default()
	c.yaw, c.pitch, c.roll = 0.3, 0.4, 0.5
	_, up, back := orbit_basis(c)
	// A sideways drag turns about the screen's up: up stays put.
	orbit_rotate(&c, {50, 0}, s)
	r2, u2, b2 := orbit_basis(c)
	testing.expect(t, linalg.dot(u2, up) > 0.9999, "a sideways drag moved the screen's up")
	testing.expect(t, linalg.dot(b2, back) < 0.99, "a sideways drag did not turn")
	// An up and down drag turns about the screen's right: right stays put.
	orbit_rotate(&c, {0, 50}, s)
	r3, _, _ := orbit_basis(c)
	testing.expect(t, linalg.dot(r3, r2) > 0.9999, "an up and down drag moved the screen's right")
	// The angles rebuild the same turn they were set from.
	m := orbit_rotation(c)
	d := c
	orbit_set_rotation(&d, m)
	m2 := orbit_rotation(d)
	for i in 0 ..< 3 do for j in 0 ..< 3 do testing.expect(t, near_eq(m[i, j], m2[i, j]), "angles do not round trip")
	// Straight down, where yaw and roll are one turn, they still do.
	d.yaw, d.pitch, d.roll = 0.7, math.PI / 2, 0.2
	m = orbit_rotation(d)
	orbit_set_rotation(&d, m)
	m2 = orbit_rotation(d)
	for i in 0 ..< 3 do for j in 0 ..< 3 do testing.expect(t, near_eq(m[i, j], m2[i, j], 1e-3), "angles do not round trip at the pole")
}

@(test)
turning_about_a_pivot_keeps_it_on_screen :: proc(t: ^testing.T) {
	// A point off the middle of the screen and nearer than the target, as the last stroke
	// on the near side of a model is.
	for style in Orbit_Style {
		for ortho in ([2]bool{false, true}) {
			for delta in ([4]Vec2{{12, 0}, {-12, 0}, {0, 9}, {7, -11}}) {
				c := orbit_default()
				c.ortho = ortho
				right, up, back := orbit_basis(c)
				pivot := c.target + right * 0.6 - up * 0.3 + back * 0.8
				want := project(orbit_proj(c, 1.5) * orbit_view(c), pivot)
				s := Orbit_Settings{style = style, speed = ORBIT_SPEED}
				// A turn and a half or so, both ways round, over the top in Free.
				for _ in 0 ..< 600 {
					before := c
					orbit_rotate(&c, delta, s)
					orbit_turn_about(&c, before, pivot)
				}
				got := project(orbit_proj(c, 1.5) * orbit_view(c), pivot)
				testing.expectf(t, near_eq(got.x, want.x, 1e-3) && near_eq(got.y, want.y, 1e-3) && near_eq(got.z, want.z, 1e-3), "%v ortho=%v %v: the pivot moved on screen from %v to %v", style, ortho, delta, want, got)
				testing.expect(t, near_eq(c.distance, orbit_default().distance), "turning about a pivot changed the distance")
				testing.expect(t, c.target != orbit_default().target, "the target did not move")
			}
		}
	}
}

@(test)
turning_about_the_target_moves_nothing_else :: proc(t: ^testing.T) {
	c := orbit_default()
	c.target = {1, 2, 3}
	plain := c
	before := c
	orbit_rotate(&c, {40, -25}, ORBIT_DEFAULT)
	orbit_turn_about(&c, before, before.target)
	orbit_rotate(&plain, {40, -25}, ORBIT_DEFAULT)
	testing.expect(t, c == plain, "turning about the target is not plain orbit_rotate")
}

@(test)
snapping_about_a_pivot_keeps_it_on_screen :: proc(t: ^testing.T) {
	c := orbit_default()
	c.yaw, c.pitch, c.roll = 0.2, 0.3, -0.25
	pivot := Vec3{0.4, -0.2, 0.7}
	want := project(orbit_proj(c, 1) * orbit_view(c), pivot)
	before := c
	orbit_snap(&c)
	orbit_turn_about(&c, before, pivot)
	got := project(orbit_proj(c, 1) * orbit_view(c), pivot)
	testing.expectf(t, near_eq(got.x, want.x) && near_eq(got.y, want.y), "the pivot moved on screen from %v to %v", want, got)
	_, _, back := orbit_basis(c)
	testing.expect(t, near_eq(back.z, 1), "did not snap to the front view")
}

@(test)
snap_turns_to_the_nearest_square_view :: proc(t: ^testing.T) {
	c := orbit_default()
	c.yaw, c.pitch, c.roll = 0.2, 0.3, -0.25
	orbit_snap(&c)
	right, up, back := orbit_basis(c)
	testing.expect(t, near_eq(back.z, 1) && near_eq(up.y, 1) && near_eq(right.x, 1), "did not snap to the front view")
	c.yaw, c.pitch, c.roll = math.PI / 2 + 0.3, 1.2, 0
	orbit_snap(&c)
	_, up, back = orbit_basis(c)
	testing.expect(t, near_eq(back.y, 1), "did not snap to the top view")
	testing.expect(t, near_eq(abs(up.x) + abs(up.z), 1), "the top view's up is not along an axis")
}

@(test)
roll_turns_the_screen_clockwise :: proc(t: ^testing.T) {
	c := orbit_default()
	right, _, _ := orbit_basis(c)
	p := c.target + right * 0.5 // right of the middle on screen
	before := project(orbit_proj(c, 1) * orbit_view(c), p)
	orbit_roll(&c, 0.3)
	after := project(orbit_proj(c, 1) * orbit_view(c), p)
	// Clockwise on screen: a point right of the middle goes down (NDC y is up).
	testing.expect(t, after.y < before.y - 0.01, "roll did not turn the screen clockwise")
	testing.expect(t, near_eq(linalg.length(orbit_eye(c) - c.target), c.distance), "roll moved the eye")
}

@(test)
zoom_toward_keeps_the_point_between_the_fingers :: proc(t: ^testing.T) {
	c := orbit_default()
	height: f32 = 800
	right, up, _ := orbit_basis(c)
	offset := Vec2{200, -100} // right of and above the middle, in pixels
	wpp := 2 * c.distance * math.tan(c.fov_y / 2) / height
	p := c.target + (right * offset.x - up * offset.y) * wpp // on the target's plane
	before := project(orbit_proj(c, 1) * orbit_view(c), p)
	orbit_zoom_toward(&c, 2, offset, height)
	after := project(orbit_proj(c, 1) * orbit_view(c), p)
	testing.expect(t, near_eq(before.x, after.x, 1e-4) && near_eq(before.y, after.y, 1e-4), "the point under the fingers moved")
	testing.expect(t, near_eq(c.distance, orbit_default().distance / 2), "did not zoom")
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

@(test)
pinch_zoom_moves_the_eye_by_the_spread :: proc(t: ^testing.T) {
	c := orbit_default()
	start := c.distance
	orbit_zoom_by(&c, 2)
	testing.expect(t, near_eq(c.distance, start / 2), "spreading twice as far should halve the distance")
	orbit_zoom_by(&c, 0.5)
	testing.expect(t, near_eq(c.distance, start), "pinching back should restore it")
	orbit_zoom_by(&c, 0)
	testing.expect(t, near_eq(c.distance, start), "a zero factor is ignored")
	orbit_zoom_by(&c, 1e9)
	testing.expect_value(t, c.distance, MIN_DISTANCE)
}

// A single-axis style turns sideways about its world axis, which keeps how the view's
// directions lie along that axis, and up and down as Free does; the sign decided at the
// press holds through a view whose up is square to the axis, where the view's own sign
// would flip with a wobble.
@(test)
single_axis_styles_turn_about_their_axis :: proc(t: ^testing.T) {
	for style in ([2]Orbit_Style{.Axis_X, .Axis_Z}) {
		axis := orbit_style_axis(style)
		c := orbit_default()
		_, up0, back0 := orbit_basis(c)
		s := Orbit_Settings{style = style, speed = ORBIT_SPEED, axis_sign = orbit_axis_sign(c, style)}
		for _ in 0 ..< 50 do orbit_rotate(&c, {13, 0}, s)
		_, up, back := orbit_basis(c)
		testing.expectf(t, near_eq(linalg.dot(back, axis), linalg.dot(back0, axis), 1e-3) && near_eq(linalg.dot(up, axis), linalg.dot(up0, axis), 1e-3), "%v: the view's lie along the axis changed", style)
		testing.expectf(t, linalg.length(orbit_eye(c) - orbit_eye(orbit_default())) > 0.5, "%v: a sideways drag did not turn the view", style)
		// Up and down is Free's.
		a, b := orbit_default(), orbit_default()
		orbit_rotate(&a, {0, 40}, s)
		orbit_rotate(&b, {0, 40}, {style = .Free, speed = ORBIT_SPEED})
		testing.expectf(t, linalg.length(orbit_eye(a) - orbit_eye(b)) < 1e-3, "%v: up and down differs from Free", style)
	}
	// Looking at the front, Z's axis points at the viewer and the up is square to it: the
	// view's sign comes from where it looks, and a latched sign keeps a drag turning one
	// way across a wobble through that up.
	c := orbit_default()
	c.yaw, c.pitch, c.roll = 0, 0, 0
	sign := orbit_axis_sign(c, .Axis_Z)
	testing.expect_value(t, sign, 1)
	s := Orbit_Settings{style = .Axis_Z, speed = ORBIT_SPEED, axis_sign = sign}
	before := c
	for k in 0 ..< 10 do orbit_rotate(&c, {10, 1 if k % 2 == 0 else -1}, s)
	right, _, _ := orbit_basis(c)
	r0, _, _ := orbit_basis(before)
	// Ten drags right roll the picture one way only: the right vector turned 100 drags' worth.
	testing.expectf(t, near_eq(linalg.dot(right, r0), math.cos(f32(100 * ORBIT_SPEED)), 2e-3), "the turn went back and forth: %v", linalg.dot(right, r0))
}

@(test)
fov_change_keeps_the_target_plane_the_same_width :: proc(t: ^testing.T) {
	c := orbit_default()
	wide := 2 * c.distance * math.tan(c.fov_y / 2)
	orbit_set_fov(&c, math.to_radians(f32(80)))
	testing.expect(t, near_eq(c.fov_y, math.to_radians(f32(80))))
	testing.expect(t, near_eq(2 * c.distance * math.tan(c.fov_y / 2), wide))
	// Wider than the range stops at its end, and the width still holds.
	orbit_set_fov(&c, math.PI)
	testing.expect(t, near_eq(c.fov_y, FOV_MAX))
	testing.expect(t, near_eq(2 * c.distance * math.tan(c.fov_y / 2), wide))
}

// Rolled any way, a turntable still turns about the world's up, and a drag moves the point
// in front of the target along the drag on screen: the model follows the pointer, up to
// the squash every turntable has away from the horizon, where a sideways drag turns the
// front less on screen than an up and down one (cos(pitch) as much).
@(test)
a_rolled_turntable_keeps_the_model_under_the_pointer :: proc(t: ^testing.T) {
	s := Orbit_Settings{style = .Turntable, speed = ORBIT_SPEED}
	for roll in ([]f32{0, 0.5, 1.6, 3.0, -2.2}) {
		for pitch in ([]f32{0.35, 2.4}) {
			for drag in ([]Vec2{{6, 0}, {0, 6}, {-4, 5}}) {
				c := orbit_default()
				c.pitch, c.roll = pitch, roll
				_, _, back := orbit_basis(c)
				q := c.target + back * 0.5
				before := project(orbit_proj(c, 1) * orbit_view(c), q)
				orbit_rotate(&c, drag, s)
				after := project(orbit_proj(c, 1) * orbit_view(c), q)
				moved := linalg.normalize(Vec2{after.x - before.x, after.y - before.y})
				// NDC's y is up, the drag's down.
				want := linalg.normalize(Vec2{drag.x, -drag.y})
				testing.expectf(t, linalg.dot(moved, want) > 0.98, "roll %v pitch %v drag %v moved the model along %v", roll, pitch, drag, moved)
				testing.expect(t, near_eq(c.roll, roll), "the turntable changed the roll")
			}
		}
	}
}

@(test)
roll_about_keeps_the_point_between_the_fingers :: proc(t: ^testing.T) {
	c := orbit_default()
	height: f32 = 800
	right, up, _ := orbit_basis(c)
	offset := Vec2{-150, 120} // left of and below the middle, in pixels
	wpp := 2 * c.distance * math.tan(c.fov_y / 2) / height
	p := c.target + (right * offset.x - up * offset.y) * wpp // on the target's plane
	before := project(orbit_proj(c, 1) * orbit_view(c), p)
	orbit_roll_about(&c, 0.7, offset, height)
	after := project(orbit_proj(c, 1) * orbit_view(c), p)
	testing.expect(t, near_eq(before.x, after.x, 1e-4) && near_eq(before.y, after.y, 1e-4), "the point under the fingers moved")
	testing.expect(t, near_eq(c.roll, 0.7), "did not roll")
	testing.expect(t, near_eq(c.distance, orbit_default().distance), "rolling zoomed")
}

@(test)
the_mirror_sees_the_other_side :: proc(t: ^testing.T) {
	c := Orbit{target = {0.3, 0.1, -0.2}, distance = 4, yaw = 0.7, pitch = 0.4, roll = 0.2, fov_y = 0.7, near = 0.01, far = 100}
	m := orbit_mirror_x(c)
	e, me := orbit_eye(c), orbit_eye(m)
	testing.expect(t, linalg.length(me - Vec3{-e.x, e.y, e.z}) < 1e-4, "the mirrored eye is not the eye reflected in x = 0")
	// Its right is the reflection of the camera's left, so the picture is the other side, not a flipped copy.
	r, u, _ := orbit_basis(c)
	mr, mu, _ := orbit_basis(m)
	testing.expect(t, linalg.length(mr - Vec3{r.x, -r.y, -r.z}) < 1e-4, "the mirrored right is not the reflected left")
	testing.expect(t, linalg.length(mu - Vec3{-u.x, u.y, u.z}) < 1e-4, "the mirrored up is not the reflected up")
	testing.expect_value(t, orbit_mirror_x(m), c)
}

@(test)
a_level_plane_lands_where_the_view_projects_it :: proc(t: ^testing.T) {
	c := Orbit{target = {0.2, 0.4, -0.1}, distance = 3, fov_y = 0.7, near = 0.01, far = 100, ortho = true}
	orbit_axis_view(&c, .Right)
	testing.expect(t, orbit_is_level(c), "the right view is not level")
	// A point at height 1.1 anywhere in the view projects to the share orbit_level_frac gives.
	y: f32 = 1.1
	clip := project(orbit_proj(c, 1.5) * orbit_view(c), {0.2, y, 0.6})
	frac := orbit_level_frac(c, y)
	testing.expect(t, near_eq(frac, 0.5 - clip.y * 0.5, 1e-4), "the guide is not where the view draws its height")
	testing.expect(t, near_eq(orbit_level_height(c, frac), y, 1e-4), "the height does not come back from its share")
	testing.expect(t, near_eq(orbit_level_frac(c, c.target.y), 0.5), "the target's height is not the middle")
	// A mirrored level view is level too; a tilted, rolled or perspective one is not.
	testing.expect(t, orbit_is_level(orbit_mirror_x(c)), "the mirror of a level view is not level")
	tilted, rolled, wide := c, c, c
	tilted.pitch, rolled.roll, wide.ortho = 0.02, 0.02, false
	testing.expect(t, !orbit_is_level(tilted) && !orbit_is_level(rolled) && !orbit_is_level(wide), "a tilted, rolled or perspective view counts as level")
	top := c
	orbit_axis_view(&top, .Top)
	testing.expect(t, !orbit_is_level(top), "the top view counts as level")
}
