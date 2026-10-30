package geom

import "core:slice"
import "core:testing"

import "../jobs"

// A remesh and a decimation told to report progress build exactly what they build without
// it, end with the whole done, and stop with nothing to free when cancelled.
@(test)
long_procs_report_progress_and_stop_when_cancelled :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	sphere := icosphere(5)
	defer mesh_destroy(&sphere)
	area, bounds := mesh_area_bounds(sphere, &pool)

	plain, plain_ok := remesh_voxel_measured(sphere, area, bounds, 20_000, &pool)
	defer mesh_destroy(&plain)
	p: jobs.Progress
	told, told_ok := remesh_voxel_measured(sphere, area, bounds, 20_000, &pool, progress = &p)
	defer mesh_destroy(&told)
	testing.expect(t, plain_ok && told_ok, "a remesh failed")
	testing.expect(t, slice.equal(plain.positions[:], told.positions[:]) && slice.equal(plain.indices[:], told.indices[:]), "progress changed the remesh")
	testing.expectf(t, jobs.progress_get(&p) == 1, "a finished remesh says %v done", jobs.progress_get(&p))

	stop: jobs.Progress
	jobs.progress_cancel(&stop)
	_, cancelled_ok := remesh_voxel_measured(sphere, area, bounds, 20_000, &pool, progress = &stop)
	testing.expect(t, !cancelled_ok, "a cancelled remesh built")

	few, few_err, few_ok := mesh_decimate(sphere, 2_000, &pool)
	defer mesh_destroy(&few)
	d: jobs.Progress
	told_few, told_err, told_few_ok := mesh_decimate(sphere, 2_000, &pool, progress = &d)
	defer mesh_destroy(&told_few)
	testing.expect(t, few_ok && told_few_ok && few_err == told_err, "a decimation failed or differed")
	testing.expect(t, slice.equal(few.positions[:], told_few.positions[:]) && slice.equal(few.indices[:], told_few.indices[:]), "progress changed the decimation")
	testing.expect(t, jobs.progress_get(&d) > 0.5, "a decimation said nothing of its progress")
	_, _, stopped_ok := mesh_decimate(sphere, 2_000, &pool, progress = &stop)
	testing.expect(t, !stopped_ok, "a cancelled decimation built")
}
