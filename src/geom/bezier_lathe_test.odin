package geom

import "core:math"
import "core:math/linalg"
import "core:testing"

// A half circle of radius one in the XY plane from the top of the Y axis round to its
// bottom, its ends on the axis.
@(private = "file")
half_circle :: proc() -> [3]Bezier_Point {
	k: f32 = 0.5523 // a quarter circle's handle length over its radius
	return {
		{p = {0, 1, 0}, h_out = {k, 0, 0}},
		{p = {1, 0, 0}, h_in = {0, k, 0}, h_out = {0, -k, 0}},
		{p = {0, -1, 0}, h_in = {k, 0, 0}},
	}
}

// The enclosed volume of a closed mesh.
@(private = "file")
lathe_volume :: proc(m: Mesh) -> f32 {
	v: f32
	for t := 0; t + 2 < len(m.indices); t += 3 {
		a, b, c := m.positions[m.indices[t]], m.positions[m.indices[t + 1]], m.positions[m.indices[t + 2]]
		v += linalg.dot(a, linalg.cross(b, c)) / 6
	}
	return v
}

// A half circle spun round the axis its ends lie on is a closed sphere facing out, with one
// point at each pole, whichever way the half circle runs.
@(test)
bezier_lathe_sphere :: proc(t: ^testing.T) {
	pts := half_circle()
	ways := [2]bool{false, true}
	for reverse in ways {
		p := pts
		if reverse {
			p = {pts[2], pts[1], pts[0]}
			for &q in p do q.h_in, q.h_out = q.h_out, q.h_in
		}
		m, ok := bezier_lathe(p[:], false, LATHE_DEFAULTS)
		defer mesh_destroy(&m)
		testing.expect(t, ok)
		r := mesh_check(m)
		testing.expectf(t, r.closed && !r.inverted && r.inconsistent_edges == 0 && r.degenerate_triangles == 0, "reverse %v: %v", reverse, r)
		v := lathe_volume(m)
		testing.expectf(t, abs(v - 4 * math.PI / 3) < 0.15, "volume %v", v)
	}
}

// Ends off the axis close with caps; without, they leave two holes a ring round each.
@(test)
bezier_lathe_caps :: proc(t: ^testing.T) {
	pts := [2]Bezier_Point{{p = {0.5, 1, 0}, h_out = {0.3, -0.3, 0}}, {p = {0.8, -1, 0}, h_in = {0, 0.4, 0}}}
	o := LATHE_DEFAULTS
	o.through = .Middle
	m, ok := bezier_lathe(pts[:], false, o)
	defer mesh_destroy(&m)
	testing.expect(t, ok)
	r := mesh_check(m)
	testing.expectf(t, r.closed && !r.inverted && r.inconsistent_edges == 0 && r.degenerate_triangles == 0, "%v", r)
	o.caps = false
	open, _ := bezier_lathe(pts[:], false, o)
	defer mesh_destroy(&open)
	testing.expect_value(t, mesh_check(open).boundary_edges, 2 * o.segments)
}

// Half a turn leaves its sides open; a closed curve off the axis spins into a closed ring.
@(test)
bezier_lathe_angle_and_loop :: proc(t: ^testing.T) {
	pts := half_circle()
	o := LATHE_DEFAULTS
	o.angle = 180
	m, ok := bezier_lathe(pts[:], false, o)
	defer mesh_destroy(&m)
	testing.expect(t, ok)
	r := mesh_check(m)
	testing.expectf(t, !r.closed && r.boundary_edges > 0 && r.inconsistent_edges == 0 && r.degenerate_triangles == 0, "%v", r)
	loop := [4]Bezier_Point {
		{p = {2, 0, 0}, h_in = {0, -0.28, 0}, h_out = {0, 0.28, 0}},
		{p = {1.5, 0.5, 0}, h_in = {0.28, 0, 0}, h_out = {-0.28, 0, 0}},
		{p = {1, 0, 0}, h_in = {0, 0.28, 0}, h_out = {0, -0.28, 0}},
		{p = {1.5, -0.5, 0}, h_in = {-0.28, 0, 0}, h_out = {0.28, 0, 0}},
	}
	o = LATHE_DEFAULTS
	o.through = .Middle
	ring, ring_ok := bezier_lathe(loop[:], true, o)
	defer mesh_destroy(&ring)
	testing.expect(t, ring_ok)
	rr := mesh_check(ring)
	testing.expectf(t, rr.closed && !rr.inverted && rr.inconsistent_edges == 0 && rr.degenerate_triangles == 0, "%v", rr)
	// A flat ring faces up the axis whichever end it is drawn from.
	flat := [2]Bezier_Point{{p = {0.5, 0, 0}}, {p = {1, 0, 0}}}
	ends := [2]bool{false, true}
	o.caps = false
	for reverse in ends {
		f := flat
		if reverse do f = {flat[1], flat[0]}
		disk, disk_ok := bezier_lathe(f[:], false, o)
		defer mesh_destroy(&disk)
		testing.expect(t, disk_ok)
		testing.expectf(t, disk.normals[0].y > 0.9, "reverse %v: normal %v", reverse, disk.normals[0])
	}
	// A curve along the axis makes nothing.
	line := [2]Bezier_Point{{p = {0, 1, 0}}, {p = {0, -1, 0}}}
	_, line_ok := bezier_lathe(line[:], false, LATHE_DEFAULTS)
	testing.expect(t, !line_ok)
}
