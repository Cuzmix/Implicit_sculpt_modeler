package sculpt

import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

@(private = "file")
ball :: proc(s: ^Sculptor, m: ^geom.Mesh, pool: ^jobs.Pool = nil) -> []Vec3 {
	m^ = geom.icosphere(5)
	sculptor_init(s, m, pool, 64)
	return slice.clone(m.positions[:], context.temp_allocator)
}

@(private = "file")
nearest_to :: proc(ps: []Vec3, p: Vec3) -> int {
	best, at := max(f32), 0
	for q, i in ps {
		d := linalg.length2(q - p)
		if d < best do best, at = d, i
	}
	return at
}

// Rotate is Grab turning what it holds about the press with no drag: the middle stays,
// a vertex off it goes round it, and the rim and beyond do not move; one undo step.
@(test)
rotate_turns_about_the_press :: proc(t: ^testing.T) {
	m: geom.Mesh
	s: Sculptor
	before := ball(&s, &m)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	top := Vec3{0, 0, 1}
	sculptor_stroke_begin(&s)
	held := sculptor_grab_begin(&s, {kind = .Rotate, radius = 0.5, strength = 0.5}, top)
	testing.expect(t, held > 0, "rotate held nothing")
	_ = sculptor_grab_move(&s, {}, {axis = top, angle = math.PI / 2})
	sculptor_grab_end(&s)
	testing.expect(t, sculptor_stroke_end(&s), "the turn was not an undo step")
	side := nearest_to(before, linalg.normalize(Vec3{0.15, 0, 1}))
	moved := m.positions[side] - before[side]
	// A quarter turn about +z at weight w takes +x toward +y.
	testing.expectf(t, moved.y > 0.03 && abs(moved.z) < 0.01, "the vertex beside the press moved %v", moved)
	testing.expectf(t, abs(linalg.length(m.positions[side].xy) - linalg.length(before[side].xy)) < 1e-3, "it left its circle round the press")
	for p, i in m.positions do if linalg.length(before[i] - top) >= 0.5 do testing.expect_value(t, p, before[i])
	testing.expect(t, sculptor_undo(&s))
	testing.expect(t, slice.equal(m.positions[:], before), "undo left the turn")
}

// Thumb carries the surface along the stroke and presses it toward the plane under it,
// moving nothing outside the brush; serial and parallel agree bit for bit.
@(test)
thumb_smears_along_the_stroke :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	result: [2][]Vec3
	for p, i in ([2]^jobs.Pool{nil, &pool}) {
		m: geom.Mesh
		s: Sculptor
		before := ball(&s, &m, p)
		at := Vec3{0, 0, 1}
		sculptor_stroke_begin(&s)
		moved := apply_dab(&s, {kind = .Thumb, radius = 0.4, strength = 1, stroke_dir = {0.1, 0, 0}}, at)
		_ = sculptor_stroke_end(&s)
		testing.expect(t, moved > 0, "thumb moved nothing")
		mid := nearest_to(before, at)
		step := m.positions[mid] - before[mid]
		testing.expectf(t, step.x > 0.1 && abs(step.y) < 1e-3, "the middle moved %v", step)
		// Pressed flat: a vertex on the rounded side comes nearer the plane z = its top's.
		side := nearest_to(before, linalg.normalize(Vec3{0, 0.2, 1}))
		testing.expectf(t, m.positions[side].z > before[side].z, "the side was not pressed toward the plane: %v -> %v", before[side].z, m.positions[side].z)
		for q, k in m.positions do if linalg.length(before[k] - at) >= 0.4 do testing.expect_value(t, q, before[k])
		// No stroke direction yet, no smear.
		testing.expect(t, apply_dab(&s, {kind = .Thumb, radius = 0.4, strength = 1}, at) == 0)
		result[i] = slice.clone(m.positions[:], context.temp_allocator)
		sculptor_destroy(&s)
		geom.mesh_destroy(&m)
	}
	testing.expect(t, slice.equal(result[0], result[1]), "parallel thumb differs from serial")
}

// Pose bends what the press reaches along the surface about a joint a radius away: on a
// ball pressed at its top with a radius of 0.8, the cap turns about the middle of the
// ring 0.8 down the surface, keeping its shape (each held vertex keeps its distance from
// the joint), and the far side stays. Edge paths run a little longer than the arc, so
// the ring sits a little nearer the press.
@(test)
pose_bends_about_its_joint :: proc(t: ^testing.T) {
	m: geom.Mesh
	s: Sculptor
	before := ball(&s, &m)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	top := Vec3{0, 0, 1}
	sculptor_stroke_begin(&s)
	held := sculptor_grab_begin(&s, {kind = .Pose, radius = 0.8, strength = 0.5}, top)
	testing.expect(t, held > 0, "pose held nothing")
	pivot := s.grab.pivots[0]
	testing.expectf(t, abs(pivot.x) < 0.02 && abs(pivot.y) < 0.02 && abs(pivot.z - math.cos(f32(0.8))) < 0.06, "the joint is at %v", pivot)
	_ = sculptor_grab_move(&s, {0.4, 0, 0})
	sculptor_grab_end(&s)
	testing.expect(t, sculptor_stroke_end(&s), "the pose was not an undo step")
	tip := nearest_to(before, top)
	moved := m.positions[tip] - before[tip]
	testing.expectf(t, moved.x > 0.1 && moved.z < 0, "the tip moved %v", moved)
	testing.expectf(t, abs(linalg.length(m.positions[tip] - pivot) - linalg.length(before[tip] - pivot)) < 1e-3, "the tip did not keep its distance from the joint")
	for q, i in m.positions do if before[i].z < 0 do testing.expect_value(t, q, before[i])
	testing.expect(t, sculptor_undo(&s))
	testing.expect(t, slice.equal(m.positions[:], before), "undo left the pose")
}

