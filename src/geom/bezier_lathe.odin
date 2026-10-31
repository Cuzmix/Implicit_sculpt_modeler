package geom

import "core:math"
import "core:math/linalg"

// A surface spun from a Bézier curve round an axis, as Nomad's Lathe and Blender's Screw
// make it: the curve at even steps, each step a ring round the axis, a step on the axis
// one pole point, an open curve's ends closed onto the axis when asked.

// Which point of the curve the axis passes through, found from the points as they are, so
// editing them keeps the axis where it was meant to be.
Lathe_Through :: enum u8 {
	Start, // the first point: a half outline drawn out from the axis spins into a vase
	End,
	Middle, // the curve's own origin, which stays put as its points are edited
}

Lathe_Options :: struct {
	axis:     Vec3, // the axis's direction, in the curve's space
	through:  Lathe_Through,
	angle:    f32, // degrees round, 1 to 360
	segments: int, // round the axis, 3 to LATHE_SEGMENTS_MAX
	caps:     bool, // close an open curve's ends off the axis onto it
}

LATHE_DEFAULTS :: Lathe_Options{axis = {0, 1, 0}, through = .Start, angle = 360, segments = 32, caps = true}
LATHE_SEGMENTS_MAX :: 256
LATHE_RINGS_MAX :: 2048

// The most points a lathe makes, so a slider dragged on a long curve stays quick.
LATHE_VERTICES_MAX :: 262_144

// The point the axis passes through for `o` on the curve through `points`.
lathe_origin :: proc(points: []Bezier_Point, o: Lathe_Options) -> Vec3 {
	if len(points) == 0 do return {}
	switch o.through {
	case .Start:
		return points[0].p
	case .End:
		return points[len(points) - 1].p
	case .Middle:
		return {}
	}
	return points[0].p
}

// The lathe of the curve through `points` (closed or not). ok is false for fewer than two
// points, no axis, or a curve lying along the axis.
bezier_lathe :: proc(points: []Bezier_Point, closed: bool, o: Lathe_Options, allocator := context.allocator) -> (m: Mesh, ok: bool) {
	if bezier_segments(len(points), closed) == 0 do return {}, false
	axis := linalg.normalize0(o.axis)
	if axis == {} do return {}, false
	origin := lathe_origin(points, o)
	segs := clamp(o.segments, 3, LATHE_SEGMENTS_MAX)
	// Within half a degree of a whole turn is a whole turn, so the seam closes.
	full := !(o.angle < 359.5)
	angle := math.to_radians(clamp(o.angle, 1, 360))
	// The widest place, from the points and their handles, sets the step along the curve so
	// the quads there come out about square.
	far: f32
	for p in points {
		reach := [3]Vec3{p.p, p.p + p.h_in, p.p + p.h_out}
		for q in reach {
			d := q - origin
			far = max(far, linalg.length(d - linalg.dot(d, axis) * axis))
		}
	}
	length := bezier_length(points, closed)
	if !(far > 0) || !(length > 0) do return {}, false
	rings_most := min(LATHE_RINGS_MAX, LATHE_VERTICES_MAX / (segs + 1))
	spacing := max(angle * far / f32(segs), length / f32(rings_most))
	samples := bezier_sample(points, closed, spacing, context.temp_allocator)
	rows := len(samples)
	if rows < 2 do return {}, false
	cols := segs if full else segs + 1
	eps := 1e-4 * far
	start := make([]u32, rows, context.temp_allocator)
	pole := make([]bool, rows, context.temp_allocator)
	heights := make([]f32, rows, context.temp_allocator)
	radii := make([]f32, rows, context.temp_allocator)
	m.positions = make([dynamic]Vec3, 0, rows * cols + 2, allocator)
	m.indices = make([dynamic]u32, 0, 6 * rows * segs + 6 * segs, allocator)
	for s, i in samples {
		d := s.p - origin
		h := linalg.dot(d, axis)
		r := d - h * axis
		start[i], heights[i], radii[i] = u32(len(m.positions)), h, linalg.length(r)
		if radii[i] < eps {
			pole[i] = true
			append(&m.positions, origin + h * axis)
			continue
		}
		// Rodrigues' turn of r, square to the axis, by each step's angle.
		across := linalg.cross(axis, r)
		for k in 0 ..< cols {
			a := angle * f32(k) / f32(segs)
			append(&m.positions, origin + h * axis + r * math.cos(a) + across * math.sin(a))
		}
	}
	at :: proc(start: []u32, pole: []bool, i, k: int) -> u32 {
		return start[i] if pole[i] else start[i] + u32(k)
	}
	join :: proc(m: ^Mesh, start: []u32, pole: []bool, i, j, segs, cols: int) {
		if pole[i] && pole[j] do return
		for k in 0 ..< segs {
			k1 := (k + 1) % cols
			a, b := at(start, pole, i, k), at(start, pole, i, k1)
			c, d := at(start, pole, j, k), at(start, pole, j, k1)
			if !pole[i] do append(&m.indices, a, b, d)
			if !pole[j] do append(&m.indices, a, d, c)
		}
	}
	for i in 0 ..< rows - 1 do join(&m, start, pole, i, i + 1, segs, cols)
	if closed {
		join(&m, start, pole, rows - 1, 0, segs, cols)
	} else if o.caps {
		// Each end off the axis: a fan from its middle on the axis, wound against the ring's
		// own edges in the body.
		ends := [2]int{0, rows - 1}
		for e, n in ends {
			if pole[e] do continue
			middle := u32(len(m.positions))
			append(&m.positions, origin + heights[e] * axis)
			for k in 0 ..< segs {
				p, q := start[e] + u32(k), start[e] + u32((k + 1) % cols)
				if n == 0 do append(&m.indices, middle, q, p)
				else do append(&m.indices, middle, p, q)
			}
		}
	}
	// As built, a triangle faces away from the axis where the curve runs along it (its
	// height rising), and toward -axis where it runs outward. So it faces out when the
	// profile's swept volume, the sum of r² dh, is positive; for a flat profile, with no
	// volume, it is turned to face +axis, so either way the result does not depend on which
	// end the curve was drawn from.
	volume, outward: f64
	pairs := rows if closed else rows - 1
	for i in 0 ..< pairs {
		j := (i + 1) % rows
		r := 0.5 * f64(radii[i] + radii[j])
		volume += r * r * f64(heights[j] - heights[i])
		outward += r * f64(radii[j] - radii[i])
	}
	flip := volume < 0 if abs(volume) > 1e-9 * f64(far * far * far) else outward > 0
	if flip {
		for t := 0; t + 2 < len(m.indices); t += 3 do m.indices[t + 1], m.indices[t + 2] = m.indices[t + 2], m.indices[t + 1]
	}
	if len(m.indices) == 0 {
		mesh_destroy(&m)
		return {}, false
	}
	m.normals = make([dynamic]Vec3, len(m.positions), allocator)
	mesh_recompute_normals(&m)
	return m, true
}
