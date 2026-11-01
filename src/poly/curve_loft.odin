package poly

import "core:math/linalg"

import "../geom"

// A loft cage, as Plasticity's and Shapr3D's Loft bridge sections: a quad cage through
// two or more curves, each cut into the same number of points evenly by length so curves
// of any points match, turned and reversed to follow the one before without a twist, with
// rings between them along a spline through the sections.

// The most sections a loft takes.
LOFT_SECTIONS_MAX :: 64

// `count` points along the curve evenly by length (an open curve's ends among them, so
// count + 1 of them), in temp memory; nil for a curve with no length.
@(private = "file")
loft_even :: proc(points: []geom.Bezier_Point, closed: bool, count: int) -> []Vec3 {
	length := geom.bezier_length(points, closed)
	if !(length > 0) do return nil
	samples := geom.bezier_sample(points, closed, length / f32(count * 16), context.temp_allocator)
	if len(samples) < 2 do return nil
	// Where each sample is and how far along; a closed curve's samples stop short of its
	// start, so the start is taken again at the whole length, closing the last span.
	at := make([dynamic]Vec3, 0, len(samples) + 1, context.temp_allocator)
	run := make([dynamic]f32, 0, len(samples) + 1, context.temp_allocator)
	for q in samples {
		append(&at, q.p)
		append(&run, q.s)
	}
	if closed {
		append(&at, samples[0].p)
		append(&run, max(length, run[len(run) - 1]))
	}
	total := run[len(run) - 1]
	n := count if closed else count + 1
	out := make([]Vec3, n, context.temp_allocator)
	j := 0
	for k in 0 ..< n {
		want := total * f32(k) / f32(count)
		for j < len(at) - 2 && run[j + 1] < want do j += 1
		span := run[j + 1] - run[j]
		u := clamp((want - run[j]) / span, 0, 1) if span > 0 else 0
		out[k] = linalg.lerp(at[j], at[j + 1], u)
	}
	return out
}

// Turns `ring` (in place) to lie along `prev` the way that moves its points least: a
// closed ring's start rotated and either way round, an open one either way.
@(private = "file")
loft_match :: proc(prev, ring: []Vec3, closed: bool) {
	n := len(ring)
	best := max(f32)
	shift, flip := 0, false
	for f in 0 ..< 2 {
		starts := n if closed else 1
		for s in 0 ..< starts {
			sum: f32
			for k in 0 ..< n {
				i := (s + k) % n if f == 0 else ((s - k) % n + n) % n
				if !closed && f == 1 do i = n - 1 - k
				sum += linalg.length2(ring[i] - prev[k])
			}
			// The first best stays, so equal choices give the same cage every time.
			if sum < best do best, shift, flip = sum, s, f == 1
		}
	}
	turned := make([]Vec3, n, context.temp_allocator)
	for k in 0 ..< n {
		i := (shift + k) % n if !flip else ((shift - k) % n + n) % n
		if !closed && flip do i = n - 1 - k
		turned[k] = ring[i]
	}
	copy(ring, turned)
}

// A loft through `sections` (each a curve's points, all in one space; all closed or all
// open, as `closed` says): `o.around` quads across, `o.steps` rows from one section to the
// next along a Catmull-Rom spline through them, and with `o.caps` a closed loft's ends
// closed by a polygon each. A closed loft faces out; an open one, a sheet, faces the way
// its first section turns with the next.
loft_cage :: proc(sections: [][]geom.Bezier_Point, closed: bool, o: Curve_Cage_Options, allocator := context.allocator) -> (m: Mesh, err: Build_Error) {
	if len(sections) < 2 || len(sections) > LOFT_SECTIONS_MAX do return mesh_make(allocator), .Degenerate_Face
	around := clamp(o.around, 3, CURVE_CAGE_AROUND_MAX)
	steps := clamp(o.steps, 1, CURVE_CAGE_STEPS_MAX)
	cols := around if closed else around + 1
	rings := make([][]Vec3, len(sections), context.temp_allocator)
	for s, i in sections {
		if geom.bezier_segments(len(s), closed) == 0 do return mesh_make(allocator), .Degenerate_Face
		rings[i] = loft_even(s, closed, around)
		if rings[i] == nil do return mesh_make(allocator), .Degenerate_Face
		if i > 0 do loft_match(rings[i - 1], rings[i], closed)
	}
	// The rows: each section, and steps - 1 between each pair on the spline through them.
	rows := (len(rings) - 1) * steps + 1
	positions := make([]Vec3, rows * cols, context.temp_allocator)
	last := len(rings) - 1
	for r in 0 ..< rows {
		i, t := r / steps, f32(r % steps) / f32(steps)
		if i == last do i, t = last - 1, 1
		for k in 0 ..< cols {
			p0, p1, p2, p3 := rings[max(i - 1, 0)][k], rings[i][k], rings[i + 1][k], rings[min(i + 2, last)][k]
			if i == 0 do p0 = 2 * p1 - p2
			if i + 1 == last do p3 = 2 * p2 - p1
			positions[r * cols + k] = catmull_rom(p0, p1, p2, p3, t)
		}
	}
	sizes := make([dynamic]int, context.temp_allocator)
	corners := make([dynamic]u32, context.temp_allocator)
	for r in 0 ..< rows - 1 {
		a, b := r * cols, (r + 1) * cols
		for k in 0 ..< around {
			k1 := (k + 1) % cols
			append(&sizes, 4)
			append(&corners, u32(a + k), u32(a + k1), u32(b + k1), u32(b + k))
		}
	}
	if closed && o.caps {
		end := (rows - 1) * cols
		append(&sizes, around, around)
		for k := around - 1; k >= 0; k -= 1 do append(&corners, u32(k))
		for k in 0 ..< around do append(&corners, u32(end + k))
	}
	if closed {
		// Faces out: the faces' area vectors point away from the middle of the points. Loops
		// all in one plane enclose nothing, so they keep the order they were built in.
		middle: Vec3
		for p in positions do middle += p
		middle /= f32(len(positions))
		out: f32
		at := 0
		for n in sizes {
			c: Vec3
			area: Vec3
			for j in 0 ..< n {
				p, q := positions[corners[at + j]], positions[corners[at + (j + 1) % n]]
				c += p
				area += linalg.cross(p, q)
			}
			out += linalg.dot(c / f32(n) - middle, area)
			at += n
		}
		if out < 0 {
			at = 0
			for n in sizes {
				face := corners[at:at + n]
				for j in 0 ..< n / 2 do face[j], face[n - 1 - j] = face[n - 1 - j], face[j]
				at += n
			}
		}
	}
	return mesh_from_polygons(positions, sizes[:], corners[:], allocator = allocator)
}

// The uniform Catmull-Rom spline between p1 (t 0) and p2 (t 1).
@(private = "file")
catmull_rom :: proc(p0, p1, p2, p3: Vec3, t: f32) -> Vec3 {
	t2, t3 := t * t, t * t * t
	return 0.5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (3 * p1 - p0 - 3 * p2 + p3) * t3)
}
