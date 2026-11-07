package voxel

import "core:math"

import "../jobs"

// Mirror and weld on clay (the mesh's Mirror and weld, 3D-Coat's Symmetry > Apply): one
// side of the object's plane across `axis` becomes the mirror image of the other, as one
// undo step. A voxel on the replaced side takes the value at its mirror image (between the
// two voxels there when the plane falls between voxel centres), so the field stays a
// distance on both sides; the band is repaired along the seam, where the two halves meet
// and a surface may now lie nearer across the plane. A brick whose image lies wholly in one
// kind of tile becomes that tile without a voxel worked out, so the cost is the surface's,
// not the volume's. The mask on the replaced side goes; what stays keeps its own.

// One brick of the replaced side: what it becomes, and where its values are worked out.
@(private = "file")
Mirror_Job :: struct {
	coord:  [3]i32,
	tile:   Tile, // Brick: worked out into the clay's scratch at `at`
	at:     int,
	straddles: bool, // it holds voxels of the kept side too
}

@(private = "file")
Mirror_Run :: struct {
	c:     ^Clay,
	jobs:  []Mirror_Job,
	axis:  int,
	plane: f32, // the object's plane along `axis`, in voxel coordinates
	keep_positive: bool,
	colors: []Color_Brick, // per worked-out brick, its colour; nil when the clay is unpainted
	painted: []bool, // per worked-out brick, whether any voxel of it is painted
}

// Mirrors the clay across the object's plane square to `axis` (0 x, 1 y, 2 z), keeping the
// positive side with `keep_positive`. No stroke may be running. Returns whether anything
// changed (false when nothing of the clay is on the kept side, or it was symmetric).
clay_mirror :: proc(c: ^Clay, axis: int, keep_positive: bool) -> bool {
	assert(!c.in_stroke, "a stroke is running")
	assert(axis >= 0 && axis < 3, "an axis is 0, 1 or 2")
	v := &c.volume
	plane := -v.origin[axis] / v.voxel
	// The box of bricks holding values; Inside tiles lie within it, inside the band.
	lo, hi := [3]i32{max(i32), max(i32), max(i32)}, [3]i32{min(i32), min(i32), min(i32)}
	for bc in v.coords {
		if bc == BRICK_FREE do continue
		lo, hi = {min(lo.x, bc.x), min(lo.y, bc.y), min(lo.z, bc.z)}, {max(hi.x, bc.x), max(hi.y, bc.y), max(hi.z, bc.z)}
	}
	if lo.x > hi.x do return false
	// Nothing kept: the clay lies wholly on the replaced side.
	kept_hi := f32(hi[axis] * BRICK + BRICK - 1)
	kept_lo := f32(lo[axis] * BRICK)
	if keep_positive && kept_hi <= plane do return false
	if !keep_positive && kept_lo >= plane do return false
	// The replaced side's bricks: whatever is there now and the image of the kept side.
	image_lo := brick_of_voxel(2 * plane - kept_hi)
	image_hi := brick_of_voxel(2 * plane - kept_lo)
	box_lo, box_hi := lo, hi
	box_lo[axis], box_hi[axis] = min(lo[axis], image_lo), max(hi[axis], image_hi)
	box_lo = {max(box_lo.x, 0), max(box_lo.y, 0), max(box_lo.z, 0)}
	box_hi = {min(box_hi.x, MAX_BRICKS - 1), min(box_hi.y, MAX_BRICKS - 1), min(box_hi.z, MAX_BRICKS - 1)}

	// Which bricks change and how: a brick whose image lies in one kind of tile is that
	// tile, the rest are worked out.
	mjobs := make([dynamic]Mirror_Job, context.temp_allocator)
	computed := 0
	for z in box_lo.z ..= box_hi.z do for y in box_lo.y ..= box_hi.y do for x in box_lo.x ..= box_hi.x {
		bc := [3]i32{x, y, z}
		first, last := f32(bc[axis] * BRICK), f32(bc[axis] * BRICK + BRICK - 1)
		// Bricks wholly on the kept side (or on the plane) stay.
		replaced := last < plane if keep_positive else first > plane
		some := first < plane if keep_positive else last > plane
		if !some do continue
		straddles := !replaced
		// The image's bricks along the axis, a voxel either side for the blend.
		a := brick_of_voxel(2 * plane - last - 1)
		b := brick_of_voxel(2 * plane - first + 1)
		image := Tile.Brick
		uniform := true
		for k in min(a, b) ..= max(a, b) {
			nc := bc
			nc[axis] = k
			t, _ := volume_tile(v, nc)
			if t == .Brick || (image != .Brick && t != image) {
				uniform = false
				break
			}
			image = t
		}
		job := Mirror_Job{coord = bc, straddles = straddles}
		if uniform && !job.straddles {
			if t, _ := volume_tile(v, bc); t == image do continue
			job.tile = image
		} else {
			job.tile = .Brick
			job.at = computed
			computed += 1
		}
		append(&mjobs, job)
	}
	if len(mjobs) == 0 do return false

	// The worked-out bricks, in parallel, into scratch: each reads only the kept side and
	// its own brick, which nothing writes until every job is done.
	resize(&c.scratch, computed)
	run := Mirror_Run{c, mjobs[:], axis, plane, keep_positive, nil, nil}
	// The colour goes with the field: each worked-out brick's beside it.
	if clay_colored(c) {
		run.colors = make([]Color_Brick, computed, context.temp_allocator)
		run.painted = make([]bool, computed, context.temp_allocator)
	}
	jobs.parallel_for(c.pool, len(mjobs), &run, proc(data: rawptr, i: int) {
		r := cast(^Mirror_Run)data
		job := r.jobs[i]
		if job.tile != .Brick do return
		mirror_brick(r, job.coord, &r.c.scratch[job.at])
		if r.colors != nil do r.painted[job.at] = mirror_color(r, job.coord, &r.colors[job.at])
	})

	// Written, each saved first; the seam's bricks are repaired at the step's end.
	clay_stroke_begin(c)
	seam := f32(CLAMP_VOXELS + BRICK)
	for job in mjobs {
		undo_record(&c.history, v, job.coord)
		if job.tile != .Brick {
			volume_brick_collapse(v, job.coord, job.tile)
			surface_mark_brick(c, job.coord)
			continue
		}
		out := &c.scratch[job.at]
		was, brick := volume_tile(v, job.coord)
		same_color := run.colors == nil || (was == .Brick && color_same(color_of(v, volume_slot(v, job.coord)), &run.colors[job.at], run.painted[job.at]))
		if was == .Brick && brick.d == out.d && same_color do continue
		if t := brick_tile(out); t != .Brick && !job.straddles {
			volume_brick_collapse(v, job.coord, t)
			surface_mark_brick(c, job.coord)
			continue
		}
		slot, b := volume_brick_make(v, job.coord, 0)
		b^ = out^
		if !job.straddles do mask_drop(v, slot)
		if run.colors != nil {
			if run.painted[job.at] do color_make(v, slot)^ = run.colors[job.at]
			else do color_drop(v, slot)
		}
		mid := f32(job.coord[axis] * BRICK) + (BRICK - 1) * 0.5
		if math.abs(mid - plane) < seam do band_mark(c, slot)
		surface_mark_brick(c, job.coord)
	}
	return clay_stroke_end(c)
}

