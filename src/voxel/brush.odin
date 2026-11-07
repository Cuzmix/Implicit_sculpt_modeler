package voxel

import "core:math"
import "core:math/linalg"

// Voxel brushes: each dab changes the field inside the brush's box, one brick a job,
// and nothing else. Add, Subtract, Clay and Inflate grow (or shrink) the surface the way
// 3D-Coat's Vox Clay does and the mesh Draw brush looks: every value within the band is
// lowered by the brush's height times its falloff, so the surface rises in a smooth bump
// that follows the shape under it (a stamp of its own shape would sit on the surface as a
// disc or a half sphere). A value at the clamp is only known to be at least that far, so
// it is never lowered; instead a voxel outside takes no more than its nearest neighbour's
// new value plus a voxel (the field moves at most a voxel a unit away), which brings the
// band along as the surface advances. A dab moves the surface by at most ADD_MAX_VOXELS,
// so one such step a dab keeps the band ahead of it. Smooth, Flatten and Inflate work on
// the values in place too; the band repair at the stroke's end (band.odin) puts true
// distances back around what every brush moved.

Brush_Kind :: enum u8 {
	Add,
	Subtract,
	Smooth,
	Flatten,
	Inflate,
	Mask, // paints the mask (mask.odin) rather than the field; inverted it erases
	Clay, // grows the surface up to a plane above it, filling dips first (inverted digs)
	// The warping brushes (dab_warp.odin): each dab moves the clay rather than growing it.
	Pinch,      // draws the clay along the surface toward the centre (inverted pushes it away)
	Crease,     // cuts a sharp groove: pushes in with a narrow falloff and pinches (inverted: a ridge)
	Snake_Hook, // drags the clay under the brush by Brush.drag, so a stroke pulls out a horn
	// More growing and clipping brushes (brush_more.odin).
	Layer,       // raises the clay by one height a stroke, however often it passes (inverted lowers)
	Clay_Strips, // builds flat-topped strips with square ends along the stroke (inverted digs)
	Trim,        // cuts a ridge into two planes about the stroke, at the angle it finds (inverted: a valley)
	Tube,        // lays a capsule from Brush.from to the dab, blended into the clay (tube.odin; inverted carves)
}

Brush :: struct {
	kind:     Brush_Kind,
	radius:   f32, // object space
	strength: f32, // 0 to 1
	invert:   bool, // Add and Subtract swap, Clay digs, Flatten fills instead of clipping, Inflate deflates
	normal:   Vec3, // the surface normal under the pointer, unit length, in the object's space
	drag:     Vec3, // Snake hook: how far this dab drags, object space
	pinch:    f32, // Snake hook: draws the clay in across the drag (below 0 swells it), -1 to 1
	along:    Vec3, // Clay strips and Trim: the way the stroke goes, object space (zero at its first dab)
	polish:   bool, // Smooth: keep the volume (Taubin's two passes)
	trim_angle: f32, // Trim: the angle between its two planes, radians, while `trim_fixed`
	trim_fixed: bool, // Trim: keep trim_angle rather than find the angle under the brush
	from:     Vec3, // Tube: where the last dab's capsule ended, object space (the dab's own centre at the first); radius is the tube's
}

