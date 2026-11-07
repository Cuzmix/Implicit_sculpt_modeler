package voxel

import "base:runtime"
import "core:slice"

import "../jobs"

// Remove floaters (ZBrush's Delete loose parts, 3D-Coat's Clean clay, Nomad's Keep largest):
// what Snake hook, Tube and Subtract leave cut off from the body goes, keeping the largest
// piece, as one undo step. A piece is a set of inside voxels joined face to face. Each brick
// labels its own pieces in parallel (an Inside tile is one piece), the labels are joined
// across the bricks' faces with a union-find in brick order, so the result is the same on
// any thread count, and the bricks of the pieces that go become Empty tiles or lose those
// voxels, the band around them repaired at the step's end.

// One brick (or Inside tile) of the clay: its pieces' labels, 1 up, 0 outside.
@(private = "file")
Piece_Unit :: struct {
	coord:  [3]i32,
	slot:   u32, // TILE_INSIDE for an Inside tile
	count:  int, // its pieces
	base:   int, // its first piece's number among all of them
	labels: [BRICK * BRICK * BRICK]u16,
}

@(private = "file")
Piece_Run :: struct {
	v:     ^Volume,
	units: []Piece_Unit,
}

// The clay's pieces: its units labelled, the labels joined, and the pieces' roots by size,
// largest first (the first of equals in number order).
@(private = "file")
Pieces :: struct {
	units:  [dynamic]Piece_Unit,
	parent: []i32,
	ranked: [dynamic]i32,
}

@(private = "file")
pieces_destroy :: proc(p: ^Pieces) {
	delete(p.units)
	delete(p.parent, runtime.heap_allocator())
	delete(p.ranked)
}

// Keeps the largest piece of the clay and removes the rest. No stroke may be running.
// Returns how many pieces went (0 leaves the clay as it was).
clay_keep_largest :: proc(c: ^Clay) -> int {
	p := pieces_find(c)
	defer pieces_destroy(&p)
	if len(p.ranked) < 2 do return 0
	pieces_keep(c, &p, p.ranked[0])
	return len(p.ranked) - 1
}

// How many pieces the clay is in.
clay_piece_count :: proc(c: ^Clay) -> int {
	p := pieces_find(c)
	defer pieces_destroy(&p)
	return len(p.ranked)
}

// Keeps only the clay's `rank`th largest piece (0 the largest), as an undo step of its
// own; Separate pieces gives each copy of a clay one of them. False when the clay has no
// piece of that rank or is that piece alone.
clay_keep_piece :: proc(c: ^Clay, rank: int) -> bool {
	p := pieces_find(c)
	defer pieces_destroy(&p)
	if rank >= len(p.ranked) || len(p.ranked) < 2 do return false
	pieces_keep(c, &p, p.ranked[rank])
	return true
}

@(private = "file")
pieces_find :: proc(c: ^Clay) -> (p: Pieces) {
	assert(!c.in_stroke, "a stroke is running")
	v := &c.volume
	heap := runtime.heap_allocator()
	p.units = make([dynamic]Piece_Unit, heap)
	p.ranked = make([dynamic]i32, heap)
	units := &p.units
	// The units: every brick in slot order, then the Inside tiles, which lie in the bricks'
	// box (a band of bricks surrounds them).
	lo, hi := [3]i32{max(i32), max(i32), max(i32)}, [3]i32{min(i32), min(i32), min(i32)}
	for bc, slot in v.coords {
		if bc == BRICK_FREE do continue
		append(units, Piece_Unit{coord = bc, slot = u32(slot)})
		lo, hi = {min(lo.x, bc.x), min(lo.y, bc.y), min(lo.z, bc.z)}, {max(hi.x, bc.x), max(hi.y, bc.y), max(hi.z, bc.z)}
	}
	if len(units) == 0 do return
	for z in lo.z ..= hi.z do for y in lo.y ..= hi.y do for x in lo.x ..= hi.x {
		if t, _ := volume_tile(v, {x, y, z}); t == .Inside do append(units, Piece_Unit{coord = {x, y, z}, slot = TILE_INSIDE})
	}
	unit_of := make(map[[3]i32]i32, len(units), heap)
	defer delete(unit_of)
	for u, i in units do unit_of[u.coord] = i32(i)

	run := Piece_Run{v, units[:]}
	jobs.parallel_for(c.pool, len(units), &run, proc(data: rawptr, i: int) {
		r := cast(^Piece_Run)data
		piece_label(r.v, &r.units[i])
	})

	// Every piece a number; the pieces that touch across a face joined.
	total := 0
	for &u in units {
		u.base = total
		total += u.count
	}
	if total == 0 do return
	p.parent = make([]i32, total, heap)
	parent := p.parent
	for &x, i in parent do x = i32(i)
	for &u in units {
		for axis in 0 ..< 3 {
			nc := u.coord
			nc[axis] += 1
			n, found := unit_of[nc]
			if !found do continue
			w := &units[n]
			for b in 0 ..< BRICK do for a in 0 ..< BRICK {
				here, there: [3]int
				here[(axis + 1) % 3], here[(axis + 2) % 3] = a, b
				there = here
				here[axis], there[axis] = BRICK - 1, 0
				la := u.labels[voxel_index(here.x, here.y, here.z)]
				lb := w.labels[voxel_index(there.x, there.y, there.z)]
				if la == 0 || lb == 0 do continue
				piece_join(parent, i32(u.base) + i32(la) - 1, i32(w.base) + i32(lb) - 1)
			}
		}
	}

	// The pieces by size, largest first, the first of equals in number order.
	size := make([]int, total, heap)
	defer delete(size, heap)
	for &u in units {
		for l in u.labels do if l != 0 do size[piece_root(parent, i32(u.base) + i32(l) - 1)] += 1
	}
	for n, i in size do if n > 0 do append(&p.ranked, i32(i))
	Ranking :: struct {
		size: []int,
	}
	ranking := Ranking{size}
	context.user_ptr = &ranking
	slice.stable_sort_by(p.ranked[:], proc(a, b: i32) -> bool {
		r := cast(^Ranking)context.user_ptr
		return r.size[a] > r.size[b]
	})
	return
}

