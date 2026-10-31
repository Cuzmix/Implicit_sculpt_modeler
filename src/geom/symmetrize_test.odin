package geom

import "core:slice"
import "core:testing"

import "../jobs"

@(test)
symmetrize_makes_a_closed_mirror_image :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	for axis in 0 ..< 3 {
		for keep_positive in ([2]bool{true, false}) {
			// Off the origin and bulging on one side, so the cut crosses triangles and
			// the two halves differ.
			m := icosphere(4)
			defer mesh_destroy(&m)
			for &p in m.positions {
				if p.x > 0.3 do p *= 1.3
				p += {0.17, -0.05, 0.11}
			}
			out, ok := mesh_symmetrize(m, axis, keep_positive, &pool)
			defer mesh_destroy(&out)
			testing.expect(t, ok)
			r := mesh_check(out)
			testing.expectf(t, r.closed && r.degenerate_triangles == 0 && r.nan_count == 0 && !r.inverted,
				"axis %d keep+ %v: %v", axis, keep_positive, r)
			// Every vertex has its mirror image among the vertices.
			at := make(map[Vec3]bool, len(out.positions), context.temp_allocator)
			for p in out.positions do at[p] = true
			missing := 0
			for p in out.positions {
				q := p
				q[axis] = -q[axis] if q[axis] != 0 else 0
				if !at[q] do missing += 1
			}
			testing.expectf(t, missing == 0, "axis %d: %d vertices without a mirror image", axis, missing)
			// Along X the kept side decides whether the bulge (at +X) is kept.
			if axis == 0 {
				far: f32
				for p in out.positions do far = max(far, abs(p.x))
				testing.expectf(t, (far > 1.2) == keep_positive, "keep+ %v: farthest x %v", keep_positive, far)
			}
		}
	}
	// A mesh entirely on the dropped side has nothing to keep.
	m := icosphere(2)
	defer mesh_destroy(&m)
	for &p in m.positions do p.x -= 5
	_, ok := mesh_symmetrize(m, 0, true, &pool)
	testing.expect(t, !ok)
}

// A closed box of n by n quads a side, each cut into two triangles, with its polygons:
// the fixture for Mirror and weld on a quad mesh.
@(private = "file")
quad_box :: proc(n: int) -> (m: Mesh, polygons: Polygons) {
	at := make(map[[3]int]u32, context.temp_allocator)
	vertex :: proc(m: ^Mesh, at: ^map[[3]int]u32, g: [3]int, n: int) -> u32 {
		if v, ok := at[g]; ok do return v
		v := u32(len(m.positions))
		append(&m.positions, Vec3{f32(g.x), f32(g.y), f32(g.z)} * (2 / f32(n)) - 1)
		at[g] = v
		return v
	}
	first := make([dynamic]u32)
	corners := make([dynamic]u32)
	tri_poly := make([dynamic]u32)
	append(&first, 0)
	for axis in 0 ..< 3 {
		for high in 0 ..< 2 {
			u, w := (axis + 1) % 3, (axis + 2) % 3
			for i in 0 ..< n {
				for j in 0 ..< n {
					g: [4][3]int
					for k in 0 ..< 4 {
						g[k][axis] = high * n
						g[k][u] = i + (1 if k == 1 || k == 2 else 0)
						g[k][w] = j + (1 if k >= 2 else 0)
					}
					q: [4]u32
					for k in 0 ..< 4 do q[k] = vertex(&m, &at, g[k], n)
					// Counter-clockwise from outside: u then w faces +axis.
					if high == 0 do q = {q[0], q[3], q[2], q[1]}
					f := u32(len(first) - 1)
					append(&corners, ..q[:])
					append(&first, u32(len(corners)))
					append(&m.indices, q[0], q[1], q[2], q[0], q[2], q[3])
					append(&tri_poly, f, f)
				}
			}
		}
	}
	resize(&m.normals, len(m.positions))
	polygons = {first[:], corners[:], tri_poly[:]}
	return
}

