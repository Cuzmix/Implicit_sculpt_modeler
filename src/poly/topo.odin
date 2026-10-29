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
