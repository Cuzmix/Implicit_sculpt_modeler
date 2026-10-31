package geom

import "core:math"
import "core:math/linalg"

// A tube swept along a Bézier curve, as Nomad's Tube and Blender's curve bevel make it:
// the curve at even steps, a rotation-minimising frame at each with the points' twist,
// and at each step a profile outline sized by the radius there.

Tube_Profile :: enum u8 {
	Round,
	Square,
	Ribbon, // a flat band, `flatness` of its width thick
	Star, // five points
	Half_Round, // a D, its flat side toward -N
}

// Where a tube's radius comes from, as Nomad cycles it: one for the whole tube, the first
// point's blending into the last's, or each point's own.
Tube_Radius :: enum u8 {
	One,
	Ends,
	Each,
}

Tube_Caps :: enum u8 {
	Flat,
	Round,
	Open,
}

Tube_Options :: struct {
	profile:  Tube_Profile,
	radius:   Tube_Radius,
	one:      f32, // the radius with One
	sides:    int, // round the profile: 3 to TUBE_SIDES_MAX
	density:  f32, // rings per radius of length: more is smoother along the curve (3 keeps a bend round)
	caps:     Tube_Caps,
	flatness: f32, // a Ribbon's thickness over its width
}

TUBE_DEFAULTS :: Tube_Options{profile = .Round, radius = .Each, one = 0.05, sides = 16, density = 3, caps = .Round, flatness = 0.25}
TUBE_SIDES_MAX :: 64
TUBE_RINGS_MAX :: 4096

// How many rings a round cap adds.
TUBE_CAP_RINGS :: 4

// The profile's outline: `sides` points round the origin, x across the curve and y out
// from it, of radius about one.
tube_outline :: proc(o: Tube_Options, allocator := context.temp_allocator) -> [][2]f32 {
	n := clamp(o.sides, 3, TUBE_SIDES_MAX)
	out := make([][2]f32, n, allocator)
	for k in 0 ..< n {
		a := 2 * math.PI * f32(k) / f32(n)
		c, s := math.cos(a), math.sin(a)
		switch o.profile {
		case .Round:
			out[k] = {c, s}
		case .Square:
			// The circle pushed out onto the square round it.
			m := max(abs(c), abs(s))
			out[k] = {c / m, s / m}
		case .Ribbon:
			m := max(abs(c), abs(s) / max(o.flatness, 0.01))
			out[k] = {c / m, s / m}
		case .Star:
			// Five points: the radius swings between one and two fifths of it.
			r := 0.7 + 0.3 * math.cos(5 * a)
			out[k] = {r * c, r * s}
		case .Half_Round:
			out[k] = {c, max(s, -0.15)}
		}
	}
	return out
}

// The radius at sample `s` of a curve `length` long.
@(private = "file")
tube_radius_at :: proc(o: Tube_Options, points: []Bezier_Point, s: Bezier_Sample, length: f32) -> f32 {
	switch o.radius {
	case .One:
		return o.one
	case .Ends:
		f := s.s / length if length > 0 else 0
		return math.lerp(points[0].radius, points[len(points) - 1].radius, f)
	case .Each:
		return s.radius
	}
	return o.one
}

