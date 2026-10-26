package main

import "core:testing"

import "../camera"
import "../geom"
import "../render"

// The head is a closed surface facing out, as the mesh pipeline's back-face culling
// needs, small enough for its picture to show all of it from any side.
@(test)
nav_head_mesh_is_closed_and_fits :: proc(t: ^testing.T) {
	m := nav_head_mesh()
	defer geom.mesh_destroy(&m)
	r := geom.mesh_check(m)
	testing.expect(t, geom.mesh_report_ok(r), "the head is a sound closed surface")
	testing.expect(t, !r.inverted)
	// Up and down within the picture's half height; across and front to back within
	// that times its width over its height, as a side view shows it.
	for i in 0 ..< 3 {
		reach := f32(render.NAV_HEAD_HALF_HEIGHT) * (1 if i == 1 else f32(NAV_HEAD_W) / NAV_HEAD_H)
		testing.expect(t, r.bounds.lo[i] > -reach && r.bounds.hi[i] < reach, "the head fits its picture")
	}
	// The nose is the furthest forward point, in the middle.
	front := 0
	for p, i in m.positions do if p.z > m.positions[front].z do front = i
	testing.expect(t, abs(m.positions[front].x) < 0.05 && m.positions[front].z > 1)
}

// A tap looks from the side of the head it lands on, wherever the view has turned; a tap
// off the head does nothing.
@(test)
nav_head_tap_picks_the_side_under_it :: proc(t: ^testing.T) {
	c := camera.orbit_default()
	camera.orbit_axis_view(&c, .Front)
	front := camera.orbit_rotation(c)
	Case :: struct {
		at:   [2]f32,
		side: camera.Axis_View,
	}
	for k in ([?]Case{{{0, 0}, .Front}, {{0.6, 0}, .Right}, {{-0.6, 0}, .Left}, {{0, 0.6}, .Top}, {{0, -0.6}, .Bottom}}) {
		side, ok := nav_head_side(front, k.at, 1)
		testing.expect(t, ok)
		testing.expect_value(t, side, k.side)
	}
	_, off := nav_head_side(front, {0.98, 0.98}, 1)
	testing.expect(t, !off, "a corner is off the head")

	// Turned to look from the right, the middle of the head is its right side and the
	// left of the picture is its face.
	camera.orbit_axis_view(&c, .Right)
	right := camera.orbit_rotation(c)
	side, _ := nav_head_side(right, {0, 0}, 1)
	testing.expect_value(t, side, camera.Axis_View.Right)
	side, _ = nav_head_side(right, {-0.6, 0}, 1)
	testing.expect_value(t, side, camera.Axis_View.Front)
	// From above, the top of the picture is the back of the head.
	camera.orbit_axis_view(&c, .Top)
	side, _ = nav_head_side(camera.orbit_rotation(c), {0, 0.6}, 1)
	testing.expect_value(t, side, camera.Axis_View.Back)
}
