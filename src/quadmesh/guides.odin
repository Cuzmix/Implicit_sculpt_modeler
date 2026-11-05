package quadmesh

import "base:runtime"
import "core:math"
import "core:slice"

import "../geom"

// The guide curves as a direction per isotropic triangle (the shim's makeGuides and
// faceGuides, ported): each triangle near a guide asks its quads' edges to run along the
// nearest of the guide's segments, in the triangle's plane, with a weight that falls off
// to nothing three quarters of a quad edge from it. The frame field pulls toward the
// direction and the cover's curl correction keeps the triangle's turn by the weight.

// How far from a guide, in quad edges, a triangle still feels it.
@(private = "file")
GUIDE_REACH :: 0.75

// The most pieces one guide segment is cut into.
@(private = "file")
GUIDE_PIECES :: 1 << 16

// A guide's piece, filed under the grid cell its middle lies in.
@(private = "file")
Guide_Piece :: struct {
	key:   u64,
	a, b:  [3]f64,
	index: int, // in the order the pieces were cut, which breaks a tie in distance
}

// Per triangle of `iso`, the direction the nearest guide segment asks (`guides` holds two
// points a segment) times its weight: `strength` 0..1 becomes s / (1 - s + 0.01), about
// 1 at a half (as strong as the curvature's strongest pull) and 100 at full, scaled down
// linearly to nothing at GUIDE_REACH of the triangle's quad edge (`quad_edge` times its
// corners' mean `iso.vertex_scale`) from the segment. Nil when no guide comes near any
// triangle, or there is no guide or no strength. The guides are cut into pieces no longer
// than the farthest reach (four times the plain quad edge's, where the density makes the
// quads larger), so each lies in its middle's cell's neighbourhood, and a triangle looks
// in the 27 cells round its middle; of two pieces as near, the earlier wins, so the
// result is the C++'s bit for bit.
odin_face_guides :: proc(iso: Isotropic, quad_edge: f64, guides: []geom.Vec3, strength: f32, allocator := context.allocator) -> (out: [][3]f64) {
	s := f64(strength) if !math.is_nan(strength) && !math.is_inf(strength) else 0
	s = max(0.0, min(1.0, s))
	cell := 4.0 * GUIDE_REACH * quad_edge
	if len(guides) < 2 || s <= 0 || !(cell > 0) do return nil
	weight := s / (1.0 - s + 0.01)
	heap := runtime.heap_allocator()
	pieces := make([dynamic]Guide_Piece, 0, len(guides), heap)
	defer delete(pieces)
	cell_of :: proc(p: [3]f64, cell: f64) -> [3]i64 {
		return {i64(math.floor(p.x / cell)), i64(math.floor(p.y / cell)), i64(math.floor(p.z / cell))}
	}
	key_of :: proc(c: [3]i64) -> u64 {
		part :: proc(a: i64) -> u64 {return u64(a + (1 << 20)) & 0x1fffff}
		return (part(c.x) << 42) | (part(c.y) << 21) | part(c.z)
	}
	for i := 0; i + 1 < len(guides); i += 2 {
		a := [3]f64{f64(guides[i].x), f64(guides[i].y), f64(guides[i].z)}
		b := [3]f64{f64(guides[i + 1].x), f64(guides[i + 1].y), f64(guides[i + 1].z)}
		sum := a.x + a.y + a.z + b.x + b.y + b.z
		if math.is_nan(sum) || math.is_inf(sum) do continue
		length := length3(b - a)
		if !(length > 1e-12) do continue
		n := min(GUIDE_PIECES, int(math.ceil(length / cell)))
		for k in 0 ..< n {
			p := a + (b - a) * (f64(k) / f64(n))
			q := a + (b - a) * (f64(k + 1) / f64(n))
			append(&pieces, Guide_Piece{key_of(cell_of((p + q) * 0.5, cell)), p, q, len(pieces)})
		}
	}
	// Filed by cell, each cell's pieces in their order.
	slice.sort_by(pieces[:], proc(x, y: Guide_Piece) -> bool {return x.key < y.key || (x.key == y.key && x.index < y.index)})
	out = make([][3]f64, len(iso.triangles), allocator)
	any := false
	scaled := len(iso.vertex_scale) == len(iso.positions)
	for t, f in iso.triangles {
		p0, p1, p2 := iso.positions[t[0]], iso.positions[t[1]], iso.positions[t[2]]
		middle := (p0 + p1 + p2) / 3.0
		scale := (iso.vertex_scale[t[0]] + iso.vertex_scale[t[1]] + iso.vertex_scale[t[2]]) / 3.0 if scaled else 1.0
		within := min(GUIDE_REACH * quad_edge * scale, cell)
		c := cell_of(middle, cell)
		// As the C++ starts it: no piece yet, so one exactly `within` away is taken.
		best, nearest, found := within, max(int), -1
		for dx in i64(-1) ..= 1 do for dy in i64(-1) ..= 1 do for dz in i64(-1) ..= 1 {
			key := key_of(c + {dx, dy, dz})
			// The first piece of the cell, if it has any.
			from, _ := slice.binary_search_by(pieces[:], key, proc(x: Guide_Piece, k: u64) -> slice.Ordering {return slice.cmp(x.key, k)})
			for i := from; i < len(pieces) && pieces[i].key == key; i += 1 {
				a, ab := pieces[i].a, pieces[i].b - pieces[i].a
				along := max(0.0, min(1.0, dot3(middle - a, ab) / dot3(ab, ab)))
				d := length3(a + ab * along - middle)
				if d < best || (d == best && pieces[i].index < nearest) {
					best, nearest, found = d, pieces[i].index, i
				}
			}
		}
		if found < 0 do continue
		normal := unit_or_zero(cross3(p1 - p0, p2 - p0))
		direction := pieces[found].b - pieces[found].a
		direction = direction - normal * dot3(direction, normal)
		if !(length3(direction) > 1e-12) do continue
		out[f] = unit_or_zero(direction) * (weight * (1.0 - best / within))
		any = true
	}
	if !any {
		delete(out, allocator)
		out = nil
	}
	return
}
