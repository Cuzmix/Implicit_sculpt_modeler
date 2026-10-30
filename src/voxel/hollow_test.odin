package voxel

import "core:math"
import "core:math/linalg"
import "core:testing"

import "../geom"
import "../jobs"

// A unit sphere hollowed 0.1 thick has its inside wall at radius 0.9 within a twentieth
// of the wall, facing inward, so the two together are one closed solid of the shell's volume;
// serial and parallel runs make the same wall.
@(test)
hollowed_sphere_has_an_even_wall :: proc(t: ^testing.T) {
	sphere := geom.icosphere(5)
	defer geom.mesh_destroy(&sphere)
	pool: jobs.Pool
	jobs.pool_init(&pool, 4)
	defer jobs.pool_destroy(&pool)
	inner, ok := hollow_inner(sphere, 0.1, nil)
	defer geom.mesh_destroy(&inner)
	if !testing.expect(t, ok && len(inner.indices) > 0, "no inside wall") do return
	worst: f32
	for p in inner.positions do worst = max(worst, abs(linalg.length(p) - 0.9))
	testing.expectf(t, worst < 0.005, "a vertex of the inside wall is %.4f from radius 0.9", worst)
	report := geom.mesh_check(inner)
	testing.expectf(t, report.closed && report.inverted, "the inside wall is not closed and facing inward: %v", report)

	// Outer and inner as one mesh: closed, of the shell's volume.
	both: geom.Mesh
	defer geom.mesh_destroy(&both)
	append(&both.positions, ..sphere.positions[:])
	append(&both.positions, ..inner.positions[:])
	append(&both.indices, ..sphere.indices[:])
	for i in inner.indices do append(&both.indices, i + u32(len(sphere.positions)))
	whole := geom.mesh_check(both)
	shell := 4 * math.PI / 3 * (1 - 0.9 * 0.9 * 0.9)
	testing.expectf(t, whole.closed && !whole.inverted && abs(whole.volume - shell) < 0.05 * shell, "the hollow sphere: %v, its shell is %.3f", whole, shell)

	parallel, pok := hollow_inner(sphere, 0.1, &pool)
	defer geom.mesh_destroy(&parallel)
	testing.expect(t, pok && slice_equal(parallel.positions[:], inner.positions[:]) && slice_equal(parallel.indices[:], inner.indices[:]), "parallel hollowing differs")
}

// A plate thinner than two walls has no inside wall; a wall too thin for the voxels the
// object would need, or not positive, is refused.
@(test)
hollow_leaves_thin_parts_solid :: proc(t: ^testing.T) {
	plate, made := geom.cube_grid(8, 1, nil)
	defer geom.mesh_destroy(&plate)
	if !testing.expect(t, made) do return
	for &p in plate.positions do p.z *= 0.075
	inner, ok := hollow_inner(plate, 0.1, nil)
	defer geom.mesh_destroy(&inner)
	testing.expectf(t, ok && len(inner.indices) == 0, "a plate 0.15 thick got an inside wall of %d triangles", len(inner.indices) / 3)
	_, fine := hollow_inner(plate, 1e-4, nil)
	testing.expect(t, !fine, "a wall needing more voxels than the most was hollowed")
	_, zero := hollow_inner(plate, 0, nil)
	testing.expect(t, !zero, "a wall of 0 was hollowed")
}

@(private = "file")
slice_equal :: proc(a, b: []$T) -> bool {
	if len(a) != len(b) do return false
	for x, i in a do if x != b[i] do return false
	return true
}
