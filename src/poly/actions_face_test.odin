package poly

import "core:math"
import "core:math/linalg"
import "core:testing"

import "../geom"

// The cage's triangles' volume, closed or not, from geom.mesh_check.
@(private = "file")
volume_of :: proc(m: ^Mesh) -> (volume: f64, closed: bool) {
	t := geom.Mesh{positions = make([dynamic]Vec3), normals = make([dynamic]Vec3), indices = make([dynamic]u32)}
	defer geom.mesh_destroy(&t)
	tri_face := make([dynamic]u32)
	defer delete(tri_face)
	triangulate(m, &t, &tri_face)
	r := geom.mesh_check(t)
	return r.volume, r.closed && !r.inverted
}

@(test)
extruding_a_cube_face_adds_four_sides_and_volume :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	v0, _ := volume_of(&m)
	area := face_area(&m, 0)
	r, d, err := extrude_faces(&m, {0}, false, false)
	defer face_ring_destroy(&r)
	defer drag_set_destroy(&d)
	testing.expect_value(t, err, Build_Error.None)
	c := mesh_check(&m)
	testing.expectf(t, check_ok(c) && c.vertices == 12 && c.faces == 10 && c.quads == 10 && c.border_edges == 0, "%v", c)
	testing.expect_value(t, len(r.sides), 4)
	testing.expect_value(t, len(r.faces), 1)
	testing.expect_value(t, len(d.verts), 4)
	// Nothing has moved yet: the volume is the cube's, with four sides of no area (which
	// mesh_check counts as degenerate, so the shape is not called closed until they open).
	v1, _ := volume_of(&m)
	testing.expectf(t, math.abs(v1 - v0) < 1e-5, "%v then %v", v0, v1)
	// Out by 0.5: the volume grows by the face's area times that.
	drag_apply(&m, &d, 0.5)
	v2, closed2 := volume_of(&m)
	testing.expect(t, closed2)
	testing.expectf(t, math.abs(v2 - v0 - f64(area) * 0.5) < 1e-4, "volume %v, want %v", v2, v0 + f64(area) * 0.5)
	testing.expect(t, check_ok(mesh_check(&m)))
}

@(test)
extruding_a_region_keeps_its_inside_edges :: proc(t: ^testing.T) {
	// The top row of a 3 by 3 cube side: three faces in a row, one region.
	m := primitive(.Cube, {across = 3})
	defer mesh_destroy(&m)
	faces := make([dynamic]u32)
	defer delete(faces)
	flat_island(&m, 0, 15, &faces)
	testing.expect_value(t, len(faces), 9)
	before := mesh_check(&m)
	r, d, err := extrude_faces(&m, faces[:], false, true)
	defer face_ring_destroy(&r)
	defer drag_set_destroy(&d)
	testing.expect_value(t, err, Build_Error.None)
	after := mesh_check(&m)
	// The side's 16 points stay where the side's border meets the rest (12 copies) and inside
	// (4 that just move): 12 new points, and a ring of 12 quads.
	testing.expectf(t, check_ok(after) && after.vertices == before.vertices + 12 && after.faces == before.faces + 12, "%v then %v", before, after)
	testing.expect_value(t, len(r.sides), 12)
	// Alt: the sides take a polygroup of their own.
	for f in r.sides do testing.expect_value(t, m.group[f], u16(1))
	// Every moved point goes straight out of the flat side, by as far as the drag says.
	drag_apply(&m, &d, 0.25)
	for v, i in d.verts {
		moved := m.positions[v] - d.base[i]
		testing.expectf(t, math.abs(linalg.length(moved) - 0.25) < 1e-5, "vertex %d moved %v", v, moved)
	}
}

