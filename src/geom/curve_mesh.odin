package geom

import "core:math"
import "core:math/linalg"

// Curve geometry, as ZBrush's curve brushes make it: a path drawn over a surface (points
// with the surface's normal at each) becomes a tube swept along it, or copies of a small
// part set along it at even steps, as stitches or zipper teeth are. Each piece is turned
// to the path's frame there: along the path, out of the surface, and across it.

Curve_Point :: struct {
	p, n: Vec3, // where, and the surface's outward normal there
}

// A frame along a curve: T along it, N out of the surface (square to T), B = T × N
// across it.
Curve_Frame :: struct {
	p, t, n, b: Vec3,
}

// The curve through `points` again at even steps of about `spacing` (the ends kept),
// then `smooth` rounds of smoothing, which take out the hand's wobble. Nil when the
// curve is shorter than one step.
curve_resample :: proc(points: []Curve_Point, spacing: f32, smooth: int, allocator := context.allocator) -> []Curve_Point {
	if len(points) < 2 || !(spacing > 0) do return nil
	length: f32
	for i in 1 ..< len(points) do length += linalg.length(points[i].p - points[i - 1].p)
	if length < spacing do return nil
	steps := max(1, int(math.round(length / spacing)))
	out := make([]Curve_Point, steps + 1, allocator)
	step := length / f32(steps)
	out[0] = points[0]
	// Walk the input once, placing a point each time the distance passes a step.
	seg, walked := 1, f32(0)
	for k in 1 ..< steps {
		want := f32(k) * step
		for seg < len(points) - 1 && walked + linalg.length(points[seg].p - points[seg - 1].p) < want {
			walked += linalg.length(points[seg].p - points[seg - 1].p)
			seg += 1
		}
		a, b := points[seg - 1], points[seg]
		l := linalg.length(b.p - a.p)
		s := clamp((want - walked) / l, 0, 1) if l > 0 else 0
		out[k] = {linalg.lerp(a.p, b.p, s), linalg.lerp(a.n, b.n, s)}
	}
	out[steps] = points[len(points) - 1]
	next := make([]Curve_Point, len(out), context.temp_allocator)
	for _ in 0 ..< smooth {
		copy(next, out)
		for i in 1 ..< len(out) - 1 {
			next[i].p = 0.5 * out[i].p + 0.25 * (out[i - 1].p + out[i + 1].p)
			next[i].n = 0.5 * out[i].n + 0.25 * (out[i - 1].n + out[i + 1].n)
		}
		copy(out, next)
	}
	for &c in out do c.n = linalg.normalize0(c.n)
	return out
}

// The frame at each point of a resampled curve. Where the normal runs along the curve
// the previous point's is kept, so the frame never flips.
curve_frames :: proc(points: []Curve_Point, allocator := context.allocator) -> []Curve_Frame {
	frames := make([]Curve_Frame, len(points), allocator)
	last := len(points) - 1
	prev_n := Vec3{0, 1, 0}
	for c, i in points {
		t := linalg.normalize0(points[min(i + 1, last)].p - points[max(i - 1, 0)].p)
		if t == {} do t = {0, 0, 1}
		n := c.n - linalg.dot(c.n, t) * t
		if linalg.length(n) < 1e-4 {
			n = prev_n - linalg.dot(prev_n, t) * t
			if linalg.length(n) < 1e-4 do n = any_square_to(t)
		}
		n = linalg.normalize(n)
		frames[i] = {c.p, t, n, linalg.cross(t, n)}
		prev_n = n
	}
	return frames
}

// A unit vector square to unit `v`.
any_square_to :: proc(v: Vec3) -> Vec3 {
	other := Vec3{1, 0, 0} if abs(v.x) < 0.9 else Vec3{0, 1, 0}
	return linalg.normalize(linalg.cross(v, other))
}

