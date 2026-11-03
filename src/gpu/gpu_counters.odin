package gpu

import "core:sync"
import "core:time"

import sdl "vendor:sdl3"

// What the GPU seam did over the run, for the exit stats: the baseline the GPU abstraction's
// steps are measured against (notes/gpu-own-model/design.md, G0). Recording time is the CPU
// time from acquiring a command buffer to submitting or cancelling it, so it counts what the
// app records into it as well as the seam's own work. Whole-GPU waits and fence waits are
// the stalls a ring or a ticket would remove; memory allocations (Vulkan) are what a
// suballocator would fold into a few blocks.
Counters :: struct {
	command_buffers: int,
	encode_ns:       i64,
	idle_waits:      int,
	fence_waits:     int,
	allocations:     int,
	allocated_bytes: i64,
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
		cmd:   ^sdl.GPUCommandBuffer,
		start: time.Tick,
	},
}

// The run's counts so far.
counters :: proc() -> Counters {
	sync.mutex_lock(&counters.lock)
	defer sync.mutex_unlock(&counters.lock)
	return counters.total
}

// Notes that `cmd` was acquired now (nil, a refused acquire, is not counted).
count_acquire :: proc(cmd: ^sdl.GPUCommandBuffer) {
	if cmd == nil do return
	sync.mutex_lock(&counters.lock)
	defer sync.mutex_unlock(&counters.lock)
	for &o in counters.open do if o.cmd == nil {
		o.cmd, o.start = cmd, time.tick_now()
		return
	}
}

// Notes that `cmd` was submitted or cancelled now, adding its recording time.
count_finish :: proc(cmd: ^sdl.GPUCommandBuffer) {
	if cmd == nil do return
	sync.mutex_lock(&counters.lock)
	defer sync.mutex_unlock(&counters.lock)
	counters.total.command_buffers += 1
	for &o in counters.open do if o.cmd == cmd {
		counters.total.encode_ns += i64(time.tick_since(o.start))
		o.cmd = nil
		return
	}
}

count_idle_wait :: proc() {
	sync.mutex_lock(&counters.lock)
	defer sync.mutex_unlock(&counters.lock)
	counters.total.idle_waits += 1
}

count_fence_wait :: proc() {
	sync.mutex_lock(&counters.lock)
	defer sync.mutex_unlock(&counters.lock)
	counters.total.fence_waits += 1
}

count_allocation :: proc(bytes: i64) {
	sync.mutex_lock(&counters.lock)
	defer sync.mutex_unlock(&counters.lock)
	counters.total.allocations += 1
	counters.total.allocated_bytes += bytes
}
