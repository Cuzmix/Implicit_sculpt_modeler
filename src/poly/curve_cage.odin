package poly

import "core:math"
import "core:math/linalg"

import "../geom"

// Quad cages made from a Bézier curve, for Model mode, as Nomad's Pipe and Lathe make
// editable low meshes: rings at each of the curve's points and `steps` between, so the
// cage's own rings sit where the curve's points do, and a corner point's ring creased so it
// stays sharp when the cage is smoothed. They are ordinary cages: every Model action, Smooth
// and Apply to sculpt work on them.

Curve_Cage_Options :: struct {
	around: int, // points round each ring, 3 to CURVE_CAGE_AROUND_MAX
	steps:  int, // rings from one curve point to the next, 1 to CURVE_CAGE_STEPS_MAX
	caps:   bool, // an open pipe's ends closed by a polygon
}

CURVE_CAGE_DEFAULTS :: Curve_Cage_Options{around = 8, steps = 2, caps = true}
CURVE_CAGE_AROUND_MAX :: 64
CURVE_CAGE_STEPS_MAX :: 16

// The curve at each point and `steps` between, by the curve's own parameter, so ring
// steps*i is point i. A closed curve does not repeat its first point.
@(private = "file")
cage_samples :: proc(points: []geom.Bezier_Point, closed: bool, steps: int) -> []geom.Bezier_Sample {
	segs := geom.bezier_segments(len(points), closed)
	count := segs * steps + (0 if closed else 1)
	out := make([]geom.Bezier_Sample, count, context.temp_allocator)
	for k in 0 ..< count {
		i, t := k / steps, f32(k % steps) / f32(steps)
		if i == segs do i, t = segs - 1, 1
		a, b, c, d := geom.bezier_controls(points, i)
		tangent := linalg.normalize0(geom.cubic_tangent(a, b, c, d, t))
		if tangent == {} do tangent = linalg.normalize0(d - a)
		r, w, tw := geom.bezier_blend(points[i], points[(i + 1) % len(points)], t)
		out[k] = {geom.cubic_at(a, b, c, d, t), tangent, 0, f32(i) + t, r, w, tw}
	}
	return out
}

// Creases the ring of `around` edges from point `first` (sharp), back round to the first
// point with `wrap`, else on to one more point (a partial lathe's open ring).
@(private = "file")
crease_ring :: proc(m: ^Mesh, first, around: int, wrap := true) {
	edges := make([dynamic]u32, 0, around, context.temp_allocator)
	for k in 0 ..< around {
		next := (k + 1) % around if wrap else k + 1
		h := find_half_edge(m, u32(first + k), u32(first + next))
		if h != NONE do append(&edges, edge_of(h))
	}
	_ = crease_edges(m, edges[:], INFINITE_SHARP)
}

// A pipe cage along the curve: a ring of `around` points at each step, each as wide as the
// curve's radius there, turned by rotation-minimising frames from `up`; quads between the
// rings, an open pipe's ends closed by a polygon with `caps`.
pipe_cage :: proc(points: []geom.Bezier_Point, closed: bool, o: Curve_Cage_Options, up: Vec3, allocator := context.allocator) -> (m: Mesh, err: Build_Error) {
	if geom.bezier_segments(len(points), closed) == 0 do return mesh_make(allocator), .Degenerate_Face
	around := clamp(o.around, 3, CURVE_CAGE_AROUND_MAX)
	steps := clamp(o.steps, 1, CURVE_CAGE_STEPS_MAX)
	samples := cage_samples(points, closed, steps)
	frames := geom.bezier_frames(samples, up, closed, context.temp_allocator)
	rings := len(samples)
	positions := make([]Vec3, rings * around, context.temp_allocator)
	for f, j in frames {
		r := max(samples[j].radius, 1e-6)
		for k in 0 ..< around {
			a := 2 * math.PI * f32(k) / f32(around)
			positions[j * around + k] = f.p + r * (math.cos(a) * f.b + math.sin(a) * f.n)
		}
	}
	sizes := make([dynamic]int, context.temp_allocator)
	corners := make([dynamic]u32, context.temp_allocator)
	joins := rings if closed else rings - 1
	for j in 0 ..< joins {
		a, b := j * around, ((j + 1) % rings) * around
		for k in 0 ..< around {
			k1 := (k + 1) % around
			// Round the ring (B toward N) then along the curve faces out.
			append(&sizes, 4)
			append(&corners, u32(a + k), u32(b + k), u32(b + k1), u32(a + k1))
		}
	}
	if !closed && o.caps {
		last := (rings - 1) * around
		append(&sizes, around, around)
		for k in 0 ..< around do append(&corners, u32(k))
		for k := around - 1; k >= 0; k -= 1 do append(&corners, u32(last + k))
	}
	m, err = mesh_from_polygons(positions, sizes[:], corners[:], allocator = allocator)
	if err != .None do return
	for p, i in points do if p.corner && (closed || (i > 0 && i < len(points) - 1)) do crease_ring(&m, i * steps * around, around)
	return
}

