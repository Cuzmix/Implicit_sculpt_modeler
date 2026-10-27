package geom

import "core:math/linalg"
import "core:testing"

@(private = "file")
retopo_sphere :: proc(t: ^testing.T, wanted: int) -> (q: Quad_Mesh, report: Retopo_Report, ok: bool) {
	source := icosphere(5)
	defer mesh_destroy(&source)
	bvh := bvh_build(source)
	defer bvh_destroy(&bvh)
	return mesh_retopo(source, &bvh, wanted, nil)
}

// Retopology of a sphere gives quads only, about as many as asked for, closed, facing
// out, on the sphere.
@(test)
retopo_makes_closed_quads_on_the_surface :: proc(t: ^testing.T) {
	q, report, ok := retopo_sphere(t, 2000)
	defer quad_mesh_destroy(&q)
	testing.expect(t, ok, "retopology failed")
	if !ok do return
	testing.expectf(t, len(q.quads) > 1000 && len(q.quads) < 4000, "%d quads for 2000 asked (%v)", len(q.quads), report)
	testing.expectf(t, report.paired > report.decimated / 2, "only %d of %d triangles paired", report.paired, report.decimated)
	testing.expect_value(t, report.unprojected, 0)
	uses := make(map[u64]int, 4 * len(q.quads), context.temp_allocator)
	for f in q.quads {
		for k in 0 ..< 4 do uses[u64(f[k]) << 32 | u64(f[(k + 1) % 4])] += 1
		n := linalg.cross(q.positions[f[2]] - q.positions[f[0]], q.positions[f[3]] - q.positions[f[1]])
		middle := 0.25 * (q.positions[f[0]] + q.positions[f[1]] + q.positions[f[2]] + q.positions[f[3]])
		testing.expect(t, linalg.dot(n, middle) > 0, "a quad faces in")
	}
	// Closed and consistently wound: each directed edge once, and its reverse once.
	for key, count in uses {
		back := (key & 0xffff_ffff) << 32 | key >> 32
		testing.expect(t, count == 1 && uses[back] == 1, "an edge is open or used twice the same way")
	}
	far: f32
	for p in q.positions do far = max(far, abs(linalg.length(p) - 1))
	testing.expectf(t, far < 0.01, "a vertex is %v off the sphere", far)
	// The same input gives the same quads.
	again, _, _ := retopo_sphere(t, 2000)
	defer quad_mesh_destroy(&again)
	same := len(again.quads) == len(q.quads) && len(again.positions) == len(q.positions)
	if same do for f, i in q.quads do if f != again.quads[i] do same = false
	if same do for p, i in q.positions do if p != again.positions[i] do same = false
	testing.expect(t, same, "two runs differ")
}

// UVs: every corner in the unit square, no triangle folded over, and no texel of a
// 512 square covered twice.
@(test)
uv_unwrap_lays_charts_apart :: proc(t: ^testing.T) {
	q, _, ok := retopo_sphere(t, 1500)
	defer quad_mesh_destroy(&q)
	if !testing.expect(t, ok) do return
	l := quad_uv_unwrap(q, 2.0 / 512)
	defer uv_layout_destroy(&l)
	testing.expectf(t, l.charts > 4 && l.charts < len(q.quads) / 10, "%d charts", l.charts)
	testing.expectf(t, l.filled > 0.35, "charts fill only %v of the square", l.filled)
	SIZE :: 512
	covered := make([]u8, SIZE * SIZE, context.temp_allocator)
	folded, twice := 0, 0
	for corners in l.uvs {
		for c in corners do testing.expect(t, c.x >= 0 && c.y >= 0 && c.x <= 1 && c.y <= 1, "a UV is outside the square")
		for half in ([2][3]int{{0, 1, 2}, {0, 2, 3}}) {
			a, b, c := corners[half[0]], corners[half[1]], corners[half[2]]
			area := (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)
			if area <= 0 do folded += 1
		}
		// Each quad marks the texel centres inside it, rasterized as its two triangles.
		lo := linalg.min(linalg.min(corners[0], corners[1]), linalg.min(corners[2], corners[3]))
		hi := linalg.max(linalg.max(corners[0], corners[1]), linalg.max(corners[2], corners[3]))
		for y in int(lo.y * SIZE) ..= min(int(hi.y * SIZE), SIZE - 1) {
			for x in int(lo.x * SIZE) ..= min(int(hi.x * SIZE), SIZE - 1) {
				p := [2]f32{(f32(x) + 0.5) / SIZE, (f32(y) + 0.5) / SIZE}
				inside := false
				for half in ([2][3]int{{0, 1, 2}, {0, 2, 3}}) {
					a, b, c := corners[half[0]], corners[half[1]], corners[half[2]]
					w0 := (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y)
					w1 := (c.x - b.x) * (p.y - b.y) - (p.x - b.x) * (c.y - b.y)
					w2 := (a.x - c.x) * (p.y - c.y) - (p.x - c.x) * (a.y - c.y)
					if w0 > 0 && w1 > 0 && w2 > 0 do inside = true
				}
				if !inside do continue
				if covered[y * SIZE + x] > 0 do twice += 1
				covered[y * SIZE + x] += 1
			}
		}
	}
	testing.expect_value(t, folded, 0)
	testing.expectf(t, twice == 0, "%d texels covered twice", twice)
}

