package jobs

import "core:sync"
import "core:testing"

@(test)
parallel_for_visits_every_index_once :: proc(t: ^testing.T) {
	p: Pool
	pool_init(&p, 3)
	defer pool_destroy(&p)
	hits := make([]i32, 10_000, context.temp_allocator)
	for _ in 0 ..< 50 { 	// repeat to catch dispatch races between jobs
		parallel_for(&p, len(hits), raw_data(hits), proc(data: rawptr, i: int) {
			h := cast([^]i32)data
			sync.atomic_add(&h[i], 1)
		})
	}
	for h in hits do testing.expect_value(t, h, 50)
}

@(test)
parallel_ranges_cover_every_index_once :: proc(t: ^testing.T) {
	p: Pool
	pool_init(&p, 3)
	defer pool_destroy(&p)
	hits := make([]i32, 100_003, context.temp_allocator)
	parallel_ranges(&p, len(hits), raw_data(hits), proc(data: rawptr, lo, hi: int) {
		h := cast([^]i32)data
		for i in lo ..< hi do sync.atomic_add(&h[i], 1)
	}, 1000)
	for h in hits do testing.expect_value(t, h, 1)
}

// Progress moves within a stage's share, reads back, and a nil one does nothing.
@(test)
progress_reports_shares_and_cancel :: proc(t: ^testing.T) {
	p: Progress
	progress_set(&p, 0.2, 0.6, 0.5)
	testing.expectf(t, abs(progress_get(&p) - 0.4) < 1e-4, "halfway through 0.2 to 0.6 reads %v", progress_get(&p))
	testing.expect(t, !progress_cancelled(&p), "cancelled before asked")
	progress_cancel(&p)
	testing.expect(t, progress_cancelled(&p), "not cancelled once asked")
	progress_set(nil, 0, 1, 1)
	progress_cancel(nil)
	testing.expect(t, progress_get(nil) == 0 && !progress_cancelled(nil), "a nil progress said something")
}
