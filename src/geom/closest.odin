package geom

import "core:math/linalg"

// The point of triangle abc nearest to p, with its barycentric weights over a, b and c
// (they sum to 1). Ericson, Real-Time Collision Detection, 5.1.5, with the corner and
// edge regions tried first; a triangle with no area (its corners on one line, or two of
// them one point) falls through to the nearest of its edges, since the edge and
// interior formulas would divide by zero.
closest_on_triangle :: proc(p, a, b, c: Vec3) -> (q: Vec3, bary: [3]f32) {
	ab, ac, ap := b - a, c - a, p - a
	d1, d2 := linalg.dot(ab, ap), linalg.dot(ac, ap)
	if d1 <= 0 && d2 <= 0 do return a, {1, 0, 0}
	bp := p - b
	d3, d4 := linalg.dot(ab, bp), linalg.dot(ac, bp)
	if d3 >= 0 && d4 <= d3 do return b, {0, 1, 0}
	vc := d1 * d4 - d3 * d2
	if vc <= 0 && d1 >= 0 && d3 <= 0 && d1 - d3 > 0 {
		v := d1 / (d1 - d3)
		return a + ab * v, {1 - v, v, 0}
	}
	cp := p - c
	d5, d6 := linalg.dot(ab, cp), linalg.dot(ac, cp)
	if d6 >= 0 && d5 <= d6 do return c, {0, 0, 1}
	vb := d5 * d2 - d1 * d6
	if vb <= 0 && d2 >= 0 && d6 <= 0 && d2 - d6 > 0 {
		w := d2 / (d2 - d6)
		return a + ac * w, {1 - w, 0, w}
	}
	va := d3 * d6 - d5 * d4
	if va <= 0 && d4 - d3 >= 0 && d5 - d6 >= 0 && (d4 - d3) + (d5 - d6) > 0 {
		w := (d4 - d3) / ((d4 - d3) + (d5 - d6))
		return b + (c - b) * w, {0, 1 - w, w}
	}
	if sum := va + vb + vc; sum > 0 {
		v, w := vb / sum, vc / sum
		return a + ab * v + ac * w, {1 - v - w, v, w}
	}
	// No area: the nearest point of the three edges.
	q, bary = closest_on_segment(p, a, b, 0, 1)
	for e in ([2][2]int{{1, 2}, {2, 0}}) {
		corners := [3]Vec3{a, b, c}
		eq, eb := closest_on_segment(p, corners[e[0]], corners[e[1]], e[0], e[1])
		if linalg.length2(eq - p) < linalg.length2(q - p) do q, bary = eq, eb
	}
	return
}

// The point of segment from-to nearest to p, with its weights put at corners i and j.
@(private = "file")
closest_on_segment :: proc(p, from, to: Vec3, i, j: int) -> (q: Vec3, bary: [3]f32) {
	d := to - from
	t := clamp(linalg.dot(p - from, d) / linalg.dot(d, d), 0, 1) if linalg.dot(d, d) > 0 else 0
	bary[i], bary[j] = 1 - t, t
	return from + d * t, bary
}

// The deepest a tree from bvh_build_morton gets: each split takes one of the 30 bits of
// the Morton codes or halves a run of equal codes (at most 32 halvings of a u32 count),
// and the traversal below keeps at most one node a level waiting.
@(private = "file")
CLOSEST_STACK :: 64

// The point of the mesh's surface nearest to p within `max_dist`: its triangle, the
// barycentric weights over that triangle's corners (in index order), and the distance.
// ok is false when no triangle is that near. Branch and bound, the nearer child first,
// with a stack of its own: threads can query one tree at once, and nothing is allocated.
// For a tree from bvh_build_morton (see CLOSEST_STACK). Of triangles equally near, the
// first met wins, so a query answers the same for the same hint.
//
// `hint`, a triangle likely to be near (the answer for a point close by), starts the
// search at its leaf, which then climbs to the root searching each sibling it passes:
// every part of the tree is still looked at, so the answer is exact, but what the hint
// found bounds it from the start, the nodes on the way are the ones the last query
// read, and the far siblings are passed with one box each.
bvh_closest :: proc(b: Bvh, m: Mesh, p: Vec3, max_dist: f32, hint := BVH_NONE) -> (tri: u32, bary: [3]f32, dist: f32, ok: bool) {
	if len(b.nodes) == 0 || b.nodes[0].bounds.lo.x > b.nodes[0].bounds.hi.x do return
	c := Closest{b = b, m = m, p = p, best = max_dist * max_dist}
	if hint == BVH_NONE || b.tri_leaf == nil {
		closest_descend(&c, 0)
	} else {
		at := b.tri_leaf[hint]
		closest_descend(&c, at)
		for parent := b.nodes[at].parent; parent != BVH_NONE; at, parent = parent, b.nodes[parent].parent {
			first := b.nodes[parent].first
			closest_descend(&c, first + 1 if at == first else first)
		}
	}
	if c.ok do dist = linalg.sqrt(c.best)
	return c.tri, c.bary, dist, c.ok
}

@(private = "file")
Closest :: struct {
	b:    Bvh,
	m:    Mesh,
	p:    Vec3,
	best: f32, // squared
	tri:  u32,
	bary: [3]f32,
	ok:   bool,
}

// Searches the subtree at `root` for anything nearer than the best so far.
@(private = "file")
closest_descend :: proc(c: ^Closest, root: u32) {
	b, m, p := c.b, c.m, c.p
	runs := b.tri_order == nil
	stack: [CLOSEST_STACK]u32
	stack[0] = root
	top := 1
	for top > 0 {
		top -= 1
		node := b.nodes[stack[top]]
		if box_distance2(node.bounds, p) > c.best do continue
		if node.count > 0 {
			for i in node.first ..< node.first + node.count {
				id := i if runs else b.tri_order[i]
				q, w := closest_on_triangle(p, m.positions[m.indices[3 * id]], m.positions[m.indices[3 * id + 1]], m.positions[m.indices[3 * id + 2]])
				if d := linalg.length2(q - p); d < c.best || (d == c.best && !c.ok) {
					c.best, c.tri, c.bary, c.ok = d, id, w, true
				}
			}
			continue
		}
		l, r := node.first, node.first + 1
		dl, dr := box_distance2(b.nodes[l].bounds, p), box_distance2(b.nodes[r].bounds, p)
		assert(top + 2 <= CLOSEST_STACK, "bvh_closest: the tree is deeper than a Morton build makes")
		// The far child first, so the near one is popped next and tightens the bound.
		if dl <= dr {
			stack[top], stack[top + 1] = r, l
		} else {
			stack[top], stack[top + 1] = l, r
		}
		top += 2
	}
}

// Without branches: which side of a box a point is on is a coin toss for the
// predictor, and a query tests dozens of boxes.
@(private = "file")
box_distance2 :: #force_inline proc(b: Aabb, p: Vec3) -> f32 {
	dx := max(b.lo.x - p.x, p.x - b.hi.x, 0)
	dy := max(b.lo.y - p.y, p.y - b.hi.y, 0)
	dz := max(b.lo.z - p.z, p.z - b.hi.z, 0)
	return dx * dx + dy * dy + dz * dz
}
