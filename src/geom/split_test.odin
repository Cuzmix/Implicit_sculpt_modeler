package geom

import "core:testing"

// Two spheres joined into one mesh come apart into two parts at their own triangles,
// numbered by the first triangle of each, and each part is closed and its own sphere
// again, vertex for vertex.
@(test)
split_two_joined_spheres_into_parts :: proc(t: ^testing.T) {
	a := icosphere(3)
	defer mesh_destroy(&a)
	b := icosphere(2)
	defer mesh_destroy(&b)
	for &p in b.positions do p.x += 3
	parts := [2]Mesh{a, b}
	both := mesh_join(parts[:])
	defer mesh_destroy(&both)
	part, count := mesh_components(both)
	defer delete(part)
	testing.expect_value(t, count, 2)
	testing.expect_value(t, part[0], 0)
	testing.expect_value(t, part[len(part) - 1], 1)
	split := mesh_split(both, part, count)
	defer split_parts_destroy(split)
	for p, k in split {
		want := parts[k]
		testing.expect_value(t, len(p.mesh.positions), len(want.positions))
		testing.expect_value(t, len(p.mesh.indices), len(want.indices))
		testing.expect(t, mesh_report_ok(mesh_check(p.mesh)))
		edges := mesh_edges(p.mesh, nil)
		testing.expect(t, mesh_edges_closed(edges))
		// Every triangle names its source triangle, whose corners are its own.
		for s, i in p.tri_from {
			for c in 0 ..< 3 {
				testing.expect_value(t, p.vertex_from[p.mesh.indices[3 * i + c]], both.indices[3 * int(s) + c])
			}
		}
		for v, i in p.vertex_from do testing.expect_value(t, p.mesh.positions[i], both.positions[v])
	}
}

// A part named by no triangle is an empty mesh, and a split by halves of one sphere
// shares the vertices on the border between them, each half keeping its own copy.
@(test)
split_halves_share_their_border :: proc(t: ^testing.T) {
	m := icosphere(3)
	defer mesh_destroy(&m)
	tcount := len(m.indices) / 3
	part := make([]u32, tcount)
	defer delete(part)
	for &p, tri in part {
		c := (m.positions[m.indices[3 * tri]] + m.positions[m.indices[3 * tri + 1]] + m.positions[m.indices[3 * tri + 2]]) / 3
		p = 0 if c.y >= 0 else 2
	}
	split := mesh_split(m, part, 3)
	defer split_parts_destroy(split)
	testing.expect_value(t, len(split[1].mesh.positions), 0)
	testing.expect_value(t, len(split[1].mesh.indices), 0)
	testing.expect_value(t, len(split[0].mesh.indices) + len(split[2].mesh.indices), len(m.indices))
	testing.expect(t, len(split[0].mesh.positions) + len(split[2].mesh.positions) > len(m.positions))
	testing.expect(t, !mesh_edges_closed(mesh_edges(split[0].mesh, nil)))
}
