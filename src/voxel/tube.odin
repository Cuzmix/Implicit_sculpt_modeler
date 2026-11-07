package voxel

import "core:math/linalg"

// Tube (3D-Coat's Snake and Toothpaste, Womp's goop): each dab lays a capsule from the
// last dab's end to its own, and the clay becomes the smooth union of the clay as it was
// at the stroke's start with every capsule laid since. Joints never swell, since each dab
// takes the lower of what is there and its own capsule blended with the press, and a
// stroke over its own tube stays one tube. Adding clay freely, of any thickness and
// anywhere, is what voxels are for: a mesh would need a boolean after it. Inverted, it
// carves a groove of the same shape.

// The width of the blend between the tube and the clay under it, in the tube's radii, and
// the most it is in voxels: the press's values are distances only within the clamp, so
// a wider blend would read bounds as distances.
TUBE_BLEND :: 0.5
TUBE_BLEND_MAX :: CLAMP_VOXELS - 1

// The distance from `p` to the segment from `a` to `b` (a point when they meet).
@(private)
segment_distance :: #force_inline proc(p, a, b: Vec3) -> f32 {
	pa, ba := p - a, b - a
	l2 := linalg.dot(ba, ba)
	h: f32 = 0
	if l2 > 0 do h = clamp(linalg.dot(pa, ba) / l2, 0, 1)
	return linalg.length(pa - ba * h)
}

// Tube on brick `bc`'s values `b` (in place): each voxel within reach takes the lower of
// its value and the press's blended with the capsule (on the grown side, so inverted it
// carves).
@(private)
tube_brick :: proc(d: ^Dab, bc: [3]i32, b: ^Brick, mask: ^Mask_Brick, e: ^Dab_Effect) {
	flip: f32 = 1 if dab_adds(d) else -1
	press, press_value := undo_press(d.history, d.volume, bc)
	p0 := Vec3{f32(bc.x), f32(bc.y), f32(bc.z)} * BRICK
	far := CLAMP_VOXELS + d.blend
	for z in 0 ..< BRICK do for y in 0 ..< BRICK do for x in 0 ..< BRICK {
		p := p0 + {f32(x), f32(y), f32(z)}
		s := segment_distance(p, d.tube_a, d.tube_b) - d.radius
		if s >= far do continue
		i := voxel_index(x, y, z)
		was := press_value if press == nil else press[i]
		g := min(flip * f32(b.d[i]) / SCALE, smin(flip * f32(was) / SCALE, s, d.blend))
		put(e, &b.d[i], masked(b.d[i], quantize(flip * g), mask, i), x, y, z)
	}
	e.repair = e.changed
}

// Whether a Tube dab changes brick `bc` as tile `tile`: within the clamp and the blend of
// the capsule, and an Empty tile only where clay can arrive (an Inside one, carving).
@(private)
tube_touches :: proc(d: ^Dab, bc: [3]i32, tile: Tile) -> bool {
	HALF_DIAGONAL :: BRICK * 0.8660254 // sqrt(3) / 2
	mid := Vec3{f32(bc.x), f32(bc.y), f32(bc.z)} * BRICK + (BRICK - 1) * 0.5
	s := segment_distance(mid, d.tube_a, d.tube_b) - d.radius - HALF_DIAGONAL
	if tile == .Brick do return s < CLAMP_VOXELS + d.blend
	if (tile == .Empty) != dab_adds(d) do return false
	return s < BAND + 1
}