// Removes every piece but `keep` (a root), as one undo step.
@(private = "file")
pieces_keep :: proc(c: ^Clay, p: ^Pieces, keep: i32) {
	v := &c.volume
	parent := p.parent
	// The units that lose a piece, and the bricks around them.
	clay_stroke_begin(c)
	for &u in p.units {
		if u.count == 0 do continue
		lost := false
		for p in 0 ..< u.count do lost ||= piece_root(parent, i32(u.base + p)) != keep
		if !lost do continue
		// The bricks around it hold distances to what goes: they are solved again.
		for dz in i32(-1) ..= 1 do for dy in i32(-1) ..= 1 do for dx in i32(-1) ..= 1 {
			nc := u.coord + {dx, dy, dz}
			if t, _ := volume_tile(v, nc); t != .Brick do continue
			undo_record(&c.history, v, nc)
			band_mark(c, volume_slot(v, nc))
		}
		undo_record(&c.history, v, u.coord)
		surface_mark_brick(c, u.coord)
		// An Inside tile is one piece, and goes whole.
		if u.slot == TILE_INSIDE {
			volume_brick_collapse(v, u.coord, .Empty)
			continue
		}
		// A brick loses the voxels of what goes; its outside voxels may hold distances to
		// the piece kept next door, so the repair (which empties it if nothing is left)
		// solves it rather than it go Empty here.
		_, b := volume_tile(v, u.coord)
		for l, k in u.labels {
			if l != 0 && piece_root(parent, i32(u.base) + i32(l) - 1) != keep do b.d[k] = CLAMP
		}
		band_mark(c, u.slot)
	}
	_ = clay_stroke_end(c)
}

// Labels the pieces of unit `u` within it, face to face, in voxel order.
@(private = "file")
piece_label :: proc(v: ^Volume, u: ^Piece_Unit) {
	if u.slot == TILE_INSIDE {
		u.count = 1
		for &l in u.labels do l = 1
		return
	}
	b := &v.bricks[u.slot]
	stack: [BRICK * BRICK * BRICK]u16
	for k in 0 ..< len(b.d) {
		if b.d[k] >= 0 || u.labels[k] != 0 do continue
		u.count += 1
		label := u16(u.count)
		u.labels[k] = label
		top := 0
		stack[top] = u16(k)
		top += 1
		for top > 0 {
			top -= 1
			at := int(stack[top])
			x, y, z := at % BRICK, at / BRICK % BRICK, at / (BRICK * BRICK)
			STEPS :: [6][3]int{{-1, 0, 0}, {1, 0, 0}, {0, -1, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 1}}
			for s in STEPS {
				nx, ny, nz := x + s.x, y + s.y, z + s.z
				if nx < 0 || ny < 0 || nz < 0 || nx >= BRICK || ny >= BRICK || nz >= BRICK do continue
				n := voxel_index(nx, ny, nz)
				if b.d[n] >= 0 || u.labels[n] != 0 do continue
				u.labels[n] = label
				stack[top] = u16(n)
				top += 1
			}
		}
	}
}

@(private = "file")
piece_root :: proc(parent: []i32, a: i32) -> i32 {
	r := a
	for parent[r] != r do r = parent[r]
	// Halve the path behind for the next look.
	for x := a; parent[x] != r; {
		next := parent[x]
		parent[x] = r
		x = next
	}
	return r
}

// Joins two pieces, the lower number the root, so the roots do not depend on the order
// the joins come in beyond the brick order they are made in.
@(private = "file")
piece_join :: proc(parent: []i32, a, b: i32) {
	ra, rb := piece_root(parent, a), piece_root(parent, b)
	if ra == rb do return
	if ra < rb do parent[rb] = ra
	else do parent[ra] = rb
}
