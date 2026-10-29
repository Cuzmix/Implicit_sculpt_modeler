package sculpt

// Clay strips and Trim dynamic, from Blender's Clay Strips and Multiplane Scrape: brushes
// that work in a frame turned along the stroke (x the way it goes, z the area normal),
// and Flatten's plane height and depth.

import "core:math"
import "core:math/linalg"

import "../geom"
import "../jobs"

// How far Clay strips raises the surface a dab at full strength, in radii, where its
// build-up weight is greatest.
CLAY_STRIPS_RATE :: 0.1
// Clay strips' Tip roundness as a fresh brush has it, and the narrowest Tip scale.
CLAY_TIP_ROUNDNESS :: 0.2
CLAY_TIP_SCALE_MIN :: 0.25
// Trim dynamic: the widest angle between its two planes, its fixed angle as a fresh brush
// has it (both in radians), and how much of a newly sampled angle each dab takes.
TRIM_ANGLE_MAX :: 160.0 * math.PI / 180
TRIM_ANGLE_DEFAULT :: 60.0 * math.PI / 180
TRIM_EASE :: 0.2

// Trim dynamic's angle over the stroke, eased from dab to dab.
@(private)
Trim_State :: struct {
	set:   bool,
	angle: f32,
}

// Lays the dab's stroke frame: x along the way the stroke goes on the area's plane (any
// tangent for the first dab, which has no way yet), y = n × x, each over the radius, x also
// over Tip scale.
@(private)
strip_frame :: proc(d: ^Dab) {
	n := d.normal
	if n == {} do n = {0, 0, 1}
	x := d.brush.stroke_dir - n * linalg.dot(d.brush.stroke_dir, n)
	if linalg.dot(x, x) < 1e-12 {
		helper := Vec3{1, 0, 0} if abs(n.x) < 0.9 else Vec3{0, 1, 0}
		x = linalg.cross(helper, n)
	}
	x = linalg.normalize(x)
	y := linalg.cross(n, x)
	inv_r := 1 / d.brush.radius
	scale := clamp(d.brush.tip_scale, CLAY_TIP_SCALE_MIN, 1) if d.brush.tip_scale > 0 else 1
	d.sx, d.sy = x * (inv_r / scale), y * inv_r
}

// Clay strips' weight for an offset from the dab's centre: the falloff at the distance
// measured in the square tip (Blender's cube tip), rounded at its corners by Tip
// roundness; with an alpha, the alpha's.
@(private)
strip_weight :: #force_inline proc(d: ^Dab, delta: Vec3, d2: f32) -> f32 {
	if d.alpha != nil do return dab_weight(d, delta, d2)
	u, v := abs(linalg.dot(delta, d.sx)), abs(linalg.dot(delta, d.sy))
	round := clamp(d.brush.tip_roundness, 0, 1)
	x2: f32
	if round <= 0 {
		x2 = max(u, v)
		x2 *= x2
	} else {
		eu, ev := max(u - (1 - round), 0), max(v - (1 - round), 0)
		x2 = (eu * eu + ev * ev) / (round * round)
	}
	if d.brush.falloff_shape != nil do return falloff_drawn(d.brush.falloff_shape, x2)
	return falloff(x2)
}

// Clay strips over hit leaf i: each vertex on the near side of the plane, within a radius
// of it, rises toward it, most from the middle of that depth (4z(1 - z)) and never past it.
@(private)
job_clay_strips :: proc(data: rawptr, i: int) {
	d := cast(^Dab)data
	s := d.s
	m := s.mesh
	first, last := owned(s, s.hit[i])
	fade, mask := s.fade, s.mask
	r := d.brush.radius
	rate := d.brush.strength * CLAY_STRIPS_RATE * r
	moved: u32
	bounds := geom.AABB_EMPTY
	for v in first ..< last {
		p := m.positions[v]
		delta := p - d.center
		d2 := linalg.dot(delta, delta)
		if d2 < d.r2 {
			// How far under the plane, on the side the brush builds from (above it for Ctrl).
			under := -linalg.dot(p - d.plane, d.normal) * d.amount
			if under > 0 && under < r {
				w := strip_weight(d, delta, d2) * shield(fade, mask, v) * facing_weight(d, m.normals[:], v)
				if w > 0 {
					z := under / r
					p += d.normal * (d.amount * min(rate * w * 4 * z * (1 - z), under))
					m.positions[v] = p
					moved += 1
				}
			}
		}
		geom.aabb_grow(&bounds, p)
	}
	s.partials[i].moved = moved
	s.partials[i].bounds = bounds
}

