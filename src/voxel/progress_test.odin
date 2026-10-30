package voxel

import "core:testing"

import "../geom"
import "../jobs"

// Voxelising a mesh and resampling clay told to report progress make exactly what they make
// without it, end with the whole done, and stop with nothing to free when cancelled; a
// resample beside the clay leaves the clay as it was until it is put in its place.
@(test)
long_voxel_procs_report_progress_and_stop_when_cancelled :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	sphere := geom.icosphere(4)
	defer geom.mesh_destroy(&sphere)
	_, bounds := geom.mesh_area_bounds(sphere)
	voxel := voxel_size_for(bounds, 96)

	plain, told: Clay
	testing.expect(t, clay_from_mesh(&plain, sphere, voxel, &pool), "voxelisation failed")
	defer clay_destroy(&plain)
	p: jobs.Progress
	testing.expect(t, clay_from_mesh(&told, sphere, voxel, &pool, progress = &p), "voxelisation with progress failed")
	defer clay_destroy(&told)
	testing.expect_value(t, clay_hash(&told), clay_hash(&plain))
	testing.expectf(t, jobs.progress_get(&p) == 1, "a finished voxelisation says %v done", jobs.progress_get(&p))

	stop: jobs.Progress
	jobs.progress_cancel(&stop)
	stopped: Clay
	testing.expect(t, !clay_from_mesh(&stopped, sphere, voxel, &pool, progress = &stop), "a cancelled voxelisation built")

	before := clay_hash(&told)
	r: jobs.Progress
	beside, ok := clay_resampled(&told, RESAMPLE_UP, &pool, &r)
	testing.expect(t, ok, "the resample beside the clay was refused")
	testing.expect_value(t, clay_hash(&told), before)
	testing.expectf(t, jobs.progress_get(&r) == 1, "a finished resample says %v done", jobs.progress_get(&r))
	testing.expect(t, clay_resample(&plain, RESAMPLE_UP), "the resample in place was refused")
	testing.expect_value(t, clay_hash(&beside), clay_hash(&plain))
	clay_destroy(&beside)
	_, stopped_ok := clay_resampled(&told, RESAMPLE_UP, &pool, &stop)
	testing.expect(t, !stopped_ok, "a cancelled resample built")
}
