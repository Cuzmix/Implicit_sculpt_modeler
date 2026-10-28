package poly

import "core:math"
import "core:testing"

import "../geom"

// The cage's triangles as a geom mesh, for geom.mesh_check's closed and volume numbers.
@(private = "file")
triangles_of :: proc(m: ^Mesh) -> (t: geom.Mesh, tri_face: [dynamic]u32) {
	t = {positions = make([dynamic]Vec3), normals = make([dynamic]Vec3), indices = make([dynamic]u32)}
	tri_face = make([dynamic]u32)
	triangulate(m, &t, &tri_face)
	return
}

@(test)
a_cube_is_eight_corners_twelve_edges_six_quads :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	c := mesh_check(&m)
	testing.expectf(t, check_ok(c), "%v", c)
	testing.expectf(t, c.vertices == 8 && c.edges == 12 && c.faces == 6 && c.quads == 6 && c.border_edges == 0, "%v", c)
	testing.expect_value(t, c.euler, 2)
	testing.expect_value(t, c.poles, 8) // three edges meet at each corner
	tm, tri_face := triangles_of(&m)
	defer geom.mesh_destroy(&tm)
	defer delete(tri_face)
	r := geom.mesh_check(tm)
	testing.expectf(t, geom.mesh_report_ok(r), "%v", r)
	// Corners on the unit sphere: sides of 2/√3, a volume of 8/3^1.5.
	want := f64(8) / math.pow(3, 1.5)
	testing.expectf(t, math.abs(r.volume - want) < 1e-5, "volume %v, want %v", r.volume, want)
	testing.expect_value(t, len(tri_face), 12)
}

@(test)
every_primitive_is_sound_and_faces_out :: proc(t: ^testing.T) {
	for kind in Primitive {
		for opts in ([3]Primitive_Options{PRIMITIVE_DEFAULTS, {across = 3, around = 12, along = 4, tube = 5}, {across = 1, around = 3, along = 1, tube = 3}}) {
			m := primitive(kind, opts)
			defer mesh_destroy(&m)
			c := mesh_check(&m)
			testing.expectf(t, check_ok(c), "%v %v: %v", kind, opts, c)
			tm, tri_face := triangles_of(&m)
			defer geom.mesh_destroy(&tm)
			defer delete(tri_face)
			r := geom.mesh_check(tm)
			if kind == .Plane {
				testing.expectf(t, c.border_edges == 4 * max(opts.across, 1) && c.euler == 1, "%v: %v", opts, c)
				continue
			}
			testing.expectf(t, r.closed && !r.inverted && r.volume > 0.1 && r.degenerate_triangles == 0, "%v %v: %v", kind, opts, r)
			testing.expectf(t, r.bounds.hi.x <= 1 + 1e-5 && r.bounds.lo.y >= -1 - 1e-5, "%v fits the unit sphere's box: %v", kind, r.bounds)
			// A torus has genus 1, everything else 0.
			testing.expectf(t, c.euler == (0 if kind == .Torus else 2), "%v %v euler %v", kind, opts, c.euler)
		}
	}
}

@(test)
building_refuses_what_half_edges_cannot_hold :: proc(t: ^testing.T) {
	square := [?]Vec3{{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}, {0, 0, 1}, {2, 2, 2}}
	cases := [?]struct {
		sizes:   []int,
		corners: []u32,
		want:    Build_Error,
	} {
		{{3}, {0, 1, 1}, .Degenerate_Face},
		{{2}, {0, 1}, .Degenerate_Face},
		{{3}, {0, 1, 9}, .Degenerate_Face},
		// Two triangles run the edge 0-1 the same way: one is turned over.
		{{3, 3}, {0, 1, 2, 0, 1, 4}, .Inconsistent},
		// Three triangles on the edge 0-1.
		{{3, 3, 3}, {0, 1, 2, 1, 0, 3, 1, 0, 4}, .Non_Manifold_Edge},
		// Two triangles touching at vertex 0 only, a bow-tie.
		{{3, 3}, {0, 1, 2, 0, 3, 4}, .Non_Manifold_Vertex},
		// Vertex 5 belongs to no face.
		{{3, 3}, {0, 1, 2, 0, 2, 3}, .Unused_Vertex},
	}
	for c, i in cases {
		positions := square[:] if c.want != .Unused_Vertex else square[:]
		if c.want != .Unused_Vertex && c.want != .Non_Manifold_Vertex do positions = square[:5]
		if c.want == .Non_Manifold_Vertex do positions = square[:5]
		m, err := mesh_from_polygons(positions, c.sizes, c.corners)
		testing.expectf(t, err == c.want, "case %d: %v, want %v", i, err, c.want)
		testing.expect(t, len(m.positions) == 0)
	}
}