// A lathe cage: the curve's rings spun round `o`'s axis in `around` steps (one more, open,
// for less than a whole turn); a point on the axis is one pole whose faces are triangles; an
// open curve's ends off the axis closed by a polygon with `caps`. Faces out whichever way
// the curve runs, as geom.bezier_lathe does.
lathe_cage :: proc(points: []geom.Bezier_Point, closed: bool, lathe: geom.Lathe_Options, o: Curve_Cage_Options, allocator := context.allocator) -> (m: Mesh, err: Build_Error) {
	if geom.bezier_segments(len(points), closed) == 0 do return mesh_make(allocator), .Degenerate_Face
	axis := linalg.normalize0(lathe.axis)
	if axis == {} do return mesh_make(allocator), .Degenerate_Face
	origin := geom.lathe_origin(points, lathe)
	around := clamp(o.around, 3, CURVE_CAGE_AROUND_MAX)
	steps := clamp(o.steps, 1, CURVE_CAGE_STEPS_MAX)
	full := !(lathe.angle < 359.5)
	angle := math.to_radians(clamp(lathe.angle, 1, 360))
	cols := around if full else around + 1
	samples := cage_samples(points, closed, steps)
	rows := len(samples)
	far: f32
	radii := make([]f32, rows, context.temp_allocator)
	heights := make([]f32, rows, context.temp_allocator)
	for s, i in samples {
		d := s.p - origin
		heights[i] = linalg.dot(d, axis)
		radii[i] = linalg.length(d - heights[i] * axis)
		far = max(far, radii[i])
	}
	if !(far > 0) do return mesh_make(allocator), .Degenerate_Face
	eps := 1e-4 * far
	pole := make([]bool, rows, context.temp_allocator)
	for i in 0 ..< rows do pole[i] = radii[i] < eps
	// A ring's first point, as the faces toward the row before (start_in) and after
	// (start_out) see it: the same for a ring. A pole is a point of its own for each fan
	// that meets it, so a profile touching the axis between two rings makes two fans that
	// touch rather than one point shared by both, and a pole with no ring beside it (a run
	// along the axis) makes no point at all.
	start_in := make([]u32, rows, context.temp_allocator)
	start_out := make([]u32, rows, context.temp_allocator)
	positions := make([dynamic]Vec3, context.temp_allocator)
	for s, i in samples {
		d := s.p - origin
		r := d - heights[i] * axis
		if pole[i] {
			before := i > 0 || closed
			after := i < rows - 1 || closed
			if before && !pole[(i + rows - 1) % rows] {
				start_in[i] = u32(len(positions))
				append(&positions, origin + heights[i] * axis)
			}
			if after && !pole[(i + 1) % rows] {
				start_out[i] = u32(len(positions))
				append(&positions, origin + heights[i] * axis)
			}
			continue
		}
		start_in[i], start_out[i] = u32(len(positions)), u32(len(positions))
		across := linalg.cross(axis, r)
		for k in 0 ..< cols {
			a := angle * f32(k) / f32(around)
			append(&positions, origin + heights[i] * axis + r * math.cos(a) + across * math.sin(a))
		}
	}
	// As built, a face faces out where the profile rises along the axis (see bezier_lathe).
	volume, outward: f64
	pairs := rows if closed else rows - 1
	for i in 0 ..< pairs {
		j := (i + 1) % rows
		r := 0.5 * f64(radii[i] + radii[j])
		volume += r * r * f64(heights[j] - heights[i])
		outward += r * f64(radii[j] - radii[i])
	}
	flip := volume < 0 if abs(volume) > 1e-9 * f64(far * far * far) else outward > 0
	sizes := make([dynamic]int, context.temp_allocator)
	corners := make([dynamic]u32, context.temp_allocator)
	face :: proc(sizes: ^[dynamic]int, corners: ^[dynamic]u32, flip: bool, vs: ..u32) {
		append(sizes, len(vs))
		if flip {
			for k := len(vs) - 1; k >= 0; k -= 1 do append(corners, vs[k])
		} else {
			append(corners, ..vs)
		}
	}
	at :: proc(start: []u32, pole: []bool, i, k: int) -> u32 {return start[i] if pole[i] else start[i] + u32(k)}
	for i in 0 ..< pairs {
		j := (i + 1) % rows
		if pole[i] && pole[j] do continue
		for k in 0 ..< around {
			k1 := (k + 1) % cols
			a, b := at(start_out, pole, i, k), at(start_out, pole, i, k1)
			c, d := at(start_in, pole, j, k), at(start_in, pole, j, k1)
			// The quad (a, b, d, c) of geom.bezier_lathe's two triangles, a triangle at a pole.
			switch {
			case pole[i]: face(&sizes, &corners, flip, a, d, c)
			case pole[j]: face(&sizes, &corners, flip, a, b, d)
			case:         face(&sizes, &corners, flip, a, b, d, c)
			}
		}
	}
	if !closed && o.caps && full {
		ends := [2]int{0, rows - 1}
		for e, n in ends {
			if pole[e] do continue
			ring := make([]u32, around, context.temp_allocator)
			for k in 0 ..< around do ring[k] = start_in[e] + u32(around - 1 - k if n == 0 else k)
			face(&sizes, &corners, flip, ..ring)
		}
	}
	m, err = mesh_from_polygons(positions[:], sizes[:], corners[:], allocator = allocator)
	if err != .None do return
	for p, i in points {
		row := i * steps
		if !p.corner || row >= rows || pole[row] do continue
		if !closed && (i == 0 || i == len(points) - 1) do continue
		crease_ring(&m, int(start_in[row]), around, wrap = full)
	}
	return
}
