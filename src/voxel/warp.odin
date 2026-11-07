package voxel

import "base:runtime"
import "core:math"
import "core:math/linalg"

import "../geom"
import "../jobs"

// Grab on clay (ZBrush's Move, Modeler's Warp): the stroke picks up the clay under the
// brush at the press and each later pointer position drags it there, the middle fully
// and the rim by the falloff. The field is warped, not stamped: every voxel the drag can
// reach takes the value the field had at the press where that voxel came from, read
// through the inverse of the move. Reading the field as it was at the press, never the
// last frame's, keeps detail from blurring however long the drag goes on; the field as it
// was is free, since it is the stroke's undo step (a brick's first save in a stroke holds
// it before the stroke). Medium's engineers found this the move that kept detail best;
// they dropped it because a stretch leaves values that are no longer distances and their
// redistancing smeared detail. Our band repair keeps every voxel beside the surface
// fixed and solves only the values farther out, so the stroke's end puts true distances
// back without moving the surface.
//
// A long drag is laid as a chain of short moves, each carrying the falloff's middle a
// GRAB_STEP of the radius further along the drag (and turning by its share of a twist):
// a single falloff dragged further than about half its radius folds over itself and has
// no inverse, while the chain stretches the clay along the drag as a pulled tendril
// does. Each voxel's source is found by undoing the moves from the last to the first,
// each by fixed-point steps (q = x − u(q)), which converge while a move is shorter than
// the falloff is steep. With symmetry every image of the brush moves its own clay its
// mirrored or turned way, all in the one warp, so nothing seams where the images meet.
//
// Elastic (Blender's Elastic Deform) is the same warp weighed by a regularized Kelvinlet
// (geom/kelvinlet.odin, the mesh Elastic's) in place of the falloff: the part pulled
// keeps its shape and the clay round it stretches smoothly out to KELVINLET_REACH radii,
// thinning its sides by the brush's Volume.

// The most of the radius one move of the chain carries the clay.
GRAB_STEP :: 0.4
// The most moves a drag is laid as: longer drags take longer moves.
GRAB_STEPS_MAX :: 24
// Fixed-point steps that undo one move, at most; they stop once a step moves the source
// less than GRAB_SETTLED voxels.
GRAB_ITERATIONS :: 4
GRAB_SETTLED :: 1.0 / 512

// One image of the brush (sculpt's symmetry images): where it pressed and its turn.
Grab_Image :: struct {
	centre: Vec3, // in voxels
	turn:   matrix[3, 3]f32,
}

// One image's share of a move: everything in voxels.
@(private)
Grab_Move :: struct {
	centre: Vec3, // where the image pressed
	offset: Vec3, // how far its clay goes over the whole drag
	axis:   Vec3, // its twist's axis, unit length (zero for none)
	angle:  f32, // its twist over the whole drag, radians
}

Clay_Grab :: struct {
	active:  bool,
	radius:  f32, // in voxels
	images:  [dynamic]Grab_Image,
	// Per brick slot: one more than the index of its save in the stroke's step, which holds
	// it as it was at the press, or 0 while the grab has not changed it (it is as it was).
	// A brick the grab changes stays a brick to the stroke's end, so its slot stays its own.
	saved:   [dynamic]i32,
	// Every brick the grab has written, so the next frame rewrites it too (the drag may
	// have moved away from it) and the stroke's end repairs it.
	bricks:  [dynamic][3]i32,
	kept:    map[[3]i32]bool, // ...the same bricks, to find them
	listed:  map[[3]i32]u32, // the frame that last listed a brick for work
	frame:   u32,
	// One frame's work: the bricks the drag can reach, what each becomes and whether
	// that differs from what it is.
	work:    [dynamic][3]i32,
	results: [dynamic]Brick,
	differs: [dynamic]bool,
	moves:   [dynamic]Grab_Move,
	steps:   int,
	// The sources of the frame's brick corners (each shared by eight bricks), and of its
	// blocks' corners.
	corners:   Corner_Grid,
	coarse:    Corner_Grid,
	// The blocks of BLOCK³ bricks the drag can reach, the one tile each falls in if it
	// does, and the frame that last listed a block.
	blocks:        [dynamic][3]i32,
	block_tiles:   [dynamic]Tile, // .Brick where it falls in more than one
	blocks_listed: map[[3]i32]u32,
	// The bricks a uniform block turns to its tile (they are the tile at the end of `work`).
	fills:     int,
	masked:  bool, // the clay has a mask, which holds what it covers still
	elastic: bool, // weighed by `kelvin` (in voxels) rather than the falloff
	kelvin:  geom.Kelvinlet,
}

