package sculpt

import "core:math"
import "core:math/linalg"

// Reshaping, as ZBrush's Deformation sliders and Blender's mesh transforms and filters
// do: an offset, turn, size change, skew, S bend, squeeze, noise, inflation, spherizing
// or sag of the part a mask leaves free (all that is shown, with no mask), over that
// part's bounds in the mesh's own space. Each runs as a pose (pose.odin), so a slider
// drag shows it live, set afresh from the start positions each frame, and letting go is
// one undo step; a half-free vertex takes part of it, so the mask's soft edge eases in.
// Every vertex's place is worked out from its own start alone (Noise hashes where it
// started), so serial and parallel runs agree to the bit.

Reshape_Kind :: enum u8 {
	Offset,   // moves the free part along the axes by a share of its size
	Rotate,   // turns it about its middle, about each axis in turn
	Size,     // scales it about its middle along the axes
	Skew,     // leans it along the axis, the further the higher it is
	S_Bend,   // waves it along the axis once each way, an S
	Squeeze,  // pinches its middle across the axis (or bulges it, the other way)
	Noise,    // roughens it along the surface's normals
	Inflate,  // pushes it out along the normals (or in)
	Spherize, // rounds it toward a ball
	Gravity,  // sags its outer parts down the axis, as a soft drape
}

Reshape :: struct {
	kind:   Reshape_Kind,
	axes:   bit_set[Axis], // the axes it works along; the kinds of one axis take the lowest
	amount: f32,           // Rotate and Skew: radians; the rest: a share, 1 for 100 %
	lo, hi: Vec3,          // the free part's bounds (sculptor_free_bounds), which it runs over
}

// The least Size takes the free part to: nothing would fold the surface onto itself.
RESHAPE_SIZE_MIN :: -0.95
// The furthest Skew leans: steeper is a sheet.
RESHAPE_SKEW_MAX :: math.PI / 3
// How far Noise and Inflate move at the most, as a share of the free part's size.
RESHAPE_NOISE_REACH :: 0.05
RESHAPE_INFLATE_REACH :: 0.1
// How far S bend waves each way at the most, as a share of the free part's size: a
// quarter keeps a full drag a strong S rather than a fold.
RESHAPE_S_BEND_REACH :: 0.25
// Noise's cells across the free part's largest side.
RESHAPE_NOISE_CELLS :: 8
// How small Squeeze takes the middle at the most.
@(private = "file")
SQUEEZE_LEAST :: 0.05

// Whether a kind moves vertices along the surface's normals, which the pose keeps from
// where they started.
reshape_needs_normals :: proc(kind: Reshape_Kind) -> bool {return kind == .Noise || kind == .Inflate}

// Whether a kind works along one axis, rather than any set of them or none.
reshape_one_axis :: proc(kind: Reshape_Kind) -> bool {
	#partial switch kind {
	case .Skew, .S_Bend, .Squeeze, .Gravity: return true
	}
	return false
}

// Whether a kind takes axes at all.
reshape_has_axes :: proc(kind: Reshape_Kind) -> bool {
	#partial switch kind {
	case .Noise, .Inflate, .Spherize: return false
	}
	return true
}

// What a reshape needs per vertex, worked out once for all of them.
@(private)
Reshape_Plan :: struct {
	kind:   Reshape_Kind,
	still:  bool,
	amount: f32,
	axes:   bit_set[Axis],
	i, j:   int,  // the one axis, and the axis it runs over (Skew, S bend)
	centre: Vec3,
	size:   f32,  // the largest side
	lo:     Vec3,
	extent: Vec3,
	delta:  Vec3, // Offset: the whole move
	radius: f32,  // Spherize: the ball's; Gravity: the furthest from the axis
	slope:  f32,  // Skew: the lean's tangent
}

@(private)
reshape_plan :: proc(r: Reshape) -> (p: Reshape_Plan) {
	p.kind, p.axes, p.amount = r.kind, r.axes, r.amount
	p.lo, p.extent = r.lo, r.hi - r.lo
	p.centre = (r.lo + r.hi) * 0.5
	p.size = max(p.extent.x, p.extent.y, p.extent.z)
	for a in Axis {
		if a in r.axes {
			p.i = int(a)
			break
		}
	}
	// Skew and S bend run over the up axis, or for Y over X.
	p.j = 0 if p.i == 1 else 1
	switch r.kind {
	case .Offset:
		for a in r.axes do p.delta[int(a)] = r.amount * p.size
	case .Size:
		p.amount = max(r.amount, RESHAPE_SIZE_MIN)
	case .Skew:
		p.slope = math.tan(clamp(r.amount, -RESHAPE_SKEW_MAX, RESHAPE_SKEW_MAX))
	case .Spherize:
		p.amount = clamp(r.amount, 0, 1)
		p.radius = (p.extent.x + p.extent.y + p.extent.z) / 6
	case .Gravity:
		across: Vec3 = p.extent * 0.5
		across[p.i] = 0
		p.radius = linalg.length(across)
	case .Rotate, .S_Bend, .Squeeze, .Noise, .Inflate:
	}
	axes_needed := reshape_has_axes(r.kind) && card(r.axes) == 0
	p.still = p.amount == 0 || !(p.size > 0) || axes_needed || (r.kind == .Gravity && !(p.radius > 0))
	return
}

