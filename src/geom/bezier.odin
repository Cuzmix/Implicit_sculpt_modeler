package geom

import "core:math"
import "core:math/linalg"

// Editable Bézier curves, as Nomad's Tube and editable strokes, Blender's curve objects and
// ZBrush's curve brushes keep them: control points, each with a handle in and a handle out,
// joined by cubic segments. Each point also carries the values a curve's uses read along it
// (a tube's radius, a stroke's intensity, a twist), which change smoothly from point to point.
// A drawn stroke becomes such a curve by fitting (bezier_fit), and every use samples it at
// even steps along its length (bezier_sample). Nothing here runs on the job pool: a curve has
// tens of points, and sampling one is far below a millisecond.

Bezier_Point :: struct {
	p:         Vec3,
	h_in:      Vec3, // the handle towards the previous point, as an offset from p
	h_out:     Vec3, // the handle towards the next point, as an offset from p
	radius:    f32,
	intensity: f32,
	twist:     f32, // radians about the curve, added to the frame there
	corner:    bool, // the handles turn freely; a smooth point keeps them in one line
}

// A point along a sampled curve: where, which way the curve runs, how far along it, which
// segment and parameter it came from, and the point values blended there.
Bezier_Sample :: struct {
	p:         Vec3,
	t:         Vec3, // unit tangent
	s:         f32, // the length along the curve from its start
	u:         f32, // the segment index plus the parameter within it
	radius:    f32,
	intensity: f32,
	twist:     f32,
}

// Each segment is measured as this many straight pieces. The pieces keep the length within
// about 0.01 % on the curves a hand draws, and a fixed count keeps every sampling of the
// same curve identical.
BEZIER_PIECES :: 64

// The number of cubic segments of a curve of `count` points.
bezier_segments :: proc(count: int, closed: bool) -> int {
	if count < 2 do return 0
	return count if closed else count - 1
}

// The four control positions of segment `i`.
bezier_controls :: proc(points: []Bezier_Point, i: int) -> (a, b, c, d: Vec3) {
	p, q := points[i], points[(i + 1) % len(points)]
	return p.p, p.p + p.h_out, q.p + q.h_in, q.p
}

// The point at parameter `t` (0 to 1) of the cubic a, b, c, d.
cubic_at :: proc(a, b, c, d: Vec3, t: f32) -> Vec3 {
	s := 1 - t
	return s * s * s * a + 3 * s * s * t * b + 3 * s * t * t * c + t * t * t * d
}

// The derivative at `t` of the cubic a, b, c, d.
cubic_tangent :: proc(a, b, c, d: Vec3, t: f32) -> Vec3 {
	s := 1 - t
	return 3 * s * s * (b - a) + 6 * s * t * (c - b) + 3 * t * t * (d - c)
}

// The position at `u`, a segment index plus the parameter within it.
bezier_at :: proc(points: []Bezier_Point, closed: bool, u: f32) -> Vec3 {
	segs := bezier_segments(len(points), closed)
	if segs == 0 do return points[0].p if len(points) > 0 else {}
	i, t := bezier_split_u(u, segs)
	a, b, c, d := bezier_controls(points, i)
	return cubic_at(a, b, c, d, t)
}

// The segment and the parameter within it of `u`, clamped to the curve.
@(private = "file")
bezier_split_u :: proc(u: f32, segs: int) -> (int, f32) {
	if !(u > 0) do return 0, 0
	if u >= f32(segs) do return segs - 1, 1
	i := int(u)
	return i, u - f32(i)
}

// The values of point `a` blended towards point `b` by `t`: smoothstep, so the values ease
// out of each point and the radius never kinks at one.
bezier_blend :: proc(a, b: Bezier_Point, t: f32) -> (radius, intensity, twist: f32) {
	w := t * t * (3 - 2 * t)
	return math.lerp(a.radius, b.radius, w), math.lerp(a.intensity, b.intensity, w), math.lerp(a.twist, b.twist, w)
}

// The length of the curve, measured as BEZIER_PIECES straight pieces a segment.
bezier_length :: proc(points: []Bezier_Point, closed: bool) -> f32 {
	total: f32
	for i in 0 ..< bezier_segments(len(points), closed) {
		a, b, c, d := bezier_controls(points, i)
		prev := a
		for k in 1 ..= BEZIER_PIECES {
			q := cubic_at(a, b, c, d, f32(k) / BEZIER_PIECES)
			total += linalg.length(q - prev)
			prev = q
		}
	}
	return total
}

