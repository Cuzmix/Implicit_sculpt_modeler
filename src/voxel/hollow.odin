package voxel

import "base:runtime"

import "../geom"
import "../jobs"

// Hollowing for a print: the inside wall of a closed mesh hollowed to an even thickness,
// as resin slicers hollow a model to save material. The mesh becomes clay with voxels
// sized so the wall is HOLLOW_DEPTH of them; every distance in the band moves outward by
// that depth, which puts the field's zero on the surface that far inside, where the band
// still holds true distances, and surface nets meshes it. Where the object is thinner
// than two walls the inner surface does not reach, so that part stays solid.

// The wall in voxels: as many as the band's true distances allow with room for the
// interpolation around the new surface (BAND voxels hold them, one more is clamped).
HOLLOW_DEPTH :: 2.5

// The inside wall of the closed mesh `m` hollowed `wall` thick (in `m`'s units), facing
// inward (its triangles wound to face the hollow), in `allocator`; empty where `m` is
// nowhere thicker than two walls. False for a wall that is not positive or so thin
// against the mesh's size that it needs more than VOXELIZE_MAX voxels along an axis.
hollow_inner :: proc(m: geom.Mesh, wall: f32, pool: ^jobs.Pool, allocator := context.allocator) -> (inner: geom.Mesh, ok: bool) {
	if !(wall > 0) do return {}, false
	heap := runtime.heap_allocator()
	c: Clay
	if !clay_from_mesh(&c, m, wall / HOLLOW_DEPTH, pool, heap) do return {}, false
	defer clay_destroy(&c)
	v := &c.volume
	// The voxelising leaves a brick deeper than its reach of the surface an Inside tile,
	// though the band's true distances go on into it; each Inside tile beside a band value
	// becomes a brick that the repair fills, so the new surface finds true distances
	// wherever it passes rather than a tile's clamp at a brick's face.
	LIMIT :: i16(BAND * SCALE)
	slots := volume_slots(v, heap)
	defer delete(slots, heap)
	for slot in slots {
		bc := v.coords[slot]
		for axis in 0 ..< 3 do for side in 0 ..< 2 {
			nc := bc
			nc[axis] += 1 if side == 1 else -1
			if !brick_in_domain(nc) do continue
			if tile, _ := volume_tile(v, nc); tile != .Inside do continue
			face := BRICK - 1 if side == 1 else 0
			near := false
			for u in 0 ..< BRICK do for w in 0 ..< BRICK {
				g: [3]int
				g[axis] = face
				g[(axis + 1) % 3] = u
				g[(axis + 2) % 3] = w
				d := v.bricks[slot].d[voxel_index(g.x, g.y, g.z)]
				if d <= 0 && d > -LIMIT do near = true
			}
			if !near do continue
			made, _ := volume_brick_make(v, nc, -CLAMP)
			band_mark(&c, made)
		}
	}
	band_repair(&c)
	shift := i32(HOLLOW_DEPTH * SCALE)
	Shift :: struct {
		v:     ^Volume,
		shift: i32,
	}
	s := Shift{v, shift}
	jobs.parallel_for(pool, len(v.coords), &s, proc(data: rawptr, slot: int) {
		s := cast(^Shift)data
		if s.v.coords[slot] == BRICK_FREE do return
		for &d in s.v.bricks[slot].d do d = i16(clamp(i32(d) + s.shift, -i32(CLAMP), i32(CLAMP)))
	})
	surface_mark_all(&c)
	inner = clay_to_mesh(&c, allocator)
	// Surface nets faces the solid's outside, here the wall; the hollow is the other way.
	for t := 0; t + 2 < len(inner.indices); t += 3 do inner.indices[t + 1], inner.indices[t + 2] = inner.indices[t + 2], inner.indices[t + 1]
	for &n in inner.normals do n = -n
	return inner, true
}
