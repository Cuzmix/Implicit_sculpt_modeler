package uv

import "core:math"
import "core:slice"

// Skyline packing (the bottom-left skyline of Jylänki's survey, which xatlas and Blender's
// box packer also build on): the islands, turned to their smallest boxes, are placed
// tallest first each where its top comes lowest along the skyline of what is placed
// (against a segment's left or right end, upright or on its side), in a row of `tiles`
// squares (UDIM tiles 1001, 1002, ... along u) that no box crosses. The
// square's side is the least that holds them all, found by halving, so the islands come
// out as large as they can. Gaps of PACK_GAP of a tile lie between neighbours and half
// that at the walls.

Pack_Method :: enum u8 {
	Skyline, // the skyline, or the shelf rows in one square when those fill more (a few big islands)
	Shelf,   // rows of falling height only: quicker
}

Pack_Options :: struct {
	method: Pack_Method,
	tiles:  int, // UDIM tiles in a row along u, from 1001; 1 for the unit square
}

DEFAULT_PACK :: Pack_Options{.Skyline, 1}

// Packs every island of `u` (for the mesh `indices`) with fewer than two pinned vertices
// into the tiles, in place; returns the share of the tiles their boxes fill.
pack :: proc(u: ^Uvs, indices: []u32, options := DEFAULT_PACK) -> f32 {
	if !has(u^) || u.islands == 0 do return 0
	filled := pack_islands(u, movable_islands(u^, indices), nil, options)
	u.filled = boxes_filled(u^)
	return filled
}

// Per island, whether it may move: true unless two or more of its vertices are pinned,
// which hold it where it lies. In the temp allocator.
@(private)
movable_islands :: proc(u: Uvs, indices: []u32) -> []bool {
	place := make([]bool, u.islands, context.temp_allocator)
	for &p in place do p = true
	if u.pins == nil do return place
	// Each pinned vertex once per island it has corners in.
	Held :: struct {
		island, vertex: u32,
	}
	held := make([dynamic]Held, context.temp_allocator)
	for t in 0 ..< len(u.corner) do for k in 0 ..< 3 {
		v := indices[3 * t + k]
		if _, on := slice.binary_search(u.pins, v); on do append(&held, Held{u.island[t], v})
	}
	slice.sort_by(held[:], proc(a, b: Held) -> bool {return a.island < b.island || (a.island == b.island && a.vertex < b.vertex)})
	count := make([]int, u.islands, context.temp_allocator)
	for h, i in held do if i == 0 || h != held[i - 1] do count[h.island] += 1
	for c, i in count do if c >= 2 do place[i] = false
	return place
}

// The packer `options` names for the islands `place` asks for (see shelf_pack for
// `leader`); the share of the tiles the boxes fill.
@(private)
pack_islands :: proc(u: ^Uvs, place: []bool, leader: []i32, options: Pack_Options) -> f32 {
	switch options.method {
	case .Shelf:
		shelf_pack(u, place, leader)
		return boxes_filled(u^)
	case .Skyline:
		tiles := max(options.tiles, 1)
		if tiles > 1 do return skyline_pack(u, place, leader, tiles)
		// In one square both are tried and the fuller kept: the skyline wins with many
		// mixed islands, the rows with a few big ones.
		before := slice.clone(u.corner, context.temp_allocator)
		sky := skyline_pack(u, place, leader, 1)
		after := slice.clone(u.corner, context.temp_allocator)
		copy(u.corner, before)
		shelf_pack(u, place, leader)
		rows := boxes_filled(u^)
		if sky >= rows {
			copy(u.corner, after)
			return sky
		}
		return rows
	}
	return 0
}

@(private = "file")
Box :: struct {
	lo, size: [2]f32,
	island:   u32,
}

@(private = "file")
Segment :: struct {
	x, w, y: f32,
}

