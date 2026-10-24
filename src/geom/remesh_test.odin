package geom

import "core:math/linalg"
import "core:testing"

import "../jobs"

// Every edge in exactly two triangles, once each way, and no triangle repeats a vertex.
@(private = "file")
expect_closed_manifold :: proc(t: ^testing.T, m: Mesh, loc := #caller_location) -> (edges: int) {
	directed := make(map[[2]u32]int, len(m.indices), context.temp_allocator)
	for i := 0; i < len(m.indices); i += 3 {
		for c in 0 ..< 3 {
			a, b := m.indices[i + c], m.indices[i + (c + 1) % 3]
			if a == b {
				testing.expect(t, false, "degenerate triangle", loc = loc)
				return
			}
			directed[{a, b}] += 1
		}
	}
	for e, n in directed {
		if n != 1 || directed[{e[1], e[0]}] != 1 {
			testing.expectf(t, false, "edge %v is in %d triangles that way and %d the other", e, n, directed[{e[1], e[0]}], loc = loc)
			return
		}
	}
	return len(directed) / 2
}

@(test)
remesh_sphere_is_closed_and_keeps_its_shape :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	sphere := icosphere(5)
	defer mesh_destroy(&sphere)
	for target in ([?]int{300, 5000, 40_000}) {
		out, ok := remesh_voxel(sphere, target, &pool)
		defer mesh_destroy(&out)
		testing.expect(t, ok, "remesh failed")
		v, f := len(out.positions), len(out.indices) / 3
		testing.expectf(t, v > target * 7 / 10 && v < target * 13 / 10, "asked for %d vertices, got %d", target, v)
		edges := expect_closed_manifold(t, out)
		testing.expectf(t, v - edges + f == 2, "Euler characteristic %d, not a sphere", v - edges + f)
		h := remesh_spacing(sphere, target)
		worst: f32
		for p, i in out.positions {
			worst = max(worst, abs(linalg.length(p) - 1))
			testing.expect(t, linalg.dot(out.normals[i], p) > 0, "normal points inward")
		}
		testing.expectf(t, worst < 0.6 * h, "a vertex is %v off the sphere, h = %v", worst, h)
	}
}

// Two overlapping spheres become one closed surface with nothing left inside.
@(test)
remesh_merges_overlapping_parts :: proc(t: ^testing.T) {
	a := icosphere(4)
	b := icosphere(4)
	defer mesh_destroy(&a)
	defer mesh_destroy(&b)
	CENTER_B :: Vec3{0.8, 0.3, 0}
	both: Mesh
	defer mesh_destroy(&both)
	for p in a.positions do append(&both.positions, p)
	for p in b.positions do append(&both.positions, p + CENTER_B)
	for i in a.indices do append(&both.indices, i)
	for i in b.indices do append(&both.indices, i + u32(len(a.positions)))
	resize(&both.normals, len(both.positions))
	out, ok := remesh_voxel(both, 8000, nil)
	defer mesh_destroy(&out)
	testing.expect(t, ok, "remesh failed")
	edges := expect_closed_manifold(t, out)
	v, f := len(out.positions), len(out.indices) / 3
	testing.expectf(t, v - edges + f == 2, "Euler characteristic %d: not one closed surface", v - edges + f)
	h := remesh_spacing(both, 8000)
	for p in out.positions {
		da, db := linalg.length(p), linalg.length(p - CENTER_B)
		// On one sphere's surface, and not inside the other.
		testing.expect(t, min(abs(da - 1), abs(db - 1)) < 0.6 * h, "vertex off both spheres")
		testing.expect(t, da > 1 - 0.6 * h && db > 1 - 0.6 * h, "vertex inside the merged shape")
	}
}

// A mesh with a twisted (self-intersecting) region still gives a closed surface.
@(test)
remesh_survives_self_intersection :: proc(t: ^testing.T) {
	m := icosphere(4)
	defer mesh_destroy(&m)
	// Push a cap through the sphere so it pokes out the other side.
	for &p in m.positions do if p.z > 0.6 do p.z -= 1.9
	out, ok := remesh_voxel(m, 6000, nil)
	defer mesh_destroy(&out)
	testing.expect(t, ok, "remesh failed")
	_ = expect_closed_manifold(t, out)
}
