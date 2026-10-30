package render

import vk "vendor:vulkan"

// GPU timestamps for the own Vulkan backend (Gpu_Caps.timestamps): each frame writes its
// timestamps into a query pool of its own, and the pool is read when it comes round again,
// VK_TIMING_SLOTS frames later, by when its frame has long finished. Nothing waits for the
// GPU, so frames overlap as they do without timing, unlike --time-gpu.
//
// The pools are reset from the CPU (hostQueryReset, core in Vulkan 1.2) before a frame
// writes into them; a query a cancelled command buffer never wrote reads as unavailable
// and is left out.

// More slots than frames may be in flight, so a slot's frame is done by the time it is reused.
VK_TIMING_SLOTS :: FRAMES_IN_FLIGHT_MAX + 1

Vk_Timing_Slot :: struct {
	pool:   vk.QueryPool,
	tags:   [TIMESTAMPS_MAX]u8,
	count:  u32,
	serial: u64, // the newest submission that wrote into the pool
}

Vk_Timing :: struct {
	slots:     [VK_TIMING_SLOTS]Vk_Timing_Slot,
	current:   int,
	open:      bool, // the current slot takes this frame's timestamps
	period_ns: f64,  // nanoseconds a timestamp tick
	mask:      u64,  // the bits a timestamp holds (timestampValidBits)
}

// Makes the pools where the device can time both graphics and compute on its queue;
// false (and no timestamps) otherwise.
vk_timing_init :: proc(valid_bits: u32) -> bool {
	t := &vk_state.timing
	if valid_bits == 0 || !vk_state.properties.limits.timestampComputeAndGraphics || vk_state.properties.limits.timestampPeriod <= 0 do return false
	t.period_ns = f64(vk_state.properties.limits.timestampPeriod)
	t.mask = max(u64) if valid_bits >= 64 else (u64(1) << valid_bits) - 1
	info := vk.QueryPoolCreateInfo{sType = .QUERY_POOL_CREATE_INFO, queryType = .TIMESTAMP, queryCount = TIMESTAMPS_MAX}
	for &s in t.slots {
		if vk.CreateQueryPool(vk_state.device, &info, nil, &s.pool) != .SUCCESS {
			vk_timing_destroy()
			return false
		}
		vk.ResetQueryPool(vk_state.device, s.pool, 0, TIMESTAMPS_MAX)
	}
	t.open = true
	return true
}

vk_timing_destroy :: proc() {
	for s in vk_state.timing.slots do if s.pool != 0 do vk.DestroyQueryPool(vk_state.device, s.pool, nil)
	vk_state.timing = {}
}

vk_write_timestamp :: proc(command_buffer: ^Vk_Cmd, tag: u8) {
	t := &vk_state.timing
	s := &t.slots[t.current]
	if !t.open || s.count == TIMESTAMPS_MAX do return
	vk.CmdWriteTimestamp2(command_buffer.cb, {.ALL_COMMANDS}, s.pool, s.count)
	s.tags[s.count] = tag
	s.count += 1
	command_buffer.timed_slot = t.current + 1
}

// Called by vk_submit with the submission's serial.
vk_timing_submitted :: proc(command_buffer: ^Vk_Cmd, serial: u64) {
	if command_buffer.timed_slot == 0 do return
	s := &vk_state.timing.slots[command_buffer.timed_slot - 1]
	s.serial = max(s.serial, serial)
	command_buffer.timed_slot = 0
}

// Starts a frame's timestamps and hands back the oldest slot's, the frame VK_TIMING_SLOTS
// back, into `out` in the order they were written; how many. When that frame is somehow
// still on the GPU this frame goes untimed rather than wait.
vk_timestamps_frame :: proc(out: []Gpu_Timestamp) -> int {
	t := &vk_state.timing
	if t.slots[0].pool == 0 do return 0
	next := (t.current + 1) % VK_TIMING_SLOTS
	s := &t.slots[next]
	vk_collect()
	if s.serial > vk_state.completed {
		t.open = false
		return 0
	}
	n := 0
	if s.count > 0 {
		// Each query's value and then whether it is available.
		results: [TIMESTAMPS_MAX][2]u64
		r := vk.GetQueryPoolResults(vk_state.device, s.pool, 0, s.count, size_of(results), &results, size_of(results[0]), {._64, .WITH_AVAILABILITY})
		if r == .SUCCESS || r == .NOT_READY {
			for i in 0 ..< int(s.count) {
				if results[i][1] == 0 || n == len(out) do continue
				out[n] = {s.tags[i], f64(results[i][0] & t.mask) * t.period_ns}
				n += 1
			}
		}
		vk.ResetQueryPool(vk_state.device, s.pool, 0, s.count)
	}
	s.count, s.serial = 0, 0
	t.current, t.open = next, true
	return n
}