// The curve at even steps of about `spacing` along its length, both ends kept (a closed
// curve's end is its start again, which is not repeated). Nil for a curve of fewer than two
// points or a spacing that is not positive.
bezier_sample :: proc(points: []Bezier_Point, closed: bool, spacing: f32, allocator := context.allocator) -> []Bezier_Sample {
	segs := bezier_segments(len(points), closed)
	if segs == 0 || !(spacing > 0) do return nil
	// The measured pieces: where each ends and the length up to it.
	n := segs * BEZIER_PIECES
	at := make([]Vec3, n + 1, context.temp_allocator)
	run := make([]f32, n + 1, context.temp_allocator)
	at[0] = points[0].p
	for i in 0 ..< segs {
		a, b, c, d := bezier_controls(points, i)
		for k in 1 ..= BEZIER_PIECES {
			j := i * BEZIER_PIECES + k
			at[j] = cubic_at(a, b, c, d, f32(k) / BEZIER_PIECES)
			run[j] = run[j - 1] + linalg.length(at[j] - at[j - 1])
		}
	}
	length := run[n]
	steps := max(1, int(math.round(length / spacing)))
	count := steps if closed else steps + 1
	out := make([]Bezier_Sample, count, allocator)
	j := 0
	for k in 0 ..< count {
		want := length * f32(k) / f32(steps)
		for j < n - 1 && run[j + 1] < want do j += 1
		piece := run[j + 1] - run[j]
		f := clamp((want - run[j]) / piece, 0, 1) if piece > 0 else 0
		u := (f32(j) + f) / BEZIER_PIECES
		if !closed && k == count - 1 do u = f32(segs)
		i, t := bezier_split_u(u, segs)
		a, b, c, d := bezier_controls(points, i)
		tangent := linalg.normalize0(cubic_tangent(a, b, c, d, t))
		if tangent == {} do tangent = linalg.normalize0(d - a)
		r, w, tw := bezier_blend(points[i], points[(i + 1) % len(points)], t)
		out[k] = {cubic_at(a, b, c, d, t), tangent, want, u, r, w, tw}
	}
	return out
}

// Frames along sampled points that turn as little as the curve lets them (rotation
// minimising frames by double reflection, Wang and others 2008), so a long tube never
// twists by itself; then each sample's own twist turns its frame about the tangent. The
// first frame's normal is `up` made square to the tangent (any square vector when `up` runs
// along it). With `closed` the twist the frames gather round the loop is spread back along
// it, so the last frame meets the first.
bezier_frames :: proc(samples: []Bezier_Sample, up: Vec3, closed: bool, allocator := context.allocator) -> []Curve_Frame {
	frames := make([]Curve_Frame, len(samples), allocator)
	if len(samples) == 0 do return frames
	t0 := samples[0].t
	n0 := up - linalg.dot(up, t0) * t0
	n0 = linalg.normalize(n0) if linalg.length(n0) > 1e-4 else any_square_to(t0)
	frames[0] = {samples[0].p, t0, n0, linalg.cross(t0, n0)}
	for i in 1 ..< len(samples) {
		prev := frames[i - 1]
		frames[i] = {samples[i].p, samples[i].t, rmf_step(prev.p, prev.t, prev.n, samples[i].p, samples[i].t), {}}
	}
	if closed && len(samples) > 2 {
		// How far round the frame has come after the last step back to the start.
		last := frames[len(frames) - 1]
		back := rmf_step(last.p, last.t, last.n, frames[0].p, frames[0].t)
		gap := math.atan2(linalg.dot(linalg.cross(back, frames[0].n), frames[0].t), linalg.dot(back, frames[0].n))
		for &f, i in frames do f.n = turn_about(f.n, f.t, gap * f32(i) / f32(len(frames)))
	}
	for &f, i in frames {
		f.n = linalg.normalize0(turn_about(f.n, f.t, samples[i].twist))
		f.b = linalg.cross(f.t, f.n)
	}
	return frames
}

// One double-reflection step: the normal at (p0, t0) carried to (p1, t1).
@(private = "file")
rmf_step :: proc(p0, t0, n0, p1, t1: Vec3) -> Vec3 {
	v1 := p1 - p0
	c1 := linalg.dot(v1, v1)
	if c1 < 1e-20 do return n0
	nl := n0 - (2 / c1) * linalg.dot(v1, n0) * v1
	tl := t0 - (2 / c1) * linalg.dot(v1, t0) * v1
	v2 := t1 - tl
	c2 := linalg.dot(v2, v2)
	n := nl - (2 / c2) * linalg.dot(v2, nl) * v2 if c2 > 1e-20 else nl
	// Rounding drifts it off square over many steps; take the drift out each step.
	n -= linalg.dot(n, t1) * t1
	return linalg.normalize(n) if linalg.length(n) > 1e-6 else n0
}

