package poly

import "core:math"
import "core:math/linalg"

// Shaping a loop, as Blender's To Circle (LoopTools) and Space evenly and ZModeler's
// Align do: the points along an edge loop move, the topology stays. Each takes the loop's
// edges in order along it (edge_loop, border_loop) and returns the points it moved.

Loop_Shape :: enum u8 {
	Circle, // round it into a circle in its own plane
	Space, // spread its points evenly along it, keeping its path
	Flatten, // move its points onto its plane
}

// The points of a loop of edges in order along it, and whether it closes. Edges that do
// not run on from each other give no points.
loop_points :: proc(m: ^Mesh, edges: []u32, allocator := context.allocator) -> (points: []u32, closed: bool) {
	if len(edges) == 0 do return nil, false
	out := make([dynamic]u32, 0, len(edges) + 1, allocator)
	a, b := edge_verts(m, edges[0])
	if len(edges) > 1 {
		c, d := edge_verts(m, edges[1])
		// Start from the end of the first edge that the second does not touch.
		if a == c || a == d do a, b = b, a
	}
	append(&out, a, b)
	for e in edges[1:] {
		c, d := edge_verts(m, e)
		last := out[len(out) - 1]
		switch last {
		case c: append(&out, d)
		case d: append(&out, c)
		case:
			delete(out)
			return nil, false
		}
	}
	if len(out) > 2 && out[len(out) - 1] == out[0] {
		pop(&out)
		return out[:], true
	}
	return out[:], false
}

// The plane a loop of points lies nearest: through their middle, across Newell's normal
// of the polygon they make (the loop's own turning direction).
@(private = "file")
loop_plane :: proc(m: ^Mesh, points: []u32) -> (center, normal: Vec3) {
	for v in points do center += m.positions[v]
	center /= f32(len(points))
	for v, i in points {
		p, q := m.positions[v], m.positions[points[(i + 1) % len(points)]]
		normal += {(p.y - q.y) * (p.z + q.z), (p.z - q.z) * (p.x + q.x), (p.x - q.x) * (p.y + q.y)}
	}
	normal = linalg.normalize0(normal)
	if normal == {} {
		// A loop with no area (a straight line): any plane through it.
		d := m.positions[points[len(points) - 1]] - m.positions[points[0]]
		normal = linalg.normalize0(linalg.cross(d, Vec3{0, 0, 1} if abs(d.z) < 0.9 * linalg.length(d) else Vec3{1, 0, 0}))
	}
	return
}

// Shapes the loop of `points` (in order; `closed` when it runs back to its start). Circle
// needs a closed loop of three points or more; `inside` makes its radius the nearest
// point's distance from the middle instead of the mean, so it fits within the loop. An
// open loop keeps its two ends. Returns false, changing nothing, when the loop cannot take
// the shape.
shape_loop :: proc(m: ^Mesh, points: []u32, closed: bool, shape: Loop_Shape, inside := false) -> bool {
	n := len(points)
	if n < 3 || (shape == .Circle && !closed) do return false
	switch shape {
	case .Flatten:
		c, nrm := loop_plane(m, points)
		for v in points {
			p := m.positions[v]
			m.positions[v] = p - nrm * linalg.dot(p - c, nrm)
		}
	case .Circle:
		c, nrm := loop_plane(m, points)
		radius: f32 = max(f32) if inside else 0
		for v in points {
			d := linalg.length(m.positions[v] - c)
			radius = min(radius, d) if inside else radius + d / f32(n)
		}
		// The circle starts at the first point's way from the middle and turns as the loop
		// does, so each point moves the least it can.
		first := m.positions[points[0]] - c
		u := linalg.normalize0(first - nrm * linalg.dot(first, nrm))
		if u == {} do return false
		w := linalg.cross(nrm, u)
		for v, i in points {
			angle := 2 * math.PI * f32(i) / f32(n)
			m.positions[v] = c + (u * math.cos(angle) + w * math.sin(angle)) * radius
		}
	case .Space:
		// Lengths along the path as it is, then each point at its even share of the whole,
		// on the path between the old points.
		count := n if closed else n - 1
		old := make([]Vec3, n, context.temp_allocator)
		along := make([]f32, count + 1, context.temp_allocator)
		for v, i in points do old[i] = m.positions[v]
		for i in 0 ..< count do along[i + 1] = along[i] + linalg.length(old[(i + 1) % n] - old[i])
		total := along[count]
		if total <= 0 do return false
		seg := 0
		last := n if closed else n - 1
		for i in 1 ..< last {
			want := total * f32(i) / f32(count)
			for seg < count - 1 && along[seg + 1] < want do seg += 1
			span := along[seg + 1] - along[seg]
			t := (want - along[seg]) / span if span > 0 else 0
			m.positions[points[i]] = linalg.lerp(old[seg], old[(seg + 1) % n], t)
		}
	}
	return true
}