// How far a full-strength dab raises or lowers the surface, in radii (the mesh Draw
// brush's height), laid in steps of at most ADD_MAX_VOXELS so the band keeps ahead of the
// surface (dab_steps); Inflate moves it INFLATE_HEIGHT radii, in the same steps.
ADD_HEIGHT :: 0.1
ADD_MAX_VOXELS :: 1.0
INFLATE_HEIGHT :: 0.05
// How far outside (in voxels, before the dab) a voxel must be for a growing dab to bound
// it by its neighbours: beyond the values the surface's crossings and normals read.
RELAX_FROM :: 2.0
// Clay builds up to a plane this many radii above the surface under the pointer (the mesh
// Clay brush's CLAY_HEIGHT), so a stroke fills the dips first and then levels off.
CLAY_PLANE :: 0.25
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
	height:    f32, // Add, Subtract, Clay, Inflate: voxels a full-weight voxel moves
	lift:      f32, // Clay: how far above the hit its plane stands, in voxels
	// The warping brushes: Snake hook's drag a step, Crease's push a step and the share of
	// a dab's pinch a step takes, all in voxels.
	drag:      Vec3,
	pinch:     f32, // Snake hook's pinch a step, by how far the step drags over the radius
	push:      f32,
	share:     f32,
	margin:    i32, // how far past its brick a step's window reaches
	// Smooth and the growing brushes read a voxel's neighbours from a window gathered
	// before the dab writes.
	window:    []i16,
	window_lo: [3]i32,
	volume:    ^Volume, // a warping dab reads it as it was before the dab, round each brick
	// Layer: the clay as it was at the stroke's start, in the window's layout, and the
	// layer's height in voxels.
	press:     []i16,
	layer:     f32,
	// Clay strips and Trim: the stroke's frame, x along it and y across, unit length; Trim's
	// two planes' normals, for either side of the stroke.
	sx, sy:    Vec3,
	trim_plus, trim_minus: Vec3,
	plane:     Vec3, // Trim: a point both planes pass through, in voxels
	// Smooth: the pass's rate, below 0 for Polish's pass that swells back.
	rate:      f32,
	history:   ^Undo_History,
	// Tube: its capsule's ends, in voxels, and the blend's width.
	tube_a, tube_b: Vec3,
	blend:     f32,
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
	case .Add, .Subtract, .Clay:
		d.height = d.radius * d.strength * ADD_HEIGHT
		d.lift = d.radius * CLAY_PLANE
	case .Inflate:
		d.height = d.radius * d.strength * INFLATE_HEIGHT
	case .Snake_Hook:
		d.drag = brush.drag / voxel
		d.pinch = clamp(brush.pinch, -1, 1)
	case .Crease:
		// Cuts in by default, as the mesh Crease does.
		d.push = -(1 if !d.invert else -1) * d.radius * d.strength * CREASE_HEIGHT
	case .Layer:
		d.layer = d.radius * d.strength * LAYER_HEIGHT
		d.height = d.layer * LAYER_RATE
	case .Clay_Strips:
		d.height = d.radius * d.strength * CLAY_STRIPS_RATE
		d.lift = d.radius * CLAY_STRIPS_HEIGHT
	case .Smooth:
		d.rate = SMOOTH_RATE
	case .Tube:
		// The dab's centre is the capsule's middle, so its reach covers both ends.
		d.tube_a, d.tube_b = (brush.from - origin) / voxel, d.centre
		d.centre = 0.5 * (d.tube_a + d.tube_b)
		d.blend = min(d.radius * TUBE_BLEND, TUBE_BLEND_MAX)
	}
	if d.kind == .Clay_Strips || d.kind == .Trim do d.sx, d.sy = stroke_frame(d.normal, brush.along)
	d.share = 1
	// The weight's own strength factor is in the height, so a step's weight is the falloff.
	if d.height > 0 do d.strength = 1
	return
}

// How many steps dab `d` is laid in: a growing dab moves the surface at most
// ADD_MAX_VOXELS a step (so the band keeps ahead of it), at most MAX_DAB_STEPS steps (a
// higher dab is lowered to that); every other dab one step. Zero for a dab that moves nothing.
MAX_DAB_STEPS :: 8
dab_steps :: proc(d: ^Dab) -> int {
	#partial switch d.kind {
	case .Add, .Subtract, .Clay, .Inflate, .Layer, .Clay_Strips:
		if d.height <= 0 do return 0
		n := int(math.ceil(d.height / ADD_MAX_VOXELS))
		if n > MAX_DAB_STEPS {
			n = MAX_DAB_STEPS
			d.height = MAX_DAB_STEPS * ADD_MAX_VOXELS
		}
		return n
	case .Pinch, .Crease, .Snake_Hook:
		return warp_steps(d)
	}
	return 1
}

// Whether the dab reads its bricks' neighbourhoods (a window a brick).
dab_reads_window :: #force_inline proc(kind: Brush_Kind) -> bool {
	#partial switch kind {
	case .Smooth, .Add, .Subtract, .Clay, .Inflate, .Layer, .Clay_Strips:
		return true
	}
	return false
}