// `v` turned by `angle` radians about unit `axis` (Rodrigues).
@(private = "file")
turn_about :: proc(v, axis: Vec3, angle: f32) -> Vec3 {
	if angle == 0 do return v
	c, s := math.cos(angle), math.sin(angle)
	return v * c + linalg.cross(axis, v) * s + axis * linalg.dot(axis, v) * (1 - c)
}

// The parameter `u` of the curve's nearest point to `q`, the point, and its distance:
// the nearest of the measured pieces, then refined on its segment. `project` maps
// positions before measuring (say, onto the screen) and may be nil.
bezier_nearest :: proc(points: []Bezier_Point, closed: bool, q: Vec3, project: proc(p: Vec3) -> Vec3 = nil) -> (u: f32, at: Vec3, dist: f32) {
	segs := bezier_segments(len(points), closed)
	if segs == 0 do return 0, points[0].p if len(points) > 0 else {}, max(f32)
	map_p := proc(project: proc(p: Vec3) -> Vec3, p: Vec3) -> Vec3 {return project(p) if project != nil else p}
	dist = max(f32)
	for i in 0 ..< segs {
		a, b, c, d := bezier_controls(points, i)
		for k in 0 ..= BEZIER_PIECES {
			t := f32(k) / BEZIER_PIECES
			p := cubic_at(a, b, c, d, t)
			if l := linalg.length(map_p(project, p) - q); l < dist do u, at, dist = f32(i) + t, p, l
		}
	}
	// Halve a bracket round the best piece a few times.
	i, t := bezier_split_u(u, segs)
	a, b, c, d := bezier_controls(points, i)
	step := f32(1) / BEZIER_PIECES
	for _ in 0 ..< 12 {
		step *= 0.5
		cands := [2]f32{t - step, t + step}
		for cand in cands {
			if cand < 0 || cand > 1 do continue
			p := cubic_at(a, b, c, d, cand)
			if l := linalg.length(map_p(project, p) - q); l < dist do t, at, dist = cand, p, l
		}
	}
	return f32(i) + t, at, dist
}

// Adds a point at `u` without changing the curve's shape (de Casteljau's split of its
// segment), its values blended from its neighbours. Returns the new point's index, or -1
// when `u` is not inside a segment.
bezier_insert :: proc(points: ^[dynamic]Bezier_Point, closed: bool, u: f32) -> int {
	segs := bezier_segments(len(points), closed)
	if segs == 0 do return -1
	i, t := bezier_split_u(u, segs)
	if !(t > 0 && t < 1) do return -1
	j := (i + 1) % len(points)
	a, b, c, d := bezier_controls(points[:], i)
	ab, bc, cd := linalg.lerp(a, b, t), linalg.lerp(b, c, t), linalg.lerp(c, d, t)
	abc, bcd := linalg.lerp(ab, bc, t), linalg.lerp(bc, cd, t)
	m := linalg.lerp(abc, bcd, t)
	r, w, tw := bezier_blend(points[i], points[j], t)
	points[i].h_out = ab - a
	points[j].h_in = cd - d
	inject_at(points, i + 1, Bezier_Point{p = m, h_in = abc - m, h_out = bcd - m, radius = r, intensity = w, twist = tw})
	return i + 1
}

// Keeps a smooth point's handles in one line after one of them moved: the other turns to
// point the opposite way and keeps its own length. A corner point is left as it is.
bezier_align_handles :: proc(point: ^Bezier_Point, moved_out: bool) {
	if point.corner do return
	if moved_out {
		l := linalg.length(point.h_in)
		point.h_in = -l * linalg.normalize0(point.h_out)
	} else {
		l := linalg.length(point.h_out)
		point.h_out = -l * linalg.normalize0(point.h_in)
	}
}

