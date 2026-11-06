package sculpt

import "core:math/linalg"
import "core:testing"

import "../geom"

// A straight open curve of `count` points along X from 0 to 1, `radius` thick.
@(private = "file")
rope_line :: proc(count: int, radius: f32) -> []geom.Bezier_Point {
	points := make([]geom.Bezier_Point, count, context.temp_allocator)
	step := 1 / f32(count - 1)
	for &p, i in points do p = {p = {f32(i) * step, 0, 0}, h_in = {-step / 3, 0, 0}, h_out = {step / 3, 0, 0}, radius = radius}
	return points
}

// Held by its first end, a rope falls and hangs straight down from it, keeping its
// length; the curve's points follow the chain and the held end stays put.
@(test)
rope_hangs_from_what_holds_it :: proc(t: ^testing.T) {
	points := rope_line(5, 0.01)
	r: Rope
	defer rope_end(&r)
	testing.expect(t, rope_begin(&r, points, false, 0))
	testing.expect_value(t, r.held, 0)
	for _ in 0 ..< 600 do _ = rope_step(&r, {0, 0, 0}, {0, -1, 0}, 1)
	rope_to_curve(&r, points, false)
	length: f32
	for i in 0 ..< len(r.pos) - 1 do length += linalg.length(r.pos[i + 1] - r.pos[i])
	testing.expectf(t, abs(length - 1) < 0.03, "the rope should keep its length, %v", length)
	tip := points[len(points) - 1].p
	testing.expectf(t, tip.y < -0.9 && abs(tip.x) < 0.1, "the free end should hang below the held one, at %v", tip)
	testing.expect_value(t, points[0].p, Vec3{})
}

// Two crossing runs of one rope keep two radii apart however they are pulled, so a loop
// pulled tight lies over itself: no two links that are not neighbours come closer than
// most of the rope's thickness.
@(test)
rope_keeps_its_thickness :: proc(t: ^testing.T) {
	// A loop that crosses itself: out along X, round and back across its own start.
	points := []geom.Bezier_Point {
		{p = {0, 0, 0}, h_out = {0.2, 0, 0}, radius = 0.03},
		{p = {0.6, 0.3, 0}, h_in = {0, -0.2, 0}, h_out = {0, 0.2, 0}, radius = 0.03},
		{p = {0.3, 0.6, 0}, h_in = {0.2, 0, 0}, h_out = {-0.2, 0, 0}, radius = 0.03},
		{p = {0.3, -0.4, 0.001}, h_in = {0, 0.2, 0}, radius = 0.03},
	}
	r: Rope
	defer rope_end(&r)
	testing.expect(t, rope_begin(&r, points, false, 0))
	end := r.pos[len(r.pos) - 1]
	// Pull the held start out along X while the far end drags, tightening the loop.
	for k in 0 ..< 300 do _ = rope_step(&r, {f32(k) * 0.002, 0, 0}, {0, 0, -1}, 0.2)
	n := len(r.pos)
	closest := f32(1e9)
	skip := int(2 * r.radius / r.link) + 2
	for a in 0 ..< n - 1 do for b in a + skip ..< n - 1 {
		sa, sb := rope_nearest(r.pos[a], r.pos[a + 1], r.pos[b], r.pos[b + 1])
		closest = min(closest, linalg.length(linalg.lerp(r.pos[a], r.pos[a + 1], sa) - linalg.lerp(r.pos[b], r.pos[b + 1], sb)))
	}
	testing.expectf(t, closest > 1.5 * r.radius, "links passed through each other: %v apart for a radius of %v", closest, r.radius)
	testing.expect(t, r.pos[n - 1] != end, "the rope should move")
}

// The floor holds the rope a radius above it.
@(test)
rope_lies_on_the_floor :: proc(t: ^testing.T) {
	points := rope_line(4, 0.02)
	r: Rope
	defer rope_end(&r)
	testing.expect(t, rope_begin(&r, points, false, 0))
	with := Cloth_Collisions{floor = true, floor_at = {0, -0.5, 0}, floor_up = {0, 1, 0}}
	for _ in 0 ..< 800 do _ = rope_step(&r, {0, 0, 0}, {0, -1, 0}, 1, &with)
	low := f32(1e9)
	for p in r.pos do low = min(low, p.y)
	testing.expectf(t, low > -0.5 + 0.019 && low < -0.45, "the rope should lie on the floor, lowest %v", low)
}
