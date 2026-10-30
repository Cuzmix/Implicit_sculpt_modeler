package geom

import "core:math"
import "core:testing"

import "../jobs"

@(test)
decimate_keeps_a_closed_shape :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	// A bumpy sphere big enough for the parallel first round.
	m := geodesic_sphere(130, &pool)
	defer mesh_destroy(&m)
	for &p in m.positions do p *= 1 + 0.05 * math.sin(p.x * 9) * math.sin(p.y * 7)
	before := mesh_check(m)
	testing.expect(t, before.triangles > 200_000)
	for target in ([2]int{20_000, 1_000}) {
		from: [dynamic]u32
		defer delete(from)
		out, err, ok := mesh_decimate(m, target, &pool, from = &from)
		defer mesh_destroy(&out)
		testing.expect(t, ok)
		// Every vertex kept is one of the mesh's own, which `from` names.
		testing.expect_value(t, len(from), len(out.positions))
		for k in 0 ..< len(from) do if out.positions[k] != m.positions[from[k]] {
			testing.expectf(t, false, "%d: vertex %d is not the mesh's %d", target, k, from[k])
			break
		}
		r := mesh_check(out)
		testing.expectf(t, r.closed && r.degenerate_triangles == 0 && !r.inverted && r.non_manifold_edges == 0, "%d: %v", target, r)
		testing.expectf(t, r.vertices - r.triangles / 2 == 2, "%d: not a sphere's count (%d, %d)", target, r.vertices, r.triangles)
		testing.expectf(t, abs(r.triangles - target) <= target / 20, "%d: %d triangles", target, r.triangles)
		// Collapsing onto existing vertices cuts corners: a little volume goes, more the
		// fewer triangles are left.
		loose := 0.02 if target > 10_000 else 0.05
		testing.expectf(t, abs(r.volume - before.volume) < loose * before.volume, "%d: volume %.4f from %.4f", target, r.volume, before.volume)
		testing.expectf(t, err < f32(loose * 2), "%d: error %f", target, err)
		testing.expect(t, len(out.normals) == len(out.positions))
	}
	// Nothing to do.
	_, _, ok := mesh_decimate(m, before.triangles, &pool)
	testing.expect(t, !ok)
}
