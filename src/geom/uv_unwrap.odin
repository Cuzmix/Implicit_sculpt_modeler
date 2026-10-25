package geom

import "core:math"
import "core:math/linalg"
import "core:slice"

// Automatic UVs for a quad mesh, for baking maps onto it: the quads are grouped into
// charts, each flat enough to lay down by projecting it onto the plane facing its first
// quad (every quad of a chart faces within UV_CHART_DEGREES of that, so none folds over
// in the projection), each chart turned to fit its smallest box, and the boxes packed
// in rows into the unit square at one common scale, the largest that fits, so every
// part of the surface gets texels in proportion to its size. A UV is kept per quad
// corner, since a vertex on a chart's edge has one in each chart it touches.

UV_CHART_DEGREES :: 55

Uv_Layout :: struct {
	uvs:    [][4][2]f32, // per quad, per corner
	chart:  []u32,       // per quad
	charts: int,
	filled: f32,         // share of the square the charts' boxes cover
}

uv_layout_destroy :: proc(l: ^Uv_Layout, allocator := context.allocator) {
	delete(l.uvs, allocator)
	delete(l.chart, allocator)
	l^ = {}
}

// Lays out UVs for `q` with `padding` (in UV units) around each chart.
quad_uv_unwrap :: proc(q: Quad_Mesh, padding: f32, allocator := context.allocator) -> (l: Uv_Layout) {
	count := len(q.quads)
	l.uvs = make([][4][2]f32, count, allocator)
	l.chart = make([]u32, count, allocator)
	if count == 0 do return
	normals := make([]Vec3, count, context.temp_allocator)
	for f, i in q.quads {
		normals[i] = linalg.normalize0(linalg.cross(q.positions[f[2]] - q.positions[f[0]], q.positions[f[3]] - q.positions[f[1]]))
	}
	// Quads across each edge.
	Side :: struct {
		key:  u64,
		quad: u32,
	}
	sides := make([]Side, 4 * count, context.temp_allocator)
	for f, i in q.quads do for k in 0 ..< 4 do sides[4 * i + k] = {retopo_edge_key(f[k], f[(k + 1) % 4]), u32(i)}
	slice.sort_by(sides, proc(a, b: Side) -> bool {return a.key < b.key || (a.key == b.key && a.quad < b.quad)})
	across := make([][4]u32, count, context.temp_allocator)
	for &a in across do a = {max(u32), max(u32), max(u32), max(u32)}
	for i := 0; i + 1 < len(sides); i += 1 {
		if sides[i].key != sides[i + 1].key || (i + 2 < len(sides) && sides[i + 2].key == sides[i].key) do continue
		a, b := sides[i].quad, sides[i + 1].quad
		for k in 0 ..< 4 {
			f := q.quads[a]
			if retopo_edge_key(f[k], f[(k + 1) % 4]) == sides[i].key do across[a][k] = b
			g := q.quads[b]
			if retopo_edge_key(g[k], g[(k + 1) % 4]) == sides[i].key do across[b][k] = a
		}
	}

	// Charts, grown breadth first from the first quad not yet in one, over edges to
	// quads that face close enough to the seed.
	limit := math.cos(f32(UV_CHART_DEGREES) * math.RAD_PER_DEG)
	NONE :: max(u32)
	for &c in l.chart do c = NONE
	Chart :: struct {
		axis, u, v: Vec3,
		first, end: int, // in `order`
		lo, hi:     [2]f32,
		turn:       f32,
		place:      [2]f32,
	}
	charts := make([dynamic]Chart, 0, 64, context.temp_allocator)
	order := make([dynamic]u32, 0, count, context.temp_allocator)
	for seed in 0 ..< count {
		if l.chart[seed] != NONE do continue
		id := u32(len(charts))
		axis := normals[seed]
		c := Chart{axis = axis, first = len(order)}
		l.chart[seed] = id
		append(&order, u32(seed))
		for at := c.first; at < len(order); at += 1 {
			for other in across[order[at]] {
				if other == NONE || l.chart[other] != NONE || linalg.dot(normals[other], axis) < limit do continue
				l.chart[other] = id
				append(&order, other)
			}
		}
		c.end = len(order)
		// A frame in the plane facing the seed.
		helper := Vec3{1, 0, 0} if abs(axis.x) < 0.9 else Vec3{0, 1, 0}
		c.u = linalg.normalize(linalg.cross(helper, axis))
		c.v = linalg.cross(axis, c.u)
		append(&charts, c)
	}
	l.charts = len(charts)

	flat :: proc(c: Chart, p: Vec3) -> [2]f32 {return {linalg.dot(p, c.u), linalg.dot(p, c.v)}}
	turned :: proc(p: [2]f32, angle: f32) -> [2]f32 {
		s, co := math.sin(angle), math.cos(angle)
		return {co * p.x - s * p.y, s * p.x + co * p.y}
	}
	// Each chart turned to its smallest box, trying every 3 degrees of a quarter turn.
	area := f32(0)
	for &c in charts {
		best := max(f32)
		for step in 0 ..< 30 {
			angle := f32(step) * 3 * math.RAD_PER_DEG
			lo, hi := [2]f32{max(f32), max(f32)}, [2]f32{-max(f32), -max(f32)}
			for i in order[c.first:c.end] {
				for v in q.quads[i] {
					p := turned(flat(c, q.positions[v]), angle)
					lo, hi = linalg.min(lo, p), linalg.max(hi, p)
				}
			}
			if a := (hi.x - lo.x) * (hi.y - lo.y); a < best {
				best, c.turn, c.lo, c.hi = a, angle, lo, hi
			}
		}
		area += best
	}

	// Rows of boxes, tallest first, at the largest scale that fits the unit square.
	by_height := make([]int, len(charts), context.temp_allocator)
	for &b, i in by_height do b = i
	// sort_by takes no closure: the comparison finds the charts through the context.
	context.user_ptr = &charts
	slice.sort_by(by_height, proc(a, b: int) -> bool {
		charts := (cast(^[dynamic]Chart)context.user_ptr)^
		ha, hb := charts[a].hi.y - charts[a].lo.y, charts[b].hi.y - charts[b].lo.y
		return ha > hb || (ha == hb && a < b)
	})
	fits :: proc(charts: []Chart, by_height: []int, scale, padding: f32, place: bool) -> bool {
		x, y, row := padding, padding, f32(0)
		for i in by_height {
			c := &charts[i]
			w, h := (c.hi.x - c.lo.x) * scale, (c.hi.y - c.lo.y) * scale
			if x + w + padding > 1 {
				x, y, row = padding, y + row + padding, 0
			}
			if x + w + padding > 1 || y + h + padding > 1 do return false
			if place do c.place = {x, y}
			x += w + padding
			row = max(row, h)
		}
		return true
	}
	lo_s, hi_s := f32(0), 1 / math.sqrt(max(area, 1e-20))
	for !fits(charts[:], by_height, hi_s, padding, false) && hi_s > 1e-20 do hi_s *= 0.5
	if fits(charts[:], by_height, hi_s, padding, false) {
		lo_s, hi_s = hi_s, 2 * hi_s
		for _ in 0 ..< 30 {
			mid := 0.5 * (lo_s + hi_s)
			if fits(charts[:], by_height, mid, padding, false) do lo_s = mid
			else do hi_s = mid
		}
	}
	scale := lo_s
	_ = fits(charts[:], by_height, scale, padding, true)
	for c in charts do l.filled += (c.hi.x - c.lo.x) * (c.hi.y - c.lo.y) * scale * scale
	for i in 0 ..< count {
		c := charts[l.chart[i]]
		for v, k in q.quads[i] {
			p := turned(flat(c, q.positions[v]), c.turn)
			l.uvs[i][k] = c.place + (p - c.lo) * scale
		}
	}
	return
}
