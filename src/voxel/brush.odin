package voxel

import "core:math"
import "core:math/linalg"

// Voxel brushes: each dab changes the field inside the brush's box, one brick a job,
// and nothing else. Add and Subtract are a smooth union or difference with a stamp: a
// sphere whose cap protrudes ADD_HEIGHT radii out of (or into) the surface and whose
// footprint is the brush radius, so the stamp's own distances fill the band it moves
// into and a dab can add more than a voxel of clay without breaking the band (as
// Medium's stamps do). Smooth, Flatten and Inflate work on the values in place and move
// the surface by less than a voxel a dab; the band repair at the stroke's end
// (band.odin) puts true distances back around what they moved.

Brush_Kind :: enum u8 {
	Add,
	Subtract,
	Smooth,
	Flatten,
	Inflate,
}

Brush :: struct {
	kind:     Brush_Kind,
	radius:   f32, // object space
	strength: f32, // 0 to 1
	invert:   bool, // Add and Subtract swap, Flatten fills instead of clipping, Inflate deflates
	normal:   Vec3, // the surface normal under the pointer, unit length, in the object's space
}

// How far a full-strength dab raises or lowers the surface, in radii (the mesh Draw
// brush's height), and how far Inflate moves it, in radii, capped at a voxel a dab so
// the values it leaves stay within a voxel of true distances.
ADD_HEIGHT :: 0.1
INFLATE_HEIGHT :: 0.05
INFLATE_MAX_VOXELS :: 1.0
// The stamp's blend radius, in brush radii: how softly new clay joins the surface.
BLEND :: 0.25
// The most a Smooth dab moves a value toward its neighbourhood's mean.
SMOOTH_RATE :: 0.5

// The dab as the jobs see it: everything in voxel coordinates.
Dab :: struct {
	kind:      Brush_Kind,
	invert:    bool,
	centre:    Vec3, // the hit, in voxels
	radius:    f32, // in voxels
	strength:  f32,
	normal:    Vec3,
	// Add and Subtract: the stamp sphere, and the sphere of radius + blend around the
	// hit it is cut to, so a stamp never reaches past the brush's footprint.
	stamp:     Vec3,
	stamp_r:   f32,
	cut_r:     f32,
	blend:     f32,
	height:    f32, // Inflate: voxels a full-weight voxel moves
	// Smooth: a voxel's neighbourhood comes from a window gathered before the dab writes.
	window:    []i16,
	window_lo: [3]i32,
}

// The dab's numbers for `brush` at `centre` (object space) on a volume of `voxel` size.
dab_make :: proc(brush: Brush, centre: Vec3, voxel: f32, origin: Vec3) -> (d: Dab) {
	d.kind, d.invert = brush.kind, brush.invert
	d.centre = (centre - origin) / voxel
	d.radius = max(brush.radius / voxel, 0.5)
	d.strength = clamp(brush.strength, 0, 1)
	d.normal = linalg.normalize0(brush.normal)
	if d.normal == {} do d.normal = {0, 0, 1}
	#partial switch d.kind {
	case .Add, .Subtract:
		h := max(d.radius * d.strength * ADD_HEIGHT, 0.05)
		// The sphere whose cap of height h has the footprint radius.
		r := d.radius
		d.stamp_r = (r * r + h * h) / (2 * h)
		d.blend = r * BLEND
		d.cut_r = r + d.blend
		out := d.kind == .Add
		if d.invert do out = !out
		d.stamp = d.centre - d.normal * (d.stamp_r - h) if out else d.centre + d.normal * (d.stamp_r - h)
	case .Inflate:
		d.height = min(d.radius * d.strength * INFLATE_HEIGHT, INFLATE_MAX_VOXELS)
	}
	return
}

// Whether a dab adds clay (Add, or Subtract inverted).
dab_adds :: #force_inline proc(d: ^Dab) -> bool {
	return (d.kind == .Add) != d.invert
}

