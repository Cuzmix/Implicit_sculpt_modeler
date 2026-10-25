package sculpt

import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

@(private = "file")
mesh_dup :: proc(m: geom.Mesh) -> geom.Mesh {
	out := geom.Mesh {
		positions = make([dynamic]Vec3, len(m.positions)),
		normals   = make([dynamic]Vec3, len(m.normals)),
		indices   = make([dynamic]u32, len(m.indices)),
	}
	copy(out.positions[:], m.positions[:])
	copy(out.normals[:], m.normals[:])
	copy(out.indices[:], m.indices[:])
	return out
}

@(test)
laid_out_sculptor_matches_the_one_it_came_from :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	a_mesh := geom.icosphere(5)
	defer geom.mesh_destroy(&a_mesh)
	a: Sculptor
	sculptor_init(&a, &a_mesh, &pool, 96)
	defer sculptor_destroy(&a)
	layout := sculptor_layout(&a, context.temp_allocator)

	b_mesh := mesh_dup(a_mesh)
	defer geom.mesh_destroy(&b_mesh)
	b: Sculptor
	testing.expect(t, sculptor_init_laid_out(&b, &b_mesh, &pool, layout, 96), "the layout should fit its own mesh")
	defer sculptor_destroy(&b)
	testing.expect(t, slice.equal(a_mesh.indices[:], b_mesh.indices[:]), "the mesh should keep its order")
	testing.expect_value(t, len(b.nodes), len(a.nodes))
	for n, id in a.nodes {
		m := b.nodes[id]
		testing.expect(t, n.tri_first == m.tri_first && n.vert_first == m.vert_first && n.shared_count == m.shared_count && n.owner_count == m.owner_count, "node differs")
		x := slice.clone(a.shared[n.shared_first:][:n.shared_count], context.temp_allocator)
		y := slice.clone(b.shared[m.shared_first:][:m.shared_count], context.temp_allocator)
		slice.sort(x)
		slice.sort(y)
		testing.expect(t, slice.equal(x, y), "shared vertices differ")
		for k in 0 ..< len(b_mesh.indices) / 3 do if b.node_of[b.bvh.tri_leaf[k]] != a.node_of[a.bvh.tri_leaf[k]] {
			testing.expectf(t, false, "triangle %d is in another node", k)
			break
		}
	}

	// The same dabs move both alike.
	for s in ([]^Sculptor{&a, &b}) {
		_ = sculptor_flush(s)
		sculptor_stroke_begin(s)
		_ = apply_dab(s, {kind = .Draw, radius = 0.4, strength = 1}, {0, 0, 1})
		_ = apply_dab(s, {kind = .Smooth, radius = 0.4, strength = 1}, {0.1, 0, 1})
		_ = sculptor_stroke_end(s)
		_ = sculptor_flush(s)
	}
	testing.expect(t, slice.equal(a_mesh.positions[:], b_mesh.positions[:]), "a dab moved the meshes differently")
	_, ok := sculptor_raycast(&b, {0, 0, 5}, {0, 0, -1})
	testing.expect(t, ok, "a ray should hit the laid out sculptor")
}

@(test)
laid_out_sculptor_refuses_a_layout_that_does_not_fit :: proc(t: ^testing.T) {
	m := geom.icosphere(4)
	defer geom.mesh_destroy(&m)
	a: Sculptor
	sculptor_init(&a, &m, nil, 64)
	defer sculptor_destroy(&a)
	good := sculptor_layout(&a, context.temp_allocator)
	bad := [][]Node_Sizes {
		{},
		good[:len(good) - 1],
		slice.clone(good, context.temp_allocator),
		slice.clone(good, context.temp_allocator),
		slice.clone(good, context.temp_allocator),
	}
	bad[2][0].tris += 1
	bad[3][0].tris, bad[3][1].tris = bad[3][0].tris + bad[3][1].tris, 0
	// Vertices moved from the first node to the second: the first then uses vertices
	// the second owns.
	bad[4][0].verts, bad[4][1].verts = bad[4][0].verts - 5, bad[4][1].verts + 5
	for layout, i in bad {
		dup := mesh_dup(m)
		defer geom.mesh_destroy(&dup)
		s: Sculptor
		testing.expectf(t, !sculptor_init_laid_out(&s, &dup, nil, layout, 64), "layout %d should be refused", i)
		testing.expect(t, s.nodes == nil && s.bvh.nodes == nil, "a refused layout should leave the sculptor empty")
	}
	// Nodes over the size the caller asks for are refused too.
	dup := mesh_dup(m)
	defer geom.mesh_destroy(&dup)
	s: Sculptor
	testing.expect(t, !sculptor_init_laid_out(&s, &dup, nil, good, 16), "nodes over the size should be refused")
}
