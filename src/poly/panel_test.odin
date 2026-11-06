package poly

import "core:math/linalg"
import "core:testing"

@(test)
panel_loops_raise_a_creased_plate_on_a_cube_face :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	groups := 0
	for g in m.group do groups = max(groups, int(g))
	p, err := panel_loops(&m, {0}, 0.1, 0.05)
	defer panel_destroy(&p)
	testing.expect_value(t, err, Build_Error.None)
	c := mesh_check(&m)
	// The cube's six faces, four ring faces round the panel and four wall faces.
	testing.expectf(t, check_ok(c) && c.faces == 14 && c.quads == 14 && c.border_edges == 0, "%v", c)
	testing.expect_value(t, len(p.top), 1)
	testing.expect_value(t, len(p.edit.face_from), 14)
	// Three loops of four edges, each creased fully.
	creased := 0
	for s in m.crease do if s >= INFINITE_SHARP do creased += 1
	testing.expect_value(t, creased, 12)
	// The wall is a polygroup of its own; the top stands 0.05 off the face it came from.
	walls := 0
	for g in m.group do if int(g) > groups do walls += 1
	testing.expect_value(t, walls, 4)
	n := face_normal(&m, p.top[0])
	top := face_center(&m, p.top[0])
	first := primitive(.Cube)
	defer mesh_destroy(&first)
	rise := linalg.dot(top - face_center(&first, 0), n)
	testing.expectf(t, abs(rise - 0.05) < 1e-4, "the panel rose %v", rise)
}

@(test)
panel_loops_refuse_nothing_or_everything :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	_, err := panel_loops(&m, {}, 0.1, 0.05)
	testing.expect(t, err != .None)
	_, err = panel_loops(&m, {0, 1, 2, 3, 4, 5}, 0.1, 0.05)
	testing.expect(t, err != .None)
	testing.expect_value(t, len(m.face_he), 6)
}
