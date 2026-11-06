package poly

import "core:math"
import "core:testing"

import "../geom"

@(private = "file")
solid_volume :: proc(m: ^Mesh) -> (volume: f64, closed: bool) {
	t := geom.Mesh{positions = make([dynamic]Vec3), normals = make([dynamic]Vec3), indices = make([dynamic]u32)}
	defer geom.mesh_destroy(&t)
	tri_face := make([dynamic]u32)
	defer delete(tri_face)
	triangulate(m, &t, &tri_face)
	r := geom.mesh_check(t)
	return r.volume, r.closed && !r.inverted
}

@(private = "file")
moved :: proc(x, y, z: f32, s: f32 = 1) -> matrix[4, 4]f32 {
	return matrix[4, 4]f32{s, 0, 0, x, 0, s, 0, y, 0, 0, s, z, 0, 0, 0, 1}
}

// Two cubes overlapping by a corner: each boolean is closed with the volume the overlap
// says, and the union and subtract keep the cubes' flat faces as quads or simple polygons.
@(test)
booleans_of_two_cubes_have_the_right_volume :: proc(t: ^testing.T) {
	a := primitive(.Cube)
	defer mesh_destroy(&a)
	b := primitive(.Cube)
	defer mesh_destroy(&b)
	side := f64(a.positions[0].x) * 2
	side = abs(side)
	shift := f32(0.5)
	v := side * side * side
	o := (side - f64(shift)) * (side - f64(shift)) * (side - f64(shift))
	want := [Boolean_Op]f64 {
		.Union     = 2 * v - o,
		.Subtract  = v - o,
		.Intersect = o,
	}
	for op in Boolean_Op {
		r, err := cage_boolean(&a, &b, moved(shift, shift, shift), op)
		defer mesh_destroy(&r)
		testing.expectf(t, err == .None, "%v: %v", op, err)
		c := mesh_check(&r)
		testing.expectf(t, check_ok(c) && c.border_edges == 0, "%v: %v", op, c)
		vol, closed := solid_volume(&r)
		testing.expectf(t, closed && math.abs(vol - want[op]) < 1e-4, "%v: volume %v, want %v (closed %v)", op, vol, want[op], closed)
		// The intersection is a box: six faces, eight corners.
		if op == .Intersect do testing.expectf(t, c.faces == 6 && c.vertices == 8, "%v", c)
	}
}

// A thin box pushed right through a cube and subtracted leaves a cube with a square hole:
// closed, one handle (Euler characteristic 0), and the volume less the hole's.
@(test)
subtracting_a_box_through_a_cube_makes_a_hole :: proc(t: ^testing.T) {
	a := primitive(.Cube)
	defer mesh_destroy(&a)
	b := primitive(.Cube)
	defer mesh_destroy(&b)
	side := abs(f64(a.positions[0].x)) * 2
	// The cutter: a quarter as wide, three times as tall, through the middle.
	cut := matrix[4, 4]f32{0.25, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0.25, 0, 0, 0, 0, 1}
	r, err := cage_boolean(&a, &b, cut, .Subtract)
	defer mesh_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	c := mesh_check(&r)
	testing.expectf(t, check_ok(c) && c.border_edges == 0 && c.euler == 0, "%v", c)
	vol, closed := solid_volume(&r)
	hole := (side * 0.25) * (side * 0.25) * side
	testing.expectf(t, closed && math.abs(vol - (side * side * side - hole)) < 1e-4, "volume %v", vol)
	// The cut's faces got a polygroup of their own and the seam is creased.
	creased, _ := crease_count(&r)
	testing.expectf(t, creased >= 8, "%d creased", creased)
}

// An open cage has no inside, so a boolean with it is refused.
@(test)
a_boolean_with_an_open_cage_is_refused :: proc(t: ^testing.T) {
	a := primitive(.Cube)
	defer mesh_destroy(&a)
	b := primitive(.Plane)
	defer mesh_destroy(&b)
	_, err := cage_boolean(&a, &b, moved(0, 0, 0), .Union)
	testing.expect_value(t, err, Build_Error.Non_Manifold_Edge)
}

