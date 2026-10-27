package voxel

import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

// A sculpted sphere: strokes of three brushes, so the surface has blends, a dent and nodes
// that were remeshed more than once.
@(private = "file")
sculpted_sphere :: proc(across: f32, pool: ^jobs.Pool = nil) -> (c: Clay) {
	clay_init(&c, 2 / across, {}, pool)
	clay_fill_sphere(&c, {}, 1)
	_ = clay_flush(&c)
	kinds := [3]Brush_Kind{.Add, .Subtract, .Smooth}
	for kind, k in kinds {
		clay_stroke_begin(&c)
		for i in 0 ..< 8 {
			a := f32(i) * 0.3 + f32(k) * 2
			at := linalg.normalize(Vec3{math.cos(a), math.sin(a), 0.4 - 0.3 * f32(k)})
			_ = clay_dab(&c, {kind = kind, radius = 0.25, strength = 0.8, normal = at}, at)
		}
		_ = clay_stroke_end(&c)
		_ = clay_flush(&c)
	}
	return
}

@(test)
the_code_weld_gives_the_position_weld_s_mesh :: proc(t: ^testing.T) {
	c := sculpted_sphere(96)
	defer clay_destroy(&c)
	by_code := clay_to_mesh(&c)
	defer geom.mesh_destroy(&by_code)
	by_position := clay_to_mesh_by_position(&c)
	defer geom.mesh_destroy(&by_position)
	testing.expectf(t, len(by_code.positions) == len(by_position.positions), "%v vertices by code, %v by position", len(by_code.positions), len(by_position.positions))
	testing.expectf(t, len(by_code.indices) == len(by_position.indices), "%v indices by code, %v by position", len(by_code.indices), len(by_position.indices))
	// The same vertices, in another order.
	a := slice.clone(by_code.positions[:])
	b := slice.clone(by_position.positions[:])
	defer delete(a)
	defer delete(b)
	by_xyz :: proc(p, q: Vec3) -> bool {
		if p.x != q.x do return p.x < q.x
		if p.y != q.y do return p.y < q.y
		return p.z < q.z
	}
	slice.sort_by(a, by_xyz)
	slice.sort_by(b, by_xyz)
	testing.expect(t, slice.equal(a, b), "the welds keep different vertices")
	r := geom.mesh_check(by_code)
	testing.expectf(t, r.closed && r.non_manifold_edges == 0 && r.boundary_edges == 0 && r.degenerate_triangles == 0 && r.nan_count == 0, "%v", r)
	vertices, _ := surface_counts(&c.surface)
	testing.expectf(t, len(by_code.positions) < vertices, "%v vertices in the slots, %v after the weld: nothing was welded", vertices, len(by_code.positions))
}

@(test)
the_weld_is_the_same_on_one_thread_and_three :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	serial := sculpted_sphere(96)
	defer clay_destroy(&serial)
	parallel := sculpted_sphere(96, &pool)
	defer clay_destroy(&parallel)
	a := clay_to_mesh(&serial)
	defer geom.mesh_destroy(&a)
	b := clay_to_mesh(&parallel)
	defer geom.mesh_destroy(&b)
	testing.expect(t, slice.equal(a.positions[:], b.positions[:]), "the positions differ")
	testing.expect(t, slice.equal(a.normals[:], b.normals[:]), "the normals differ")
	testing.expect(t, slice.equal(a.indices[:], b.indices[:]), "the triangles differ")
}

@(test)
the_band_repair_stops_once_every_brick_has_settled :: proc(t: ^testing.T) {
	// The same repair over the same bricks of two equal spheres: one stops at the sweep that
	// changes nothing, the other runs every sweep; the fields must agree bit for bit.
	stopped := sculpted_sphere(96)
	defer clay_destroy(&stopped)
	every := sculpted_sphere(96)
	defer clay_destroy(&every)
	testing.expect_value(t, clay_hash(&stopped), clay_hash(&every))
	mark_front :: proc(c: ^Clay) {
		for coord, slot in c.volume.coords do if coord != BRICK_FREE && coord.z > 256 / BRICK do band_mark(c, u32(slot))
	}
	mark_front(&stopped)
	band_repair(&stopped)
	mark_front(&every)
	band_repair(&every, every_sweep = true)
	testing.expectf(t, stopped.repair_sweeps >= 1 && stopped.repair_sweeps < REPAIR_SWEEPS, "the repair stopped after %v sweeps of %v", stopped.repair_sweeps, REPAIR_SWEEPS)
	testing.expect_value(t, every.repair_sweeps, REPAIR_SWEEPS)
	testing.expect_value(t, clay_hash(&stopped), clay_hash(&every))
}

@(test)
the_weld_survives_a_compaction_of_the_slots :: proc(t: ^testing.T) {
	c := sculpted_sphere(96)
	defer clay_destroy(&c)
	before := clay_to_mesh_by_position(&c)
	defer geom.mesh_destroy(&before)
	surface_compact(&c.surface)
	after := clay_to_mesh(&c)
	defer geom.mesh_destroy(&after)
	testing.expect_value(t, len(after.positions), len(before.positions))
	testing.expect_value(t, len(after.indices), len(before.indices))
	r := geom.mesh_check(after)
	testing.expectf(t, r.closed && r.non_manifold_edges == 0 && r.nan_count == 0, "%v", r)
}