// Baking a mesh onto itself gives no displacement and normals straight out; onto a copy
// one percent larger, about a hundredth out everywhere.
@(test)
bake_finds_the_source_surface :: proc(t: ^testing.T) {
	q, _, ok := retopo_sphere(t, 1500)
	defer quad_mesh_destroy(&q)
	if !testing.expect(t, ok) do return
	l := quad_uv_unwrap(q, 4.0 / 256)
	defer uv_layout_destroy(&l)
	for grow in ([2]f32{1, 1.01}) {
		source := quad_mesh_triangulate(q)
		defer mesh_destroy(&source)
		for &p in source.positions do p *= grow
		mesh_recompute_normals(&source)
		bvh := bvh_build(source)
		defer bvh_destroy(&bvh)
		b := bake_maps(q, l, {mesh = source, bvh = &bvh}, 256, 0.1, {}, nil)
		defer bake_maps_destroy(&b)
		testing.expectf(t, b.covered > 256 * 256 / 4, "only %d texels covered", b.covered)
		testing.expectf(t, b.hit == b.covered, "%d of %d texels found the surface", b.hit, b.covered)
		// Texels away from every chart keep no displacement; the rest must be right.
		off, tilted, near := 0, 0, 0
		for at in 0 ..< 256 * 256 {
			d := b.displacement[at]
			if abs(d - (grow - 1)) <= 0.004 do near += 1
			else if d != 0 do off += 1
			n := b.normal[4 * at:]
			if abs(int(n[0]) - 128) > 12 || abs(int(n[1]) - 128) > 12 || n[2] < 240 do tilted += 1
		}
		testing.expectf(t, off == 0, "grow %v: %d texels off (max %v)", grow, off, b.max_displacement)
		testing.expectf(t, near >= b.covered, "grow %v: %d texels right of %d covered", grow, near, b.covered)
		testing.expectf(t, tilted < 256 * 256 / 200, "grow %v: %d texels tilted", grow, tilted)
	}
}

// Two quads side by side, one long the 0-2 way and one long the 1-3 way: the triangle
// mesh splits them on different diagonals, and the split mesh written over the quads
// follows the same ones.
@(test)
diagonals_follow_the_triangles :: proc(t: ^testing.T) {
	positions := []Vec3{{0, 0, 0}, {1, -0.4, 0}, {2.5, 1.2, 0}, {0, 1, 0}, {3, 0, 0}, {4, 0, 0}, {4, 1, 0}, {2.6, 1.4, 0}}
	q := Quad_Mesh{positions = positions, quads = [][4]u32{{0, 1, 2, 3}, {4, 5, 6, 7}}}
	m := quad_mesh_triangulate(q)
	defer mesh_destroy(&m)
	faces := vertex_faces_build(m)
	defer vertex_faces_destroy(&faces)
	across := quad_mesh_diagonals(q, m.indices[:], faces)
	defer delete(across)
	for f, i in q.quads {
		split := quad_split(positions, f)
		testing.expectf(t, across[i] == (split[2] != f[2]), "quad %d: across %v, but its triangles are %v", i, across[i], split)
	}
	testing.expect(t, across[0] != across[1], "the two quads should split differently")

	q.across = across
	uvs := Uv_Layout{uvs = [][4][2]f32{{{0, 0}, {0.4, 0}, {0.4, 0.4}, {0, 0.4}}, {{0.5, 0}, {0.9, 0}, {0.9, 0.4}, {0.5, 0.4}}}, chart = []u32{0, 1}, charts = 2}
	normals := quad_mesh_normals(q, context.temp_allocator)
	frame := quad_mesh_tangents(q, uvs, normals, context.temp_allocator)
	_, _, _, indices := quad_mesh_split_uvs(q, uvs, normals, frame, context.temp_allocator)
	for i in 0 ..< len(indices) {
		testing.expectf(t, frame.vertex[indices[i]] == m.indices[i], "corner %d is vertex %d in the split mesh but %d in the triangles", i, frame.vertex[indices[i]], m.indices[i])
	}
	free_all(context.temp_allocator)
}