// On a finger-like ellipsoid three times as tall as wide, Pose pressed on the tip with a
// radius of half its height swings the tip sideways about a joint halfway down, keeping
// the tip's length from the joint, and leaves the lower half where it was.
@(test)
pose_swings_a_finger :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	for &p in m.positions do p.z *= 3
	geom.mesh_recompute_normals(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	before := slice.clone(m.positions[:], context.temp_allocator)
	tip := Vec3{0, 0, 3}
	sculptor_stroke_begin(&s)
	_ = sculptor_grab_begin(&s, {kind = .Pose, radius = 3, strength = 0.5}, tip)
	pivot := s.grab.pivots[0]
	testing.expectf(t, abs(pivot.x) < 0.05 && pivot.z > -0.3 && pivot.z < 0.6, "the joint is at %v", pivot)
	_ = sculptor_grab_move(&s, {1, 0, 0})
	sculptor_grab_end(&s)
	_ = sculptor_stroke_end(&s)
	at := nearest_to(before, tip)
	testing.expectf(t, m.positions[at].x > 0.6, "the tip went to %v", m.positions[at])
	testing.expectf(t, abs(linalg.length(m.positions[at] - pivot) - linalg.length(before[at] - pivot)) < 1e-3, "the tip did not keep its length from the joint")
	for q, i in m.positions do if before[i].z < -1.2 do testing.expect_value(t, q, before[i])
}

// A flat sheet 2 by 2 in z = 0, n vertices a side, facing +z: an open edge all round.
@(private = "file")
sheet :: proc(n: int) -> (m: geom.Mesh) {
	m.positions = make([dynamic]Vec3, 0, n * n)
	m.normals = make([dynamic]Vec3, 0, n * n)
	m.indices = make([dynamic]u32, 0, (n - 1) * (n - 1) * 6)
	for j in 0 ..< n do for i in 0 ..< n {
		append(&m.positions, Vec3{-1 + 2 * f32(i) / f32(n - 1), -1 + 2 * f32(j) / f32(n - 1), 0})
		append(&m.normals, Vec3{0, 0, 1})
	}
	for j in 0 ..< n - 1 do for i in 0 ..< n - 1 {
		a := u32(j * n + i)
		b, c, d := a + 1, a + u32(n), a + u32(n) + 1
		append(&m.indices, a, b, d, a, d, c)
	}
	return
}

// Boundary pressed beside a sheet's edge picks up the edge, not the press: the edge's
// middle takes the whole drag, the edge further along it less, the sheet a radius in from
// it nothing; serial and parallel agree bit for bit, and undo puts it back. On a closed
// ball it holds nothing.
@(test)
boundary_drags_the_open_edge :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	result: [2][]Vec3
	for p, i in ([2]^jobs.Pool{nil, &pool}) {
		m := sheet(81)
		s: Sculptor
		sculptor_init(&s, &m, p, 64)
		before := slice.clone(m.positions[:], context.temp_allocator)
		sculptor_stroke_begin(&s)
		held := sculptor_grab_begin(&s, {kind = .Boundary, radius = 0.3, strength = 0.5}, {0, -0.85, 0})
		testing.expect(t, held > 0, "boundary held nothing")
		_ = sculptor_grab_move(&s, {0, 0, 0.2})
		sculptor_grab_end(&s)
		testing.expect(t, sculptor_stroke_end(&s), "the drag was not an undo step")
		lift :: proc(m: ^geom.Mesh, before: []Vec3, at: Vec3) -> f32 {
			k := nearest_to(before, at)
			return m.positions[k].z - before[k].z
		}
		edge, along, far_along := lift(&m, before, {0, -1, 0}), lift(&m, before, {0.4, -1, 0}), lift(&m, before, {0.65, -1, 0})
		testing.expectf(t, abs(edge - 0.2) < 1e-4, "the edge's middle rose %v", edge)
		testing.expectf(t, abs(lift(&m, before, {0.25, -1, 0}) - 0.2) < 1e-4, "the edge a little along rose %v", lift(&m, before, {0.25, -1, 0}))
		testing.expectf(t, along > 0.01 && along < 0.2 && far_along == 0, "along the edge it rose %v then %v", along, far_along)
		// The press lies 0.15 in from the edge; the edge, not the press, takes the most.
		testing.expectf(t, lift(&m, before, {0, -0.85, 0}) < edge, "the press rose as much as the edge")
		for q, k in m.positions do if before[k].y > -0.69 do testing.expect_value(t, q, before[k])
		result[i] = slice.clone(m.positions[:], context.temp_allocator)
		testing.expect(t, sculptor_undo(&s))
		testing.expect(t, slice.equal(m.positions[:], before), "undo left the drag")
		sculptor_destroy(&s)
		geom.mesh_destroy(&m)
	}
	testing.expect(t, slice.equal(result[0], result[1]), "parallel boundary differs from serial")
	m: geom.Mesh
	s: Sculptor
	_ = ball(&s, &m)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	sculptor_stroke_begin(&s)
	testing.expect(t, sculptor_grab_begin(&s, {kind = .Boundary, radius = 0.3, strength = 0.5}, {0, 0, 1}) == 0, "a closed ball has an open edge")
	testing.expect(t, sculptor_grab_move(&s, {0, 0, 0.2}) == 0)
	sculptor_grab_end(&s)
	_ = sculptor_stroke_end(&s)
}