// The brush's reach from its centre, in voxels: the voxels it may change lie within it.
dab_reach :: proc(d: ^Dab) -> f32 {
	#partial switch d.kind {
	case .Add, .Subtract:
		return d.cut_r + 1
	}
	return d.radius + 1
}

// The quadratic smooth minimum: min(a, b) blended over `k` (Quilez), which keeps k the
// width of the blend in voxels; plain min when k is 0.
smin :: #force_inline proc(a, b, k: f32) -> f32 {
	if k <= 0 do return min(a, b)
	h := max(k - abs(a - b), 0) / k
	return min(a, b) - h * h * k * 0.25
}

// The brush weight at squared distance x2 over the squared radius: (1 − x²)², as the
// mesh brushes' falloff.
falloff :: #force_inline proc(x2: f32) -> f32 {
	if x2 >= 1 do return 0
	t := 1 - x2
	return t * t
}

// What a dab did to one brick, so the post-pass remeshes and repairs only what it must.
Dab_Effect :: struct {
	changed: bool, // any value changed
	repair:  bool, // values changed that are no longer distances: the band repair's region
	// The box of changed voxels that the mesh can see (either value within NEAR of the
	// surface), in the brick; lo > hi when there are none.
	lo, hi:  [3]i8,
}

// How far from the surface a value can be and still shape the mesh: a crossing cell's
// corners lie within the cell's diagonal, and their gradients read one voxel farther.
NEAR :: i16(3 * SCALE)

// Applies the dab to brick `bc`'s values `b` (in place). Smooth reads the dab's window and
// writes `out`; the others ignore the window and write `b` (out is b then).
dab_brick :: proc(d: ^Dab, bc: [3]i32, b: ^Brick, out: ^Brick) -> (e: Dab_Effect) {
	e.lo, e.hi = {BRICK, BRICK, BRICK}, {-1, -1, -1}
	p0 := Vec3{f32(bc.x), f32(bc.y), f32(bc.z)} * BRICK
	inv_r2 := 1 / (d.radius * d.radius)
	switch d.kind {
	case .Add, .Subtract:
		// The union or difference stays a distance field except where the blend acts.
		adds := dab_adds(d)
		for z in 0 ..< BRICK do for y in 0 ..< BRICK do for x in 0 ..< BRICK {
			p := p0 + {f32(x), f32(y), f32(z)}
			// The stamp, cut to the ball around the hit.
			s := max(linalg.length(p - d.stamp) - d.stamp_r, linalg.length(p - d.centre) - d.cut_r)
			i := voxel_index(x, y, z)
			v := f32(b.d[i]) / SCALE
			r := smin(v, s, d.blend) if adds else -smin(-v, s, d.blend)
			// Only values the blend shaped, and only within the band, need the repair.
			if put(&e, &b.d[i], quantize(r), x, y, z) && abs(v - s) < d.blend && abs(r) < BAND do e.repair = true
		}
	case .Inflate:
		h := -d.height if d.invert else d.height
		for z in 0 ..< BRICK do for y in 0 ..< BRICK do for x in 0 ..< BRICK {
			p := p0 + {f32(x), f32(y), f32(z)}
			delta := p - d.centre
			w := falloff(linalg.dot(delta, delta) * inv_r2) * d.strength
			if w == 0 do continue
			i := voxel_index(x, y, z)
			put(&e, &b.d[i], quantize(f32(b.d[i]) / SCALE - h * w), x, y, z)
		}
		e.repair = e.changed
	case .Flatten:
		for z in 0 ..< BRICK do for y in 0 ..< BRICK do for x in 0 ..< BRICK {
			p := p0 + {f32(x), f32(y), f32(z)}
			delta := p - d.centre
			dist2 := linalg.dot(delta, delta)
			w := falloff(dist2 * inv_r2) * d.strength
			if w == 0 do continue
			i := voxel_index(x, y, z)
			v := f32(b.d[i]) / SCALE
			plane := linalg.dot(delta, d.normal)
			target: f32
			if d.invert {
				// Fill up to the plane, within the brush's ball.
				target = min(v, max(-plane, math.sqrt(dist2) - d.radius))
			} else {
				target = max(v, plane)
			}
			put(&e, &b.d[i], quantize(math.lerp(v, target, w)), x, y, z)
		}
		e.repair = e.changed
	case .Smooth:
		// The window holds the brick and a voxel around it: 10³, its first voxel at window_lo.
		W :: BRICK + 2
		base := bc * BRICK - d.window_lo
		for z in 0 ..< BRICK do for y in 0 ..< BRICK do for x in 0 ..< BRICK {
			p := p0 + {f32(x), f32(y), f32(z)}
			delta := p - d.centre
			w := falloff(linalg.dot(delta, delta) * inv_r2) * d.strength * SMOOTH_RATE
			i := voxel_index(x, y, z)
			out.d[i] = b.d[i]
			if w == 0 do continue
			wx, wy, wz := int(base.x) + x, int(base.y) + y, int(base.z) + z
			sum: i32
			for dz in -1 ..= 1 do for dy in -1 ..= 1 do for dx in -1 ..= 1 {
				sum += i32(d.window[((wz + dz) * W + wy + dy) * W + wx + dx])
			}
			mean := f32(sum) / (27 * SCALE)
			put(&e, &out.d[i], quantize(math.lerp(f32(b.d[i]) / SCALE, mean, w)), x, y, z)
		}
		e.repair = e.changed
	}
	return
}

