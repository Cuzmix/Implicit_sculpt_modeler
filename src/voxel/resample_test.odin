package voxel

import "core:math"
import "core:math/linalg"
import "core:testing"

import "../geom"
import "../jobs"

// Res+ keeps the surface where it was: a sphere at 128 across resampled to 256 stays
// closed, within a quarter of a new voxel of radius 1 on average, and no vertex strays a
// whole voxel; the field around it still reads the distance.
@(test)
resampling_up_keeps_the_surface_within_a_quarter_voxel :: proc(t: ^testing.T) {
	c: Clay
	clay_init(&c, 2.0 / 128, {}, nil)
	defer clay_destroy(&c)
	clay_fill_sphere(&c, {}, 1)
	before := volume_brick_count(&c.volume)
	testing.expect(t, clay_resample(&c, RESAMPLE_UP), "the resample was refused")
	testing.expect_value(t, c.volume.voxel, f32(2.0 / 256))
	testing.expectf(t, volume_brick_count(&c.volume) > 2 * before, "bricks %d before, %d after", before, volume_brick_count(&c.volume))
	m := clay_to_mesh(&c)
	defer geom.mesh_destroy(&m)
	report := geom.mesh_check(m)
	testing.expectf(t, report.closed && !report.inverted, "%v", report)
	voxel := c.volume.voxel
	worst, sum: f32
	for p in m.positions {
		e := abs(linalg.length(p) - 1)
		worst = max(worst, e)
		sum += e * e
	}
	rms := math.sqrt(sum / f32(len(m.positions)))
	testing.expectf(t, rms < 0.25 * voxel && worst < voxel, "rms %.5f, worst %.5f, a voxel is %.5f", rms, worst, voxel)
	for d in ([4]f32{-2.5, -1, 1, 2.5}) {
		got := volume_sample(&c.volume, Vec3{0, 0, 1 + d * voxel})
		testing.expectf(t, abs(got - d) < 0.5, "at %v voxels the field reads %v", d, got)
	}
}

// Res− then Res+ brings a sphere back to its lattice within a coarse voxel, with its
// volume; a resample is the same bit for bit with and without worker threads.
@(test)
resampling_down_and_up_round_trips_within_a_coarse_voxel :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	serial, parallel: Clay
	clay_init(&serial, 2.0 / 128, {}, nil)
	defer clay_destroy(&serial)
	clay_init(&parallel, 2.0 / 128, {}, &pool)
	defer clay_destroy(&parallel)
	clay_fill_sphere(&serial, {}, 1)
	clay_fill_sphere(&parallel, {}, 1)
	testing.expect(t, clay_resample(&serial, RESAMPLE_DOWN) && clay_resample(&parallel, RESAMPLE_DOWN))
	testing.expect_value(t, clay_hash(&parallel), clay_hash(&serial))
	coarse := serial.volume.voxel
	testing.expect_value(t, coarse, f32(2.0 / 64))
	testing.expect(t, clay_resample(&serial, RESAMPLE_UP) && clay_resample(&parallel, RESAMPLE_UP))
	testing.expect_value(t, clay_hash(&parallel), clay_hash(&serial))
	testing.expect_value(t, serial.volume.voxel, f32(2.0 / 128))
	m := clay_to_mesh(&serial)
	defer geom.mesh_destroy(&m)
	report := geom.mesh_check(m)
	testing.expectf(t, report.closed && !report.inverted, "%v", report)
	worst: f32
	for p in m.positions do worst = max(worst, abs(linalg.length(p) - 1))
	testing.expectf(t, worst < coarse, "a vertex is %.4f from the sphere (a coarse voxel is %.4f)", worst, coarse)
	expected := 4 * math.PI / 3
	testing.expectf(t, abs(report.volume - expected) < 0.03 * expected, "volume %.3f", report.volume)
}

// Res+ halves the domain in object space: clay that would leave it, or come within the band
// of its edge, is refused and left as it was; a wrong factor is refused too.
@(test)
resampling_refuses_clay_the_smaller_domain_cannot_hold :: proc(t: ^testing.T) {
	voxel := f32(2.0 / 256) // the domain spans ±16 in object space, ±8 after ×2
	c: Clay
	clay_init(&c, voxel, {}, nil)
	defer clay_destroy(&c)
	clay_fill_sphere(&c, {9, 0, 0}, 0.5)
	hash := clay_hash(&c)
	testing.expect(t, !clay_resample(&c, RESAMPLE_UP), "a sphere past the halved domain was resampled")
	testing.expect_value(t, clay_hash(&c), hash)
	testing.expect_value(t, c.volume.voxel, voxel)
	testing.expect(t, !clay_resample(&c, 3), "a factor of 3 was taken")
	testing.expect(t, clay_resample(&c, RESAMPLE_DOWN), "Res- was refused")
	fits: Clay
	clay_init(&fits, voxel, {}, nil)
	defer clay_destroy(&fits)
	clay_fill_sphere(&fits, {3, 0, 0}, 0.5)
	testing.expect(t, clay_resample(&fits, RESAMPLE_UP), "a sphere well inside the halved domain was refused")
}
