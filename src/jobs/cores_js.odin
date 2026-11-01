#+build js
package jobs

// The web build runs on the browser's main thread: Odin's js runtime starts no threads,
// so the pool has no workers and every parallel_for runs its loop on the calling thread.
// Serial and parallel results are bit-identical, so the web sculpts exactly as the
// desktop does, only more slowly.
@(private)
thread_count_hint :: proc() -> int {
	return 1
}