@(test)
symmetrize_keeps_a_quad_mesh_quads :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	// Along an edge loop (no shift) and through the middle of a column of quads.
	for shift in ([2]f32{0, 0.1}) {
		for keep_positive in ([2]bool{true, false}) {
			m, polygons := quad_box(8)
			defer mesh_destroy(&m)
			defer delete(polygons.first)
			defer delete(polygons.corners)
			defer delete(polygons.tri_poly)
			for &p in m.positions do p.x += shift
			// The box's top edges along x creased, to see the creases come through.
			creased := make([dynamic]u64, context.temp_allocator)
			for p, v in m.positions {
				if p.y != 1 || p.z != 1 do continue
				for q, w in m.positions {
					if w > v && q.y == 1 && q.z == 1 && abs(q.x - p.x) < 0.3 do append(&creased, u64(v) << 32 | u64(w))
				}
			}
			slice.sort(creased[:])
			sharpness := make([]f32, len(creased), context.temp_allocator)
			slice.fill(sharpness, 2)
			kept: Symmetrized_Polygons
			defer symmetrized_polygons_destroy(&kept)
			out, ok := mesh_symmetrize(m, 0, keep_positive, &pool, polygons = polygons, creases = {edges = creased[:], edge = sharpness}, out_polygons = &kept)
			defer mesh_destroy(&out)
			testing.expect(t, ok)
			r := mesh_check(out)
			testing.expectf(t, r.closed && r.degenerate_triangles == 0 && !r.inverted, "shift %v keep+ %v: %v", shift, keep_positive, r)
			first, corners, tri_poly := mesh_polygons(out.indices[:], kept.polys[:])
			defer delete(first)
			defer delete(corners)
			defer delete(tri_poly)
			testing.expect(t, first != nil)
			not_quads := 0
			for f in 0 ..< len(first) - 1 do if first[f + 1] - first[f] != 4 do not_quads += 1
			testing.expectf(t, not_quads == 0, "shift %v keep+ %v: %d polygons not quads", shift, keep_positive, not_quads)
			// Whether the plane runs along an edge loop or through a column of quads, the
			// seam is an edge loop on the plane (the shifted box's moved onto it), so the
			// box keeps 8 columns of whole quads across x and its 384 quads.
			testing.expectf(t, len(first) - 1 == 384, "shift %v keep+ %v: %d quads, not 384", shift, keep_positive, len(first) - 1)
			// The creased top edge along x runs the whole width, mirrored.
			testing.expectf(t, len(kept.creases.edges) == 8, "shift %v keep+ %v: %d creased edges, not 8", shift, keep_positive, len(kept.creases.edges))
			testing.expect(t, slice.is_sorted(kept.creases.edges))
		}
	}
}

// A polygon the seam would lay flat on the plane: the box of one quad a side keeping its
// - side, where only the end (all four corners on the seam) has its middle there. The
// polygons are cut at the plane instead, each side clipped through two opposite sides to
// a narrower quad, and the creased edges along x are creased to the plane.
@(test)
symmetrize_cuts_quads_when_the_seam_would_flatten_one :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	m, polygons := quad_box(1)
	defer mesh_destroy(&m)
	defer delete(polygons.first)
	defer delete(polygons.corners)
	defer delete(polygons.tri_poly)
	for &p in m.positions do p.x += 0.1
	creased := make([dynamic]u64, context.temp_allocator)
	for p, v in m.positions {
		for q, w in m.positions do if w > v && p.y == q.y && p.z == q.z do append(&creased, u64(v) << 32 | u64(w))
	}
	slice.sort(creased[:])
	sharpness := make([]f32, len(creased), context.temp_allocator)
	slice.fill(sharpness, 1)
	kept: Symmetrized_Polygons
	defer symmetrized_polygons_destroy(&kept)
	out, ok := mesh_symmetrize(m, 0, false, &pool, polygons = polygons, creases = {edges = creased[:], edge = sharpness}, out_polygons = &kept)
	defer mesh_destroy(&out)
	testing.expect(t, ok)
	r := mesh_check(out)
	testing.expectf(t, r.closed && r.degenerate_triangles == 0 && !r.inverted, "%v", r)
	far: f32
	for p in out.positions do far = max(far, abs(p.x))
	testing.expectf(t, abs(far - 0.9) < 1e-5, "the cut moved the end: farthest x %v", far)
	first, corners, tri_poly := mesh_polygons(out.indices[:], kept.polys[:])
	defer delete(first)
	defer delete(corners)
	defer delete(tri_poly)
	testing.expectf(t, len(first) - 1 == 10, "%d polygons, not 10", len(first) - 1)
	for f in 0 ..< len(first) - 1 do testing.expectf(t, first[f + 1] - first[f] == 4, "polygon %d has %d corners", f, first[f + 1] - first[f])
	// Four edges along x, each cut at the plane and mirrored.
	testing.expectf(t, len(kept.creases.edges) == 8, "%d creased edges, not 8", len(kept.creases.edges))
}
