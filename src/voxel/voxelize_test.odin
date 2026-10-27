package voxel

import "core:math"
import "core:math/linalg"
import "core:testing"

import "../geom"
import "../jobs"

// A voxelised unit sphere's surface lies within a voxel of radius 1 everywhere, and the
// field around it reads the distance to the sphere within a voxel through the band.
@(test)
voxelised_sphere_keeps_its_shape_within_a_voxel :: proc(t: ^testing.T) {
	sphere := geom.icosphere(4)
	defer geom.mesh_destroy(&sphere)
	for across in ([2]int{64, 128}) {
		_, bounds := geom.mesh_area_bounds(sphere)
		voxel := voxel_size_for(bounds, across)
		c: Clay
		testing.expect(t, clay_from_mesh(&c, sphere, voxel, nil), "voxelisation failed")
		defer clay_destroy(&c)
		m := clay_to_mesh(&c)
		defer geom.mesh_destroy(&m)
		report := geom.mesh_check(m)
		testing.expectf(t, report.closed && !report.inverted, "%d across: %v", across, report)
		worst: f32
		for p in m.positions do worst = max(worst, abs(linalg.length(p) - 1))
		testing.expectf(t, worst < voxel, "%d across: a vertex is %.4f from the sphere (a voxel is %.4f)", across, worst, voxel)
		expected := 4 * math.PI / 3
		testing.expectf(t, abs(report.volume - expected) < 0.05 * expected, "%d across: volume %.3f", across, report.volume)
		for dir in ([3]Vec3{{0, 0, 1}, linalg.normalize(Vec3{1, 1, 1}), linalg.normalize(Vec3{-2, 1, 3})}) {
			for d in ([5]f32{-2.5, -1, 0, 1, 2.5}) {
				got := volume_sample(&c.volume, dir * (1 + d * voxel))
				testing.expectf(t, abs(got - d) < 1, "%d across: at %v voxels along %v the field reads %v", across, d, dir, got)
			}
		}
	}
}

// A torus stays a torus: one closed surface with a hole (Euler characteristic 0), of about
// the torus's volume.
@(test)
voxelised_torus_keeps_its_hole :: proc(t: ^testing.T) {
	torus := geom.torus_grid(96, 48, 1, 0.4)
	defer geom.mesh_destroy(&torus)
	_, bounds := geom.mesh_area_bounds(torus)
	c: Clay
	testing.expect(t, clay_from_mesh(&c, torus, voxel_size_for(bounds, 128), nil), "voxelisation failed")
	defer clay_destroy(&c)
	m := clay_to_mesh(&c)
	defer geom.mesh_destroy(&m)
	report := geom.mesh_check(m)
	testing.expectf(t, report.closed && !report.inverted, "%v", report)
	// Closed: E = 3F / 2, so V − E + F = V − F / 2.
	testing.expectf(t, report.vertices * 2 == report.triangles, "V %d, F %d: not a torus", report.vertices, report.triangles)
	expected := 2 * math.PI * math.PI * 1 * 0.4 * 0.4
	testing.expectf(t, abs(report.volume - expected) < 0.1 * expected, "volume %.3f, a torus's is %.3f", report.volume, expected)
}

// A cube whose faces lie exactly on voxel rows (the lattice is centred, so ±32 voxels are
// lattice points) comes through closed, with its volume, and its surface within a voxel of
// the faces: the crossings on the rows are kept off the lattice points by the margin.
@(test)
voxelised_cube_keeps_its_faces_on_the_lattice :: proc(t: ^testing.T) {
	cube, ok := geom.cube_grid(8, 0.8, nil)
	testing.expect(t, ok)
	defer geom.mesh_destroy(&cube)
	_, bounds := geom.mesh_area_bounds(cube)
	voxel := voxel_size_for(bounds, 64)
	c: Clay
	testing.expect(t, clay_from_mesh(&c, cube, voxel, nil), "voxelisation failed")
	defer clay_destroy(&c)
	m := clay_to_mesh(&c)
	defer geom.mesh_destroy(&m)
	report := geom.mesh_check(m)
	testing.expectf(t, report.closed && !report.inverted, "%v", report)
	worst: f32
	for p in m.positions do worst = max(worst, abs(max(abs(p.x), abs(p.y), abs(p.z)) - 0.8))
	testing.expectf(t, worst < voxel, "a vertex is %.4f from the cube's faces (a voxel is %.4f)", worst, voxel)
	expected := 1.6 * 1.6 * 1.6
	testing.expectf(t, abs(report.volume - expected) < 0.05 * expected, "volume %.3f", report.volume)
}

// The field is the same bit for bit with and without worker threads.
@(test)
voxelisation_is_the_same_serial_and_parallel :: proc(t: ^testing.T) {
	sphere := geom.icosphere(3)
	defer geom.mesh_destroy(&sphere)
	_, bounds := geom.mesh_area_bounds(sphere)
	voxel := voxel_size_for(bounds, 96)
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	serial, parallel: Clay
	testing.expect(t, clay_from_mesh(&serial, sphere, voxel, nil))
	defer clay_destroy(&serial)
	testing.expect(t, clay_from_mesh(&parallel, sphere, voxel, &pool))
	defer clay_destroy(&parallel)
	testing.expect_value(t, clay_hash(&parallel), clay_hash(&serial))
	testing.expect_value(t, volume_brick_count(&parallel.volume), volume_brick_count(&serial.volume))
}

// Nothing to voxelise, or too much, is refused with the clay left empty.
@(test)
voxelisation_refuses_what_it_cannot_hold :: proc(t: ^testing.T) {
	empty: geom.Mesh
	c: Clay
	testing.expect(t, !clay_from_mesh(&c, empty, 0.1, nil), "an empty mesh was voxelised")
	sphere := geom.icosphere(2)
	defer geom.mesh_destroy(&sphere)
	testing.expect(t, !clay_from_mesh(&c, sphere, 0, nil), "a zero voxel was accepted")
	testing.expect(t, !clay_from_mesh(&c, sphere, 2.0 / (VOXELIZE_MAX + 8), nil), "a lattice past VOXELIZE_MAX was accepted")
	testing.expect(t, c.volume.chunks == nil, "a refused clay was left initialised")
}