// Whether a dab adds clay (Add, Clay or Inflate, or Subtract inverted).
dab_adds :: #force_inline proc(d: ^Dab) -> bool {
	return (d.kind != .Subtract) != d.invert
}

// The brush's reach from its centre, in voxels: the voxels it may change lie within it.
dab_reach :: proc(d: ^Dab) -> f32 {
	if d.kind == .Clay_Strips do return d.radius * math.SQRT_TWO + 1
	if d.kind == .Tube do return 0.5 * linalg.length(d.tube_b - d.tube_a) + d.radius + CLAMP_VOXELS + d.blend + 1
	return d.radius + 1 + f32(d.margin)
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
// writes `out`; the others ignore the window and write `b` (out is b then). A masked voxel
// (`mask`, nil for an unmasked brick) takes only the unmasked share of its new value. Not
// for the Mask brush, which is dab_mask_brick.
dab_brick :: proc(d: ^Dab, bc: [3]i32, b: ^Brick, out: ^Brick, mask: ^Mask_Brick) -> (e: Dab_Effect) {
	e.lo, e.hi = {BRICK, BRICK, BRICK}, {-1, -1, -1}
	p0 := Vec3{f32(bc.x), f32(bc.y), f32(bc.z)} * BRICK
	inv_r2 := 1 / (d.radius * d.radius)
	switch d.kind {
	case .Mask:
		unreachable()
	case .Add, .Subtract, .Clay, .Inflate, .Layer, .Clay_Strips:
		grow_brick(d, bc, b, out, mask, &e)
	case .Trim:
		trim_brick(d, bc, b, mask, &e)
	case .Tube:
		tube_brick(d, bc, b, mask, &e)
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
			put(&e, &b.d[i], masked(b.d[i], quantize(math.lerp(v, target, w)), mask, i), x, y, z)
		}
		e.repair = e.changed
	case .Pinch, .Crease, .Snake_Hook:
		warp_brick(d, bc, b, out, mask, &e)
	case .Smooth:
		// The window holds the brick and a voxel around it: 10³, its first voxel at window_lo.
		W :: BRICK + 2
		base := bc * BRICK - d.window_lo
		for z in 0 ..< BRICK do for y in 0 ..< BRICK do for x in 0 ..< BRICK {
			p := p0 + {f32(x), f32(y), f32(z)}
			delta := p - d.centre
			w := falloff(linalg.dot(delta, delta) * inv_r2) * d.strength * d.rate
			i := voxel_index(x, y, z)
			out.d[i] = b.d[i]
			if w == 0 do continue
			wx, wy, wz := int(base.x) + x, int(base.y) + y, int(base.z) + z
			sum: i32
			for dz in -1 ..= 1 do for dy in -1 ..= 1 do for dx in -1 ..= 1 {
				sum += i32(d.window[((wz + dz) * W + wy + dy) * W + wx + dx])
			}
			mean := f32(sum) / (27 * SCALE)
			put(&e, &out.d[i], masked(b.d[i], quantize(math.lerp(f32(b.d[i]) / SCALE, mean, w)), mask, i), x, y, z)
		}
		e.repair = e.changed
	}
	return
}

// The growing brushes on one brick: Add, Subtract, Clay, Clay strips, Layer and Inflate.
// Worked as growing on the field turned inside out when the dab takes clay away, so one
// rule serves both:
// every value within the band goes down by the height times the weight (Clay no lower
// than its plane, the field's distance to it; Inflate along the field's own normals,
// which is the same offset), a value at the clamp stays (it is a bound, not a distance),
// and then a voxel outside takes no more than its nearest neighbour's new value plus a
// voxel. Reads the dab's window (the brick and a voxel around it), writes `out`.
@(private)
grow_brick :: proc(d: ^Dab, bc: [3]i32, b: ^Brick, out: ^Brick, mask: ^Mask_Brick, e: ^Dab_Effect) {
	// Each shape its own loop, so Add's per-voxel work has no branch for the others.
	#partial switch d.kind {
	case .Clay:
		grow_shaped(d, bc, b, out, mask, e, Grow_Shape.Plane)
	case .Clay_Strips:
		grow_shaped(d, bc, b, out, mask, e, Grow_Shape.Strip)
	case .Layer:
		grow_shaped(d, bc, b, out, mask, e, Grow_Shape.Layer)
	case:
		grow_shaped(d, bc, b, out, mask, e, Grow_Shape.Bump)
	}
}

