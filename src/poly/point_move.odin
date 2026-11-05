package poly

import "core:math/linalg"

// Moving, turning or scaling some points of the cage freely, as Blender's edit mode moves
// its selection with G, R and S and the gizmo: the points carried, their mirror images
// under symmetry (each mapped through the mirror, so the two sides move as mirror images),
// and with a falloff the points round them, each by a share that eases from all of it next
// to the carried points to none at the falloff's reach (Blender's proportional editing,
// smooth falloff; ZBrush's gizmo on a soft mask). A point on a mirror plane stays on it
// (Blender's mirror clipping). The plan is made once when a drag begins; each frame maps
// the points from where they began, so nothing drifts.

// What a move takes, made by point_move_plan: per point it moves, its id, the mirror it is
// mapped through (signs of the axes, {1, 1, 1} for none), how much of the move it takes
// (1 for a carried point and its images), and the axes whose plane it stays on.
Point_Move :: struct {
	verts:   [dynamic]u32,
	signs:   [dynamic]Vec3,
	weights: [dynamic]f32,
	planes:  [dynamic]Mirror_Axes,
}

point_move_destroy :: proc(p: ^Point_Move) {
	delete(p.verts)
	delete(p.signs)
	delete(p.weights)
	delete(p.planes)
	p^ = {}
}

// The share of a move a point `d` away from the nearest carried point takes, with the
// falloff reaching `reach`: smoothstep from 1 at the carried points to 0 at the reach.
point_move_falloff :: proc(d, reach: f32) -> f32 {
	if reach <= 0 || d >= reach do return 0
	t := 1 - d / reach
	return t * t * (3 - 2 * t)
}

// The plan for moving `carried` (ascending): them, their images across `axes`, and with a
// `reach` above zero the points within it, ordered by id.
point_move_plan :: proc(m: ^Mesh, carried: []u32, axes: Mirror_Axes, reach: f32, allocator := context.allocator) -> (p: Point_Move) {
	p.verts = make([dynamic]u32, allocator)
	p.signs = make([dynamic]Vec3, allocator)
	p.weights = make([dynamic]f32, allocator)
	p.planes = make([dynamic]Mirror_Axes, allocator)
	n := len(m.positions)
	if n == 0 || len(carried) == 0 do return
	slack := mirror_slack(m)
	// Per point: taken, the sign it is mapped through, its weight.
	taken := make([]bool, n, context.temp_allocator)
	sign := make([]Vec3, n, context.temp_allocator)
	weight := make([]f32, n, context.temp_allocator)
	for v in carried {
		if int(v) >= n do continue
		taken[v], sign[v], weight[v] = true, {1, 1, 1}, 1
	}
	if axes != {} {
		g := point_grid_make(m, slack)
		signs := mirror_signs(axes)
		for v in carried {
			if int(v) >= n do continue
			for s in signs[1:] {
				w := nearest_point(m, &g, m.positions[v] * s, slack)
				if w == NONE || taken[w] do continue
				taken[w], sign[w], weight[w] = true, s, 1
			}
		}
	}
	if reach > 0 {
		// Each other point's distance to the nearest moved one, through a grid of the reach,
		// so only the cells round it are looked at.
		moved := make([dynamic]u32, context.temp_allocator)
		for x, v in taken do if x do append(&moved, u32(v))
		g := point_grid_make(m, reach)
		near := make([dynamic]u32, context.temp_allocator)
		best := make([]f32, n, context.temp_allocator)
		from := make([]u32, n, context.temp_allocator)
		for &b in best do b = reach
		for &f in from do f = NONE
		for v in moved {
			point_grid_near(&g, m.positions[v], &near)
			for u in near {
				if taken[u] do continue
				d := linalg.length(m.positions[u] - m.positions[v])
				if d < best[u] || (d == best[u] && from[u] != NONE && v < from[u]) do best[u], from[u] = d, v
			}
		}
		for u in 0 ..< n {
			if from[u] == NONE do continue
			w := point_move_falloff(best[u], reach)
			if w <= 0 do continue
			taken[u], sign[u], weight[u] = true, sign[from[u]], w
		}
	}
	for x, v in taken {
		if !x do continue
		planes: Mirror_Axes
		for a in axes do if abs(m.positions[v][int(a)]) <= slack do planes += {a}
		append(&p.verts, u32(v))
		append(&p.signs, sign[v])
		append(&p.weights, weight[v])
		append(&p.planes, planes)
	}
	return
}

// Sets every planned point to where `start` (every point as the move began) maps under
// p ↦ a·p + b, through its mirror and by its share; a point on a mirror plane keeps that
// coordinate.
point_move_apply :: proc(m: ^Mesh, plan: ^Point_Move, start: []Vec3, a: matrix[3, 3]f32, b: Vec3) {
	for v, i in plan.verts {
		if int(v) >= len(m.positions) || int(v) >= len(start) do continue
		s := plan.signs[i]
		q := start[v]
		to := s * (a * (s * q) + b)
		p := linalg.lerp(q, to, plan.weights[i])
		for axis in plan.planes[i] do p[int(axis)] = q[int(axis)]
		m.positions[v] = p
	}
}
