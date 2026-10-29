package gizmo

import "core:math"
import "core:math/linalg"
import "core:testing"

@(test)
axis_drag_follows_ray :: proc(t: ^testing.T) {
	// A ray straight down through x = 2.5 hits the X axis at s = 2.5.
	s, ok := closest_on_axis({0, 0, 0}, {1, 0, 0}, {2.5, 5, 0}, {0, -1, 0})
	testing.expect(t, ok)
	testing.expect(t, math.abs(s - 2.5) < 1e-5)

	// A slanted ray that meets the axis (through x = 1) at z = 5.
	s, ok = closest_on_axis({1, 0, 0}, {0, 0, 1}, {1, 3, 1}, {0, -0.6, 0.8})
	testing.expect(t, ok)
	testing.expect(t, math.abs(s - 5) < 1e-4)
	s, ok = closest_on_axis({1, 0, 0}, {0, 0, 1}, {1, 3, 4}, {0, -1, 0})
	testing.expect(t, ok)
	testing.expect(t, math.abs(s - 4) < 1e-5)
	_, ok = closest_on_axis({0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {1, 0, 0})
	testing.expect(t, !ok, "a ray parallel to the axis cannot drag along it")
}

@(test)
plane_hit :: proc(t: ^testing.T) {
	hit, ok := ray_plane({0, 0, 5}, {0, 0, -1}, {0, 0, 1}, {0, 0, 1})
	testing.expect(t, ok)
	testing.expect_value(t, hit, Vec3{0, 0, 1})
	_, ok = ray_plane({0, 0, 5}, {0, 0, 1}, {0, 0, 1}, {0, 0, 1})
	testing.expect(t, !ok, "plane behind the ray")
}

@(test)
picking :: proc(t: ^testing.T) {
	s := Screen{center = {100, 100}, tips = {{190, 100}, {100, 10}, {40, 160}}, tip_ok = {true, true, true}, arm_px = 90, ok = true}
	testing.expect_value(t, pick(s, .Move, {102, 97}, PICK_PX), Handle.View)
	testing.expect_value(t, pick(s, .Move, {150, 104}, PICK_PX), Handle.X)
	testing.expect_value(t, pick(s, .Move, {97, 50}, PICK_PX), Handle.Y)
	testing.expect_value(t, pick(s, .Move, {70, 131}, PICK_PX), Handle.Z)
	testing.expect_value(t, pick(s, .Move, {160, 160}, PICK_PX), Handle.None)
	// Between the X and Y arms, the square that moves in their plane.
	testing.expect_value(t, pick(s, .Move, {135, 65}, PICK_PX), Handle.XY)
	// A finger's radius reaches the arm from further off, and grows the centre.
	testing.expect_value(t, pick(s, .Move, {150, 118}, PICK_PX), Handle.None)
	testing.expect_value(t, pick(s, .Move, {150, 118}, 24), Handle.X)
	testing.expect_value(t, pick(s, .Move, {112, 88}, PICK_PX), Handle.None)
	testing.expect_value(t, pick(s, .Move, {112, 88}, 24), Handle.View)
	// Scale: the disc in the middle and the circle at the arm's length.
	testing.expect_value(t, pick(s, .Scale, {105, 104}, PICK_PX), Handle.Scale)
	testing.expect_value(t, pick(s, .Scale, {100, 194}, PICK_PX), Handle.Scale)
	testing.expect_value(t, pick(s, .Scale, {100, 150}, PICK_PX), Handle.None)
	// Drawn twice as large (the interface at 200%), the disc picks twice as far.
	testing.expect_value(t, pick(s, .Scale, {120, 100}, PICK_PX), Handle.None)
	big := s
	big.arm_px = 2 * ARM_PX
	testing.expect_value(t, pick(big, .Scale, {120, 100}, 2 * PICK_PX), Handle.Scale)
	s.tip_ok.x = false
	testing.expect_value(t, pick(s, .Move, {150, 104}, PICK_PX), Handle.None)
	testing.expect_value(t, pick(s, .Move, {135, 65}, PICK_PX), Handle.None)
	s.ok = false
	testing.expect_value(t, pick(s, .Move, {102, 97}, PICK_PX), Handle.None)
}

@(test)
projection_round_trip :: proc(t: ^testing.T) {
	// Identity view-projection: NDC (0, 0) is the viewport centre, +y is up.
	identity := Mat4(1)
	p, ok := project(identity, {0, 0, 0.5}, {200, 100})
	testing.expect(t, ok)
	testing.expect_value(t, p, Vec2{100, 50})
	p, _ = project(identity, {1, 1, 0.5}, {200, 100})
	testing.expect_value(t, p, Vec2{200, 0})
}

// rotation_degrees undoes rotation_matrix across the whole range, the gimbal poles too
// (where the turn, not the angles, must come back).
@(test)
rotation_round_trip :: proc(t: ^testing.T) {
	for x := f32(-180); x < 180; x += 30 {
		for y := f32(-90); y <= 90; y += 15 {
			for z := f32(-180); z < 180; z += 45 {
				m := rotation_matrix({x, y, z})
				back := rotation_matrix(rotation_degrees(m))
				worst: f32
				for i in 0 ..< 3 do for j in 0 ..< 3 do worst = max(worst, abs(back[i, j] - m[i, j]))
				testing.expectf(t, worst < 1e-4, "%v comes back %v off", Vec3{x, y, z}, worst)
				d := rotation_degrees(m)
				testing.expectf(t, d.y >= -90 && d.y <= 90 && abs(d.x) <= 180 && abs(d.z) <= 180, "%v out of range", d)
			}
		}
	}
	testing.expect_value(t, rotation_degrees(1), Vec3{})
}

// A quarter turn about z takes x onto y; the edge-on drag follows the ring's direction.
@(test)
turns_and_scales :: proc(t: ^testing.T) {
	a := plane_turn({0, 0, 0}, {0, 0, 1}, {1, 0, 0}, {0, 2, 0})
	testing.expect(t, abs(a - math.PI / 2) < 1e-5)
	testing.expect(t, abs(plane_turn({0, 0, 0}, {0, 0, -1}, {1, 0, 0}, {0, 2, 0}) + math.PI / 2) < 1e-5)
	testing.expect(t, abs(tangent_turn({30, 0}, {60, 0}) - 0.5) < 1e-6)
	testing.expect_value(t, tangent_turn({30, 0}, {0, 0}), 0)
	// An arm's length further out scales by e, and as far back in undoes it, from
	// wherever the press was.
	testing.expect(t, abs(scale_factor({0, 0}, {10, 0}, {0, 100}, 90) - math.E) < 1e-5)
	testing.expect(t, abs(scale_factor({0, 0}, {0, 0}, {90, 0}, 90) - math.E) < 1e-5)
	testing.expect_value(t, scale_factor({0, 0}, {30, 0}, {0, 30}, 90), 1)
	testing.expect_value(t, wrap_degrees(190), -170)
	testing.expect_value(t, wrap_degrees(-180), -180)
	testing.expect_value(t, wrap_degrees(180), -180)
	testing.expect_value(t, wrap_degrees(-725), -5)
	testing.expect_value(t, snap(0.26, 0.1), f32(0.3))
	testing.expect_value(t, snap(37, TURN_SNAP_DEGREES), f32(30))
	testing.expect_value(t, snap(5, 0), f32(5))
	testing.expect_value(t, grid_step(0.01), f32(0.1))  // half an arm is 0.45
	testing.expect_value(t, grid_step(0.001), f32(0.01))
}

// A ring projects to a circle on a straight-on view and is picked by its line; a plane
// square holds its middle and not the centre.
@(test)
rings_and_squares_pick :: proc(t: ^testing.T) {
	// Orthographic-like: x and y map straight onto the screen, 100 px a unit.
	vp := Mat4{
		0.1, 0, 0, 0,
		0, 0.1, 0, 0,
		0, 0, 0.1, 0,
		0, 0, 0, 1,
	}
	pts, front, ok := ring(vp, {0, 0, 0}, {0, 0, 1}, 2, {0, 0, 1}, {1000, 1000})
	testing.expect(t, ok)
	for p in pts do testing.expect(t, abs(linalg.length(p - Vec2{500, 500}) - 100) < 0.01)
	for f in front do testing.expect(t, f)
	testing.expect(t, ring_distance({600, 500}, pts[:]) < 0.5)
	testing.expect(t, ring_distance({500, 500}, pts[:]) > 99)
	// At the ring's right, a turn about +z (toward the eye) runs up the screen, 100 px a
	// radian: a drag upward turns it the positive way.
	tangent := ring_tangent(pts[:], {601, 500})
	testing.expect(t, abs(tangent.x) < 1 && abs(tangent.y + 100) < 0.5)
	testing.expect(t, abs(tangent_turn({0, -50}, tangent) - 0.5) < 0.01)
	// The gizmo seen straight down z: the z ring is a circle, the view ring outside it,
	// and the x and y rings lines through the centre.
	sc := screen(vp, {0, 0, 0}, 2, {0, 0, 1}, {1000, 1000}, 100)
	testing.expect(t, sc.ok && sc.ring_ok == {true, true, true, true})
	testing.expect_value(t, pick(sc, .Turn, {600, 502}, PICK_PX), Handle.Turn_Z)
	testing.expect_value(t, pick(sc, .Turn, {625, 500}, PICK_PX), Handle.Turn_View)
	testing.expect_value(t, pick(sc, .Turn, {503, 560}, PICK_PX), Handle.Turn_X)
	testing.expect_value(t, pick(sc, .Turn, {640, 420}, PICK_PX), Handle.None)
	// The z arm points at the eye: neither it nor the squares beside it can be picked.
	testing.expect(t, !arm_shows(sc, 2))
	_, xy := square_of(sc, 2)
	_, yz := square_of(sc, 0)
	testing.expect(t, xy && !yz)
	q := plane_square({0, 0}, {100, 0}, {0, -100})
	testing.expect(t, inside_quad({38, -38}, q))
	testing.expect(t, !inside_quad({0, 0}, q))
	testing.expect(t, !inside_quad({90, -90}, q))
}

// The All mode seen straight down z: the arrows run on past the rings, the knobs on the
// arms scale, and where an edge-on ring lies along an arm the arm wins; the rings, the
// plane square and the middle pick as in their own modes.
@(test)
all_mode_picks_every_handle :: proc(t: ^testing.T) {
	vp := Mat4{
		0.1, 0, 0, 0,
		0, 0.1, 0, 0,
		0, 0, 0.1, 0,
		0, 0, 0, 1,
	}
	sc := screen(vp, {0, 0, 0}, 2, {0, 0, 1}, {1000, 1000}, 100, .All)
	testing.expect(t, sc.ok)
	testing.expect(t, abs(sc.ends[0].x - 635) < 0.01 && abs(sc.knobs[0].x - 562) < 0.01)
	// The z ring is smaller than in the Turn mode, and the view ring a quarter outside it.
	testing.expect(t, abs(linalg.length(sc.rings[2][0] - sc.center) - 85) < 0.01)
	testing.expect(t, abs(linalg.length(sc.rings[3][0] - sc.center) - 106.25) < 0.01)
	testing.expect_value(t, pick(sc, .All, {502, 498}, PICK_PX), Handle.View)
	testing.expect_value(t, pick(sc, .All, {625, 503}, PICK_PX), Handle.X)
	testing.expect_value(t, pick(sc, .All, {530, 501}, PICK_PX), Handle.X)
	testing.expect_value(t, pick(sc, .All, {501, 380}, PICK_PX), Handle.Y)
	testing.expect_value(t, pick(sc, .All, {565, 502}, PICK_PX), Handle.Scale)
	testing.expect_value(t, pick(sc, .All, {500, 438}, PICK_PX), Handle.Scale)
	testing.expect_value(t, pick(sc, .All, {560, 560}, PICK_PX), Handle.Turn_Z)
	testing.expect_value(t, pick(sc, .All, {575, 575}, PICK_PX), Handle.Turn_View)
	testing.expect_value(t, pick(sc, .All, {500, 570}, PICK_PX), Handle.Turn_X)
	testing.expect_value(t, pick(sc, .All, {538, 462}, PICK_PX), Handle.XY)
	testing.expect_value(t, pick(sc, .All, {680, 680}, PICK_PX), Handle.None)
	// A finger's radius grows the knob as it grows the middle.
	testing.expect_value(t, pick(sc, .All, {562, 517}, PICK_PX), Handle.None)
	testing.expect_value(t, pick(sc, .All, {562, 517}, 24), Handle.Scale)
	// The z arm points at the eye: no arrow, no knob.
	testing.expect(t, !all_arm_shows(sc, 2))
	// The other modes have no arrows or knobs.
	plain := screen(vp, {0, 0, 0}, 2, {0, 0, 1}, {1000, 1000}, 100)
	testing.expect(t, !all_arm_shows(plain, 0))
}
