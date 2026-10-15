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
