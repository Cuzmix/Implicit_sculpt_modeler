package sculpt

import "core:math"
import "core:math/linalg"

import "../jobs"

// Deformers, as ZBrush's gizmo deformers and Blender's Simple Deform do: a bend, twist or
// taper of the part a mask leaves free (all that is shown, with no mask), along one of
// the mesh's own axes over that part's extent, from a fixed end that stays put to the far
// end that moves most. Each runs as a pose (pose.odin), so it is set afresh from the
// positions it started from each frame of a drag and is one undo step when it ends. A
// half-free vertex takes the deformation by part of the amount, as a pose's turn does,
// so the mask's soft edge eases into it.

Deform_Kind :: enum u8 {
	Bend,
	Twist,
	Taper,
}

Deform :: struct {
	kind:      Deform_Kind,
	along:     Axis,
	toward:    Axis, // Bend: the axis it bends toward; the amount's sign picks the side
	from_plus: bool, // the + end along the axis stays put, not the - end
	amount:    f32,  // Bend and Twist: radians from end to end; Taper: the far end's scale less 1
	lo, hi:    Vec3, // the free part's bounds (sculptor_free_bounds), which it runs over
}

// Below this many radians a bend uses the first terms of its series, where sin φ / φ and
// (1 - cos φ) / φ would lose their digits to the division.
@(private = "file")
BEND_SERIES :: 1e-4

// The smallest scale Taper takes an end to: a point would fold the surface onto itself.
DEFORM_TAPER_MIN :: -0.95

// The largest bend, in radians, that does not fold the inside of the bend over itself:
// a bend's radius stays more than the half thickness toward the side it bends to (and
// at most a whole turn).
deform_bend_limit :: proc(d: Deform) -> f32 {
	i, j := int(d.along), int(d.toward)
	length, half := d.hi[i] - d.lo[i], (d.hi[j] - d.lo[j]) * 0.5
	if i == j || !(half > 0) do return 2 * math.PI
	return min(2 * math.PI, 0.95 * length / half)
}

// What a deformation needs per vertex, worked out once for all of them.
@(private)
Deform_Plan :: struct {
	kind:        Deform_Kind,
	i, j:        int,  // the axis it runs along, and for a bend the one it bends toward
	still:       bool, // it moves nothing
	centre:      Vec3,
	fixed, dir:  f32,  // the fixed end's coordinate along the axis, and +1 or -1 toward the far end
	length:      f32,
	per_length:  f32,  // the amount per unit along: radians, or scale
	axis:        Vec3, // Twist: the unit axis
}

@(private)
deform_plan :: proc(d: Deform) -> (p: Deform_Plan) {
	p.kind, p.i, p.j = d.kind, int(d.along), int(d.toward)
	p.length = d.hi[p.i] - d.lo[p.i]
	p.centre = (d.lo + d.hi) * 0.5
	p.fixed = d.hi[p.i] if d.from_plus else d.lo[p.i]
	p.dir = -1 if d.from_plus else 1
	p.axis[p.i] = 1
	amount := d.amount
	switch d.kind {
	case .Bend:
		limit := deform_bend_limit(d)
		amount = clamp(amount, -limit, limit)
	case .Taper:
		amount = max(amount, DEFORM_TAPER_MIN)
	case .Twist:
	}
	p.still = amount == 0 || !(p.length > 0) || (d.kind == .Bend && p.i == p.j)
	if !p.still do p.per_length = amount / p.length
	return
}

// Where `a`, a vertex `w` free (0 to 1) when the deformation began, goes.
@(private)
deform_at :: #force_inline proc(p: ^Deform_Plan, a: Vec3, w: f32) -> Vec3 {
	if p.still || w <= 0 do return a
	i := p.i
	// How far along from the fixed end; the bounds are the free part's, so no free
	// vertex is outside them.
	s := clamp((a[i] - p.fixed) * p.dir, 0, p.length)
	switch p.kind {
	case .Twist:
		return p.centre + turn_by(a - p.centre, p.axis, w * p.per_length * s)
	case .Taper:
		q := p.centre + (a - p.centre) * (1 + w * p.per_length * s)
		q[i] = a[i]
		return q
	case .Bend:
		// The line through the centre along the axis becomes an arc of the same length,
		// from the fixed end, turning by the amount (Blender's bend with its radius taken
		// out, so a tiny amount does not divide by nearly nothing): at s along and x
		// across, s'' = s sin φ / φ - x sin φ and x'' = x cos φ + s (1 - cos φ) / φ, with
		// φ the angle turned by s. Both come from the half angle, one sine and cosine.
		j := p.j
		phi := w * p.per_length * s
		x := a[j] - p.centre[j]
		sh, ch := math.sin(phi * 0.5), math.cos(phi * 0.5)
		sn, cs := 2 * sh * ch, 1 - 2 * sh * sh
		sinc, versc: f32
		if abs(phi) < BEND_SERIES {
			sinc, versc = 1 - phi * phi / 6, phi * 0.5 - phi * phi * phi / 24
		} else {
			sinc, versc = sn / phi, 2 * sh * sh / phi
		}
		q := a
		q[i] = p.fixed + p.dir * (s * sinc - x * sn)
		q[j] = p.centre[j] + x * cs + s * versc
		return q
	}
	return a
}

// The bounds of the vertices a pose or deformer would move (any part free of the mask
// and shown), in the mesh's own space. ok is false when none is. Starts nothing.
sculptor_free_bounds :: proc(s: ^Sculptor) -> (lo, hi: Vec3, ok: bool) {
	Job :: struct {
		s:      ^Sculptor,
		lo, hi: []Vec3,
		any:    []bool,
	}
	n := len(s.nodes)
	job := Job{s, make([]Vec3, n, context.temp_allocator), make([]Vec3, n, context.temp_allocator), make([]bool, n, context.temp_allocator)}
	jobs.parallel_ranges(s.pool, n, &job, proc(data: rawptr, first, last: int) {
		job := cast(^Job)data
		s := job.s
		for id in first ..< last {
			node := s.nodes[id]
			lo, hi := Vec3(math.F32_MAX), Vec3(-math.F32_MAX)
			for v in node.vert_first ..< node.vert_first + node.vert_count {
				if shield(s.fade, s.mask, v) <= 0 do continue
				p := s.mesh.positions[v]
				lo, hi = linalg.min(lo, p), linalg.max(hi, p)
				job.any[id] = true
			}
			job.lo[id], job.hi[id] = lo, hi
		}
	}, NODE_GRAIN)
	// Least and greatest come out the same in any order, so the split cannot change them.
	lo, hi = Vec3(math.F32_MAX), Vec3(-math.F32_MAX)
	for found, id in job.any {
		if !found do continue
		lo, hi, ok = linalg.min(lo, job.lo[id]), linalg.max(hi, job.hi[id]), true
	}
	if !ok do lo, hi = {}, {}
	return
}
