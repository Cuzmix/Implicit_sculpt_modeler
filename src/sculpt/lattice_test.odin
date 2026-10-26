package sculpt

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

@(private = "file")
Ball :: struct {
	mesh:     geom.Mesh,
	sculptor: Sculptor,
}

// A sphere with a lattice of `points` a side noted round it, a little larger.
@(private = "file")
ball_make :: proc(pool: ^jobs.Pool = nil) -> ^Ball {
	b := new(Ball)
	b.mesh = geom.icosphere(3)
	sculptor_init(&b.sculptor, &b.mesh, pool, 64)
	sculptor_lattice_rest(&b.sculptor, -1.1, 1.1)
	return b
}

@(private = "file")
ball_free :: proc(b: ^Ball) {
	sculptor_destroy(&b.sculptor)
	geom.mesh_destroy(&b.mesh)
	free(b)
}

// Moves one point by `offset` as a pose of its own, one undo step.
@(private = "file")
pull :: proc(t: ^testing.T, s: ^Sculptor, points: int, point: [3]int, offset: Vec3) {
	testing.expect(t, sculptor_pose_begin(s))
	sculptor_pose_apply(s, {kind = .Lattice, lattice = {points = points, point = point, offset = offset}})
	testing.expect(t, sculptor_pose_end(s))
}

// Every point moved alike moves the whole surface alike: the weights add up to 1.
@(test)
lattice_all_points_move_everything :: proc(t: ^testing.T) {
	for points in 2 ..= LATTICE_MAX_POINTS {
		b := ball_make()
		defer ball_free(b)
		before := slice.clone(b.mesh.positions[:], context.temp_allocator)
		for i in 0 ..< points do for j in 0 ..< points do for k in 0 ..< points {
			pull(t, &b.sculptor, points, {i, j, k}, {0.1, -0.2, 0.05})
		}
		worst: f32
		for a, v in before do worst = max(worst, linalg.length(b.mesh.positions[v] - (a + Vec3{0.1, -0.2, 0.05})))
		testing.expectf(t, worst < 1e-5, "%d a side: %v off", points, worst)
	}
}

// Drags add up: one point then another, in either order, or one point twice, end where
// one deformation by all the moves does, and the cage's corner pulls its corner most.
@(test)
lattice_drags_add_up :: proc(t: ^testing.T) {
	runs: [3][]Vec3
	for &run, r in runs {
		b := ball_make()
		defer ball_free(b)
		s := &b.sculptor
		switch r {
		case 0:
			pull(t, s, 3, {2, 2, 2}, {0.3, 0, 0})
			pull(t, s, 3, {0, 1, 2}, {0, 0.2, 0})
		case 1:
			pull(t, s, 3, {0, 1, 2}, {0, 0.2, 0})
			pull(t, s, 3, {2, 2, 2}, {0.1, 0, 0})
			pull(t, s, 3, {2, 2, 2}, {0.2, 0, 0})
		case 2:
			testing.expect(t, sculptor_pose_begin(s))
			sculptor_pose_apply(s, {kind = .Lattice, lattice = {points = 3, point = {2, 2, 2}, offset = {0.3, 0, 0}}})
			sculptor_pose_apply(s, {kind = .Lattice, lattice = {points = 3, point = {0, 1, 2}, offset = {0, 0.2, 0}}})
			// The last apply alone counts within one pose: from where it began.
			testing.expect(t, sculptor_pose_end(s))
		}
		run = slice.clone(b.mesh.positions[:], context.temp_allocator)
	}
	worst: f32
	for p, v in runs[0] do worst = max(worst, linalg.length(p - runs[1][v]))
	testing.expectf(t, worst < 1e-5, "the order of the drags moved the surface %v", worst)
	testing.expect(t, !slice.equal(runs[0], runs[2]))
}

// A point pulls the vertices near its corner of the cage, not the far side; masked
// vertices stay; undo puts it back.
@(test)
lattice_corner_pulls_its_corner :: proc(t: ^testing.T) {
	b := ball_make()
	defer ball_free(b)
	s := &b.sculptor
	values := make([]u8, len(b.mesh.positions), context.temp_allocator)
	for p, v in b.mesh.positions do values[v] = 255 if p.z < -0.5 else 0
	testing.expect(t, sculptor_mask_values(s, values, .Replace))
	before := slice.clone(b.mesh.positions[:], context.temp_allocator)
	pull(t, s, 2, {1, 1, 1}, {0.5, 0.5, 0.5})
	near, far: f32
	for a, v in before {
		d := linalg.length(b.mesh.positions[v] - a)
		if values[v] == 255 do testing.expect(t, d == 0)
		if a.x > 0.5 && a.y > 0.5 && a.z > 0.5 do near = max(near, d)
		if a.x < -0.5 && a.y < -0.5 do far = max(far, d)
	}
	testing.expectf(t, near > 0.2 && far < 0.05, "the near corner moved %v, the far side %v", near, far)
	testing.expect(t, sculptor_undo(s))
	testing.expect(t, slice.equal(b.mesh.positions[:], before))
}

// Without noted places a lattice pose moves nothing; threads match one thread.
@(test)
lattice_needs_its_places_and_is_deterministic :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	runs: [2][]Vec3
	for &run, k in runs {
		b := ball_make(&pool if k == 1 else nil)
		defer ball_free(b)
		pull(t, &b.sculptor, 4, {3, 0, 1}, {0.2, 0.1, -0.3})
		run = slice.clone(b.mesh.positions[:], context.temp_allocator)
	}
	testing.expect(t, slice.equal(runs[0], runs[1]))
	b := ball_make()
	defer ball_free(b)
	sculptor_lattice_clear(&b.sculptor)
	testing.expect(t, !sculptor_lattice_ready(&b.sculptor))
	before := slice.clone(b.mesh.positions[:], context.temp_allocator)
	testing.expect(t, sculptor_pose_begin(&b.sculptor))
	sculptor_pose_apply(&b.sculptor, {kind = .Lattice, lattice = {points = 2, point = {1, 1, 1}, offset = {1, 1, 1}}})
	testing.expect(t, slice.equal(b.mesh.positions[:], before))
	sculptor_pose_cancel(&b.sculptor)
}
