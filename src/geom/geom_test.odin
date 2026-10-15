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

	// Closed manifold: every directed edge appears once and its reverse appears once.
	edges := make(map[u64]int, context.temp_allocator)
	for tri := 0; tri < len(m.indices); tri += 3 {
		for k in 0 ..< 3 {
			a, b := m.indices[tri + k], m.indices[tri + (k + 1) % 3]
			edges[u64(a) << 32 | u64(b)] += 1
		}
	}
	for key, count in edges {
		testing.expect_value(t, count, 1)
		a, b := key >> 32, key & 0xffff_ffff
		testing.expect(t, (b << 32 | a) in edges, "edge without a twin")
	}

	// Counter-clockwise winding from outside: face normal points away from the centre.
	for tri := 0; tri < len(m.indices); tri += 3 {
		p0, p1, p2 := m.positions[m.indices[tri]], m.positions[m.indices[tri + 1]], m.positions[m.indices[tri + 2]]
		fn := linalg.cross(p1 - p0, p2 - p0)
		testing.expect(t, linalg.dot(fn, p0 + p1 + p2) > 0, "inward-facing triangle")
	}
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