@(private)
grab_init :: proc(g: ^Clay_Grab, allocator: runtime.Allocator) {
	g.images = make([dynamic]Grab_Image, allocator)
	g.saved = make([dynamic]i32, allocator)
	g.bricks = make([dynamic][3]i32, allocator)
	g.kept = make(map[[3]i32]bool, allocator)
	g.listed = make(map[[3]i32]u32, allocator)
	g.work = make([dynamic][3]i32, allocator)
	g.results = make([dynamic]Brick, allocator)
	g.differs = make([dynamic]bool, allocator)
	g.moves = make([dynamic]Grab_Move, allocator)
	corner_grid_init(&g.corners, 1, allocator)
	corner_grid_init(&g.coarse, BLOCK, allocator)
	g.blocks = make([dynamic][3]i32, allocator)
	g.block_tiles = make([dynamic]Tile, allocator)
	g.blocks_listed = make(map[[3]i32]u32, allocator)
}

@(private)
grab_destroy :: proc(g: ^Clay_Grab) {
	delete(g.images)
	delete(g.saved)
	delete(g.bricks)
	delete(g.kept)
	delete(g.listed)
	delete(g.work)
	delete(g.results)
	delete(g.differs)
	delete(g.moves)
	corner_grid_destroy(&g.corners)
	corner_grid_destroy(&g.coarse)
	delete(g.blocks)
	delete(g.block_tiles)
	delete(g.blocks_listed)
}

// Starts a grab in the running stroke: the brush of `radius` (object space) pressed at
// each image's `centres[i]`, turned by `turns[i]` (the press's own image first, its turn
// the identity). With `elastic` the clay moves as an elastic solid keeping `volume` (0 to
// 1) of its volume would. Nothing moves until clay_grab_move.
clay_grab_begin :: proc(c: ^Clay, radius: f32, centres: []Vec3, turns: []matrix[3, 3]f32, elastic := false, volume: f32 = 0) {
	assert(c.in_stroke, "a grab needs a stroke")
	assert(len(centres) == len(turns), "an image needs its turn")
	g := &c.grab
	v := &c.volume
	g.active = true
	g.radius = max(radius / v.voxel, 1)
	clear(&g.images)
	for centre, i in centres do append(&g.images, Grab_Image{centre = (centre - v.origin) / v.voxel, turn = turns[i]})
	resize(&g.saved, len(c.volume.bricks))
	for &i in g.saved do i = 0
	clear(&g.bricks)
	clear(&g.kept)
	clear(&g.listed)
	clear(&g.blocks_listed)
	g.frame = 0
	g.masked = clay_has_mask(c)
	g.elastic = elastic
	if elastic do g.kelvin = geom.kelvinlet_make(g.radius, volume)
}

// How far from the middle of its falloff the grab moves clay, in voxels.
@(private)
grab_reach :: proc(g: ^Clay_Grab) -> f32 {
	return g.radius * (geom.KELVINLET_REACH if g.elastic else 1)
}

