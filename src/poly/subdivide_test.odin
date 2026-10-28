package poly

import "core:math/linalg"
import "core:slice"
import "core:testing"

@(test)
a_cube_subdivides_into_quads_toward_a_ball :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	s, err := subdivide(&m, 2)
	defer subdivision_destroy(&s)
	testing.expect_value(t, err, Build_Error.None)
	testing.expect_value(t, len(s.steps), 2)
	one := mesh_check(&s.steps[0])
	testing.expectf(t, check_ok(one) && one.faces == 24 && one.vertices == 26 && one.edges == 48 && one.border_edges == 0 && one.quads == 24, "%v", one)
	top := subdivision_top(&s, &m)
	two := mesh_check(top)
	testing.expectf(t, check_ok(two) && two.faces == 96 && two.quads == 96, "%v", two)
	testing.expect_value(t, len(s.face_from), 96)
	// Every point keeps to one side of the middle as far as its mirror on the other, and
	// the corners pull in toward the middle.
	for p in top.positions do testing.expect(t, linalg.length(p) < linalg.length(m.positions[0]))
	b := mesh_bounds(top)
	testing.expectf(t, linalg.length(b.hi + b.lo) < 1e-5, "%v", b)
	// Each finer face lies in the cage face it came from: on its side of the cube.
	for f, i in s.face_from {
		n := face_normal(&m, f)
		testing.expect(t, linalg.dot(face_center(top, u32(i)), n) > 0)
	}
}

@(test)
creases_keep_edges_sharp :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	for &c in m.crease do c = INFINITE_SHARP
	s, _ := subdivide(&m, 3)
	defer subdivision_destroy(&s)
	top := subdivision_top(&s, &m)
	// With every edge fully creased the cube keeps its shape: corners stay, and every
	// point lies on the cube's surface.
	for v in 0 ..< len(m.positions) do testing.expect_value(t, top.positions[v], m.positions[v])
	half := abs(m.positions[0].x)
	for p in top.positions {
		on := abs(abs(p.x) - half) < 1e-5 || abs(abs(p.y) - half) < 1e-5 || abs(abs(p.z) - half) < 1e-5
		testing.expectf(t, on, "%v is off the cube", p)
	}
	// A crease of one rounds off after a step: between the smooth cube and the sharp one.
	soft := primitive(.Cube)
	defer mesh_destroy(&soft)
	for &c in soft.crease do c = 1
	s1, _ := subdivide(&soft, 3)
	defer subdivision_destroy(&s1)
	plain := primitive(.Cube)
	defer mesh_destroy(&plain)
	s0, _ := subdivide(&plain, 3)
	defer subdivision_destroy(&s0)
	r1, r0 := linalg.length(subdivision_top(&s1, &soft).positions[0]), linalg.length(subdivision_top(&s0, &plain).positions[0])
	testing.expectf(t, r1 > r0 && r1 < linalg.length(m.positions[0]), "corner at %v, smooth %v", r1, r0)
}

@(test)
a_plane_keeps_its_corners_and_borders_flat :: proc(t: ^testing.T) {
	m := primitive(.Plane, {across = 2})
	defer mesh_destroy(&m)
	s, _ := subdivide(&m, 2)
	defer subdivision_destroy(&s)
	top := subdivision_top(&s, &m)
	c := mesh_check(top)
	testing.expectf(t, check_ok(c) && c.faces == 64 && c.border_edges == 32, "%v", c)
	b0, b1 := mesh_bounds(&m), mesh_bounds(top)
	testing.expectf(t, linalg.length(b0.lo - b1.lo) < 1e-5 && linalg.length(b0.hi - b1.hi) < 1e-5, "%v then %v", b0, b1)
}

@(test)
moving_the_cage_moves_the_finer_cages_alike :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	m.corner[3] = 0.5
	m.crease[2] = 1.5
	s, _ := subdivide(&m, 2)
	defer subdivision_destroy(&s)
	m.positions[0] += {0.3, -0.2, 0.1}
	subdivision_update(&s, &m)
	fresh, _ := subdivide(&m, 2)
	defer subdivision_destroy(&fresh)
	testing.expect(t, slice.equal(subdivision_top(&s, &m).positions[:], subdivision_top(&fresh, &m).positions[:]))
}

@(test)
each_edge_runs_along_the_finest_cage :: proc(t: ^testing.T) {
	m := primitive(.Cylinder, {around = 6, along = 1})
	defer mesh_destroy(&m)
	s, _ := subdivide(&m, 2)
	defer subdivision_destroy(&s)
	top := subdivision_top(&s, &m)
	testing.expect_value(t, s.line_points, 5)
	for e in 0 ..< u32(len(m.crease)) {
		line := s.edge_line[int(e) * s.line_points:][:s.line_points]
		a, b := edge_verts(&m, e)
		testing.expect(t, line[0] == a && line[len(line) - 1] == b)
		for i in 0 ..< len(line) - 1 do testing.expect(t, find_half_edge(top, line[i], line[i + 1]) != NONE)
	}
	// No steps: the cage's own edges.
	none, _ := subdivide(&m, 0)
	defer subdivision_destroy(&none)
	testing.expect(t, subdivision_top(&none, &m) == &m && none.line_points == 2 && len(none.face_from) == len(m.face_he))
}
