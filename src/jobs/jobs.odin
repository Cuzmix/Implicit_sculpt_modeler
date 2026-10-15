// Package jobs is a minimal persistent worker pool for data-parallel loops on the
// sculpt hot path. After a job, workers spin briefly waiting for the next one before
// sleeping on a semaphore: a dab runs several parallel loops back to back, and waking
// a sleeping thread costs tens of microseconds, as much as a whole loop. Dispatching a
// parallel_for allocates nothing.
package jobs

import "base:intrinsics"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

Job_Proc :: #type proc(data: rawptr, index: int)

// How long an idle worker keeps polling for the next job before it sleeps.
SPIN_TIME :: 200 * time.Microsecond

Pool :: struct {
	threads:  [dynamic]^thread.Thread,
	wake:     sync.Sema,
	// Current job. The caller writes these, then publishes the job by storing `claim`.
	fn:       Job_Proc,
	data:     rawptr,
	count:    int,
	claim:    u64, // atomic: job generation << 32 | next index to claim
	pending:  int, // atomic: indices of the current job not yet finished
	sleepers: int, // atomic: workers that are or are about to be in sema_wait
	quit:     bool,
}

// Starts `workers` background threads (0 = one per extra CPU core). The calling
// thread also works during parallel_for, so total parallelism is workers + 1.
pool_init :: proc(p: ^Pool, workers := 0, allocator := context.allocator) {
	n := workers
	if n <= 0 do n = max(thread_count_hint() - 1, 0)
	p.threads = make([dynamic]^thread.Thread, 0, n, allocator)
	for _ in 0 ..< n {
		t := thread.create(worker_main)
		t.data = p
		thread.start(t)
		append(&p.threads, t)
	}
}

pool_destroy :: proc(p: ^Pool) {
	sync.atomic_store(&p.quit, true)
	sync.atomic_add(&p.claim, u64(1) << 32)
	sync.sema_post(&p.wake, len(p.threads))
	for t in p.threads {
		thread.join(t)
		thread.destroy(t)
	}
	delete(p.threads)
	p^ = {}
}

pool_size :: proc(p: ^Pool) -> int {
	return len(p.threads) + 1
}

// Calls fn(data, i) for every i in [0, count), spread across the pool, and returns
// when all calls are done. Indices are claimed one at a time, so uneven work
// balances. A nil pool runs the loop on the calling thread. Workers that are slow to
// wake never hold the caller up: whoever is running claims the work.
parallel_for :: proc(p: ^Pool, count: int, data: rawptr, fn: Job_Proc) {
	if count <= 0 do return
	if p == nil || count == 1 || len(p.threads) == 0 {
		for i in 0 ..< count do fn(data, i)
		return
	}
	job := u32(sync.atomic_load(&p.claim) >> 32) + 1
	sync.atomic_store_explicit(&p.fn, fn, .Relaxed)
	sync.atomic_store_explicit(&p.data, data, .Relaxed)
	sync.atomic_store_explicit(&p.count, count, .Relaxed)
	sync.atomic_store(&p.pending, count)
	sync.atomic_store(&p.claim, u64(job) << 32)
	// A worker counts itself a sleeper before re-checking `claim`, so either it sees the
	// new job or we see it here and wake it. Extra posts only cause a spurious wake.
	if sleepers := sync.atomic_load(&p.sleepers); sleepers > 0 {
		sync.sema_post(&p.wake, min(sleepers, count - 1))
	}
	run_claims(p, job)
	for sync.atomic_load(&p.pending) > 0 do intrinsics.cpu_relax()
}

// Runs indices of job `job` until none are left or a newer job replaced it. The job's
// fields are read before the claim is validated: a successful compare-exchange proves
// the job was still unfinished, so the caller had not yet overwritten them.
Range_Proc :: #type proc(data: rawptr, lo, hi: int)

// Calls fn(data, lo, hi) over consecutive chunks of [0, count) of about `grain`
// indices each, spread across the pool. For flat loops over big arrays.
parallel_ranges :: proc(p: ^Pool, count: int, data: rawptr, fn: Range_Proc, grain := 1 << 16) {
	Chunks :: struct {
		fn:    Range_Proc,
		data:  rawptr,
		count: int,
		grain: int,
	}
	c := Chunks{fn, data, count, max(grain, 1)}
	parallel_for(p, (count + c.grain - 1) / c.grain, &c, proc(data: rawptr, i: int) {
		c := cast(^Chunks)data
		lo := i * c.grain
		c.fn(c.data, lo, min(lo + c.grain, c.count))
	})
}

@(private)
run_claims :: proc(p: ^Pool, job: u32) {
	for {
		v := sync.atomic_load(&p.claim)
		if u32(v >> 32) != job do return
		fn := sync.atomic_load_explicit(&p.fn, .Relaxed)
		data := sync.atomic_load_explicit(&p.data, .Relaxed)
		count := sync.atomic_load_explicit(&p.count, .Relaxed)
		i := int(u32(v))
		if i >= count do return
		if _, ok := sync.atomic_compare_exchange_weak(&p.claim, v, v + 1); !ok do continue
		fn(data, i)
		sync.atomic_sub(&p.pending, 1)
	}
}

@(private)
worker_main :: proc(t: ^thread.Thread) {
	p := cast(^Pool)t.data
	seen: u32 = 0
	for {
		seen = wait_for_job(p, seen)
		if sync.atomic_load(&p.quit) do return
		run_claims(p, seen)
	}
}

// Returns the current job once it differs from `seen`: spins for SPIN_TIME, then
// sleeps until woken.
@(private)
wait_for_job :: proc(p: ^Pool, seen: u32) -> u32 {
	current :: #force_inline proc(p: ^Pool) -> u32 {return u32(sync.atomic_load(&p.claim) >> 32)}
	start := time.tick_now()
	for spins := 0;; spins += 1 {
		if job := current(p); job != seen do return job
		intrinsics.cpu_relax()
		if spins & 255 == 255 && time.tick_since(start) > SPIN_TIME do break
	}
	for {
		sync.atomic_add(&p.sleepers, 1)
		job := current(p)
		if job == seen do sync.sema_wait(&p.wake)
		sync.atomic_sub(&p.sleepers, 1)
		if job != seen do return job
		if job = current(p); job != seen do return job
	}
}

@(private)
thread_count_hint :: proc() -> int {
	return max(os.get_processor_core_count(), 1)
}