// Stores `value` at voxel (x, y, z) of the brick and records the change in `e`: whether
// there was one, and the box of changes near the surface. True when the value changed.
@(private)
put :: #force_inline proc(e: ^Dab_Effect, at: ^i16, value: i16, x, y, z: int) -> bool {
	if at^ == value do return false
	if abs(at^) <= NEAR || abs(value) <= NEAR {
		e.lo = linalg.min(e.lo, [3]i8{i8(x), i8(y), i8(z)})
		e.hi = linalg.max(e.hi, [3]i8{i8(x), i8(y), i8(z)})
	}
	at^ = value
	e.changed = true
	return true
}

// The distance from `p` to the box of brick `bc` (zero inside it), in voxels: the brick's
// voxel centres span [8bc, 8bc + 7].
@(private)
brick_distance :: #force_inline proc(p: Vec3, bc: [3]i32) -> f32 {
	lo := Vec3{f32(bc.x), f32(bc.y), f32(bc.z)} * BRICK
	hi := lo + (BRICK - 1)
	return linalg.length(linalg.max(linalg.max(lo - p, p - hi), Vec3{}))
}

// Whether the dab can change any voxel of brick `bc` as tile `tile`: a brick within
// reach always may; an Empty tile only where clay can arrive, an Inside tile only where
// clay can be carved. `reach` is dab_reach.
dab_touches :: proc(d: ^Dab, bc: [3]i32, tile: Tile, reach: f32) -> bool {
	if brick_distance(d.centre, bc) > reach do return false
	if tile == .Brick do return true
	switch d.kind {
	case .Add, .Subtract:
		// New values arrive where the stamp comes within the clamp of the tile's value: the
		// stamp's distance over the box is at least its distance to the box, and so is the cut's.
		if (tile == .Empty) != dab_adds(d) do return false
		s := max(brick_distance(d.stamp, bc) - d.stamp_r, brick_distance(d.centre, bc) - d.cut_r)
		return s < BAND + 1
	case .Flatten:
		// Clipping carves Inside tiles the plane passes; filling fills Empty ones.
		if (tile == .Empty) != d.invert do return false
		mid := Vec3{f32(bc.x), f32(bc.y), f32(bc.z)} * BRICK + (BRICK - 1) * 0.5
		HALF_DIAGONAL :: BRICK * 0.8660254 // sqrt(3) / 2
		return abs(linalg.dot(mid - d.centre, d.normal)) - HALF_DIAGONAL < BAND + 1
	case .Smooth, .Inflate:
		// They move the surface less than a voxel: the band grows into tiles through
		// band dilation after the dab, not here.
		return false
	}
	return false
}
