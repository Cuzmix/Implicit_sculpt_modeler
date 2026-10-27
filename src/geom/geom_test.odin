package geom

import "core:math"
import "core:math/linalg"
import "core:testing"

@(test)
icosphere_counts :: proc(t: ^testing.T) {
	for level in 0 ..= 4 {
		m := icosphere(level)
		defer mesh_destroy(&m)
		pow4 := 1 << uint(2 * level)
		testing.expect_value(t, mesh_vertex_count(m), 10 * pow4 + 2)
		testing.expect_value(t, mesh_triangle_count(m), 20 * pow4)
		testing.expect_value(t, len(m.normals), len(m.positions))
	}
}

@(test)
icosphere_on_sphere_with_unit_normals :: proc(t: ^testing.T) {
	m := icosphere(3, radius = 2)
	defer mesh_destroy(&m)
	for p, i in m.positions {
		testing.expect(t, math.abs(linalg.length(p) - 2) < 1e-5, "vertex not on sphere")
		testing.expect(t, math.abs(linalg.length(m.normals[i]) - 1) < 1e-5, "normal not unit length")
	}
}

@(test)
icosphere_is_closed_and_outward :: proc(t: ^testing.T) {
	m := icosphere(2)
	defer mesh_destroy(&m)
	// Closed, consistently wound and facing outward (a positive signed volume).
	r := mesh_check(m)
	testing.expectf(t, mesh_report_ok(r), "%v", r)
}

@(test)
recomputed_normals_match_sphere :: proc(t: ^testing.T) {
	m := icosphere(4)
	defer mesh_destroy(&m)
	mesh_recompute_normals(&m)
	for p, i in m.positions {
		testing.expect(t, linalg.dot(m.normals[i], linalg.normalize(p)) > 0.999, "normal deviates from radial")
	}
}

@(test)
vertex_faces_cover_every_corner :: proc(t: ^testing.T) {
	m := icosphere(2)
	defer mesh_destroy(&m)
	vf := vertex_faces_build(m)
	defer vertex_faces_destroy(&vf)
	testing.expect_value(t, len(vf.tris), len(m.indices))
	for v in 0 ..< u32(len(m.positions)) {
		faces := vertex_faces_of(vf, v)
		testing.expect(t, len(faces) == 5 || len(faces) == 6, "icosphere valence should be 5 or 6")
		for f in faces {
			ok := m.indices[3 * f] == v || m.indices[3 * f + 1] == v || m.indices[3 * f + 2] == v
			testing.expect(t, ok, "face does not contain its vertex")
		}
	}
}

@(test)
spatial_sort_preserves_geometry :: proc(t: ^testing.T) {
	m := icosphere(3)
	defer mesh_destroy(&m)
	before := make([]Vec3, len(m.indices), context.temp_allocator)
	for i, k in m.indices {
		before[k] = m.positions[i]
	}
	mesh_sort_vertices_spatially(&m)
	for i, k in m.indices {
		testing.expect_value(t, m.positions[i], before[k])
	}
}

// Every triangle must lie inside its leaf, and every node inside its parent.
@(private = "file")
bvh_bounds_valid :: proc(b: Bvh, m: Mesh) -> bool {
	inside :: proc(inner, outer: Aabb) -> bool {
		eps :: 1e-6
		return inner.lo.x >= outer.lo.x - eps && inner.lo.y >= outer.lo.y - eps && inner.lo.z >= outer.lo.z - eps &&
			inner.hi.x <= outer.hi.x + eps && inner.hi.y <= outer.hi.y + eps && inner.hi.z <= outer.hi.z + eps
	}
	for tri in 0 ..< u32(len(m.indices) / 3) {
		if !inside(tri_bounds(m, tri), b.nodes[b.tri_leaf[tri]].bounds) do return false
	}
	for node in b.nodes {
		if node.parent != BVH_NONE && !inside(node.bounds, b.nodes[node.parent].bounds) do return false
	}
	return true
}

@(test)
bvh_build_covers_every_triangle_once :: proc(t: ^testing.T) {
	m := icosphere(4)
	defer mesh_destroy(&m)
	b := bvh_build(m)
	defer bvh_destroy(&b)
	seen := make([]bool, len(m.indices) / 3, context.temp_allocator)
	for node in b.nodes {
		if node.count == 0 do continue
		testing.expect(t, node.count <= BVH_LEAF_SIZE, "leaf too large")
		for i in node.first ..< node.first + node.count {
			testing.expect(t, !seen[b.tri_order[i]], "triangle in two leaves")
			seen[b.tri_order[i]] = true
		}
	}
	for s in seen do testing.expect(t, s, "triangle missing from BVH")
	testing.expect(t, bvh_bounds_valid(b, m), "bounds do not nest")
}