// A quad sphere's faces are bent; subtracting it from a cube's corner still gives a closed
// cage, smaller than the cube.
@(test)
subtracting_a_sphere_from_a_cube :: proc(t: ^testing.T) {
	a := primitive(.Cube)
	defer mesh_destroy(&a)
	b := primitive(.Sphere)
	defer mesh_destroy(&b)
	v0, _ := solid_volume(&a)
	r, err := cage_boolean(&a, &b, moved(0.5, 0.5, 0.5, 0.8), .Subtract)
	defer mesh_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	c := mesh_check(&r)
	testing.expectf(t, check_ok(c) && c.border_edges == 0, "%v", c)
	vol, closed := solid_volume(&r)
	testing.expectf(t, closed && vol < v0 && vol > v0 * 0.5, "volume %v of %v", vol, v0)
}

// A cylinder (n-gon caps) drilled right through a cube: closed, one handle.
@(test)
drilling_a_cylinder_through_a_cube :: proc(t: ^testing.T) {
	a := primitive(.Cube)
	defer mesh_destroy(&a)
	b := primitive(.Cylinder)
	defer mesh_destroy(&b)
	cut := matrix[4, 4]f32{0.4, 0, 0, 0.05, 0, 3, 0, 0, 0, 0, 0.4, -0.03, 0, 0, 0, 1}
	r, err := cage_boolean(&a, &b, cut, .Subtract)
	defer mesh_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	c := mesh_check(&r)
	testing.expectf(t, check_ok(c) && c.border_edges == 0 && c.euler == 0, "%v", c)
	_, closed := solid_volume(&r)
	testing.expect(t, closed)
}

// Cubes sharing face planes (shifted along one axis only): the shared planes are decided
// by which way the faces look, so union, subtract and intersect all close with the right
// volume, and a mirroring transform (a negative scale) changes nothing.
@(test)
booleans_of_cubes_on_shared_planes :: proc(t: ^testing.T) {
	a := primitive(.Cube)
	defer mesh_destroy(&a)
	b := primitive(.Cube)
	defer mesh_destroy(&b)
	side := abs(f64(a.positions[0].x)) * 2
	half := f32(side / 2)
	v := side * side * side
	want := [Boolean_Op]f64 {
		.Union     = 1.5 * v,
		.Subtract  = 0.5 * v,
		.Intersect = 0.5 * v,
	}
	shifts := [2]matrix[4, 4]f32{moved(half, 0, 0), {-1, 0, 0, half, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}}
	for to in shifts do for op in Boolean_Op {
		r, err := cage_boolean(&a, &b, to, op)
		defer mesh_destroy(&r)
		testing.expectf(t, err == .None, "%v: %v", op, err)
		c := mesh_check(&r)
		testing.expectf(t, check_ok(c) && c.border_edges == 0 && c.euler == 2, "%v: %v", op, c)
		vol, closed := solid_volume(&r)
		testing.expectf(t, closed && math.abs(vol - want[op]) < 1e-4, "%v: volume %v, want %v", op, vol, want[op])
	}
}

// Two dense quad spheres overlapping: every boolean closes as one shell, and the faces
// far from the seam come through whole (far fewer faces than the two spheres had pieces).
@(test)
booleans_of_dense_spheres_close :: proc(t: ^testing.T) {
	a := primitive(.Sphere, {across = 8})
	defer mesh_destroy(&a)
	b := primitive(.Sphere, {across = 8})
	defer mesh_destroy(&b)
	v0, _ := solid_volume(&a)
	for op in Boolean_Op {
		r, err := cage_boolean(&a, &b, moved(0.4, 0.3, 0.2), op)
		defer mesh_destroy(&r)
		testing.expectf(t, err == .None, "%v: %v", op, err)
		c := mesh_check(&r)
		testing.expectf(t, check_ok(c) && c.border_edges == 0 && c.euler == 2 && c.faces < 4 * len(a.face_he), "%v: %v", op, c)
		vol, closed := solid_volume(&r)
		testing.expectf(t, closed && vol > 0 && (op != .Union || vol > v0) && (op == .Union || vol < v0), "%v: volume %v of %v", op, vol, v0)
	}
}
