package sculpt

import "core:math/linalg"
import "core:testing"

import "../geom"

// The levels' top level as polygons: its own (Catmull-Clark) or its triangles.
@(private = "file")
top_polys :: proc(l: ^Levels) -> (positions: []Vec3, first, corners: []u32) {
	lv := l.levels[len(l.levels) - 1]
	positions = lv.mesh.positions[:]
	if lv.polys.first != nil do return positions, lv.polys.first, lv.polys.corners
	tris := len(lv.mesh.indices) / 3
	first = make([]u32, tris + 1, context.temp_allocator)
	for &f, i in first do f = u32(3 * i)
	return positions, first, lv.mesh.indices[:]
}

// Whether every point of `a` has one of `b` within `within`.
@(private = "file")
near_all :: proc(a, b: []Vec3, within: f32) -> (worst: f32) {
	for p in a {
		best := max(f32)
		for q in b do best = min(best, linalg.length(p - q))
		worst = max(worst, best)
	}
	return
}

// A sphere subdivided twice by Loop gets its two levels back: the top is the mesh itself,
// exactly, and the base lands where the sphere it was made from was.
@(test)
rebuild_finds_loop_levels :: proc(t: ^testing.T) {
	made: Levels
	defer levels_destroy(&made)
	levels_init(&made, geom.icosphere(1), nil, 64)
	original := make([]Vec3, len(made.levels[0].mesh.positions), context.temp_allocator)
	copy(original, made.levels[0].mesh.positions[:])
	testing.expect(t, levels_subdivide(&made) && levels_subdivide(&made))
	positions, first, corners := top_polys(&made)

	l: Levels
	defer levels_destroy(&l)
	below, from := levels_rebuild(&l, positions, first, corners, nil, node_triangles = 64)
	defer delete(from)
	// The icosphere is itself an icosahedron split once, so a third level turns up.
	testing.expect_value(t, below, 3)
	testing.expect_value(t, len(l.levels), 4)
	testing.expect_value(t, l.current, 3)
	if below != 3 do return
	top := l.levels[3].mesh.positions[:]
	worst: f32
	for u, i in from do worst = max(worst, linalg.length(top[i] - positions[u]))
	testing.expectf(t, worst == 0, "the top moved by %v", worst)
	testing.expect_value(t, len(l.levels[1].mesh.positions), len(original))
	testing.expectf(t, near_all(l.levels[1].mesh.positions[:], original, 1e-3) < 1e-3, "level 1 is not the sphere it was made from")
	testing.expect_value(t, len(l.levels[0].mesh.positions), 12)
	// Down to the base and back, the top is still the mesh.
	levels_set_current(&l, 0)
	levels_set_current(&l, 3)
	worst = 0
	for u, i in from do worst = max(worst, linalg.length(top[i] - positions[u]))
	testing.expectf(t, worst < 1e-5, "the top drifted by %v going down and back", worst)
}

// A cube's Catmull-Clark levels come back as Catmull-Clark levels, its base the cube.
@(test)
rebuild_finds_catmull_clark_levels :: proc(t: ^testing.T) {
	cube := []Vec3{{-1, -1, -1}, {1, -1, -1}, {1, 1, -1}, {-1, 1, -1}, {-1, -1, 1}, {1, -1, 1}, {1, 1, 1}, {-1, 1, 1}}
	quads := [][4]u32{{0, 3, 2, 1}, {4, 5, 6, 7}, {0, 1, 5, 4}, {1, 2, 6, 5}, {2, 3, 7, 6}, {3, 0, 4, 7}}
	mesh: geom.Mesh
	append(&mesh.positions, ..cube)
	for q in quads do append(&mesh.indices, q[0], q[1], q[2], q[0], q[2], q[3])
	resize(&mesh.normals, len(cube))
	geom.mesh_recompute_normals(&mesh)
	made: Levels
	defer levels_destroy(&made)
	old_to_new := make([]u32, 8, context.temp_allocator)
	tri_from := make([]u32, 12, context.temp_allocator)
	levels_init(&made, mesh, nil, 64, old_to_new, tri_from)
	polys := Polys{first = make([]u32, 7), corners = make([]u32, 24), tri_poly = make([]u32, 12)}
	for q, f in quads {
		polys.first[f + 1] = u32(4 * (f + 1))
		for k in 0 ..< 4 do polys.corners[4 * f + k] = old_to_new[q[k]]
	}
	for old, tt in tri_from do polys.tri_poly[tt] = old / 2
	testing.expect(t, levels_set_polys(&made, polys, {}, .Smooth))
	testing.expect(t, levels_subdivide(&made) && levels_subdivide(&made))
	positions, first, corners := top_polys(&made)
	testing.expect_value(t, int(first[1] - first[0]), 4)

	l: Levels
	defer levels_destroy(&l)
	below, from := levels_rebuild(&l, positions, first, corners, nil, node_triangles = 64)
	defer delete(from)
	testing.expect_value(t, below, 2)
	if below != 2 do return
	testing.expect(t, l.rule == .Smooth, "not Catmull-Clark levels")
	top := l.levels[2].mesh.positions[:]
	worst: f32
	for u, i in from do worst = max(worst, linalg.length(top[i] - positions[u]))
	testing.expectf(t, worst == 0, "the top moved by %v", worst)
	testing.expectf(t, near_all(l.levels[0].mesh.positions[:], cube, 1e-3) < 1e-3, "the base is not the cube: %v", l.levels[0].mesh.positions[:])
}

// A mesh no subdivision made, and an open one, get no levels.
@(test)
rebuild_refuses_other_meshes :: proc(t: ^testing.T) {
	cube := geom.icosphere(0)
	defer geom.mesh_destroy(&cube)
	first := make([]u32, len(cube.indices) / 3 + 1, context.temp_allocator)
	for &f, i in first do f = u32(3 * i)
	l: Levels
	below, from := levels_rebuild(&l, cube.positions[:], first, cube.indices[:], nil)
	testing.expect_value(t, below, 0)
	testing.expect(t, from == nil && l.levels == nil)
	// Open: the sphere's last triangle gone.
	sphere := geom.icosphere(2)
	defer geom.mesh_destroy(&sphere)
	n := len(sphere.indices) / 3 - 1
	open_first := make([]u32, n + 1, context.temp_allocator)
	for &f, i in open_first do f = u32(3 * i)
	below, from = levels_rebuild(&l, sphere.positions[:], open_first, sphere.indices[:3 * n], nil)
	testing.expect_value(t, below, 0)
}
