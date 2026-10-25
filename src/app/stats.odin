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
	lod_ms:     Sample_Ring, // building and uploading simplified copies, on frames that did
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
	// The last HD window: building it, uploading it, and storing it on leaving.
	hd_open_ms:     f64,
	hd_upload_ms:   f64,
	hd_leave_ms:    f64,
	// The last remesh: building the new surface, then preparing it to sculpt and upload.
	remesh_ms:      f64,
	remesh_setup_ms: f64,
	// The last slice: cutting and capping, then preparing both parts to sculpt and upload.
	slice_ms:       f64,
	slice_setup_ms: f64,
	// The last decimation, and how far from the surface it went at most.
	decimate_ms:    f64,
	decimate_error: f32,
	// The last file read (import or open: reading and, for imports, parsing) and the
	// last one written (export or save, formatting included).
	file_read_ms:   f64,
	file_parse_ms:  f64,
	file_write_ms:  f64,
	// The last time dynamic topology was turned on or off: converting the mesh, then
	// uploading it; and how often its growth has called for bigger GPU buffers.
	dyntopo_ms:        f64,
	dyntopo_upload_ms: f64,
	gpu_regrows:       int,
}
