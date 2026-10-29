package sculpt

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

// A grid of 61 by 61 over the unit square shaped by `height` (z), with normals.
@(private = "file")
height_grid :: proc(height: proc(x, y: f32) -> f32) -> (m: geom.Mesh) {
	N :: 61
	for y in 0 ..< N do for x in 0 ..< N {
		px, py := f32(x) / (N - 1), f32(y) / (N - 1)
		append(&m.positions, Vec3{px, py, height(px, py)})
	}
	for y in 0 ..< N - 1 do for x in 0 ..< N - 1 {
		a := u32(y * N + x)
		append(&m.indices, a, a + 1, a + N + 1, a, a + N + 1, a + N)
	}
	resize(&m.normals, len(m.positions))
	geom.mesh_recompute_normals(&m)
	return
}

// The area normal a dab finds at `at`: with Stabilize on, the stroke's first dab starts
// the mean with its own area, which the sculptor keeps.
@(private = "file")
area_normal :: proc(m: ^geom.Mesh, at: Vec3, radius, sample: f32) -> Vec3 {
	s: Sculptor
	sculptor_init(&s, m, nil, 64)
	defer sculptor_destroy(&s)
	sculptor_stroke_begin(&s)
	_ = apply_dab(&s, {kind = .Draw, radius = radius, strength = 1e-6, stabilize = 0.5, sample_radius = sample}, at)
	_ = sculptor_stroke_end(&s)
	return s.steady.normal
}

// Sample radius: beside a ridge, a dab sampling a quarter of its radius takes the slope
// it presses on, where the whole radius reaches over the ridge and averages both sides.
@(test)
sample_radius_follows_the_slope_pressed :: proc(t: ^testing.T) {
	m := height_grid(proc(x, y: f32) -> f32 {return 0.5 - abs(x - 0.5)})
	defer geom.mesh_destroy(&m)
	slope := linalg.normalize(Vec3{1, 0, 1}) // the side past the ridge, x > 0.5, falling away
	at := Vec3{0.6, 0.5, 0.4}
	whole := area_normal(&m, at, 0.3, 1)
	quarter := area_normal(&m, at, 0.3, 0.25)
	testing.expectf(t, linalg.dot(quarter, slope) > 0.99 && linalg.dot(quarter, slope) > linalg.dot(whole, slope) + 0.02, "the slope's normal %v; at a quarter %v, whole %v", slope, quarter, whole)
}

// Stabilize orientation keeps most of the stroke's mean: past a bend from flat to a slope
// the second dab still works close to the first one's normal; serial == parallel.
@(test)
stabilize_keeps_the_strokes_normal :: proc(t: ^testing.T) {
	run :: proc(keep: f32, pool: ^jobs.Pool) -> (Vec3, []Vec3) {
		m := height_grid(proc(x, y: f32) -> f32 {return max(x - 0.5, 0)})
		defer geom.mesh_destroy(&m)
		s: Sculptor
		sculptor_init(&s, &m, pool, 64)
		defer sculptor_destroy(&s)
		sculptor_stroke_begin(&s)
		brush := Brush{kind = .Clay, radius = 0.1, strength = 0.5, stabilize = keep}
		_ = apply_dab(&s, brush, {0.25, 0.5, 0})
		_ = apply_dab(&s, brush, {0.8, 0.5, 0.3})
		_ = sculptor_stroke_end(&s)
		return s.steady.normal, slice.clone(m.positions[:], context.temp_allocator)
	}
	steady, serial := run(0.9, nil)
	follows, _ := run(0.01, nil)
	up := Vec3{0, 0, 1}
	testing.expectf(t, linalg.dot(steady, up) > 0.99 && linalg.dot(follows, up) < 0.8, "kept %v, followed %v", steady, follows)
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	_, parallel := run(0.9, &pool)
	testing.expect(t, slice.equal(serial, parallel), "parallel Stabilize differs from serial")
}

// Accumulate off: a Draw stroke over the same place three times raises it as one pass
// does, where with Accumulate on it builds three times as high; undo puts it back.
@(test)
accumulate_off_builds_one_pass :: proc(t: ^testing.T) {
	rise :: proc(once: bool, passes: int) -> f32 {
		m := geom.icosphere(4)
		defer geom.mesh_destroy(&m)
		s: Sculptor
		sculptor_init(&s, &m, nil, 64)
		defer sculptor_destroy(&s)
		before := slice.clone(m.positions[:], context.temp_allocator)
		sculptor_stroke_begin(&s)
		for _ in 0 ..< passes do _ = apply_dab(&s, {kind = .Draw, radius = 0.3, strength = 0.5, no_accumulate = once}, {0, 0, 1})
		_ = sculptor_stroke_end(&s)
		most: f32
		for p in m.positions do most = max(most, p.z)
		_ = sculptor_undo(&s)
		if !slice.equal(before, m.positions[:]) do return -1
		return most - 1
	}
	one := rise(true, 1)
	three_once := rise(true, 3)
	three := rise(false, 3)
	testing.expectf(t, one > 0 && abs(three_once - one) < 0.01 * one && three > 2.5 * one, "one pass %v; three without accumulating %v, accumulating %v", one, three_once, three)
}