// Where `a`, a vertex `w` free (0 to 1) when the reshape began with the normal `n`, goes.
@(private)
reshape_at :: #force_inline proc(p: ^Reshape_Plan, a, n: Vec3, w: f32) -> Vec3 {
	if p.still || w <= 0 do return a
	switch p.kind {
	case .Offset:
		return a + w * p.delta
	case .Rotate:
		q := a - p.centre
		for axis in Axis {
			if axis not_in p.axes do continue
			unit: Vec3
			unit[int(axis)] = 1
			q = turn_by(q, unit, w * p.amount)
		}
		return p.centre + q
	case .Size:
		q := a
		for axis in Axis {
			k := int(axis)
			if axis in p.axes do q[k] = p.centre[k] + (a[k] - p.centre[k]) * (1 + w * p.amount)
		}
		return q
	case .Skew:
		q := a
		q[p.i] += w * p.slope * (a[p.j] - p.centre[p.j])
		return q
	case .S_Bend:
		t := along(p, a, p.j)
		q := a
		q[p.i] += w * p.amount * p.size * RESHAPE_S_BEND_REACH * math.sin(2 * math.PI * t)
		return q
	case .Squeeze:
		t := along(p, a, p.i)
		f := max(1 - w * p.amount * math.sin(math.PI * t), SQUEEZE_LEAST)
		q := p.centre + (a - p.centre) * f
		q[p.i] = a[p.i]
		return q
	case .Noise:
		cells := RESHAPE_NOISE_CELLS / p.size
		return a + n * (w * p.amount * p.size * RESHAPE_NOISE_REACH * value_noise((a - p.lo) * cells))
	case .Inflate:
		return a + n * (w * p.amount * p.size * RESHAPE_INFLATE_REACH)
	case .Spherize:
		d := a - p.centre
		length := linalg.length(d)
		if !(length > 0) do return a
		return a + (p.centre + d * (p.radius / length) - a) * (w * p.amount)
	case .Gravity:
		d := a - p.centre
		d[p.i] = 0
		r := linalg.length(d) / p.radius
		q := a
		q[p.i] -= w * p.amount * p.size * 0.5 * r * r
		return q
	}
	return a
}

// How far along axis `k` of the bounds `a` is, 0 to 1 (0 when they are flat that way).
@(private = "file")
along :: #force_inline proc(p: ^Reshape_Plan, a: Vec3, k: int) -> f32 {
	if !(p.extent[k] > 0) do return 0
	return clamp((a[k] - p.lo[k]) / p.extent[k], 0, 1)
}

// Smooth value noise, -1 to 1, with a cell a unit wide: a hashed value at each lattice
// point, blended across the cell by smoothstep, so it has no seams and is the same at a
// place whatever else is computed.
value_noise :: proc(p: Vec3) -> f32 {
	f := Vec3{math.floor(p.x), math.floor(p.y), math.floor(p.z)}
	t := p - f
	t = t * t * (3 - 2 * t)
	x, y, z := i32(f.x), i32(f.y), i32(f.z)
	c: [8]f32
	for k in 0 ..< 8 do c[k] = lattice_value(x + i32(k & 1), y + i32(k >> 1 & 1), z + i32(k >> 2))
	x0 := math.lerp(math.lerp(c[0], c[1], t.x), math.lerp(c[2], c[3], t.x), t.y)
	x1 := math.lerp(math.lerp(c[4], c[5], t.x), math.lerp(c[6], c[7], t.x), t.y)
	return math.lerp(x0, x1, t.z)
}

// A lattice point's value, -1 to 1, from a hash of its coordinates.
@(private = "file")
lattice_value :: #force_inline proc(x, y, z: i32) -> f32 {
	h := u32(x) * 0x8da6b343 ~ u32(y) * 0xd8163841 ~ u32(z) * 0xcb1ab31f
	h ~= h >> 13
	h *= 0x85ebca6b
	h ~= h >> 16
	return f32(h & 0xffffff) / f32(0xffffff) * 2 - 1
}
