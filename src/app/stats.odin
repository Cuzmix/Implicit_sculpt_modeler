package main

import "core:slice"

import "../render"

HISTORY :: 240

// Fixed-size ring of samples: recording never allocates.
Sample_Ring :: struct {
	values: [HISTORY]f32,
	head:   int,
	count:  int,
}

ring_push :: proc(r: ^Sample_Ring, v: f64) {
	r.values[r.head] = f32(v)
	r.head = (r.head + 1) % HISTORY
	r.count = min(r.count + 1, HISTORY)
}

// Median and 99th percentile, sorted on the stack.
ring_percentiles :: proc(r: Sample_Ring) -> (p50, p99: f32) {
	if r.count == 0 do return
	// Until the ring wraps, samples occupy the first `count` slots.
	sorted := r.values
	n := r.count
	slice.sort(sorted[:n])
	return sorted[n / 2], sorted[min(n - 1, n * 99 / 100)]
}

Frame_Stats :: struct {
	frame_ms:   Sample_Ring, // whole frame, start of event polling to after submit
	cpu_ms:     Sample_Ring, // events + UI
	// Recorded only on frames where the brush changed the mesh:
	raycast_ms: Sample_Ring,
	brush_ms:   Sample_Ring, // dabs, excluding the raycast
	normals_ms: Sample_Ring, // the per-frame flush that recomputes normals
	upload_kb:  Sample_Ring,
	latency_ms: Sample_Ring, // newest input event to command buffer submit
	dabs_total: int,
	viewport:      render.Viewport_Stats, // last frame
	cache_redraws: int,
}