@(test)
polygons_go_out_as_they_came_in :: proc(t: ^testing.T) {
	m := primitive(.Cylinder, {around = 6, along = 2})
	defer mesh_destroy(&m)
	p := mesh_polygons(&m)
	defer polygons_destroy(&p)
	back, err := mesh_from_polygons(p.positions[:], p.sizes[:], p.corners[:], p.groups[:])
	defer mesh_destroy(&back)
	testing.expect_value(t, err, Build_Error.None)
	testing.expect_value(t, len(back.he_vert), len(m.he_vert))
	testing.expect_value(t, len(back.face_he), len(m.face_he))
	for f in 0 ..< u32(len(m.face_he)) do testing.expect_value(t, face_size(&back, f), face_size(&m, f))
	// Two hexagon caps and twelve quads.
	c := mesh_check(&back)
	testing.expectf(t, c.ngons == 2 && c.quads == 12, "%v", c)
}

@(test)
a_concave_polygon_triangulates_inside_its_outline :: proc(t: ^testing.T) {
	// An L: six corners, one of them reflex, counter-clockwise seen from +Z.
	l := [?]Vec3{{0, 0, 0}, {2, 0, 0}, {2, 1, 0}, {1, 1, 0}, {1, 2, 0}, {0, 2, 0}}
	m, err := mesh_from_polygons(l[:], {6}, {0, 1, 2, 3, 4, 5})
	defer mesh_destroy(&m)
	testing.expect_value(t, err, Build_Error.None)
	tm, tri_face := triangles_of(&m)
	defer geom.mesh_destroy(&tm)
	defer delete(tri_face)
	testing.expect_value(t, len(tri_face), 4)
	// Every triangle faces +Z and their areas add up to the L's 3.
	area: f32
	for k in 0 ..< len(tri_face) {
		a := tm.positions[tm.indices[3 * k]]
		b := tm.positions[tm.indices[3 * k + 1]]
		c := tm.positions[tm.indices[3 * k + 2]]
		z := ((b - a).x * (c - a).y - (b - a).y * (c - a).x) / 2
		testing.expectf(t, z > 0, "triangle %d turned over", k)
		area += z
	}
	testing.expectf(t, math.abs(area - 3) < 1e-5, "area %v", area)
	testing.expectf(t, math.abs(face_area(&m, 0) - 3) < 1e-5, "Newell area %v", face_area(&m, 0))
}

@(test)
deleting_faces_leaves_a_hole_and_drops_lonely_vertices :: proc(t: ^testing.T) {
	m := primitive(.Plane, {across = 2})
	defer mesh_destroy(&m)
	before := mesh_check(&m)
	// Face 3 is a corner square: one of its vertices belongs to it alone.
	r, err := delete_faces(&m, {3})
	defer edit_result_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	after := mesh_check(&m)
	testing.expectf(t, check_ok(after), "%v", after)
	testing.expectf(t, after.faces == 3 && after.vertices == before.vertices - 1 && after.edges == before.edges - 2, "%v then %v", before, after)
	dropped := 0
	for v in r.vert do if v == NONE do dropped += 1
	testing.expect_value(t, dropped, 1)
	for f in 0 ..< 3 do testing.expect_value(t, r.face_from[f], u32(f))
	// The middle of a 3 by 3 plane: the hole leaves a second border inside the first.
	m2 := primitive(.Plane, {across = 3})
	defer mesh_destroy(&m2)
	r2, err2 := delete_faces(&m2, {4})
	defer edit_result_destroy(&r2)
	testing.expect_value(t, err2, Build_Error.None)
	c := mesh_check(&m2)
	testing.expectf(t, check_ok(c) && c.border_edges == 16 && c.faces == 8 && c.euler == 0, "%v", c)
	// Two opposite corners of the 2 by 2 plane's middle would leave a bow-tie: refused.
	m3 := primitive(.Plane, {across = 2})
	defer mesh_destroy(&m3)
	positions := len(m3.positions)
	_, err3 := delete_faces(&m3, {0, 3})
	testing.expect_value(t, err3, Build_Error.Non_Manifold_Vertex)
	testing.expect_value(t, len(m3.positions), positions)
}

@(test)
creases_survive_a_rebuild :: proc(t: ^testing.T) {
	m := primitive(.Cube, {across = 2})
	defer mesh_destroy(&m)
	m.crease[0] = 2.5
	a, b := edge_verts(&m, 0)
	r, err := delete_faces(&m, {0})
	defer edit_result_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	h := find_half_edge(&m, r.vert[a], r.vert[b])
	testing.expect(t, h != NONE)
	testing.expect_value(t, m.crease[edge_of(h)], f32(2.5))
}