// Drags what the grab picked up by `offset` (object space) since the press, turned
// `angle` radians about `axis` (unit length, object space) through where it pressed, the
// turn carried with the drag. Returns how many bricks changed this frame.
clay_grab_move :: proc(c: ^Clay, offset: Vec3, axis := Vec3{}, angle: f32 = 0) -> int {
	g := &c.grab
	if !g.active || len(g.images) == 0 do return 0
	v := &c.volume

	// Each image's move, and the chain's length.
	clear(&g.moves)
	reach_far: f32 = 0
	o := offset / v.voxel
	for img in g.images {
		m := Grab_Move{centre = img.centre, offset = img.turn * o}
		if angle != 0 && axis != {} {
			// A turn conjugated by a mirror runs the other way round the mirrored axis.
			m.axis = linalg.normalize0(img.turn * axis)
			m.angle = angle if linalg.determinant(img.turn) > 0 else -angle
		}
		append(&g.moves, m)
		reach_far = max(reach_far, linalg.length(m.offset) + abs(m.angle) * g.radius)
	}
	g.steps = clamp(int(math.ceil(reach_far / (GRAB_STEP * g.radius))), 1, GRAB_STEPS_MAX)

	// The bricks to work out: every brick within reach of an image's drag, and every
	// brick the grab wrote before (the drag may have left it, which puts it back). Most of
	// a wide reach (an Elastic's) lies deep in the clay or far outside it: the reach is
	// first taken in blocks of BLOCK³ bricks, and a block whose corners' sources all fall
	// in one tile kind is that tile, so only its bricks that are not already it are written.
	g.frame += 1
	clear(&g.work)
	clear(&g.blocks)
	reach := grab_reach(g) + 2
	for m in g.moves {
		lo := block_floor(linalg.min(m.centre, m.centre + m.offset) - reach)
		hi := block_floor(linalg.max(m.centre, m.centre + m.offset) + reach)
		for z in lo.z ..= hi.z do for y in lo.y ..= hi.y do for x in lo.x ..= hi.x {
			bk := [3]i32{x, y, z}
			if grab_segment_distance(bk, BLOCK, m.centre, m.centre + m.offset) > reach do continue
			if g.blocks_listed[bk] == g.frame do continue
			g.blocks_listed[bk] = g.frame
			append(&g.blocks, bk)
		}
	}
	if len(g.blocks) > 0 {
		corner_grid_frame(c, &g.coarse, g.blocks[:], nil)
		resize(&g.block_tiles, len(g.blocks))
		jobs.parallel_for(c.pool, len(g.blocks), c, proc(data: rawptr, i: int) {
			c := cast(^Clay)data
			g := &c.grab
			cache: Snap_Cache
			cache.coord = {-1, -1, -1}
			tile, ok := grab_source_tile(c, &cache, &g.coarse, g.blocks[i])
			g.block_tiles[i] = tile if ok else .Brick
		})
	}
	fills := make([dynamic][3]i32, context.temp_allocator)
	fill_tiles := make([dynamic]Tile, context.temp_allocator)
	for bk, i in g.blocks {
		uniform := g.block_tiles[i]
		for z in 0 ..< i32(BLOCK) do for y in 0 ..< i32(BLOCK) do for x in 0 ..< i32(BLOCK) {
			bc := bk * BLOCK + {x, y, z}
			if !brick_in_domain(bc) || !grab_within(g, bc, reach) do continue
			if uniform == .Brick {
				grab_list(g, bc)
				continue
			}
			if bc in g.kept do continue
			if tile, live := volume_tile(v, bc); tile == uniform && live == nil do continue
			append(&fills, bc)
			append(&fill_tiles, uniform)
		}
	}
	for bc in g.bricks do grab_list(g, bc)
	worked := len(g.work)
	g.fills = len(fills)
	n := worked + g.fills
	if n == 0 do return 0
	if worked > 0 do corner_grid_frame(c, &g.corners, nil, g.work[:])
	append(&g.work, ..fills[:])
	resize(&g.results, n)
	resize(&g.differs, n)
	jobs.parallel_for(c.pool, worked, c, proc(data: rawptr, i: int) {
		c := cast(^Clay)data
		g := &c.grab
		g.differs[i] = grab_brick(c, g.work[i], &g.results[i])
	})
	for t, i in fill_tiles {
		value := tile_value(t)
		for &d in g.results[worked + i].d do d = value
		g.differs[worked + i] = true
	}

	// Commit, serially: a brick is saved for undo before its first change and made from a
	// tile where the clay arrives; it stays a brick for the rest of the grab (the stroke's
	// end turns what is all one clamp back into a tile).
	changed := 0
	for bc, i in g.work {
		if !g.differs[i] do continue
		saves := len(undo_current(&c.history).bricks)
		undo_record(&c.history, v, bc)
		tile, _ := volume_tile(v, bc)
		slot: u32
		if tile == .Brick {
			slot = volume_slot(v, bc)
		} else {
			slot, _ = volume_brick_make(v, bc, tile_value(tile))
			// Its save is the tile's, just made: stamped so a later change saves nothing
			// more, and the press's field here stays the tile.
			v.saved[slot] = c.history.stroke
		}
		if int(slot) >= len(g.saved) do resize(&g.saved, len(v.bricks))
		if len(undo_current(&c.history).bricks) > saves do g.saved[slot] = i32(saves) + 1
		v.bricks[slot] = g.results[i]
		if bc not_in g.kept {
			g.kept[bc] = true
			append(&g.bricks, bc)
		}
		surface_mark_brick(c, bc)
		changed += 1
	}
	// A warp that squeezes the clay (a thin tendril's sides) can leave a tile the drag did
	// not change beside a tile of the other kind, with no brick between to hold the surface
	// that runs along their shared face: such a tile becomes a brick of its value, which the
	// mesh and the stroke's band repair then see.
	for bc in g.work {
		tile, _ := volume_tile(v, bc)
		if tile == .Brick do continue
		other := Tile.Empty if tile == .Inside else Tile.Inside
		for axis in 0 ..< 3 do for side in 0 ..< 2 {
			nc := bc
			nc[axis] += 1 if side == 1 else -1
			if !brick_in_domain(nc) do continue
			if t, _ := volume_tile(v, nc); t != other do continue
			saves := len(undo_current(&c.history).bricks)
			undo_record(&c.history, v, bc)
			slot, _ := volume_brick_make(v, bc, tile_value(tile))
			v.saved[slot] = c.history.stroke
			if int(slot) >= len(g.saved) do resize(&g.saved, len(v.bricks))
			g.saved[slot] = i32(saves) + 1
			if bc not_in g.kept {
				g.kept[bc] = true
				append(&g.bricks, bc)
			}
			surface_mark_brick(c, bc)
			changed += 1
			break
		}
	}
	c.stroke_bricks += changed
	if changed > 0 do c.stroke_dabs += 1
	return changed
}

