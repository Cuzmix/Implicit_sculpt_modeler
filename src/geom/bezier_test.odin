package geom

import "core:math"
import "core:math/linalg"
import "core:testing"

// A quarter circle of radius 1 as one cubic, with the usual handle length 0.5523.
@(private = "file")
quarter_circle :: proc() -> [2]Bezier_Point {
	k: f32 = 0.5522847
	return {
		{p = {1, 0, 0}, h_out = {0, k, 0}, radius = 1, intensity = 0},
		{p = {0, 1, 0}, h_in = {k, 0, 0}, radius = 3, intensity = 1},
	}
}

// The length of a quarter circle is pi/2 to within the cubic's own error, and samples come
// at even steps with the ends kept and the values eased between the points.
@(test)
bezier_samples_a_quarter_circle_evenly :: proc(t: ^testing.T) {
	q := quarter_circle()
	length := bezier_length(q[:], false)
	testing.expectf(t, abs(length - math.PI / 2) < 1e-3, "length %v", length)
	samples := bezier_sample(q[:], false, 0.1, context.temp_allocator)
	testing.expect_value(t, len(samples), 17)
	testing.expect(t, samples[0].p == q[0].p && samples[16].p == q[1].p, "the ends moved")
	for i in 1 ..< len(samples) {
		step := linalg.length(samples[i].p - samples[i - 1].p)
		testing.expectf(t, abs(step - length / 16) < 1e-3, "step %d is %v", i, step)
		testing.expect(t, samples[i].radius >= samples[i - 1].radius, "the radius should only grow")
	}
	for s in samples {
		testing.expectf(t, abs(linalg.length(s.p) - 1) < 1e-3, "sample off the circle at %v", s.p)
		testing.expectf(t, abs(linalg.dot(s.t, s.p)) < 1e-2, "tangent %v not square to the radius at %v", s.t, s.p)
	}
	testing.expectf(t, abs(samples[8].radius - 2) < 1e-5, "middle radius %v", samples[8].radius)
	testing.expect(t, bezier_sample(q[:1], false, 0.1, context.temp_allocator) == nil, "one point samples to nothing")
}

// Adding a point keeps the curve where it was, and the new point sits on it.
@(test)
bezier_insert_keeps_the_shape :: proc(t: ^testing.T) {
	q := quarter_circle()
	points := make([dynamic]Bezier_Point, context.temp_allocator)
	append(&points, ..q[:])
	before := bezier_sample(points[:], false, 0.05, context.temp_allocator)
	at := bezier_insert(&points, false, 0.3)
	testing.expect_value(t, at, 1)
	testing.expect_value(t, len(points), 3)
	after := bezier_sample(points[:], false, 0.05, context.temp_allocator)
	testing.expect_value(t, len(after), len(before))
	for s, i in after do testing.expectf(t, linalg.length(s.p - before[i].p) < 1e-3, "sample %d moved", i)
	testing.expectf(t, linalg.length(points[1].p - bezier_at(q[:], false, 0.3)) < 1e-5, "the new point is off the curve")
	testing.expect_value(t, bezier_insert(&points, false, 1), -1)
}

// A wobbly hand-drawn arc fits to a handful of points that stay within the tolerance of
// every input point, the joints smooth, and the source indices name input points in order.
@(test)
bezier_fit_takes_few_points :: proc(t: ^testing.T) {
	input := make([dynamic]Vec3, context.temp_allocator)
	for i in 0 ..= 200 {
		a := f32(i) / 200 * math.PI
		wobble := 0.002 * math.sin(f32(i) * 1.7)
		append(&input, Vec3{(1 + wobble) * math.cos(a), (1 + wobble) * math.sin(a), 0})
		if i % 50 == 0 do append(&input, input[len(input) - 1]) // repeated points are skipped
	}
	tolerance: f32 = 0.01
	points, source := bezier_fit(input[:], tolerance, context.temp_allocator)
	testing.expectf(t, len(points) >= 2 && len(points) <= 6, "%d points for a half circle", len(points))
	testing.expect_value(t, len(source), len(points))
	testing.expect_value(t, source[0], 0)
	// The last input point is a repeat, skipped, so the end sits on the one before it.
	testing.expect_value(t, source[len(source) - 1], len(input) - 2)
	for i in 1 ..< len(source) do testing.expect(t, source[i] > source[i - 1], "sources out of order")
	for p in input {
		_, _, d := bezier_nearest(points, false, p)
		testing.expectf(t, d < 2 * tolerance, "an input point is %v from the fit", d)
	}
	for p in points[1:len(points) - 1] {
		testing.expectf(t, linalg.dot(linalg.normalize(p.h_in), linalg.normalize(p.h_out)) < -0.999, "a joint is not smooth")
	}
	none, _ := bezier_fit({{1, 1, 1}, {1, 1, 1}}, tolerance, context.temp_allocator)
	testing.expect_value(t, len(none), 0)
}

