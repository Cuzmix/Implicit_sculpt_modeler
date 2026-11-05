package geom

import "core:math/linalg"
import "core:testing"

// Taper narrows a straight tube from its points' radius at the start to 0.15 of it at the
// end; every preset still gives a closed tube facing out.
@(test)
tube_width_shapes_the_radius_along :: proc(t: ^testing.T) {
	pts := [2]Bezier_Point{{p = {0, 0, 0}, h_out = {0.5, 0, 0}, radius = 1}, {p = {2, 0, 0}, h_in = {-0.5, 0, 0}, radius = 1}}
	o := TUBE_DEFAULTS
	o.radius, o.one, o.caps = .One, 0.1, .Flat
	o.width = width_preset(.Taper)
	m, ok := bezier_tube(pts[:], false, o, {0, 1, 0})
	defer mesh_destroy(&m)
	testing.expect(t, ok)
	start, end: f32
	for p in m.positions {
		r := linalg.length(p.yz)
		if p.x < 0.01 do start = max(start, r)
		if p.x > 1.99 do end = max(end, r)
	}
	testing.expectf(t, abs(start - 0.1) < 2e-3, "the start is %v wide, want 0.1", start)
	testing.expectf(t, abs(end - 0.015) < 2e-3, "the end is %v wide, want 0.015", end)
	for kind in Width_Preset {
		o.width = width_preset(kind)
		mm, mok := bezier_tube(pts[:], false, o, {0, 1, 0})
		defer mesh_destroy(&mm)
		r := mesh_check(mm)
		testing.expectf(t, mok && r.closed && !r.inverted && r.degenerate_triangles == 0, "%v: %v", kind, r)
	}
}

// Points added keep the graph's shape; held points keep their order and the ends at 0 and
// 1; the ends cannot be deleted.
@(test)
tube_width_edits_keep_its_order :: proc(t: ^testing.T) {
	w := width_preset(.Bulge)
	table := width_table(w)
	before := width_lookup(table, 0.3)
	at := width_insert(&w, 0.6)
	testing.expect_value(t, at, 1)
	testing.expectf(t, abs(width_lookup(width_table(w), 0.3) - before) < 1e-3, "adding a point changed the graph")
	w.points[at].p = {0.9, 3}
	width_hold(&w, at)
	testing.expect(t, w.points[at].p.x < w.points[at + 1].p.x && w.points[at].p.y == WIDTH_MAX, "a held point left its place")
	w.points[0].p.x = 0.4
	width_hold(&w, 0)
	testing.expect_value(t, w.points[0].p.x, 0)
	testing.expect(t, !width_delete(&w, 0) && !width_delete(&w, w.count - 1), "an end went")
	testing.expect(t, width_delete(&w, at))
	testing.expect(t, width_is_even(width_preset(.Even)) && !width_is_even(width_preset(.Taper)), "Even is not level")
}
