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
	frame_ms:   Sample_Ring, // whole frame, waits included
	cpu_ms:     Sample_Ring, // the frame minus its waits
	wait_ms:    Sample_Ring, // waiting for the display (and, while timing the GPU, for the previous frame)
	gpu_ms:     Sample_Ring, // GPU time of the 3D viewport's uploads and drawing; only while timing the GPU
	// Recorded only on frames where the brush changed the mesh:
	raycast_ms: Sample_Ring,
	brush_ms:   Sample_Ring, // dabs, excluding the raycast
	normals_ms: Sample_Ring, // the per-frame flush that recomputes normals
	upload_kb:  Sample_Ring,
	latency_ms: Sample_Ring, // newest input event to command buffer submit
	dabs_total: int,
	viewport:      render.Viewport_Stats, // last frame
	cache_redraws: int,
	partial_frames: int, // frames that kept the previous image and redrew only what changed
	// The last change of subdivision level: bringing the levels up to date (or building
	// a new one), then the new level's normals and GPU buffers.
	level_sync_ms:  f64,
	level_show_ms:  f64,
}
