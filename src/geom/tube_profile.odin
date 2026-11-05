package geom

import "core:math"
import "core:math/linalg"

// A tube's cross-section as a closed Bézier outline in its own plane (x across the curve, y
// out from it, about -1 to 1), edited with the same points, handles and handle types as a
// curve in space, as Blender's custom bevel profile and 3D-Coat's curve profiles are. The
// presets (Tube_Profile) are starting shapes. With `mirror`, the outline is the same either
// side of x = 0: point 0 and, for an even count, point count/2 stand on that line, and
// point i pairs with point count - i.

PROFILE_POINTS_MAX :: 24

// A point of a profile: where, its two handles as offsets, and how they behave.
Profile_Point :: struct {
	p, h_in, h_out: [2]f32,
	handles:        Handle_Type,
}

Tube_Outline :: struct {
	points: [PROFILE_POINTS_MAX]Profile_Point,
	count:  int,
	mirror: bool,
}

// A quarter circle's handle length over its radius.
@(private = "file")
K :: 0.5522847

// The round preset as a constant, for TUBE_DEFAULTS: four Aligned points, top, right,
// bottom, left.
PROFILE_ROUND :: Tube_Outline {
	count  = 4,
	mirror = true,
	points = {
		0 = {p = {0, 1}, h_in = {-K, 0}, h_out = {K, 0}},
		1 = {p = {1, 0}, h_in = {0, K}, h_out = {0, -K}},
		2 = {p = {0, -1}, h_in = {K, 0}, h_out = {-K, 0}},
		3 = {p = {-1, 0}, h_in = {0, -K}, h_out = {0, K}},
	},
}

// The preset `kind` as an outline: Round a circle; Square a square of Vector corners;
// Ribbon a flat band a quarter as thick as it is wide; Star five points; Half a D, its flat
// side toward -y. Each is mirrored, point 0 at the top on the mirror line.
profile_preset :: proc(kind: Tube_Profile) -> (o: Tube_Outline) {
	o.mirror = true
	put :: proc(o: ^Tube_Outline, p: [2]f32, kind: Handle_Type, h_in: [2]f32 = {}, h_out: [2]f32 = {}) {
		o.points[o.count] = {p = p, h_in = h_in, h_out = h_out, handles = kind}
		o.count += 1
	}
	switch kind {
	case .Round:
		return PROFILE_ROUND
	case .Square:
		S :: 0.9
		put(&o, {0, S}, .Vector)
		put(&o, {S, S}, .Vector)
		put(&o, {S, -S}, .Vector)
		put(&o, {0, -S}, .Vector)
		put(&o, {-S, -S}, .Vector)
		put(&o, {-S, S}, .Vector)
	case .Ribbon:
		T :: 0.25
		put(&o, {0, T}, .Aligned, {-K, 0}, {K, 0})
		put(&o, {1, 0}, .Aligned, {0, K * T}, {0, -K * T})
		put(&o, {0, -T}, .Aligned, {K, 0}, {-K, 0})
		put(&o, {-1, 0}, .Aligned, {0, -K * T}, {0, K * T})
	case .Star:
		for i in 0 ..< 10 {
			a := 0.5 * math.PI - f32(i) * math.PI / 5
			r: f32 = 0.6 if i % 2 == 1 else 1
			p := [2]f32{math.cos(a) * r, math.sin(a) * r}
			if i == 0 || i == 5 do p.x = 0
			put(&o, p, .Vector)
		}
	case .Half_Round:
		put(&o, {0, 0.95}, .Aligned, {-0.6, 0}, {0.6, 0})
		put(&o, {1, -0.35}, .Free, {0, 0.75}, {-0.33, 0})
		put(&o, {0, -0.35}, .Vector)
		put(&o, {-1, -0.35}, .Free, {0.33, 0}, {0, 0.75})
	}
	profile_auto_handles(&o)
	return
}

// The outline as curve points (z = 0), in the temporary allocator, for the curve's own
// procs.
profile_bezier :: proc(o: Tube_Outline, allocator := context.temp_allocator) -> []Bezier_Point {
	out := make([]Bezier_Point, o.count, allocator)
	for i in 0 ..< o.count {
		q := o.points[i]
		out[i] = {p = {q.p.x, q.p.y, 0}, h_in = {q.h_in.x, q.h_in.y, 0}, h_out = {q.h_out.x, q.h_out.y, 0}, handles = q.handles}
	}
	return out
}

// Sets the outline's points from curve points (z dropped), up to PROFILE_POINTS_MAX.
profile_from_bezier :: proc(o: ^Tube_Outline, points: []Bezier_Point) {
	o.count = min(len(points), PROFILE_POINTS_MAX)
	for p, i in points[:o.count] do o.points[i] = {p = p.p.xy, h_in = p.h_in.xy, h_out = p.h_out.xy, handles = p.handles}
}

// Sets the handles of the outline's Auto and Vector points from their neighbours.
profile_auto_handles :: proc(o: ^Tube_Outline) {
	pts := profile_bezier(o^)
	bezier_auto_handles(pts, true)
	profile_from_bezier(o, pts)
}

// Point i's partner across the mirror line: count - i, itself for a point on the line.
profile_partner :: proc(o: Tube_Outline, i: int) -> int {
	return (o.count - i) % max(o.count, 1)
}

