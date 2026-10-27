package voxel

import "base:runtime"
import "core:math/linalg"
import "core:slice"

import "../geom"
import "../jobs"

// Clay is a sculpted volume with everything a stroke needs around it: the field, the
// surface shown for it, the undo steps and the worker pool. A dab runs in three passes:
// a serial pre-pass over the brush's box of bricks decides which bricks the dab can
// change, makes bricks from tiles where it can and saves each for undo; a parallel pass
// writes every brick on its own; a serial post-pass turns bricks that are all one clamp
// back into tiles, grows the band into tiles the surface is approaching and marks the
// nodes to remesh. Every voxel's new value depends only on old values, so serial and
// parallel runs agree bit for bit.
Clay :: struct {
	volume:        Volume,
	surface:       Surface,
	history:       Undo_History,
	pool:          ^jobs.Pool,
	jobs:          [dynamic]Dab_Job, // scratch: the bricks one dab writes
	job_slots:     [dynamic]u32, // scratch: the stroke's bricks, for the saddle pass at its end
	scratch:       [dynamic]Brick, // Smooth writes here, one brick a job, then commits
	windows:       [dynamic]i16, // Smooth's gathered neighbourhoods, WINDOW_VOXELS a job
	// The band repair (band.odin): bricks waiting for it, its region, the fixed voxels of
	// each region brick, the generation that stamps pending slots and the running sweep.
	pending:       [dynamic][3]i32,
	region:        [dynamic]u32,
	fixed:         [dynamic][BRICK_VOXELS / 64]u64,
	settled:       [dynamic]bool, // per region brick: the last sweep changed nothing in it
	changed:       [dynamic]bool, // per region brick: the running sweep changed it
	levels:        [dynamic]u64, // the region's bricks in the running sweep's wavefront order: level over index
	level_first:   int, // where the running wavefront starts in `levels`
	repair_gen:    u32,
	sweep:         int,
	repair_sweeps: int, // sweeps the last repair took before every brick had settled
	in_stroke:     bool,
	stroke_bricks: int, // bricks written by the stroke's dabs, for the stats (one a dab each)
	stroke_dabs:   int,
	allocator:     runtime.Allocator,
}

Dab_Job :: struct {
	slot:   u32,
	coord:  [3]i32,
	effect: Dab_Effect, // written by the job
}

// Smooth's window: the brick and a voxel around it.
WINDOW :: BRICK + 2
WINDOW_VOXELS :: WINDOW * WINDOW * WINDOW

clay_init :: proc(c: ^Clay, voxel: f32, centre: Vec3, pool: ^jobs.Pool, allocator := context.allocator) {
	c.allocator = allocator
	c.pool = pool
	volume_init(&c.volume, voxel, centre, allocator)
	surface_init(&c.surface, allocator)
	undo_init(&c.history, allocator)
	c.jobs = make([dynamic]Dab_Job, allocator)
	c.job_slots = make([dynamic]u32, allocator)
	c.scratch = make([dynamic]Brick, allocator)
	c.windows = make([dynamic]i16, allocator)
	c.pending = make([dynamic][3]i32, allocator)
	c.region = make([dynamic]u32, allocator)
	c.fixed = make([dynamic][BRICK_VOXELS / 64]u64, allocator)
	c.settled = make([dynamic]bool, allocator)
	c.changed = make([dynamic]bool, allocator)
	c.levels = make([dynamic]u64, allocator)
	// Slots start stamped 0, so the first generation must not be 0.
	c.repair_gen = 1
}

clay_destroy :: proc(c: ^Clay) {
	volume_destroy(&c.volume)
	surface_destroy(&c.surface)
	undo_destroy(&c.history)
	delete(c.jobs)
	delete(c.job_slots)
	delete(c.scratch)
	delete(c.windows)
	delete(c.pending)
	delete(c.region)
	delete(c.fixed)
	delete(c.settled)
	delete(c.changed)
	delete(c.levels)
	c^ = {}
}

// Replaces the clay with a sphere of `radius` at `centre` (object space) and queues every
// node for meshing. Not undoable: it is how a clay starts.
clay_fill_sphere :: proc(c: ^Clay, centre: Vec3, radius: f32) {
	volume_fill_sphere(&c.volume, centre, radius, c.pool)
	resolve_all_saddles(c)
	surface_mark_all(c)
}

// Flips every saddle face in the field (saddle.odin) and repairs the band around the
// flips: what every way of building a whole field ends with.
@(private)
resolve_all_saddles :: proc(c: ^Clay) {
	heap := runtime.heap_allocator()
	slots := volume_slots(&c.volume, heap)
	defer delete(slots, heap)
	if resolve_saddles(c, slots, false) > 0 do band_repair(c)
}