@(private)
skyline_pack :: proc(u: ^Uvs, place: []bool, leader: []i32, tiles: int) -> f32 {
	assert(len(place) == u.islands)
	turn_to_smallest_box(u, place, leader)
	lo := make([][2]f32, u.islands, context.temp_allocator)
	hi := make([][2]f32, u.islands, context.temp_allocator)
	for &l in lo do l = {math.F32_MAX, math.F32_MAX}
	for &h in hi do h = {-math.F32_MAX, -math.F32_MAX}
	for c, t in u.corner do if place[u.island[t]] {
		i := u.island[t]
		for p in c do lo[i], hi[i] = {min(lo[i].x, p.x), min(lo[i].y, p.y)}, {max(hi[i].x, p.x), max(hi[i].y, p.y)}
	}
	boxes := make([dynamic]Box, 0, u.islands, context.temp_allocator)
	area: f64 = 0
	biggest: f32 = 0
	for i in 0 ..< u.islands do if place[i] && hi[i].x >= lo[i].x {
		size := hi[i] - lo[i]
		append(&boxes, Box{lo[i], size, u32(i)})
		area += f64(size.x) * f64(size.y)
		biggest = max(biggest, size.x, size.y)
	}
	if len(boxes) == 0 do return 0
	slice.sort_by(boxes[:], proc(a, b: Box) -> bool {
		if a.size.y != b.size.y do return a.size.y > b.size.y
		if a.size.x != b.size.x do return a.size.x > b.size.x
		return a.island < b.island
	})
	at := make([][2]f32, len(boxes), context.temp_allocator)
	turned := make([]bool, len(boxes), context.temp_allocator)
	sky := make([][dynamic]Segment, tiles, context.temp_allocator)
	for &s in sky do s = make([dynamic]Segment, 0, 64, context.temp_allocator)
	// A box may lie on its side too, unless mirrored islands must turn alike.
	may_turn := leader == nil
	fits :: proc(boxes: []Box, side: f32, sky: [][dynamic]Segment, at: [][2]f32, turned: []bool, may_turn: bool) -> bool {
		gap := PACK_GAP * side
		for &s in sky {
			clear(&s)
			append(&s, Segment{0, side, 0})
		}
		limit := side * (1 + 1e-6)
		for b, k in boxes {
			best_top, best_x := f32(math.F32_MAX), f32(0)
			best_tile, best_turn := -1, false
			for turn in ([2]bool{false, true}) {
				if turn && !may_turn do break
				w, h := b.size.x + gap, b.size.y + gap
				if turn do w, h = h, w
				if w > limit || h > limit do continue
				for s, tile in sky do for i in 0 ..< len(s) {
					// Each segment's left end and, against its right end, the box's right.
					for x in ([2]f32{s[i].x, s[i].x + s[i].w - w}) {
						if x < 0 || x + w > limit do continue
						y: f32 = 0
						for g in s do if g.x < x + w && g.x + g.w > x do y = max(y, g.y)
						top := y + h
						if top < best_top || (top == best_top && (tile < best_tile || (tile == best_tile && x < best_x))) {
							best_top, best_x, best_tile, best_turn = top, x, tile, turn
						}
					}
				}
			}
			if best_tile < 0 || best_top > limit do return false
			w, h := b.size.x + gap, b.size.y + gap
			if best_turn do w, h = h, w
			at[k] = {f32(best_tile) * side + best_x + gap * 0.5, best_top - h + gap * 0.5}
			turned[k] = best_turn
			raise(&sky[best_tile], best_x, w, best_top)
		}
		return true
	}
	// The side: from the least it could be (the boxes' area spread over the tiles, or the
	// biggest box) up to one that holds them all, then halved down to it.
	small := max(f32(math.sqrt(area / f64(tiles))), biggest)
	large := small
	for !fits(boxes[:], large, sky, at, turned, may_turn) do large *= 1.25
	for _ in 0 ..< 18 {
		mid := (small + large) * 0.5
		if fits(boxes[:], mid, sky, at, turned, may_turn) do large = mid
		else do small = mid
	}
	_ = fits(boxes[:], large, sky, at, turned, may_turn)
	scale := 1 / large
	// Each island into its box's place, a turned one a quarter turn about its box first.
	Move :: struct {
		lo, size, at: [2]f32,
		turned:       bool,
	}
	moves := make([]Move, u.islands, context.temp_allocator)
	filled: f64 = 0
	for b, k in boxes {
		moves[b.island] = {b.lo, b.size, at[k], turned[k]}
		filled += f64(b.size.x) * f64(b.size.y)
	}
	for &c, t in u.corner do if i := u.island[t]; place[i] {
		mv := moves[i]
		for &p in c {
			q := p - mv.lo
			if mv.turned do q = {mv.size.y - q.y, q.x}
			p = (q + mv.at) * scale
		}
	}
	return f32(filled / (f64(large) * f64(large) * f64(tiles)))
}

// The skyline `s` with [x, x + w) raised to `top`: the segments under it cut away and
// neighbours of the same height joined.
@(private = "file")
raise :: proc(s: ^[dynamic]Segment, x, w, top: f32) {
	out := make([dynamic]Segment, 0, len(s) + 2, context.temp_allocator)
	end := x + w
	inserted := false
	for g in s {
		g_end := g.x + g.w
		if g_end <= x || g.x >= end {
			if !inserted && g.x >= end {
				append(&out, Segment{x, w, top})
				inserted = true
			}
			append(&out, g)
			continue
		}
		if g.x < x do append(&out, Segment{g.x, x - g.x, g.y})
		if !inserted {
			append(&out, Segment{x, w, top})
			inserted = true
		}
		if g_end > end do append(&out, Segment{end, g_end - end, g.y})
	}
	if !inserted do append(&out, Segment{x, w, top})
	clear(s)
	for g in out {
		if n := len(s); n > 0 && s[n - 1].y == g.y do s[n - 1].w = g.x + g.w - s[n - 1].x
		else do append(s, g)
	}
}