// A tube of `radius` along the curve, its middle `lift` out from the surface, with
// `sides` vertices round each ring and a flat cap at each end: closed and manifold.
// The curve should be resampled at about the ring spacing wanted.
curve_tube :: proc(points: []Curve_Point, radius, lift: f32, sides: int, allocator := context.allocator) -> (m: Mesh, ok: bool) {
	if len(points) < 2 || sides < 3 || !(radius > 0) do return {}, false
	frames := curve_frames(points, context.temp_allocator)
	rings := len(frames)
	m.positions = make([dynamic]Vec3, 0, rings * sides + 2, allocator)
	m.indices = make([dynamic]u32, 0, 6 * (rings - 1) * sides + 6 * sides, allocator)
	for f in frames {
		middle := f.p + lift * f.n
		for k in 0 ..< sides {
			a := 2 * math.PI * f32(k) / f32(sides)
			append(&m.positions, middle + radius * (math.cos(a) * f.n + math.sin(a) * f.b))
		}
	}
	S := u32(sides)
	for i in 0 ..< u32(rings - 1) {
		for k in 0 ..< S {
			a, b := i * S + k, i * S + (k + 1) % S
			c, d := b + S, a + S
			// Round the ring (N towards B, anticlockwise about T) then along T faces out.
			append(&m.indices, a, b, c, a, c, d)
		}
	}
	start, end := u32(len(m.positions)), u32(len(m.positions) + 1)
	append(&m.positions, frames[0].p + lift * frames[0].n, frames[rings - 1].p + lift * frames[rings - 1].n)
	last := u32(rings - 1) * S
	for k in 0 ..< S {
		append(&m.indices, start, (k + 1) % S, k)
		append(&m.indices, end, last + k, last + (k + 1) % S)
	}
	m.normals = make([dynamic]Vec3, len(m.positions), allocator)
	mesh_recompute_normals(&m)
	return m, true
}

// Copies of `part` at every point of the curve, each turned to the frame there: the
// part's x goes across the curve (B), y out of the surface (N) and z back along it (-T,
// which keeps the turn from mirroring the part), and its origin `lift` out from the surface. With `alternate` every other copy is turned
// half round N, so it points to the other side. Closed parts give a closed mesh.
curve_place :: proc(points: []Curve_Point, part: Mesh, lift: f32, alternate: bool, allocator := context.allocator) -> (m: Mesh, ok: bool) {
	if len(points) == 0 || len(part.positions) == 0 do return {}, false
	frames := curve_frames(points, context.temp_allocator)
	m.positions = make([dynamic]Vec3, 0, len(frames) * len(part.positions), allocator)
	m.indices = make([dynamic]u32, 0, len(frames) * len(part.indices), allocator)
	for f, i in frames {
		turn: f32 = -1 if alternate && i % 2 == 1 else 1
		base := u32(len(m.positions))
		origin := f.p + lift * f.n
		for q in part.positions do append(&m.positions, origin + turn * q.x * f.b + q.y * f.n - turn * q.z * f.t)
		for v in part.indices do append(&m.indices, base + v)
	}
	m.normals = make([dynamic]Vec3, len(m.positions), allocator)
	mesh_recompute_normals(&m)
	return m, true
}

// A stitch for curve_place, `width` across: a flattened, rounded bar across the curve,
// leaning a little along it, as a cross-stitch's thread does.
curve_stitch_part :: proc(width: f32, allocator := context.allocator) -> Mesh {
	m := icosphere(2, 1, allocator)
	lean := math.to_radians(f32(25))
	c, s := math.cos(lean), math.sin(lean)
	for &p in m.positions {
		q := p * Vec3{0.5 * width, 0.15 * width, 0.14 * width}
		// Turned about y, so the bar leans along the curve.
		p = {c * q.x - s * q.z, q.y, s * q.x + c * q.z}
	}
	mesh_recompute_normals(&m)
	return m
}

// A zipper tooth for curve_place, the zipper `width` across: a rounded block from just
// short of the middle out to one side, so alternate teeth interlock.
curve_tooth_part :: proc(width: f32, allocator := context.allocator) -> Mesh {
	m := icosphere(2, 1, allocator)
	for &p in m.positions {
		// Halfway from the sphere to a rounded box: each coordinate pushed outward.
		box := Vec3{math.sign(p.x) * math.sqrt(abs(p.x)), math.sign(p.y) * math.sqrt(abs(p.y)), math.sign(p.z) * math.sqrt(abs(p.z))}
		q := linalg.lerp(p, box, 0.5)
		p = q * Vec3{0.3 * width, 0.12 * width, 0.14 * width} + {0.18 * width, 0, 0}
	}
	mesh_recompute_normals(&m)
	return m
}
