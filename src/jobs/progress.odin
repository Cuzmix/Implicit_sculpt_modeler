package jobs

import "core:sync"

// How far a long piece of work running on another thread has come, and whether the thread
// that started it asked it to stop. The worker writes the share done and reads the cancel;
// the starter reads the share (to draw it) and writes the cancel. Both are single atomics,
// so a check inside a loop costs one load. Every proc takes nil and then does nothing, so
// long procs take a `^Progress = nil` and their other callers pass nothing.
Progress :: struct {
	done:   u32, // atomic: parts of PROGRESS_SCALE
	cancel: bool, // atomic
}

PROGRESS_SCALE :: 1 << 16

// Sets the share done to `k` (0 to 1) of the way through the stage from `from` to `to`
// (shares of the whole), so a proc with several stages moves one ring evenly.
progress_set :: proc(p: ^Progress, from, to, k: f32) {
	if p == nil do return
	share := clamp(from + (to - from) * clamp(k, 0, 1), 0, 1)
	sync.atomic_store(&p.done, u32(share * PROGRESS_SCALE))
}

// The share done, 0 to 1.
progress_get :: proc(p: ^Progress) -> f32 {
	if p == nil do return 0
	return f32(sync.atomic_load(&p.done)) / PROGRESS_SCALE
}

// Asks the work to stop at its next check.
progress_cancel :: proc(p: ^Progress) {
	if p == nil do return
	sync.atomic_store(&p.cancel, true)
}

// Whether the work was asked to stop; a long proc returns as not built at the next check
// that finds it so, freeing what it made.
progress_cancelled :: proc(p: ^Progress) -> bool {
	if p == nil do return false
	return sync.atomic_load(&p.cancel)
}
