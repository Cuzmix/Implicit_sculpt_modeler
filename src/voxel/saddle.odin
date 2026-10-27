package voxel

import "base:runtime"

import "../jobs"

// Saddle faces. A 2×2 face of voxels whose inside corners sit on one diagonal and outside
// corners on the other (a saddle) is crossed by the surface four times: two surface
// segments through one face, which the surface nets turn into an edge shared by four
// triangles. The field keeps no saddle face: after every change, the inside corner with
// the smaller distance is moved a hair outside (SADDLE_FLIP: the smallest positive value,
// a 4096th of a voxel, so that it is outside for both the `d < 0` tests and the raycast's
// `d <= 0`). A flip only ever turns an inside voxel outside, so the pass ends; it can make
// a new saddle on another face through the flipped voxel, so those faces are checked again
// until none is left. With no saddle face every cell face has two crossings or none, which
// is what makes mesh_node's surface closed and manifold (one vertex per loop of crossings).
// The pass runs when a field is built or read and at a stroke's end over the bricks the
// stroke touched: between a stroke's dabs a saddle may stand for a few frames, and the
// mesh shows an edge in four triangles there until the stroke ends.
// A planar field has no saddle, so flips happen only where the surface bends within a voxel:
// a neck or sheet thinner than a voxel loses a voxel, and a sheet one voxel thick on a
// diagonal dissolves.
SADDLE_FLIP :: i16(1)

// A face: its lower corner voxel and the axis it is square to.
@(private)
Saddle_Face :: struct {
	g:    [3]i32,
	axis: u8,
}

// Finds the saddle faces among those with a lower corner in bricks `slots` or the voxel
// layer before them (the faces a change to those bricks can have made), in parallel a
// brick at a time, then flips until none is left, in a fixed order whatever the thread
// count. With `record`, every brick written is saved for undo first (inside a stroke); a
// flipped corner in an Inside tile makes that tile a brick. Returns how many corners
// flipped; the bricks written are marked for the band repair and the surface.
@(private)
resolve_saddles :: proc(c: ^Clay, slots: []u32, record: bool) -> (flips: int) {
	if len(slots) == 0 do return 0
	heap := runtime.heap_allocator()
	Scan :: struct {
		c:     ^Clay,
		slots: []u32,
		found: [][dynamic]Saddle_Face,
	}
	scan := Scan{c, slots, make([][dynamic]Saddle_Face, len(slots), heap)}
	defer {
		for &f in scan.found do delete(f)
		delete(scan.found, heap)
	}
	// The windows are gathered into the clay's scratch (Smooth's, free again by now).
	resize(&c.windows, len(slots) * WINDOW_VOXELS)
	jobs.parallel_for(c.pool, len(slots), &scan, proc(data: rawptr, i: int) {
		s := cast(^Scan)data
		v := &s.c.volume
		s.found[i].allocator = runtime.heap_allocator() // allocated on the first find only
		window := s.c.windows[i * WINDOW_VOXELS:][:WINDOW_VOXELS]
		lo := v.coords[s.slots[i]] * BRICK - 1
		gather_window(v, lo, WINDOW, window)
		// Faces with a lower corner at window index 0 to BRICK (the layer before the brick
		// and the brick): the other corners reach index BRICK + 1, the window's last.
		for axis in 0 ..< 3 {
			u, w := (axis + 1) % 3, (axis + 2) % 3
			su, sw := window_stride(u), window_stride(w)
			for z in 0 ..= BRICK do for y in 0 ..= BRICK do for x in 0 ..= BRICK {
				at := window_at(x, y, z)
				if saddle_at(window[at] < 0, window[at + su] < 0, window[at + sw] < 0, window[at + su + sw] < 0) {
					append(&s.found[i], Saddle_Face{lo + {i32(x), i32(y), i32(z)}, u8(axis)})
				}
			}
		}
	})
	work := make([dynamic]Saddle_Face, heap)
	defer delete(work)
	for f in scan.found do append(&work, ..f[:])
	for len(work) > 0 {
		face := pop(&work)
		if flip_saddle(c, face, record) {
			flips += 1
			// Every face through the flipped corner may be a saddle now.
			flipped := saddle_corner(c, face)
			for axis in 0 ..< 3 {
				u, w := (axis + 1) % 3, (axis + 2) % 3
				for k in 0 ..< 4 {
					g := flipped
					if k & 1 != 0 do g[u] -= 1
					if k & 2 != 0 do g[w] -= 1
					append(&work, Saddle_Face{g, u8(axis)})
				}
			}
		}
	}
	return
}

