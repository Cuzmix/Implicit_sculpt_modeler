package voxel

import "core:testing"

import "../geom"
import "../jobs"

// A box of clay is closed and manifold, holds the box's volume to within the edges a
// voxel rounds, keeps its sides flat, and fills the same bit for bit with worker threads.
@(test)
a_box_of_clay_holds_its_volume_and_fills_the_same_in_parallel :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	half := Vec3{0.8, 0.8, 0.8}
	serial, parallel: Clay
	clay_init(&serial, 2.0 / 96, {}, nil)
	defer clay_destroy(&serial)
	clay_init(&parallel, 2.0 / 96, {}, &pool)
	defer clay_destroy(&parallel)
	clay_fill_box(&serial, {}, half)
	clay_fill_box(&parallel, {}, half)
	testing.expect_value(t, clay_hash(&parallel), clay_hash(&serial))

	m := clay_to_mesh(&serial)
	defer geom.mesh_destroy(&m)
	r := geom.mesh_check(m)
	testing.expectf(t, r.closed && !r.inverted && r.non_manifold_edges == 0 && r.boundary_edges == 0 && r.degenerate_triangles == 0 && r.nan_count == 0, "%v", r)
	exact := f64(8 * half.x * half.y * half.z)
	testing.expectf(t, abs(r.volume - exact) < 0.03 * exact, "volume %.4f, want %.4f", r.volume, exact)
	// Every vertex is on the box: no further than a voxel from its nearest side.
	voxel := serial.volume.voxel
	for p in m.positions {
		q := [3]f32{abs(p.x) - half.x, abs(p.y) - half.y, abs(p.z) - half.z}
		testing.expectf(t, abs(max(q.x, q.y, q.z)) < voxel, "%v is %.4f off the box", p, max(q.x, q.y, q.z))
	}
}