// Frames along a helix stay square and unit, follow the curve, and never flip; a closed
// circle's frames meet themselves after the loop; a twist turns them.
@(test)
bezier_frames_turn_as_little_as_they_can :: proc(t: ^testing.T) {
	input := make([dynamic]Vec3, context.temp_allocator)
	for i in 0 ..= 400 {
		a := f32(i) / 100 * math.PI
		append(&input, Vec3{math.cos(a), math.sin(a), 0.1 * a})
	}
	points, _ := bezier_fit(input[:], 0.002, context.temp_allocator)
	samples := bezier_sample(points, false, 0.02, context.temp_allocator)
	frames := bezier_frames(samples, {0, 0, 1}, false, context.temp_allocator)
	for f, i in frames {
		testing.expectf(t, abs(linalg.length(f.n) - 1) < 1e-4 && abs(linalg.dot(f.n, f.t)) < 1e-4, "frame %d not square", i)
		testing.expectf(t, linalg.length(linalg.cross(f.t, f.n) - f.b) < 1e-5, "frame %d's b", i)
		if i > 0 do testing.expectf(t, linalg.dot(f.n, frames[i - 1].n) > 0.99, "frame %d flipped", i)
	}

	k: f32 = 0.5522847
	circle := [4]Bezier_Point {
		{p = {1, 0, 0}, h_in = {0, -k, 0}, h_out = {0, k, 0}},
		{p = {0, 1, 0}, h_in = {k, 0, 0}, h_out = {-k, 0, 0}},
		{p = {-1, 0, 0}, h_in = {0, k, 0}, h_out = {0, -k, 0}},
		{p = {0, -1, 0}, h_in = {-k, 0, 0}, h_out = {k, 0, 0}},
	}
	round := bezier_sample(circle[:], true, 0.05, context.temp_allocator)
	testing.expectf(t, abs(round[len(round) - 1].s + linalg.length(round[0].p - round[len(round) - 1].p) - 2 * math.PI) < 5e-3, "loop length")
	ring := bezier_frames(round, {0.3, 0.2, 1}, true, context.temp_allocator)
	testing.expectf(t, linalg.dot(ring[0].n, ring[len(ring) - 1].n) > 0.99, "the loop's frames do not meet")

	circle[0].twist = math.PI / 2
	twisted := bezier_frames(bezier_sample(circle[:], true, 0.05, context.temp_allocator), {0.3, 0.2, 1}, true, context.temp_allocator)
	testing.expectf(t, abs(linalg.dot(twisted[0].n, ring[0].n)) < 1e-3, "a quarter twist should turn the first frame square")
}

// Smooth and corner keep or free the handles; a moved handle drags its partner in line.
@(test)
bezier_smooth_and_corner_points :: proc(t: ^testing.T) {
	points := [3]Bezier_Point{{p = {0, 0, 0}}, {p = {1, 1, 0}}, {p = {2, 0, 0}}}
	bezier_make_smooth(points[:], false, 1)
	testing.expectf(t, linalg.length(points[1].h_out - Vec3{1, 0, 0} * linalg.length(Vec3{1, -1, 0}) / 3) < 1e-5, "smooth h_out %v", points[1].h_out)
	testing.expect(t, linalg.length(points[1].h_in + points[1].h_out) < 1e-5, "smooth handles not opposite")
	bezier_make_corner(points[:], false, 1)
	testing.expect(t, points[1].corner, "not a corner")
	testing.expectf(t, linalg.length(points[1].h_in - Vec3{-1, -1, 0} / 3) < 1e-5, "corner h_in %v", points[1].h_in)
	bezier_make_smooth(points[:], false, 0)
	testing.expect_value(t, points[0].h_in, Vec3{})
	points[1].corner = false
	points[1].h_out = {0, 2, 0}
	bezier_align_handles(&points[1], true)
	testing.expectf(t, abs(points[1].h_in.y + linalg.length(Vec3{-1, -1, 0} / 3)) < 1e-5 && abs(points[1].h_in.x) < 1e-6, "aligned h_in %v", points[1].h_in)
}