// Lists brick `bc` for this frame's work, once.
@(private)
grab_list :: proc(g: ^Clay_Grab, bc: [3]i32) {
	if g.listed[bc] == g.frame do return
	g.listed[bc] = g.frame
	append(&g.work, bc)
}

// Ends the grab at the stroke's end: every brick it wrote goes to the band repair.
@(private)
grab_end :: proc(c: ^Clay) {
	g := &c.grab
	if !g.active do return
	v := &c.volume
	for bc in g.bricks {
		tile, _ := volume_tile(v, bc)
		if tile == .Brick do band_mark(c, volume_slot(v, bc))
	}
	g.active = false
	clear(&g.bricks)
	clear(&g.kept)
	clear(&g.listed)
}

// Whether brick `bc` lies within `reach` voxels of any image's drag.
@(private)
grab_within :: proc(g: ^Clay_Grab, bc: [3]i32, reach: f32) -> bool {
	for m in g.moves do if grab_segment_distance(bc, 1, m.centre, m.centre + m.offset) <= reach do return true
	return false
}

// The distance from segment [a, b] to the box of `size`³ bricks at `at` (in units of that
// box), in voxels, from the box's middle less its half diagonal: never more than the true
// distance.
@(private)
grab_segment_distance :: proc(at: [3]i32, size: i32, a, b: Vec3) -> f32 {
	side := f32(size * BRICK)
	mid := Vec3{f32(at.x), f32(at.y), f32(at.z)} * side + (side - 1) * 0.5
	ab := b - a
	t: f32 = 0
	if l2 := linalg.dot(ab, ab); l2 > 0 do t = clamp(linalg.dot(mid - a, ab) / l2, 0, 1)
	return linalg.length(mid - (a + ab * t)) - side * 0.8660254
}

// Works out brick `bc` under the drag into `out`; true when that differs from the brick
// (or tile) as it is now. Reads only the field as it was at the press. Most bricks the
// drag passes over lie deep inside or far outside the clay: where the sources of the
// brick's corners, widened by how far the warp can bend between them, fall in tiles of one
// kind only, the brick is that tile without working out a voxel.
@(private)
grab_brick :: proc(c: ^Clay, bc: [3]i32, out: ^Brick) -> bool {
	g := &c.grab
	cache: Snap_Cache
	cache.coord = {-1, -1, -1}
	inv_r2 := 1 / (g.radius * g.radius)
	tile, live := volume_tile(&c.volume, bc)
	if uniform, ok := grab_source_tile(c, &cache, &g.corners, bc); ok {
		value := tile_value(uniform)
		for &d in out.d do d = value
		if live != nil do return true
		return tile != uniform
	}
	grab_lattice(c, &cache, bc, inv_r2, out)
	if live != nil do return live.d != out.d
	value := tile_value(tile)
	for d in out.d do if d != value do return true
	return false
}

