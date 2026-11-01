package poly

import "core:math"
import "core:math/linalg"
import "core:testing"

import "../geom"

// A circle of `n` smooth points of radius r at height y, about the y axis, starting at
// angle `from` and going round the way `way` says.
@(private = "file")
loft_circle :: proc(n: int, r, y: f32, from: f32 = 0, way: f32 = 1) -> []geom.Bezier_Point {
	pts := make([]geom.Bezier_Point, n, context.temp_allocator)
	for i in 0 ..< n {
		a := from + way * 2 * math.PI * f32(i) / f32(n)
		pts[i] = {p = {r * math.cos(a), y, r * math.sin(a)}, radius = 0.1, intensity = 1}
	}
	for i in 0 ..< n do geom.bezier_make_smooth(pts, true, i)
	return pts
}

// The signed volume a closed mesh's faces enclose (positive when they face out).
@(private = "file")
loft_volume :: proc(m: ^Mesh) -> f32 {
	v: f32
	for f in 0 ..< u32(len(m.face_he)) {
		w := face_walk(m, f)
		first := NONE
		prev := NONE
		for h in face_walk_next(&w) {
			p := m.he_vert[h]
			if first == NONE {
				first = p
			} else if prev != first {
				v += linalg.dot(m.positions[first], linalg.cross(m.positions[prev], m.positions[p])) / 6
			}
			prev = p
		}
	}
	return v
}

@(test)
loft_two_circles_make_a_capped_tube :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	sections := [][]geom.Bezier_Point{loft_circle(4, 1, 0), loft_circle(6, 0.5, 2)}
	m, err := loft_cage(sections, true, {around = 8, steps = 3, caps = true})
	defer mesh_destroy(&m)
	testing.expect_value(t, err, Build_Error.None)
	c := mesh_check(&m)
	testing.expect_value(t, c.faces, 8 * 3 + 2)
	testing.expect_value(t, c.vertices, 8 * 4)
	testing.expect_value(t, c.border_edges, 0)
	testing.expect_value(t, c.broken_links, 0)
	testing.expectf(t, loft_volume(&m) > 0, "faces in: volume %v", loft_volume(&m))
}

@(test)
loft_a_reversed_and_turned_section_does_not_twist :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	straight := [][]geom.Bezier_Point{loft_circle(8, 1, 0), loft_circle(8, 1, 1)}
	twisted := [][]geom.Bezier_Point{loft_circle(8, 1, 0), loft_circle(8, 1, 1, from = 1.3, way = -1)}
	a, _ := loft_cage(straight, true, {around = 8, steps = 1, caps = false})
	b, _ := loft_cage(twisted, true, {around = 8, steps = 1, caps = false})
	defer mesh_destroy(&a)
	defer mesh_destroy(&b)
	// Untwisted, every side is upright: its edges between the rows run straight up, as long
	// as the rows are apart, the twisted section's start and way matched to the first's.
	for m in ([2]^Mesh{&a, &b}) {
		for e in 0 ..< u32(len(m.crease)) {
			p, q := edge_verts(m, e)
			d := m.positions[q] - m.positions[p]
			if abs(d.y) < 0.5 do continue
			testing.expectf(t, linalg.length(d.xz) < 0.35, "a side edge leans %v", d)
		}
	}
	testing.expect(t, loft_volume(&a) * loft_volume(&b) >= 0)
}

@(test)
loft_three_open_lines_make_a_smooth_sheet :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	line :: proc(z, bulge: f32) -> []geom.Bezier_Point {
		pts := make([]geom.Bezier_Point, 2, context.temp_allocator)
		pts[0] = {p = {-1, bulge, z}, radius = 0.1, intensity = 1}
		pts[1] = {p = {1, bulge, z}, radius = 0.1, intensity = 1}
		return pts
	}
	sections := [][]geom.Bezier_Point{line(0, 0), line(1, 1), line(2, 0)}
	m, err := loft_cage(sections, false, {around = 4, steps = 2, caps = true})
	defer mesh_destroy(&m)
	testing.expect_value(t, err, Build_Error.None)
	c := mesh_check(&m)
	// Four quads across, four rows of them (two between each pair), no caps on a sheet.
	testing.expect_value(t, c.faces, 4 * 4)
	testing.expect_value(t, c.vertices, 5 * 5)
	// The spline passes through the middle section and bulges between them, never past it.
	hi: f32
	for p in m.positions do hi = max(hi, p.y)
	testing.expect(t, abs(hi - 1) < 1e-4)
}

@(test)
loft_refuses_one_section_or_a_point :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	one := [][]geom.Bezier_Point{loft_circle(4, 1, 0)}
	m, err := loft_cage(one, true, CURVE_CAGE_DEFAULTS)
	mesh_destroy(&m)
	testing.expect(t, err != .None)
	dot := []geom.Bezier_Point{{p = {}}, {p = {}}}
	two := [][]geom.Bezier_Point{dot, dot}
	m, err = loft_cage(two, false, CURVE_CAGE_DEFAULTS)
	mesh_destroy(&m)
	testing.expect(t, err != .None)
}

@(test)
loft_spaces_a_loop_evenly :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// Two round loops: every column of quads is as wide as the others, the last too.
	sections := [][]geom.Bezier_Point{loft_circle(8, 1, 0), loft_circle(8, 1, 1)}
	m, _ := loft_cage(sections, true, {around = 8, steps = 1, caps = false})
	defer mesh_destroy(&m)
	lo, hi := max(f32), f32(0)
	for e in 0 ..< u32(len(m.crease)) {
		p, q := edge_verts(&m, e)
		d := m.positions[q] - m.positions[p]
		if abs(d.y) > 0.5 do continue
		lo, hi = min(lo, linalg.length(d)), max(hi, linalg.length(d))
	}
	testing.expectf(t, hi < 1.02 * lo, "ring edges from %v to %v", lo, hi)
}
