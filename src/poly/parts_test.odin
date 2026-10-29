package poly

import "core:math/linalg"
import "core:testing"

// Two cubes in one cage, the second `apart` along x.
@(private = "file")
two_cubes :: proc(apart: f32) -> Mesh {
	m := primitive(.Cube)
	e := edit_begin(&m, context.temp_allocator)
	n := u32(len(m.positions))
	for p in m.positions do edit_vertex(&e, p + {apart, 0, 0})
	faces := len(e.faces)
	for i in 0 ..< faces {
		verts := make([dynamic]u32, context.temp_allocator)
		for v in e.faces[i].verts do append(&verts, v + n)
		edit_face(&e, verts[:], 1)
	}
	r, err := edit_end(&m, &e)
	assert(err == .None)
	edit_result_destroy(&r)
	return m
}

// The cage face whose normal is nearest `way`, among faces from..<to.
@(private = "file")
face_facing :: proc(m: ^Mesh, way: Vec3, from, to: u32) -> u32 {
	best, best_dot := NONE, f32(-2)
	for f in from ..< to do if d := linalg.dot(face_normal(m, f), way); d > best_dot do best, best_dot = f, d
	return best
}

@(test)
align_sets_a_part_on_another :: proc(t: ^testing.T) {
	// The first cube's +x face put on the second cube's top: the first then sits on the
	// second, face to face, centre over centre.
	m := two_cubes(3)
	defer mesh_destroy(&m)
	part := make([dynamic]u32, context.temp_allocator)
	island(&m, 0, &part)
	testing.expect_value(t, len(part), 6)
	from := face_facing(&m, {1, 0, 0}, 0, 6)
	to := face_facing(&m, {0, 1, 0}, 6, 12)
	top := face_center(&m, to)
	testing.expect(t, align_part(&m, part[:], from, to, false, 0))
	testing.expect(t, linalg.length(face_center(&m, from) - top) < 1e-5)
	testing.expect(t, linalg.dot(face_normal(&m, from), face_normal(&m, to)) < -0.9999)
	lowest := max(f32)
	for v in face_set_verts(&m, part[:], context.temp_allocator) do lowest = min(lowest, m.positions[v].y)
	testing.expect(t, abs(lowest - top.y) < 1e-5)
	// The joined faces' edges run together: every corner of one lies on a corner of the other.
	w := face_walk(&m, from)
	for h in face_walk_next(&w) {
		p := m.positions[m.he_vert[h]]
		near := max(f32)
		v := face_walk(&m, to)
		for g in face_walk_next(&v) do near = min(near, linalg.length(m.positions[m.he_vert[g]] - p))
		testing.expect(t, near < 1e-4)
	}
	// Flipped, it faces the same way and passes into the other; a part cannot join itself.
	testing.expect(t, align_part(&m, part[:], from, to, true, 0))
	testing.expect(t, linalg.dot(face_normal(&m, from), face_normal(&m, to)) > 0.9999)
	testing.expect(t, !align_part(&m, part[:], from, part[1], false, 0))
}

@(test)
align_turns_a_step_at_a_time :: proc(t: ^testing.T) {
	// A turn moves the part's edge onto the next edge of the face it is joined to: four
	// turns of a quad bring it back.
	m := two_cubes(3)
	defer mesh_destroy(&m)
	part := make([dynamic]u32, context.temp_allocator)
	island(&m, 0, &part)
	from := face_facing(&m, {1, 0, 0}, 0, 6)
	to := face_facing(&m, {0, 1, 0}, 6, 12)
	testing.expect(t, align_part(&m, part[:], from, to, false, 0))
	first := m.face_he[from]
	way :: proc(m: ^Mesh, h: u32) -> Vec3 {return linalg.normalize(m.positions[he_tip(m, h)] - m.positions[m.he_vert[h]])}
	start := way(&m, first)
	testing.expect(t, align_part(&m, part[:], from, to, false, 1))
	turned := way(&m, first)
	testing.expect(t, abs(linalg.dot(start, turned)) < 1e-4)
	for _ in 0 ..< 3 do testing.expect(t, align_part(&m, part[:], from, to, false, 1))
	testing.expect(t, linalg.dot(start, way(&m, first)) > 0.9999)
}