// With Mirror on, makes point i's partner its reflection across x = 0 (a point on the line
// is kept on it, its handles level), so the outline stays the same either side.
profile_mirror_from :: proc(o: ^Tube_Outline, i: int) {
	if !o.mirror || i < 0 || i >= o.count do return
	j := profile_partner(o^, i)
	a := &o.points[i]
	if j == i {
		a.p.x = 0
		if a.handles != .Auto && a.handles != .Vector {
			l := 0.5 * (linalg.length(a.h_out) + linalg.length(a.h_in))
			way: f32 = 1 if a.h_out.x >= 0 else -1
			a.h_out, a.h_in = {way * l, 0}, {-way * l, 0}
		}
		return
	}
	b := &o.points[j]
	b.handles = a.handles
	b.p = {-a.p.x, a.p.y}
	b.h_in = {-a.h_out.x, a.h_out.y}
	b.h_out = {-a.h_in.x, a.h_in.y}
}

// Adds a point at place `u` of the outline (as bezier_insert), and with Mirror its partner
// at the mirrored place, keeping the pairs. Returns the new point's index, -1 when it is
// full or the place is a point already.
profile_insert :: proc(o: ^Tube_Outline, u: f32) -> int {
	extra := 2 if o.mirror else 1
	if o.count + extra > PROFILE_POINTS_MAX do return -1
	pts := make([dynamic]Bezier_Point, 0, PROFILE_POINTS_MAX, context.temp_allocator)
	append(&pts, ..profile_bezier(o^))
	n := o.count
	if !o.mirror {
		at := bezier_insert(&pts, true, u)
		profile_from_bezier(o, pts[:])
		return at
	}
	i := clamp(int(u), 0, n - 1)
	t := u - f32(i)
	mi := n - 1 - i
	if mi == i {
		// The segment that crosses the line: one point in its middle, on the line.
		at := bezier_insert(&pts, true, f32(i) + 0.5)
		profile_from_bezier(o, pts[:])
		profile_mirror_from(o, at)
		return at
	}
	// Each half's point, the later place first so the earlier one's index holds.
	at: int
	if mi > i {
		_ = bezier_insert(&pts, true, f32(mi) + (1 - t))
		at = bezier_insert(&pts, true, f32(i) + t)
	} else {
		at = bezier_insert(&pts, true, f32(i) + t)
		// The partner's place comes before, so the new point moves one on.
		if bezier_insert(&pts, true, f32(mi) + (1 - t)) >= 0 && at >= 0 do at += 1
	}
	profile_from_bezier(o, pts[:])
	if at >= 0 do profile_mirror_from(o, at)
	return at
}

// Deletes point i (and with Mirror its partner), keeping at least three points; a point
// on the mirror line stays while Mirror is on. Returns whether it went.
profile_delete :: proc(o: ^Tube_Outline, i: int) -> bool {
	if i < 0 || i >= o.count do return false
	j := profile_partner(o^, i)
	if o.mirror {
		if j == i || o.count - 2 < 3 do return false
		hi, lo := max(i, j), min(i, j)
		for k in hi ..< o.count - 1 do o.points[k] = o.points[k + 1]
		o.count -= 1
		for k in lo ..< o.count - 1 do o.points[k] = o.points[k + 1]
		o.count -= 1
	} else {
		if o.count - 1 < 3 do return false
		for k in i ..< o.count - 1 do o.points[k] = o.points[k + 1]
		o.count -= 1
	}
	profile_auto_handles(o)
	return true
}

// The outline sampled to `sides` points or more, every one of its points among them (so
// corners stay sharp on the swept mesh), the rest spread over its segments by length;
// turned to run counterclockwise (x to y), so the tube faces out whichever way it was
// drawn. A broken outline (fewer than three points) gives a circle.
profile_sample :: proc(o: Tube_Outline, sides: int, allocator := context.temp_allocator) -> [][2]f32 {
	n := o.count
	if n < 3 {
		return profile_sample(PROFILE_ROUND, sides, allocator)
	}
	pts := profile_bezier(o)
	total := max(sides, n)
	// Each segment's length, by a fine polyline.
	FINE :: 16
	lengths := make([]f32, n, context.temp_allocator)
	sum: f32
	for i in 0 ..< n {
		prev := pts[i].p
		for k in 1 ..= FINE {
			q := bezier_at(pts, true, f32(i) + f32(k) / FINE)
			lengths[i] += linalg.length(q - prev)
			prev = q
		}
		sum += lengths[i]
	}
	// Every segment gets its start point; the samples left go by length, largest
	// remainders first, so the count is exact.
	counts := make([]int, n, context.temp_allocator)
	left := total - n
	given := 0
	for i in 0 ..< n {
		share := f32(left) * lengths[i] / max(sum, 1e-9)
		counts[i] = int(share)
		given += counts[i]
	}
	for given < left {
		best, best_r := 0, f32(-1)
		for i in 0 ..< n {
			r := f32(left) * lengths[i] / max(sum, 1e-9) - f32(counts[i])
			if r > best_r do best, best_r = i, r
		}
		counts[best] += 1
		given += 1
	}
	out := make([dynamic][2]f32, 0, total, allocator)
	for i in 0 ..< n {
		for k in 0 ..= counts[i] {
			q := bezier_at(pts, true, f32(i) + f32(k) / f32(counts[i] + 1))
			append(&out, q.xy)
		}
	}
	area: f32
	for p, i in out {
		q := out[(i + 1) % len(out)]
		area += p.x * q.y - q.x * p.y
	}
	if area < 0 {
		for i in 0 ..< len(out) / 2 do out[i], out[len(out) - 1 - i] = out[len(out) - 1 - i], out[i]
	}
	return out[:]
}