// Brick `bc` into `out` from the sources on a lattice of every other voxel (and one past
// the brick), trilinear between them: the warp is smooth over a brick (its falloff spans
// the radius), so this is a quarter of the work for a shape off by a small, smooth
// fraction of a voxel. Every fourth voxel left grain where an Elastic squeezes the clay.
@(private)
grab_lattice :: proc(c: ^Clay, cache: ^Snap_Cache, bc: [3]i32, inv_r2: f32, out: ^Brick) {
	S :: 2
	L :: BRICK / S + 1
	p0 := Vec3{f32(bc.x), f32(bc.y), f32(bc.z)} * BRICK
	lattice: [L * L * L]Vec3 = ---
	corners: [8]Vec3
	mean: Vec3
	for corner in 0 ..< 8 {
		corners[corner] = corner_grid_at(&c.grab.corners, bc + {i32(corner & 1), i32(corner >> 1 & 1), i32(corner >> 2 & 1)})
		mean += corners[corner] / 8
	}
	// Where the warp is all but trilinear across the brick (its middle's source is within
	// LATTICE_FLAT of the corners' mean: most of an Elastic's wide reach), the corners say
	// it all.
	middle := grab_source(c, p0 + BRICK / 2, inv_r2)
	flat := linalg.length2(middle - mean) < LATTICE_FLAT * LATTICE_FLAT
	for z in 0 ..< L do for y in 0 ..< L do for x in 0 ..< L {
		k := (z * L + y) * L + x
		if x == L / 2 && y == L / 2 && z == L / 2 {
			lattice[k] = middle
		} else if flat || (x == 0 || x == L - 1) && (y == 0 || y == L - 1) && (z == 0 || z == L - 1) {
			t := Vec3{f32(x), f32(y), f32(z)} / (L - 1)
			lattice[k] = linalg.lerp(
				linalg.lerp(linalg.lerp(corners[0], corners[1], t.x), linalg.lerp(corners[2], corners[3], t.x), t.y),
				linalg.lerp(linalg.lerp(corners[4], corners[5], t.x), linalg.lerp(corners[6], corners[7], t.x), t.y),
				t.z,
			)
		} else {
			lattice[k] = grab_source(c, p0 + {f32(x), f32(y), f32(z)} * f32(S), inv_r2)
		}
	}
	// The press's values round where the sources fall, read once: a brick's voxels sample
	// eight values each, mostly the same few hundred.
	lo, hi := lattice[0], lattice[0]
	for q in lattice do lo, hi = linalg.min(lo, q), linalg.max(hi, q)
	f := linalg.floor(lo)
	base := [3]i32{i32(f.x), i32(f.y), i32(f.z)}
	top := linalg.floor(hi)
	span := [3]i32{i32(top.x), i32(top.y), i32(top.z)} - base + 2
	near: [GATHER * GATHER * GATHER]f32 = ---
	gathered := span.x <= GATHER && span.y <= GATHER && span.z <= GATHER
	if gathered {
		// Brick by brick, each looked up once.
		blo, bhi := shr3(base, 3), shr3(base + span - 1, 3) // BRICK is 8
		for bz in blo.z ..= bhi.z do for by in blo.y ..= bhi.y do for bx in blo.x ..= bhi.x {
			sb := [3]i32{bx, by, bz}
			data, value := snap_brick(c, sb)
			from := linalg.max(sb * BRICK, base) - base
			to := linalg.min(sb * BRICK + BRICK, base + span) - base
			for z in from.z ..< to.z do for y in from.y ..< to.y {
				row := near[(z * GATHER + y) * GATHER:]
				if data == nil {
					for x in from.x ..< to.x do row[x] = f32(value)
					continue
				}
				for x in from.x ..< to.x {
					l := base + {x, y, z} - sb * BRICK
					row[x] = f32(data[voxel_index(int(l.x), int(l.y), int(l.z))])
				}
			}
		}
	}
	for z in 0 ..< BRICK do for y in 0 ..< BRICK {
		// The row's lattice points, bilinear in y and z; then each voxel along x between two.
		lz, ly := z / S, y / S
		fz, fy := f32(z % S) / f32(S), f32(y % S) / f32(S)
		row: [L]Vec3 = ---
		for lx in 0 ..< L {
			a := linalg.lerp(lattice[(lz * L + ly) * L + lx], lattice[(lz * L + ly + 1) * L + lx], fy) if fy != 0 else lattice[(lz * L + ly) * L + lx]
			b := linalg.lerp(lattice[((lz + 1) * L + ly) * L + lx], lattice[((lz + 1) * L + ly + 1) * L + lx], fy) if fy != 0 else lattice[((lz + 1) * L + ly) * L + lx]
			row[lx] = linalg.lerp(a, b, fz) if fz != 0 else a
		}
		for x in 0 ..< BRICK {
			lx := x / S
			fx := f32(x % S) / f32(S)
			q := linalg.lerp(row[lx], row[lx + 1], fx) if fx != 0 else row[lx]
			k := voxel_index(x, y, z)
			if !gathered {
				out.d[k] = snap_sample(c, cache, q)
				continue
			}
			// As snap_sample, from the values read.
			qf := linalg.floor(q)
			t := q - qf
			o := [3]i32{i32(qf.x), i32(qf.y), i32(qf.z)} - base
			i := (o.z * GATHER + o.y) * GATHER + o.x
			X :: 1
			Y :: GATHER
			Z :: GATHER * GATHER
			a := math.lerp(math.lerp(near[i], near[i + X], t.x), math.lerp(near[i + Y], near[i + Y + X], t.x), t.y)
			b := math.lerp(math.lerp(near[i + Z], near[i + Z + X], t.x), math.lerp(near[i + Z + Y], near[i + Z + Y + X], t.x), t.y)
			out.d[k] = i16(clamp(math.round(math.lerp(a, b, t.z)), -f32(CLAMP), f32(CLAMP)))
		}
	}
}