// Where the ray from `origin` along `dir` (object space) hits the clay's surface.
clay_raycast :: proc(c: ^Clay, origin, dir: Vec3) -> (hit, normal: Vec3, ok: bool) {
	return volume_raycast(&c.volume, origin, dir)
}

// Starts a stroke: its dabs go into one undo step.
clay_stroke_begin :: proc(c: ^Clay) {
	assert(!c.in_stroke, "a stroke is already running")
	c.in_stroke = true
	c.stroke_bricks, c.stroke_dabs = 0, 0
	undo_begin(&c.history)
}

// Ends the stroke: no saddle face is left in the bricks it touched (saddle.odin), so the
// surface is manifold again (a dab leaves them until here, since the scan would cost a
// quarter of the dab), the band around what it changed gets true distances back
// (band.odin), the surface's arrays are compacted if holes took them over, and the undo
// step is kept if the stroke changed anything. Returns whether it did.
clay_stroke_end :: proc(c: ^Clay) -> bool {
	assert(c.in_stroke, "no stroke is running")
	v := &c.volume
	clear(&c.job_slots)
	// The bricks the stroke saved that are bricks still, each once (a tile that became a
	// brick is saved more than once).
	for saved in undo_current(&c.history).bricks {
		if tile, _ := volume_tile(v, saved.coord); tile == .Brick do append(&c.job_slots, volume_slot(v, saved.coord))
	}
	slice.sort(c.job_slots[:])
	_ = resolve_saddles(c, slice.unique(c.job_slots[:]), true)
	band_repair(c)
	surface_compact_if_needed(c)
	c.in_stroke = false
	return undo_end(&c.history)
}

// Applies one dab of `brush` at `centre` (object space) inside a stroke. Returns how many
// bricks it wrote.
clay_dab :: proc(c: ^Clay, brush: Brush, centre: Vec3) -> int {
	assert(c.in_stroke, "a dab needs a stroke")
	v := &c.volume
	d := dab_make(brush, centre, v.voxel, v.origin)
	reach := dab_reach(&d)
	lo := brick_floor(d.centre - reach)
	hi := brick_floor(d.centre + reach)
	// The pre-pass: which bricks, made from tiles where needed, each saved for undo first.
	clear(&c.jobs)
	for z in lo.z ..= hi.z do for y in lo.y ..= hi.y do for x in lo.x ..= hi.x {
		bc := [3]i32{x, y, z}
		if !brick_in_domain(bc) do continue
		tile, _ := volume_tile(v, bc)
		if !dab_touches(&d, bc, tile, reach) do continue
		undo_record(&c.history, v, bc)
		slot: u32
		if tile == .Brick {
			slot = volume_slot(v, bc)
		} else {
			slot, _ = volume_brick_make(v, bc, tile_value(tile))
		}
		append(&c.jobs, Dab_Job{slot = slot, coord = bc})
	}
	if len(c.jobs) == 0 do return 0
	c.stroke_dabs += 1

	// The parallel pass: one brick a job. Smooth reads neighbourhoods other jobs' bricks
	// hold, so it writes scratch bricks from windows gathered before anything changes and
	// commits them in a second pass.
	Run :: struct {
		c: ^Clay,
		d: Dab,
	}
	run := Run{c, d}
	if d.kind == .Smooth {
		resize(&c.scratch, len(c.jobs))
		resize(&c.windows, len(c.jobs) * WINDOW_VOXELS)
		jobs.parallel_for(c.pool, len(c.jobs), &run, proc(data: rawptr, i: int) {
			r := cast(^Run)data
			c := r.c
			job := c.jobs[i]
			d := r.d
			d.window = c.windows[i * WINDOW_VOXELS:][:WINDOW_VOXELS]
			d.window_lo = job.coord * BRICK - 1
			gather_window(&c.volume, d.window_lo, WINDOW, d.window)
			c.jobs[i].effect = dab_brick(&d, job.coord, &c.volume.bricks[job.slot], &c.scratch[i])
		})
		jobs.parallel_for(c.pool, len(c.jobs), &run, proc(data: rawptr, i: int) {
			c := (cast(^Run)data).c
			c.volume.bricks[c.jobs[i].slot] = c.scratch[i]
		})
	} else {
		jobs.parallel_for(c.pool, len(c.jobs), &run, proc(data: rawptr, i: int) {
			r := cast(^Run)data
			job := &r.c.jobs[i]
			b := &r.c.volume.bricks[job.slot]
			job.effect = dab_brick(&r.d, job.coord, b, b)
		})
	}

	// The post-pass. A brick whose values are all one clamp is a tile again (a brick made
	// from a tile the dab did not reach after all goes straight back, and nothing is
	// remeshed for it); a brick whose face has values inside the band next to a tile needs
	// that tile to be a brick before the surface moves there, since only bricks take values
	// (band dilation).
	written := 0
	for job in c.jobs {
		b := &v.bricks[job.slot]
		surface_mark_box(c, job.coord, job.effect.lo, job.effect.hi)
		if tile := brick_tile(b); tile != .Brick {
			volume_brick_collapse(v, job.coord, tile)
			continue
		}
		if !job.effect.changed do continue
		written += 1
		if job.effect.repair do band_mark(c, job.slot)
		dilate_band(c, job.coord, b)
	}
	c.stroke_bricks += written
	return written
}

