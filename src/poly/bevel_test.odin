package poly

import "core:testing"

@(test)
bevelling_one_edge_of_a_cube :: proc(t: ^testing.T) {
	for s in ([2]int{1, 3}) {
		m := primitive(.Cube)
		defer mesh_destroy(&m)
		r, d, err := bevel_edges(&m, {0}, s)
		defer edit_result_destroy(&r)
		defer drag_set_destroy(&d)
		testing.expect_value(t, err, Build_Error.None)
		c := mesh_check(&m)
		// The strip's s quads; each end's three-edged corner goes, its far face taking the
		// strip's end (two points and the arc between).
		testing.expectf(t, check_ok(c) && c.faces == 6 + s && c.vertices == 8 - 2 + 4 + 2 * (s - 1) && c.euler == 2 && c.border_edges == 0, "%d segments: %v", s, c)
		testing.expect_value(t, len(d.verts), 4 + 2 * (s - 1))
		half := abs(m.positions[0].x)
		// The strip may slide most of the way along the edges beside it, whose far ends stay.
		testing.expectf(t, d.hi > 0.85 * 2 * abs(m.positions[0].x) && d.hi < 2 * abs(m.positions[0].x), "%v", d.hi)
		drag_apply(&m, &d, 0.2)
		testing.expect(t, check_ok(mesh_check(&m)))
		b := mesh_bounds(&m)
		testing.expectf(t, b.hi.x <= half + 1e-5 && b.lo.x >= -half - 1e-5 && b.hi.y <= half + 1e-5, "%v", b)
	}
}

@(test)
bevelling_every_edge_of_a_cube :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	all: [12]u32
	for &e, i in all do e = u32(i)
	r, d, err := bevel_edges(&m, all[:], 1)
	defer edit_result_destroy(&r)
	defer drag_set_destroy(&d)
	testing.expect_value(t, err, Build_Error.None)
	half := abs(m.positions[0].x)
	c := mesh_check(&m)
	// Six smaller faces, twelve strips and a triangle at each corner.
	testing.expectf(t, check_ok(c) && c.faces == 26 && c.vertices == 24 && c.triangles == 8 && c.quads == 18, "%v", c)
	// Each face's mitered corners stay on the face's plane: a width in from both edges.
	drag_apply(&m, &d, 0.1)
	for p in m.positions {
		on := abs(abs(p.x) - half) < 1e-5 || abs(abs(p.y) - half) < 1e-5 || abs(abs(p.z) - half) < 1e-5
		testing.expectf(t, on, "%v is off the cube", p)
		// Two of its three coordinates are a width in from the cube's edges.
		in_count := int(abs(p.x) <= half - 0.1 + 1e-5) + int(abs(p.y) <= half - 0.1 + 1e-5) + int(abs(p.z) <= half - 0.1 + 1e-5)
		inside := in_count == 2
		testing.expectf(t, inside, "%v is not a width in", p)
	}
	// The widest a bevel of every edge goes is half a side.
	testing.expectf(t, d.hi < half && d.hi > 0.9 * half, "%v", d.hi)
}

@(test)
bevelling_a_loop_rounds_it :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	// The four edges round the face on half-edge 0.
	loop := make([dynamic]u32, context.temp_allocator)
	w := face_walk(&m, 0)
	for h in face_walk_next(&w) do append(&loop, edge_of(h))
	r, d, err := bevel_edges(&m, loop[:], 2)
	defer edit_result_destroy(&r)
	defer drag_set_destroy(&d)
	testing.expect_value(t, err, Build_Error.None)
	c := mesh_check(&m)
	// Two quads across each of the four strips; the strips meet at the corners with no patch.
	testing.expectf(t, check_ok(c) && c.faces == 14 && c.vertices == 16 && c.quads == 14, "%v", c)
	drag_apply(&m, &d, 0.2)
	testing.expect(t, check_ok(mesh_check(&m)))
}

@(test)
a_bevel_at_a_border_is_refused :: proc(t: ^testing.T) {
	m := primitive(.Plane)
	defer mesh_destroy(&m)
	before := mesh_check(&m)
	r, d, err := bevel_edges(&m, {0}, 1)
	edit_result_destroy(&r)
	drag_set_destroy(&d)
	testing.expect_value(t, err, Build_Error.Unsupported)
	testing.expect_value(t, mesh_check(&m), before)
}

@(test)
bevelling_where_four_edges_meet :: proc(t: ^testing.T) {
	opts := PRIMITIVE_DEFAULTS
	opts.across = 2
	// A loop round the middle of a cube of 2 x 2 quads a side: every point on it has four
	// edges, two of them bevelled, so each side's point slides along the edge between.
	{
		m := primitive(.Cube, opts)
		defer mesh_destroy(&m)
		loop := make([dynamic]u32, context.temp_allocator)
		start := u32(inner_edge(&m))
		edge_loop(&m, start, &loop)
		testing.expect_value(t, len(loop), 8)
		before := mesh_check(&m)
		r, d, err := bevel_edges(&m, loop[:], 3)
		defer edit_result_destroy(&r)
		defer drag_set_destroy(&d)
		testing.expect_value(t, err, Build_Error.None)
		c := mesh_check(&m)
		testing.expectf(t, check_ok(c) && c.faces == before.faces + 3 * 8 && c.vertices == before.vertices + 8 * 3 && c.quads == c.faces, "%v", c)
		drag_apply(&m, &d, 0.1)
		testing.expect(t, check_ok(mesh_check(&m)))
	}
	// One edge alone, from a side's middle point: each end keeps its point and closes the
	// strip's end with a triangle.
	{
		m := primitive(.Cube, opts)
		defer mesh_destroy(&m)
		before := mesh_check(&m)
		e := inner_edge(&m)
		r, d, err := bevel_edges(&m, {e}, 1)
		defer edit_result_destroy(&r)
		defer drag_set_destroy(&d)
		testing.expect_value(t, err, Build_Error.None)
		c := mesh_check(&m)
		testing.expectf(t, check_ok(c) && c.faces == before.faces + 3 && c.triangles == 2 && c.vertices == before.vertices + 4, "%v", c)
		drag_apply(&m, &d, 0.1)
		testing.expect(t, check_ok(mesh_check(&m)))
	}
}

// An edge whose two ends both have four edges.
@(private = "file")
inner_edge :: proc(m: ^Mesh) -> u32 {
	for e in 0 ..< u32(len(m.crease)) {
		a, b := edge_verts(m, e)
		if valence(m, a) == 4 && valence(m, b) == 4 do return e
	}
	return NONE
}
