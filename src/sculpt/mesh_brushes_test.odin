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
