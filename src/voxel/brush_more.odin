package voxel

import "core:math"
import "core:math/linalg"

// Layer, Clay strips, Trim and Smooth's Polish on clay, each the mesh brush of that name
// with its rates. Layer and Clay strips grow the surface as Add does (grow_brick): Layer no
// further than its height from where the clay was at the stroke's start (read from the
// stroke's undo step, Undo_History.first), so passing again adds nothing and the top is
// flat; Clay strips up to a plane a little above the hit, its weight measured in a square
// lying along the stroke, so it lays flat-topped strips with square ends. Trim clips to
// two planes through the hit, turned about the stroke by the angle between the surface's
// normals on its two sides, so a ridge is cut into two flats (a valley inverted). Polish
// follows each Smooth pass with one that swells back a little more (Taubin's λ|μ), so
// the clay keeps its volume as it smooths.

// Layer's height at full strength, in radii, and the share of it a dab rises (the mesh
// Layer's LAYER_HEIGHT and LAYER_RATE).
LAYER_HEIGHT :: 0.15
LAYER_RATE :: 0.5
// Clay strips: how high a dab builds at full strength, and where its plane stands above
// the hit, in radii (the mesh brush's CLAY_STRIPS_RATE and CLAY_STRIPS_HEIGHT).
CLAY_STRIPS_RATE :: 0.1
CLAY_STRIPS_HEIGHT :: 0.08
// Trim: the most angle between its planes and how far a dab's angle moves toward the
// angle it finds (the mesh brush's TRIM_ANGLE_MAX and TRIM_EASE).
TRIM_ANGLE_MAX :: 160.0 * math.PI / 180
TRIM_EASE :: 0.2
// Polish's swell back, over the smoothing pass's rate (Taubin's μ over λ).
POLISH_SWELL :: 1.06

// The stroke's frame on the surface: x along the way it goes, y across, both unit length;
// a stroke's first dab, which has no way yet, takes any x.
@(private)
stroke_frame :: proc(normal, along: Vec3) -> (x, y: Vec3) {
	x = along - normal * linalg.dot(along, normal)
	if linalg.dot(x, x) < 1e-12 {
		helper := Vec3{1, 0, 0} if abs(normal.x) < 0.9 else Vec3{0, 1, 0}
		x = linalg.cross(helper, normal)
	}
	x = linalg.normalize(x)
	y = linalg.cross(normal, x)
	return
}

// Clay strips' squared distance for an offset from the hit, over the squared radius: the
// largest along the stroke, across it and along the normal (Blender's cube tip), so the
// falloff is square on the surface.
@(private)
strip_x2 :: #force_inline proc(d: ^Dab, delta: Vec3, inv_r2: f32) -> f32 {
	u, v, h := linalg.dot(delta, d.sx), linalg.dot(delta, d.sy), linalg.dot(delta, d.normal)
	return max(u * u, v * v, h * h) * inv_r2
}

// How far voxel `q` was from the clay at the stroke's start, on the grown side (`flip`),
// its value then `press`. A value at the clamp only says it was at least that far, and a
// layer higher than the clamp needs to know how much farther: it is found by stepping from
// `q` back toward the clay along the brush's normal until the values then are distances
// again, which holds for ground that is near flat across the brush, as a layer's is.
@(private)
layer_press :: proc(d: ^Dab, flip: f32, q: Vec3, press: i16) -> f32 {
	at := flip * f32(press) / SCALE
	if at < CLAMP_VOXELS do return at
	toward := -flip * d.normal
	for s := f32(BAND); s < d.layer + CLAMP_VOXELS; s += BAND {
		r := linalg.round(q + toward * s)
		g := [3]i32{i32(r.x), i32(r.y), i32(r.z)}
		bc := shr3(g, 3) // BRICK is 8
		data, value := undo_press(d.history, d.volume, bc)
		l := g - bc * BRICK
		p := f32(value if data == nil else data[voxel_index(int(l.x), int(l.y), int(l.z))])
		if flip * p / SCALE < CLAMP_VOXELS do return s + flip * p / SCALE
	}
	return d.layer + CLAMP_VOXELS
}

