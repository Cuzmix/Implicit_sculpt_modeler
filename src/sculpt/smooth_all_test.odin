package sculpt

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

// A sphere with every vertex pushed in or out by a fixed hash of its index.
@(private = "file")
rough_sphere :: proc(level: int) -> geom.Mesh {
	m := geom.icosphere(level)
	for &p, v in m.positions {
		h := u32(v) * 2654435761
		h ~= h >> 15
		p *= 1 + 0.05 * (f32(h & 0xffff) / 0xffff - 0.5)
	}
	return m
}

// How far the vertices `mask` leaves free sit from the unit sphere, on average.
@(private = "file")
roughness :: proc(m: geom.Mesh, mask: []u8) -> f32 {
	sum: f32
	n: int
	for p, v in m.positions {
		if mask[v] != 0 do continue
		sum += abs(linalg.length(p) - 1)
		n += 1
	}
	return sum / f32(n)
}

@(test)
smooth_all_evens_the_surface_and_leaves_masked_vertices :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	m := rough_sphere(6)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, &pool, 64)
	defer sculptor_destroy(&s)
	sculptor_recompute_all(&s)
	before := slice.clone(m.positions[:])
	defer delete(before)
	mask_ensure(&s)
	for p, v in m.positions do if p.z < -0.5 do s.mask[v] = 255

	rough := roughness(m, s.mask)
	changed, on_gpu := sculptor_smooth_all(&s, 5, 0.5)
	testing.expect(t, changed && !on_gpu)
	_ = sculptor_flush(&s)
	testing.expectf(t, roughness(m, s.mask) < rough / 2, "roughness %v from %v", roughness(m, s.mask), rough)
	for p, v in m.positions do if s.mask[v] == 255 do testing.expect(t, p == before[v])
	// The BVH follows the moved surface.
	hit, ok := sculptor_raycast(&s, {0, 0, 2}, {0, 0, -1})
	testing.expectf(t, ok && abs(linalg.length(hit) - 1) < 0.05, "hit %v %v", hit, ok)

	// One undo step puts every vertex back exactly; redo brings the smoothing back.
	after := slice.clone(m.positions[:])
	defer delete(after)
	testing.expect(t, sculptor_undo(&s))
	for p, v in m.positions do testing.expect(t, p == before[v])
	testing.expect(t, sculptor_redo(&s))
	for p, v in m.positions do testing.expect(t, p == after[v])

	// Nothing free to move: no step.
	for &k in s.mask do k = 255
	changed, _ = sculptor_smooth_all(&s, 3, 1)
	testing.expect(t, !changed)
}

@(test)
smooth_all_is_the_same_serial_and_parallel :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	m := rough_sphere(7)
	defer geom.mesh_destroy(&m)
	faces := geom.vertex_faces_build(m, &pool)
	defer geom.vertex_faces_destroy(&faces)
	weights := make([]f32, len(m.positions))
	defer delete(weights)
	for p, v in m.positions do weights[v] = 0.7 if p.x > -0.3 else 0
	serial := slice.clone(m.positions[:])
	defer delete(serial)
	parallel := slice.clone(m.positions[:])
	defer delete(parallel)
	// An odd step count leaves the result in the scratch copy, which must come back.
	smooth_all_cpu(nil, serial, m.indices[:], faces, weights, 3)
	smooth_all_cpu(&pool, parallel, m.indices[:], faces, weights, 3)
	testing.expect(t, slice.equal(serial, parallel))
	testing.expect(t, !slice.equal(serial, m.positions[:]))
}

// A GPU that fails hands the work back to the CPU, which gives the CPU's result.
@(test)
smooth_all_falls_back_to_the_cpu :: proc(t: ^testing.T) {
	m := rough_sphere(4)
	defer geom.mesh_destroy(&m)
	copy_m := rough_sphere(4)
	defer geom.mesh_destroy(&copy_m)
	a, b: Sculptor
	sculptor_init(&a, &m, nil, 64)
	defer sculptor_destroy(&a)
	sculptor_init(&b, &copy_m, nil, 64)
	defer sculptor_destroy(&b)
	failing := Smooth_Gpu{run = proc(data: rawptr, job: Smooth_Gpu_Job) -> bool {return false}}
	changed, on_gpu := sculptor_smooth_all(&a, 2, 0.5, failing)
	testing.expect(t, changed && !on_gpu)
	_, _ = sculptor_smooth_all(&b, 2, 0.5)
	testing.expect(t, slice.equal(m.positions[:], copy_m.positions[:]))
}

@(test)
smooth_all_is_refused_with_dynamic_topology :: proc(t: ^testing.T) {
	m := geom.icosphere(3)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	testing.expect(t, sculptor_dyn_enable(&s))
	changed, _ := sculptor_smooth_all(&s, 2, 0.5)
	testing.expect(t, !changed)
}