// Trim dynamic's sample: the falloff-weighted normals of each side of the stroke (y > 0
// into normal_sum, y < 0 into center_sum) over hit leaf i.
@(private)
job_trim_sides :: proc(data: rawptr, i: int) {
	d := cast(^Dab)data
	s := d.s
	m := s.mesh
	first, last := owned(s, s.hit[i])
	plus, minus: Vec3
	for v in first ..< last {
		delta := m.positions[v] - d.center
		d2 := linalg.dot(delta, delta)
		if d2 * d.inv_r2 >= 1 do continue
		w := falloff(d2 * d.inv_r2) * connected_weight(d, v)
		if linalg.dot(delta, d.sy) >= 0 {
			plus += m.normals[v] * w
		} else {
			minus += m.normals[v] * w
		}
	}
	p := &s.partials[i]
	p.normal_sum, p.center_sum = plus, minus
}

// The angle between the two sides' normals about the stroke's x axis where the ground is
// a ridge (each side faces out its own way), 0 where it is a valley or flat.
@(private)
trim_sampled_angle :: proc(d: ^Dab, plus, minus: Vec3) -> f32 {
	x := linalg.normalize0(linalg.cross(d.sy, d.normal))
	a := linalg.normalize0(plus - x * linalg.dot(plus, x))
	b := linalg.normalize0(minus - x * linalg.dot(minus, x))
	if a == {} || b == {} do return 0
	y := linalg.normalize0(d.sy)
	if linalg.dot(a, y) <= linalg.dot(b, y) do return 0
	return min(math.acos(clamp(linalg.dot(a, b), -1, 1)), TRIM_ANGLE_MAX)
}

// Trim dynamic over hit leaf i: each vertex above the plane of its side of the stroke
// (through the area's centre, its normal turned half the angle toward that side) is
// pulled onto it.
@(private)
job_trim :: proc(data: rawptr, i: int) {
	d := cast(^Dab)data
	s := d.s
	m := s.mesh
	first, last := owned(s, s.hit[i])
	fade, mask := s.fade, s.mask
	moved: u32
	bounds := geom.AABB_EMPTY
	for v in first ..< last {
		p := m.positions[v]
		delta := p - d.center
		d2 := linalg.dot(delta, delta)
		if d2 < d.r2 {
			n := d.trim_plus if linalg.dot(delta, d.sy) >= 0 else d.trim_minus
			h := linalg.dot(p - d.plane, n)
			if h > 0 {
				w := dab_weight(d, delta, d2) * shield(fade, mask, v) * facing_weight(d, m.normals[:], v)
				if w > 0 {
					p -= n * (h * min(d.brush.strength * w * PLANE_RATE, 1))
					m.positions[v] = p
					moved += 1
				}
			}
		}
		geom.aabb_grow(&bounds, p)
	}
	s.partials[i].moved = moved
	s.partials[i].bounds = bounds
}

// Sets Trim dynamic's two plane normals for this dab: the angle sampled from the two sides
// and eased along the stroke (by the dab of the first symmetry image, which every image
// then takes, a mirror keeping an angle), or the brush's fixed one; Ctrl turns the planes
// the other way, cutting a valley.
@(private)
trim_planes :: proc(s: ^Sculptor, d: ^Dab, pool: ^jobs.Pool, own: bool) {
	angle := clamp(d.brush.trim_angle, 0, TRIM_ANGLE_MAX)
	if !d.brush.trim_fixed {
		if own {
			jobs.parallel_for(pool, len(s.hit), d, job_trim_sides)
			plus, minus: Vec3
			for p in s.partials {
				plus += p.normal_sum
				minus += p.center_sum
			}
			sampled := trim_sampled_angle(d, plus, minus)
			t := &s.trim
			t.angle = t.angle + (sampled - t.angle) * TRIM_EASE if t.set else sampled
			t.set = true
		}
		angle = s.trim.angle
	}
	if d.brush.invert do angle = -angle
	c, sn := math.cos(angle / 2), math.sin(angle / 2)
	y := d.sy * d.brush.radius
	d.trim_plus, d.trim_minus = d.normal * c + y * sn, d.normal * c - y * sn
}