// How far from trilinear across a brick, in voxels, the warp may be for its corners alone
// to place its sources.
LATTICE_FLAT :: 1.0 / 64

// The most voxels along an axis a brick's sources are read from at once.
@(private)
GATHER :: 16

// Where the clay at voxel `at` came from: the moves undone from the last to the first.
@(private)
grab_source :: #force_inline proc(c: ^Clay, at: Vec3, inv_r2: f32) -> Vec3 {
	g := &c.grab
	k := f32(g.steps)
	q := at
	for s := g.steps - 1; s >= 0; s -= 1 {
		target := q
		for _ in 0 ..< GRAB_ITERATIONS {
			u := Vec3{}
			for m in g.moves do u += grab_displacement(c, m, f32(s) / k, 1 / k, q, inv_r2)
			next := target - u
			// Settled (outside the move's falloff it is there at once).
			moved := next - q
			q = next
			if linalg.dot(moved, moved) < GRAB_SETTLED * GRAB_SETTLED do break
		}
	}
	return q
}

// The one tile kind every source of box `at` of `grid` (a brick or a block) falls in, if
// there is one: the box of its corners' sources, widened by how far the warp bends between
// them and a voxel for the trilinear read, met only tiles of that kind as the field was at
// the press.
@(private)
grab_source_tile :: proc(c: ^Clay, cache: ^Snap_Cache, grid: ^Corner_Grid, at: [3]i32) -> (tile: Tile, ok: bool) {
	lo, hi := Vec3{max(f32), max(f32), max(f32)}, Vec3{min(f32), min(f32), min(f32)}
	for corner in 0 ..< 8 {
		q := corner_grid_at(grid, at + {i32(corner & 1), i32(corner >> 1 & 1), i32(corner >> 2 & 1)})
		lo, hi = linalg.min(lo, q), linalg.max(hi, q)
	}
	inv_r2 := 1 / (c.grab.radius * c.grab.radius)
	spacing := f32(grid.stride * BRICK)
	// Between its corners the warp bends by at most its second derivative times the
	// squared spacing over eight: the falloff's is under 12 / r² of the move.
	g := &c.grab
	reach: f32 = 0
	for m in g.moves do reach = max(reach, linalg.length(m.offset) + abs(m.angle) * g.radius)
	// The Kelvinlet's smallest scale is the radius, so its curvature is of the same order.
	bend := 12 * reach * inv_r2 * spacing * spacing / 8
	margin := min(bend, reach) + 2
	blo, bhi := brick_floor(lo - margin), brick_floor(hi + margin)
	most := 64 * grid.stride * grid.stride * grid.stride
	if (bhi.x - blo.x + 1) * (bhi.y - blo.y + 1) * (bhi.z - blo.z + 1) > most do return .Brick, false
	first := true
	for z in blo.z ..= bhi.z do for y in blo.y ..= bhi.y do for x in blo.x ..= bhi.x {
		t := snap_tile(c, cache, {x, y, z})
		if t == .Brick do return .Brick, false
		if first do tile = t
		else if t != tile do return .Brick, false
		first = false
	}
	return tile, true
}

