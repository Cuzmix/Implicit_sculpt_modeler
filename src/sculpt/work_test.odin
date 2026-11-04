package sculpt

import "core:testing"

import "../geom"
import "../jobs"

// The work of one recorded stroke of `dabs` Draw dabs across the front of an icosphere.
@(private = "file")
stroke_work :: proc(pool: ^jobs.Pool, dabs: int) -> (w: Work_Counts, moved: u64) {
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, pool, 64)
	defer sculptor_destroy(&s)
	_ = sculptor_flush(&s)
	_ = sculptor_work_take(&s) // the first flush's whole-mesh normals are setup, not sculpting
	sculptor_stroke_begin(&s)
	for i in 0 ..< dabs {
		x := -0.4 + 0.8 * f32(i) / f32(dabs - 1)
		moved += u64(apply_dab(&s, {kind = .Draw, radius = 0.2, strength = 0.5}, {x, 0, 1}))
		_ = sculptor_flush(&s)
	}
	_ = sculptor_stroke_end(&s)
	return sculptor_work_take(&s), moved
}

@(test)
work_counts_bound_what_the_dabs_moved :: proc(t: ^testing.T) {
	w, moved := stroke_work(nil, 6)
	testing.expect_value(t, w.dabs, 6)
	testing.expect_value(t, w.moved, moved)
	testing.expectf(t, moved > 0 && w.scanned >= w.moved, "scanned %d, moved %d", w.scanned, w.moved)
	// A flush follows each dab, and every vertex a dab moved belongs to a node whose shape
	// changed, which recomputes all its normals.
	testing.expectf(t, w.renormalised >= w.moved, "renormalised %d of %d moved", w.renormalised, w.moved)
	testing.expectf(t, w.saved > 0 && w.saved <= w.scanned, "saved %d, scanned %d", w.saved, w.scanned)
}

@(test)
work_counts_are_the_same_serial_and_parallel :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	serial, _ := stroke_work(nil, 6)
	parallel, _ := stroke_work(&pool, 6)
	testing.expect_value(t, parallel, serial)
}

@(test)
taking_the_work_counts_starts_them_again :: proc(t: ^testing.T) {
	m := geom.icosphere(3)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	_ = apply_dab(&s, {kind = .Draw, radius = 0.3, strength = 0.5}, {0, 0, 1})
	testing.expect(t, sculptor_work_take(&s).dabs == 1, "the dab was not counted")
	testing.expect_value(t, sculptor_work_take(&s), Work_Counts{})
}
