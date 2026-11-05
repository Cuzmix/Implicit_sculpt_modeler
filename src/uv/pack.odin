package uv

import "core:math"
import "core:slice"

// Shelf placement: the islands asked for, each as it was flattened (one texel density)
// and turned so its box is the smallest it can have and no taller than wide, are laid in rows of falling height and the whole set scaled into the unit
// square, with a gap of PACK_GAP of the square between neighbours and at the edges. The
// row width is tried at several widths about the square root of the boxes' area, and the
// one whose rows make the smallest square is kept, so a set of like islands comes out
// near square. Islands not asked for (pinned, closed, failed) keep their coordinates and
// may overlap the placed ones; the packers of the UV editor place round them.

PACK_GAP :: f32(1) / 256

// Rows tried, from 0.9 to 1.6 times the square root of the boxes' area.
@(private = "file")
PACK_TRIES :: 15

@(private)
shelf_pack :: proc(u: ^Uvs, place: []bool) {
	assert(len(place) == u.islands)
	Box :: struct {
		lo, size: [2]f32,
		island:   u32,
	}
	turn_to_smallest_box(u, place)
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
	widest: f32 = 0
	for i in 0 ..< u.islands do if place[i] && hi[i].x >= lo[i].x {
		size := hi[i] - lo[i]
		append(&boxes, Box{lo[i], size, u32(i)})
		area += f64(size.x) * f64(size.y)
		widest = max(widest, size.x)
	}
	if len(boxes) == 0 do return
	slice.sort_by(boxes[:], proc(a, b: Box) -> bool {
		if a.size.y != b.size.y do return a.size.y > b.size.y
		if a.size.x != b.size.x do return a.size.x > b.size.x
		return a.island < b.island
	})
	// The gap in the islands' own units, so that after scaling it is about PACK_GAP: the
	// side the boxes would fill packed perfectly.
	side := f32(math.sqrt(area))
	if side <= 0 do side = max(widest, 1e-6)
	gap := PACK_GAP * side

	// Each box's corner in the rows for a row width, and the square those rows need.
	rows :: proc(boxes: []Box, width, gap: f32, at: [][2]f32) -> (extent: f32) {
		x, y, row := gap, gap, f32(0)
		used: f32 = 0
		for b, k in boxes {
			if x > gap && x + b.size.x + gap > width {
				x, y = gap, y + row + gap
				row = 0
			}
			at[k] = {x, y}
			x += b.size.x + gap
			used = max(used, x)
			row = max(row, b.size.y)
		}
		return max(used, y + row + gap)
	}
	at := make([][2]f32, len(boxes), context.temp_allocator)
	best_width, best := f32(0), f32(math.F32_MAX)
	for k in 0 ..< PACK_TRIES {
		width := max(side * (0.9 + 0.05 * f32(k)), widest + 2 * gap)
		if e := rows(boxes[:], width, gap, at); e < best do best_width, best = width, e
	}
	rows(boxes[:], best_width, gap, at)
	scale := 1 / best

	// Each placed island moved by its box and scaled with the rest.
	shift := make([][2]f32, u.islands, context.temp_allocator)
	for b, k in boxes do shift[b.island] = at[k] - b.lo
	for &c, t in u.corner do if i := u.island[t]; place[i] {
		for &p in c do p = (p + shift[i]) * scale
	}
}

// Turns each island asked for about its box's corner so that its box is the smallest
// any turn gives (the box lies along an edge of the island's convex hull, as rotating
// calipers find it) and no taller than wide.
@(private = "file")
turn_to_smallest_box :: proc(u: ^Uvs, place: []bool) {
	// The corners grouped by island, in triangle order.
	first := make([]u32, u.islands + 1, context.temp_allocator)
	for i in u.island do if place[i] do first[i + 1] += 3
	for i in 0 ..< u.islands do first[i + 1] += first[i]
	points := make([][2]f32, first[u.islands], context.temp_allocator)
	fill := slice.clone(first[:u.islands], context.temp_allocator)
	for c, t in u.corner do if i := u.island[t]; place[i] {
		for p in c {
			points[fill[i]] = p
			fill[i] += 1
		}
	}
	turn := make([][2]f32, u.islands, context.temp_allocator) // cos, sin
	hull := make([dynamic][2]f32, context.temp_allocator)
	for i in 0 ..< u.islands {
		turn[i] = {1, 0}
		if !place[i] || first[i + 1] == first[i] do continue
		pts := points[first[i]:first[i + 1]]
		// Akl and Toussaint's filter: no point strictly inside the quadrilateral of the
		// four extremes can be on the hull, which leaves few to sort.
		ext := [4][2]f32{pts[0], pts[0], pts[0], pts[0]} // least x, least y, most x, most y
		for p in pts {
			if p.x < ext[0].x do ext[0] = p
			if p.y < ext[1].y do ext[1] = p
			if p.x > ext[2].x do ext[2] = p
			if p.y > ext[3].y do ext[3] = p
		}
		kept := 0
		for p in pts {
			inside := true
			for e in 0 ..< 4 {
				a, b := ext[e], ext[(e + 1) % 4]
				if (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) <= 0 {
					inside = false
					break
				}
			}
			if !inside {
				pts[kept] = p
				kept += 1
			}
		}
		pts = pts[:kept]
		slice.sort_by(pts, proc(a, b: [2]f32) -> bool {return a.x < b.x || (a.x == b.x && a.y < b.y)})
		// Andrew's monotone chain, counter-clockwise.
		cross :: proc(o, a, b: [2]f32) -> f32 {return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)}
		clear(&hull)
		for p in pts {
			for len(hull) >= 2 && cross(hull[len(hull) - 2], hull[len(hull) - 1], p) <= 0 do pop(&hull)
			append(&hull, p)
		}
		lower := len(hull) + 1
		#reverse for p in pts {
			for len(hull) >= lower && cross(hull[len(hull) - 2], hull[len(hull) - 1], p) <= 0 do pop(&hull)
			append(&hull, p)
		}
		if len(hull) > 1 do pop(&hull)
		if len(hull) < 3 do continue
		// Each hull edge's direction as the box's x axis; the smallest area wins, the
		// first on a tie, and among them the turn nearest none keeps like islands alike.
		best := f32(math.F32_MAX)
		best_turn := [2]f32{1, 0}
		best_wide := true
		for k in 0 ..< len(hull) {
			e := hull[(k + 1) % len(hull)] - hull[k]
			l := math.sqrt(e.x * e.x + e.y * e.y)
			if l <= 0 do continue
			d := e / l
			lo, hi := [2]f32{math.F32_MAX, math.F32_MAX}, [2]f32{-math.F32_MAX, -math.F32_MAX}
			for p in hull {
				q := [2]f32{p.x * d.x + p.y * d.y, -p.x * d.y + p.y * d.x}
				lo, hi = {min(lo.x, q.x), min(lo.y, q.y)}, {max(hi.x, q.x), max(hi.y, q.y)}
			}
			size := hi - lo
			if a := size.x * size.y; a < best * (1 - 1e-5) {
				best, best_turn, best_wide = a, d, size.x >= size.y
			}
		}
		// The turn takes direction d to the x axis; a quarter turn more lays it wide.
		c, s := best_turn.x, -best_turn.y
		if !best_wide do c, s = -s, c
		turn[i] = {c, s}
	}
	for &cs, t in u.corner do if i := u.island[t]; place[i] {
		r := turn[i]
		for &p in cs do p = {p.x * r.x - p.y * r.y, p.x * r.y + p.y * r.x}
	}
}
