package main

import "core:reflect"
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
	// From one frame's start to the next's: what the screen's pace is made of, including
	// the work after the submit (autosave, simplified copies and any GPU wait in them)
	// that frame_ms ends before.
	interval_ms: Sample_Ring,
	cpu_ms:     Sample_Ring, // the frame minus its waits
	wait_ms:    Sample_Ring, // waiting for the display (and, while timing the GPU, for the previous frame)
	gpu_ms:     Sample_Ring, // GPU time of the 3D viewport's uploads and drawing; only while timing the GPU
	// GPU time by pass from timestamps (render.Gpu_Times), a few frames late and without
	// waiting; [.None] is the frame's whole GPU time. Only where render.caps has timestamps.
	gpu_spans:  [render.Gpu_Span]Sample_Ring,
	// The 3D viewport's share of the newest timestamped frame (every span but the
	// interface's), what gpu_ms measures by waiting; 0 until one comes back.
	gpu_viewport_stamped_ms: f64,
	lod_ms:     Sample_Ring, // building and uploading simplified copies, on frames that did
	ui_ms:      Sample_Ring, // the interface's layout and tessellation, CPU
	ui_vertices: int, // the interface's vertices last frame
	cursor_ms:  Sample_Ring, // laying the brush ring on the surface: its raycast and area normal, on frames that did
	// Recorded only on frames where the brush changed the mesh:
	raycast_ms: Sample_Ring,
	brush_ms:   Sample_Ring, // dabs, excluding the raycast
	normals_ms: Sample_Ring, // the per-frame flush that recomputes normals
	upload_kb:  Sample_Ring,
	latency_ms: Sample_Ring, // newest input event to command buffer submit
	display_ms: Sample_Ring, // newest input event to the frame on the screen, where the backend can tell (render.Present_Timing)
	// Sculpt on the GPU, on frames a readback landed: its size, the time to copy it into
	// the mesh and the time to refit the bounds of what landed (sculptor_positions_landed).
	gpu_sculpt_kb:       Sample_Ring,
	gpu_sculpt_apply_ms: Sample_Ring,
	gpu_sculpt_land_ms:  Sample_Ring,
	dabs_total: int,
	viewport:      render.Viewport_Stats, // last frame
	cache_redraws: int,
	partial_frames: int, // frames that kept the previous image and redrew only what changed
	cmds_dropped: int, // command buffers dropped for holding nothing (frame_submit): the GPU slept through them
	// The last change of subdivision level: bringing the levels up to date (or building
	// a new one), then the new level's normals and GPU buffers.
	level_sync_ms:  f64,
	level_show_ms:  f64,
	// The last HD window: building it, uploading it, and storing it on leaving.
	hd_open_ms:     f64,
	hd_upload_ms:   f64,
	hd_leave_ms:    f64,
	recall_ms:      f64, // the last History brush target built
	// Carrying sculpt layers onto the last rebuilt mesh (a slice's second part: the
	// build of each part starts the stats afresh).
	layers_carry_ms: f64,
	// The last remesh: building the new surface, then preparing it to sculpt and upload.
	remesh_ms:      f64,
	// The last skin carried onto a rebuilt mesh (sculpt.skin_carry).
	skin_carry_ms:  f64,
	remesh_setup_ms: f64,
	remesh_cell:    f32, // the last remesh's lattice spacing, in its object's mesh space
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

// Starts the frame timings and counts afresh, as for a run whose set-up is done (a start-up
// script): every ring and running count. The times of the last level change, HD window,
// remesh and the like stay, since the panels that show them still show those operations.
stats_restart :: proc(s: ^Frame_Stats) {
	for f in reflect.struct_fields_zipped(Frame_Stats) {
		at := rawptr(uintptr(s) + f.offset)
		switch f.type.id {
		case Sample_Ring: (^Sample_Ring)(at)^ = {}
		}
	}
	s.dabs_total, s.cache_redraws, s.partial_frames = 0, 0, 0
}
