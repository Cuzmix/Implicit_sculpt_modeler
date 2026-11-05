package main

import "core:math/linalg"
import "core:testing"

// The world map of a gizmo drag, seen in a placed cage's own space, takes a point where the
// world map takes its world place.
@(test)
a_selection_drag_maps_through_the_cages_place :: proc(t: ^testing.T) {
	place := Transform{position = {1, -2, 0.5}, scale = 2, rotation = {0, 30, 10}}
	pivot := Vec3{0.3, 0.1, -0.2}
	turn := linalg.matrix3_rotate_f32(linalg.to_radians(f32(40)), linalg.normalize(Vec3{1, 2, 0}))
	move := Vec3{0.2, -0.4, 0.7}
	a, b := cage_local_map(place, pivot, turn, move)
	for p in ([3]Vec3{{0, 0, 0}, {0.5, -0.25, 1}, {-1, 2, 0.3}}) {
		want := to_local(place, pivot + turn * (to_world(place, p) - pivot) + move)
		got := a * p + b
		testing.expectf(t, linalg.length(got - want) < 1e-4, "%v went to %v, want %v", p, got, want)
	}
}

// Select's targets follow what it picks: face targets for faces, edge targets for edges,
// one point for points, and the element it takes with them.
@(test)
select_picks_faces_edges_or_points :: proc(t: ^testing.T) {
	m: Model_Tool
	m.action = .Select
	testing.expect_value(t, model_element(&m, .Select), Model_Element.Face)
	testing.expect(t, .Island in model_targets(&m, .Select))
	m.pick = .Edge
	testing.expect_value(t, model_element(&m, .Select), Model_Element.Edge)
	testing.expect(t, .Edge_Loop in model_targets(&m, .Select) && .Island not_in model_targets(&m, .Select))
	m.targets[.Select], m.targeted = .Edge_Loop, {.Select}
	testing.expect_value(t, model_target(&m, .Select), Model_Target.Edge_Loop)
	// A target the new pick cannot take falls back to Single.
	m.pick = .Point
	testing.expect_value(t, model_target(&m, .Select), Model_Target.Single)
	testing.expect_value(t, model_element(&m, .Extrude), Model_Element.Face)
}
