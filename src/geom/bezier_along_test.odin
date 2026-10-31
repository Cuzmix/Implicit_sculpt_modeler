package geom

import "core:testing"

@(private = "file")
straight :: proc(r0, r1: f32) -> [2]Bezier_Point {
	return {{p = {0, 0, 0}, h_out = {1, 0, 0}, radius = r0}, {p = {3, 0, 0}, h_in = {-1, 0, 0}, radius = r1}}
}

// A sphere part of depth one, on a straight curve three long and 0.2 wide with a gap of
// half a copy, is set every 0.3: eleven copies from 0 to 3, each closed and facing out.
@(test)
bezier_along_counts_and_closes :: proc(t: ^testing.T) {
	part := icosphere(1, 0.5)
	defer mesh_destroy(&part)
	pts := straight(0.1, 0.1)
	o := ALONG_DEFAULTS
	o.gap = 0.5
	m, ok := bezier_along(pts[:], false, part, o)
	defer mesh_destroy(&m)
	testing.expect(t, ok)
	testing.expect_value(t, len(m.positions) / len(part.positions), 11)
	r := mesh_check(m)
	testing.expectf(t, !r.inverted && r.inconsistent_edges == 0 && r.degenerate_triangles == 0 && r.boundary_edges == 0, "%v", r)
	// The same again is the same, to the bit.
	again, _ := bezier_along(pts[:], false, part, o)
	defer mesh_destroy(&again)
	testing.expect(t, len(again.positions) == len(m.positions))
	for p, i in m.positions do if p != again.positions[i] {
		testing.expect(t, false, "not deterministic")
		break
	}
}

// Copies grow with the curve's radius and spread to keep their gaps; Alternate turns every
// other one half round, so a part off to one side lands on the other.
@(test)
bezier_along_sizes_and_alternates :: proc(t: ^testing.T) {
	part := curve_tooth_part(1)
	defer mesh_destroy(&part)
	pts := straight(0.05, 0.2)
	o := ALONG_DEFAULTS
	o.up = {0, 0, 1}
	m, ok := bezier_along(pts[:], false, part, o)
	defer mesh_destroy(&m)
	testing.expect(t, ok)
	copies := len(m.positions) / len(part.positions)
	testing.expect(t, copies > 3)
	extent :: proc(m: Mesh, first, count: int) -> (lo, hi: Vec3) {
		lo, hi = max(f32), -max(f32)
		for p in m.positions[first:][:count] do lo, hi = {min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)}, {max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)}
		return
	}
	n := len(part.positions)
	lo0, hi0 := extent(m, 0, n)
	lo1, hi1 := extent(m, (copies - 1) * n, n)
	testing.expectf(t, (hi1.z - lo1.z) > 2 * (hi0.z - lo0.z), "the last copy %v is not wider than the first %v", hi1.z - lo1.z, hi0.z - lo0.z)
	o.alternate = true
	alt, _ := bezier_along(pts[:], false, part, o)
	defer mesh_destroy(&alt)
	a_lo, a_hi := extent(alt, 0, n)
	b_lo, b_hi := extent(alt, n, n)
	// The tooth sits to one side of the curve (across is y here, up being z), and the next
	// sits to the other.
	testing.expectf(t, (a_lo.y + a_hi.y) * (b_lo.y + b_hi.y) < 0, "%v %v / %v %v", a_lo, a_hi, b_lo, b_hi)
}

// On a closed curve the last copy stops short of the first; a part made of any mesh is
// centred and one wide.
@(test)
bezier_along_closed_and_any_part :: proc(t: ^testing.T) {
	loop := [4]Bezier_Point {
		{p = {1, 0, 0}, h_in = {0, 0, -0.55}, h_out = {0, 0, 0.55}, radius = 0.1},
		{p = {0, 0, 1}, h_in = {0.55, 0, 0}, h_out = {-0.55, 0, 0}, radius = 0.1},
		{p = {-1, 0, 0}, h_in = {0, 0, 0.55}, h_out = {0, 0, -0.55}, radius = 0.1},
		{p = {0, 0, -1}, h_in = {-0.55, 0, 0}, h_out = {0.55, 0, 0}, radius = 0.1},
	}
	ball := icosphere(1, 3)
	defer mesh_destroy(&ball)
	for &p in ball.positions do p += {5, 5, 5}
	part, ok := along_part_of(ball)
	defer mesh_destroy(&part)
	testing.expect(t, ok)
	lo, hi := max(f32), -max(f32)
	for p in part.positions do lo, hi = min(lo, p.x), max(hi, p.x)
	testing.expectf(t, abs(hi - lo - 1) < 1e-4 && abs(hi + lo) < 1e-4, "%v %v", lo, hi)
	o := ALONG_DEFAULTS
	o.gap = 0
	m, made := bezier_along(loop[:], true, part, o)
	defer mesh_destroy(&m)
	testing.expect(t, made)
	copies := len(m.positions) / len(part.positions)
	length := bezier_length(loop[:], true)
	testing.expectf(t, f32(copies) * 0.2 <= length + 1e-3 && f32(copies + 1) * 0.2 > length, "%d copies of 0.2 round %v", copies, length)
}
