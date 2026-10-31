package geom

import "core:testing"

@(private = "file")
tube_curve :: proc() -> [3]Bezier_Point {
	return {
		{p = {0, 0, 0}, h_out = {0.3, 0, 0}, radius = 0.1, intensity = 1},
		{p = {1, 0.3, 0}, h_in = {-0.3, 0, 0}, h_out = {0.3, 0, 0}, radius = 0.2, intensity = 1},
		{p = {2, 0, 0.2}, h_in = {-0.3, 0, 0}, radius = 0.05, intensity = 1},
	}
}

// Every profile and cap gives a closed tube facing out, with no flipped or degenerate
// triangles; open caps leave two holes the size of a ring.
@(test)
bezier_tube_is_closed_and_faces_out :: proc(t: ^testing.T) {
	pts := tube_curve()
	for profile in Tube_Profile {
		caps := [2]Tube_Caps{.Flat, .Round}
		for cap in caps {
			o := TUBE_DEFAULTS
			o.profile, o.caps = profile, cap
			m, ok := bezier_tube(pts[:], false, o, {0, 1, 0})
			defer mesh_destroy(&m)
			testing.expect(t, ok)
			r := mesh_check(m)
			testing.expectf(t, r.closed && !r.inverted && r.inconsistent_edges == 0 && r.degenerate_triangles == 0 && r.nan_count == 0, "%v %v: %v", profile, cap, r)
		}
	}
	o := TUBE_DEFAULTS
	o.caps = .Open
	m, _ := bezier_tube(pts[:], false, o, {0, 1, 0})
	defer mesh_destroy(&m)
	r := mesh_check(m)
	testing.expect_value(t, r.boundary_edges, 2 * o.sides)
}

// A closed curve gives a ring of a tube with no caps, closed and facing out.
@(test)
bezier_tube_closed_loop :: proc(t: ^testing.T) {
	pts := [4]Bezier_Point {
		{p = {1, 0, 0}, h_in = {0, 0, -0.55}, h_out = {0, 0, 0.55}, radius = 0.1},
		{p = {0, 0, 1}, h_in = {0.55, 0, 0}, h_out = {-0.55, 0, 0}, radius = 0.1},
		{p = {-1, 0, 0}, h_in = {0, 0, 0.55}, h_out = {0, 0, -0.55}, radius = 0.1},
		{p = {0, 0, -1}, h_in = {-0.55, 0, 0}, h_out = {0.55, 0, 0}, radius = 0.1},
	}
	m, ok := bezier_tube(pts[:], true, TUBE_DEFAULTS, {0, 1, 0})
	defer mesh_destroy(&m)
	testing.expect(t, ok)
	r := mesh_check(m)
	testing.expectf(t, r.closed && !r.inverted && r.inconsistent_edges == 0, "%v", r)
	testing.expect_value(t, r.vertices % TUBE_DEFAULTS.sides, 0)
}

// One makes every ring the same size; Ends blends the end points' radii; Each follows the
// points, so the middle ring is the widest.
@(test)
bezier_tube_radius_modes :: proc(t: ^testing.T) {
	pts := tube_curve()
	widest :: proc(m: Mesh, sides: int, ring: int) -> f32 {
		lo, hi := m.positions[ring * sides], m.positions[ring * sides]
		for k in 0 ..< sides {
			p := m.positions[ring * sides + k]
			lo, hi = {min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)}, {max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)}
		}
		d := hi - lo
		return max(d.y, d.z)
	}
	o := TUBE_DEFAULTS
	o.caps = .Open
	modes := [3]Tube_Radius{.One, .Ends, .Each}
	for mode in modes {
		o.radius = mode
		m, ok := bezier_tube(pts[:], false, o, {0, 1, 0})
		defer mesh_destroy(&m)
		testing.expect(t, ok)
		rings := len(m.positions) / o.sides
		a, mid, b := widest(m, o.sides, 0), widest(m, o.sides, rings / 2), widest(m, o.sides, rings - 1)
		switch mode {
		case .One:
			testing.expectf(t, abs(a - b) < 0.01 && abs(a - 2 * o.one) < 0.01, "one: %v %v", a, b)
		case .Ends:
			testing.expectf(t, a > b && mid < a && mid > b, "ends: %v %v %v", a, mid, b)
		case .Each:
			testing.expectf(t, mid > a && mid > b, "each: %v %v %v", a, mid, b)
		}
	}
}
