package sculpt

import "core:math"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

// A grid of 61 by 61 over the unit square shaped by `height` (z), with normals.
@(private = "file")
grid :: proc(height: proc(x, y: f32) -> f32) -> (m: geom.Mesh) {
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

@(private = "file")
flat :: proc(x, y: f32) -> f32 {return 0}

// The grid vertex nearest (x, y).
@(private = "file")
at :: proc(x, y: f32) -> int {
	return int(math.round(y * 60)) * 61 + int(math.round(x * 60))
}

// Where the grid vertex now at index v began, as at() numbers them: sculptor_init orders
// the vertices by node, so they are found again by where they lay.
@(private = "file")
grid_index :: proc(p: Vec3) -> int {return at(p.x, p.y)}

// One dab of `brush` on a fresh grid at (0.5, 0.5); the rise of each vertex, in at()'s
// order.
@(private = "file")
rise :: proc(height: proc(x, y: f32) -> f32, brush: Brush, pool: ^jobs.Pool = nil) -> []f32 {
	m := grid(height)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, pool, 64)
	defer sculptor_destroy(&s)
	before := slice.clone(m.positions[:], context.temp_allocator)
	sculptor_stroke_begin(&s)
	_ = apply_dab(&s, brush, {0.5, 0.5, height(0.5, 0.5)})
	_ = sculptor_stroke_end(&s)
	out := make([]f32, len(m.positions), context.temp_allocator)
	for p, v in m.positions do out[grid_index(before[v])] = p.z - before[v].z
	return out
}

// Clay strips' tip is a square turned along the stroke: a vertex 0.8 radii out along both
// axes, past the round brush's reach, rises with it, and far more of the corners rise
// than Clay's round dab lifts; turned 45 degrees, that corner lies outside it.
@(test)
clay_strips_lays_a_square_along_the_stroke :: proc(t: ^testing.T) {
	R :: 0.2
	strip := Brush{kind = .Clay_Strips, radius = R, strength = 1, stroke_dir = {1, 0, 0}}
	square := rise(flat, strip)
	round := rise(flat, {kind = .Clay, radius = R, strength = 1})
	middle, corner, far := at(0.5, 0.5), at(0.5 + 0.6 * R, 0.5 + 0.6 * R), at(0.5 + 0.8 * R, 0.5 + 0.8 * R)
	testing.expectf(t, square[middle] > 0 && square[far] > 0 && round[far] == 0, "middle %v, past the round reach %v (Clay %v)", square[middle], square[far], round[far])
	testing.expectf(t, square[corner] / square[middle] > 2 * round[corner] / round[middle], "the corner's share: strips %v, Clay %v", square[corner] / square[middle], round[corner] / round[middle])
	strip.stroke_dir = {1, 1, 0}
	turned := rise(flat, strip)
	testing.expectf(t, turned[far] == 0 && turned[at(0.5 + 0.9 * R, 0.5)] > 0, "turned: the corner %v, along the side %v", turned[far], turned[at(0.5 + 0.9 * R, 0.5)])
	// Rounder corners give up the far corner.
	strip.stroke_dir, strip.tip_roundness = {1, 0, 0}, 1
	testing.expect_value(t, rise(flat, strip)[far], 0)
}

// A rounded roof along y: its ridge, a sharp top's normals 62 degrees apart.
@(private = "file")
roof :: proc(x, y: f32) -> f32 {
	dx := x - 0.5
	return 0.3 - 0.6 * math.sqrt(dx * dx + 0.03 * 0.03)
}

@(private = "file")
valley :: proc(x, y: f32) -> f32 {return -roof(x, y)}

// Trim dynamic drawn along a rounded ridge reads its angle from the two sides and cuts the
// rounding away: the top comes down more than the flanks. On a valley the angle it reads
// is 0. Serial and parallel agree for both kinds.
@(test)
trim_dynamic_sharpens_a_ridge :: proc(t: ^testing.T) {
	R :: 0.15
	m := grid(roof)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	before := slice.clone(m.positions[:], context.temp_allocator)
	sculptor_stroke_begin(&s)
	for k in 0 ..< 4 do _ = apply_dab(&s, {kind = .Trim_Dynamic, radius = R, strength = 1, stroke_dir = {0, 1, 0}}, {0.5, 0.45 + 0.03 * f32(k), roof(0.5, 0.5)})
	angle := math.to_degrees(s.trim.angle)
	_ = sculptor_stroke_end(&s)
	testing.expectf(t, angle > 40 && angle < 75, "sampled angle %v degrees", angle)
	cut := make([]f32, len(m.positions), context.temp_allocator)
	for p, i in m.positions do cut[grid_index(before[i])] = before[i].z - p.z
	cut_top, cut_flank := cut[at(0.5, 0.5)], cut[at(0.5 + 0.5 * R, 0.5)]
	testing.expectf(t, cut_top > 0 && cut_top > 1.5 * cut_flank, "cut at the top %v, on the flank %v", cut_top, cut_flank)

	v := grid(valley)
	defer geom.mesh_destroy(&v)
	sv: Sculptor
	sculptor_init(&sv, &v, nil, 64)
	defer sculptor_destroy(&sv)
	sculptor_stroke_begin(&sv)
	_ = apply_dab(&sv, {kind = .Trim_Dynamic, radius = R, strength = 1, stroke_dir = {0, 1, 0}}, {0.5, 0.5, valley(0.5, 0.5)})
	testing.expect_value(t, sv.trim.angle, 0)
	_ = sculptor_stroke_end(&sv)

	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	for kind in ([2]Brush_Kind{.Clay_Strips, .Trim_Dynamic}) {
		b := Brush{kind = kind, radius = 0.3, strength = 1, stroke_dir = {1, 0.3, 0}}
		testing.expectf(t, slice.equal(rise(roof, b), rise(roof, b, &pool)), "%v: serial and parallel differ", kind)
	}
}

// A wavy ground for Flatten.
@(private = "file")
waves :: proc(x, y: f32) -> f32 {return 0.03 * math.sin(40 * x)}

// Flatten's plane height 0 (Fill) leaves what lies above its plane and raises the dips;
// depth 0 (Scrape) leaves the dips and cuts what lies above.
@(test)
flatten_plane_height_and_depth :: proc(t: ^testing.T) {
	plain := rise(waves, {kind = .Flatten, radius = 0.2, strength = 1})
	fill := rise(waves, {kind = .Flatten, radius = 0.2, strength = 1, plane_short = {1, 0}})
	scrape := rise(waves, {kind = .Flatten, radius = 0.2, strength = 1, plane_short = {0, 1}})
	up, down, raised, cut, wrong: int
	for r, v in plain {
		if r < 0 {
			down += 1
			if fill[v] != 0 do wrong += 1
			if scrape[v] < 0 do cut += 1
		} else if r > 0 {
			up += 1
			if scrape[v] != 0 do wrong += 1
			if fill[v] > 0 do raised += 1
		}
	}
	testing.expectf(t, up > 0 && down > 0 && raised == up && cut == down && wrong == 0, "plain raises %v and cuts %v; Fill raises %v, Scrape cuts %v, %v on the wrong side", up, down, raised, cut, wrong)
}
