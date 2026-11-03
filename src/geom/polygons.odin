package geom

import "core:slice"

// The polygons a mesh's triangles were cut from, given `polys` (one a triangle, as
// Mesh_Part.polys keeps them: a run of equal numbers is one polygon's triangles): for
// polygon f its corners are corners[first[f]:first[f + 1]], in order round it, and
// tri_poly[t] is triangle t's polygon. A run is joined back into one polygon when its
// triangles make a disc whose edge passes each corner once, which any cut of a simple
// polygon into triangles does whatever the cut (a fan, ear clipping) and whichever way
// the triangles were turned, starting from the run's first corner so a fan keeps the
// file's order; otherwise each of its triangles stays a polygon of its own, as when
// cleaning welded two of its corners together. All nil when `polys` is empty or every
// polygon is a triangle. Made with `allocator`; serial, so the result never depends on
// the pool.
mesh_polygons :: proc(indices: []u32, polys: []u32, allocator := context.allocator) -> (first, corners, tri_poly: []u32) {
	triangles := len(indices) / 3
	if len(polys) != triangles || triangles == 0 do return
	joined := false
	for t in 1 ..< triangles do joined ||= polys[t] == polys[t - 1]
	if !joined do return

	out_first := make([dynamic]u32, 0, triangles + 1, allocator)
	out_corners := make([dynamic]u32, 0, indices_room(polys), allocator)
	tri_poly = make([]u32, triangles, allocator)
	append(&out_first, 0)
	edges := make([dynamic]u64, context.temp_allocator)
	boundary := make([dynamic]u64, context.temp_allocator)
	loop := make([dynamic]u32, context.temp_allocator)
	for lo := 0; lo < triangles; {
		hi := lo + 1
		for hi < triangles && polys[hi] == polys[lo] do hi += 1
		if hi - lo == 2 && polygon_quad(indices[3 * lo:3 * hi], &loop) || hi - lo > 2 && polygon_loop(indices[3 * lo:3 * hi], &edges, &boundary, &loop) {
			append(&out_corners, ..loop[:])
			append(&out_first, u32(len(out_corners)))
			slice.fill(tri_poly[lo:hi], u32(len(out_first) - 2))
		} else {
			for t in lo ..< hi {
				append(&out_corners, ..indices[3 * t:][:3])
				append(&out_first, u32(len(out_corners)))
				tri_poly[t] = u32(len(out_first) - 2)
			}
		}
		lo = hi
	}
	shrink(&out_first)
	shrink(&out_corners)
	return out_first[:], out_corners[:], tri_poly
}

// Gives the triangles of `polys` (one a triangle, or empty for none) numbers counted from
// `next` in triangle order, a run of equal numbers one number, so polygons from several
// parts never share one; a part without polygons gets a number a triangle. Returns the
// next free number.
polys_renumber :: proc(polys: ^[dynamic]u32, triangles: int, next: u32) -> u32 {
	next := next
	if len(polys) == 0 {
		resize(polys, triangles)
		for &p in polys {
			p = next
			next += 1
		}
		return next
	}
	assert(len(polys) == triangles, "one polygon number a triangle")
	for t := 0; t < triangles; {
		run := polys[t]
		for t < triangles && polys[t] == run {
			polys[t] = next
			t += 1
		}
		next += 1
	}
	return next
}

// About how many corners the polygons of `polys` have, as room to make for them: a
// polygon cut into k triangles has k + 2.
@(private = "file")
indices_room :: proc(polys: []u32) -> int {
	runs := 1
	for t in 1 ..< len(polys) do if polys[t] != polys[t - 1] do runs += 1
	return len(polys) + 2 * runs
}

// Two triangles (`tris`, three corners each) as the quad they make into `loop`, when they
// share one edge, either way round, and are turned the same way: the common case of a
// quad mesh, done without polygon_loop's sorting.
@(private = "file")
polygon_quad :: proc(tris: []u32, loop: ^[dynamic]u32) -> bool {
	a, b := tris[0:3], tris[3:6]
	for i in 0 ..< 3 {
		x, y, z := a[i], a[(i + 1) % 3], a[(i + 2) % 3]
		for j in 0 ..< 3 {
			if b[j] != y || b[(j + 1) % 3] != x do continue
			o := b[(j + 2) % 3]
			if o == z do return false
			// Round the edge x -> o -> y -> z, started at the first triangle's first corner.
			quad := [4]u32{x, o, y, z}
			start := 0
			for k in 0 ..< 4 do if quad[k] == a[0] do start = k
			clear(loop)
			for k in 0 ..< 4 do append(loop, quad[(start + k) % 4])
			return true
		}
	}
	return false
}

// The edge of a run of triangles (`tris`, three corners each) as one loop of its
// corners into `loop`, or false when the run is not a disc whose edge passes each of
// its corners once.
@(private = "file")
polygon_loop :: proc(tris: []u32, edges, boundary: ^[dynamic]u64, loop: ^[dynamic]u32) -> bool {
	k := len(tris) / 3
	clear(edges)
	clear(boundary)
	clear(loop)
	for t in 0 ..< k {
		for c in 0 ..< 3 do append(edges, u64(tris[3 * t + c]) << 32 | u64(tris[3 * t + (c + 1) % 3]))
	}
	slice.sort(edges[:])
	// An edge twice the same way round means triangles that overlap or face apart.
	for i in 1 ..< len(edges) do if edges[i] == edges[i - 1] do return false
	// An edge the run has both ways round is inside it; the rest are its edge.
	for e in edges {
		back := e << 32 | e >> 32
		if _, inside := slice.binary_search(edges[:], back); !inside do append(boundary, e)
	}
	// A disc of k triangles whose corners are all on its edge has k + 2 edges there.
	if len(boundary) != k + 2 do return false
	// Sorted by where they start, as `edges` was; each corner starts one.
	for i in 1 ..< len(boundary) do if boundary[i] >> 32 == boundary[i - 1] >> 32 do return false
	starts := proc(e: u64, v: u32) -> slice.Ordering {return slice.cmp(u32(e >> 32), v)}
	// One walk round must pass every edge before it comes back, or the edge is two loops.
	at := tris[0]
	for step in 0 ..< len(boundary) {
		i, found := slice.binary_search_by(boundary[:], at, starts)
		if !found do return false
		append(loop, at)
		at = u32(boundary[i] & 0xffff_ffff)
		if (at == tris[0]) != (step == len(boundary) - 1) do return false
	}
	// Every corner of the run is on the loop (no corner inside the disc).
	for c in tris {
		if _, on := slice.binary_search_by(boundary[:], c, starts); !on do return false
	}
	return true
}
