package geom

import "core:math/linalg"
import "core:math/rand"
import "core:testing"

import "../jobs"

@(private = "file")
Closest_Run :: struct {
	b:      Bvh,
	m:      Mesh,
	points: []Vec3,
	tris:   []u32,
	barys:  [][3]f32,
	dists:  []f32,
}

@(private = "file")
closest_points :: proc(n: int, seed: u64) -> []Vec3 {
	r := rand.create(seed)
	context.random_generator = rand.default_random_generator(&r)
	points := make([]Vec3, n)
	for &p in points do p = {rand.float32_range(-1.6, 1.6), rand.float32_range(-1.6, 1.6), rand.float32_range(-1.6, 1.6)}
	return points
}

@(test)
bvh_closest_matches_every_triangle_tried :: proc(t: ^testing.T) {
	m := geodesic_sphere(12)
	defer mesh_destroy(&m)
	b := bvh_build_morton(m)
	defer bvh_destroy(&b)
	points := closest_points(300, 3)
	defer delete(points)
	// A hint (here the last point's answer, often far off) changes where the search
	// starts, never what it finds.
	hint := BVH_NONE
	for p in points {
		tri, bary, dist, ok := bvh_closest(b, m, p, 10)
		testing.expect(t, ok, "every point is within reach")
		brute := max(f32)
		for k := 0; k < len(m.indices); k += 3 {
			q, _ := closest_on_triangle(p, m.positions[m.indices[k]], m.positions[m.indices[k + 1]], m.positions[m.indices[k + 2]])
			brute = min(brute, linalg.length(q - p))
		}
		testing.expectf(t, abs(dist - brute) < 1e-5, "nearest %v, every triangle tried %v", dist, brute)
		_, _, hinted, _ := bvh_closest(b, m, p, 10, hint)
		testing.expectf(t, abs(hinted - brute) < 1e-5, "with a hint %v, every triangle tried %v", hinted, brute)
		hint = tri
		// The weights put back the nearest point, at that distance.
		q := bary[0] * m.positions[m.indices[3 * tri]] + bary[1] * m.positions[m.indices[3 * tri + 1]] + bary[2] * m.positions[m.indices[3 * tri + 2]]
		testing.expectf(t, abs(linalg.length(q - p) - dist) < 1e-5, "weights %v give a point %v away, not %v", bary, linalg.length(q - p), dist)
		testing.expect(t, abs(bary[0] + bary[1] + bary[2] - 1) < 1e-5 && min(bary[0], bary[1], bary[2]) >= -1e-6, "weights are a blend")
	}
}

@(test)
bvh_closest_stops_at_its_reach :: proc(t: ^testing.T) {
	m := icosphere(3)
	defer mesh_destroy(&m)
	b := bvh_build_morton(m)
	defer bvh_destroy(&b)
	// A point 1 out from the unit sphere.
	_, _, _, near := bvh_closest(b, m, {0, 2, 0}, 0.5)
	testing.expect(t, !near, "nothing within 0.5")
	_, _, dist, far := bvh_closest(b, m, {0, 2, 0}, 1.5)
	testing.expect(t, far && abs(dist - 1) < 0.01, "the sphere is 1 away")
}

@(test)
closest_on_a_triangle_without_area :: proc(t: ^testing.T) {
	q, bary := closest_on_triangle({1, 1, 0}, {0, 0, 0}, {1, 0, 0}, {2, 0, 0})
	testing.expectf(t, linalg.length(q - Vec3{1, 0, 0}) < 1e-6, "nearest point %v", q)
	testing.expect(t, abs(bary[0] + bary[1] + bary[2] - 1) < 1e-6, "weights are a blend")
	q, bary = closest_on_triangle({3, 1, 0}, {1, 1, 1}, {1, 1, 1}, {1, 1, 1})
	testing.expect(t, q == Vec3{1, 1, 1} && bary[0] + bary[1] + bary[2] == 1, "a triangle that is a point")
	// Two corners one point, with p over the third edge: no 0/0.
	q, bary = closest_on_triangle({0.5, 1, 0}, {0, 0, 0}, {0, 0, 0}, {1, 0, 0})
	testing.expectf(t, linalg.length(q - Vec3{0.5, 0, 0}) < 1e-6, "nearest point %v", q)
	testing.expectf(t, abs(bary[0] + bary[1] + bary[2] - 1) < 1e-6, "weights %v", bary)
}

@(test)
bvh_closest_by_threads_matches_one :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	m := geodesic_sphere(30, &pool)
	defer mesh_destroy(&m)
	b := bvh_build_morton(m, BVH_LEAF_SIZE, &pool)
	defer bvh_destroy(&b)
	points := closest_points(5000, 9)
	defer delete(points)
	runs: [2]Closest_Run
	for &run, k in runs {
		run = {b = b, m = m, points = points}
		run.tris, run.barys, run.dists = make([]u32, len(points)), make([][3]f32, len(points)), make([]f32, len(points))
		jobs.parallel_for(&pool if k == 1 else nil, len(points), &run, proc(data: rawptr, i: int) {
			run := cast(^Closest_Run)data
			run.tris[i], run.barys[i], run.dists[i], _ = bvh_closest(run.b, run.m, run.points[i], 10)
		})
	}
	for i in 0 ..< len(points) {
		if runs[0].tris[i] != runs[1].tris[i] || runs[0].barys[i] != runs[1].barys[i] || runs[0].dists[i] != runs[1].dists[i] {
			testing.expectf(t, false, "point %d differs between one thread and several", i)
			break
		}
	}
	for run in runs {
		delete(run.tris)
		delete(run.barys)
		delete(run.dists)
	}
}