@(test)
bvh_refit_tracks_moved_vertices :: proc(t: ^testing.T) {
	m := icosphere(4)
	defer mesh_destroy(&m)
	b := bvh_build(m)
	defer bvh_destroy(&b)
	vf := vertex_faces_build(m)
	defer vertex_faces_destroy(&vf)

	// Pull a patch of vertices far outward, then refit only their triangles.
	moved := make([dynamic]u32, context.temp_allocator)
	for &p, v in m.positions {
		if p.z > 0.8 {
			p *= 1.6
			append(&moved, ..vertex_faces_of(vf, u32(v)))
		}
	}
	testing.expect(t, !bvh_bounds_valid(b, m), "test should invalidate bounds before refit")
	bvh_refit_triangles(&b, m, moved[:])
	testing.expect(t, bvh_bounds_valid(b, m), "refit left stale bounds")
}

@(test)
geodesic_sphere_is_closed_with_expected_counts :: proc(t: ^testing.T) {
	for f in 1 ..= 9 {
		m := geodesic_sphere(f)
		defer mesh_destroy(&m)
		testing.expect_value(t, len(m.positions), 10 * f * f + 2)
		testing.expect_value(t, len(m.indices), 60 * f * f)
		// Closed (faces share their vertices), consistently wound and facing outward.
		r := mesh_check(m)
		testing.expectf(t, mesh_report_ok(r), "frequency %d: %v", f, r)
		for p in m.positions do testing.expect(t, math.abs(linalg.length(p) - 1) < 1e-5, "vertex off sphere")
	}
	testing.expect_value(t, geodesic_frequency_for(10_000_000), 1000)
}

@(test)
morton_bvh_is_valid_and_raycasts :: proc(t: ^testing.T) {
	m := geodesic_sphere(20)
	defer mesh_destroy(&m)
	b := bvh_build_morton(m, 16)
	defer bvh_destroy(&b)
	seen := make([]bool, len(m.indices) / 3, context.temp_allocator)
	for node in b.nodes {
		if node.count == 0 do continue
		testing.expect(t, node.count <= 16, "leaf too large")
		for i in node.first ..< node.first + node.count do seen[b.tri_order[i]] = true
	}
	for s in seen do testing.expect(t, s, "triangle missing from BVH")
	testing.expect(t, bvh_bounds_valid(b, m), "bounds do not nest")
	tri_t, _, ok := bvh_raycast(&b, m, {0.1, 0.2, 5}, {0, 0, -1})
	testing.expect(t, ok && math.abs(tri_t - (5 - math.sqrt(f32(0.95)))) < 0.01, "ray should hit the front of the sphere")
}

// The line query returns every leaf holding a vertex within the radius of the line, and
// only leaves whose bounds come that near it.
@(test)
bvh_line_query_finds_the_leaves_near_the_line :: proc(t: ^testing.T) {
	m := icosphere(4)
	defer mesh_destroy(&m)
	b := bvh_build(m)
	defer bvh_destroy(&b)
	origin, dir, radius := Vec3{0.2, -0.1, 3}, linalg.normalize(Vec3{0.1, 0.05, -1}), f32(0.3)
	found: [dynamic]u32
	defer delete(found)
	bvh_query_leaves_line(&b, origin, dir, radius, &found)
	is_found := make([]bool, len(b.nodes), context.temp_allocator)
	for n in found do is_found[n] = true
	near :: proc(p, origin, dir: Vec3, radius: f32) -> bool {
		d := p - origin
		across := d - linalg.dot(d, dir) * dir
		return linalg.dot(across, across) < radius * radius
	}
	wanted := 0
	for node, n in b.nodes {
		if node.count == 0 do continue
		has := false
		for i in node.first ..< node.first + node.count {
			tri := b.tri_order[i]
			for c in 0 ..< u32(3) do has ||= near(m.positions[m.indices[3 * tri + c]], origin, dir, radius)
		}
		if has {
			wanted += 1
			testing.expectf(t, is_found[n], "leaf %d near the line was missed", n)
		}
		if is_found[n] {
			// Its bounds' centre along the line's nearest point: the box grown by the radius
			// holds a point of the line.
			lo, hi := node.bounds.lo - radius, node.bounds.hi + radius
			hit := false
			for k in 0 ..= 4000 {
				p := origin + dir * (f32(k) * 0.002)
				if p.x >= lo.x && p.x <= hi.x && p.y >= lo.y && p.y <= hi.y && p.z >= lo.z && p.z <= hi.z do hit = true
			}
			testing.expectf(t, hit, "leaf %d is far from the line", n)
		}
	}
	testing.expect(t, wanted > 0 && len(found) < len(b.nodes) / 2)
}