// How a growing brush's offset is bounded: not at all (Add, Subtract, Inflate), by a plane
// (Clay), by a plane with a square falloff (Clay strips), by the layer (Layer).
@(private)
Grow_Shape :: enum u8 {Bump, Plane, Strip, Layer}

@(private)
grow_shaped :: proc(d: ^Dab, bc: [3]i32, b: ^Brick, out: ^Brick, mask: ^Mask_Brick, e: ^Dab_Effect, $SHAPE: Grow_Shape) {
	W :: BRICK + 2
	flip: f32 = 1 if dab_adds(d) else -1
	inv_r2 := 1 / (d.radius * d.radius)
	base := bc * BRICK - d.window_lo
	// The voxel at window index `k` (at `q`) after the offset, in voxels, on the grown side.
	grown :: #force_inline proc(d: ^Dab, flip, inv_r2: f32, q: Vec3, k: int, $SHAPE: Grow_Shape) -> f32 {
		v := flip * f32(d.window[k]) / SCALE
		if v >= CLAMP_VOXELS do return v // at least this far: left as it is
		delta := q - d.centre
		when SHAPE == .Strip {
			w := falloff(strip_x2(d, delta, inv_r2))
		} else {
			w := falloff(linalg.dot(delta, delta) * inv_r2) * d.strength
		}
		if w == 0 do return v
		g := v - d.height * w
		when SHAPE == .Plane || SHAPE == .Strip {
			// Down to the plane above the hit (its distance, on the grown side), never up.
			plane := flip * (linalg.dot(delta, d.normal) - d.lift)
			g = min(v, max(g, plane))
		} else when SHAPE == .Layer {
			// No further than the layer's height from where the clay was at the stroke's
			// start, wherever the brush is in its falloff: a flat top however often it passes.
			g = min(v, max(g, layer_press(d, flip, q, d.press[k]) - d.layer))
		}
		return g
	}
	// Nothing within reach of the brush, the voxel or its neighbours is changed (Clay
	// strips' square reaches its corners, √2 radii out).
	far := d.radius * (math.SQRT_TWO if SHAPE == .Strip else 1) + 1
	origin := Vec3{f32(d.window_lo.x), f32(d.window_lo.y), f32(d.window_lo.z)}
	for z in 0 ..< BRICK do for y in 0 ..< BRICK do for x in 0 ..< BRICK {
		i := voxel_index(x, y, z)
		out.d[i] = b.d[i]
		wx, wy, wz := int(base.x) + x, int(base.y) + y, int(base.z) + z
		p := origin + {f32(wx), f32(wy), f32(wz)}
		delta := p - d.centre
		if linalg.dot(delta, delta) > far * far do continue
		at :: #force_inline proc(wx, wy, wz: int) -> int {return (wz * W + wy) * W + wx}
		value := d.window[at(wx, wy, wz)]
		// Inside at the clamp (on the grown side) it stays there.
		if flip * f32(value) <= -f32(CLAMP) do continue
		g := grown(d, flip, inv_r2, p, at(wx, wy, wz), SHAPE)
		if flip * f32(value) / SCALE >= RELAX_FROM {
			// Far outside: no farther than its neighbours allow. Nearer the surface the
			// offset values stand (a stroke's offsets steepen or flatten the field there, and
			// bounding them by a neighbour would kink the field where the mesh reads it).
			// The eikonal solution from the nearer neighbour on each axis (band.odin's
			// update), which is exact for a plane at any angle where a neighbour plus a
			// voxel would bound it by steps along the axes and leave a grain in the field.
			gx := min(grown(d, flip, inv_r2, p - {1, 0, 0}, at(wx - 1, wy, wz), SHAPE), grown(d, flip, inv_r2, p + {1, 0, 0}, at(wx + 1, wy, wz), SHAPE))
			gy := min(grown(d, flip, inv_r2, p - {0, 1, 0}, at(wx, wy - 1, wz), SHAPE), grown(d, flip, inv_r2, p + {0, 1, 0}, at(wx, wy + 1, wz), SHAPE))
			gz := min(grown(d, flip, inv_r2, p - {0, 0, 1}, at(wx, wy, wz - 1), SHAPE), grown(d, flip, inv_r2, p + {0, 0, 1}, at(wx, wy, wz + 1), SHAPE))
			g = min(g, eikonal_update({max(gx, 0), max(gy, 0), max(gz, 0)}))
		}
		put(e, &out.d[i], masked(b.d[i], quantize(flip * g), mask, i), x, y, z)
	}
	e.repair = e.changed
}