// Makes point `i` smooth: its handles in one line, along the line between its neighbours
// (Catmull-Rom's tangent), each a third of the way to its neighbour. The ends of an open
// curve point at their one neighbour.
bezier_make_smooth :: proc(points: []Bezier_Point, closed: bool, i: int) {
	n := len(points)
	if n < 2 do return
	p := &points[i]
	p.corner = false
	has_prev, has_next := closed || i > 0, closed || i < n - 1
	prev := points[(i + n - 1) % n].p if has_prev else p.p
	next := points[(i + 1) % n].p if has_next else p.p
	dir := linalg.normalize0(next - prev)
	p.h_in = -dir * linalg.length(p.p - prev) / 3 if has_prev else {}
	p.h_out = dir * linalg.length(next - p.p) / 3 if has_next else {}
}

// Makes point `i` a corner whose handles point straight at its neighbours, a third of the
// way, so the segments either side leave it in straight lines.
bezier_make_corner :: proc(points: []Bezier_Point, closed: bool, i: int) {
	n := len(points)
	if n < 2 do return
	p := &points[i]
	p.corner = true
	p.h_in = (points[(i + n - 1) % n].p - p.p) / 3 if closed || i > 0 else {}
	p.h_out = (points[(i + 1) % n].p - p.p) / 3 if closed || i < n - 1 else {}
}

// The fewest cubic segments through `input` that stay within `tolerance` of every input
// point (Schneider's fitting, Graphics Gems 1990): one cubic by least squares with the end
// tangents fixed, a few Newton steps on the parameters when it is close, else a split at
// the worst point with the tangent there shared by both halves, so every joint is smooth.
// Also returns, for each control point, the index of the input point it sits on, which a
// caller uses to carry pen pressure or other values from the input. Repeated input points
// are skipped; fewer than two distinct ones give nothing.
bezier_fit :: proc(input: []Vec3, tolerance: f32, allocator := context.allocator) -> (points: []Bezier_Point, source: []int) {
	kept := make([dynamic]Vec3, 0, len(input), context.temp_allocator)
	index := make([dynamic]int, 0, len(input), context.temp_allocator)
	for p, i in input {
		if len(kept) > 0 && linalg.length(p - kept[len(kept) - 1]) < 1e-7 do continue
		append(&kept, p)
		append(&index, i)
	}
	if len(kept) < 2 do return nil, nil
	fit := Fit{d = kept[:], tolerance = max(tolerance, 1e-6)}
	fit.out = make([dynamic]Bezier_Point, context.temp_allocator)
	fit.at = make([dynamic]int, context.temp_allocator)
	last := len(kept) - 1
	append(&fit.out, Bezier_Point{p = kept[0]})
	append(&fit.at, 0)
	fit_cubic(&fit, 0, last, fit_end_tangent(kept[:], 0, 1), fit_end_tangent(kept[:], last, -1), 0)
	points = make([]Bezier_Point, len(fit.out), allocator)
	source = make([]int, len(fit.out), allocator)
	copy(points, fit.out[:])
	for k, i in fit.at do source[i] = index[k]
	return
}

@(private = "file")
Fit :: struct {
	d:         []Vec3,
	tolerance: f32,
	out:       [dynamic]Bezier_Point,
	at:        [dynamic]int,
}

// How deep the fit splits at most: 2^24 segments is more than any stroke holds, and the cap
// keeps a pathological input from recursing without end.
@(private = "file")
FIT_MAX_DEPTH :: 24

// The unit tangent at end `i` of the input, looking `dir` (1 forwards, -1 back), over the
// first few points so the hand's last twitch does not decide it.
@(private = "file")
fit_end_tangent :: proc(d: []Vec3, i, dir: int) -> Vec3 {
	j := clamp(i + dir * min(3, len(d) - 1), 0, len(d) - 1)
	return linalg.normalize0(d[j] - d[i])
}

// Appends the segments for d[first..last] that leave d[first] along t1 and reach d[last]
// along t2 (t2 points back, into the segment).
@(private = "file")
fit_cubic :: proc(f: ^Fit, first, last: int, t1, t2: Vec3, depth: int) {
	d := f.d
	if last - first == 1 {
		l := linalg.length(d[last] - d[first]) / 3
		fit_emit(f, first, last, d[first] + t1 * l, d[last] + t2 * l)
		return
	}
	u := fit_chord_params(d, first, last)
	b1, b2 := fit_least_squares(d, first, last, u, t1, t2)
	worst, split := fit_error(d, first, last, u, b1, b2)
	tol2 := f.tolerance * f.tolerance
	if worst <= tol2 {
		fit_emit(f, first, last, b1, b2)
		return
	}
	if worst <= 4 * tol2 {
		for _ in 0 ..< 4 {
			fit_reparameterize(d, first, last, u, b1, b2)
			b1, b2 = fit_least_squares(d, first, last, u, t1, t2)
			worst, split = fit_error(d, first, last, u, b1, b2)
			if worst <= tol2 {
				fit_emit(f, first, last, b1, b2)
				return
			}
		}
	}
	if depth >= FIT_MAX_DEPTH {
		fit_emit(f, first, last, b1, b2)
		return
	}
	split = clamp(split, first + 1, last - 1)
	centre := linalg.normalize0(d[split - 1] - d[split + 1])
	if centre == {} do centre = linalg.normalize0(d[first] - d[last])
	fit_cubic(f, first, split, t1, centre, depth + 1)
	fit_cubic(f, split, last, -centre, t2, depth + 1)
}