// Copies the clay as it was at the recording stroke's start into `out`, the `n`³ voxels
// from `lo`, as gather_window does for the clay as it is.
@(private)
gather_press :: proc(h: ^Undo_History, v: ^Volume, lo: [3]i32, n: int, out: []i16) {
	hi := lo + i32(n - 1)
	blo, bhi := shr3(lo, 3), shr3(hi, 3) // BRICK is 8
	for bz in blo.z ..= bhi.z do for by in blo.y ..= bhi.y do for bx in blo.x ..= bhi.x {
		bc := [3]i32{bx, by, bz}
		data, value := undo_press(h, v, bc)
		base := bc * BRICK
		l := linalg.max(lo - base, [3]i32{0, 0, 0})
		u := linalg.min(hi - base, [3]i32{BRICK - 1, BRICK - 1, BRICK - 1})
		for z in l.z ..= u.z do for y in l.y ..= u.y do for x in l.x ..= u.x {
			k := (int(base.z + z - lo.z) * n + int(base.y + y - lo.y)) * n + int(base.x + x - lo.x)
			out[k] = value if data == nil else data[voxel_index(int(x), int(y), int(z))]
		}
	}
}

// Trim's two planes for dab `d` at `centre` (object space), through the middle of the
// surface under it: each side's normal is turned half the angle about the stroke toward
// that side. The angle is the one the surface makes
// a radius to either side of the hit (found by casting down onto it), eased across the
// stroke as the mesh brush does, unless `brush.trim_fixed`.
@(private)
trim_planes :: proc(c: ^Clay, d: ^Dab, brush: Brush, centre: Vec3) {
	angle := clamp(brush.trim_angle, 0, TRIM_ANGLE_MAX)
	if !brush.trim_fixed {
		n := d.normal
		r := brush.radius
		side :: proc(c: ^Clay, at, n: Vec3, r: f32) -> (Vec3, Vec3) {
			hit, normal, ok := clay_raycast(c, at + n * r, -n)
			if !ok do return at, n
			return hit, normal
		}
		v := &c.volume
		sy := d.sy
		plus_at, plus := side(c, centre + sy * (r * 0.5), n, r)
		minus_at, minus := side(c, centre - sy * (r * 0.5), n, r)
		// Through the middle of the three, as the mesh brush's plane runs through the area's
		// middle: below a ridge's top, so the top is what it cuts.
		d.plane = ((centre + plus_at + minus_at) / 3 - v.origin) / v.voxel
		// The angle about the stroke's x between the sides' normals where they face apart
		// (a ridge), none where they face together or the ground is flat.
		a := linalg.normalize0(plus - d.sx * linalg.dot(plus, d.sx))
		b := linalg.normalize0(minus - d.sx * linalg.dot(minus, d.sx))
		sampled: f32
		if a != {} && b != {} && linalg.dot(a, sy) > linalg.dot(b, sy) {
			sampled = min(math.acos(clamp(linalg.dot(a, b), -1, 1)), TRIM_ANGLE_MAX)
		}
		c.trim_angle = c.trim_angle + (sampled - c.trim_angle) * TRIM_EASE if c.trim_set else sampled
		c.trim_set = true
		angle = c.trim_angle
	}
	if d.invert do angle = -angle
	cs, sn := math.cos(angle / 2), math.sin(angle / 2)
	d.trim_plus, d.trim_minus = d.normal * cs + d.sy * sn, d.normal * cs - d.sy * sn
}

// Trim on brick `bc`'s values `b` (in place): every value under the plane of its side of
// the stroke goes toward that plane's distance by the weight, carving what stands above
// it, as Flatten clips to its one plane.
@(private)
trim_brick :: proc(d: ^Dab, bc: [3]i32, b: ^Brick, mask: ^Mask_Brick, e: ^Dab_Effect) {
	p0 := Vec3{f32(bc.x), f32(bc.y), f32(bc.z)} * BRICK
	inv_r2 := 1 / (d.radius * d.radius)
	for z in 0 ..< BRICK do for y in 0 ..< BRICK do for x in 0 ..< BRICK {
		p := p0 + {f32(x), f32(y), f32(z)}
		delta := p - d.centre
		w := falloff(linalg.dot(delta, delta) * inv_r2) * d.strength
		if w == 0 do continue
		n := d.trim_plus if linalg.dot(delta, d.sy) >= 0 else d.trim_minus
		i := voxel_index(x, y, z)
		v := f32(b.d[i]) / SCALE
		target := max(v, linalg.dot(p - d.plane, n))
		put(e, &b.d[i], masked(b.d[i], quantize(math.lerp(v, target, w)), mask, i), x, y, z)
	}
	e.repair = e.changed
}