// The triangles over two quads, reordered and each started from another corner, still
// find their quad's slots in their own corner order; a pillow of two quads over the same
// four vertices, wound opposite ways, gives each triangle its own quad's slots; and a
// triangle wound the wrong way is no half.
@(test)
triangle_corners_follow_each_triangle :: proc(t: ^testing.T) {
	positions := []Vec3{{0, 0, 0}, {1, -0.4, 0}, {2.5, 1.2, 0}, {0, 1, 0}, {3, 0, 0}, {4, 0, 0}, {4, 1, 0}, {2.6, 1.4, 0}}
	q := Quad_Mesh{positions = positions, quads = [][4]u32{{0, 1, 2, 3}, {4, 5, 6, 7}}}
	m := quad_mesh_triangulate(q)
	defer mesh_destroy(&m)
	tris := len(m.indices) / 3
	shuffled := make([]u32, len(m.indices), context.temp_allocator)
	for k in 0 ..< tris {
		from := m.indices[3 * (tris - 1 - k):][:3]
		for c in 0 ..< 3 do shuffled[3 * k + c] = from[(c + k) % 3]
	}
	copy(m.indices[:], shuffled)
	faces := vertex_faces_build(m)
	defer vertex_faces_destroy(&faces)
	q.across = quad_mesh_diagonals(q, m.indices[:], faces, context.temp_allocator)
	uvs := Uv_Layout{uvs = [][4][2]f32{{{0, 0}, {0.4, 0}, {0.4, 0.4}, {0, 0.4}}, {{0.5, 0}, {0.9, 0}, {0.9, 0.4}, {0.5, 0.4}}}, chart = []u32{0, 1}, charts = 2}
	normals := quad_mesh_normals(q, context.temp_allocator)
	frame := quad_mesh_tangents(q, uvs, normals, context.temp_allocator)
	_, _, texcoords, split := quad_mesh_split_uvs(q, uvs, normals, frame, context.temp_allocator)
	corners, ok := quad_mesh_triangle_corners(q, split, m.indices[:], faces, context.temp_allocator)
	testing.expect(t, ok)
	for c, i in corners {
		testing.expectf(t, frame.vertex[c] == m.indices[i], "corner %d takes vertex %d's slot, not %d's", i, frame.vertex[c], m.indices[i])
		quad := 0 if m.indices[i] < 4 else 1
		k := 0
		for q.quads[quad][k] != m.indices[i] do k += 1
		testing.expect_value(t, texcoords[c], uvs.uvs[quad][k])
	}

	// The pillow: the same four vertices, the second quad wound back.
	pillow := Quad_Mesh{positions = positions[:4], quads = [][4]u32{{0, 1, 2, 3}, {0, 3, 2, 1}}}
	pm := quad_mesh_triangulate(pillow)
	defer mesh_destroy(&pm)
	pfaces := vertex_faces_build(pm)
	defer vertex_faces_destroy(&pfaces)
	pillow.across = quad_mesh_diagonals(pillow, pm.indices[:], pfaces, context.temp_allocator)
	puvs := Uv_Layout{uvs = uvs.uvs, chart = []u32{0, 1}, charts = 2}
	pnormals := quad_mesh_normals(pillow, context.temp_allocator)
	pframe := quad_mesh_tangents(pillow, puvs, pnormals, context.temp_allocator)
	_, _, ptex, psplit := quad_mesh_split_uvs(pillow, puvs, pnormals, pframe, context.temp_allocator)
	pcorners, pok := quad_mesh_triangle_corners(pillow, psplit, pm.indices[:], pfaces, context.temp_allocator)
	testing.expect(t, pok)
	for c, i in pcorners {
		// quad_mesh_triangulate keeps quad order: the first two triangles are the first quad's.
		quad := i / 6
		testing.expectf(t, (ptex[c].x < 0.45) == (quad == 0), "corner %d of quad %d took the other quad's UV %v", i, quad, ptex[c])
	}

	// A triangle wound the wrong way.
	m.indices[1], m.indices[2] = m.indices[2], m.indices[1]
	wrong := vertex_faces_build(m)
	defer vertex_faces_destroy(&wrong)
	_, wrong_ok := quad_mesh_triangle_corners(q, split, m.indices[:], wrong, context.temp_allocator)
	testing.expect(t, !wrong_ok)
	free_all(context.temp_allocator)
}