@(test)
insetting_keeps_the_width_even :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	area := face_area(&m, 0)
	side := math.sqrt(area)
	r, d, err := inset_faces(&m, {0}, false)
	defer face_ring_destroy(&r)
	defer drag_set_destroy(&d)
	testing.expect_value(t, err, Build_Error.None)
	c := mesh_check(&m)
	testing.expectf(t, check_ok(c) && c.faces == 10 && c.vertices == 12, "%v", c)
	got := drag_apply(&m, &d, 0.1)
	testing.expect_value(t, got, f32(0.1))
	// A square inset by 0.1 all round is 0.2 narrower each way.
	inner := face_area(&m, r.faces[0])
	want := (side - 0.2) * (side - 0.2)
	testing.expectf(t, math.abs(inner - want) < 1e-4, "inner area %v, want %v", inner, want)
	// The drag stops short of the middle.
	got = drag_apply(&m, &d, 10)
	testing.expectf(t, got < side / 2 && got > side / 2 * 0.9, "inset clamped to %v of half side %v", got, side / 2)
	_, closed := volume_of(&m)
	testing.expect(t, closed)
}

@(test)
insetting_each_face_rings_every_face :: proc(t: ^testing.T) {
	m := primitive(.Plane, {across = 2})
	defer mesh_destroy(&m)
	r, d, err := inset_faces(&m, {0, 1, 2, 3}, true)
	defer face_ring_destroy(&r)
	defer drag_set_destroy(&d)
	testing.expect_value(t, err, Build_Error.None)
	c := mesh_check(&m)
	// Four faces, each with its own four corners and a ring of four quads.
	testing.expectf(t, check_ok(c) && c.faces == 4 + 16 && c.vertices == 9 + 16, "%v", c)
	drag_apply(&m, &d, 0.05)
	testing.expect(t, check_ok(mesh_check(&m)))
}

@(test)
moving_faces_keeps_the_shape_closed :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	v0, _ := volume_of(&m)
	d := move_faces(&m, {0})
	defer drag_set_destroy(&d)
	testing.expect_value(t, len(d.verts), 4)
	drag_apply(&m, &d, 0.3)
	v1, closed := volume_of(&m)
	testing.expect(t, closed)
	testing.expectf(t, v1 > v0, "moving a face out grows the cube: %v then %v", v0, v1)
}

@(test)
deleting_with_alt_closes_the_hole_with_one_face :: proc(t: ^testing.T) {
	m := primitive(.Cube, {across = 2})
	defer mesh_destroy(&m)
	faces := make([dynamic]u32)
	defer delete(faces)
	flat_island(&m, 0, 15, &faces)
	testing.expect_value(t, len(faces), 4)
	before := mesh_check(&m)
	r, err := delete_or_dissolve(&m, faces[:], true)
	defer edit_result_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	c := mesh_check(&m)
	// The side's four quads become one octagon; its middle point goes.
	testing.expectf(t, check_ok(c) && c.faces == before.faces - 3 && c.ngons == 1 && c.border_edges == 0 && c.vertices == before.vertices - 1, "%v then %v", before, c)
	_, closed := volume_of(&m)
	testing.expect(t, closed)
	// A band all round a cube leaves two holes: one face cannot close them.
	m2 := primitive(.Cube)
	defer mesh_destroy(&m2)
	band := make([dynamic]u32)
	defer delete(band)
	face_loop(&m2, 0, &band)
	testing.expect_value(t, len(band), 4)
	_, err2 := delete_or_dissolve(&m2, band[:], true)
	testing.expect(t, err2 != .None)
	testing.expect_value(t, len(m2.face_he), 6)
}

@(test)
flipping_a_whole_island_turns_it_inside_out :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	all := make([dynamic]u32)
	defer delete(all)
	island(&m, 0, &all)
	r, err := flip_faces(&m, all[:])
	defer edit_result_destroy(&r)
	testing.expect_value(t, err, Build_Error.None)
	v, _ := volume_of(&m)
	testing.expectf(t, v < 0, "a flipped cube has a negative volume, %v", v)
	// Part of a piece cannot turn over alone.
	m2 := primitive(.Cube)
	defer mesh_destroy(&m2)
	_, err2 := flip_faces(&m2, {0})
	testing.expect_value(t, err2, Build_Error.Inconsistent)
	testing.expect_value(t, len(m2.face_he), 6)
}
