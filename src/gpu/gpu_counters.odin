package gpu

import "core:sync"
import "core:time"


// What the GPU seam did over the run, for the exit stats: the baseline the GPU abstraction's
// steps are measured against (notes/gpu-own-model/design.md, G0). Recording time is the CPU
// time from acquiring a command buffer to submitting or cancelling it, less the time spent in
// it waiting for a swapchain image (the display), so it counts what the app records into it
// as well as the seam's own work, and not vsync. Whole-GPU waits and waits on a ticket
// not yet done are the CPU's stalls on the GPU; memory allocations (Vulkan) are the blocks
// resources share and large resources' own memory (vk_memory.odin); barriers (Vulkan) are the
// whole-memory barriers recorded, to which copies of a copy pass into separate buffer ranges
// add none.
Counters :: struct {
	command_buffers: int,
	encode_ns:       i64,
	idle_waits:      int,
	ticket_waits:    int,
	allocations:     int,
	allocated_bytes: i64,
	barriers:        int,
}

// Command buffers being recorded and when each was acquired: a few at a time (a frame's, a
// readback's, an upload's), so a short list is enough. One older than the list's room is
// left out of the recording time rather than misplaced.
@(private = "file")
OPEN_MAX :: 16

@(private = "file")
counters: struct {
	lock:  sync.Mutex,
	total: Counters,
	open:  [OPEN_MAX]struct {
		cmd:    Cmd,
		start:  time.Tick,
		paused: time.Duration, // waiting for the display while it was open
	},
}

// The run's counts so far.
counters :: proc() -> Counters {
	sync.mutex_lock(&counters.lock)
	defer sync.mutex_unlock(&counters.lock)
	return counters.total
}

// Notes that `cmd` was acquired now (nil, a refused acquire, is not counted).
count_acquire :: proc(cmd: Cmd) {
	if cmd == nil do return
	sync.mutex_lock(&counters.lock)
	defer sync.mutex_unlock(&counters.lock)
	for &o in counters.open do if o.cmd == nil {
		o.cmd, o.start, o.paused = cmd, time.tick_now(), 0
		return
	}
}

// Notes that `cmd` was submitted or cancelled now, adding its recording time.
count_finish :: proc(cmd: Cmd) {
	if cmd == nil do return
	sync.mutex_lock(&counters.lock)
	defer sync.mutex_unlock(&counters.lock)
	counters.total.command_buffers += 1
	for &o in counters.open do if o.cmd == cmd {
		counters.total.encode_ns += i64(max(time.tick_since(o.start) - o.paused, 0))
		o.cmd = nil
		return
	}
}

// Notes that `cmd`, open, spent `waited` waiting for a swapchain image, which its recording
// time leaves out.
count_pause :: proc(cmd: Cmd, waited: time.Duration) {
	if cmd == nil do return
	sync.mutex_lock(&counters.lock)
	defer sync.mutex_unlock(&counters.lock)
	for &o in counters.open do if o.cmd == cmd {
		o.paused += waited
		return
	}
}

// One whole-memory barrier recorded: atomic rather than locked, as a frame records many.
count_barrier :: proc() {
	sync.atomic_add(&counters.total.barriers, 1)
}

count_idle_wait :: proc() {
	sync.mutex_lock(&counters.lock)
	defer sync.mutex_unlock(&counters.lock)
	counters.total.idle_waits += 1
}

count_wait :: proc() {
	sync.mutex_lock(&counters.lock)
	defer sync.mutex_unlock(&counters.lock)
	counters.total.ticket_waits += 1
}

count_allocation :: proc(bytes: i64) {
	sync.mutex_lock(&counters.lock)
	defer sync.mutex_unlock(&counters.lock)
	counters.total.allocations += 1
	counters.total.allocated_bytes += bytes
}
