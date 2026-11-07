package voxel

import "core:math"
import "core:math/linalg"

// The warping brushes, Pinch, Crease and Snake hook (Modeler's Warp, 3D-Coat's Snake):
// a dab moves the clay under the brush rather than growing it, as the mesh brushes move
// vertices. Each voxel takes the value the field had where the dab's move brings clay
// from, found by undoing the move (fixed-point steps, as Grab's warp), read trilinear from
// a window gathered before the dab writes. Clay is never torn: a horn pulled however far
// is clay dragged along, and the stroke's band repair gives the stretched values true
// distances again. A dab that moves the clay more than WARP_STEP voxels is laid in steps
// (a Snake hook's middle carried along its drag), so a step's window stays a few voxels
// past its brick.

// The most a step of a warping dab moves any clay, in voxels: half the clamp, so the
// surface never reaches a tile within a step (band dilation makes the next bricks after
// each).
WARP_STEP :: 2.0
// The fixed-point steps that undo a warp step's move.
WARP_ITERATIONS :: 3
// Share of the way to the centre's axis that Pinch draws the clay a dab at full strength,
// and that Crease's pinch draws it; how deep Crease pushes in, in radii (the mesh
// brushes' PINCH_RATE, CREASE_PINCH and DRAW_HEIGHT).
PINCH_RATE :: 0.25
CREASE_PINCH :: 0.2
CREASE_HEIGHT :: 0.1

// How many steps warping dab `d` is laid in, its step's share set: the farthest the dab
// moves any clay over WARP_STEP, at most MAX_DAB_STEPS (a farther dab takes longer steps).
@(private)
warp_steps :: proc(d: ^Dab) -> int {
	far: f32
	switch d.kind {
	case .Snake_Hook:
		far = linalg.length(d.drag)
	case .Pinch:
		far = d.radius * min(d.strength * PINCH_RATE, 1)
	case .Crease:
		far = abs(d.push) + d.radius * min(d.strength * CREASE_PINCH, 1)
	case .Add, .Subtract, .Smooth, .Flatten, .Inflate, .Mask, .Clay:
		return 1
	}
	if far <= 0 do return 0
	n := clamp(int(math.ceil(far / WARP_STEP)), 1, MAX_DAB_STEPS)
	d.share = 1 / f32(n)
	d.drag *= d.share
	if d.kind == .Snake_Hook do d.pinch *= linalg.length(d.drag) / d.radius
	d.push *= d.share
	d.margin = i32(math.ceil(far * d.share)) + 2
	return n
}

// How far a step of warping dab `d` moves the clay at `p` (voxels), `hold` the share of
// it the mask leaves free.
@(private)
warp_move :: #force_inline proc(d: ^Dab, p: Vec3, inv_r2, hold: f32) -> Vec3 {
	delta := p - d.centre
	w := falloff(linalg.dot(delta, delta) * inv_r2)
	if w == 0 do return {}
	// Along the surface toward the axis through the middle.
	to := -delta - d.normal * linalg.dot(-delta, d.normal)
	sign: f32 = -1 if d.invert else 1
	#partial switch d.kind {
	case .Snake_Hook:
		// As the mesh Snake hook: the clay under the middle follows the pointer the whole
		// way whatever the strength, drawn in across the line it pulls along, less the
		// nearer that line so the tip never pinches to nothing.
		move := d.drag * w
		if d.pinch != 0 {
			way := linalg.normalize0(d.drag)
			across := delta + d.drag
			across -= way * linalg.dot(across, way)
			k := d.pinch * w
			if k > 0 do k *= math.pow(min(1, linalg.length(across) / d.radius), 2)
			move -= across * k
		}
		return move * hold
	case .Pinch:
		return to * (sign * min(d.strength * w * PINCH_RATE, 1) * d.share * hold)
	case .Crease:
		return (d.normal * (d.push * w * w) + to * (min(d.strength * w * CREASE_PINCH, 1) * d.share)) * hold
	}
	return {}
}

// A step of warping dab `d` on brick `bc` (values `b`) into `out`, read from the bricks
// round it as they were before the dab (d.margin is under a brick, so its 27).
@(private)
warp_brick :: proc(d: ^Dab, bc: [3]i32, b: ^Brick, out: ^Brick, mask: ^Mask_Brick, e: ^Dab_Effect) {
	assert(d.margin < BRICK, "a warp step reaches past the bricks round it")
	near: [27]^[BRICK_VOXELS]i16
	value: [27]f32
	for k in 0 ..< 27 {
		nc := bc + {i32(k % 3) - 1, i32(k / 3 % 3) - 1, i32(k / 9) - 1}
		value[k] = f32(CLAMP)
		if !brick_in_domain(nc) do continue
		tile, brick := volume_tile(d.volume, nc)
		if brick != nil do near[k] = &brick.d
		else do value[k] = f32(tile_value(tile))
	}
	// The value of voxel `l` (from the brick below and behind `bc`'s lowest corner).
	read :: #force_inline proc(near: ^[27]^[BRICK_VOXELS]i16, value: ^[27]f32, l: [3]i32) -> f32 {
		o := shr3(l, 3) // BRICK is 8
		k := (o.z * 3 + o.y) * 3 + o.x
		if near[k] == nil do return value[k]
		in_brick := l - o * BRICK
		return f32(near[k][voxel_index(int(in_brick.x), int(in_brick.y), int(in_brick.z))])
	}
	inv_r2 := 1 / (d.radius * d.radius)
	base := Vec3{f32(bc.x), f32(bc.y), f32(bc.z)} * BRICK - BRICK
	top := f32(3 * BRICK - 1) - 1e-3
	reach := d.radius + f32(d.margin)
	p0 := Vec3{f32(bc.x), f32(bc.y), f32(bc.z)} * BRICK
	for z in 0 ..< BRICK do for y in 0 ..< BRICK do for x in 0 ..< BRICK {
		i := voxel_index(x, y, z)
		out.d[i] = b.d[i]
		p := p0 + {f32(x), f32(y), f32(z)}
		// Clay comes to a voxel only from within the brush.
		if linalg.length2(p - d.centre) > reach * reach do continue
		hold: f32 = 1
		if mask != nil do hold = 1 - f32(mask.m[i]) / 255
		if hold == 0 do continue
		q := p - warp_move(d, p, inv_r2, hold)
		for _ in 1 ..< WARP_ITERATIONS do q = p - warp_move(d, q, inv_r2, hold)
		if q == p do continue
		// The value at q, trilinear.
		l := linalg.clamp(q - base, Vec3{}, Vec3{top, top, top})
		f := linalg.floor(l)
		t := l - f
		g := [3]i32{i32(f.x), i32(f.y), i32(f.z)}
		c000 := read(&near, &value, g)
		c100 := read(&near, &value, g + {1, 0, 0})
		c010 := read(&near, &value, g + {0, 1, 0})
		c110 := read(&near, &value, g + {1, 1, 0})
		c001 := read(&near, &value, g + {0, 0, 1})
		c101 := read(&near, &value, g + {1, 0, 1})
		c011 := read(&near, &value, g + {0, 1, 1})
		c111 := read(&near, &value, g + {1, 1, 1})
		a := math.lerp(math.lerp(c000, c100, t.x), math.lerp(c010, c110, t.x), t.y)
		c := math.lerp(math.lerp(c001, c101, t.x), math.lerp(c011, c111, t.x), t.y)
		put(e, &out.d[i], i16(clamp(math.round(math.lerp(a, c, t.z)), -f32(CLAMP), f32(CLAMP))), x, y, z)
	}
	e.repair = e.changed
}