@(private = "file")
window_stride :: #force_inline proc(axis: int) -> int {
	switch axis {
	case 0:
		return 1
	case 1:
		return WINDOW
	}
	return WINDOW * WINDOW
}

// Whether the four corners (lower, +u, +w, +u+w) are a saddle: the insides on one diagonal.
@(private = "file")
saddle_at :: #force_inline proc(a, b, cc, d: bool) -> bool {
	return a == d && b == cc && a != b
}

// The four corner voxels of `face`: lower, +u, +w, +u+w.
@(private = "file")
face_corners :: proc(face: Saddle_Face) -> (g: [4][3]i32) {
	u, w := (int(face.axis) + 1) % 3, (int(face.axis) + 2) % 3
	for k in 0 ..< 4 {
		g[k] = face.g
		if k & 1 != 0 do g[k][u] += 1
		if k & 2 != 0 do g[k][w] += 1
	}
	return
}

// The inside corner of `face` that a flip takes: the one with the smaller distance, the
// lower coordinate (z, then y, then x) when they tie. Reads the field as it is now.
@(private = "file")
saddle_corner :: proc(c: ^Clay, face: Saddle_Face) -> [3]i32 {
	g := face_corners(face)
	d: [4]i16
	for k in 0 ..< 4 do d[k] = volume_value(&c.volume, g[k])
	// The insides are corners 0 and 3, or 1 and 2.
	a, b := 0, 3
	if d[0] >= 0 do a, b = 1, 2
	if d[b] > d[a] do return g[b] // the smaller |d| is the larger (less negative) value
	if d[a] > d[b] do return g[a]
	// Tie: the lower coordinate.
	ga, gb := g[a], g[b]
	if ga.z != gb.z do return ga if ga.z < gb.z else gb
	if ga.y != gb.y do return ga if ga.y < gb.y else gb
	return ga if ga.x < gb.x else gb
}

// Flips `face`'s chosen corner if the face is a saddle as the field stands. Returns whether
// it did.
@(private = "file")
flip_saddle :: proc(c: ^Clay, face: Saddle_Face, record: bool) -> bool {
	v := &c.volume
	g := face_corners(face)
	for p in g do if p.x < 0 || p.y < 0 || p.z < 0 || p.x >= DOMAIN || p.y >= DOMAIN || p.z >= DOMAIN do return false
	d: [4]bool
	for k in 0 ..< 4 do d[k] = volume_value(v, g[k]) < 0
	if !saddle_at(d[0], d[1], d[2], d[3]) do return false
	corner := saddle_corner(c, face)
	bc := shr3(corner, 3) // BRICK is 8
	if record do undo_record(&c.history, v, bc)
	tile, brick := volume_tile(v, bc)
	slot: u32
	if brick == nil {
		slot, brick = volume_brick_make(v, bc, tile_value(tile))
	} else {
		slot = volume_slot(v, bc)
	}
	l := and3(corner, BRICK - 1)
	brick.d[voxel_index(int(l.x), int(l.y), int(l.z))] = SADDLE_FLIP
	band_mark(c, slot)
	surface_mark_box(c, bc, {i8(l.x), i8(l.y), i8(l.z)}, {i8(l.x), i8(l.y), i8(l.z)})
	return true
}