// A tube along the curve through `points` (closed or not), with `up` the way the first
// frame's normal faces. ok is false for fewer than two points or no radius anywhere.
bezier_tube :: proc(points: []Bezier_Point, closed: bool, o: Tube_Options, up: Vec3, allocator := context.allocator) -> (m: Mesh, ok: bool) {
	if bezier_segments(len(points), closed) == 0 do return {}, false
	mean: f32
	switch o.radius {
	case .One:
		mean = o.one
	case .Ends:
		mean = 0.5 * (points[0].radius + points[len(points) - 1].radius)
	case .Each:
		for p in points do mean += p.radius
		mean /= f32(len(points))
	}
	if !(mean > 0) do return {}, false
	length := bezier_length(points, closed)
	if !(length > 0) do return {}, false
	density := clamp(o.density, 0.05, 16)
	spacing := max(mean / density, length / TUBE_RINGS_MAX)
	samples := bezier_sample(points, closed, spacing, context.temp_allocator)
	if len(samples) < 2 do return {}, false
	frames := bezier_frames(samples, up, closed, context.temp_allocator)
	outline := tube_outline(o)
	sides := len(outline)
	rings := len(samples)
	m.positions = make([dynamic]Vec3, 0, (rings + 2 * TUBE_CAP_RINGS) * sides + 2, allocator)
	m.indices = make([dynamic]u32, 0, 6 * (rings + 2 * TUBE_CAP_RINGS + 1) * sides, allocator)
	ring_at :: proc(m: ^Mesh, f: Curve_Frame, outline: [][2]f32, r: f32, middle: Vec3) {
		for q in outline do append(&m.positions, middle + r * (q.x * f.b + q.y * f.n))
	}
	join :: proc(m: ^Mesh, a, b: u32, sides: int) {
		S := u32(sides)
		for k in 0 ..< S {
			p, q := a + k, a + (k + 1) % S
			// Round the ring (B towards N) then along T faces out.
			append(&m.indices, p, b + k, q, q, b + k, b + (k + 1) % S)
		}
	}
	radii := make([]f32, rings, context.temp_allocator)
	for s, i in samples do radii[i] = max(tube_radius_at(o, points, s, length), 0)
	round := !closed && o.caps == .Round
	// A round cap's rings before the first: the profile shrinking by a quarter circle,
	// stepping back along the curve.
	if round {
		f, r := frames[0], radii[0]
		for c in 0 ..< TUBE_CAP_RINGS {
			a := 0.5 * math.PI * f32(TUBE_CAP_RINGS - c) / f32(TUBE_CAP_RINGS + 1)
			ring_at(&m, f, outline, r * math.cos(a), f.p - f.t * (r * math.sin(a)))
		}
	}
	first := u32(len(m.positions))
	for f, i in frames do ring_at(&m, f, outline, radii[i], f.p)
	if round {
		f, r := frames[rings - 1], radii[rings - 1]
		for c in 1 ..= TUBE_CAP_RINGS {
			a := 0.5 * math.PI * f32(c) / f32(TUBE_CAP_RINGS + 1)
			ring_at(&m, f, outline, r * math.cos(a), f.p + f.t * (r * math.sin(a)))
		}
	}
	total := len(m.positions) / sides
	for i in 0 ..< total - 1 do join(&m, u32(i * sides), u32((i + 1) * sides), sides)
	if closed {
		join(&m, u32((total - 1) * sides), first, sides)
	} else if o.caps != .Open {
		// The ends: a fan from a point on the curve (a round cap's tip) to the end rings.
		head := frames[0].p - (frames[0].t * radii[0] if round else 0)
		tail := frames[rings - 1].p + (frames[rings - 1].t * radii[rings - 1] if round else 0)
		start, end := u32(len(m.positions)), u32(len(m.positions) + 1)
		append(&m.positions, head, tail)
		last := u32((total - 1) * sides)
		S := u32(sides)
		for k in 0 ..< S {
			append(&m.indices, start, k, (k + 1) % S)
			append(&m.indices, end, last + (k + 1) % S, last + k)
		}
	}
	m.normals = make([dynamic]Vec3, len(m.positions), allocator)
	mesh_recompute_normals(&m)
	return m, true
}

// The way a curve's first tube frame faces: square to its first tangent, toward +Y where
// it can, else +Z.
tube_up :: proc(points: []Bezier_Point) -> Vec3 {
	if len(points) < 2 do return {0, 1, 0}
	t := linalg.normalize0(points[1].p - points[0].p)
	if abs(linalg.dot(t, Vec3{0, 1, 0})) < 0.95 do return {0, 1, 0}
	return {0, 0, 1}
}
