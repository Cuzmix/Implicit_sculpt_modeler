package gizmo

import "core:math"
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
	center := Vec2{100, 100}
	tips := [3]Vec2{{190, 100}, {100, 10}, {40, 160}}
	ok := [3]bool{true, true, true}
	testing.expect_value(t, pick({102, 97}, center, tips, ok), Handle.View)
	testing.expect_value(t, pick({150, 104}, center, tips, ok), Handle.X)
	testing.expect_value(t, pick({97, 50}, center, tips, ok), Handle.Y)
	testing.expect_value(t, pick({70, 131}, center, tips, ok), Handle.Z)
	testing.expect_value(t, pick({160, 160}, center, tips, ok), Handle.None)
	ok.x = false
	testing.expect_value(t, pick({150, 104}, center, tips, ok), Handle.None)
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