// What brick `bc` was at the press: a brick, or the tile it was.
@(private)
snap_tile :: proc(c: ^Clay, cache: ^Snap_Cache, bc: [3]i32) -> Tile {
	_ = snap_value(c, cache, bc * BRICK)
	if cache.data != nil do return .Brick
	return .Inside if cache.value < 0 else .Empty
}

// How far move `m`'s share from `from` to `from + share` of the drag carries the clay
// at `q`: by the falloff around where its middle is then, the turn about it carried too.
@(private)
grab_displacement :: #force_inline proc(c: ^Clay, m: Grab_Move, from, share: f32, q: Vec3, inv_r2: f32) -> Vec3 {
	centre := m.centre + m.offset * from
	delta := q - centre
	pull := m.offset * share
	moved: Vec3
	w: f32
	if c.grab.elastic {
		if linalg.dot(delta, delta) >= c.grab.kelvin.fade_to * c.grab.kelvin.fade_to do return {}
		follow := geom.kelvinlet_follow(&c.grab.kelvin, delta)
		hold: f32 = 1
		if c.grab.masked do hold = 1 - snap_mask(c, q)
		if hold == 0 do return {}
		moved = q + follow * pull * hold
		// The turn by the share of the drag the Kelvinlet passes on there, a third of its
		// trace, as the mesh Elastic's.
		w = clamp((follow[0, 0] + follow[1, 1] + follow[2, 2]) / 3, 0, 1) * hold
	} else {
		w = falloff(linalg.dot(delta, delta) * inv_r2)
		if w == 0 do return {}
		if c.grab.masked do w *= 1 - snap_mask(c, q)
		if w == 0 do return {}
		moved = q + pull * w
	}
	if m.angle != 0 {
		next := centre + m.offset * share
		moved = next + linalg.matrix3_rotate_f32(m.angle * share * w, m.axis) * (moved - next)
	}
	return moved - q
}

// The last brick a sample read, so a run of samples in one brick finds it once.
@(private)
Snap_Cache :: struct {
	coord: [3]i32,
	data:  ^[BRICK_VOXELS]i16, // nil for a tile
	value: i16, // the tile's value
}

// The field as it was at the press at voxel `p` (voxel coordinates, any point),
// trilinear between the voxels around it.
@(private)
snap_sample :: proc(c: ^Clay, cache: ^Snap_Cache, p: Vec3) -> i16 {
	f := linalg.floor(p)
	t := p - f
	g := [3]i32{i32(f.x), i32(f.y), i32(f.z)}
	sum: f32
	for corner in 0 ..< 8 {
		o := [3]i32{i32(corner & 1), i32(corner >> 1 & 1), i32(corner >> 2 & 1)}
		wx := t.x if o.x == 1 else 1 - t.x
		wy := t.y if o.y == 1 else 1 - t.y
		wz := t.z if o.z == 1 else 1 - t.z
		w := wx * wy * wz
		if w == 0 do continue
		sum += w * f32(snap_value(c, cache, g + o))
	}
	return i16(clamp(math.round(sum), -f32(CLAMP), f32(CLAMP)))
}

// The value voxel `g` had at the press.
@(private)
snap_value :: proc(c: ^Clay, cache: ^Snap_Cache, g: [3]i32) -> i16 {
	bc := shr3(g, 3) // BRICK is 8
	if bc != cache.coord {
		cache.coord = bc
		cache.data, cache.value = snap_brick(c, bc)
	}
	if cache.data == nil do return cache.value
	l := g - bc * BRICK
	return cache.data[voxel_index(int(l.x), int(l.y), int(l.z))]
}

// Brick `bc` as it was at the press: its values, or nil and the value of the tile it was.
@(private)
snap_brick :: proc(c: ^Clay, bc: [3]i32) -> (data: ^[BRICK_VOXELS]i16, value: i16) {
	value = CLAMP
	if !brick_in_domain(bc) do return
	tile, b := volume_tile(&c.volume, bc)
	if b == nil do return nil, tile_value(tile)
	if i := c.grab.saved[volume_slot(&c.volume, bc)]; i > 0 {
		saved := &undo_current(&c.history).bricks[i - 1]
		if saved.tile == .Brick do return &saved.d, 0
		return nil, tile_value(saved.tile)
	}
	return &b.d, 0
}

