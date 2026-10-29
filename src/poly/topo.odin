package poly

// The Topo pen's changes to a cage (retopology by hand, as Maya's Quad Draw and Modo's
// Topology Pen): a polygon added between points of the cage and new points, a cage of a
// single polygon to start from, and relaxing points toward their neighbours. Placing the
// points on the sculpt is the app's: these work on the cage alone.

// A corner of a polygon the Topo pen adds: a point of the cage, or (point NONE) a new
// point at `at`.
Topo_Corner :: struct {
	point: u32,
	at:    Vec3,
}

// Adds one polygon with `corners` in order (counter-clockwise seen from outside), new
// points appended in the order they come. Refused, with the cage as it was, when the
// polygon would break it: a corner twice, an edge that already has two faces, or faces
// either side of an edge running it the same way.
add_polygon :: proc(m: ^Mesh, corners: []Topo_Corner, group: u16, allocator := context.allocator) -> (r: Edit_Result, err: Build_Error) {
	if len(corners) < 3 do return {}, .Degenerate_Face
	ed := edit_begin(m, context.temp_allocator)
	verts := make([dynamic]u32, 0, len(corners), context.temp_allocator)
	for c in corners {
		v := c.point
		if v == NONE do v = edit_vertex(&ed, c.at)
		else if int(v) >= len(m.positions) do return {}, .Degenerate_Face
		append(&verts, v)
	}
	edit_face(&ed, verts[:], group)
	return edit_end(m, &ed, allocator)
}

// Adds polygons on new points: `points` appended in order, then face k with sizes[k]
// corners taken in order from `corners` (indices into `points`). A strip, a filled
// outline or a patch of the Topo pen. Refused, with the cage as it was, when they would
// not make a sound cage.
add_polygons :: proc(m: ^Mesh, points: []Vec3, sizes: []int, corners: []u32, group: u16, allocator := context.allocator) -> (r: Edit_Result, err: Build_Error) {
	ed := edit_begin(m, context.temp_allocator)
	first := u32(len(ed.positions))
	for p in points do edit_vertex(&ed, p)
	at := 0
	for size in sizes {
		if size < 3 || at + size > len(corners) do return {}, .Degenerate_Face
		verts := make([]u32, size, context.temp_allocator)
		for c, i in corners[at:at + size] {
			if int(c) >= len(points) do return {}, .Degenerate_Face
			verts[i] = first + c
		}
		edit_face(&ed, verts, group)
		at += size
	}
	return edit_end(m, &ed, allocator)
}

// The quads of a grid of (across + 1) × (down + 1) points, row by row: each cell's
// corners counter-clockwise when the rows run across and the columns down a page seen
// from above, as sizes and corners for add_polygons or mesh_from_polygons.
grid_quads :: proc(across, down: int, allocator := context.allocator) -> (sizes: []int, corners: []u32) {
	sizes = make([]int, across * down, allocator)
	corners = make([]u32, 4 * across * down, allocator)
	k := 0
	for j in 0 ..< down {
		for i in 0 ..< across {
			a := u32(j * (across + 1) + i)
			b := a + u32(across + 1)
			sizes[k] = 4
			corners[4 * k], corners[4 * k + 1], corners[4 * k + 2], corners[4 * k + 3] = a, a + 1, b + 1, b
			k += 1
		}
	}
	return
}

// The points of a Coons patch filling a closed outline of 2 × (across + down) points
// (each once, in order, from a corner): the outline's sides run across, down, across and
// down points, and the inside points blend them, so a drawn shape fills with a grid of
// quads (as Blender's Grid Fill and 3D-Coat's outline fill do). Row by row, as grid_quads
// numbers them. Works on any vector type, so the app fills a shape on screen.
coons_fill :: proc(outline: [][2]f32, across, down: int, allocator := context.allocator) -> [][2]f32 {
	n, m := across, down
	count := len(outline)
	at :: proc(o: [][2]f32, i: int) -> [2]f32 {return o[(i % len(o) + len(o)) % len(o)]}
	bottom :: proc(o: [][2]f32, n, m, i: int) -> [2]f32 {return at(o, i)}
	right :: proc(o: [][2]f32, n, m, j: int) -> [2]f32 {return at(o, n + j)}
	top :: proc(o: [][2]f32, n, m, i: int) -> [2]f32 {return at(o, 2 * n + m - i)}
	left :: proc(o: [][2]f32, n, m, j: int) -> [2]f32 {return at(o, 2 * n + 2 * m - j)}
	out := make([][2]f32, (n + 1) * (m + 1), allocator)
	if count != 2 * (n + m) do return out
	c00, c10, c11, c01 := at(outline, 0), at(outline, n), at(outline, n + m), at(outline, 2 * n + m)
	for j in 0 ..= m {
		v := f32(j) / f32(m)
		for i in 0 ..= n {
			u := f32(i) / f32(n)
			p := (1 - v) * bottom(outline, n, m, i) + v * top(outline, n, m, i) + (1 - u) * left(outline, n, m, j) + u * right(outline, n, m, j)
			p -= (1 - u) * (1 - v) * c00 + u * (1 - v) * c10 + u * v * c11 + (1 - u) * v * c01
			out[j * (n + 1) + i] = p
		}
	}
	return out
}

// A cage of one polygon through `points` in order: where the Topo pen starts a cage.
polygon_mesh :: proc(points: []Vec3, group: u16, allocator := context.allocator) -> (m: Mesh, err: Build_Error) {
	corners := make([]u32, len(points), context.temp_allocator)
	for &c, i in corners do c = u32(i)
	return mesh_from_polygons(points, {len(points)}, corners, {group}, allocator)
}

// Where each of `points` goes when relaxed once, as Quad Draw's Relax does: an inner point
// to the middle of the points it shares an edge with, a border point to the middle of the
// two border points beside it, so a border stays a border and slides along itself.
// Positions are taken before any point moves, so the result does not depend on the
// points' order.
relax_points :: proc(m: ^Mesh, points: []u32, allocator := context.allocator) -> []Vec3 {
	out := make([]Vec3, len(points), allocator)
	for v, i in points {
		sum: Vec3
		n := 0
		border := vert_border(m, v)
		w := vertex_walk(m, v)
		for h in vertex_walk_next(&w) {
			if border && !edge_border(m, edge_of(h)) do continue
			sum += m.positions[he_tip(m, h)]
			n += 1
		}
		out[i] = sum / f32(n) if n > 0 else m.positions[v]
	}
	return out
}
