package poly

import "core:testing"

import "../geom"

@(private = "file")
cage_curve :: proc() -> [3]geom.Bezier_Point {
	return {
		{p = {0, 0, 0}, h_out = {0.3, 0, 0}, radius = 0.1},
		{p = {1, 0.3, 0}, h_in = {-0.3, 0, 0}, h_out = {0.3, 0, 0}, radius = 0.2, corner = true},
		{p = {2, 0, 0.2}, h_in = {-0.3, 0, 0}, radius = 0.05},
	}
}

// A pipe cage is all quads but its two caps, closed, a ring at each curve point and the
// steps between, its corner point's ring creased.
@(test)
pipe_cage_is_closed_quads :: proc(t: ^testing.T) {
	pts := cage_curve()
	o := CURVE_CAGE_DEFAULTS
	m, err := pipe_cage(pts[:], false, o, {0, 1, 0})
	defer mesh_destroy(&m)
	testing.expect_value(t, err, Build_Error.None)
	c := mesh_check(&m)
	rings := 2 * o.steps + 1
	testing.expect_value(t, c.vertices, rings * o.around)
	testing.expect_value(t, c.quads, (rings - 1) * o.around)
	testing.expect_value(t, c.ngons, 2)
	testing.expect_value(t, c.border_edges, 0)
	creased, _ := crease_count(&m)
	testing.expect_value(t, creased, o.around)
	// Facing out: each face's normal points away from the curve under its middle.
	for f in 0 ..< face_count(&m) - 2 {
		centre := face_center(&m, u32(f))
		_, at, _ := geom.bezier_nearest(pts[:], false, centre)
		testing.expect(t, linalg_dot(face_normal(&m, u32(f)), centre - at) > 0)
	}
	o.caps = false
	open, _ := pipe_cage(pts[:], false, o, {0, 1, 0})
	defer mesh_destroy(&open)
	testing.expect_value(t, mesh_check(&open).border_edges, 2 * o.around)
}

// A closed curve's pipe is a ring with no caps or borders.
@(test)
pipe_cage_closed_loop :: proc(t: ^testing.T) {
	loop := [4]geom.Bezier_Point {
		{p = {1, 0, 0}, h_in = {0, 0, -0.55}, h_out = {0, 0, 0.55}, radius = 0.1},
		{p = {0, 0, 1}, h_in = {0.55, 0, 0}, h_out = {-0.55, 0, 0}, radius = 0.1},
		{p = {-1, 0, 0}, h_in = {0, 0, 0.55}, h_out = {0, 0, -0.55}, radius = 0.1},
		{p = {0, 0, -1}, h_in = {-0.55, 0, 0}, h_out = {0.55, 0, 0}, radius = 0.1},
	}
	m, err := pipe_cage(loop[:], true, CURVE_CAGE_DEFAULTS, {0, 1, 0})
	defer mesh_destroy(&m)
	testing.expect_value(t, err, Build_Error.None)
	c := mesh_check(&m)
	testing.expect_value(t, c.border_edges, 0)
	testing.expect_value(t, c.faces, c.quads)
}

// A half circle with its ends on the axis spins into a closed ball: quads, and triangles
// round each pole.
@(test)
lathe_cage_is_a_closed_ball :: proc(t: ^testing.T) {
	k: f32 = 0.5523
	half := [3]geom.Bezier_Point{{p = {0, 1, 0}, h_out = {k, 0, 0}}, {p = {1, 0, 0}, h_in = {0, k, 0}, h_out = {0, -k, 0}}, {p = {0, -1, 0}, h_in = {k, 0, 0}}}
	ways := [2]bool{false, true}
	for reverse in ways {
		p := half
		if reverse {
			p = {half[2], half[1], half[0]}
			for &q in p do q.h_in, q.h_out = q.h_out, q.h_in
		}
		o := CURVE_CAGE_DEFAULTS
		m, err := lathe_cage(p[:], false, geom.LATHE_DEFAULTS, o)
		defer mesh_destroy(&m)
		testing.expect_value(t, err, Build_Error.None)
		c := mesh_check(&m)
		testing.expect_value(t, c.border_edges, 0)
		testing.expect_value(t, c.triangles, 2 * o.around)
		// Facing out: the first face's normal points away from the middle.
		testing.expectf(t, geom.Vec3(face_normal(&m, 0)) != {} && linalg_dot(face_normal(&m, 0), face_center(&m, 0)) > 0, "reverse %v faces in", reverse)
	}
}

// A closed half section, its flat side down the axis, spins into a closed solid: the
// samples along the axis make no points of their own; a profile touching the axis between
// two rings makes two fans that meet at a point; a partial turn's corner ring is creased.
@(test)
lathe_cage_on_the_axis :: proc(t: ^testing.T) {
	section := [4]geom.Bezier_Point{{p = {0, 1, 0}, corner = true}, {p = {1, 1, 0}, corner = true}, {p = {1, -1, 0}, corner = true}, {p = {0, -1, 0}, corner = true}}
	l := geom.LATHE_DEFAULTS
	l.through = .Middle
	m, err := lathe_cage(section[:], true, l, CURVE_CAGE_DEFAULTS)
	defer mesh_destroy(&m)
	testing.expect_value(t, err, Build_Error.None)
	testing.expect_value(t, mesh_check(&m).border_edges, 0)
	waist := [5]geom.Bezier_Point{{p = {0, 2, 0}}, {p = {1, 1.5, 0}}, {p = {0, 1, 0}}, {p = {1, 0.5, 0}}, {p = {0, 0, 0}}}
	w, w_err := lathe_cage(waist[:], false, geom.LATHE_DEFAULTS, CURVE_CAGE_DEFAULTS)
	defer mesh_destroy(&w)
	testing.expect_value(t, w_err, Build_Error.None)
	half := l
	half.angle = 180
	h, h_err := lathe_cage(section[:], true, half, CURVE_CAGE_DEFAULTS)
	defer mesh_destroy(&h)
	testing.expect_value(t, h_err, Build_Error.None)
	creased, _ := crease_count(&h)
	testing.expectf(t, creased >= 2 * CURVE_CAGE_DEFAULTS.around, "%d creased", creased)
}

@(private = "file")
linalg_dot :: proc(a, b: Vec3) -> f32 {return a.x * b.x + a.y * b.y + a.z * b.z}