// Records the segment d[first] to d[last] with inner controls b1 and b2.
@(private = "file")
fit_emit :: proc(f: ^Fit, first, last: int, b1, b2: Vec3) {
	f.out[len(f.out) - 1].h_out = b1 - f.d[first]
	append(&f.out, Bezier_Point{p = f.d[last], h_in = b2 - f.d[last]})
	append(&f.at, last)
}

// Parameters for d[first..last] by the length along them, from 0 to 1.
@(private = "file")
fit_chord_params :: proc(d: []Vec3, first, last: int) -> []f32 {
	u := make([]f32, last - first + 1, context.temp_allocator)
	for i in first + 1 ..= last do u[i - first] = u[i - first - 1] + linalg.length(d[i] - d[i - 1])
	total := u[last - first]
	for &x in u do x = x / total if total > 0 else 0
	return u
}

// The inner controls of the cubic from d[first] along t1 to d[last] along t2 nearest the
// points at parameters u, by least squares on the two handle lengths. When the system is
// singular or gives a handle that runs backwards, both handles are a third of the chord.
@(private = "file")
fit_least_squares :: proc(d: []Vec3, first, last: int, u: []f32, t1, t2: Vec3) -> (Vec3, Vec3) {
	p0, p3 := d[first], d[last]
	c00, c01, c11, x0, x1: f32
	for i in first ..= last {
		t := u[i - first]
		s := 1 - t
		b0, b1, b2, b3 := s * s * s, 3 * s * s * t, 3 * s * t * t, t * t * t
		a1, a2 := t1 * b1, t2 * b2
		c00 += linalg.dot(a1, a1)
		c01 += linalg.dot(a1, a2)
		c11 += linalg.dot(a2, a2)
		rest := d[i] - (p0 * (b0 + b1) + p3 * (b2 + b3))
		x0 += linalg.dot(a1, rest)
		x1 += linalg.dot(a2, rest)
	}
	det := c00 * c11 - c01 * c01
	chord := linalg.length(p3 - p0)
	alpha1, alpha2: f32
	if abs(det) > 1e-12 * max(c00 * c11, 1e-30) {
		alpha1 = (x0 * c11 - x1 * c01) / det
		alpha2 = (c00 * x1 - c01 * x0) / det
	}
	if !(alpha1 > 1e-6 * chord) || !(alpha2 > 1e-6 * chord) do alpha1, alpha2 = chord / 3, chord / 3
	return p0 + t1 * alpha1, p3 + t2 * alpha2
}

// The worst squared distance from a point to the cubic at its parameter, and where it is.
@(private = "file")
fit_error :: proc(d: []Vec3, first, last: int, u: []f32, b1, b2: Vec3) -> (worst: f32, at: int) {
	at = (first + last) / 2
	for i in first + 1 ..< last {
		q := cubic_at(d[first], b1, b2, d[last], u[i - first]) - d[i]
		if e := linalg.dot(q, q); e > worst do worst, at = e, i
	}
	return
}

// One Newton step on each parameter towards the cubic's nearest point to its input point.
@(private = "file")
fit_reparameterize :: proc(d: []Vec3, first, last: int, u: []f32, b1, b2: Vec3) {
	a, b, c, e := d[first], b1, b2, d[last]
	for i in first + 1 ..< last {
		t := u[i - first]
		q := cubic_at(a, b, c, e, t) - d[i]
		q1 := cubic_tangent(a, b, c, e, t)
		s := 1 - t
		q2 := 6 * s * (c - 2 * b + a) + 6 * t * (e - 2 * c + b)
		den := linalg.dot(q1, q1) + linalg.dot(q, q2)
		if abs(den) > 1e-12 do u[i - first] = clamp(t - linalg.dot(q, q1) / den, 0, 1)
	}
}