// Copies the `n`³ voxels from `lo` into `out`, x fastest, reading tiles as their values.
// Whole bricks are copied at a time rather than a voxel at a time through the directory.
@(private)
gather_window :: proc(v: ^Volume, lo: [3]i32, n: int, out: []i16) {
	assert(len(out) == n * n * n, "window size")
	hi := lo + i32(n - 1)
	blo, bhi := shr3(lo, 3), shr3(hi, 3) // BRICK is 8
	for bz in blo.z ..= bhi.z do for by in blo.y ..= bhi.y do for bx in blo.x ..= bhi.x {
		bc := [3]i32{bx, by, bz}
		tile, brick := volume_tile(v, bc)
		base := bc * BRICK
		// The window's voxels this brick covers, in the brick's coordinates.
		l := linalg.max(lo - base, [3]i32{0, 0, 0})
		h := linalg.min(hi - base, [3]i32{BRICK - 1, BRICK - 1, BRICK - 1})
		if l.x > h.x || l.y > h.y || l.z > h.z do continue
		if brick == nil {
			value := tile_value(tile)
			for z in l.z ..= h.z do for y in l.y ..= h.y {
				row := (int(base.z + z - lo.z) * n + int(base.y + y - lo.y)) * n + int(base.x - lo.x)
				for x in l.x ..= h.x do out[row + int(x)] = value
			}
		} else {
			for z in l.z ..= h.z do for y in l.y ..= h.y {
				row := (int(base.z + z - lo.z) * n + int(base.y + y - lo.y)) * n + int(base.x - lo.x)
				src := voxel_index(int(l.x), int(y), int(z))
				copy(out[row + int(l.x):row + int(h.x) + 1], brick.d[src:src + int(h.x - l.x) + 1])
			}
		}
	}
}

// Makes a brick of each tile next to a face of `b` that holds a value within the band on
// that tile's side (an Empty tile beside an outside value under BAND, an Inside tile beside
// an inside value above -BAND), filled with the tile's value, so the next dab can write
// there. The surface moves under a voxel a dab, so one brick ahead is enough. The new
// brick holds the clamp where the true distances may be as small as a voxel, so the
// stroke's end repairs it.
@(private)
dilate_band :: proc(c: ^Clay, bc: [3]i32, b: ^Brick) {
	v := &c.volume
	LIMIT :: i16(BAND * SCALE)
	for axis in 0 ..< 3 {
		for side in 0 ..< 2 {
			nc := bc
			nc[axis] += 1 if side == 1 else -1
			if !brick_in_domain(nc) do continue
			tile, _ := volume_tile(v, nc)
			if tile == .Brick do continue
			// Any face voxel within the band on the tile's side.
			face := BRICK - 1 if side == 1 else 0
			near := false
			for u in 0 ..< BRICK do for w in 0 ..< BRICK {
				g: [3]int
				g[axis] = face
				g[(axis + 1) % 3] = u
				g[(axis + 2) % 3] = w
				d := b.d[voxel_index(g.x, g.y, g.z)]
				if (tile == .Empty && d >= 0 && d < LIMIT) || (tile == .Inside && d <= 0 && d > -LIMIT) {
					near = true
					break
				}
			}
			if !near do continue
			undo_record(&c.history, v, nc)
			slot, _ := volume_brick_make(v, nc, tile_value(tile))
			band_mark(c, slot)
		}
	}
}

// The object-space box around the clay's bricks.
clay_bounds :: proc(c: ^Clay) -> geom.Aabb {
	return volume_bounds(&c.volume)
}

// Bytes held by the field, the surface's arrays and the undo steps.
clay_bytes :: proc(c: ^Clay) -> int {
	return volume_bytes(&c.volume) + surface_bytes(&c.surface) + c.history.bytes
}
