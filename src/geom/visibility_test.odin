package geom

import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:testing"

@(test)
oct_encoding_round_trips :: proc(t: ^testing.T) {
	r := rand.create(7)
	context.random_generator = rand.default_random_generator(&r)
	// Chord length ~ angle in radians: 1e-4 is under 0.006 degrees.
	MAX_ERROR :: 1e-4
	axes := [?]Vec3{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
	for n in axes do testing.expect(t, linalg.length(oct_decode(oct_encode(n)) - n) < MAX_ERROR, "axis not preserved")
	worst: f32
	for _ in 0 ..< 10_000 {
		n := linalg.normalize(Vec3{rand.float32_range(-1, 1), rand.float32_range(-1, 1), rand.float32_range(-1, 1)})
		worst = max(worst, linalg.length(oct_decode(oct_encode(n)) - n))
	}
	testing.expectf(t, worst < MAX_ERROR, "worst normal error %v", worst)
}

@(test)
normal_cone_bounds_its_normals :: proc(t: ^testing.T) {
	ns := [?]Vec3{{0, 0, 1}, {0.2, 0, 1}, {0, -0.3, 1}}
	axis, cutoff := normal_cone(ns[:])
	testing.expect(t, cutoff < 1, "narrow cone marked as never culled")
	cos_half := math.sqrt(1 - cutoff * cutoff)
	ns = {{0, 0, 1}, {0.2, 0, 1}, {0, -0.3, 1}} // normal_cone normalized them in place
	for n in ns do testing.expect(t, linalg.dot(linalg.normalize(n), axis) >= cos_half, "normal outside its cone")

	wide := [?]Vec3{{0, 0, 1}, {0, 0, -1}}
	_, cutoff = normal_cone(wide[:])
	testing.expect_value(t, cutoff, f32(1))
}

@(test)
cull_view_and_backface :: proc(t: ^testing.T) {
	// Camera at z = 5 looking down -Z.
	view := Mat4{
		1, 0, 0, 0,
		0, 1, 0, 0,
		0, 0, 1, -5,
		0, 0, 0, 1,
	}
	f := 1 / math.tan(f32(0.35))
	near, far := f32(0.01), f32(100)
	proj := Mat4{
		f, 0, 0, 0,
		0, f, 0, 0,
		0, 0, far / (near - far), near * far / (near - far),
		0, 0, -1, 0,
	}
	eye := Vec3{0, 0, 5}
	unit := Aabb{{-0.1, -0.1, -0.1}, {0.1, 0.1, 0.1}}
	moved :: proc(b: Aabb, d: Vec3) -> Aabb {return {b.lo + d, b.hi + d}}
	chunks := [?]Chunk {
		{bounds = unit, cone_axis = {0, 0, 1}, cone_cutoff = 0.1, first_index = 0, index_count = 3},             // facing the eye
		{bounds = unit, cone_axis = {0, 0, -1}, cone_cutoff = 0.1, first_index = 3, index_count = 3},            // facing away
		{bounds = moved(unit, {0, 0, 10}), cone_cutoff = 1, first_index = 6, index_count = 3},                   // behind the eye
		{bounds = moved(unit, {50, 0, 0}), cone_cutoff = 1, first_index = 9, index_count = 3},                   // far to the side
		{bounds = unit, cone_axis = {0, 0, -1}, cone_cutoff = 1, first_index = 12, index_count = 3},             // too wide to cull
		{bounds = moved(unit, {0, 0, 5}), cone_axis = {0, 0, -1}, cone_cutoff = 0.1, first_index = 15, index_count = 3}, // eye inside
	}
	out: [dynamic]Index_Range
	defer delete(out)
	stats := cull_chunks(chunks[:], proj * view, eye, &out)
	testing.expect_value(t, stats.frustum, 2) // behind and to the side
	testing.expect_value(t, stats.backface, 1)
	testing.expect_value(t, len(out), 2)
	if len(out) == 2 {
		testing.expect_value(t, out[0], Index_Range{0, 3})
		testing.expect_value(t, out[1], Index_Range{12, 6}) // the last two merge
	}
}