// The brick holding voxel coordinate `g` along an axis.
@(private = "file")
brick_of_voxel :: #force_inline proc(g: f32) -> i32 {
	return i32(math.floor(math.floor(g + 0.5) / BRICK))
}

// Brick `bc` after the mirror, into `out`: a voxel on the replaced side takes the value at
// its image, between the two voxels there; one on the kept side or the plane keeps its own.
@(private = "file")
mirror_brick :: proc(r: ^Mirror_Run, bc: [3]i32, out: ^Brick) {
	v := &r.c.volume
	axis := r.axis
	for z in 0 ..< BRICK do for y in 0 ..< BRICK do for x in 0 ..< BRICK {
		g := [3]i32{bc.x * BRICK + i32(x), bc.y * BRICK + i32(y), bc.z * BRICK + i32(z)}
		k := voxel_index(x, y, z)
		at := f32(g[axis])
		replaced := at < r.plane if r.keep_positive else at > r.plane
		if !replaced {
			out.d[k] = volume_value(v, g)
			continue
		}
		image := 2 * r.plane - at
		f := math.floor(image)
		t := image - f
		ga, gb := g, g
		ga[axis], gb[axis] = i32(f), i32(f) + 1
		va := f32(volume_value(v, ga))
		value := va if t == 0 else math.lerp(va, f32(volume_value(v, gb)), t)
		out.d[k] = i16(math.round(value))
	}
}

// Brick `bc`'s colour after the mirror, into `out`: a voxel on the replaced side takes the
// colour of the voxel nearest its image, one on the kept side or the plane keeps its own.
// Returns whether any voxel of it is painted.
@(private = "file")
mirror_color :: proc(r: ^Mirror_Run, bc: [3]i32, out: ^Color_Brick) -> bool {
	v := &r.c.volume
	axis := r.axis
	painted := false
	for z in 0 ..< BRICK do for y in 0 ..< BRICK do for x in 0 ..< BRICK {
		g := [3]i32{bc.x * BRICK + i32(x), bc.y * BRICK + i32(y), bc.z * BRICK + i32(z)}
		at := f32(g[axis])
		replaced := at < r.plane if r.keep_positive else at > r.plane
		from := g
		if replaced do from[axis] = i32(math.round(2 * r.plane - at))
		col := color_value(v, from)
		out.c[voxel_index(x, y, z)] = col
		painted ||= col[3] != 0
	}
	return painted
}

// Whether brick colour `live` (nil for none) is `out`, which is `painted` or not.
@(private = "file")
color_same :: proc(live: ^Color_Brick, out: ^Color_Brick, painted: bool) -> bool {
	if live == nil do return !painted
	return live.c == out.c
}
