package uv

import "core:math"
import "core:math/linalg"

import "../geom"

// How far UVs are from the surface they lie on, as Sander et al. (2001) measure a
// texture map: per triangle, the singular values of the map from the texture to the
// surface, with the UVs first scaled so their area equals the surface's (one texel
// density, so only the shape counts). Used by the tests, `bench --uv` and the relax.
Stretch :: struct {
	l2:        f64, // Sander's L2 stretch over the surface: 1 for a map that keeps lengths
	worst:     f64, // the largest ratio of a triangle's two singular values (1 is conformal)
	angle:     f64, // mean difference of a corner's angle from the surface's, in degrees
	flips:     int, // triangles facing the other way in the texture
	triangles: int, // triangles measured: those with area on the surface
	// Texel density: the UVs' length a unit of the surface takes (the square root of their
	// area over the surface's), so a map `side` texels wide gives density * side texels a
	// unit, as Blender's Texel Density and RizomUV's TD read it.
	density:   f64,
}

// Measures the triangles `tris` of `u` over `positions` and `indices` (nil: all of them).
stretch :: proc(u: Uvs, positions: []geom.Vec3, indices: []u32, tris: []u32 = nil) -> (s: Stretch) {
	count := len(tris) if tris != nil else len(u.corner)
	at :: #force_inline proc(tris: []u32, i: int) -> u32 {return tris[i] if tris != nil else u32(i)}
	surface, texture: f64
	for i in 0 ..< count {
		t := at(tris, i)
		q := surface_frame(positions, indices, t)
		surface += abs(q[1].x * q[2].y) * 0.5
		c := u.corner[t]
		texture += abs(f64(c[1].x - c[0].x) * f64(c[2].y - c[0].y) - f64(c[2].x - c[0].x) * f64(c[1].y - c[0].y)) * 0.5
	}
	if surface <= 0 || texture <= 0 do return
	s.density = math.sqrt(texture / surface)
	// UVs scaled by `k` have the surface's area.
	k := math.sqrt(surface / texture)
	sum_l2, sum_angle, weight: f64
	for i in 0 ..< count {
		t := at(tris, i)
		q := surface_frame(positions, indices, t)
		area := q[1].x * q[2].y * 0.5
		if area <= 0 do continue
		c := u.corner[t]
		p := [3][2]f64{linalg.array_cast(c[0], f64) * k, linalg.array_cast(c[1], f64) * k, linalg.array_cast(c[2], f64) * k}
		// P maps the triangle's frame edges into the texture; S = Q P⁻¹ the texture back
		// onto the surface.
		p1, p2 := p[1] - p[0], p[2] - p[0]
		det := p1.x * p2.y - p2.x * p1.y
		s.triangles += 1
		weight += area
		if det <= 0 {
			s.flips += 1
			if det == 0 {
				s.worst = math.INF_F64
				continue
			}
		}
		inv := matrix[2, 2]f64{p2.y / det, -p2.x / det, -p1.y / det, p1.x / det}
		Q := matrix[2, 2]f64{q[1].x, q[2].x, q[1].y, q[2].y}
		S := Q * inv
		e := S[0, 0] * S[0, 0] + S[1, 0] * S[1, 0]
		f := S[0, 0] * S[0, 1] + S[1, 0] * S[1, 1]
		g := S[0, 1] * S[0, 1] + S[1, 1] * S[1, 1]
		root := math.sqrt((e - g) * (e - g) + 4 * f * f)
		big := math.sqrt(max((e + g + root) * 0.5, 0))
		small := math.sqrt(max((e + g - root) * 0.5, 0))
		sum_l2 += (big * big + small * small) * 0.5 * area
		s.worst = max(s.worst, big / small if small > 0 else math.INF_F64)
		off: f64
		for j in 0 ..< 3 do off += abs(corner_angle(p, j) - corner_angle(q, j))
		sum_angle += off / 3 * area
	}
	if weight > 0 {
		s.l2 = math.sqrt(sum_l2 / weight)
		s.angle = math.to_degrees(sum_angle / weight)
	}
	return
}

// Triangle `t` laid into a frame of its own: corner 0 at the origin, corner 1 along x,
// corner 2 above it.
@(private)
surface_frame :: proc(positions: []geom.Vec3, indices: []u32, t: u32) -> [3][2]f64 {
	p0 := linalg.array_cast(positions[indices[3 * t]], f64)
	e1 := linalg.array_cast(positions[indices[3 * t + 1]], f64) - p0
	e2 := linalg.array_cast(positions[indices[3 * t + 2]], f64) - p0
	x1 := linalg.length(e1)
	if x1 <= 0 do return {}
	return {{0, 0}, {x1, 0}, {linalg.dot(e2, e1) / x1, linalg.length(linalg.cross(e1, e2)) / x1}}
}

// The angle at corner `j` of a flat triangle, in radians.
@(private)
corner_angle :: proc(p: [3][2]f64, j: int) -> f64 {
	a := p[(j + 1) % 3] - p[j]
	b := p[(j + 2) % 3] - p[j]
	return math.atan2(abs(a.x * b.y - a.y * b.x), linalg.dot(a, b))
}
