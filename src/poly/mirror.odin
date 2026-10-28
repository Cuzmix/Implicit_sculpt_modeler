package poly

import "core:math"
import "core:math/linalg"
import "core:slice"

// Mirror images of elements, for Model mode's symmetry (ZModeler's and Blender's mirror
// editing): an action on some faces, edges or points also acts on their images across the
// planes of `axes` through the cage's origin. Images are found by position: a point's
// image is the point nearest its mirrored position, within `slack`, so a cage built
// symmetric (primitives, and everything symmetric actions make of them) finds every
// image, and a cage that is not finds those that are there.

Mirror_Axes :: bit_set[Mirror_Axis; u8]
Mirror_Axis :: enum u8 {
	X,
	Y,
	Z,
}

// The sign changes of every image `axes` give, the element itself first ({1,1,1}).
mirror_signs :: proc(axes: Mirror_Axes) -> (signs: [dynamic; 8]Vec3) {
	append(&signs, Vec3{1, 1, 1})
	for axis in Mirror_Axis {
		if axis not_in axes do continue
		n := len(signs)
		for i in 0 ..< n {
			s := signs[i]
			s[int(axis)] = -s[int(axis)]
			append(&signs, s)
		}
	}
	return
}

// The cage's points bucketed on a grid of `cell` spacing, sorted by cell, so the points
// near a place are found by looking in the 27 cells round it.
Point_Grid :: struct {
	cell:   f32,
	sorted: []Grid_Point,
	runs:   map[[3]i32]int, // each cell's first place in sorted
}

Grid_Point :: struct {
	cell: [3]i32,
	v:    u32,
}

grid_cell :: proc(p: Vec3, cell: f32) -> [3]i32 {
	return {i32(math.floor(p.x / cell)), i32(math.floor(p.y / cell)), i32(math.floor(p.z / cell))}
}

// A grid of the cage's points; everything in temp memory.
point_grid_make :: proc(m: ^Mesh, cell: f32) -> (g: Point_Grid) {
	g.cell = cell
	g.sorted = make([]Grid_Point, len(m.positions), context.temp_allocator)
	for p, v in m.positions do g.sorted[v] = {grid_cell(p, cell), u32(v)}
	slice.sort_by(g.sorted, proc(a, b: Grid_Point) -> bool {
		if a.cell.x != b.cell.x do return a.cell.x < b.cell.x
		if a.cell.y != b.cell.y do return a.cell.y < b.cell.y
		if a.cell.z != b.cell.z do return a.cell.z < b.cell.z
		return a.v < b.v
	})
	g.runs = make(map[[3]i32]int, allocator = context.temp_allocator)
	for i := len(g.sorted) - 1; i >= 0; i -= 1 do g.runs[g.sorted[i].cell] = i
	return
}

// Every point within one cell of p's cell, into `out` (cleared first), in a fixed order.
point_grid_near :: proc(g: ^Point_Grid, p: Vec3, out: ^[dynamic]u32) {
	clear(out)
	c := grid_cell(p, g.cell)
	for dx in i32(-1) ..= 1 do for dy in i32(-1) ..= 1 do for dz in i32(-1) ..= 1 {
		k := c + {dx, dy, dz}
		at, ok := g.runs[k]
		if !ok do continue
		for i := at; i < len(g.sorted) && g.sorted[i].cell == k; i += 1 do append(out, g.sorted[i].v)
	}
}

// The point nearest p within `slack` (no more than the grid's cell), or NONE; the lower
// id of two as near.
nearest_point :: proc(m: ^Mesh, g: ^Point_Grid, p: Vec3, slack: f32) -> u32 {
	near := make([dynamic]u32, context.temp_allocator)
	point_grid_near(g, p, &near)
	best, best_d := NONE, slack * slack
	for v in near {
		d := linalg.length2(m.positions[v] - p)
		if d < best_d || (d == best_d && v < best) do best, best_d = v, d
	}
	return best
}

// The slack images are matched within: a thousandth of the cage's size.
mirror_slack :: proc(m: ^Mesh) -> f32 {
	b := mesh_bounds(m)
	return max(linalg.length(b.hi - b.lo) * 1e-3, 1e-6)
}

