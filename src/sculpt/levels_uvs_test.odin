package sculpt

import "core:math"
import "core:testing"

import "../geom"
import "../uv"

// Each island's area in the UV square, which a linear split of every triangle (or
// polygon) keeps exactly, so a level's UVs cover the square as the base's do.
@(private = "file")
island_areas :: proc(u: uv.Uvs, allocator := context.temp_allocator) -> []f64 {
	out := make([]f64, u.islands, allocator)
	for c, t in u.corner {
		d1, d2 := c[1] - c[0], c[2] - c[0]
		out[u.island[t]] += 0.5 * f64(d1.x * d2.y - d2.x * d1.y)
	}
	return out
}

@(private = "file")
expect_same_areas :: proc(t: ^testing.T, base, level: uv.Uvs, loc := #caller_location) {
	a, b := island_areas(base), island_areas(level)
	if !testing.expect_value(t, len(b), len(a), loc = loc) do return
	for x, i in a do testing.expectf(t, math.abs(b[i] - x) < 1e-6, "island %d covers %v, the base's %v", i, b[i], x, loc = loc)
}

// The UVs of every Loop level are the base's, split with its triangles: each island
// covers the same area, the seams fall where the base's are, each even vertex keeps
// its coordinates, and Delete lower keeps them as the new base's own.
@(test)
loop_levels_carry_the_uvs :: proc(t: ^testing.T) {
	l: Levels
	levels_init(&l, geom.icosphere(2), nil, 64)
	defer levels_destroy(&l)
	base := l.levels[0]
	u := uv.make_uvs(len(base.mesh.indices) / 3, l.allocator)
	_ = uv.unwrap(&u, base.mesh.positions[:], base.mesh.indices[:], base.sculptor.faces)
	levels_take_uvs(&l, u)
	if !testing.expect(t, l.uvs.islands > 1, "the sphere unwrapped as one island") do return
	testing.expect(t, levels_subdivide(&l))
	testing.expect(t, levels_subdivide(&l))
	for j in 1 ..< 3 {
		at, ok := levels_uvs_at(&l, j, context.temp_allocator)
		if !testing.expectf(t, ok, "level %d has no UVs", j) do continue
		lv := l.levels[j]
		testing.expect_value(t, uv.check(at, lv.mesh.indices[:], lv.sculptor.faces, len(lv.mesh.positions)), "")
		expect_same_areas(t, l.uvs, at)
		// Four children of each parent: four times the seam edges, each split in two.
		seams_below, seams := 0, 0
		below, _ := levels_uvs_at(&l, j - 1, context.temp_allocator)
		for s in below.seam do seams_below += card(s)
		for s in at.seam do seams += card(s)
		testing.expect_value(t, seams, 2 * seams_below)
	}
	// The even vertices of level 1 keep the base's coordinates.
	one, _ := levels_uvs_at(&l, 1, context.temp_allocator)
	lv := l.levels[1]
	for c, tri in l.uvs.corner {
		for k in 0 ..< 3 {
			v := lv.even_of[base.mesh.indices[3 * tri + k]]
			found := false
			for f in geom.vertex_faces_of(lv.sculptor.faces, v) {
				for m in 0 ..< 3 do if lv.mesh.indices[3 * f + u32(m)] == v && one.corner[f][m] == c[k] do found = true
			}
			testing.expect(t, found, "an even vertex lost its coordinate")
		}
	}
	before := l.uvs
	l.uvs = uv.clone(before, l.allocator)
	defer uv.destroy(&before, l.allocator)
	levels_set_current(&l, 2)
	levels_delete_lower(&l)
	if !testing.expect(t, levels_has_uvs(&l), "Delete lower dropped the UVs") do return
	b := l.levels[0]
	testing.expect_value(t, uv.check(l.uvs, b.mesh.indices[:], b.sculptor.faces, len(b.mesh.positions)), "")
	expect_same_areas(t, before, l.uvs)
}

// A Catmull-Clark level's UVs split each polygon at its edges' middles and its corners'
// mean, so a quad cube's islands keep their areas two levels up.
@(test)
catmull_clark_levels_carry_the_uvs :: proc(t: ^testing.T) {
	q := cube_quads()
	old_to_new := make([]u32, len(q.positions), context.temp_allocator)
	tri_from := make([]u32, 2 * len(q.quads), context.temp_allocator)
	l: Levels
	levels_init(&l, geom.quad_mesh_triangulate(q), nil, 64, old_to_new, tri_from)
	defer levels_destroy(&l)
	quads := make([][4]u32, len(q.quads), context.temp_allocator)
	for f, i in q.quads do for v, k in f do quads[i][k] = old_to_new[v]
	polys: Polys
	polys.first = make([]u32, len(quads) + 1)
	for &x, i in polys.first do x = u32(4 * i)
	polys.corners = make([]u32, 4 * len(quads))
	for &f, i in quads do copy(polys.corners[4 * i:], f[:])
	polys.tri_poly = make([]u32, len(tri_from))
	for from, i in tri_from do polys.tri_poly[i] = from / 2
	if !testing.expect(t, levels_set_polys(&l, polys, {}, .Smooth)) do return
	base := l.levels[0]
	// Each face its own island, laid in its own cell of a 3 x 2 grid.
	u := uv.make_uvs(len(base.mesh.indices) / 3, l.allocator)
	for tri in 0 ..< len(u.corner) {
		f := polys.tri_poly[tri]
		cell := [2]f32{f32(f % 3), f32(f / 3)}
		u.island[tri] = f
		for k in 0 ..< 3 {
			v := base.mesh.indices[3 * tri + k]
			corner := 0
			for c, m in quads[f] do if c == v do corner = m
			square := [4][2]f32{{0, 0}, {1, 0}, {1, 1}, {0, 1}}
			u.corner[tri][k] = (cell + 0.1 + 0.8 * square[corner]) / 3
		}
	}
	u.islands = len(quads)
	uv.seams_from_breaks(&u, base.mesh.indices[:], base.sculptor.faces)
	levels_take_uvs(&l, u)
	testing.expect_value(t, uv.check(l.uvs, base.mesh.indices[:], base.sculptor.faces, len(base.mesh.positions)), "")
	testing.expect(t, levels_subdivide(&l))
	testing.expect(t, levels_subdivide(&l))
	at, ok := levels_uvs_at(&l, 2, context.temp_allocator)
	if !testing.expect(t, ok, "the top level has no UVs") do return
	top := l.levels[2]
	testing.expect_value(t, uv.check(at, top.mesh.indices[:], top.sculptor.faces, len(top.mesh.positions)), "")
	expect_same_areas(t, l.uvs, at)
}