// The mask at the press at the voxel nearest `p`, from 0 (free) to 1 (fully masked).
@(private)
snap_mask :: proc(c: ^Clay, p: Vec3) -> f32 {
	r := linalg.round(p)
	g := [3]i32{i32(r.x), i32(r.y), i32(r.z)}
	bc := shr3(g, 3)
	if !brick_in_domain(bc) do return 0
	l := g - bc * BRICK
	k := voxel_index(int(l.x), int(l.y), int(l.z))
	tile, _ := volume_tile(&c.volume, bc)
	if tile != .Brick do return 0
	slot := volume_slot(&c.volume, bc)
	if i := c.grab.saved[slot]; i > 0 {
		step := undo_current(&c.history)
		saved := &step.bricks[i - 1]
		if saved.mask < 0 do return 0
		return f32(step.masks[saved.mask].m[k]) / 255
	}
	m := mask_of(&c.volume, slot)
	if m == nil do return 0
	return f32(m.m[k]) / 255
}

// The side of a block of bricks the reach is first taken in.
BLOCK :: 4

// The block holding voxel point `p`.
@(private)
block_floor :: proc(p: Vec3) -> [3]i32 {
	f := linalg.floor(p / (BLOCK * BRICK))
	return {i32(f.x), i32(f.y), i32(f.z)}
}

// The sources of a frame's corners of boxes of `stride`³ bricks (bricks or blocks), on a
// grid over the boxes from `lo`, `dim` corners an axis; only those `wanted` are worked out.
@(private)
Corner_Grid :: struct {
	stride:  i32,
	lo, dim: [3]i32,
	sources: [dynamic]Vec3,
	wanted:  [dynamic]bool,
}

@(private)
corner_grid_init :: proc(grid: ^Corner_Grid, stride: i32, allocator: runtime.Allocator) {
	grid.stride = stride
	grid.sources = make([dynamic]Vec3, allocator)
	grid.wanted = make([dynamic]bool, allocator)
}

@(private)
corner_grid_destroy :: proc(grid: ^Corner_Grid) {
	delete(grid.sources)
	delete(grid.wanted)
}

// The source of the corner at `at` (a box's lowest corner, in boxes).
@(private)
corner_grid_at :: #force_inline proc(grid: ^Corner_Grid, at: [3]i32) -> Vec3 {
	l := at - grid.lo
	return grid.sources[(l.z * grid.dim.y + l.y) * grid.dim.x + l.x]
}

// Works out the corners of the boxes `all` (every corner of their bounds) or `some` (only
// theirs), in parallel by rows.
@(private)
corner_grid_frame :: proc(c: ^Clay, grid: ^Corner_Grid, all, some: [][3]i32) {
	boxes := all if all != nil else some
	lo, hi := boxes[0], boxes[0]
	for b in boxes do lo, hi = linalg.min(lo, b), linalg.max(hi, b)
	grid.lo, grid.dim = lo, hi - lo + 2
	count := int(grid.dim.x * grid.dim.y * grid.dim.z)
	resize(&grid.sources, count)
	resize(&grid.wanted, count)
	for &w in grid.wanted do w = all != nil
	for b in some do for corner in 0 ..< 8 {
		l := b - grid.lo + {i32(corner & 1), i32(corner >> 1 & 1), i32(corner >> 2 & 1)}
		grid.wanted[(l.z * grid.dim.y + l.y) * grid.dim.x + l.x] = true
	}
	Rows :: struct {
		c:    ^Clay,
		grid: ^Corner_Grid,
	}
	rows := Rows{c, grid}
	jobs.parallel_for(c.pool, int(grid.dim.y * grid.dim.z), &rows, proc(data: rawptr, i: int) {
		rows := cast(^Rows)data
		g := rows.grid
		inv_r2 := 1 / (rows.c.grab.radius * rows.c.grab.radius)
		y, z := i32(i) % g.dim.y, i32(i) / g.dim.y
		for x in 0 ..< g.dim.x {
			k := i * int(g.dim.x) + int(x)
			if !g.wanted[k] do continue
			at := (g.lo + {x, y, z}) * g.stride * BRICK
			g.sources[k] = grab_source(rows.c, Vec3{f32(at.x), f32(at.y), f32(at.z)}, inv_r2)
		}
	})
}