// `points` and their images, without repeats, ascending.
mirror_points :: proc(m: ^Mesh, points: []u32, axes: Mirror_Axes, allocator := context.allocator) -> []u32 {
	slack := mirror_slack(m)
	g := point_grid_make(m, slack)
	out := make([dynamic]u32, 0, len(points) * 2, allocator)
	seen := make([]bool, len(m.positions), context.temp_allocator)
	signs := mirror_signs(axes)
	for v in points {
		for s in signs {
			w := nearest_point(m, &g, m.positions[v] * s, slack)
			if w == NONE || seen[w] do continue
			seen[w] = true
			append(&out, w)
		}
	}
	slice.sort(out[:])
	return out[:]
}

// `edges` and their images (the edges between the images of their ends), without repeats,
// in the order found: each edge, then its images.
mirror_edges :: proc(m: ^Mesh, edges: []u32, axes: Mirror_Axes, allocator := context.allocator) -> []u32 {
	slack := mirror_slack(m)
	g := point_grid_make(m, slack)
	out := make([dynamic]u32, 0, len(edges) * 2, allocator)
	seen := make([]bool, len(m.crease), context.temp_allocator)
	signs := mirror_signs(axes)
	for e in edges {
		a, b := edge_verts(m, e)
		for s in signs {
			ia := nearest_point(m, &g, m.positions[a] * s, slack)
			ib := nearest_point(m, &g, m.positions[b] * s, slack)
			if ia == NONE || ib == NONE do continue
			h := find_half_edge(m, ia, ib)
			if h == NONE do continue
			if x := edge_of(h); !seen[x] {
				seen[x] = true
				append(&out, x)
			}
		}
	}
	return out[:]
}

// `faces` and their images (the faces whose corners are the images of theirs), without
// repeats, ascending.
mirror_faces :: proc(m: ^Mesh, faces: []u32, axes: Mirror_Axes, allocator := context.allocator) -> []u32 {
	slack := mirror_slack(m)
	g := point_grid_make(m, slack)
	out := make([dynamic]u32, 0, len(faces) * 2, allocator)
	seen := make([]bool, len(m.face_he), context.temp_allocator)
	signs := mirror_signs(axes)
	for f in faces {
		a := m.he_vert[m.face_he[f]]
		b := he_tip(m, m.face_he[f])
		for s in signs {
			ia := nearest_point(m, &g, m.positions[a] * s, slack)
			ib := nearest_point(m, &g, m.positions[b] * s, slack)
			if ia == NONE || ib == NONE do continue
			// An odd number of mirrors turns the face's winding over: its image then runs
			// from b's image to a's.
			flips := 0
			for k in 0 ..< 3 do if s[k] < 0 do flips += 1
			h := find_half_edge(m, ib, ia) if flips % 2 == 1 else find_half_edge(m, ia, ib)
			if h == NONE || m.he_face[h] == NONE do continue
			if img := m.he_face[h]; !seen[img] {
				seen[img] = true
				append(&out, img)
			}
		}
	}
	slice.sort(out[:])
	return out[:]
}

// Point v's image under each of `axes`' sign changes, in mirror_signs' order (v itself
// first), NONE where the cage has no point there.
mirror_point_each :: proc(m: ^Mesh, v: u32, axes: Mirror_Axes) -> (out: [dynamic; 8]u32) {
	slack := mirror_slack(m)
	g := point_grid_make(m, slack)
	for s in mirror_signs(axes) do append(&out, nearest_point(m, &g, m.positions[v] * s, slack))
	return
}

// The edge through point p running along `way` (either sense), p lying inside it, not at
// an end: where a mirrored loop goes in. Returns the edge and the share of it p lies at
// from its first end; not found when p lies on a point (a loop is already there) or on no
// such edge. The nearest wins, then the lower id.
edge_through :: proc(m: ^Mesh, p, way: Vec3, slack: f32) -> (edge: u32, share: f32, found: bool) {
	best := slack
	w := linalg.normalize0(way)
	for e in 0 ..< u32(len(m.crease)) {
		a, b := edge_verts(m, e)
		pa, pb := m.positions[a], m.positions[b]
		ab := pb - pa
		length := linalg.length(ab)
		if length <= slack || abs(linalg.dot(ab / length, w)) < 0.999 do continue
		t := linalg.dot(p - pa, ab) / (length * length)
		if t * length <= slack || (1 - t) * length <= slack do continue
		if d := linalg.length(p - (pa + ab * t)); d < best {
			best, edge, share, found = d, e, t, true
		}
	}
	return
}