// The value a masked voxel takes: `new` where it is unmasked, `old` where fully masked,
// between in proportion. A brick without a mask takes `new`.
@(private)
masked :: #force_inline proc(old, new: i16, mask: ^Mask_Brick, i: int) -> i16 {
	if mask == nil do return new
	m := mask.m[i]
	if m == 0 do return new
	if m == MASK_FULL do return old
	return i16(f32(old) + (f32(new) - f32(old)) * (1 - f32(m) / 255))
}

// Applies a Mask dab to brick `bc`'s mask `m`: each voxel within the brush is masked by
// the falloff times the strength more (or, inverted, less). The box is of every voxel
// that changed, since the mask shows wherever the surface passes.
dab_mask_brick :: proc(d: ^Dab, bc: [3]i32, m: ^Mask_Brick) -> (e: Dab_Effect) {
	e.lo, e.hi = {BRICK, BRICK, BRICK}, {-1, -1, -1}
	p0 := Vec3{f32(bc.x), f32(bc.y), f32(bc.z)} * BRICK
	inv_r2 := 1 / (d.radius * d.radius)
	for z in 0 ..< BRICK do for y in 0 ..< BRICK do for x in 0 ..< BRICK {
		p := p0 + {f32(x), f32(y), f32(z)}
		delta := p - d.centre
		w := falloff(linalg.dot(delta, delta) * inv_r2) * d.strength
		if w == 0 do continue
		i := voxel_index(x, y, z)
		amount := 255 * w
		value := u8(clamp(f32(m.m[i]) + (-amount if d.invert else amount), 0, 255) + 0.5)
		if value == m.m[i] do continue
		m.m[i] = value
		e.lo = linalg.min(e.lo, [3]i8{i8(x), i8(y), i8(z)})
		e.hi = linalg.max(e.hi, [3]i8{i8(x), i8(y), i8(z)})
		e.changed = true
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
	if d.kind == .Tube do return tube_touches(d, bc, tile)
	if tile == .Brick do return true
	switch d.kind {
	case .Flatten:
		// Clipping carves Inside tiles the plane passes; filling fills Empty ones.
		if (tile == .Empty) != d.invert do return false
		mid := Vec3{f32(bc.x), f32(bc.y), f32(bc.z)} * BRICK + (BRICK - 1) * 0.5
		HALF_DIAGONAL :: BRICK * 0.8660254 // sqrt(3) / 2
		return abs(linalg.dot(mid - d.centre, d.normal)) - HALF_DIAGONAL < BAND + 1
	case .Trim:
		// It carves Inside tiles either plane passes.
		if tile == .Empty do return false
		mid := Vec3{f32(bc.x), f32(bc.y), f32(bc.z)} * BRICK + (BRICK - 1) * 0.5
		HALF_DIAGONAL :: BRICK * 0.8660254
		h := max(linalg.dot(mid - d.plane, d.trim_plus), linalg.dot(mid - d.plane, d.trim_minus))
		return h + HALF_DIAGONAL > -(BAND + 1)
	case .Smooth, .Inflate, .Mask, .Add, .Subtract, .Clay, .Pinch, .Crease, .Snake_Hook, .Layer, .Clay_Strips, .Tube:
		// They move the surface at most a voxel, the warps WARP_STEP voxels a step, less
		// than the clamp, so the surface never reaches a tile within a step (the band grows
		// into tiles through band dilation after each, not here), and a mask lives on
		// bricks only.
		return false
	}
	return false
}