@(test)
spine_steps_follow_the_path :: proc(t: ^testing.T) {
	// Straight up a unit: four even steps that do not turn.
	up := []Vec3{{0, 0, 0}, {0, 1, 0}}
	steps := spine_steps(up, nil, {0, 0, 0}, {0, 1, 0}, 0.25)
	defer delete(steps)
	testing.expect_value(t, len(steps), 4)
	for s, k in steps {
		testing.expect(t, linalg.length(s.at - {0, 0.25 * f32(k + 1), 0}) < 1e-5)
		testing.expect(t, linalg.length(spine_point(s, {1, 0, 0}) - (s.at + {1, 0, 0})) < 1e-5)
	}
	// Up, then off along x: the last step faces along x, and the scale follows the path's.
	bend := []Vec3{{0, 0, 0}, {0, 1, 0}, {1, 1, 0}}
	scale := []f32{1, 1, 0.5}
	turned := spine_steps(bend, scale, {0, 0, 0}, {0, 1, 0}, 0.25)
	defer delete(turned)
	testing.expect_value(t, len(turned), 8)
	last := turned[len(turned) - 1]
	testing.expect(t, linalg.length(linalg.quaternion_mul_vector3(last.turn, Vec3{0, 1, 0}) - {1, 0, 0}) < 1e-4)
	testing.expect(t, abs(last.scale - 0.5) < 1e-5)
	testing.expect(t, linalg.length(last.at - {1, 1, 0}) < 1e-5)
}

@(test)
spine_arc_is_a_circle :: proc(t: ^testing.T) {
	// From the origin up, ending at (1, 1, 0): a quarter of the unit circle about (1, 0, 0).
	arc := spine_arc({0, 0, 0}, {0, 1, 0}, {1, 1, 0}, 8)
	defer delete(arc)
	testing.expect_value(t, len(arc), 9)
	for p in arc do testing.expect(t, abs(linalg.length(p - {1, 0, 0}) - 1) < 1e-4)
	testing.expect(t, linalg.length(arc[8] - {1, 1, 0}) < 1e-4)
	// Straight ahead is a line.
	line := spine_arc({0, 0, 0}, {0, 1, 0}, {0, 2, 0}, 4)
	defer delete(line)
	testing.expect(t, linalg.length(line[2] - {0, 1, 0}) < 1e-5)
}

@(test)
spine_grows_a_closed_arm :: proc(t: ^testing.T) {
	// The cube's top face along three steps up and over: a closed cage of 6 + 4 × 3
	// faces, its end face where the last step put it, the same both times it is built.
	build :: proc() -> Mesh {
		m := primitive(.Cube)
		top := face_facing(&m, {0, 1, 0}, 0, 6)
		c, n := face_center(&m, top), face_normal(&m, top)
		path := []Vec3{c, c + n, c + n + {1, 0, 0}}
		steps := spine_steps(path, nil, c, n, 0.7, context.temp_allocator)
		regions := [][]u32{{top}}
		all := [][]Spine_Step{steps}
		ends, err := spine_faces(&m, regions, all)
		defer delete(ends)
		assert(err == .None && len(steps) == 3 && len(ends) == 1)
		return m
	}
	a := build()
	defer mesh_destroy(&a)
	c := mesh_check(&a)
	testing.expect(t, check_ok(c))
	testing.expect_value(t, c.border_edges, 0)
	testing.expect_value(t, c.faces, 6 + 4 * 3)
	b := build()
	defer mesh_destroy(&b)
	testing.expect_value(t, len(a.positions), len(b.positions))
	for p, i in a.positions do testing.expect_value(t, p, b.positions[i])
	// Regions that share a point are refused, leaving the cage as it was.
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	steps := spine_steps([]Vec3{{0, 0, 0}, {0, 1, 0}}, nil, {}, {0, 1, 0}, 0.5, context.temp_allocator)
	up, side := face_facing(&m, {0, 1, 0}, 0, 6), face_facing(&m, {1, 0, 0}, 0, 6)
	_, err := spine_faces(&m, [][]u32{{up}, {side}}, [][]Spine_Step{steps, steps})
	testing.expect_value(t, err, Build_Error.Unsupported)
	testing.expect_value(t, len(m.face_he), 6)
}

@(test)
mirror_faces_by_finds_the_image :: proc(t: ^testing.T) {
	m := primitive(.Cube)
	defer mesh_destroy(&m)
	right := face_facing(&m, {1, 0, 0}, 0, 6)
	left := face_facing(&m, {-1, 0, 0}, 0, 6)
	got, ok := mirror_faces_by(&m, {right}, {-1, 1, 1}, mirror_slack(&m))
	defer delete(got)
	testing.expect(t, ok && len(got) == 1 && got[0] == left)
}

@(test)
spine_steps_mirror :: proc(t: ^testing.T) {
	// A bent path's step and its image across x and across x and y: each puts a point's
	// image where the image of the step puts the point.
	steps := spine_steps([]Vec3{{0.2, 0, 0}, {0.2, 1, 0}, {1, 1.3, 0.4}}, nil, {0.2, 0, 0}, {0, 1, 0}, 0.3, context.temp_allocator)
	p := Vec3{0.5, 0.1, -0.3}
	for sign in ([2]Vec3{{-1, 1, 1}, {-1, -1, 1}}) {
		for s in steps {
			img := spine_step_mirror(s, sign)
			testing.expect(t, linalg.length(spine_point(img, p * sign) - spine_point(s, p) * sign) < 1e-4)
		}
	}
}
